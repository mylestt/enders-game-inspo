@tool
class_name CylindricalForceField
extends Area3D

# Cylindrical repulsor volume: pushes rigid bodies laterally AWAY from the node's local
# Y axis (the cylinder axis). Three nested radii shape the radial force profile:
#
#   start_radius  GREEN gizmo   force starts here — zero at this ring and everywhere inside
#   full_radius   YELLOW gizmo  force peaks here at force_strength
#   end_radius    RED gizmo     force has faded back to zero
#
# Between the rings the force blends: blend_in_falloff / blend_out_falloff are exponents
# on each 0→1 ramp (1 = linear; >1 hugs the zero end so the onset is gentler; <1 reaches
# full force sooner). The volume is `height` metres tall, centred on the node origin —
# no force outside that band. All sizing is properties; do NOT scale the node (same rule
# as spawn markers — scale leaks into physics math).
#
# The wireframe gizmo (three colored cylinders) is generated procedurally in _ready —
# in-editor via @tool and at runtime — and is never saved into the scene. `gizmo_visible`
# hides it (players see it otherwise; handy while tuning, toggle off to ship it invisible).
#
# Multiplayer: forces are applied every physics tick to overlapping NON-frozen
# RigidBody3Ds only. Remote player replicas are frozen (player.set_multiplayer_player
# sets freeze = not is_local_player), so each machine pushes exactly the bodies it
# simulates — the field never fights the transform relay. Purely local physics:
# no @rpc methods, so NET_PROTOCOL_VERSION is untouched.

const RING_SEGMENTS := 48
const VERTICAL_LINES := 8
const COLOR_START := Color(0.2, 1.0, 0.25)
const COLOR_FULL := Color(1.0, 0.85, 0.1)
const COLOR_END := Color(1.0, 0.2, 0.15)

## Master switch for the physics push (the gizmo still draws).
@export var active: bool = true

## Peak outward force in newtons, reached at full_radius. Reference: booster thrust is
## 7.5 N on the 1 kg player body, so ~10 is a hazard you fight, not a wall.
@export_range(0.0, 200.0, 0.1, "or_greater") var force_strength: float = 10.0

## Cylinder height, centred on the node origin along local Y.
@export_range(0.1, 400.0, 0.05, "or_greater", "suffix:m") var height: float = 10.0:
	set(value):
		height = maxf(0.1, value)
		_refresh()

## Inner (green) ring: the force is zero here and everywhere inside.
@export_range(0.0, 400.0, 0.05, "or_greater", "suffix:m") var start_radius: float = 2.0:
	set(value):
		start_radius = maxf(0.0, value)
		_refresh()

## Middle (yellow) ring: the force peaks here.
@export_range(0.0, 400.0, 0.05, "or_greater", "suffix:m") var full_radius: float = 4.0:
	set(value):
		full_radius = maxf(0.0, value)
		_refresh()

## Outer (red) ring: the force has faded to zero here; nothing beyond it.
@export_range(0.0, 400.0, 0.05, "or_greater", "suffix:m") var end_radius: float = 6.0:
	set(value):
		end_radius = maxf(0.0, value)
		_refresh()

## Ramp exponent from start_radius to full_radius (1 = linear).
@export_range(0.05, 10.0, 0.05) var blend_in_falloff: float = 1.0

## Ramp exponent from full_radius back down to end_radius (1 = linear).
@export_range(0.05, 10.0, 0.05) var blend_out_falloff: float = 1.0

## Shows/hides the green/yellow/red wireframe cylinders (editor AND in-game).
@export var gizmo_visible: bool = true:
	set(value):
		gizmo_visible = value

		if _gizmo_mesh != null:
			_gizmo_mesh.visible = value

var _collision_shape: CollisionShape3D = null
var _cylinder_shape: CylinderShape3D = null
var _gizmo_mesh: MeshInstance3D = null


func _init() -> void:
	# Nothing needs to detect the field itself, and it must never swallow camera picking.
	monitorable = false
	input_ray_pickable = false


func _ready() -> void:
	_ensure_children()
	_refresh()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not active:
		return

	for body in get_overlapping_bodies():
		var rigid := body as RigidBody3D

		# Frozen bodies ignore forces anyway — and remote player replicas are frozen,
		# which is exactly the machines-simulate-their-own-bodies split we want.
		if rigid == null or rigid.freeze:
			continue

		var force := get_force_for_global_position(rigid.global_position)

		if force == Vector3.ZERO:
			continue

		if rigid.sleeping:
			rigid.sleeping = false

		rigid.apply_central_force(force)


