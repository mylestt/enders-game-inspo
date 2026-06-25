@tool
extends Node3D
class_name MapGenerator

# Procedural 6DOF greybox arena. Builds thick, walkable StaticBody cover in one of
# three styles, plus 5 spawn points per side and a gate at each end. Everything is
# 180°-rotationally symmetric about the arena centre, so the two sides are fair.
#
# Deterministic from `map_seed`: every networked peer that runs this with the same
# seed builds an identical map, so the static collision matches everywhere with no
# replication needed.
#
# Editor preview: tick `regenerate` in the inspector. At runtime it builds in _ready.

enum MapStyle {
	CORE,
	MODULE_STATION,
	ASTEROID_FIELD,
	DESIGNED,
	ARENA_2V2,
}

@export var style: MapStyle = MapStyle.CORE:
	set(value):
		style = value
		_rebuild_in_editor()

@export var map_seed: int = 1:
	set(value):
		map_seed = value
		_rebuild_in_editor()

@export var regenerate: bool = false:
	set(value):
		regenerate = false
		_rebuild_in_editor()

@export var generate_on_ready: bool = true

@export_group("Arena Size")
@export var arena_length: float = 90.0   # gate-to-gate (Z)
@export var arena_width: float = 50.0    # X
@export var arena_height: float = 40.0   # Y
@export var build_boundary: bool = true
@export var boundary_thickness: float = 3.0
@export var add_lighting: bool = true

@export_group("Teams")
@export var spawns_per_side: int = 5
@export var spawn_row_width: float = 18.0
@export var spawn_inset: float = 9.0     # how far spawns sit inward from their gate
@export var gate_opening: float = 9.0
@export var gate_bar_thickness: float = 1.6
@export var gate_inset: float = 6.0      # how far gates sit inward from the end wall

@export_group("Cover Tuning")
@export var core_radius: float = 7.0
@export var core_height: float = 16.0
@export var core_ring_count: int = 8
@export var core_lane_cover: int = 5
@export var module_cluster_count: int = 3
@export var asteroid_count: int = 28

@export_group("Designed Arena")
@export var designed_arena_size: float = 120.0   # cubic; roughly arena3-scale
@export var designed_center_size: float = 22.0
@export var designed_cube_size: float = 7.0
@export var designed_grid_count: int = 5         # cubes per axis (odd = aligned to centre)
@export var designed_margin: float = 8.0

@export_group("Colors")
@export var cover_color: Color = Color(0.82, 0.85, 0.9)
@export var boundary_color: Color = Color(0.5, 0.52, 0.58)
@export var team_a_color: Color = Color(0.3, 0.55, 1.0)
@export var team_b_color: Color = Color(1.0, 0.5, 0.3)

@export_group("Surface Texture")
@export var grid_texture: Texture2D = preload("res://textures/GreyGrid.png")
@export var grid_tiling: float = 0.5

@export_group("Area Lights")
@export var area_light_energy: float = 2.2
@export var area_light_range: float = 55.0

@export_group("Default Arena")
@export var use_default_arena: bool = false
@export var default_arena_transform: Transform3D = Transform3D.IDENTITY
@export var primary_spawn_a_path: NodePath
@export var primary_spawn_b_path: NodePath
@export var default_spawn_a_transform: Transform3D = Transform3D.IDENTITY
@export var default_spawn_b_transform: Transform3D = Transform3D.IDENTITY

@export_group("Manual Arena Scenes")
@export var arena_2v2_scene: PackedScene = preload("res://2v_2.tscn")

var cover_material: StandardMaterial3D
var boundary_material: StandardMaterial3D
var team_a_material: StandardMaterial3D
var team_b_material: StandardMaterial3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_apply_launch_overrides()

	if generate_on_ready:
		build_map()


# Pulls the player's map-setup-menu choices in, before building.
func _apply_launch_overrides() -> void:
	if not GameLaunch.map_configured:
		return

	use_default_arena = GameLaunch.map_use_default_arena
	style = GameLaunch.map_style as MapStyle
	map_seed = GameLaunch.map_seed
	arena_length = GameLaunch.map_length
	arena_width = GameLaunch.map_width
	arena_height = GameLaunch.map_height
	build_boundary = GameLaunch.map_boundary

	var d := maxf(GameLaunch.map_density, 0.1)
	core_ring_count = maxi(int(round(8.0 * d)), 1)
	core_lane_cover = maxi(int(round(5.0 * d)), 0)
	module_cluster_count = maxi(int(round(3.0 * d)), 1)
	asteroid_count = maxi(int(round(28.0 * d)), 1)


