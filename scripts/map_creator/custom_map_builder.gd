extends RefCounted
class_name CustomMapBuilder

# Turns a MapDocument into a live node tree. Used by BOTH the map creator (edit_mode =
# true: adds selection proxies for spawns/lights, tags every entry root with
# "map_object_id" metadata for picking) and the game at runtime (edit_mode = false:
# real SpawnPoints that join the spawn_team_a/b groups NetworkManager reads).
#
# Collision follows the same structure as the hand-built arenas (MeshInstance3D →
# StaticBody3D → CollisionShape3D). Shapes are trimesh (ConcavePolygonShape3D) for
# imported models and any curved-bevel/ramp/cone/torus geometry; UNMODIFIED box /
# sphere / cylinder / capsule primitives use their exact analytic shapes instead
# because surface-walk needs smooth analytic normals on curved surfaces (see CLAUDE.md:
# primitive colliders for curves, not trimesh).
#
# Dimensions are baked into meshes/shapes — object nodes always have unit scale (only
# imported models may scale) so a spawn or wall can never leak scale into player math.

const SPAWN_POINT_SCENE := preload("res://scenes/spawn_point.tscn")

const TEAM_A_COLOR := Color(0.35, 0.6, 1.0)
const TEAM_B_COLOR := Color(1.0, 0.55, 0.3)


# model_cache: pass a Dictionary you own to reuse loaded model files across rebuilds
# (the editor does); free it with free_model_cache(). Pass null for a self-contained
# one-shot build (runtime map load).
static func build_map_node(doc: MapDocument, edit_mode: bool, model_cache = null) -> Node3D:
	var cache: Dictionary = model_cache if model_cache is Dictionary else {}

	var root := Node3D.new()
	root.name = "CustomMap"

	if edit_mode:
		# Editor drags transforms at render-frame rate; interpolation would judder them.
		root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	_add_environment(root, doc.environment)

	var objects_parent := Node3D.new()
	objects_parent.name = "Objects"
	root.add_child(objects_parent)

	for entry in doc.objects:
		if not (entry is Dictionary):
			continue

		var node := build_entry_node(entry, doc.slug, edit_mode, cache)

		if node != null:
			objects_parent.add_child(node)

	if model_cache == null:
		free_model_cache(cache)

	return root


static func free_model_cache(cache: Dictionary) -> void:
	for key in cache:
		var node: Variant = cache[key]

		if node is Node and is_instance_valid(node):
			node.free()

	cache.clear()


# --- Environment ---------------------------------------------------------------------------

static func _add_environment(root: Node3D, env: Dictionary) -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "MapEnvironment"

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = MapDocument.color_from(env.get("background_color"), Color(0.02, 0.03, 0.05))
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = MapDocument.color_from(env.get("ambient_color"), Color(0.55, 0.6, 0.7))
	environment.ambient_light_energy = MapDocument._safe_float(env.get("ambient_energy"), 0.6)
	world_environment.environment = environment
	root.add_child(world_environment)

	if bool(env.get("sun_enabled", true)):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.light_color = MapDocument.color_from(env.get("sun_color"), Color(1.0, 0.97, 0.9))
		sun.light_energy = MapDocument._safe_float(env.get("sun_energy"), 1.2)
		sun.shadow_enabled = bool(env.get("sun_shadows", true))

		var angles: Variant = env.get("sun_rotation_degrees")

		if angles is Array and angles.size() == 2:
			sun.rotation_degrees = Vector3(
				MapDocument._safe_float(angles[0], -42.0),
				MapDocument._safe_float(angles[1], 28.0),
				0.0
			)
		else:
			sun.rotation_degrees = Vector3(-42.0, 28.0, 0.0)

		root.add_child(sun)


# --- Entries ---------------------------------------------------------------------------------

