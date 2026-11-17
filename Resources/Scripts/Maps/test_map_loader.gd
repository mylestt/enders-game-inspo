extends RefCounted
class_name TestMapLoader

# Runtime glTF blockout importer used by the start menu's "Upload Test Map" action.
#
# Authoring conventions (case-insensitive; Blender's .001 suffixes are ignored):
#   spawn / spawn_*             player spawn marker (Team A; -Z is forward)
#   spawn_b / spawn_team_b      optional Team B marker
#   light / light_*             light marker (an Empty becomes an OmniLight3D)
#   no_collision / nocollide_*  visual-only branch
#
# Every other MeshInstance3D receives:
#   MeshInstance3D -> StaticBody3D -> CollisionShape3D (trimesh)
#
# Surfaces with an authored albedo texture keep their material. Solid-color surfaces
# tint the UV-free triplanar grid with their imported base color.

const BLOCKOUT_SHADER := preload("res://Resources/Materials/Shaders/Gameplay/test_map_blockout.gdshader")
const BLOCKOUT_TEXTURE := preload("res://Resources/Textures/Blockout/GreyGrid.png")
const TEST_LIGHT_ENERGY := 16.0
const TEST_LIGHT_MAX_RANGE := 4096.0

const SUPPORTED_EXTENSIONS := ["gltf", "glb"]
const FILE_DIALOG_FILTERS := [
	"*.gltf, *.glb ; glTF 2.0 Maps",
	"*.glb ; Binary glTF (recommended)",
	"*.gltf ; glTF + companion files",
]

# Returns:
# {
#   ok, scene, error, warnings,
#   mesh_count, collision_count, spawn_count, light_count, blockout_material_count
# }
static func load_file(path: String) -> Dictionary:
	var result := _empty_result()
	var extension := path.get_extension().to_lower()

	if not SUPPORTED_EXTENSIONS.has(extension):
		result["error"] = "Choose a .gltf or .glb file."
		return result

	if not FileAccess.file_exists(path):
		result["error"] = "File not found: " + path
		return result

	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state, 0, path.get_base_dir())

	if error != OK:
		result["error"] = "Godot could not read this glTF file (error %d)." % error
		return result

	var generated := document.generate_scene(state)

	if not (generated is Node3D):
		if generated != null:
			generated.free()

		result["error"] = "The glTF did not contain a usable 3D scene."
		return result

	result = prepare_scene(generated as Node3D)

	if bool(result.get("ok", false)):
		result["scene"] = generated

	return result


# Public separately from load_file so the smoke suite can verify generated-map behavior
# without writing a fixture glTF to disk.
static func prepare_scene(scene: Node3D) -> Dictionary:
	var result := _empty_result()

	if scene == null:
		result["error"] = "The generated scene is empty."
		return result

	scene.name = "UploadedTestMap"

	var original_nodes: Array[Node] = []
	_collect_nodes(scene, original_nodes)

	var marker_branch_ids := {}

	# Markers are processed before meshes so their optional Blender viewport geometry never
	# becomes visible/collidable map geometry.
	for node in original_nodes:
		var role := "light" if node is Light3D else _node_role(String(node.name))

		match role:
			"spawn_a", "spawn_b":
				_configure_spawn(node, role == "spawn_b")
				_hide_meshes(node)
				marker_branch_ids[node.get_instance_id()] = true
				result["spawn_count"] = int(result["spawn_count"]) + 1
			"light":
				if _configure_light(node):
					result["light_count"] = int(result["light_count"]) + 1
				_hide_meshes(node)
				marker_branch_ids[node.get_instance_id()] = true
			"no_collision":
				marker_branch_ids[node.get_instance_id()] = true

	var grid_materials: Dictionary[Color, ShaderMaterial] = {}
	for node in original_nodes:
		if not (node is MeshInstance3D):
			continue

		var mesh_instance := node as MeshInstance3D

		if _is_inside_marked_branch(mesh_instance, marker_branch_ids):
			continue

		result["mesh_count"] = int(result["mesh_count"]) + 1

		if _apply_blockout_materials(mesh_instance, grid_materials):
			result["blockout_material_count"] = int(result["blockout_material_count"]) + 1

		if _add_trimesh_collider(mesh_instance):
			result["collision_count"] = int(result["collision_count"]) + 1

	if int(result["spawn_count"]) == 0:
		var fallback_spawn := Marker3D.new()
		fallback_spawn.name = "SpawnFallback"
		fallback_spawn.position = Vector3(0.0, 1.0, 0.0)
		fallback_spawn.add_to_group("spawn_team_a")
		scene.add_child(fallback_spawn)
		result["spawn_count"] = 1
		(result["warnings"] as Array).append(
			"No node named 'spawn' was found; using a fallback spawn at (0, 1, 0)."
		)

	if int(result["light_count"]) == 0 and not _tree_contains_light(scene):
		_add_default_light(scene)
		result["light_count"] = 1
		(result["warnings"] as Array).append(
			"No node named 'light' was found; using the default blockout omni light."
		)

	_add_environment(scene)

	if int(result["mesh_count"]) == 0:
		scene.free()
		result["error"] = "The glTF contains no playable mesh geometry."
		return result

	if int(result["collision_count"]) == 0:
		scene.free()
		result["error"] = "Godot could not generate collision from the glTF meshes."
		return result

	result["ok"] = true
	return result


static func _empty_result() -> Dictionary:
	return {
		"ok": false,
		"scene": null,
		"error": "",
		"warnings": [],
		"mesh_count": 0,
		"collision_count": 0,
		"spawn_count": 0,
		"light_count": 0,
		"blockout_material_count": 0,
	}


