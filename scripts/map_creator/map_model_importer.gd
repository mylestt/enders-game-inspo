extends RefCounted
class_name MapModelImporter

# Runtime 3D-file import for the map creator. The Godot EDITOR import pipeline is not
# available in an exported game, so each format gets a runtime path instead:
#
#   .glb / .gltf — GLTFDocument (engine-native runtime loader; external .bin/textures are
#                  copied alongside at import time)
#   .fbx         — FBXDocument (ufbx, engine-native since 4.3)
#   .obj         — hand-written parser below (v/vt/vn/f + basic .mtl: Kd, d, map_Kd)
#   .stl         — hand-written parser below (binary + ascii, flat shaded)
#   .blend       — cannot be read directly at runtime; if Blender is installed we shell out
#                  to `blender -b <file> --python-expr "export_scene.gltf(...)"` (exactly
#                  what the Godot editor does) and keep the resulting .glb in the map's
#                  assets folder. Without Blender the import fails with instructions.
#
# import_file() copies/converts the source INTO user://custom_maps/<slug>/assets/ so a
# saved map never depends on files elsewhere on disk. load_model_scene() loads from there.

const IMPORT_EXTENSIONS := ["glb", "gltf", "obj", "stl", "fbx", "blend"]

const FILE_DIALOG_FILTERS := [
	"*.glb, *.gltf, *.obj, *.stl, *.fbx, *.blend ; 3D Models",
	"*.blend ; Blender",
	"*.glb, *.gltf ; glTF 2.0",
	"*.obj ; Wavefront OBJ",
	"*.fbx ; FBX",
	"*.stl ; STL",
]


static func is_supported(path: String) -> bool:
	return IMPORT_EXTENSIONS.has(path.get_extension().to_lower())


# --- Import (copy/convert into the map's assets folder) -----------------------------------

# Returns {ok: bool, relative: String, error: String, warnings: Array[String]}.
static func import_file(source_path: String, map_slug: String) -> Dictionary:
	var result := {"ok": false, "relative": "", "error": "", "warnings": []}
	var extension := source_path.get_extension().to_lower()

	if not IMPORT_EXTENSIONS.has(extension):
		result["error"] = "Unsupported file type '." + extension + "'."
		return result

	if not FileAccess.file_exists(source_path):
		result["error"] = "File not found: " + source_path
		return result

	var assets := MapDocument.assets_dir(map_slug)
	DirAccess.make_dir_recursive_absolute(assets)

	if extension == "blend":
		return _import_blend(source_path, assets, result)

	var copied := _copy_into_assets(source_path, assets)

	if copied == "":
		result["error"] = "Could not copy the file into the map's assets folder."
		return result

	# Formats with external companion files: copy those too, next to the model.
	match extension:
		"gltf":
			result["warnings"].append_array(_copy_gltf_dependencies(source_path, assets))
		"obj":
			result["warnings"].append_array(_copy_obj_dependencies(source_path, assets))
		"fbx":
			result["warnings"].append("FBX texture files are not collected automatically — embed media in the FBX, or convert to .glb for full material support.")

	# Prove it loads before declaring success, so a broken file fails at import time
	# (with the dialog open) instead of when the map builds.
	var probe := load_model_scene(assets + "/" + copied)

	if probe == null:
		result["error"] = "The file copied, but could not be parsed as a 3D model."
		return result

	probe.free()
	result["ok"] = true
	result["relative"] = MapDocument.ASSETS_DIR_NAME + "/" + copied
	return result


static func _import_blend(source_path: String, assets_dir: String, result: Dictionary) -> Dictionary:
	var blender := find_blender_executable()

	if blender == "":
		result["error"] = (
			"Importing .blend files needs Blender installed. Install Blender (blender.org), "
			+ "or export your model as .glb from Blender and import that instead. "
			+ "If Blender is installed somewhere unusual, set its path in this dialog."
		)
		return result

	var out_name := _unique_asset_name(assets_dir, source_path.get_file().get_basename() + ".glb")
	var out_path := assets_dir + "/" + out_name
	var convert := convert_blend_to_glb(blender, source_path, out_path)

	if not bool(convert.get("ok", false)):
		result["error"] = String(convert.get("error", "Blender conversion failed."))
		return result

	var probe := load_model_scene(out_path)

	if probe == null:
		result["error"] = "Blender converted the file, but the result could not be loaded."
		return result

	probe.free()
	result["ok"] = true
	result["relative"] = MapDocument.ASSETS_DIR_NAME + "/" + out_name
	return result


