@tool
extends Node3D
class_name MapGenerator

# Map loader. Maps are hand-built .tscn scenes — there is no procedural generation.
# Each map scene supplies its own spawn markers in the groups `spawn_team_a` /
# `spawn_team_b` (and optional gates in `gate_team_a` / `gate_team_b`); NetworkManager
# reads those groups to place players, so a map needs no per-map code here.
#
# To add a map: author the scene with the spawn groups, then add one line to MAPS.
#
# Editor preview: set `map_id` (or tick `regenerate`) in the inspector. At runtime it
# loads in _ready from the id chosen on GameLaunch (set by the map-setup menu / lobby).
#
# (Filename/class kept as map_generator/MapGenerator to avoid churning scene references;
# it is now purely a loader.)

# Scenes are preloaded so the exporter packs them (a bare load("res://…") string is not
# tracked as a dependency and silently ships missing on a dedicated-server export).
const MAP_DIAMOND := preload("res://DiamondArena.tscn")

# The available maps. Add an entry here to register a new arena scene.
const MAPS := [
	{"id": "diamond", "name": "Diamond Arena", "scene": MAP_DIAMOND},
]

const DEFAULT_MAP_ID := "diamond"

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


func _clear_generated() -> void:
	var existing := get_node_or_null("GeneratedMap")

	if existing != null:
		existing.free()


# --- Registry lookups ---------------------------------------------------------------

static func get_map_entry(id: String) -> Dictionary:
	for entry in MAPS:
		if String(entry.get("id", "")) == id:
			return entry

	return {}


static func has_map(id: String) -> bool:
	return not get_map_entry(id).is_empty()


static func get_map_ids() -> Array:
	var ids: Array = []

	for entry in MAPS:
		ids.append(String(entry.get("id", "")))

	return ids


static func get_map_name(id: String) -> String:
	var entry := get_map_entry(id)
	return String(entry.get("name", id)) if not entry.is_empty() else id


static func normalize_map_id(value: String) -> String:
	var key := value.strip_edges().to_lower().replace(" ", "_").replace("-", "_")

	match key:
		"diamond", "diamond_arena", "arena_diamond":
			return "diamond"

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
