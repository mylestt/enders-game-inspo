extends RefCounted
class_name MapDocument

# A custom map on disk. Everything the in-game map creator edits lives in this document;
# CustomMapBuilder turns it into a playable node tree at runtime, so a custom map is DATA
# (JSON + copied model files), never a script or scene — nothing in a map file can execute
# code. Layout on disk:
#
#   user://custom_maps/<slug>/map.json    — this document
#   user://custom_maps/<slug>/assets/…    — imported model files (glb/gltf/obj/stl/fbx),
#                                           copied in at import time so maps stay portable
#
# Every placeable thing is an entry in `objects`, discriminated by "kind":
#   primitive — box / sphere / cylinder / capsule / ramp / cone / torus (+ bevel on
#               box & cylinder) with a simple PBR material. Dimensions are stored as
#               explicit fields (never node scale) so player math never sees scaled bases.
#   model     — an imported 3D file, by assets-relative path; may carry node scale.
#   spawn     — a player spawn (team "a"/"b"); becomes a real SpawnPoint at runtime.
#   light     — omni or spot light.
#
# All reads go through the _safe_* helpers so a hand-edited or truncated JSON degrades to
# defaults instead of crashing the builder (same ethos as LobbyManager's settings guards).

const SAVE_ROOT := "user://custom_maps"
const MAP_FILE_NAME := "map.json"
const ASSETS_DIR_NAME := "assets"
const FORMAT_VERSION := 1
const MAX_SLUG_LENGTH := 24
const MAX_NAME_LENGTH := 40

const KIND_PRIMITIVE := "primitive"
const KIND_MODEL := "model"
const KIND_SPAWN := "spawn"
const KIND_LIGHT := "light"

const PRIMITIVE_SHAPES := ["box", "sphere", "cylinder", "capsule", "ramp", "cone", "torus"]

var slug: String = ""
var map_name: String = "Untitled Map"
var environment: Dictionary = default_environment()
var objects: Array = []
var next_object_id: int = 1


# --- Defaults -------------------------------------------------------------------------

static func default_environment() -> Dictionary:
	return {
		"background_color": [0.02, 0.03, 0.05],
		"ambient_color": [0.55, 0.6, 0.7],
		"ambient_energy": 0.6,
		"sun_enabled": true,
		"sun_color": [1.0, 0.97, 0.9],
		"sun_energy": 1.2,
		"sun_shadows": true,
		# Node rotation degrees: x = elevation (negative pitches down), y = azimuth.
		"sun_rotation_degrees": [-42.0, 28.0],
	}


static func default_material() -> Dictionary:
	return {
		"color": [0.62, 0.66, 0.72],
		"metallic": 0.1,
		"roughness": 0.7,
		"emission": [0.0, 0.0, 0.0],
		"emission_energy": 0.0,
	}


# A starter map: a floor slab, a sun, ambient light, and one spawn per team, so a brand
# new map is instantly walkable/playtestable instead of an empty void.
static func create_new(display_name: String) -> MapDocument:
	var doc := MapDocument.new()
	doc.map_name = sanitize_name(display_name)
	doc.slug = slug_from_name(doc.map_name)

	var floor_entry := doc.make_primitive_entry("box")
	floor_entry["name"] = "Floor"
	floor_entry["size"] = [24.0, 1.0, 24.0]
	floor_entry["position"] = [0.0, -0.5, 0.0]
	floor_entry["bevel_radius"] = 0.12
	floor_entry["bevel_segments"] = 2
	doc.objects.append(floor_entry)

	var spawn_a := doc.make_spawn_entry("a")
	spawn_a["position"] = [-6.0, 1.05, 0.0]
	spawn_a["rotation_degrees"] = [0.0, -90.0, 0.0]
	doc.objects.append(spawn_a)

	var spawn_b := doc.make_spawn_entry("b")
	spawn_b["position"] = [6.0, 1.05, 0.0]
	spawn_b["rotation_degrees"] = [0.0, 90.0, 0.0]
	doc.objects.append(spawn_b)

	return doc