# Copies a file into the assets dir; returns the stored file name, or "" on failure.
# A same-name, same-size file is treated as a re-import and reused; a same-name but
# DIFFERENT file gets a _2/_3 suffix so it can never clobber another object's asset.
static func _copy_into_assets(source_path: String, assets_dir: String) -> String:
	var name := source_path.get_file()

	if FileAccess.file_exists(assets_dir + "/" + name):
		if _same_file_size(source_path, assets_dir + "/" + name):
			return name

		name = _unique_asset_name(assets_dir, name)

	var error := DirAccess.copy_absolute(source_path, assets_dir + "/" + name)
	return name if error == OK else ""


static func _same_file_size(path_a: String, path_b: String) -> bool:
	var a := FileAccess.open(path_a, FileAccess.READ)
	var b := FileAccess.open(path_b, FileAccess.READ)
	var same := a != null and b != null and a.get_length() == b.get_length()

	if a != null:
		a.close()

	if b != null:
		b.close()

	return same


# First free file name: name.ext, name_2.ext, name_3.ext, …
static func _unique_asset_name(assets_dir: String, file_name: String) -> String:
	if not FileAccess.file_exists(assets_dir + "/" + file_name):
		return file_name

	var base := file_name.get_basename()
	var extension := file_name.get_extension()

	for counter in range(2, 1000):
		var candidate := base + "_" + str(counter) + ("." + extension if extension != "" else "")

		if not FileAccess.file_exists(assets_dir + "/" + candidate):
			return candidate

	return base + "_" + str(Time.get_ticks_msec()) + "." + extension


# .gltf JSON may reference external buffers/images by relative uri; copy them along.
static func _copy_gltf_dependencies(gltf_path: String, assets_dir: String) -> Array:
	var warnings: Array = []
	var file := FileAccess.open(gltf_path, FileAccess.READ)

	if file == null:
		return warnings

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	if not (parsed is Dictionary):
		return warnings

	var base_dir := gltf_path.get_base_dir()
	var uris: Array = []

	for section in ["buffers", "images"]:
		var entries: Variant = parsed.get(section)

		if entries is Array:
			for entry in entries:
				if entry is Dictionary and entry.get("uri") is String:
					uris.append(String(entry["uri"]))

	for uri in uris:
		var text := String(uri)

		if text.begins_with("data:"):
			continue

		text = text.uri_decode()

		if text.contains("..") or text.begins_with("/"):
			warnings.append("Skipped external reference outside the model folder: " + text)
			continue

		var dependency := base_dir + "/" + text

		if not FileAccess.file_exists(dependency):
			warnings.append("Missing companion file: " + text)
			continue

		var target_dir := (assets_dir + "/" + text).get_base_dir()
		DirAccess.make_dir_recursive_absolute(target_dir)
		DirAccess.copy_absolute(dependency, assets_dir + "/" + text)

	return warnings