static func build_entry_node(entry: Dictionary, map_slug: String, edit_mode: bool, cache: Dictionary) -> Node3D:
	var node: Node3D = null

	match String(entry.get("kind", "")):
		MapDocument.KIND_PRIMITIVE:
			node = _build_primitive(entry)
		MapDocument.KIND_MODEL:
			node = _build_model(entry, map_slug, cache)
		MapDocument.KIND_SPAWN:
			node = _build_spawn(entry, edit_mode)
		MapDocument.KIND_LIGHT:
			node = _build_light(entry, edit_mode)

	if node == null:
		return null

	var id := int(entry.get("id", 0))
	node.name = "Entry_%d" % id
	node.set_meta("map_object_id", id)
	node.position = MapDocument.vec3_from(entry.get("position"))
	node.rotation_degrees = MapDocument.vec3_from(entry.get("rotation_degrees"))
	return node


static func _build_primitive(entry: Dictionary) -> Node3D:
	var root := Node3D.new()
	var mesh := build_primitive_mesh(entry)

	if mesh == null:
		return root

	var instance := MeshInstance3D.new()
	instance.name = "Mesh"
	instance.mesh = mesh
	instance.material_override = _material_from(entry.get("material"))
	root.add_child(instance)

	var shape := build_primitive_collider(entry, mesh)

	if shape != null:
		var body := StaticBody3D.new()
		body.name = "StaticBody3D"
		var collision := CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		collision.shape = shape
		body.add_child(collision)
		instance.add_child(body)

	return root


static func build_primitive_mesh(entry: Dictionary) -> Mesh:
	var shape := String(entry.get("shape", "box"))
	var bevel := MapDocument._safe_float(entry.get("bevel_radius"), 0.0)
	var bevel_segments := MapDocument._safe_int(entry.get("bevel_segments"), 3)

	match shape:
		"box":
			var size := MapDocument.vec3_from(entry.get("size"), Vector3(2, 2, 2))

			if bevel > 0.0005:
				return BevelMesh.build_rounded_box(size, bevel, bevel_segments)

			var box := BoxMesh.new()
			box.size = size
			return box
		"ramp":
			var prism := PrismMesh.new()
			prism.size = MapDocument.vec3_from(entry.get("size"), Vector3(3, 2, 4))
			prism.left_to_right = 0.0
			return prism
		"sphere":
			var radius := MapDocument._safe_float(entry.get("radius"), 1.5)
			var sphere := SphereMesh.new()
			sphere.radius = radius
			sphere.height = radius * 2.0
			sphere.radial_segments = 48
			sphere.rings = 24
			return sphere
		"cylinder":
			var radius := MapDocument._safe_float(entry.get("radius"), 1.0)
			var height := MapDocument._safe_float(entry.get("height"), 3.0)

			if bevel > 0.0005:
				return BevelMesh.build_beveled_cylinder(radius, height, bevel, bevel_segments)

			var cylinder := CylinderMesh.new()
			cylinder.top_radius = radius
			cylinder.bottom_radius = radius
			cylinder.height = height
			cylinder.radial_segments = 32
			return cylinder
		"cone":
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = MapDocument._safe_float(entry.get("radius"), 1.2)
			cone.height = MapDocument._safe_float(entry.get("height"), 2.5)
			cone.radial_segments = 32
			return cone
		"capsule":
			var radius := MapDocument._safe_float(entry.get("radius"), 0.8)
			var capsule := CapsuleMesh.new()
			capsule.radius = radius
			capsule.height = maxf(MapDocument._safe_float(entry.get("height"), 3.0), radius * 2.0)
			return capsule
		"torus":
			var ring_radius := MapDocument._safe_float(entry.get("radius"), 2.0)
			var tube := MapDocument._safe_float(entry.get("thickness"), 0.6) * 0.5
			var torus := TorusMesh.new()
			torus.inner_radius = maxf(ring_radius - tube, 0.01)
			torus.outer_radius = ring_radius + tube
			torus.rings = 48
			torus.ring_segments = 24
			return torus

	return null