# --- Entry factories (editor + tests) --------------------------------------------------

func take_object_id() -> int:
	var id := next_object_id
	next_object_id += 1
	return id


func make_primitive_entry(shape: String) -> Dictionary:
	var entry := {
		"id": take_object_id(),
		"kind": KIND_PRIMITIVE,
		"shape": shape if PRIMITIVE_SHAPES.has(shape) else "box",
		"name": shape.capitalize(),
		"position": [0.0, 0.0, 0.0],
		"rotation_degrees": [0.0, 0.0, 0.0],
		"material": default_material(),
	}

	match entry["shape"]:
		"box":
			entry["size"] = [2.0, 2.0, 2.0]
			entry["bevel_radius"] = 0.0
			entry["bevel_segments"] = 3
		"ramp":
			entry["size"] = [3.0, 2.0, 4.0]
		"sphere":
			entry["radius"] = 1.5
		"cylinder":
			entry["radius"] = 1.0
			entry["height"] = 3.0
			entry["bevel_radius"] = 0.0
			entry["bevel_segments"] = 3
		"cone":
			entry["radius"] = 1.2
			entry["height"] = 2.5
		"capsule":
			entry["radius"] = 0.8
			entry["height"] = 3.0
		"torus":
			entry["radius"] = 2.0
			entry["thickness"] = 0.6

	return entry


func make_model_entry(assets_relative_path: String, display_name: String) -> Dictionary:
	return {
		"id": take_object_id(),
		"kind": KIND_MODEL,
		"name": sanitize_name(display_name),
		"source": assets_relative_path,
		"position": [0.0, 0.0, 0.0],
		"rotation_degrees": [0.0, 0.0, 0.0],
		"scale": [1.0, 1.0, 1.0],
	}


func make_spawn_entry(team: String) -> Dictionary:
	return {
		"id": take_object_id(),
		"kind": KIND_SPAWN,
		"team": "b" if team.to_lower() == "b" else "a",
		"name": "Spawn " + ("B" if team.to_lower() == "b" else "A"),
		"position": [0.0, 1.05, 0.0],
		"rotation_degrees": [0.0, 0.0, 0.0],
	}


func make_light_entry(light_type: String) -> Dictionary:
	var entry := {
		"id": take_object_id(),
		"kind": KIND_LIGHT,
		"type": "spot" if light_type.to_lower() == "spot" else "omni",
		"name": "Spot Light" if light_type.to_lower() == "spot" else "Omni Light",
		"position": [0.0, 4.0, 0.0],
		"rotation_degrees": [-90.0, 0.0, 0.0],
		"color": [1.0, 0.98, 0.92],
		"energy": 4.0,
		"range": 18.0,
		"spot_angle": 45.0,
		"shadows": false,
	}
	return entry


func get_entry(object_id: int) -> Dictionary:
	for entry in objects:
		if entry is Dictionary and int(entry.get("id", -1)) == object_id:
			return entry

	return {}


func remove_entry(object_id: int) -> void:
	for i in range(objects.size()):
		if objects[i] is Dictionary and int(objects[i].get("id", -1)) == object_id:
			objects.remove_at(i)
			return


func count_kind(kind: String, extra_key := "", extra_value := "") -> int:
	var total := 0

	for entry in objects:
		if not (entry is Dictionary) or String(entry.get("kind", "")) != kind:
			continue

		if extra_key != "" and String(entry.get(extra_key, "")) != extra_value:
			continue

		total += 1

	return total


# --- Serialization ---------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"format": FORMAT_VERSION,
		"name": map_name,
		"next_object_id": next_object_id,
		"environment": environment.duplicate(true),
		"objects": objects.duplicate(true),
	}