# .obj may reference .mtl files, which may reference textures; copy the chain.
static func _copy_obj_dependencies(obj_path: String, assets_dir: String) -> Array:
	var warnings: Array = []
	var base_dir := obj_path.get_base_dir()
	var file := FileAccess.open(obj_path, FileAccess.READ)

	if file == null:
		return warnings

	while not file.eof_reached():
		var line := file.get_line().strip_edges()

		if not line.begins_with("mtllib "):
			continue

		var mtl_name := line.substr(7).strip_edges()

		if mtl_name == "" or mtl_name.contains("..") or mtl_name.begins_with("/"):
			continue

		var mtl_path := base_dir + "/" + mtl_name

		if not FileAccess.file_exists(mtl_path):
			warnings.append("Missing material file: " + mtl_name)
			continue

		DirAccess.copy_absolute(mtl_path, assets_dir + "/" + mtl_name.get_file())

		var mtl := FileAccess.open(mtl_path, FileAccess.READ)

		if mtl == null:
			continue

		while not mtl.eof_reached():
			var mtl_line := mtl.get_line().strip_edges()

			if not mtl_line.begins_with("map_"):
				continue

			var texture_name := mtl_line.get_slice(" ", mtl_line.get_slice_count(" ") - 1).strip_edges()

			if texture_name == "" or texture_name.contains("..") or texture_name.begins_with("/"):
				continue

			var texture_path := base_dir + "/" + texture_name

			if FileAccess.file_exists(texture_path):
				DirAccess.copy_absolute(texture_path, assets_dir + "/" + texture_name.get_file())
			else:
				warnings.append("Missing texture: " + texture_name)

		mtl.close()

	file.close()
	return warnings


# --- Load (assets folder -> Node3D) --------------------------------------------------------

# Loads a model file into a plain Node3D tree (MeshInstance3Ds inside). Returns null on
# failure. No colliders here — CustomMapBuilder adds StaticBody3D+trimesh per mesh.
static func load_model_scene(path: String) -> Node3D:
	match path.get_extension().to_lower():
		"glb", "gltf":
			return _load_gltf(path)
		"fbx":
			return _load_fbx(path)
		"obj":
			return _load_obj(path)
		"stl":
			return _load_stl(path)

	return null


static func _load_gltf(path: String) -> Node3D:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state, 0, path.get_base_dir())

	if error != OK:
		push_warning("MapModelImporter: glTF load failed for " + path + " (error " + str(error) + ").")
		return null

	var scene := document.generate_scene(state)
	return scene as Node3D


static func _load_fbx(path: String) -> Node3D:
	if not ClassDB.class_exists("FBXDocument"):
		push_warning("MapModelImporter: FBX runtime loading is unavailable in this build.")
		return null

	var document: Variant = ClassDB.instantiate("FBXDocument")
	var state: Variant = ClassDB.instantiate("FBXState")

	if document == null or state == null:
		return null

	var error: int = document.append_from_file(path, state, 0, path.get_base_dir())

	if error != OK:
		push_warning("MapModelImporter: FBX load failed for " + path + " (error " + str(error) + ").")
		return null

	return document.generate_scene(state) as Node3D


# --- OBJ ------------------------------------------------------------------------------------

static func _load_obj(path: String) -> Node3D:
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return null

	var positions: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var normals: Array[Vector3] = []
	var materials := {}
	var base_dir := path.get_base_dir()

	# Faces bucketed by material name; "" = no material.
	var face_buckets := {}
	var current_bucket := ""
	face_buckets[current_bucket] = []

	while not file.eof_reached():
		var line := file.get_line().strip_edges()

		if line == "" or line.begins_with("#"):
			continue

		var parts := line.split(" ", false)

		if parts.is_empty():
			continue

		match parts[0]:
			"v":
				if parts.size() >= 4:
					positions.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
			"vt":
				if parts.size() >= 3:
					# OBJ v axis is bottom-up; Godot UVs are top-down.
					uvs.append(Vector2(parts[1].to_float(), 1.0 - parts[2].to_float()))
			"vn":
				if parts.size() >= 4:
					normals.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
			"mtllib":
				if parts.size() >= 2:
					_parse_mtl(base_dir + "/" + line.substr(7).strip_edges(), materials)
			"usemtl":
				current_bucket = parts[1] if parts.size() >= 2 else ""

				if not face_buckets.has(current_bucket):
					face_buckets[current_bucket] = []
			"f":
				if parts.size() >= 4:
					face_buckets[current_bucket].append(parts.slice(1))

	file.close()

	if positions.is_empty():
		return null

	var mesh := ArrayMesh.new()
	var surface_materials: Array = []

	for bucket_name in face_buckets:
		var faces: Array = face_buckets[bucket_name]

		if faces.is_empty():
			continue

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var wrote_normals := false

		for face in faces:
			var corner_count: int = face.size()

			# Fan triangulation, emitted in REVERSED order: OBJ fronts are counter-clockwise,
			# Godot fronts are clockwise.
			for triangle in range(1, corner_count - 1):
				for corner_index in [0, triangle + 1, triangle]:
					var reference := String(face[corner_index])
					var indices := reference.split("/")
					var position_index := _obj_index(indices[0], positions.size())

					if position_index < 0:
						continue

					if indices.size() >= 3 and indices[2] != "":
						var normal_index := _obj_index(indices[2], normals.size())

						if normal_index >= 0:
							st.set_normal(normals[normal_index])
							wrote_normals = true

					if indices.size() >= 2 and indices[1] != "":
						var uv_index := _obj_index(indices[1], uvs.size())

						if uv_index >= 0:
							st.set_uv(uvs[uv_index])

					st.add_vertex(positions[position_index])

		if not wrote_normals:
			st.generate_normals()

		st.index()
		st.commit(mesh)
		surface_materials.append(materials.get(bucket_name))

	if mesh.get_surface_count() == 0:
		return null

	var root := Node3D.new()
	root.name = path.get_file().get_basename()
	var instance := MeshInstance3D.new()
	instance.name = "Mesh"
	instance.mesh = mesh

	for surface in range(mesh.get_surface_count()):
		if surface < surface_materials.size() and surface_materials[surface] != null:
			instance.set_surface_override_material(surface, surface_materials[surface])

	root.add_child(instance)
	return root