func _rebuild_in_editor() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		build_map()


# Re-read the launch/lobby config and rebuild — used for runtime map changes
# (e.g. when a lobby is created/reconfigured with different map settings).
func rebuild_from_launch() -> void:
	_apply_launch_overrides()
	build_map()


func build_map() -> void:
	_clear_generated()

	var container := Node3D.new()
	container.name = "GeneratedMap"
	add_child(container)

	_ensure_materials()

	if use_default_arena:
		_build_default_arena(container)
		_update_primary_spawns()
		print("MapGenerator: loaded Default Arena 3.")
		return

	if style == MapStyle.ARENA_2V2:
		_build_scene_arena(container, arena_2v2_scene, "2v2")
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed

	# The designed arena is a fixed cubic room, so gates/spawns/boundary use that size.
	if style == MapStyle.DESIGNED:
		arena_length = designed_arena_size
		arena_width = designed_arena_size
		arena_height = designed_arena_size

	if add_lighting:
		_build_lighting(container)
		_build_area_lights(container)

	if build_boundary:
		_build_boundary(container)

	match style:
		MapStyle.CORE:
			_build_core(container, rng)
		MapStyle.MODULE_STATION:
			_build_module_station(container, rng)
		MapStyle.ASTEROID_FIELD:
			_build_asteroid_field(container, rng)
		MapStyle.DESIGNED:
			_build_designed(container)

	var gate_a_z := -arena_length * 0.5 + gate_inset
	var gate_b_z := arena_length * 0.5 - gate_inset

	_place_gate(container, "A", gate_a_z, team_a_material)
	_place_gate(container, "B", gate_b_z, team_b_material)

	_place_spawns(container, "A", gate_a_z + spawn_inset, team_a_material)
	_place_spawns(container, "B", gate_b_z - spawn_inset, team_b_material)

	_update_primary_spawns()

	print("MapGenerator: built ", _style_name(style), " (seed ", map_seed, ").")


func _clear_generated() -> void:
	var existing := get_node_or_null("GeneratedMap")

	if existing != null:
		existing.free()


func _ensure_materials() -> void:
	cover_material = _make_grid_material(cover_color)
	boundary_material = _make_grid_material(boundary_color)
	team_a_material = _make_material(team_a_color)
	team_b_material = _make_material(team_b_color)


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	material.metallic = 0.0
	return material


# Greybox material with the GreyGrid texture, world-space triplanar so the grid is a
# consistent size across every box no matter how big it is.
func _make_grid_material(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.9
	material.metallic = 0.0

	if grid_texture == null:
		grid_texture = load("res://textures/GreyGrid.png") as Texture2D

	if grid_texture != null:
		material.albedo_texture = grid_texture
		material.uv1_triplanar = true
		material.uv1_world_triplanar = true
		material.uv1_scale = Vector3(grid_tiling, grid_tiling, grid_tiling)

	return material


func _build_lighting(container: Node) -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.025, 0.04)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.6, 0.65, 0.75)
	environment.ambient_light_energy = 0.7

	var world_environment := WorldEnvironment.new()
	world_environment.name = "GeneratedEnvironment"
	world_environment.environment = environment
	container.add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "GeneratedSun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 1.1
	container.add_child(sun)


# Fill lights spread through the volume so every area (centre, both gate ends, and
# all six directions) is lit — important in 6DOF where any face can be in view.
func _build_area_lights(container: Node) -> void:
	var positions := [
		Vector3.ZERO,
		Vector3(0.0, 0.0, -arena_length * 0.3),
		Vector3(0.0, 0.0, arena_length * 0.3),
		Vector3(arena_width * 0.3, 0.0, 0.0),
		Vector3(-arena_width * 0.3, 0.0, 0.0),
		Vector3(0.0, arena_height * 0.3, 0.0),
		Vector3(0.0, -arena_height * 0.3, 0.0),
	]

	var effective_range := maxf(area_light_range, maxf(arena_length, maxf(arena_width, arena_height)) * 0.6)

	for i in range(positions.size()):
		var omni := OmniLight3D.new()
		omni.name = "AreaLight" + str(i)
		omni.position = positions[i]
		omni.light_energy = area_light_energy
		omni.omni_range = effective_range
		omni.shadow_enabled = false
		container.add_child(omni)