func load_from_dict(data: Dictionary) -> void:
	map_name = sanitize_name(_safe_string(data.get("name"), "Untitled Map"))
	next_object_id = maxi(_safe_int(data.get("next_object_id"), 1), 1)
	environment = _safe_environment(data.get("environment"))
	objects = []

	var raw_objects: Variant = data.get("objects")

	if raw_objects is Array:
		for raw_entry in raw_objects:
			if not (raw_entry is Dictionary):
				continue

			var entry := _safe_entry(raw_entry)

			if not entry.is_empty():
				objects.append(entry)
				next_object_id = maxi(next_object_id, int(entry["id"]) + 1)


# Per-entry validation: unknown kinds are dropped, every field is type-checked and clamped
# so the builder can trust what it reads.
func _safe_entry(raw: Dictionary) -> Dictionary:
	var kind := _safe_string(raw.get("kind"), "")

	if not [KIND_PRIMITIVE, KIND_MODEL, KIND_SPAWN, KIND_LIGHT].has(kind):
		return {}

	var entry := {
		"id": maxi(_safe_int(raw.get("id"), 0), 0),
		"kind": kind,
		"name": sanitize_name(_safe_string(raw.get("name"), kind.capitalize())),
		"position": _safe_vector3_list(raw.get("position"), [0.0, 0.0, 0.0], 100000.0),
		"rotation_degrees": _safe_vector3_list(raw.get("rotation_degrees"), [0.0, 0.0, 0.0], 36000.0),
	}

	match kind:
		KIND_PRIMITIVE:
			var shape := _safe_string(raw.get("shape"), "box")
			entry["shape"] = shape if PRIMITIVE_SHAPES.has(shape) else "box"
			entry["material"] = _safe_material(raw.get("material"))
			entry["size"] = _safe_vector3_list(raw.get("size"), [2.0, 2.0, 2.0], 2000.0, 0.05)
			entry["radius"] = clampf(_safe_float(raw.get("radius"), 1.0), 0.025, 1000.0)
			entry["height"] = clampf(_safe_float(raw.get("height"), 2.0), 0.05, 2000.0)
			entry["thickness"] = clampf(_safe_float(raw.get("thickness"), 0.5), 0.025, 1000.0)
			entry["bevel_radius"] = clampf(_safe_float(raw.get("bevel_radius"), 0.0), 0.0, 1000.0)
			entry["bevel_segments"] = clampi(_safe_int(raw.get("bevel_segments"), 3), 1, BevelMesh.MAX_SEGMENTS)
		KIND_MODEL:
			var source := _safe_string(raw.get("source"), "")

			# Assets-relative only: reject anything that tries to escape the map folder.
			if source == "" or source.contains("..") or source.begins_with("/") or source.contains(":"):
				return {}

			entry["source"] = source
			entry["scale"] = _safe_vector3_list(raw.get("scale"), [1.0, 1.0, 1.0], 1000.0, 0.001)
		KIND_SPAWN:
			entry["team"] = "b" if _safe_string(raw.get("team"), "a") == "b" else "a"
		KIND_LIGHT:
			entry["type"] = "spot" if _safe_string(raw.get("type"), "omni") == "spot" else "omni"
			entry["color"] = _safe_color_list(raw.get("color"), [1.0, 1.0, 1.0])
			entry["energy"] = clampf(_safe_float(raw.get("energy"), 4.0), 0.0, 64.0)
			entry["range"] = clampf(_safe_float(raw.get("range"), 18.0), 0.5, 500.0)
			entry["spot_angle"] = clampf(_safe_float(raw.get("spot_angle"), 45.0), 1.0, 89.0)
			entry["shadows"] = bool(raw.get("shadows", false)) if raw.get("shadows") is bool else false

	return entry


func _safe_environment(raw: Variant) -> Dictionary:
	var defaults := default_environment()

	if not (raw is Dictionary):
		return defaults

	var env: Dictionary = raw

	return {
		"background_color": _safe_color_list(env.get("background_color"), defaults["background_color"]),
		"ambient_color": _safe_color_list(env.get("ambient_color"), defaults["ambient_color"]),
		"ambient_energy": clampf(_safe_float(env.get("ambient_energy"), defaults["ambient_energy"]), 0.0, 16.0),
		"sun_enabled": bool(env.get("sun_enabled", true)) if env.get("sun_enabled") is bool else true,
		"sun_color": _safe_color_list(env.get("sun_color"), defaults["sun_color"]),
		"sun_energy": clampf(_safe_float(env.get("sun_energy"), defaults["sun_energy"]), 0.0, 16.0),
		"sun_shadows": bool(env.get("sun_shadows", true)) if env.get("sun_shadows") is bool else true,
		"sun_rotation_degrees": _safe_vector2_list(env.get("sun_rotation_degrees"), defaults["sun_rotation_degrees"], 36000.0),
	}