# 1-based (or negative-relative) OBJ index -> 0-based, or -1 when out of range.
static func _obj_index(token: String, count: int) -> int:
	var raw := token.to_int()
	var index := raw - 1 if raw > 0 else count + raw

	return index if index >= 0 and index < count else -1


static func _parse_mtl(path: String, materials: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return

	var base_dir := path.get_base_dir()
	var current: StandardMaterial3D = null

	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		var parts := line.split(" ", false)

		if parts.is_empty():
			continue

		match parts[0]:
			"newmtl":
				current = StandardMaterial3D.new()
				current.roughness = 0.8
				materials[parts[1] if parts.size() >= 2 else ""] = current
			"Kd":
				if current != null and parts.size() >= 4:
					current.albedo_color = Color(parts[1].to_float(), parts[2].to_float(), parts[3].to_float())
			"d":
				if current != null and parts.size() >= 2:
					var alpha := parts[1].to_float()

					if alpha < 0.999:
						current.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						current.albedo_color.a = clampf(alpha, 0.0, 1.0)
			"map_Kd":
				if current != null and parts.size() >= 2:
					var texture_name := String(parts[parts.size() - 1])
					var texture := _load_texture(base_dir + "/" + texture_name)

					if texture != null:
						current.albedo_texture = texture

	file.close()


static func _load_texture(path: String) -> ImageTexture:
	if not FileAccess.file_exists(path):
		return null

	var image := Image.load_from_file(path)

	if image == null or image.is_empty():
		return null

	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


# --- STL ------------------------------------------------------------------------------------

static func _load_stl(path: String) -> Node3D:
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return null

	var length := file.get_length()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangle_count := 0

	# Binary detection by exact size (some binary files also start with "solid").
	var is_binary := false

	if length >= 84:
		file.seek(80)
		var declared := file.get_32()
		is_binary = length == 84 + declared * 50

	if is_binary:
		file.seek(80)
		var declared := file.get_32()

		for triangle in range(declared):
			var normal := Vector3(file.get_float(), file.get_float(), file.get_float())
			var a := Vector3(file.get_float(), file.get_float(), file.get_float())
			var b := Vector3(file.get_float(), file.get_float(), file.get_float())
			var c := Vector3(file.get_float(), file.get_float(), file.get_float())
			file.get_16()
			_emit_stl_triangle(st, normal, a, b, c)
			triangle_count += 1
	else:
		file.seek(0)
		var corners: Array[Vector3] = []
		var normal := Vector3.UP

		while not file.eof_reached():
			var parts := file.get_line().strip_edges().split(" ", false)

			if parts.size() >= 5 and parts[0] == "facet" and parts[1] == "normal":
				normal = Vector3(parts[2].to_float(), parts[3].to_float(), parts[4].to_float())
				corners.clear()
			elif parts.size() >= 4 and parts[0] == "vertex":
				corners.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))

				if corners.size() == 3:
					_emit_stl_triangle(st, normal, corners[0], corners[1], corners[2])
					triangle_count += 1
					corners.clear()

	file.close()

	if triangle_count == 0:
		return null

	var mesh := ArrayMesh.new()
	st.commit(mesh)

	var root := Node3D.new()
	root.name = path.get_file().get_basename()
	var instance := MeshInstance3D.new()
	instance.name = "Mesh"
	instance.mesh = mesh
	root.add_child(instance)
	return root


