extends RefCounted
class_name BevelMesh

# Procedural beveled primitives for the map creator. Godot has no modeling/bevel tool at
# runtime, so these build the geometry directly:
#
#   build_rounded_box     — box whose edges/corners are replaced by a bevel of `radius`;
#                           1 segment = flat chamfer, more = smooth round-over. Implemented
#                           as the Minkowski surface of the inner (shrunk) box and a sphere:
#                           every vertex of a subdivided box is clamped to the inner box and
#                           pushed back out along the exact surface normal, which yields
#                           perfectly flat faces, true arc edges, and analytic smooth normals.
#   build_beveled_cylinder — lathe of a rim-rounded profile (flat caps, arc rims, straight
#                           side), swept around Y.
#
# Both emit clockwise-wound front faces (Godot's convention); the smoke suite cross-checks
# the winding against a built-in BoxMesh so a regression cannot slip in silently.

const MIN_DIMENSION := 0.05
const MAX_SEGMENTS := 8


# A bevel radius is only valid below half the smallest box dimension; callers can clamp
# a user-supplied value with this before generating.
static func max_box_bevel(size: Vector3) -> float:
	return minf(size.x, minf(size.y, size.z)) * 0.5


static func build_rounded_box(size: Vector3, bevel_radius: float, segments: int) -> ArrayMesh:
	var safe_size := Vector3(
		maxf(size.x, MIN_DIMENSION),
		maxf(size.y, MIN_DIMENSION),
		maxf(size.z, MIN_DIMENSION)
	)
	var half := safe_size * 0.5
	var radius: float = clampf(bevel_radius, 0.0, max_box_bevel(safe_size))
	var steps: int = clampi(segments, 1, MAX_SEGMENTS)

	if radius <= 0.0005:
		# No bevel — a plain box mesh is cheaper and exact.
		var plain := BoxMesh.new()
		plain.size = safe_size
		var out := ArrayMesh.new()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plain.get_mesh_arrays())
		return out

	# Inner (core) half extents: the box the bevel sphere rolls around.
	var inner := Vector3(
		maxf(half.x - radius, 0.0),
		maxf(half.y - radius, 0.0),
		maxf(half.z - radius, 0.0)
	)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_surface_tool_vertex_count = 0

	# One subdivided grid per face; the clamp projection turns border bands into the bevel.
	for axis in range(3):
		for sign_value in [1.0, -1.0]:
			_build_rounded_box_face(st, axis, sign_value, half, inner, radius, steps)

	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh


static func _build_rounded_box_face(
	st: SurfaceTool,
	axis: int,
	sign_value: float,
	half: Vector3,
	inner: Vector3,
	radius: float,
	steps: int
) -> void:
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3

	# Negative faces swap u/v so one winding path serves both directions.
	if sign_value < 0.0:
		var swap := u_axis
		u_axis = v_axis
		v_axis = swap

	var u_rows := _band_positions(half[u_axis], inner[u_axis], radius, steps)
	var v_rows := _band_positions(half[v_axis], inner[v_axis], radius, steps)

	# SurfaceTool has no public vertex count; track indices locally instead.
	var start_index := _surface_tool_vertex_count
	var u_count := u_rows.size()
	var v_count := v_rows.size()

	for i in range(u_count):
		for j in range(v_count):
			var point := Vector3.ZERO
			point[axis] = half[axis] * sign_value
			point[u_axis] = u_rows[i]
			point[v_axis] = v_rows[j]

			var core := point.clamp(-inner, inner)
			var offset := point - core
			var normal := offset.normalized()

			if not normal.is_finite() or normal.length_squared() < 0.5:
				normal = Vector3.ZERO
				normal[axis] = sign_value

			var projected := core + normal * radius

			st.set_uv(Vector2(
				(u_rows[i] + half[u_axis]) / maxf(half[u_axis] * 2.0, 0.0001),
				(v_rows[j] + half[v_axis]) / maxf(half[v_axis] * 2.0, 0.0001)
			))
			st.set_normal(normal)
			st.add_vertex(projected)
			_surface_tool_vertex_count += 1

	for i in range(u_count - 1):
		for j in range(v_count - 1):
			var a := start_index + i * v_count + j
			var b := start_index + (i + 1) * v_count + j
			var c := start_index + (i + 1) * v_count + (j + 1)
			var d := start_index + i * v_count + (j + 1)

			# Clockwise front faces (u cross v points outward here).
			st.add_index(a)
			st.add_index(d)
			st.add_index(c)
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)


