extends Node3D
class_name MapCreatorEditor

# In-game map editor (scenes/map_creator.tscn), reached from the start menu. Lets players
# build arenas from primitives (with bevels), import 3D model files, place spawns and
# lights, then playtest the map solo — all without the Godot editor. Maps persist as JSON
# in user://custom_maps/<slug>/ (see MapDocument) and are loaded at runtime by
# MapGenerator under the "custom:<slug>" map id.
#
# Controls (also shown in the bottom hint bar):
#   RMB hold        fly camera (WASD + Q/E, Shift fast, wheel = speed)
#   LMB             select / confirm transform / drag a gizmo handle
#   1 / 2 / 3       gizmo tool: move arrows / rotate rings / scale cubes (press again to hide)
#   G / R / S       move / rotate / scale the selection (Blender-style, keyboard-modal)
#   X / Y / Z       constrain the active transform to a world axis
#   F               focus camera on selection
#   Ctrl+D          duplicate      Del: delete      Esc: cancel / deselect
#   Ctrl+Z / Ctrl+Y undo / redo    Ctrl+S: save
#
# The gizmo handles are real (editor-only) physics bodies on their own collision layer
# (GIZMO_LAYER) so handle drags and object picking can never steal each other's clicks.
# A gizmo drag reuses the exact same op machinery as G/R/S — same axis math, same snap,
# same undo — it just begins on handle press and commits on mouse release.
#
# All UI is procedural (project convention: no .tscn menus). Physics-space raycasts are
# queued into _physics_process so the editor never queries a locked space.

# Set by the start menu before changing scene: which map to open ("" = new untitled).
static var open_slug: String = ""

# Set when launching a playtest, consumed by the start menu on return so the editor
# reopens on the same map after the player leaves the test session.
static var _return_after_playtest_slug: String = ""


static func consume_return_slug() -> String:
	var slug := _return_after_playtest_slug
	_return_after_playtest_slug = ""
	return slug


enum OpMode { NONE, GRAB, ROTATE, SCALE }
enum OpSource { MODAL, DRAG }
enum Tool { NONE, MOVE, ROTATE, SCALE }

const CAMERA_START := Vector3(12.0, 9.0, 12.0)
const ROTATE_SNAP_DEGREES := 15.0
const UNDO_LIMIT := 64
const UNDO_COALESCE_MSEC := 900

const SNAP_STEPS := [0.1, 0.25, 0.5, 1.0, 2.0]

# Physics layer reserved for gizmo handles; object picking masks it out (layer 1 only).
const GIZMO_LAYER := 1 << 19
const OBJECT_PICK_MASK := 1
const GIZMO_SCREEN_SCALE := 0.13

const AXIS_COLORS: Array[Color] = [
	Color(0.93, 0.29, 0.29),
	Color(0.45, 0.85, 0.36),
	Color(0.33, 0.55, 0.98),
]
const GIZMO_CENTER_COLOR := Color(0.92, 0.92, 0.95)

var doc: MapDocument
var model_cache: Dictionary = {}

var camera: Camera3D
var map_root: Node3D
var objects_parent: Node3D
var selection_lines: MeshInstance3D
var selection_mesh: ImmediateMesh
var grid_instance: MeshInstance3D

var entry_nodes: Dictionary = {}
var selected_id: int = -1

var flying: bool = false
var fly_speed: float = 10.0

var op_mode: int = OpMode.NONE
var op_source: int = OpSource.MODAL
var op_axis: int = -1
var op_entry_backup: Dictionary = {}
var op_doc_snapshot: Dictionary = {}
var op_start_mouse: Vector2 = Vector2.ZERO
var op_start_position: Vector3 = Vector3.ZERO
var op_start_basis: Basis = Basis.IDENTITY

# Gizmo state. Handles are records: {tool, axis, body, material, color, group}.
var tool_mode: int = Tool.MOVE
var gizmo_root: Node3D
var gizmo_groups: Dictionary = {}
var gizmo_handles: Array = []
var tool_buttons: Dictionary = {}
var _hover_handle: int = -1
var _drag_handle: int = -1
var _lmb_down: bool = false

var snap_enabled: bool = true
var snap_step: float = 0.5

var undo_stack: Array = []
var redo_stack: Array = []
var dirty: bool = false
var _last_undo_tag: String = ""
var _last_undo_msec: int = -100000

# Physics-space work queued from input/UI (raycasts must not run on a locked space).
var _queued_actions: Array = []

# --- UI references -----------------------------------------------------------------------

var ui_layer: CanvasLayer
var name_field: LineEdit
var status_label: Label
var hint_label: Label
var outliner: ItemList
var inspector_root: VBoxContainer
var import_dialog: FileDialog
var error_dialog: AcceptDialog
var exit_dialog: ConfirmationDialog
var blender_dialog: ConfirmationDialog
var blender_path_field: LineEdit
var _pending_blend_path: String = ""
var _suppress_outliner_signal: bool = false


func _ready() -> void:
	# Everything here animates at render-frame rate; interpolation would fight it.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	camera = Camera3D.new()
	camera.position = CAMERA_START
	camera.near = 0.05
	camera.far = 4000.0
	camera.fov = 75.0
	add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.UP)

	_build_grid()
	_build_selection_lines()
	_build_gizmos()
	_build_ui()

	var slug := open_slug
	open_slug = ""

	if slug != "" and MapDocument.map_exists(slug):
		doc = MapDocument.load_map(slug)

	if doc == null:
		doc = MapDocument.create_new("Untitled Map")
		doc.save()

	name_field.text = doc.map_name
	_rebuild_map()
	_refresh_outliner()
	_rebuild_inspector()
	_set_status("Editing '%s'." % doc.map_name)


func _exit_tree() -> void:
	CustomMapBuilder.free_model_cache(model_cache)


# =============================================================================================
# Map node management
# =============================================================================================

func _rebuild_map() -> void:
	if map_root != null:
		map_root.queue_free()

	map_root = CustomMapBuilder.build_map_node(doc, true, model_cache)
	add_child(map_root)
	objects_parent = map_root.get_node("Objects")

	entry_nodes.clear()

	for node in objects_parent.get_children():
		if node.has_meta("map_object_id"):
			entry_nodes[int(node.get_meta("map_object_id"))] = node

	if not entry_nodes.has(selected_id):
		selected_id = -1


func _rebuild_environment() -> void:
	for node_name in ["MapEnvironment", "Sun"]:
		var node := map_root.get_node_or_null(node_name)

		if node != null:
			node.free()

	CustomMapBuilder._add_environment(map_root, doc.environment)


func _rebuild_entry_node(id: int) -> void:
	var entry := doc.get_entry(id)

	if entry.is_empty():
		return

	var old: Node3D = entry_nodes.get(id)

	if old != null and is_instance_valid(old):
		old.free()

	var node := CustomMapBuilder.build_entry_node(entry, doc.slug, true, model_cache)

	if node != null:
		objects_parent.add_child(node)
		entry_nodes[id] = node
	else:
		entry_nodes.erase(id)


func _apply_entry_transform(id: int) -> void:
	var entry := doc.get_entry(id)
	var node: Node3D = entry_nodes.get(id)

	if entry.is_empty() or node == null or not is_instance_valid(node):
		return

	node.position = MapDocument.vec3_from(entry.get("position"))
	node.rotation_degrees = MapDocument.vec3_from(entry.get("rotation_degrees"))

	if String(entry.get("kind", "")) == MapDocument.KIND_MODEL:
		node.scale = MapDocument.vec3_from(entry.get("scale"), Vector3.ONE)


# =============================================================================================
# Undo / redo / dirty state
# =============================================================================================

func _push_undo(tag: String = "") -> void:
	var now := Time.get_ticks_msec()

	if tag != "" and tag == _last_undo_tag and now - _last_undo_msec < UNDO_COALESCE_MSEC:
		_last_undo_msec = now
		_mark_dirty()
		return

	_last_undo_tag = tag
	_last_undo_msec = now
	undo_stack.append({"doc": doc.to_dict(), "selected": selected_id})

	while undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()

	redo_stack.clear()
	_mark_dirty()


func _undo() -> void:
	if op_mode != OpMode.NONE or undo_stack.is_empty():
		return

	redo_stack.append({"doc": doc.to_dict(), "selected": selected_id})
	_restore_snapshot(undo_stack.pop_back())
	_set_status("Undo.")


func _redo() -> void:
	if op_mode != OpMode.NONE or redo_stack.is_empty():
		return

	undo_stack.append({"doc": doc.to_dict(), "selected": selected_id})
	_restore_snapshot(redo_stack.pop_back())
	_set_status("Redo.")