func _safe_material(raw: Variant) -> Dictionary:
	var defaults := default_material()

	if not (raw is Dictionary):
		return defaults

	var mat: Dictionary = raw

	return {
		"color": _safe_color_list(mat.get("color"), defaults["color"]),
		"metallic": clampf(_safe_float(mat.get("metallic"), 0.1), 0.0, 1.0),
		"roughness": clampf(_safe_float(mat.get("roughness"), 0.7), 0.0, 1.0),
		"emission": _safe_color_list(mat.get("emission"), defaults["emission"]),
		"emission_energy": clampf(_safe_float(mat.get("emission_energy"), 0.0), 0.0, 32.0),
	}


# --- Disk I/O ---------------------------------------------------------------------------

func save() -> Error:
	if slug == "":
		return ERR_INVALID_PARAMETER

	var dir_path := map_dir(slug)
	DirAccess.make_dir_recursive_absolute(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path + "/" + ASSETS_DIR_NAME)

	var file := FileAccess.open(dir_path + "/" + MAP_FILE_NAME, FileAccess.WRITE)

	if file == null:
		return FileAccess.get_open_error()

	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.close()
	return OK


static func load_map(map_slug: String) -> MapDocument:
	var path := map_dir(map_slug) + "/" + MAP_FILE_NAME

	if not FileAccess.file_exists(path):
		return null

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return null

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	if not (parsed is Dictionary):
		return null

	var doc := MapDocument.new()
	doc.slug = map_slug
	doc.load_from_dict(parsed)
	return doc


static func map_exists(map_slug: String) -> bool:
	return FileAccess.file_exists(map_dir(map_slug) + "/" + MAP_FILE_NAME)


static func map_dir(map_slug: String) -> String:
	return SAVE_ROOT + "/" + map_slug


static func assets_dir(map_slug: String) -> String:
	return map_dir(map_slug) + "/" + ASSETS_DIR_NAME