# --- Cover styles ------------------------------------------------------------------

func _build_core(container: Node, rng: RandomNumberGenerator) -> void:
	# Central walkable structure (placed once; it's self-symmetric).
	_add_box(container, Vector3.ZERO, Vector3(core_radius * 2.0, core_height, core_radius * 2.0), Basis(), cover_material, "Core")
	_add_box(container, Vector3.ZERO, Vector3(core_radius * 0.7, core_height * 1.7, core_radius * 0.7), Basis(), cover_material, "CoreSpire")

	# Ring of cover around the core (angles 0..PI; the mirror fills the rest).
	for i in range(core_ring_count):
		var angle := float(i) / float(maxi(core_ring_count, 1)) * PI
		var radius := core_radius + rng.randf_range(6.0, 12.0)
		var y := rng.randf_range(-arena_height * 0.25, arena_height * 0.25)
		var pos := Vector3(cos(angle) * radius, y, sin(angle) * radius)
		var size := _random_box(rng, 3.0, 6.0)
		_place_cover_symmetric(container, pos, size, Basis(Vector3.UP, rng.randf_range(0.0, PI)))

	# Mid-lane cover between core and gates.
	for i in range(core_lane_cover):
		var z := rng.randf_range(arena_length * 0.15, arena_length * 0.4)
		var x := rng.randf_range(-arena_width * 0.35, arena_width * 0.35)
		var y := rng.randf_range(-arena_height * 0.25, arena_height * 0.25)
		_place_cover_symmetric(container, Vector3(x, y, z), _random_box(rng, 3.0, 7.0), Basis(Vector3.UP, rng.randf_range(0.0, PI)))


func _build_module_station(container: Node, rng: RandomNumberGenerator) -> void:
	for c in range(module_cluster_count):
		var cz := rng.randf_range(arena_length * 0.12, arena_length * 0.42)
		var cx := rng.randf_range(-arena_width * 0.3, arena_width * 0.3)
		var cy := rng.randf_range(-arena_height * 0.2, arena_height * 0.2)
		_build_module(container, rng, Vector3(cx, cy, cz), false)

	# Central junction module.
	_build_module(container, rng, Vector3.ZERO, true)


func _build_module(container: Node, rng: RandomNumberGenerator, center: Vector3, central: bool) -> void:
	var pieces := rng.randi_range(3, 5)

	for i in range(pieces):
		var offset := Vector3(rng.randf_range(-5.0, 5.0), rng.randf_range(-5.0, 5.0), rng.randf_range(-5.0, 5.0))
		var size := Vector3(rng.randf_range(4.0, 8.0), rng.randf_range(4.0, 8.0), rng.randf_range(3.0, 5.0))
		var pos := center + offset
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, PI))

		if central:
			_add_box(container, pos, size, basis, cover_material, "Module")
			_add_box(container, Vector3(-pos.x, pos.y, -pos.z), size, Basis(Vector3.UP, PI) * basis, cover_material, "Module")
		else:
			_place_cover_symmetric(container, pos, size, basis)


func _build_asteroid_field(container: Node, rng: RandomNumberGenerator) -> void:
	for i in range(asteroid_count):
		# Bias Z toward the centre so the middle is dense and the gate runs are open.
		var z := pow(rng.randf(), 1.6) * (arena_length * 0.45)
		var x := rng.randf_range(-arena_width * 0.42, arena_width * 0.42)
		var y := rng.randf_range(-arena_height * 0.42, arena_height * 0.42)
		var base := rng.randf_range(2.5, 7.0)
		var size := Vector3(
			base * rng.randf_range(0.7, 1.3),
			base * rng.randf_range(0.7, 1.3),
			base * rng.randf_range(0.7, 1.3)
		)
		var basis := Basis.from_euler(Vector3(
			rng.randf_range(0.0, TAU),
			rng.randf_range(0.0, TAU),
			rng.randf_range(0.0, TAU)
		))
		_place_cover_symmetric(container, Vector3(x, y, z), size, basis)