func _restore_snapshot(snapshot: Dictionary) -> void:
	doc.load_from_dict(snapshot["doc"])
	selected_id = int(snapshot.get("selected", -1))
	_last_undo_tag = ""
	_mark_dirty()
	name_field.text = doc.map_name
	_rebuild_map()
	_refresh_outliner()
	_rebuild_inspector()


func _mark_dirty() -> void:
	dirty = true
	_refresh_title_status()


func _refresh_title_status() -> void:
	if status_label != null:
		var marker := "●  " if dirty else ""
		status_label.text = marker + status_label.get_meta("base_text", "")


func _set_status(text: String) -> void:
	if status_label != null:
		status_label.set_meta("base_text", text)
		_refresh_title_status()


# =============================================================================================
# Input
# =============================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			if event.pressed and op_mode != OpMode.NONE:
				_cancel_op()
				return

			flying = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if flying else Input.MOUSE_MODE_VISIBLE
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_lmb_down = true

				if op_mode != OpMode.NONE:
					# Keyboard-modal ops confirm on click; a running drag ignores extras.
					if op_source == OpSource.MODAL:
						_commit_op()
				elif not flying:
					_queued_actions.append(_press_at.bind(event.position))
			else:
				_lmb_down = false

				# Gizmo drags commit on release.
				if op_mode != OpMode.NONE and op_source == OpSource.DRAG:
					_commit_op()
		MOUSE_BUTTON_WHEEL_UP:
			if flying:
				fly_speed = clampf(fly_speed * 1.15, 1.0, 120.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			if flying:
				fly_speed = clampf(fly_speed / 1.15, 1.0, 120.0)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if flying:
		var sensitivity := 0.0032
		camera.rotation.y -= event.relative.x * sensitivity
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * sensitivity, -1.55, 1.55)
		camera.rotation.z = 0.0
	elif op_mode != OpMode.NONE:
		_update_op(event.position)


func _handle_key(event: InputEventKey) -> void:
	var key := event.keycode

	if event.ctrl_pressed:
		match key:
			KEY_S:
				_save_map()
			KEY_D:
				_duplicate_selection()
			KEY_Z:
				if event.shift_pressed:
					_redo()
				else:
					_undo()
			KEY_Y:
				_redo()

		return

	match key:
		KEY_1:
			_set_tool(Tool.NONE if tool_mode == Tool.MOVE else Tool.MOVE)
		KEY_2:
			_set_tool(Tool.NONE if tool_mode == Tool.ROTATE else Tool.ROTATE)
		KEY_3:
			_set_tool(Tool.NONE if tool_mode == Tool.SCALE else Tool.SCALE)
		KEY_G:
			_begin_op(OpMode.GRAB)
		KEY_R:
			_begin_op(OpMode.ROTATE)
		KEY_S:
			if not flying:
				_begin_op(OpMode.SCALE)
		KEY_X:
			_set_op_axis(0)
		KEY_Y:
			_set_op_axis(1)
		KEY_Z:
			_set_op_axis(2)
		KEY_F:
			_focus_selection()
		KEY_DELETE, KEY_BACKSPACE:
			_delete_selection()
		KEY_ENTER, KEY_KP_ENTER:
			if op_mode != OpMode.NONE:
				_commit_op()
		KEY_ESCAPE:
			if op_mode != OpMode.NONE:
				_cancel_op()
			else:
				_select_entry(-1)


func _process(delta: float) -> void:
	if flying:
		var motion := Vector3.ZERO

		if Input.is_physical_key_pressed(KEY_W):
			motion -= camera.global_basis.z

		if Input.is_physical_key_pressed(KEY_S):
			motion += camera.global_basis.z

		if Input.is_physical_key_pressed(KEY_A):
			motion -= camera.global_basis.x

		if Input.is_physical_key_pressed(KEY_D):
			motion += camera.global_basis.x

		if Input.is_physical_key_pressed(KEY_Q):
			motion -= Vector3.UP

		if Input.is_physical_key_pressed(KEY_E):
			motion += Vector3.UP

		if motion != Vector3.ZERO:
			var boost := 3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
			camera.position += motion.normalized() * fly_speed * boost * delta

	_update_gizmo_placement()
	_redraw_selection_lines()


func _physics_process(_delta: float) -> void:
	while not _queued_actions.is_empty():
		var action: Callable = _queued_actions.pop_front()
		action.call()

	_update_gizmo_hover()


# =============================================================================================
# Picking / placement
# =============================================================================================

# LMB press router: gizmo handles get first claim on the click, then object picking.
func _press_at(screen_position: Vector2) -> void:
	if gizmo_root != null and gizmo_root.visible and op_mode == OpMode.NONE:
		var handle := _raycast_gizmo_handle(screen_position)

		if handle >= 0:
			# A press-and-instant-release can beat this queued action; only start a drag
			# while the button is still down, and never pick "through" a handle.
			if _lmb_down:
				_begin_gizmo_drag(handle, screen_position)

			return

	_pick_at(screen_position)


func _pick_at(screen_position: Vector2) -> void:
	var query := PhysicsRayQueryParameters3D.create(
		camera.project_ray_origin(screen_position),
		camera.project_ray_origin(screen_position) + camera.project_ray_normal(screen_position) * 2000.0
	)
	query.collision_mask = OBJECT_PICK_MASK
	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		_select_entry(-1)
		return

	var node: Node = hit.get("collider")

	while node != null and not node.has_meta("map_object_id"):
		node = node.get_parent()

	_select_entry(int(node.get_meta("map_object_id")) if node != null else -1)


# Where a newly added object should land: surface under the viewport centre, else 8 m ahead.
func _placement_transform(half_extent: float, align_to_surface: bool) -> Dictionary:
	var center := get_viewport().get_visible_rect().size * 0.5
	var origin := camera.project_ray_origin(center)
	var direction := camera.project_ray_normal(center)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 120.0)
	query.collision_mask = OBJECT_PICK_MASK
	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	var position: Vector3
	var normal := Vector3.UP

	if hit.is_empty():
		position = origin + direction * 8.0
	else:
		normal = hit["normal"]
		position = Vector3(hit["position"]) + normal * half_extent

	if snap_enabled:
		position = _snap_vector(position)

	var rotation := Vector3.ZERO

	if align_to_surface and not hit.is_empty():
		var forward := -camera.global_basis.z
		rotation = _basis_from_up(normal, forward).get_euler() * (180.0 / PI)

	return {"position": position, "rotation": rotation}


func _basis_from_up(up: Vector3, forward_hint: Vector3) -> Basis:
	var y := up.normalized()
	var x := forward_hint.cross(y)

	if x.length_squared() < 0.0001:
		x = y.cross(Vector3.RIGHT)

		if x.length_squared() < 0.0001:
			x = y.cross(Vector3.FORWARD)

	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z).orthonormalized()


func _snap_vector(value: Vector3) -> Vector3:
	return Vector3(
		snappedf(value.x, snap_step),
		snappedf(value.y, snap_step),
		snappedf(value.z, snap_step)
	)


# =============================================================================================
# Selection
# =============================================================================================

func _select_entry(id: int, from_outliner := false) -> void:
	if op_mode != OpMode.NONE:
		_cancel_op()

	selected_id = id if entry_nodes.has(id) else -1
	_rebuild_inspector()

	if not from_outliner:
		_sync_outliner_selection()


func _selected_entry() -> Dictionary:
	return doc.get_entry(selected_id) if selected_id >= 0 else {}


func _selected_node() -> Node3D:
	var node: Variant = entry_nodes.get(selected_id)
	return node if node is Node3D and is_instance_valid(node) else null


func _selection_aabb(node: Node3D) -> AABB:
	var merged := AABB()
	var found := false
	var pending: Array = [node]

	while not pending.is_empty():
		var current: Node = pending.pop_back()

		for child in current.get_children():
			pending.append(child)

		if current is VisualInstance3D:
			var visual := current as VisualInstance3D
			var box: AABB = visual.global_transform * visual.get_aabb()

			if found:
				merged = merged.merge(box)
			else:
				merged = box
				found = true

	if not found:
		merged = AABB(node.global_position - Vector3.ONE * 0.5, Vector3.ONE)

	return merged


func _focus_selection() -> void:
	var node := _selected_node()

	if node == null:
		return

	var box := _selection_aabb(node)
	var distance := maxf(box.size.length() * 1.4, 4.0)
	camera.position = box.get_center() + camera.global_basis.z * distance
	camera.look_at(box.get_center(), Vector3.UP)


# =============================================================================================
# Transform operations (Blender-style G/R/S)
# =============================================================================================