# Lists saved maps as [{slug, name}], sorted by name.
static func list_maps() -> Array:
	var out: Array = []
	var root := DirAccess.open(SAVE_ROOT)

	if root == null:
		return out

	root.list_dir_begin()
	var entry_name := root.get_next()

	while entry_name != "":
		if root.current_is_dir() and not entry_name.begins_with("."):
			var doc := load_map(entry_name)

			if doc != null:
				out.append({"slug": entry_name, "name": doc.map_name})

		entry_name = root.get_next()

	root.list_dir_end()
	out.sort_custom(func(a, b): return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	return out


static func delete_map(map_slug: String) -> void:
	if map_slug == "" or map_slug.contains("..") or map_slug.contains("/"):
		return

	_delete_recursive(map_dir(map_slug))


static func duplicate_map(map_slug: String, new_name: String) -> String:
	var source := load_map(map_slug)

	if source == null:
		return ""

	source.map_name = sanitize_name(new_name)
	var new_slug := slug_from_name(source.map_name)
	source.slug = new_slug

	if source.save() != OK:
		return ""

	_copy_dir_files(assets_dir(map_slug), assets_dir(new_slug))
	return new_slug


static func _delete_recursive(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir == null:
		return

	dir.list_dir_begin()
	var entry_name := dir.get_next()

	while entry_name != "":
		if entry_name != "." and entry_name != "..":
			if dir.current_is_dir():
				_delete_recursive(path + "/" + entry_name)
			else:
				dir.remove(entry_name)

		entry_name = dir.get_next()

	dir.list_dir_end()
	DirAccess.remove_absolute(path)


static func _copy_dir_files(from_dir: String, to_dir: String) -> void:
	var dir := DirAccess.open(from_dir)

	if dir == null:
		return

	DirAccess.make_dir_recursive_absolute(to_dir)
	dir.list_dir_begin()
	var entry_name := dir.get_next()

	while entry_name != "":
		if not dir.current_is_dir():
			dir.copy(from_dir + "/" + entry_name, to_dir + "/" + entry_name)

		entry_name = dir.get_next()

	dir.list_dir_end()


# --- Naming ------------------------------------------------------------------------------

static func sanitize_name(value: String) -> String:
	var clean := value.strip_edges().replace("\n", " ").replace("\r", " ").replace("\t", " ")

	if clean.length() > MAX_NAME_LENGTH:
		clean = clean.substr(0, MAX_NAME_LENGTH)

	return clean if clean != "" else "Untitled Map"


# Folder-safe slug from a display name; suffixes _2, _3… if the folder is taken.
static func slug_from_name(display_name: String) -> String:
	var base := ""

	for character in display_name.to_lower():
		if (character >= "a" and character <= "z") or (character >= "0" and character <= "9"):
			base += character
		elif character == " " or character == "-" or character == "_":
			base += "_"

	while base.contains("__"):
		base = base.replace("__", "_")

	base = base.lstrip("_").rstrip("_")

	if base == "":
		base = "map"

	if base.length() > MAX_SLUG_LENGTH:
		base = base.substr(0, MAX_SLUG_LENGTH)

	if not map_exists(base):
		return base

	for i in range(2, 1000):
		var candidate := base + "_" + str(i)

		if not map_exists(candidate):
			return candidate

	return base + "_" + str(Time.get_ticks_msec())


# --- Safe readers -------------------------------------------------------------------------

static func _safe_string(value: Variant, fallback: String) -> String:
	return String(value) if value is String else fallback


static func _safe_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value

	if value is float and is_finite(value):
		return int(value)

	return fallback


static func _safe_float(value: Variant, fallback: float) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return float(value)

	return fallback


static func _safe_vector3_list(value: Variant, fallback: Array, limit: float, minimum: float = -INF) -> Array:
	if not (value is Array) or value.size() != 3:
		return fallback.duplicate()

	var out: Array = []

	for i in range(3):
		var component := _safe_float(value[i], float(fallback[i]))
		out.append(clampf(component, maxf(-limit, minimum), limit))

	return out


static func _safe_vector2_list(value: Variant, fallback: Array, limit: float) -> Array:
	if not (value is Array) or value.size() != 2:
		return fallback.duplicate()

	return [
		clampf(_safe_float(value[0], float(fallback[0])), -limit, limit),
		clampf(_safe_float(value[1], float(fallback[1])), -limit, limit),
	]


static func _safe_color_list(value: Variant, fallback: Array) -> Array:
	if not (value is Array) or value.size() < 3:
		return fallback.duplicate()

	return [
		clampf(_safe_float(value[0], float(fallback[0])), 0.0, 8.0),
		clampf(_safe_float(value[1], float(fallback[1])), 0.0, 8.0),
		clampf(_safe_float(value[2], float(fallback[2])), 0.0, 8.0),
	]


# --- Vector helpers shared by builder + editor ---------------------------------------------

static func vec3_from(list: Variant, fallback := Vector3.ZERO) -> Vector3:
	if list is Array and list.size() == 3:
		return Vector3(_safe_float(list[0], fallback.x), _safe_float(list[1], fallback.y), _safe_float(list[2], fallback.z))

	return fallback


static func list_from_vec3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func color_from(list: Variant, fallback := Color.WHITE) -> Color:
	if list is Array and list.size() >= 3:
		return Color(_safe_float(list[0], fallback.r), _safe_float(list[1], fallback.g), _safe_float(list[2], fallback.b))

	return fallback


static func list_from_color(value: Color) -> Array:
	return [value.r, value.g, value.b]
