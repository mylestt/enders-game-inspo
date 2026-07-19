@tool
extends Resource
class_name WeaponListing

# One entry in the weapon registry (see weapon_registry.gd / weapon_registry.tres). Add a
# weapon by dragging its .tscn into `scene` in the inspector — `id` and `display_name`
# auto-derive from the scene's filename if you leave them blank, so a new weapon needs
# nothing else. Mirrors MapListing so the two registries behave the same way.
#
# The ORDER of entries in the registry is the quick-swap slot order (first = slot 1, etc.),
# so put the guns in the order you want keys 1/2/3/4 to select them.
#
# Set `id`/`display_name` explicitly when the id must NOT match the filename (e.g. a scene
# named RailCannon.tscn whose weapon id must stay "railgun" for the shop/economy/FFA pool).

# Drag the weapon .tscn here. This is the only required field.
@export var scene: PackedScene

# Optional. Leave blank to derive a slug from the scene filename (e.g. rifle.tscn -> "rifle").
@export var id: String = ""

# Optional. Leave blank to derive a title from the id (e.g. "plasma_cannon" -> "Plasma Cannon").
@export var display_name: String = ""


func resolve_id() -> String:
	var raw := id.strip_edges()

	if raw.is_empty() and scene != null:
		raw = scene.resource_path.get_file().get_basename()

	# Slugify the same way weapon ids are compared everywhere (lower snake_case).
	return raw.to_lower().replace(" ", "_").replace("-", "_")


func resolve_name() -> String:
	var raw := display_name.strip_edges()

	if not raw.is_empty():
		return raw

	# "plasma_cannon" -> "Plasma Cannon".
	return resolve_id().capitalize()