func _begin_op(mode: int) -> void:
	var entry := _selected_entry()

	if entry.is_empty() or flying:
		return

	if mode == OpMode.SCALE and [MapDocument.KIND_SPAWN, MapDocument.KIND_LIGHT].has(String(entry["kind"])):
		_set_status("Spawns and lights have no scale — use G to move, R to rotate.")
		return

	if op_mode != OpMode.NONE:
		_cancel_op()

	op_mode = mode
	op_source = OpSource.MODAL
	op_axis = -1
	op_entry_backup = entry.duplicate(true)
	op_doc_snapshot = doc.to_dict()
	op_start_mouse = get_viewport().get_mouse_position()

	var node := _selected_node()
	op_start_position = node.global_position
	op_start_basis = node.global_basis

	_update_hint_for_op()


func _set_op_axis(axis: int) -> void:
	if op_mode == OpMode.NONE:
		return

	op_axis = -1 if op_axis == axis else axis
	_update_op(get_viewport().get_mouse_position())
	_update_hint_for_op()


func _cancel_op() -> void:
	if op_mode == OpMode.NONE:
		return

	var entry := _selected_entry()

	if not entry.is_empty():
		entry.clear()
		entry.merge(op_entry_backup)
		_refresh_entry_after_op(entry)

	op_mode = OpMode.NONE
	op_axis = -1
	op_source = OpSource.MODAL
	_drag_handle = -1
	_reset_hint()
	_rebuild_inspector()


func _commit_op() -> void:
	if op_mode == OpMode.NONE:
		return

	# A no-movement confirm (or a dead click on a gizmo handle) must not pollute undo.
	var changed := _selected_entry() != op_entry_backup

	if changed:
		undo_stack.append({"doc": op_doc_snapshot, "selected": selected_id})

		while undo_stack.size() > UNDO_LIMIT:
			undo_stack.pop_front()

		redo_stack.clear()
		_last_undo_tag = ""
		_mark_dirty()

	op_mode = OpMode.NONE
	op_axis = -1
	op_source = OpSource.MODAL
	_drag_handle = -1
	_reset_hint()
	_rebuild_inspector()


func _update_op(mouse_position: Vector2) -> void:
	var entry := _selected_entry()

	if entry.is_empty():
		return

	match op_mode:
		OpMode.GRAB:
			_update_grab(entry, mouse_position)
		OpMode.ROTATE:
			_update_rotate(entry, mouse_position)
		OpMode.SCALE:
			_update_scale(entry, mouse_position)


func _update_grab(entry: Dictionary, mouse_position: Vector2) -> void:
	var new_position := op_start_position

	if op_axis >= 0:
		var axis := Vector3.ZERO
		axis[op_axis] = 1.0
		var t_now := _closest_axis_parameter(op_start_position, axis, mouse_position)
		var t_start := _closest_axis_parameter(op_start_position, axis, op_start_mouse)
		new_position = op_start_position + axis * (t_now - t_start)
	else:
		var plane := Plane(-camera.global_basis.z, op_start_position)
		var hit_now: Variant = _plane_hit(plane, mouse_position)
		var hit_start: Variant = _plane_hit(plane, op_start_mouse)

		if hit_now != null and hit_start != null:
			new_position = op_start_position + (Vector3(hit_now) - Vector3(hit_start))

	if snap_enabled:
		new_position = _snap_vector(new_position)

	entry["position"] = MapDocument.list_from_vec3(new_position)
	_apply_entry_transform(int(entry["id"]))


func _plane_hit(plane: Plane, screen_point: Vector2) -> Variant:
	return plane.intersects_ray(
		camera.project_ray_origin(screen_point),
		camera.project_ray_normal(screen_point)
	)


# Parameter of the closest point on line (origin + t*axis) to the mouse ray.
func _closest_axis_parameter(origin: Vector3, axis: Vector3, screen_point: Vector2) -> float:
	var ray_origin := camera.project_ray_origin(screen_point)
	var ray_direction := camera.project_ray_normal(screen_point)

	var w := origin - ray_origin
	var a := axis.dot(axis)
	var b := axis.dot(ray_direction)
	var c := ray_direction.dot(ray_direction)
	var d := axis.dot(w)
	var e := ray_direction.dot(w)
	var denominator := a * c - b * b

	if absf(denominator) < 0.000001:
		return 0.0

	return (b * e - c * d) / denominator


func _update_rotate(entry: Dictionary, mouse_position: Vector2) -> void:
	var center := camera.unproject_position(op_start_position)
	var from := op_start_mouse - center
	var to := mouse_position - center

	if from.length() < 4.0 or to.length() < 4.0:
		return

	var delta := to.angle() - from.angle()

	var axis: Vector3

	if op_axis >= 0:
		axis = Vector3.ZERO
		axis[op_axis] = 1.0
	else:
		axis = -camera.global_basis.z

	var view_direction := (op_start_position - camera.global_position).normalized()

	if axis.dot(view_direction) < 0.0:
		delta = -delta

	if snap_enabled:
		delta = deg_to_rad(snappedf(rad_to_deg(delta), ROTATE_SNAP_DEGREES))

	var node := _selected_node()

	if node == null:
		return

	node.global_basis = Basis(axis.normalized(), delta) * op_start_basis
	entry["rotation_degrees"] = MapDocument.list_from_vec3(node.rotation_degrees)


func _update_scale(entry: Dictionary, mouse_position: Vector2) -> void:
	var center := camera.unproject_position(op_start_position)
	var start_distance := maxf((op_start_mouse - center).length(), 5.0)
	var ratio := clampf((mouse_position - center).length() / start_distance, 0.02, 50.0)

	match String(entry.get("kind", "")):
		MapDocument.KIND_PRIMITIVE:
			_scale_primitive(entry, ratio)
			_rebuild_entry_node(int(entry["id"]))
		MapDocument.KIND_MODEL:
			var base := MapDocument.vec3_from(op_entry_backup.get("scale"), Vector3.ONE)
			var scaled := base * ratio

			if op_axis >= 0:
				scaled = base
				scaled[op_axis] = base[op_axis] * ratio

			entry["scale"] = MapDocument.list_from_vec3(scaled.clamp(Vector3.ONE * 0.001, Vector3.ONE * 1000.0))
			_apply_entry_transform(int(entry["id"]))


func _scale_primitive(entry: Dictionary, ratio: float) -> void:
	var shape := String(entry.get("shape", "box"))

	match shape:
		"box", "ramp":
			var base := MapDocument.vec3_from(op_entry_backup.get("size"), Vector3(2, 2, 2))
			var size := base * ratio

			if op_axis >= 0:
				size = base
				size[op_axis] = base[op_axis] * ratio

			entry["size"] = MapDocument.list_from_vec3(size.clamp(Vector3.ONE * 0.05, Vector3.ONE * 2000.0))
		"sphere":
			entry["radius"] = clampf(float(op_entry_backup.get("radius", 1.0)) * ratio, 0.025, 1000.0)
		"cylinder", "cone", "capsule":
			var scale_radius := op_axis == -1 or op_axis == 0 or op_axis == 2
			var scale_height := op_axis == -1 or op_axis == 1

			if scale_radius:
				entry["radius"] = clampf(float(op_entry_backup.get("radius", 1.0)) * ratio, 0.025, 1000.0)

			if scale_height:
				entry["height"] = clampf(float(op_entry_backup.get("height", 2.0)) * ratio, 0.05, 2000.0)
		"torus":
			entry["radius"] = clampf(float(op_entry_backup.get("radius", 2.0)) * ratio, 0.05, 1000.0)

			if op_axis == -1:
				entry["thickness"] = clampf(float(op_entry_backup.get("thickness", 0.6)) * ratio, 0.025, 1000.0)


func _refresh_entry_after_op(entry: Dictionary) -> void:
	var id := int(entry.get("id", -1))

	match String(entry.get("kind", "")):
		MapDocument.KIND_PRIMITIVE:
			_rebuild_entry_node(id)
		_:
			_apply_entry_transform(id)


func _update_hint_for_op() -> void:
	var axis_text: String = ["X", "Y", "Z"][op_axis] if op_axis >= 0 else "free"
	var mode_text := String({OpMode.GRAB: "Move", OpMode.ROTATE: "Rotate", OpMode.SCALE: "Scale"}.get(op_mode, ""))

	if op_source == OpSource.DRAG:
		hint_label.text = "%s [%s] — release to confirm · Esc/RMB cancel" % [mode_text, axis_text]
	else:
		hint_label.text = "%s [%s] — LMB/Enter confirm · X/Y/Z lock axis · Esc/RMB cancel" % [mode_text, axis_text]