# SurfaceTool does not expose its vertex count, so the builders above track it manually.
# Reset at the start of every public build call that indexes vertices.
static var _surface_tool_vertex_count: int = 0


# Sample positions across one face axis: an arc-uniform band over each bevel (angle-even
# tan() spacing so the projected arc is evenly tessellated) plus the two flat-region edges.
static func _band_positions(half_extent: float, inner_extent: float, radius: float, steps: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()

	for k in range(steps, -1, -1):
		out.append(-inner_extent - radius * tan(float(k) / float(steps) * PI * 0.25))

	for k in range(0, steps + 1):
		var value := inner_extent + radius * tan(float(k) / float(steps) * PI * 0.25)

		if out.size() > 0 and absf(value - out[out.size() - 1]) < 0.000001:
			continue

		out.append(value)

	return out


static func build_beveled_cylinder(
	radius: float,
	height: float,
	bevel_radius: float,
	segments: int,
	radial_segments: int = 32
) -> ArrayMesh:
	var safe_radius := maxf(radius, MIN_DIMENSION * 0.5)
	var safe_height := maxf(height, MIN_DIMENSION)
	var half_height := safe_height * 0.5
	var rim: float = clampf(bevel_radius, 0.0, minf(safe_radius, half_height) - 0.001)
	var steps: int = clampi(segments, 1, MAX_SEGMENTS)
	var radial: int = clampi(radial_segments, 8, 64)

	if rim <= 0.0005:
		var plain := CylinderMesh.new()
		plain.top_radius = safe_radius
		plain.bottom_radius = safe_radius
		plain.height = safe_height
		plain.radial_segments = radial
		var out := ArrayMesh.new()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plain.get_mesh_arrays())
		return out

	# 2D lathe profile in (rho, y) with matching outward normals, bottom to top.
	var profile_points: Array[Vector2] = []
	var profile_normals: Array[Vector2] = []

	profile_points.append(Vector2(0.0, -half_height))
	profile_normals.append(Vector2(0.0, -1.0))

	profile_points.append(Vector2(safe_radius - rim, -half_height))
	profile_normals.append(Vector2(0.0, -1.0))

	for k in range(1, steps + 1):
		var angle := float(k) / float(steps) * PI * 0.5
		profile_points.append(Vector2(
			(safe_radius - rim) + rim * sin(angle),
			(-half_height + rim) - rim * cos(angle)
		))
		profile_normals.append(Vector2(sin(angle), -cos(angle)))

	profile_points.append(Vector2(safe_radius, half_height - rim))
	profile_normals.append(Vector2(1.0, 0.0))

	for k in range(1, steps + 1):
		var angle := float(k) / float(steps) * PI * 0.5
		profile_points.append(Vector2(
			(safe_radius - rim) + rim * cos(angle),
			(half_height - rim) + rim * sin(angle)
		))
		profile_normals.append(Vector2(cos(angle), sin(angle)))

	profile_points.append(Vector2(0.0, half_height))
	profile_normals.append(Vector2(0.0, 1.0))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_surface_tool_vertex_count = 0
	var start_index := 0

	var ring_count := profile_points.size()
	var column_count := radial + 1

	for ring in range(ring_count):
		for column in range(column_count):
			var sweep := float(column) / float(radial) * TAU
			var cos_s := cos(sweep)
			var sin_s := sin(sweep)
			var rho := profile_points[ring].x
			var y := profile_points[ring].y
			var normal_2d := profile_normals[ring]

			var position := Vector3(rho * cos_s, y, rho * sin_s)
			var normal := Vector3(normal_2d.x * cos_s, normal_2d.y, normal_2d.x * sin_s).normalized()

			st.set_uv(Vector2(float(column) / float(radial), float(ring) / float(ring_count - 1)))
			st.set_normal(normal)
			st.add_vertex(position)
			_surface_tool_vertex_count += 1

	for ring in range(ring_count - 1):
		for column in range(radial):
			var a := start_index + ring * column_count + column
			var b := start_index + ring * column_count + column + 1
			var c := start_index + (ring + 1) * column_count + column + 1
			var d := start_index + (ring + 1) * column_count + column

			# With +Y up, sweeping X toward Z: this order gives clockwise front faces.
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(a)
			st.add_index(c)
			st.add_index(d)

	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh
