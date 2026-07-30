@tool
extends Node3D
class_name MapGenerator

# Map loader. Maps are hand-built .tscn scenes — there is no procedural generation.
# Each map scene supplies its own spawn markers in the groups `spawn_team_a` /
# `spawn_team_b` (and optional gates in `gate_team_a` / `gate_team_b`); NetworkManager
# reads those groups to place players, so a map needs no per-map code here.
#
# To add a map: author the scene with the spawn groups, then register it in the inspector —
# double-click `Resources/Registries/map_registry.tres`, add an element to `maps`, and drag the .tscn into its
# `scene` slot (id/name auto-derive from the filename). No code edit needed. Re-export the
# server afterwards so the new scene is baked into the binary.
#
# Editor preview: set `map_id` (or tick `regenerate`) in the inspector. At runtime it
# loads in _ready from the id chosen on GameLaunch (set by the map-setup menu / lobby).
#
# (Filename/class kept as map_generator/MapGenerator to avoid churning scene references;
# it is now purely a loader.)

# The map list lives in a preloaded resource so it can be edited in the inspector while
# staying export-safe: preloading Resources/Registries/map_registry.tres makes the exporter track it AND its
# PackedScene references as dependencies, so they pack into the dedicated-server build (a
# bare load("res://…") string is not tracked and silently ships missing).
const MAP_REGISTRY := preload("res://Resources/Registries/map_registry.tres")

const DEFAULT_MAP_ID := "diamond"

# Cached Dictionary view of MAP_REGISTRY.maps, in the {"id","name","scene"} shape the rest
# of the code (menus, lobby, smoke tests) already expects. Built once on first access.
static var _entries_cache: Array = []
static var _entries_built: bool = false

# Transient start-menu glTF upload. It is never returned by get_map_ids(), so it cannot be
# selected by multiplayer hosts or sent to a dedicated server.
const UPLOADED_TEST_MAP_ID := "__uploaded_test_map"

@export var map_id: String = DEFAULT_MAP_ID:
	set(value):
		map_id = value
		_rebuild_in_editor()

@export var regenerate: bool = false:
	set(value):
		regenerate = false
		_rebuild_in_editor()

@export var build_on_ready: bool = true


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_apply_launch_overrides()

	if build_on_ready:
		build_map()


# Pulls the player's map-setup-menu / lobby choice in, before building.
func _apply_launch_overrides() -> void:
	if not GameLaunch.map_configured:
		return

	map_id = GameLaunch.map_id


func _rebuild_in_editor() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		build_map()


# Re-read the launch/lobby config and rebuild — used for runtime map changes
# (e.g. when a lobby is created/reconfigured with a different map).
func rebuild_from_launch() -> void:
	_apply_launch_overrides()
	build_map()


func build_map() -> void:
	_clear_generated()

	var container := Node3D.new()
	container.name = "GeneratedMap"
	add_child(container)

	if map_id == UPLOADED_TEST_MAP_ID:
		if _build_uploaded_test_map(container):
			return

		# The transient scene should always be present after the start-menu import. If it
		# was lost, fall back rather than booting into a void.
		push_warning("MapGenerator: uploaded test map unavailable; falling back to '" + DEFAULT_MAP_ID + "'.")
		map_id = DEFAULT_MAP_ID

	var entry := get_map_entry(map_id)

	if entry.is_empty():
		push_warning("MapGenerator: unknown map id '" + map_id + "'.")
		return

	var scene: PackedScene = entry.get("scene")

	if scene == null:
		push_warning("MapGenerator: map '" + map_id + "' has no scene.")
		return

	var instance := scene.instantiate()
	container.add_child(instance)

	print("MapGenerator: loaded ", String(entry.get("name", map_id)), ".")


func _build_uploaded_test_map(container: Node3D) -> bool:
	var built := GameLaunch.consume_uploaded_test_map_scene()

	if built == null:
		return false

	container.add_child(built)
	var report := GameLaunch.uploaded_test_map_report
	print(
		"MapGenerator: loaded test map '",
		GameLaunch.uploaded_test_map_path.get_file(),
		"' (",
		int(report.get("mesh_count", 0)),
		" meshes, ",
		int(report.get("collision_count", 0)),
		" colliders, ",
		int(report.get("spawn_count", 0)),
		" spawns, ",
		int(report.get("light_count", 0)),
		" lights)."
	)

	for warning in report.get("warnings", []):
		push_warning("Uploaded test map: " + String(warning))

	return true


func _clear_generated() -> void:
	var existing := get_node_or_null("GeneratedMap")

	if existing != null:
		existing.free()


# --- Registry lookups ---------------------------------------------------------------

# The registered maps as {"id","name","scene"} dicts, built from Resources/Registries/map_registry.tres.
static func get_map_entries() -> Array:
	if _entries_built:
		return _entries_cache

	_entries_cache = []

	if MAP_REGISTRY != null:
		for listing in MAP_REGISTRY.maps:
			if listing == null or listing.scene == null:
				continue

			_entries_cache.append({
				"id": listing.resolve_id(),
				"name": listing.resolve_name(),
				"scene": listing.scene,
			})

	_entries_built = true
	return _entries_cache


static func get_map_entry(id: String) -> Dictionary:
	for entry in get_map_entries():
		if String(entry.get("id", "")) == id:
			return entry

	return {}


static func has_map(id: String) -> bool:
	if id == UPLOADED_TEST_MAP_ID:
		return GameLaunch.uploaded_test_map_scene != null

	return not get_map_entry(id).is_empty()


static func get_map_ids() -> Array:
	var ids: Array = []

	for entry in get_map_entries():
		ids.append(String(entry.get("id", "")))

	return ids


static func get_map_name(id: String) -> String:
	if id == UPLOADED_TEST_MAP_ID:
		return GameLaunch.uploaded_test_map_path.get_file()

	var entry := get_map_entry(id)
	return String(entry.get("name", id)) if not entry.is_empty() else id


static func normalize_map_id(value: String) -> String:
	var key := value.strip_edges().to_lower().replace(" ", "_").replace("-", "_")

	match key:
		"diamond", "diamond_arena", "arena_diamond":
			return "diamond"
		"sphere", "sphere_arena", "arena_sphere", "ball":
			return "sphere"

	# Already a known id? Pass it through. Otherwise return as-is (build_map warns).
	if has_map(key):
		return key

	return key


# --- Spawn / gate lookups (used to wire NetworkManager / RoundManager) --------------

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