func _reset_hint() -> void:
	hint_label.text = (
		"RMB fly (WASD+QE) · LMB select · drag gizmo to transform · 1/2/3 move/rotate/scale tool"
		+ " · G/R/S keyboard transform · X/Y/Z axis · F focus · Ctrl+D duplicate · Del delete"
		+ " · Ctrl+Z undo · Ctrl+S save"
	)


# =============================================================================================
# Transform gizmo (move arrows / rotate rings / scale cubes)
# =============================================================================================

func _set_tool(tool: int) -> void:
	if op_mode != OpMode.NONE:
		_cancel_op()

	tool_mode = tool

	for t in tool_buttons:
		(tool_buttons[t] as Button).set_pressed_no_signal(t == tool_mode)

	_set_hover_handle(-1)
	_reset_hint()


func _build_gizmos() -> void:
	gizmo_root = Node3D.new()
	gizmo_root.name = "TransformGizmo"
	gizmo_root.visible = false
	add_child(gizmo_root)

	for tool in [Tool.MOVE, Tool.ROTATE, Tool.SCALE]:
		var group := Node3D.new()
		group.name = "Gizmo%d" % tool
		group.visible = false
		gizmo_root.add_child(group)
		gizmo_groups[tool] = group

	for axis in range(3):
		_add_arrow_handle(gizmo_groups[Tool.MOVE], axis)
		_add_ring_handle(gizmo_groups[Tool.ROTATE], axis)
		_add_scale_handle(gizmo_groups[Tool.SCALE], axis)

	# Centre handles: screen-plane move, view-axis rotate, uniform scale (all axis = -1).
	_add_center_handle(gizmo_groups[Tool.MOVE], Tool.MOVE, 0.10, false)
	_add_center_handle(gizmo_groups[Tool.ROTATE], Tool.ROTATE, 0.07, false)
	_add_center_handle(gizmo_groups[Tool.SCALE], Tool.SCALE, 0.11, true)


func _gizmo_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.render_priority = 20
	material.albedo_color = Color(color.r, color.g, color.b, 0.95)
	return material


# Rotation that points a +Y-authored mesh along the given world axis (and lays the
# default around-Y torus into the plane perpendicular to that axis).
func _gizmo_axis_rotation(axis: int) -> Vector3:
	match axis:
		0:
			return Vector3(0.0, 0.0, -90.0)
		2:
			return Vector3(90.0, 0.0, 0.0)

	return Vector3.ZERO