# Exact, non-random layout: one large centre cube with a uniform 3D lattice of smaller
# cubes around it on every side. Deterministic, clean, and symmetric.
func _build_designed(container: Node) -> void:
	var ext := arena_length * 0.5 - designed_margin
	var n := maxi(designed_grid_count, 2)
	var center_clear := designed_center_size * 0.5 + designed_cube_size
	var gate_lane := gate_opening * 0.5

	_add_box(container, Vector3.ZERO, Vector3.ONE * designed_center_size, Basis(), cover_material, "CenterCube")

	for ix in range(n):
		for iy in range(n):
			for iz in range(n):
				var x := lerpf(-ext, ext, float(ix) / float(n - 1))
				var y := lerpf(-ext, ext, float(iy) / float(n - 1))
				var z := lerpf(-ext, ext, float(iz) / float(n - 1))

				# Skip the centre (the big cube sits there).
				if absf(x) < center_clear and absf(y) < center_clear and absf(z) < center_clear:
					continue

				# Keep the gate-approach lane clear so spawns aren't inside a cube.
				if absf(x) < gate_lane and absf(y) < gate_lane and absf(z) > ext - designed_cube_size:
					continue

				_add_box(container, Vector3(x, y, z), Vector3.ONE * designed_cube_size, Basis(), cover_material, "GridCube")


# --- Gates & spawns ----------------------------------------------------------------

func _place_gate(container: Node, team: String, z: float, material: StandardMaterial3D) -> void:
	var gate := Node3D.new()
	gate.name = "Gate" + team
	container.add_child(gate)
	gate.add_to_group("gate_team_" + team.to_lower())

	var half := gate_opening * 0.5
	var bar := gate_bar_thickness
	var depth := bar * 2.0

	_add_box(gate, Vector3(0.0, half + bar * 0.5, z), Vector3(gate_opening + bar * 2.0, bar, depth), Basis(), material, "Top")
	_add_box(gate, Vector3(0.0, -half - bar * 0.5, z), Vector3(gate_opening + bar * 2.0, bar, depth), Basis(), material, "Bottom")
	_add_box(gate, Vector3(-half - bar * 0.5, 0.0, z), Vector3(bar, gate_opening, depth), Basis(), material, "Left")
	_add_box(gate, Vector3(half + bar * 0.5, 0.0, z), Vector3(bar, gate_opening, depth), Basis(), material, "Right")

	# Pass-through trigger in the opening, for future gate-scoring logic.
	var area := Area3D.new()
	area.name = "PassThrough"
	area.position = Vector3(0.0, 0.0, z)
	gate.add_child(area)

	var area_shape := CollisionShape3D.new()
	var area_box := BoxShape3D.new()
	area_box.size = Vector3(gate_opening, gate_opening, depth)
	area_shape.shape = area_box
	area.add_child(area_shape)


func _place_spawns(container: Node, team: String, z: float, material: StandardMaterial3D) -> void:
	var parent := Node3D.new()
	parent.name = "Spawns" + team
	container.add_child(parent)

	var count := maxi(spawns_per_side, 1)

	for i in range(count):
		var tx := 0.0

		if count > 1:
			tx = lerpf(-spawn_row_width * 0.5, spawn_row_width * 0.5, float(i) / float(count - 1))

		var pos := Vector3(tx, 0.0, z)

		var marker := Marker3D.new()
		marker.name = "Spawn" + team + str(i)
		parent.add_child(marker)
		marker.position = pos
		marker.add_to_group("spawn_team_" + team.to_lower())

		if pos.length() > 0.01:
			marker.look_at(Vector3.ZERO, Vector3.UP)

		var pad := MeshInstance3D.new()
		pad.name = "Pad" + str(i)
		var pad_mesh := BoxMesh.new()
		pad_mesh.size = Vector3(2.4, 0.3, 2.4)
		pad.mesh = pad_mesh
		pad.material_override = material
		pad.position = pos
		parent.add_child(pad)


# --- Boundary & primitives ---------------------------------------------------------