# Analytic shapes for exact primitives (smooth normals for surface-walk on curves);
# trimesh for everything tessellated.
static func build_primitive_collider(entry: Dictionary, mesh: Mesh) -> Shape3D:
	var shape := String(entry.get("shape", "box"))
	var bevel := MapDocument._safe_float(entry.get("bevel_radius"), 0.0)

	match shape:
		"box":
			if bevel <= 0.0005:
				var box := BoxShape3D.new()
				box.size = MapDocument.vec3_from(entry.get("size"), Vector3(2, 2, 2))
				return box
		"sphere":
			var sphere := SphereShape3D.new()
			sphere.radius = MapDocument._safe_float(entry.get("radius"), 1.5)
			return sphere
		"cylinder":
			if bevel <= 0.0005:
				var cylinder := CylinderShape3D.new()
				cylinder.radius = MapDocument._safe_float(entry.get("radius"), 1.0)
				cylinder.height = MapDocument._safe_float(entry.get("height"), 3.0)
				return cylinder
		"capsule":
			var capsule := CapsuleShape3D.new()
			capsule.radius = MapDocument._safe_float(entry.get("radius"), 0.8)
			capsule.height = maxf(MapDocument._safe_float(entry.get("height"), 3.0), capsule.radius * 2.0)
			return capsule

	return _trimesh_from(mesh)


static func _trimesh_from(mesh: Mesh) -> Shape3D:
	if mesh == null or mesh.get_surface_count() == 0:
		return null

	var trimesh := mesh.create_trimesh_shape()

	if trimesh == null or trimesh.get_faces().is_empty():
		return null

	return trimesh


static func _material_from(raw: Variant) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var data: Dictionary = raw if raw is Dictionary else MapDocument.default_material()

	material.albedo_color = MapDocument.color_from(data.get("color"), Color(0.62, 0.66, 0.72))
	material.metallic = clampf(MapDocument._safe_float(data.get("metallic"), 0.1), 0.0, 1.0)
	material.roughness = clampf(MapDocument._safe_float(data.get("roughness"), 0.7), 0.0, 1.0)

	var emission_energy := MapDocument._safe_float(data.get("emission_energy"), 0.0)

	if emission_energy > 0.001:
		material.emission_enabled = true
		material.emission = MapDocument.color_from(data.get("emission"), Color.BLACK)
		material.emission_energy_multiplier = emission_energy

	return material


# --- Imported models --------------------------------------------------------------------------

static func _build_model(entry: Dictionary, map_slug: String, cache: Dictionary) -> Node3D:
	var root := Node3D.new()
	var relative := String(entry.get("source", ""))
	var path := MapDocument.map_dir(map_slug) + "/" + relative
	var source: Node3D = null

	if cache.has(path):
		source = cache[path]
	else:
		source = MapModelImporter.load_model_scene(path)
		cache[path] = source

	if source == null:
		# Missing/broken asset: leave a visible placeholder instead of silently nothing.
		var placeholder := MeshInstance3D.new()
		placeholder.name = "MissingAsset"
		var box := BoxMesh.new()
		box.size = Vector3.ONE
		placeholder.mesh = box
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 0.1, 0.6)
		placeholder.material_override = material
		root.add_child(placeholder)
		push_warning("CustomMapBuilder: missing model asset '" + relative + "'.")
		return root

	var instance := source.duplicate() as Node3D
	instance.name = "Model"
	root.add_child(instance)
	root.scale = MapDocument.vec3_from(entry.get("scale"), Vector3.ONE)

	add_trimesh_colliders(instance)
	return root


# Gives every MeshInstance3D under `root` a StaticBody3D + trimesh CollisionShape3D child
# (the same structure the hand-built arenas use), so imported geometry is instantly solid.
static func add_trimesh_colliders(root: Node) -> int:
	var added := 0
	var pending: Array = [root]

	while not pending.is_empty():
		var node: Node = pending.pop_back()

		for child in node.get_children():
			pending.append(child)

		if node is MeshInstance3D:
			var instance := node as MeshInstance3D
			var shape := _trimesh_from(instance.mesh)

			if shape == null:
				continue

			var body := StaticBody3D.new()
			body.name = "StaticBody3D"
			var collision := CollisionShape3D.new()
			collision.name = "CollisionShape3D"
			collision.shape = shape
			body.add_child(collision)
			instance.add_child(body)
			added += 1

	return added