func _register_gizmo_handle(parent: Node3D, tool: int, axis: int, color: Color, material: StandardMaterial3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "HandleBody"
	body.collision_layer = GIZMO_LAYER
	body.collision_mask = 0
	body.set_meta("gizmo_index", gizmo_handles.size())
	parent.add_child(body)

	gizmo_handles.append({
		"tool": tool,
		"axis": axis,
		"body": body,
		"material": material,
		"color": color,
	})

	return body


func _add_arrow_handle(group: Node3D, axis: int) -> void:
	var color := AXIS_COLORS[axis]
	var material := _gizmo_material(color)

	var handle := Node3D.new()
	handle.name = "Arrow%d" % axis
	handle.rotation_degrees = _gizmo_axis_rotation(axis)
	group.add_child(handle)

	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.028
	shaft_mesh.bottom_radius = 0.028
	shaft_mesh.height = 0.75
	shaft_mesh.radial_segments = 10
	shaft.mesh = shaft_mesh
	shaft.position = Vector3(0.0, 0.525, 0.0)
	shaft.material_override = material
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	handle.add_child(shaft)

	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.085
	tip_mesh.height = 0.24
	tip_mesh.radial_segments = 12
	tip.mesh = tip_mesh
	tip.position = Vector3(0.0, 1.02, 0.0)
	tip.material_override = material
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	handle.add_child(tip)

	var body := _register_gizmo_handle(handle, Tool.MOVE, axis, color, material)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.11
	shape.height = 1.05
	collision.shape = shape
	collision.position = Vector3(0.0, 0.62, 0.0)
	body.add_child(collision)


func _add_ring_handle(group: Node3D, axis: int) -> void:
	var color := AXIS_COLORS[axis]
	var material := _gizmo_material(color)

	var handle := Node3D.new()
	handle.name = "Ring%d" % axis
	handle.rotation_degrees = _gizmo_axis_rotation(axis)
	group.add_child(handle)

	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.80
	ring_mesh.outer_radius = 0.86
	ring_mesh.rings = 48
	ring_mesh.ring_segments = 8
	ring.mesh = ring_mesh
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	handle.add_child(ring)

	# Physics has no torus shape: a chain of small spheres along the circle gives exact
	# ring-only hits (clicks through the ring's middle fall through to object picking).
	var body := _register_gizmo_handle(handle, Tool.ROTATE, axis, color, material)
	var segments := 20

	for i in range(segments):
		var angle := float(i) / float(segments) * TAU
		var collision := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.09
		collision.shape = sphere
		collision.position = Vector3(cos(angle), 0.0, sin(angle)) * 0.83
		body.add_child(collision)


func _add_scale_handle(group: Node3D, axis: int) -> void:
	var color := AXIS_COLORS[axis]
	var material := _gizmo_material(color)

	var handle := Node3D.new()
	handle.name = "ScaleAxis%d" % axis
	handle.rotation_degrees = _gizmo_axis_rotation(axis)
	group.add_child(handle)

	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.024
	shaft_mesh.bottom_radius = 0.024
	shaft_mesh.height = 0.68
	shaft_mesh.radial_segments = 10
	shaft.mesh = shaft_mesh
	shaft.position = Vector3(0.0, 0.49, 0.0)
	shaft.material_override = material
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	handle.add_child(shaft)

	var cube := MeshInstance3D.new()
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3.ONE * 0.16
	cube.mesh = cube_mesh
	cube.position = Vector3(0.0, 0.9, 0.0)
	cube.material_override = material
	cube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	handle.add_child(cube)

	var body := _register_gizmo_handle(handle, Tool.SCALE, axis, color, material)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.11
	shape.height = 0.92
	collision.shape = shape
	collision.position = Vector3(0.0, 0.56, 0.0)
	body.add_child(collision)


func _add_center_handle(group: Node3D, tool: int, radius: float, cube: bool) -> void:
	var material := _gizmo_material(GIZMO_CENTER_COLOR)

	var visual := MeshInstance3D.new()
	visual.name = "Center"

	if cube:
		var box := BoxMesh.new()
		box.size = Vector3.ONE * radius * 2.0
		visual.mesh = box
	else:
		var sphere := SphereMesh.new()
		sphere.radius = radius
		sphere.height = radius * 2.0
		visual.mesh = sphere

	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.add_child(visual)

	var body := _register_gizmo_handle(group, tool, -1, GIZMO_CENTER_COLOR, material)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius + 0.04
	collision.shape = shape
	body.add_child(collision)


# Follows the selection at constant screen size; shows only the active tool's handles.
func _update_gizmo_placement() -> void:
	if gizmo_root == null:
		return

	var node := _selected_node()
	var show := node != null and tool_mode != Tool.NONE

	gizmo_root.visible = show

	if not show:
		return

	gizmo_root.global_position = node.global_position
	var distance := camera.global_position.distance_to(gizmo_root.global_position)
	gizmo_root.scale = Vector3.ONE * maxf(distance * GIZMO_SCREEN_SCALE, 0.01)

	for tool in gizmo_groups:
		(gizmo_groups[tool] as Node3D).visible = tool == tool_mode

	# Hidden nodes still collide — take inactive tools' handles off the pick layer so
	# they can never occlude the visible handles (arrows/rings/cubes overlap at centre).
	for handle in gizmo_handles:
		(handle["body"] as StaticBody3D).collision_layer = GIZMO_LAYER if int(handle["tool"]) == tool_mode else 0


func _raycast_gizmo_handle(screen_position: Vector2) -> int:
	var query := PhysicsRayQueryParameters3D.create(
		camera.project_ray_origin(screen_position),
		camera.project_ray_origin(screen_position) + camera.project_ray_normal(screen_position) * 2000.0
	)
	query.collision_mask = GIZMO_LAYER
	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return -1

	var collider: Object = hit.get("collider")

	if collider == null or not collider.has_meta("gizmo_index"):
		return -1

	var index := int(collider.get_meta("gizmo_index"))

	# Only the active tool's handles are grabbable (hidden groups keep their bodies).
	if index < 0 or index >= gizmo_handles.size() or int(gizmo_handles[index]["tool"]) != tool_mode:
		return -1

	return index


func _begin_gizmo_drag(handle_index: int, screen_position: Vector2) -> void:
	var entry := _selected_entry()

	if entry.is_empty() or flying:
		return

	var handle: Dictionary = gizmo_handles[handle_index]
	var mode: int = {Tool.MOVE: OpMode.GRAB, Tool.ROTATE: OpMode.ROTATE, Tool.SCALE: OpMode.SCALE}.get(int(handle["tool"]), OpMode.GRAB)

	if mode == OpMode.SCALE and [MapDocument.KIND_SPAWN, MapDocument.KIND_LIGHT].has(String(entry["kind"])):
		_set_status("Spawns and lights have no scale — use the move or rotate tool.")
		return

	op_mode = mode
	op_source = OpSource.DRAG
	op_axis = int(handle["axis"])
	op_entry_backup = entry.duplicate(true)
	op_doc_snapshot = doc.to_dict()
	op_start_mouse = screen_position
	_drag_handle = handle_index

	var node := _selected_node()
	op_start_position = node.global_position
	op_start_basis = node.global_basis

	_set_hover_handle(handle_index)
	_update_hint_for_op()


# Hover highlight, sampled once per physics tick (raycasts must not run mid-flush).
func _update_gizmo_hover() -> void:
	if gizmo_root == null or not gizmo_root.visible:
		_set_hover_handle(-1)
		return

	if op_mode != OpMode.NONE:
		_set_hover_handle(_drag_handle if op_source == OpSource.DRAG else -1)
		return

	if flying:
		_set_hover_handle(-1)
		return

	_set_hover_handle(_raycast_gizmo_handle(get_viewport().get_mouse_position()))


func _set_hover_handle(index: int) -> void:
	if index == _hover_handle:
		return

	_hover_handle = index

	for i in range(gizmo_handles.size()):
		var handle: Dictionary = gizmo_handles[i]
		var color: Color = handle["color"]

		if i == index:
			color = Color(minf(color.r + 0.35, 1.0), minf(color.g + 0.35, 1.0), minf(color.b + 0.35, 1.0))

		(handle["material"] as StandardMaterial3D).albedo_color = Color(color.r, color.g, color.b, 0.95)


# =============================================================================================
# Add / duplicate / delete
# =============================================================================================

func _add_primitive(shape: String) -> void:
	_queued_actions.append(func() -> void:
		_push_undo()
		var entry := doc.make_primitive_entry(shape)
		var half := 1.0

		match shape:
			"box", "ramp":
				half = MapDocument.vec3_from(entry.get("size"), Vector3(2, 2, 2)).y * 0.5
			"sphere", "cylinder", "cone", "capsule", "torus":
				half = float(entry.get("radius", 1.0))

		var placement := _placement_transform(half, false)
		entry["position"] = MapDocument.list_from_vec3(placement["position"])
		doc.objects.append(entry)
		_spawn_entry_node(entry)
	)


func _add_spawn(team: String) -> void:
	_queued_actions.append(func() -> void:
		_push_undo()
		var entry := doc.make_spawn_entry(team)
		var placement := _placement_transform(1.05, true)
		entry["position"] = MapDocument.list_from_vec3(placement["position"])
		entry["rotation_degrees"] = MapDocument.list_from_vec3(placement["rotation"])
		doc.objects.append(entry)
		_spawn_entry_node(entry)
	)


func _add_light(light_type: String) -> void:
	_queued_actions.append(func() -> void:
		_push_undo()
		var entry := doc.make_light_entry(light_type)
		var placement := _placement_transform(0.5, false)
		entry["position"] = MapDocument.list_from_vec3(placement["position"])
		doc.objects.append(entry)
		_spawn_entry_node(entry)
	)


func _spawn_entry_node(entry: Dictionary) -> void:
	var node := CustomMapBuilder.build_entry_node(entry, doc.slug, true, model_cache)

	if node != null:
		objects_parent.add_child(node)
		entry_nodes[int(entry["id"])] = node

	_refresh_outliner()
	_select_entry(int(entry["id"]))


func _duplicate_selection() -> void:
	var entry := _selected_entry()

	if entry.is_empty() or op_mode != OpMode.NONE:
		return

	_push_undo()
	var copy := entry.duplicate(true)
	copy["id"] = doc.take_object_id()
	copy["name"] = String(entry.get("name", "Object")) + " Copy"
	var position := MapDocument.vec3_from(copy.get("position"))
	position += Vector3(snap_step, 0.0, 0.0) if snap_enabled else Vector3(0.5, 0.0, 0.0)
	copy["position"] = MapDocument.list_from_vec3(position)
	doc.objects.append(copy)
	_spawn_entry_node(copy)
	_set_status("Duplicated '%s'." % String(entry.get("name", "Object")))


func _delete_selection() -> void:
	var entry := _selected_entry()

	if entry.is_empty() or op_mode != OpMode.NONE:
		return

	_push_undo()
	var id := int(entry["id"])
	doc.remove_entry(id)

	var node: Variant = entry_nodes.get(id)

	if node is Node and is_instance_valid(node):
		node.free()

	entry_nodes.erase(id)
	selected_id = -1
	_refresh_outliner()
	_rebuild_inspector()


# =============================================================================================
# Import
# =============================================================================================

func _open_import_dialog() -> void:
	if import_dialog == null:
		import_dialog = FileDialog.new()
		import_dialog.access = FileDialog.ACCESS_FILESYSTEM
		import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		import_dialog.use_native_dialog = true
		import_dialog.title = "Import 3D Model"

		for filter in MapModelImporter.FILE_DIALOG_FILTERS:
			import_dialog.add_filter(filter.get_slice(";", 0).strip_edges(), filter.get_slice(";", 1).strip_edges())

		import_dialog.file_selected.connect(_on_import_file_selected)
		ui_layer.add_child(import_dialog)

	import_dialog.popup_centered_ratio(0.7)


func _on_import_file_selected(path: String) -> void:
	if path.get_extension().to_lower() == "blend" and MapModelImporter.find_blender_executable() == "":
		_pending_blend_path = path
		_open_blender_dialog()
		return

	_run_import(path)


func _run_import(path: String) -> void:
	_set_status("Importing '%s'…" % path.get_file())
	await get_tree().process_frame
	await get_tree().process_frame

	var result := MapModelImporter.import_file(path, doc.slug)

	if not bool(result.get("ok", false)):
		_show_error("Import failed", String(result.get("error", "Unknown error.")))
		_set_status("Import failed.")
		return

	_push_undo()
	var entry := doc.make_model_entry(String(result["relative"]), path.get_file().get_basename())

	_queued_actions.append(func() -> void:
		var placement := _placement_transform(0.0, false)
		entry["position"] = MapDocument.list_from_vec3(placement["position"])
		doc.objects.append(entry)
		_spawn_entry_node(entry)

		var warnings: Array = result.get("warnings", [])

		if warnings.is_empty():
			_set_status("Imported '%s'." % path.get_file())
		else:
			_set_status("Imported with warnings — see popup.")
			_show_error("Imported with warnings", "\n".join(PackedStringArray(warnings)))
	)


func _open_blender_dialog() -> void:
	if blender_dialog == null:
		blender_dialog = ConfirmationDialog.new()
		blender_dialog.title = "Blender needed for .blend import"
		blender_dialog.ok_button_text = "Use this Blender"

		var column := VBoxContainer.new()
		column.custom_minimum_size = Vector2(480.0, 240.0)
		column.add_theme_constant_override("separation", 10)

		var explanation := Label.new()
		explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		explanation.text = (
			".blend files are converted through Blender itself (run invisibly in the background)."
			+ " Blender was not found on this PC.\n\nInstall it from blender.org, or if it is already"
			+ " installed, paste the full path to blender.exe below.\n\nAlternatively, export your"
			+ " model from Blender as .glb and import that — no Blender needed."
		)
		column.add_child(explanation)

		blender_path_field = LineEdit.new()
		blender_path_field.placeholder_text = "C:/Program Files/Blender Foundation/Blender 4.x/blender.exe"
		column.add_child(blender_path_field)

		blender_dialog.add_child(column)
		blender_dialog.confirmed.connect(_on_blender_path_confirmed)
		ui_layer.add_child(blender_dialog)

	blender_dialog.popup_centered()


func _on_blender_path_confirmed() -> void:
	var path := blender_path_field.text.strip_edges().replace("\\", "/")

	if path == "" or not FileAccess.file_exists(path):
		_show_error("Blender not found", "No file exists at:\n" + path)
		return

	GameSettings.blender_path = path
	GameSettings.save()

	if _pending_blend_path != "":
		var pending := _pending_blend_path
		_pending_blend_path = ""
		_run_import(pending)


# =============================================================================================
# Save / playtest / exit
# =============================================================================================

func _save_map() -> bool:
	doc.map_name = MapDocument.sanitize_name(name_field.text)
	name_field.text = doc.map_name

	if doc.save() != OK:
		_show_error("Save failed", "Could not write the map file. Check disk space/permissions.")
		return false

	dirty = false
	_set_status("Saved %s." % Time.get_time_string_from_system().substr(0, 5))
	return true


func _playtest() -> void:
	if doc.count_kind(MapDocument.KIND_SPAWN, "team", "a") == 0:
		_show_error(
			"No Team A spawn",
			"Add at least one Team A spawn point (you spawn on Team A in a solo playtest)."
		)
		return

	if not _save_map():
		return

	_return_after_playtest_slug = doc.slug

	GameLaunch.map_configured = true
	GameLaunch.map_id = MapGenerator.CUSTOM_MAP_PREFIX + doc.slug
	GameLaunch.rules_configured = true
	GameLaunch.min_players_to_start = 1
	GameLaunch.game_mode_id = "team"
	GameLaunch.round_time_limit = 0.0
	GameLaunch.drone_mode = GameLaunch.DRONES_NONE
	GameLaunch.pending_mode = GameLaunch.Mode.TEST_ARENA
	get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _request_exit() -> void:
	if not dirty:
		_exit_to_menu()
		return

	if exit_dialog == null:
		exit_dialog = ConfirmationDialog.new()
		exit_dialog.title = "Unsaved changes"
		exit_dialog.dialog_text = "Save this map before leaving?"
		exit_dialog.ok_button_text = "Save & Exit"
		exit_dialog.add_button("Discard", true, "discard")
		exit_dialog.confirmed.connect(func() -> void:
			if _save_map():
				_exit_to_menu()
		)
		exit_dialog.custom_action.connect(func(action: StringName) -> void:
			if action == &"discard":
				exit_dialog.hide()
				_exit_to_menu()
		)
		ui_layer.add_child(exit_dialog)

	exit_dialog.popup_centered()


func _exit_to_menu() -> void:
	get_tree().change_scene_to_file.call_deferred("res://scenes/start_menu.tscn")


func _show_error(title: String, message: String) -> void:
	if error_dialog == null:
		error_dialog = AcceptDialog.new()
		ui_layer.add_child(error_dialog)

	error_dialog.title = title
	error_dialog.dialog_text = message
	error_dialog.popup_centered()


# =============================================================================================
# 3D helpers (grid + selection outline)
# =============================================================================================

func _build_grid() -> void:
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)

	var extent := 40
	var minor := Color(1.0, 1.0, 1.0, 0.07)
	var major := Color(1.0, 1.0, 1.0, 0.16)

	for i in range(-extent, extent + 1):
		if i == 0:
			continue

		var color := major if i % 5 == 0 else minor
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(Vector3(i, 0, -extent))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(Vector3(i, 0, extent))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(Vector3(-extent, 0, i))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(Vector3(extent, 0, i))

	# Origin axes: X red, Z blue.
	mesh.surface_set_color(Color(0.9, 0.3, 0.3, 0.5))
	mesh.surface_add_vertex(Vector3(-extent, 0, 0))
	mesh.surface_set_color(Color(0.9, 0.3, 0.3, 0.5))
	mesh.surface_add_vertex(Vector3(extent, 0, 0))
	mesh.surface_set_color(Color(0.3, 0.5, 0.95, 0.5))
	mesh.surface_add_vertex(Vector3(0, 0, -extent))
	mesh.surface_set_color(Color(0.3, 0.5, 0.95, 0.5))
	mesh.surface_add_vertex(Vector3(0, 0, extent))
	mesh.surface_end()

	grid_instance = MeshInstance3D.new()
	grid_instance.name = "EditorGrid"
	grid_instance.mesh = mesh
	grid_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(grid_instance)


