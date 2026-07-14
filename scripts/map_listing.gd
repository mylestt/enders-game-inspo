@tool
extends Resource
class_name MapListing

# One entry in the map registry (see map_registry.gd / map_registry.tres). Add a map by
# dragging its .tscn into `scene` in the inspector — `id` and `display_name` auto-derive
# from the scene's filename if you leave them blank, so a new map needs nothing else.
#
# Set `id`/`display_name` explicitly when the id must NOT match the filename (e.g. the
# diamond arena scene is DiamondArena.tscn but its id is "diamond", which cmdline `--map`,
# saved settings and normalize aliases all depend on).

# Drag the arena .tscn here. This is the only required field.
@export var scene: PackedScene

# Optional. Leave blank to derive a slug from the scene filename (e.g. my_map.tscn -> "my_map").
@export var id: String = ""

# Optional. Leave blank to derive a title from the id (e.g. "my_map" -> "My Map").
@export var display_name: String = ""


func resolve_id() -> String:
	var raw := id.strip_edges()

	if raw.is_empty() and scene != null:
		raw = scene.resource_path.get_file().get_basename()

	# Slugify the same way MapGenerator.normalize_map_id does (kept inline to avoid a
	# call back into the registry while it is still building its entry list).
	return raw.to_lower().replace(" ", "_").replace("-", "_")


func resolve_name() -> String:
	var raw := display_name.strip_edges()

	if not raw.is_empty():
		return raw

	# "my_map" -> "My Map".
	return resolve_id().capitalize()