static func _collect_nodes(root: Node, out: Array[Node]) -> void:
	out.append(root)

	for child in root.get_children():
		_collect_nodes(child, out)


static func _node_role(raw_name: String) -> String:
	var key := raw_name.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	var dot := key.rfind(".")

	# Blender makes duplicate object names Spawn.001, Spawn.002, etc.
	if dot >= 0 and key.substr(dot + 1).is_valid_int():
		key = key.substr(0, dot)

	if (
		key == "no_collision"
		or key == "nocollision"
		or key == "nocollide"
		or key.begins_with("no_collision_")
		or key.begins_with("nocollide_")
	):
		return "no_collision"

	if key == "spawn_b" or key == "spawn_team_b" or key.begins_with("spawn_b_"):
		return "spawn_b"

	if (
		key == "spawn"
		or key == "player_spawn"
		or key == "spawn_a"
		or key == "spawn_team_a"
		or key.begins_with("spawn_")
	):
		return "spawn_a"

	if (
		key == "light"
		or key == "point_light"
		or key == "omni_light"
		or key == "spot_light"
		or key.begins_with("light_")
		or key.begins_with("point_light_")
		or key.begins_with("omni_light_")
		or key.begins_with("spot_light_")
	):
		return "light"

	return ""


static func _configure_spawn(node: Node, team_b: bool) -> void:
	if node is Node3D:
		node.add_to_group("spawn_team_b" if team_b else "spawn_team_a")


# Returns true when the marker represents a usable light.
static func _configure_light(node: Node) -> bool:
	if node is OmniLight3D:
		var imported_omni := node as OmniLight3D
		imported_omni.omni_range = TEST_LIGHT_MAX_RANGE
		imported_omni.light_energy = TEST_LIGHT_ENERGY
		imported_omni.shadow_enabled = true
		return true

	if not (node is Node3D):
		return false

	# A Blender spot/directional light is retained as the transform marker but disabled;
	# the actual runtime light is always the deterministic OmniLight3D child below.
	if node is Light3D:
		(node as Light3D).light_energy = 0.0

	var omni := OmniLight3D.new()
	omni.name = "GeneratedLight"
	omni.light_color = Color(1.0, 0.96, 0.88)
	omni.light_energy = TEST_LIGHT_ENERGY
	omni.omni_range = TEST_LIGHT_MAX_RANGE
	omni.shadow_enabled = true
	node.add_child(omni)
	return true


static func _hide_meshes(root: Node) -> void:
	if root is MeshInstance3D:
		(root as MeshInstance3D).visible = false

	for child in root.get_children():
		_hide_meshes(child)


static func _is_inside_marked_branch(node: Node, marked_ids: Dictionary) -> bool:
	var current: Node = node

	while current != null:
		if marked_ids.has(current.get_instance_id()):
			return true

		current = current.get_parent()

	return false


static func _apply_blockout_materials(
	instance: MeshInstance3D, grid_materials: Dictionary[Color, ShaderMaterial]
) -> bool:
	if instance.mesh == null:
		return false

	# A whole-object override takes precedence over every surface slot.
	if instance.material_override != null:
		var grid := _grid_for_material(instance.material_override, grid_materials)
		if grid == null:
			return false
		instance.material_override = grid
		return true

	var changed := false
	for surface in range(instance.mesh.get_surface_count()):
		var grid := _grid_for_material(instance.get_active_material(surface), grid_materials)
		if grid != null:
			instance.set_surface_override_material(surface, grid)
			changed = true

	return changed


static func _grid_for_material(
	material: Material, grid_materials: Dictionary[Color, ShaderMaterial]
) -> ShaderMaterial:
	var tint := Color.WHITE
	if material != null:
		var base := material as BaseMaterial3D
		if base == null or base.albedo_texture != null:
			return null
		tint = base.albedo_color

	if not grid_materials.has(tint):
		var grid := ShaderMaterial.new()
		grid.shader = BLOCKOUT_SHADER
		grid.set_shader_parameter("blockout_texture", BLOCKOUT_TEXTURE)
		grid.set_shader_parameter("tint", tint)
		grid_materials[tint] = grid

	return grid_materials[tint]


static func _add_trimesh_collider(instance: MeshInstance3D) -> bool:
	if instance.mesh == null or instance.mesh.get_surface_count() == 0:
		return false

	for child in instance.get_children():
		if child is StaticBody3D:
			return true

	var shape := instance.mesh.create_trimesh_shape()

	if shape == null or shape.get_faces().is_empty():
		return false

	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	body.add_child(collision)
	instance.add_child(body)
	return true


static func _tree_contains_light(root: Node) -> bool:
	if root is Light3D:
		return true

	for child in root.get_children():
		if _tree_contains_light(child):
			return true

	return false


static func _add_default_light(root: Node3D) -> void:
	var omni := OmniLight3D.new()
	omni.name = "TestMapLight"
	omni.position = Vector3(0.0, 10.0, 0.0)
	omni.light_color = Color(1.0, 0.96, 0.9)
	omni.light_energy = TEST_LIGHT_ENERGY
	omni.omni_range = TEST_LIGHT_MAX_RANGE
	omni.shadow_enabled = true
	root.add_child(omni)


static func _add_environment(root: Node3D) -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "TestMapEnvironment"

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.025, 0.035, 0.055)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.62, 0.72)
	environment.ambient_light_energy = 0.55
	world_environment.environment = environment
	root.add_child(world_environment)