func _build_selection_lines() -> void:
	selection_mesh = ImmediateMesh.new()
	selection_lines = MeshInstance3D.new()
	selection_lines.name = "SelectionLines"
	selection_lines.mesh = selection_mesh
	selection_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	selection_lines.material_override = material
	add_child(selection_lines)


func _redraw_selection_lines() -> void:
	selection_mesh.clear_surfaces()
	var node := _selected_node()

	if node == null:
		return

	var box := _selection_aabb(node).grow(0.06)
	var color := Color(0.4, 0.9, 1.0, 0.85)

	selection_mesh.surface_begin(Mesh.PRIMITIVE_LINES, null)

	var corners: Array[Vector3] = []

	for i in range(8):
		corners.append(box.get_endpoint(i))

	# AABB endpoints: bit 0 = x, bit 1 = y, bit 2 = z.
	var edges := [
		[0, 1], [0, 2], [1, 3], [2, 3],
		[4, 5], [4, 6], [5, 7], [6, 7],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]

	for edge in edges:
		selection_mesh.surface_set_color(color)
		selection_mesh.surface_add_vertex(corners[edge[0]])
		selection_mesh.surface_set_color(color)
		selection_mesh.surface_add_vertex(corners[edge[1]])

	# Axis guide while a constrained op is running.
	if op_mode != OpMode.NONE and op_axis >= 0:
		var axis := Vector3.ZERO
		axis[op_axis] = 1.0
		var axis_color: Color = [Color(1, 0.35, 0.35, 0.9), Color(0.45, 1, 0.45, 0.9), Color(0.4, 0.55, 1, 0.9)][op_axis]
		selection_mesh.surface_set_color(axis_color)
		selection_mesh.surface_add_vertex(op_start_position - axis * 500.0)
		selection_mesh.surface_set_color(axis_color)
		selection_mesh.surface_add_vertex(op_start_position + axis * 500.0)

	selection_mesh.surface_end()


# =============================================================================================
# UI construction
# =============================================================================================

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "UI"
	add_child(ui_layer)

	_build_top_bar()
	_build_left_panel()
	_build_right_panel()
	_build_bottom_bar()


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	ui_layer.add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	bar.add_child(row)

	var title := Label.new()
	title.text = "  MAP CREATOR"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	row.add_child(title)

	# Gizmo tool switcher — mirrors the 1/2/3 hotkeys; pressing the active tool hides
	# the gizmo. State is synced manually in _set_tool via set_pressed_no_signal.
	for tool_entry in [["Move (1)", Tool.MOVE], ["Rotate (2)", Tool.ROTATE], ["Scale (3)", Tool.SCALE]]:
		var tool: int = tool_entry[1]
		var button := Button.new()
		button.text = String(tool_entry[0])
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(86.0, 34.0)
		button.button_pressed = tool == tool_mode
		button.pressed.connect(func() -> void:
			_set_tool(tool if button.button_pressed else Tool.NONE)
		)
		row.add_child(button)
		tool_buttons[tool] = button

	name_field = LineEdit.new()
	name_field.custom_minimum_size = Vector2(240.0, 0.0)
	name_field.placeholder_text = "Map name"
	name_field.text_changed.connect(func(_text: String) -> void: _mark_dirty())
	row.add_child(name_field)

	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	status_label.set_meta("base_text", "")
	row.add_child(status_label)

	row.add_child(_make_bar_button("Save", _save_map))
	row.add_child(_make_bar_button("Playtest", _playtest))
	row.add_child(_make_bar_button("Exit", _request_exit))


func _make_bar_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(96.0, 34.0)
	button.pressed.connect(handler)
	return button


func _build_left_panel() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.offset_top = 44.0
	panel.offset_bottom = -30.0
	panel.custom_minimum_size = Vector2(220.0, 0.0)
	ui_layer.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)

	column.add_child(_make_section_label("ADD OBJECT"))

	var shape_grid := GridContainer.new()
	shape_grid.columns = 2
	shape_grid.add_theme_constant_override("h_separation", 6)
	shape_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(shape_grid)

	for shape in [["Box", "box"], ["Sphere", "sphere"], ["Cylinder", "cylinder"], ["Capsule", "capsule"], ["Ramp", "ramp"], ["Cone", "cone"], ["Torus", "torus"]]:
		shape_grid.add_child(_make_add_button(String(shape[0]), _add_primitive.bind(String(shape[1]))))

	column.add_child(_make_section_label("SPAWNS & LIGHTS"))

	var utility_grid := GridContainer.new()
	utility_grid.columns = 2
	utility_grid.add_theme_constant_override("h_separation", 6)
	utility_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(utility_grid)

	utility_grid.add_child(_make_add_button("Spawn A", _add_spawn.bind("a"), CustomMapBuilder.TEAM_A_COLOR))
	utility_grid.add_child(_make_add_button("Spawn B", _add_spawn.bind("b"), CustomMapBuilder.TEAM_B_COLOR))
	utility_grid.add_child(_make_add_button("Omni Light", _add_light.bind("omni")))
	utility_grid.add_child(_make_add_button("Spot Light", _add_light.bind("spot")))

	var import_button := _make_add_button("Import Model…  (.blend .glb .obj .fbx .stl)", _open_import_dialog)
	import_button.custom_minimum_size = Vector2(0.0, 40.0)
	column.add_child(import_button)

	column.add_child(_make_section_label("OBJECTS"))

	outliner = ItemList.new()
	outliner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outliner.item_selected.connect(_on_outliner_selected)
	column.add_child(outliner)