func _build_boundary(container: Node) -> void:
	var w := arena_width
	var h := arena_height
	var l := arena_length
	var t := boundary_thickness

	_add_box(container, Vector3(w * 0.5, 0.0, 0.0), Vector3(t, h, l), Basis(), boundary_material, "WallXPos")
	_add_box(container, Vector3(-w * 0.5, 0.0, 0.0), Vector3(t, h, l), Basis(), boundary_material, "WallXNeg")
	_add_box(container, Vector3(0.0, h * 0.5, 0.0), Vector3(w, t, l), Basis(), boundary_material, "WallYPos")
	_add_box(container, Vector3(0.0, -h * 0.5, 0.0), Vector3(w, t, l), Basis(), boundary_material, "WallYNeg")
	_add_box(container, Vector3(0.0, 0.0, l * 0.5), Vector3(w, h, t), Basis(), boundary_material, "WallZPos")
	_add_box(container, Vector3(0.0, 0.0, -l * 0.5), Vector3(w, h, t), Basis(), boundary_material, "WallZNeg")


func _place_cover_symmetric(container: Node, pos: Vector3, size: Vector3, basis: Basis) -> void:
	_add_box(container, pos, size, basis, cover_material, "Cover")

	# Skip the mirror for near-centre pieces (it would overlap itself).
	if absf(pos.x) < 2.0 and absf(pos.z) < 2.0:
		return

	var mirror_pos := Vector3(-pos.x, pos.y, -pos.z)
	var mirror_basis := Basis(Vector3.UP, PI) * basis
	_add_box(container, mirror_pos, size, mirror_basis, cover_material, "Cover")


func _random_box(rng: RandomNumberGenerator, min_size: float, max_size: float) -> Vector3:
	return Vector3(
		rng.randf_range(min_size, max_size),
		rng.randf_range(min_size, max_size),
		rng.randf_range(min_size, max_size)
	)


func _add_box(parent: Node, center: Vector3, size: Vector3, basis: Basis, material: Material, body_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.transform = Transform3D(basis, center)
	parent.add_child(body)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)

	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	mesh_instance.material_override = material
	body.add_child(mesh_instance)

	return body


# --- Default arena & spawn positioning ---------------------------------------------

func _build_default_arena(container: Node) -> void:
	if add_lighting:
		_build_lighting(container)

	var scene := load("res://scenes/arena3.tscn") as PackedScene

	if scene == null:
		push_warning("MapGenerator: could not load default arena res://scenes/arena3.tscn.")
		return

	var instance := scene.instantiate()
	container.add_child(instance)

	if instance is Node3D:
		(instance as Node3D).transform = default_arena_transform


# Moves the two NetworkManager spawn markers to suit the active map: the generated
# greybox spawns near each gate, or the default arena's original spawn transforms.
func _update_primary_spawns() -> void:
	var marker_a := _get_external_marker(primary_spawn_a_path)
	var marker_b := _get_external_marker(primary_spawn_b_path)

	if use_default_arena:
		if marker_a != null:
			marker_a.global_transform = default_spawn_a_transform

		if marker_b != null:
			marker_b.global_transform = default_spawn_b_transform

		return

	var spawn_z := arena_length * 0.5 - gate_inset - 2.0

	if marker_a != null:
		marker_a.global_transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 0.0, -spawn_z))

	if marker_b != null:
		marker_b.global_transform = Transform3D(Basis(), Vector3(0.0, 0.0, spawn_z))


func _get_external_marker(path: NodePath) -> Node3D:
	if String(path) == "":
		return null

	return get_node_or_null(path) as Node3D


# --- Manual arena scenes -----------------------------------------------------------

func _build_scene_arena(container: Node, scene: PackedScene, label: String) -> void:
	if scene == null:
		push_warning("MapGenerator: could not load " + label + " arena scene.")
		return

	var instance := scene.instantiate()
	container.add_child(instance)
	print("MapGenerator: loaded ", label, " arena scene.")


# --- Lookups for wiring spawns/gates into NetworkManager / RoundManager later -------

func get_spawn_markers(team: String) -> Array:
	if not is_inside_tree():
		return []

	return get_tree().get_nodes_in_group("spawn_team_" + team.to_lower())


func get_gate(team: String) -> Node:
	if not is_inside_tree():
		return null

	var gates := get_tree().get_nodes_in_group("gate_team_" + team.to_lower())

	if gates.is_empty():
		return null

	return gates[0]


func _style_name(value: int) -> String:
	match value:
		MapStyle.CORE:
			return "Core"
		MapStyle.MODULE_STATION:
			return "Module Station"
		MapStyle.ASTEROID_FIELD:
			return "Asteroid Field"
		MapStyle.DESIGNED:
			return "Designed"
		MapStyle.ARENA_2V2:
			return "2v2"

	return "Unknown"