# --- Spawns ------------------------------------------------------------------------------------

static func _build_spawn(entry: Dictionary, edit_mode: bool) -> Node3D:
	var team := String(entry.get("team", "a"))

	if not edit_mode:
		# The real thing: joins spawn_team_a/b in _ready, exactly like hand-built maps.
		var spawn := SPAWN_POINT_SCENE.instantiate()
		spawn.set("team", SpawnPoint.Team.B if team == "b" else SpawnPoint.Team.A)
		spawn.set("show_in_game", false)
		return spawn

	# Edit mode: an inert, clickable stand-in (never joins spawn groups while editing).
	var root := Node3D.new()
	var color := TEAM_B_COLOR if team == "b" else TEAM_A_COLOR

	var capsule := MeshInstance3D.new()
	capsule.name = "Capsule"
	var capsule_mesh := CapsuleMesh.new()
	capsule_mesh.radius = 0.5
	capsule_mesh.height = 2.0
	capsule.mesh = capsule_mesh
	capsule.material_override = _ghost_material(color, 0.45)
	root.add_child(capsule)

	var nub := MeshInstance3D.new()
	nub.name = "FacingNub"
	var nub_mesh := BoxMesh.new()
	nub_mesh.size = Vector3(0.12, 0.12, 0.4)
	nub.mesh = nub_mesh
	nub.position = Vector3(0.0, 0.2, -0.75)
	nub.material_override = _ghost_material(color, 1.0)
	root.add_child(nub)

	var body := StaticBody3D.new()
	body.name = "PickBody"
	var collision := CollisionShape3D.new()
	var capsule_shape := CapsuleShape3D.new()
	capsule_shape.radius = 0.5
	capsule_shape.height = 2.0
	collision.shape = capsule_shape
	body.add_child(collision)
	root.add_child(body)

	return root


# --- Lights -------------------------------------------------------------------------------------

static func _build_light(entry: Dictionary, edit_mode: bool) -> Node3D:
	var root := Node3D.new()
	var color := MapDocument.color_from(entry.get("color"), Color(1.0, 0.98, 0.92))
	var energy := MapDocument._safe_float(entry.get("energy"), 4.0)
	var light_range := MapDocument._safe_float(entry.get("range"), 18.0)
	var shadows: bool = bool(entry.get("shadows", false))

	if String(entry.get("type", "omni")) == "spot":
		var spot := SpotLight3D.new()
		spot.name = "Light"
		spot.light_color = color
		spot.light_energy = energy
		spot.spot_range = light_range
		spot.spot_angle = clampf(MapDocument._safe_float(entry.get("spot_angle"), 45.0), 1.0, 89.0)
		spot.shadow_enabled = shadows
		root.add_child(spot)
	else:
		var omni := OmniLight3D.new()
		omni.name = "Light"
		omni.light_color = color
		omni.light_energy = energy
		omni.omni_range = light_range
		omni.shadow_enabled = shadows
		root.add_child(omni)

	if edit_mode:
		var bulb := MeshInstance3D.new()
		bulb.name = "Bulb"
		var bulb_mesh := SphereMesh.new()
		bulb_mesh.radius = 0.22
		bulb_mesh.height = 0.44
		bulb.mesh = bulb_mesh
		bulb.material_override = _ghost_material(color, 1.0)
		root.add_child(bulb)

		if String(entry.get("type", "omni")) == "spot":
			var direction := MeshInstance3D.new()
			direction.name = "SpotDirection"
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.14
			cone.height = 0.5
			direction.mesh = cone
			# CylinderMesh points +Y; aim it down the light's -Z.
			direction.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
			direction.position = Vector3(0.0, 0.0, -0.5)
			direction.material_override = _ghost_material(color, 0.8)
			root.add_child(direction)

		var body := StaticBody3D.new()
		body.name = "PickBody"
		var collision := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.35
		collision.shape = sphere
		body.add_child(collision)
		root.add_child(body)

	return root


static func _ghost_material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	if alpha < 0.999:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(color.r, color.g, color.b, alpha)
	else:
		material.albedo_color = color

	return material