func _make_section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0, 0.8))
	return label


func _make_add_button(text: String, handler: Callable, tint := Color.WHITE) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(100.0, 32.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if tint != Color.WHITE:
		button.add_theme_color_override("font_color", tint)

	button.pressed.connect(handler)
	return button


func _on_outliner_selected(index: int) -> void:
	if _suppress_outliner_signal:
		return

	var id: Variant = outliner.get_item_metadata(index)
	_select_entry(int(id) if id != null else -1, true)


func _refresh_outliner() -> void:
	_suppress_outliner_signal = true
	outliner.clear()

	for entry in doc.objects:
		if not (entry is Dictionary):
			continue

		var prefix := ""

		match String(entry.get("kind", "")):
			MapDocument.KIND_PRIMITIVE:
				prefix = "▢ "
			MapDocument.KIND_MODEL:
				prefix = "◆ "
			MapDocument.KIND_SPAWN:
				prefix = "◉ "
			MapDocument.KIND_LIGHT:
				prefix = "✦ "

		var index := outliner.add_item(prefix + String(entry.get("name", "Object")))
		outliner.set_item_metadata(index, int(entry.get("id", -1)))

	_suppress_outliner_signal = false
	_sync_outliner_selection()


func _sync_outliner_selection() -> void:
	_suppress_outliner_signal = true

	for index in range(outliner.item_count):
		if int(outliner.get_item_metadata(index)) == selected_id:
			outliner.select(index)
			_suppress_outliner_signal = false
			return

	outliner.deselect_all()
	_suppress_outliner_signal = false


func _build_bottom_bar() -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	ui_layer.add_child(bar)

	hint_label = Label.new()
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_font_size_override("font_size", 13)
	hint_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	bar.add_child(hint_label)
	_reset_hint()


func _build_right_panel() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_top = 44.0
	panel.offset_bottom = -30.0
	panel.custom_minimum_size = Vector2(300.0, 0.0)
	ui_layer.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	inspector_root = VBoxContainer.new()
	inspector_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_root.add_theme_constant_override("separation", 8)
	scroll.add_child(inspector_root)


# =============================================================================================
# Inspector
# =============================================================================================

func _rebuild_inspector() -> void:
	for child in inspector_root.get_children():
		child.queue_free()

	var entry := _selected_entry()

	if entry.is_empty():
		_build_map_inspector()
	else:
		_build_entry_inspector(entry)

	_sync_outliner_selection()


func _build_entry_inspector(entry: Dictionary) -> void:
	var kind := String(entry.get("kind", ""))

	inspector_root.add_child(_make_section_label("SELECTION"))

	var name_edit := LineEdit.new()
	name_edit.text = String(entry.get("name", "Object"))
	name_edit.text_changed.connect(func(text: String) -> void:
		if text.strip_edges() == "":
			return

		_push_undo("entry_name")
		entry["name"] = MapDocument.sanitize_name(text)
		_refresh_outliner()
	)
	inspector_root.add_child(name_edit)

	_add_vec3_rows(entry, "position", "Position", -100000.0, 100000.0, false)
	_add_vec3_rows(entry, "rotation_degrees", "Rotation°", -3600.0, 3600.0, false)

	match kind:
		MapDocument.KIND_PRIMITIVE:
			_build_primitive_inspector(entry)
		MapDocument.KIND_MODEL:
			_add_vec3_rows(entry, "scale", "Scale", 0.001, 1000.0, false)
			var source := Label.new()
			source.text = "File: " + String(entry.get("source", ""))
			source.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			source.add_theme_font_size_override("font_size", 12)
			source.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
			inspector_root.add_child(source)
		MapDocument.KIND_SPAWN:
			var team_row := HBoxContainer.new()
			team_row.add_child(_make_row_label("Team"))
			var team_option := OptionButton.new()
			team_option.add_item("Team A (blue)", 0)
			team_option.add_item("Team B (orange)", 1)
			team_option.selected = 1 if String(entry.get("team", "a")) == "b" else 0
			team_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			team_option.item_selected.connect(func(index: int) -> void:
				_push_undo()
				entry["team"] = "b" if index == 1 else "a"
				entry["name"] = "Spawn " + ("B" if index == 1 else "A")
				_rebuild_entry_node(int(entry["id"]))
				_refresh_outliner()
			)
			team_row.add_child(team_option)
			inspector_root.add_child(team_row)
		MapDocument.KIND_LIGHT:
			_build_light_inspector(entry)

	inspector_root.add_child(HSeparator.new())

	var delete_button := Button.new()
	delete_button.text = "Delete (Del)"
	delete_button.focus_mode = Control.FOCUS_NONE
	delete_button.pressed.connect(_delete_selection)
	inspector_root.add_child(delete_button)

	var duplicate_button := Button.new()
	duplicate_button.text = "Duplicate (Ctrl+D)"
	duplicate_button.focus_mode = Control.FOCUS_NONE
	duplicate_button.pressed.connect(_duplicate_selection)
	inspector_root.add_child(duplicate_button)


func _build_primitive_inspector(entry: Dictionary) -> void:
	var shape := String(entry.get("shape", "box"))

	inspector_root.add_child(_make_section_label("SHAPE — " + shape.to_upper()))

	match shape:
		"box", "ramp":
			_add_vec3_rows(entry, "size", "Size", 0.05, 2000.0, true)
		"sphere":
			_add_number_row(entry, "radius", "Radius", 0.025, 1000.0, true)
		"cylinder", "cone", "capsule":
			_add_number_row(entry, "radius", "Radius", 0.025, 1000.0, true)
			_add_number_row(entry, "height", "Height", 0.05, 2000.0, true)
		"torus":
			_add_number_row(entry, "radius", "Ring Radius", 0.05, 1000.0, true)
			_add_number_row(entry, "thickness", "Thickness", 0.025, 1000.0, true)

	if shape == "box" or shape == "cylinder":
		inspector_root.add_child(_make_section_label("BEVEL"))
		_add_number_row(entry, "bevel_radius", "Bevel Radius", 0.0, 1000.0, true)
		_add_number_row(entry, "bevel_segments", "Bevel Segments", 1, BevelMesh.MAX_SEGMENTS, true, true)

		var bevel_note := Label.new()
		bevel_note.text = "1 segment = flat chamfer; more = rounder."
		bevel_note.add_theme_font_size_override("font_size", 11)
		bevel_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
		inspector_root.add_child(bevel_note)

	inspector_root.add_child(_make_section_label("MATERIAL"))

	var material: Dictionary = entry.get("material", MapDocument.default_material())
	entry["material"] = material

	_add_color_row(material, "color", "Color", entry)
	_add_slider_row(material, "metallic", "Metallic", entry)
	_add_slider_row(material, "roughness", "Roughness", entry)
	_add_color_row(material, "emission", "Emission", entry)
	_add_number_row_dict(material, "emission_energy", "Emit Energy", 0.0, 32.0, entry)


func _build_light_inspector(entry: Dictionary) -> void:
	inspector_root.add_child(_make_section_label("LIGHT — " + String(entry.get("type", "omni")).to_upper()))

	_add_color_row(entry, "color", "Color", entry)
	_add_number_row(entry, "energy", "Energy", 0.0, 64.0, true)
	_add_number_row(entry, "range", "Range", 0.5, 500.0, true)

	if String(entry.get("type", "omni")) == "spot":
		_add_number_row(entry, "spot_angle", "Spot Angle°", 1.0, 89.0, true)

	var shadow_row := HBoxContainer.new()
	shadow_row.add_child(_make_row_label("Shadows"))
	var shadow_check := CheckBox.new()
	shadow_check.button_pressed = bool(entry.get("shadows", false))
	shadow_check.toggled.connect(func(on: bool) -> void:
		_push_undo()
		entry["shadows"] = on
		_rebuild_entry_node(int(entry["id"]))
	)
	shadow_row.add_child(shadow_check)
	inspector_root.add_child(shadow_row)


func _build_map_inspector() -> void:
	inspector_root.add_child(_make_section_label("MAP SETTINGS"))

	var env := doc.environment

	_add_env_color(env, "background_color", "Background")
	_add_env_color(env, "ambient_color", "Ambient")
	_add_env_number(env, "ambient_energy", "Ambient Energy", 0.0, 16.0)

	inspector_root.add_child(_make_section_label("SUN"))

	var sun_row := HBoxContainer.new()
	sun_row.add_child(_make_row_label("Sun Enabled"))
	var sun_check := CheckBox.new()
	sun_check.button_pressed = bool(env.get("sun_enabled", true))
	sun_check.toggled.connect(func(on: bool) -> void:
		_push_undo("env")
		env["sun_enabled"] = on
		_rebuild_environment()
	)
	sun_row.add_child(sun_check)
	inspector_root.add_child(sun_row)

	_add_env_color(env, "sun_color", "Sun Color")
	_add_env_number(env, "sun_energy", "Sun Energy", 0.0, 16.0)
	_add_sun_angle_row(env, 0, "Sun Pitch°", -89.0, 89.0)
	_add_sun_angle_row(env, 1, "Sun Yaw°", -360.0, 360.0)

	inspector_root.add_child(_make_section_label("EDITOR"))

	var snap_row := HBoxContainer.new()
	snap_row.add_child(_make_row_label("Grid Snap"))
	var snap_check := CheckBox.new()
	snap_check.button_pressed = snap_enabled
	snap_check.toggled.connect(func(on: bool) -> void: snap_enabled = on)
	snap_row.add_child(snap_check)

	var snap_option := OptionButton.new()

	for i in range(SNAP_STEPS.size()):
		snap_option.add_item(str(SNAP_STEPS[i]) + " m", i)

		if absf(float(SNAP_STEPS[i]) - snap_step) < 0.001:
			snap_option.selected = i

	snap_option.item_selected.connect(func(index: int) -> void: snap_step = float(SNAP_STEPS[index]))
	snap_row.add_child(snap_option)
	inspector_root.add_child(snap_row)

	var grid_row := HBoxContainer.new()
	grid_row.add_child(_make_row_label("Show Grid"))
	var grid_check := CheckBox.new()
	grid_check.button_pressed = grid_instance.visible
	grid_check.toggled.connect(func(on: bool) -> void: grid_instance.visible = on)
	grid_row.add_child(grid_check)
	inspector_root.add_child(grid_row)

	inspector_root.add_child(HSeparator.new())
	inspector_root.add_child(_make_section_label("MAP CHECK"))

	var stats := Label.new()
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.add_theme_font_size_override("font_size", 12)
	stats.text = _map_report()
	inspector_root.add_child(stats)


func _map_report() -> String:
	var solids := doc.count_kind(MapDocument.KIND_PRIMITIVE) + doc.count_kind(MapDocument.KIND_MODEL)
	var spawns_a := doc.count_kind(MapDocument.KIND_SPAWN, "team", "a")
	var spawns_b := doc.count_kind(MapDocument.KIND_SPAWN, "team", "b")
	var lights := doc.count_kind(MapDocument.KIND_LIGHT)

	var lines := [
		"Solids: %d   Lights: %d" % [solids, lights],
		"Spawns: %d × Team A, %d × Team B" % [spawns_a, spawns_b],
	]

	if solids == 0:
		lines.append("⚠ No geometry yet — add shapes or import a model.")

	if spawns_a == 0:
		lines.append("⚠ Needs a Team A spawn to playtest.")

	if spawns_b == 0:
		lines.append("⚠ Team B has no spawns (needed for multiplayer team mode).")

	if not bool(doc.environment.get("sun_enabled", true)) and lights == 0 and MapDocument._safe_float(doc.environment.get("ambient_energy"), 0.6) <= 0.01:
		lines.append("⚠ No light sources — the map will render black.")

	return "\n".join(PackedStringArray(lines))


# --- Inspector row helpers -------------------------------------------------------------------

func _make_row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(110.0, 0.0)
	label.add_theme_font_size_override("font_size", 13)
	return label


func _make_spin(value: float, minimum: float, maximum: float, integer := false) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1.0 if integer else 0.01
	spin.value = value
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin


# Three-spin row bound to a [x, y, z] list field on `entry`.
func _add_vec3_rows(entry: Dictionary, key: String, label_text: String, minimum: float, maximum: float, rebuild_mesh: bool) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var current := MapDocument.vec3_from(entry.get(key), Vector3.ZERO)

	for component in range(3):
		var spin := _make_spin(current[component], minimum, maximum)
		spin.value_changed.connect(func(value: float) -> void:
			_push_undo("field_" + key + str(component))
			var list: Array = entry.get(key, [0.0, 0.0, 0.0])
			list[component] = value
			entry[key] = list
			_after_inspector_edit(entry, rebuild_mesh)
		)
		row.add_child(spin)

	inspector_root.add_child(row)


func _add_number_row(entry: Dictionary, key: String, label_text: String, minimum: float, maximum: float, rebuild_mesh: bool, integer := false) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var spin := _make_spin(MapDocument._safe_float(entry.get(key), minimum), minimum, maximum, integer)
	spin.value_changed.connect(func(value: float) -> void:
		_push_undo("field_" + key)
		entry[key] = int(value) if integer else value
		_after_inspector_edit(entry, rebuild_mesh)
	)
	row.add_child(spin)
	inspector_root.add_child(row)


# Number row for a nested dict (e.g. material) that still rebuilds the owning entry.
func _add_number_row_dict(target: Dictionary, key: String, label_text: String, minimum: float, maximum: float, owner_entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var spin := _make_spin(MapDocument._safe_float(target.get(key), minimum), minimum, maximum)
	spin.value_changed.connect(func(value: float) -> void:
		_push_undo("field_" + key)
		target[key] = value
		_after_inspector_edit(owner_entry, true)
	)
	row.add_child(spin)
	inspector_root.add_child(row)


func _add_color_row(target: Dictionary, key: String, label_text: String, owner_entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var picker := ColorPickerButton.new()
	picker.edit_alpha = false
	picker.color = MapDocument.color_from(target.get(key), Color.WHITE)
	picker.custom_minimum_size = Vector2(0.0, 28.0)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color_changed.connect(func(color: Color) -> void:
		_push_undo("color_" + key)
		target[key] = MapDocument.list_from_color(color)
		_after_inspector_edit(owner_entry, true)
	)
	row.add_child(picker)
	inspector_root.add_child(row)


func _add_slider_row(target: Dictionary, key: String, label_text: String, owner_entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = MapDocument._safe_float(target.get(key), 0.5)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(value: float) -> void:
		_push_undo("slider_" + key)
		target[key] = value
		_after_inspector_edit(owner_entry, true)
	)
	row.add_child(slider)
	inspector_root.add_child(row)


func _after_inspector_edit(entry: Dictionary, rebuild_mesh: bool) -> void:
	var id := int(entry.get("id", -1))

	if rebuild_mesh:
		_rebuild_entry_node(id)
	else:
		_apply_entry_transform(id)


func _add_env_color(env: Dictionary, key: String, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var picker := ColorPickerButton.new()
	picker.edit_alpha = false
	picker.color = MapDocument.color_from(env.get(key), Color.WHITE)
	picker.custom_minimum_size = Vector2(0.0, 28.0)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color_changed.connect(func(color: Color) -> void:
		_push_undo("env_" + key)
		env[key] = MapDocument.list_from_color(color)
		_rebuild_environment()
	)
	row.add_child(picker)
	inspector_root.add_child(row)


func _add_env_number(env: Dictionary, key: String, label_text: String, minimum: float, maximum: float) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var spin := _make_spin(MapDocument._safe_float(env.get(key), minimum), minimum, maximum)
	spin.value_changed.connect(func(value: float) -> void:
		_push_undo("env_" + key)
		env[key] = value
		_rebuild_environment()
	)
	row.add_child(spin)
	inspector_root.add_child(row)


func _add_sun_angle_row(env: Dictionary, component: int, label_text: String, minimum: float, maximum: float) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_row_label(label_text))

	var angles: Array = env.get("sun_rotation_degrees", [-42.0, 28.0])
	var spin := _make_spin(MapDocument._safe_float(angles[component], 0.0), minimum, maximum)
	spin.value_changed.connect(func(value: float) -> void:
		_push_undo("env_sun_angle" + str(component))
		var list: Array = env.get("sun_rotation_degrees", [-42.0, 28.0])
		list[component] = value
		env["sun_rotation_degrees"] = list
		_rebuild_environment()
	)
	row.add_child(spin)
	inspector_root.add_child(row)
