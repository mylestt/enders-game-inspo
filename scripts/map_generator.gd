@tool
extends Node3D
class_name MapGenerator

# Map loader. Maps are hand-built .tscn scenes — there is no procedural generation.
# Each map scene supplies its own spawn markers in the groups `spawn_team_a` /
# `spawn_team_b` (and optional gates in `gate_team_a` / `gate_team_b`); NetworkManager
# reads those groups to place players, so a map needs no per-map code here.
#
# To add a map: author the scene with the spawn groups, then register it in the inspector —
# double-click `map_registry.tres`, add an element to `maps`, and drag the .tscn into its
# `scene` slot (id/name auto-derive from the filename). No code edit needed. Re-export the
# server afterwards so the new scene is baked into the binary.
#
# Editor preview: set `map_id` (or tick `regenerate`) in the inspector. At runtime it
# loads in _ready from the id chosen on GameLaunch (set by the map-setup menu / lobby).
#
# (Filename/class kept as map_generator/MapGenerator to avoid churning scene references;
# it is now purely a loader.)

# The map list lives in a preloaded resource so it can be edited in the inspector while
# staying export-safe: preloading map_registry.tres makes the exporter track it AND its
# PackedScene references as dependencies, so they pack into the dedicated-server build (a
# bare load("res://…") string is not tracked and silently ships missing).
const MAP_REGISTRY := preload("res://map_registry.tres")

const DEFAULT_MAP_ID := "diamond"

# Cached Dictionary view of MAP_REGISTRY.maps, in the {"id","name","scene"} shape the rest
# of the code (menus, lobby, smoke tests) already expects. Built once on first access.
static var _entries_cache: Array = []
static var _entries_built: bool = false

# Player-made maps from the in-game map creator: id = "custom:<slug>", built at runtime
# from user://custom_maps/<slug>/ by CustomMapBuilder (data-only JSON — see MapDocument).
# They are LOCAL files: has_map() is true only where the file exists, so a server that
# receives a custom id it doesn't have falls back safely (lobby flow already routes
# unknown ids through GameLaunch.map_id). Custom maps are offered for offline Test
# Arena / map-creator playtests, not for online lobbies.
const CUSTOM_MAP_PREFIX := "custom:"

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

	if is_custom_map_id(map_id):
		if _build_custom_map(container):
			return

		# Missing/corrupt custom map (or a server that doesn't have the file): fall back
		# to the default arena rather than booting into a void.
		push_warning("MapGenerator: custom map '" + map_id + "' unavailable — falling back to '" + DEFAULT_MAP_ID + "'.")
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


func _build_custom_map(container: Node3D) -> bool:
	var doc := MapDocument.load_map(custom_map_slug(map_id))

	if doc == null:
		return false

	var built := CustomMapBuilder.build_map_node(doc, false)
	container.add_child(built)
	print("MapGenerator: built custom map '", doc.map_name, "'.")
	return true


func _clear_generated() -> void:
	var existing := get_node_or_null("GeneratedMap")

	if existing != null:
		existing.free()


# --- Registry lookups ---------------------------------------------------------------

# The registered maps as {"id","name","scene"} dicts, built from map_registry.tres.
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


static func is_custom_map_id(id: String) -> bool:
	return id.begins_with(CUSTOM_MAP_PREFIX)


static func custom_map_slug(id: String) -> String:
	return id.trim_prefix(CUSTOM_MAP_PREFIX)


# Custom-map ids offered by menus, as "custom:<slug>". Local machine only.
static func get_custom_map_ids() -> Array:
	var out: Array = []

	for info in MapDocument.list_maps():
		out.append(CUSTOM_MAP_PREFIX + String(info["slug"]))

	return out


static func has_map(id: String) -> bool:
	if is_custom_map_id(id):
		# Only true where the map file actually exists (custom maps are per-machine).
		return MapDocument.map_exists(custom_map_slug(id))

	return not get_map_entry(id).is_empty()


static func get_map_ids() -> Array:
	var ids: Array = []

	for entry in get_map_entries():
		ids.append(String(entry.get("id", "")))

	return ids


static func get_map_name(id: String) -> String:
	if is_custom_map_id(id):
		var doc := MapDocument.load_map(custom_map_slug(id))
		return doc.map_name if doc != null else custom_map_slug(id)

	var entry := get_map_entry(id)
	return String(entry.get("name", id)) if not entry.is_empty() else id


static func normalize_map_id(value: String) -> String:
	var key := value.strip_edges().to_lower().replace(" ", "_").replace("-", "_")

	# "custom:<slug>" ids pass through (slug part re-sanitized). Whether the map exists
	# is a separate question — has_map() answers that per machine.
	if key.begins_with(CUSTOM_MAP_PREFIX):
		var slug := key.trim_prefix(CUSTOM_MAP_PREFIX)
		slug = slug.replace("/", "").replace("\\", "").replace("..", "").replace(":", "")
		return CUSTOM_MAP_PREFIX + slug

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