# --- Force profile (pure math — smoke-tested directly) -------------------------------


## Force multiplier (0..1) at a lateral distance from the cylinder axis.
func get_force_weight(radial_distance: float) -> float:
	if radial_distance < start_radius or radial_distance > end_radius:
		return 0.0

	if radial_distance <= full_radius:
		var in_span := full_radius - start_radius

		# Degenerate blend-in (start == full): instant full force at the ring.
		if in_span <= 0.0001:
			return 1.0

		return pow(clampf((radial_distance - start_radius) / in_span, 0.0, 1.0), blend_in_falloff)

	var out_span := end_radius - full_radius

	# Degenerate blend-out (full == end): full force right up to the hard edge.
	if out_span <= 0.0001:
		return 1.0

	return pow(clampf((end_radius - radial_distance) / out_span, 0.0, 1.0), blend_out_falloff)


## World-space force the field exerts on a body at a world-space position.
func get_force_for_global_position(world_position: Vector3) -> Vector3:
	var local := to_local(world_position)

	if absf(local.y) > height * 0.5:
		return Vector3.ZERO

	var radial := Vector3(local.x, 0.0, local.z)
	var distance := radial.length()

	# On the axis the outward direction is undefined — no push.
	if distance < 0.001:
		return Vector3.ZERO

	var weight := get_force_weight(distance)

	if weight <= 0.0:
		return Vector3.ZERO

	var outward := (global_basis * (radial / distance)).normalized()
	return outward * force_strength * weight


# --- Generated children (collider + gizmo; never owned, never saved) ------------------


func _ensure_children() -> void:
	if _collision_shape != null:
		return

	_cylinder_shape = CylinderShape3D.new()
	_collision_shape = CollisionShape3D.new()
	_collision_shape.shape = _cylinder_shape
	add_child(_collision_shape, false, Node.INTERNAL_MODE_BACK)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true

	_gizmo_mesh = MeshInstance3D.new()
	_gizmo_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_gizmo_mesh.material_override = material
	add_child(_gizmo_mesh, false, Node.INTERNAL_MODE_BACK)


func _refresh() -> void:
	if _cylinder_shape == null:
		return

	# The overlap volume is the outermost cylinder; the profile math trims the rest.
	_cylinder_shape.height = height
	_cylinder_shape.radius = maxf(end_radius, 0.01)
	_rebuild_gizmo()


func _rebuild_gizmo() -> void:
	if _gizmo_mesh == null:
		return

	var vertices := PackedVector3Array()
	var colors := PackedColorArray()

	_append_wire_cylinder(vertices, colors, start_radius, COLOR_START)
	_append_wire_cylinder(vertices, colors, full_radius, COLOR_FULL)
	_append_wire_cylinder(vertices, colors, end_radius, COLOR_END)

	var mesh := ArrayMesh.new()

	if vertices.size() >= 2:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	_gizmo_mesh.mesh = mesh
	_gizmo_mesh.visible = gizmo_visible


func _append_wire_cylinder(vertices: PackedVector3Array, colors: PackedColorArray, radius: float, color: Color) -> void:
	if radius <= 0.001:
		return

	var half := height * 0.5

	# Top and bottom rings.
	for i in RING_SEGMENTS:
		var a0 := TAU * float(i) / float(RING_SEGMENTS)
		var a1 := TAU * float(i + 1) / float(RING_SEGMENTS)
		var x0 := cos(a0) * radius
		var z0 := sin(a0) * radius
		var x1 := cos(a1) * radius
		var z1 := sin(a1) * radius

		vertices.append(Vector3(x0, half, z0))
		vertices.append(Vector3(x1, half, z1))
		vertices.append(Vector3(x0, -half, z0))
		vertices.append(Vector3(x1, -half, z1))

		for _c in 4:
			colors.append(color)

	# Vertical connectors.
	var step := RING_SEGMENTS / VERTICAL_LINES

	for i in VERTICAL_LINES:
		var a := TAU * float(i * step) / float(RING_SEGMENTS)
		var x := cos(a) * radius
		var z := sin(a) * radius

		vertices.append(Vector3(x, half, z))
		vertices.append(Vector3(x, -half, z))
		colors.append(color)
		colors.append(color)