static func _emit_stl_triangle(st: SurfaceTool, normal: Vector3, a: Vector3, b: Vector3, c: Vector3) -> void:
	var face_normal := normal

	if face_normal.length_squared() < 0.0001:
		# STL right-hand rule: (b-a) x (c-a) points outward.
		face_normal = (b - a).cross(c - a).normalized()

	st.set_normal(face_normal)
	st.add_vertex(a)
	st.set_normal(face_normal)
	st.add_vertex(c)
	st.set_normal(face_normal)
	st.add_vertex(b)


# --- Blender ---------------------------------------------------------------------------------

static func find_blender_executable() -> String:
	# 1) A path the user set (persisted in settings.cfg).
	if GameSettings.blender_path != "" and FileAccess.file_exists(GameSettings.blender_path):
		return GameSettings.blender_path

	# 2) On PATH.
	var lookup := "where" if OS.get_name() == "Windows" else "which"
	var output: Array = []

	if OS.execute(lookup, ["blender"], output) == 0 and output.size() > 0:
		var found := String(output[0]).split("\n")[0].strip_edges()

		if found != "" and FileAccess.file_exists(found):
			return found

	# 3) Standard install locations.
	match OS.get_name():
		"Windows":
			for root in ["C:/Program Files/Blender Foundation", "C:/Program Files (x86)/Blender Foundation"]:
				var dir := DirAccess.open(root)

				if dir == null:
					continue

				var versions: Array = []
				dir.list_dir_begin()
				var entry := dir.get_next()

				while entry != "":
					if dir.current_is_dir() and FileAccess.file_exists(root + "/" + entry + "/blender.exe"):
						versions.append(entry)

					entry = dir.get_next()

				dir.list_dir_end()
				versions.sort()

				if not versions.is_empty():
					return root + "/" + versions[versions.size() - 1] + "/blender.exe"
		"macOS":
			var mac_path := "/Applications/Blender.app/Contents/MacOS/Blender"

			if FileAccess.file_exists(mac_path):
				return mac_path
		_:
			for candidate in ["/usr/bin/blender", "/usr/local/bin/blender", "/snap/bin/blender"]:
				if FileAccess.file_exists(candidate):
					return candidate

	return ""


# Runs Blender headless to export the .blend as .glb. Returns {ok, error}.
static func convert_blend_to_glb(blender_path: String, blend_path: String, output_path: String) -> Dictionary:
	var blend_global := ProjectSettings.globalize_path(blend_path).replace("\\", "/")
	var output_global := ProjectSettings.globalize_path(output_path).replace("\\", "/")

	var expression := (
		'import bpy; bpy.ops.export_scene.gltf(filepath="%s", export_format="GLB")' % output_global
	)

	var output: Array = []
	var exit_code := OS.execute(blender_path, ["-b", blend_global, "--python-expr", expression], output, true)

	if exit_code != 0 or not FileAccess.file_exists(output_path):
		var detail := ""

		if output.size() > 0:
			var lines := String(output[0]).split("\n")
			detail = " Blender said: " + lines[maxi(lines.size() - 2, 0)].strip_edges()

		return {"ok": false, "error": "Blender conversion failed (exit code " + str(exit_code) + ")." + detail}

	return {"ok": true, "error": ""}
