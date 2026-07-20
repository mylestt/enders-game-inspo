@tool
extends Node3D
class_name SurfaceGraphBaker

# Drop this node into a map scene (like a NavigationRegion3D), press "Bake Surface Graph" in
# the inspector, and it builds a SurfaceGraph from every StaticBody3D collider under the bake
# root — voxel connectivity + exact collider normals (see SurfaceGraph for why). PLACE THE
# NODE INSIDE THE PLAYABLE SPACE: its own position seeds the interior air-fill, which is how
# an ENCLOSED arena's inside gets recognised as reachable air (spawn-group nodes seed too,
# when present). Custom maps can call bake() from code at load — same pipeline, no button.
#
# The debug view colours each surface cell: GREEN = every seam off this cell is walkable at
# max_walkable_angle_degrees, RED = at least one blocked seam (a wall boundary), ORANGE = an
# open edge with no continuation (a ledge rim). Retuning the angle recolours instantly — the
# angle is a VIEW/RUNTIME threshold, never baked into the data; only geometry/voxel-size
# changes need a rebake.

const STATE_EMPTY := 0
const STATE_SOLID := 1
const STATE_AIR := 2

@export var voxel_size: float = 0.5:
	set(value):
		voxel_size = maxf(value, 0.05)

# View/runtime threshold only (see header) — NOT baked into the graph data.
@export var max_walkable_angle_degrees: float = 80.0:
	set(value):
		max_walkable_angle_degrees = clampf(value, 0.0, 180.0)
		_rebuild_debug_view()

# Root to scan for StaticBody3D colliders. Empty = this node's parent (the map root).
@export var bake_root_path: NodePath = NodePath("")

# Optional bake bounds: a WORLD-AXIS-ALIGNED box of this size centred on this node (shown as
# a cyan wireframe in the editor; keep the node unrotated). ZERO = bake everything. Bounding
# the bake to the PLAYABLE volume is how a huge map affords fine voxels — geometry outside
# is skipped entirely, and cells at the cutoff are never marked as open edges (out-of-bounds
# continuation is unknown, not a void).
@export var bake_bounds_size: Vector3 = Vector3.ZERO:
	set(value):
		bake_bounds_size = value.max(Vector3.ZERO)
		_rebuild_debug_view()

# 0 = accept every collision layer; otherwise only bodies overlapping this mask bake.
@export_flags_3d_physics var collision_mask: int = 0

@export var surface_graph: SurfaceGraph:
	set(value):
		surface_graph = value
		_rebuild_debug_view()

@export var debug_draw: bool = true:
	set(value):
		debug_draw = value
		_rebuild_debug_view()

# The editor always may draw; in a running game the overlay only shows with this ON.
@export var debug_draw_in_game: bool = false

# OFF (default): air floods ONLY from the interior seeds (this node + spawn points), so
# cells exist solely on surfaces REACHABLE from the playable space — an enclosed arena's
# exterior (and any sealed dead space) bakes no cells at all. Turn ON for open maps where
# the space outside the geometry is genuinely playable.
@export var seed_from_grid_corner: bool = false

@export_tool_button("Bake Surface Graph")
var bake_button: Callable = bake

# Guard against absurd grids (tiny voxel on a huge map) before allocating.
const MAX_GRID_VOXELS := 24_000_000
const GRID_PADDING := 2

var _debug_mesh_instance: MeshInstance3D
var _bounds_gizmo_instance: MeshInstance3D

# Working state during a bake (freed after).
var _grid: PackedByteArray
var _grid_size: Vector3i
var _grid_origin: Vector3
var _solid_tri: Dictionary = {}
var _solid_dist: Dictionary = {}


func _ready() -> void:
	# Runtime discovery: the player's movement controller finds the active map's graph
	# through this group (first member wins — one baker per map).
	add_to_group("surface_graph")

	if Engine.is_editor_hint() or debug_draw_in_game:
		_rebuild_debug_view()


func _grid_index(c: Vector3i) -> int:
	return c.x + _grid_size.x * (c.y + _grid_size.y * c.z)


func _in_grid(c: Vector3i) -> bool:
	return (
		c.x >= 0 and c.y >= 0 and c.z >= 0
		and c.x < _grid_size.x and c.y < _grid_size.y and c.z < _grid_size.z
	)


# ---------------------------------------------------------------- bake pipeline


func bake() -> SurfaceGraph:
	var started := Time.get_ticks_msec()
	var stats: Dictionary = {}

	var triangles := collect_collision_triangles()
	stats["triangles"] = triangles.size() / 3
	stats["collect_ms"] = Time.get_ticks_msec() - started

	if triangles.is_empty():
		push_error("SurfaceGraphBaker: no StaticBody3D collision triangles found under the bake root.")
		return null

	var phase := Time.get_ticks_msec()

	if not _setup_grid(triangles):
		return null

	_rasterize_triangles(triangles)
	stats["raster_ms"] = Time.get_ticks_msec() - phase

	phase = Time.get_ticks_msec()
	_flood_fill_air()
	stats["flood_ms"] = Time.get_ticks_msec() - phase

	phase = Time.get_ticks_msec()
	var graph := _extract_graph(triangles)
	stats["cells_links_ms"] = Time.get_ticks_msec() - phase

	stats["total_ms"] = Time.get_ticks_msec() - started
	stats["grid_size"] = _grid_size
	stats["cells"] = graph.cell_count()
	stats["links"] = graph.link_targets.size() / 2

	var open_cells := 0

	for count in graph.open_side_counts:
		if count > 0:
			open_cells += 1

	stats["open_cells"] = open_cells
	stats.merge(graph.bake_stats)   # ambiguous_normals / pruned_dust from extraction
	graph.bake_stats = stats

	# Release working memory.
	_grid = PackedByteArray()
	_solid_tri.clear()
	_solid_dist.clear()

	surface_graph = graph
	print("SurfaceGraphBaker: baked ", stats["cells"], " cells / ", stats["links"], " links in ",
		stats["total_ms"], " ms (grid ", _grid_size, ", ", stats["triangles"], " tris).")
	return graph


# Every collision triangle (world space, flat PackedVector3Array of v0,v1,v2 per tri) from
# StaticBody3D shapes under the bake root. Areas, rigid bodies and disabled shapes are
# skipped — the graph is the STATIC world only.
func collect_collision_triangles() -> PackedVector3Array:
	var root := get_node_or_null(bake_root_path) if bake_root_path != NodePath("") else get_parent()

	if root == null:
		root = self

	var triangles := PackedVector3Array()
	var pending: Array[Node] = [root]
	var skipped_convex := 0

	while not pending.is_empty():
		var node: Node = pending.pop_back()

		for child in node.get_children():
			pending.append(child)

		var shape_node := node as CollisionShape3D

		if shape_node == null or shape_node.disabled or shape_node.shape == null:
			continue

		var body := shape_node.get_parent() as StaticBody3D

		if body == null:
			continue

		if collision_mask != 0 and (body.collision_layer & collision_mask) == 0:
			continue

		var local_faces := _shape_faces(shape_node.shape)

		if local_faces.is_empty():
			if shape_node.shape is ConvexPolygonShape3D:
				skipped_convex += 1
			continue

		var to_world := shape_node.global_transform

		for point in local_faces:
			triangles.append(to_world * point)

	if skipped_convex > 0:
		push_warning("SurfaceGraphBaker: skipped %d ConvexPolygonShape3D(s) — not supported yet." % skipped_convex)

	return triangles


# Local-space triangle soup for a collision shape. Primitives tessellate via their Mesh
# counterparts so curved colliders contribute real curved geometry.
func _shape_faces(shape: Shape3D) -> PackedVector3Array:
	if shape is ConcavePolygonShape3D:
		return (shape as ConcavePolygonShape3D).get_faces()

	if shape is BoxShape3D:
		var box := BoxMesh.new()
		box.size = (shape as BoxShape3D).size
		return box.get_faces()

	if shape is SphereShape3D:
		var sphere := SphereMesh.new()
		sphere.radius = (shape as SphereShape3D).radius
		sphere.height = sphere.radius * 2.0
		sphere.radial_segments = 24
		sphere.rings = 12
		return sphere.get_faces()

	if shape is CylinderShape3D:
		var cyl_shape := shape as CylinderShape3D
		var cyl := CylinderMesh.new()
		cyl.top_radius = cyl_shape.radius
		cyl.bottom_radius = cyl_shape.radius
		cyl.height = cyl_shape.height
		cyl.radial_segments = 24
		return cyl.get_faces()

	if shape is CapsuleShape3D:
		var cap_shape := shape as CapsuleShape3D
		var cap := CapsuleMesh.new()
		cap.radius = cap_shape.radius
		cap.height = cap_shape.height
		cap.radial_segments = 24
		cap.rings = 8
		return cap.get_faces()

	return PackedVector3Array()


func _setup_grid(triangles: PackedVector3Array) -> bool:
	var aabb := AABB(triangles[0], Vector3.ZERO)

	for point in triangles:
		aabb = aabb.expand(point)

	if bake_bounds_size != Vector3.ZERO:
		var bounds := AABB(global_position - bake_bounds_size * 0.5, bake_bounds_size)
		aabb = aabb.intersection(bounds)

		if not aabb.has_volume():
			push_error("SurfaceGraphBaker: bake_bounds does not overlap any collision geometry.")
			return false

	_grid_origin = aabb.position - Vector3.ONE * (voxel_size * GRID_PADDING)
	var span := aabb.size + Vector3.ONE * (voxel_size * GRID_PADDING * 2.0)
	_grid_size = Vector3i(
		ceili(span.x / voxel_size) + 1,
		ceili(span.y / voxel_size) + 1,
		ceili(span.z / voxel_size) + 1
	)

	var total := _grid_size.x * _grid_size.y * _grid_size.z

	if total > MAX_GRID_VOXELS:
		push_error("SurfaceGraphBaker: grid %s = %d voxels exceeds %d — raise voxel_size." % [
			_grid_size, total, MAX_GRID_VOXELS])
		return false

	_grid = PackedByteArray()
	_grid.resize(total)
	_solid_tri.clear()
	_solid_dist.clear()
	return true


# Conservative rasterization: triangles are recursively bisected until small, then each
# leaf's few candidate voxels are tested by exact point-to-triangle distance. Every solid
# voxel remembers its NEAREST original triangle — that triangle's plane provides the cell's
# exact normal and surface point later.
func _rasterize_triangles(triangles: PackedVector3Array) -> void:
	var tri_count := triangles.size() / 3
	var max_edge := voxel_size * 2.0
	var half_diagonal := voxel_size * 0.8660254  # sqrt(3)/2: centre-to-corner of a voxel
	var grid_min := _grid_origin
	var grid_max := _grid_origin + Vector3(_grid_size) * voxel_size

	for tri_index in range(tri_count):
		var a := triangles[tri_index * 3]
		var b := triangles[tri_index * 3 + 1]
		var c := triangles[tri_index * 3 + 2]

		# Whole-triangle early out: outside the (possibly bounds-clipped) grid entirely.
		if (
			maxf(a.x, maxf(b.x, c.x)) < grid_min.x or minf(a.x, minf(b.x, c.x)) > grid_max.x
			or maxf(a.y, maxf(b.y, c.y)) < grid_min.y or minf(a.y, minf(b.y, c.y)) > grid_max.y
			or maxf(a.z, maxf(b.z, c.z)) < grid_min.z or minf(a.z, minf(b.z, c.z)) > grid_max.z
		):
			continue

		# Iterative longest-edge bisection: work stack of sub-triangles.
		var stack: Array = [[a, b, c]]

		while not stack.is_empty():
			var tri: Array = stack.pop_back()
			var p0: Vector3 = tri[0]
			var p1: Vector3 = tri[1]
			var p2: Vector3 = tri[2]

			var e01 := p0.distance_squared_to(p1)
			var e12 := p1.distance_squared_to(p2)
			var e20 := p2.distance_squared_to(p0)
			var longest := maxf(e01, maxf(e12, e20))

			if longest > max_edge * max_edge:
				if e01 >= e12 and e01 >= e20:
					var mid := (p0 + p1) * 0.5
					stack.append([p0, mid, p2])
					stack.append([mid, p1, p2])
				elif e12 >= e20:
					var mid := (p1 + p2) * 0.5
					stack.append([p1, mid, p0])
					stack.append([mid, p2, p0])
				else:
					var mid := (p2 + p0) * 0.5
					stack.append([p2, mid, p1])
					stack.append([mid, p0, p1])
				continue

			# Leaf: test the few voxels around its AABB against the ORIGINAL triangle.
			var lo := Vector3(
				minf(p0.x, minf(p1.x, p2.x)),
				minf(p0.y, minf(p1.y, p2.y)),
				minf(p0.z, minf(p1.z, p2.z))
			)
			var hi := Vector3(
				maxf(p0.x, maxf(p1.x, p2.x)),
				maxf(p0.y, maxf(p1.y, p2.y)),
				maxf(p0.z, maxf(p1.z, p2.z))
			)
			var lo_v := Vector3i(
				maxi(floori((lo.x - _grid_origin.x) / voxel_size) - 1, 0),
				maxi(floori((lo.y - _grid_origin.y) / voxel_size) - 1, 0),
				maxi(floori((lo.z - _grid_origin.z) / voxel_size) - 1, 0)
			)
			var hi_v := Vector3i(
				mini(floori((hi.x - _grid_origin.x) / voxel_size) + 1, _grid_size.x - 1),
				mini(floori((hi.y - _grid_origin.y) / voxel_size) + 1, _grid_size.y - 1),
				mini(floori((hi.z - _grid_origin.z) / voxel_size) + 1, _grid_size.z - 1)
			)

			for x in range(lo_v.x, hi_v.x + 1):
				for y in range(lo_v.y, hi_v.y + 1):
					for z in range(lo_v.z, hi_v.z + 1):
						var coord := Vector3i(x, y, z)
						var centre := _grid_origin + (Vector3(coord) + Vector3.ONE * 0.5) * voxel_size
						var closest := _closest_point_on_triangle(centre, a, b, c)
						var distance := centre.distance_to(closest)

						if distance > half_diagonal:
							continue

						var flat := _grid_index(coord)
						_grid[flat] = STATE_SOLID

						if distance < float(_solid_dist.get(flat, INF)):
							_solid_dist[flat] = distance
							_solid_tri[flat] = tri_index


# Mark REACHABLE empty voxels as air: BFS from the interior seeds — this node's own
# position and any spawn-group node — plus (only if seed_from_grid_corner) a padded-corner
# voxel for everything outside the map. Unreached empty voxels (exterior of an enclosed
# arena, inside thick solids, sealed dead space) stay EMPTY and never produce cells.
func _flood_fill_air() -> void:
	var queue := PackedInt32Array()
	var seeds: Array[Vector3i] = [_world_to_voxel_grid(global_position)]

	if seed_from_grid_corner:
		seeds.append(Vector3i.ZERO)

	var tree := get_tree()

	if tree != null:
		for group in ["spawn_team_a", "spawn_team_b"]:
			for node in tree.get_nodes_in_group(group):
				if node is Node3D:
					seeds.append(_world_to_voxel_grid((node as Node3D).global_position))

	for seed in seeds:
		if not _in_grid(seed):
			continue

		var flat := _grid_index(seed)

		if _grid[flat] == STATE_EMPTY:
			_grid[flat] = STATE_AIR
			queue.append(flat)

	var sx := _grid_size.x
	var sy := _grid_size.y
	var sz := _grid_size.z
	var stride_z := sx * sy
	var head := 0

	while head < queue.size():
		var flat := queue[head]
		head += 1

		var x := flat % sx
		var y := (flat / sx) % sy
		var z := flat / stride_z

		# Six neighbours, unrolled with bounds checks.
		if x > 0 and _grid[flat - 1] == STATE_EMPTY:
			_grid[flat - 1] = STATE_AIR
			queue.append(flat - 1)
		if x < sx - 1 and _grid[flat + 1] == STATE_EMPTY:
			_grid[flat + 1] = STATE_AIR
			queue.append(flat + 1)
		if y > 0 and _grid[flat - sx] == STATE_EMPTY:
			_grid[flat - sx] = STATE_AIR
			queue.append(flat - sx)
		if y < sy - 1 and _grid[flat + sx] == STATE_EMPTY:
			_grid[flat + sx] = STATE_AIR
			queue.append(flat + sx)
		if z > 0 and _grid[flat - stride_z] == STATE_EMPTY:
			_grid[flat - stride_z] = STATE_AIR
			queue.append(flat - stride_z)
		if z < sz - 1 and _grid[flat + stride_z] == STATE_EMPTY:
			_grid[flat + stride_z] = STATE_AIR
			queue.append(flat + stride_z)


func _world_to_voxel_grid(world_position: Vector3) -> Vector3i:
	var local := (world_position - _grid_origin) / voxel_size
	return Vector3i(floori(local.x), floori(local.y), floori(local.z))


const AXIS_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


# Surface cells (solid voxels touching air), exact normals/positions from their nearest
# triangle, adjacency through shared airspace, open-edge counts — assembled into the
# SurfaceGraph resource.
func _extract_graph(triangles: PackedVector3Array) -> SurfaceGraph:
	var graph := SurfaceGraph.new()
	graph.voxel_size = voxel_size
	graph.grid_origin = _grid_origin
	graph.grid_size = _grid_size

	# Pass 1+2: surface cells with positions and normals. A solid voxel touching air spawns
	# ONE CELL PER AIR SIDE of its nearest triangle's plane: thin-shell geometry (a
	# zero-thickness wall with reachable air on both faces) gets a correctly-oriented cell
	# for EACH side, instead of one cell whose facing is a winding coin-flip (which
	# back-face culling exposed as walls vanishing from inside). Solid-volume surfaces have
	# air on one side only and bake exactly as before.
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var cell_voxels: Array[Vector3i] = []
	var cell_plus: Dictionary = {}    # flat -> cell index on the winding-normal side
	var cell_minus: Dictionary = {}   # flat -> cell index on the opposite side
	var two_sided := 0
	var ambiguous_normals := 0

	for flat in _solid_tri.keys():
		var coord := _flat_to_coord(flat)
		var tri_index: int = _solid_tri[flat]
		var a := triangles[tri_index * 3]
		var b := triangles[tri_index * 3 + 1]
		var c := triangles[tri_index * 3 + 2]
		var centre := _grid_origin + (Vector3(coord) + Vector3.ONE * 0.5) * voxel_size
		var winding_normal := (b - a).cross(c - a)
		winding_normal = winding_normal.normalized() if winding_normal.length() > 0.0001 else Vector3.UP
		var surface_point := _closest_point_on_triangle(centre, a, b, c)

		var has_plus := false
		var has_minus := false
		var air_sum := Vector3.ZERO

		for dir in AXIS_DIRS:
			var n := coord + dir

			if not (_in_grid(n) and _grid[_grid_index(n)] == STATE_AIR):
				continue

			air_sum += Vector3(dir)
			var side := winding_normal.dot(Vector3(dir))

			if side > 0.25:
				has_plus = true
			elif side < -0.25:
				has_minus = true

		if not has_plus and not has_minus:
			if air_sum == Vector3.ZERO:
				continue   # no air at all: not a surface voxel

			# Only in-plane air (a crack or edge sliver): one cell, oriented toward the air.
			ambiguous_normals += 1
			var fallback := winding_normal if winding_normal.dot(air_sum) >= 0.0 else -winding_normal
			cell_plus[flat] = positions.size()
			positions.append(surface_point)
			normals.append(fallback)
			cell_voxels.append(coord)
			continue

		if has_plus:
			cell_plus[flat] = positions.size()
			positions.append(surface_point)
			normals.append(winding_normal)
			cell_voxels.append(coord)

		if has_minus:
			cell_minus[flat] = positions.size()
			positions.append(surface_point)
			normals.append(-winding_normal)
			cell_voxels.append(coord)

		if has_plus and has_minus:
			two_sided += 1

	# Pass 3: links. Two cells connect only through SHARED AIRSPACE that lies on BOTH cells'
	# OWN sides — so the two faces of a thin wall never link (their air is on opposite
	# sides), while a floor seam, a concave corner, and a convex 90-degree corner all link
	# through the air you actually traverse. The two cells of one voxel are never linked.
	var cell_total := positions.size()
	var neighbour_lists: Array = []
	neighbour_lists.resize(cell_total)

	for i in range(cell_total):
		neighbour_lists[i] = PackedInt32Array()

	var open_sides := PackedInt32Array()
	open_sides.resize(cell_total)

	for i in range(cell_total):
		var ca := cell_voxels[i]
		var n_a := normals[i]

		# Axis neighbours.
		for dir in AXIS_DIRS:
			var cb := ca + dir

			if not _in_grid(cb):
				continue

			var flat_b := _grid_index(cb)

			for j in [cell_plus.get(flat_b, -1), cell_minus.get(flat_b, -1)]:
				if j <= i:   # covers the -1 misses and de-dupes the pair
					continue

				if _share_perpendicular_air_sided(ca, cb, dir, n_a, normals[j]):
					neighbour_lists[i].append(j)
					neighbour_lists[j].append(i)

		# Edge-diagonal neighbours (two non-zero components): linked through the corner air
		# completing the 2x2 square, which must also lie on both cells' own sides.
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var nonzero := int(dx != 0) + int(dy != 0) + int(dz != 0)

					if nonzero != 2:
						continue

					var delta := Vector3i(dx, dy, dz)
					var cb := ca + delta

					if not _in_grid(cb):
						continue

					var flat_b := _grid_index(cb)

					for j in [cell_plus.get(flat_b, -1), cell_minus.get(flat_b, -1)]:
						if j <= i:
							continue

						var n_b: Vector3 = normals[j]
						var linked := false

						var comp_first := _first_component(delta)

						for comp: Vector3i in [comp_first, delta - comp_first]:
							var corner := ca + comp

							if not _voxel_is_air(corner):
								continue

							var from_a := Vector3(comp).normalized()
							var from_b := Vector3(corner - cb)

							if from_b.length() > 0.01:
								from_b = from_b.normalized()

							if from_a.dot(n_a) > -0.35 and from_b.dot(n_b) > -0.35:
								linked = true
								break

						if linked:
							neighbour_lists[i].append(j)
							neighbour_lists[j].append(i)

		# Open sides: a tangent-ish air direction with NO surface continuation anywhere in
		# the air voxel's full 26-neighbourhood — the surface truly ENDS there (a void).
		# A surface that exists but is too steep shows as a RED link instead, and cells at
		# the bake-bounds cutoff are never marked (out-of-bounds continuation is unknown,
		# not void) — so clipping can't paint false orange rims.
		var normal := normals[i]
		var open_count := 0

		for dir in AXIS_DIRS:
			if absf(normal.dot(Vector3(dir))) > 0.7:
				continue

			var air_coord := ca + dir

			if not _voxel_is_air(air_coord):
				continue

			if _near_grid_edge(air_coord):
				continue

			var continues := false

			for dx2 in [-1, 0, 1]:
				for dy2 in [-1, 0, 1]:
					for dz2 in [-1, 0, 1]:
						var around := air_coord + Vector3i(dx2, dy2, dz2)

						if around == ca or around == air_coord or not _in_grid(around):
							continue

						var around_flat := _grid_index(around)

						if cell_plus.has(around_flat) or cell_minus.has(around_flat):
							continues = true
							break

					if continues:
						break

				if continues:
					break

			if not continues:
				open_count += 1

		open_sides[i] = open_count

	# Prune isolated dust: a cell with ZERO links (a sub-voxel sliver nothing connects to)
	# is unusable by any runtime and pure noise in the overlay. Targets always point at
	# linked cells, so a remapped target can never be -1.
	var remap := PackedInt32Array()
	remap.resize(cell_total)
	var kept := 0

	for i in range(cell_total):
		if (neighbour_lists[i] as PackedInt32Array).size() > 0:
			remap[i] = kept
			kept += 1
		else:
			remap[i] = -1

	var pruned := cell_total - kept

	# CSR flatten over the kept cells.
	var kept_positions := PackedVector3Array()
	var kept_normals := PackedVector3Array()
	var kept_coords := PackedInt32Array()
	var kept_open := PackedInt32Array()
	var starts := PackedInt32Array()
	var targets := PackedInt32Array()
	starts.resize(kept + 1)
	var running := 0

	for i in range(cell_total):
		if remap[i] < 0:
			continue

		starts[remap[i]] = running
		var list: PackedInt32Array = neighbour_lists[i]
		running += list.size()

		for target in list:
			targets.append(remap[target])

		kept_positions.append(positions[i])
		kept_normals.append(normals[i])
		kept_coords.append(cell_voxels[i].x)
		kept_coords.append(cell_voxels[i].y)
		kept_coords.append(cell_voxels[i].z)
		kept_open.append(open_sides[i])

	starts[kept] = running

	graph.cell_positions = kept_positions
	graph.cell_normals = kept_normals
	graph.cell_coords = kept_coords
	graph.link_starts = starts
	graph.link_targets = targets
	graph.open_side_counts = kept_open
	graph.bake_stats = {
		"ambiguous_normals": ambiguous_normals,
		"pruned_dust": pruned,
		"two_sided_voxels": two_sided,
	}
	return graph


func _flat_to_coord(flat: int) -> Vector3i:
	var sx := _grid_size.x
	var stride_z := sx * _grid_size.y
	return Vector3i(flat % sx, (flat / sx) % _grid_size.y, flat / stride_z)


func _voxel_is_air(coord: Vector3i) -> bool:
	return _in_grid(coord) and _grid[_grid_index(coord)] == STATE_AIR


# Within a voxel of the grid boundary — where "no continuation" may just mean "clipped by
# the bake bounds", so open-edge marking is suppressed.
func _near_grid_edge(c: Vector3i) -> bool:
	return (
		c.x <= 1 or c.y <= 1 or c.z <= 1
		or c.x >= _grid_size.x - 2 or c.y >= _grid_size.y - 2 or c.z >= _grid_size.z - 2
	)


func _first_component(delta: Vector3i) -> Vector3i:
	if delta.x != 0:
		return Vector3i(delta.x, 0, 0)

	if delta.y != 0:
		return Vector3i(0, delta.y, 0)

	return Vector3i(0, 0, delta.z)


# Shared perpendicular air that lies on BOTH cells' own sides (dot with each cell's normal
# not opposing) — flat floors pass via the air above, thin-wall opposite faces never pass.
func _share_perpendicular_air_sided(
	ca: Vector3i,
	cb: Vector3i,
	axis: Vector3i,
	n_a: Vector3,
	n_b: Vector3
) -> bool:
	for dir in AXIS_DIRS:
		if dir == axis or dir == -axis:
			continue

		if not (_voxel_is_air(ca + dir) and _voxel_is_air(cb + dir)):
			continue

		var d := Vector3(dir)

		if d.dot(n_a) > -0.35 and d.dot(n_b) > -0.35:
			return true

	return false


# Closest point on triangle abc to p (Ericson, Real-Time Collision Detection).
func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)

	if d1 <= 0.0 and d2 <= 0.0:
		return a

	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)

	if d3 >= 0.0 and d4 <= d3:
		return b

	var vc := d1 * d4 - d3 * d2

	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))

	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)

	if d6 >= 0.0 and d5 <= d6:
		return c

	var vb := d5 * d2 - d1 * d6

	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))

	var va := d3 * d6 - d5 * d4

	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))

	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


# ---------------------------------------------------------------- debug view


func _rebuild_debug_view() -> void:
	if not is_inside_tree():
		return

	if not (Engine.is_editor_hint() or debug_draw_in_game):
		return

	if _debug_mesh_instance != null:
		_debug_mesh_instance.queue_free()
		_debug_mesh_instance = null

	# The bounds box draws even with no graph yet — you position it before the first bake.
	_rebuild_bounds_gizmo()

	if not debug_draw or surface_graph == null or surface_graph.cell_count() == 0:
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var graph := surface_graph
	var half := graph.voxel_size * 0.4

	for i in range(graph.cell_count()):
		var colour := Color(0.2, 0.9, 0.3, 0.85)

		if graph.open_side_counts[i] > 0:
			colour = Color(1.0, 0.55, 0.1, 0.9)
		else:
			for j in graph.get_cell_links(i):
				if not graph.is_link_walkable(i, j, max_walkable_angle_degrees):
					colour = Color(0.9, 0.15, 0.15, 0.9)
					break

		var normal := graph.cell_normals[i]
		var tangent := normal.cross(Vector3.UP)

		if tangent.length() < 0.01:
			tangent = normal.cross(Vector3.RIGHT)

		tangent = tangent.normalized() * half
		var bitangent := normal.cross(tangent).normalized() * half
		# Lifted off the surface enough to clear z-fighting at map scale.
		var centre := graph.cell_positions[i] + normal * 0.05

		var p0 := centre - tangent - bitangent
		var p1 := centre + tangent - bitangent
		var p2 := centre + tangent + bitangent
		var p3 := centre - tangent + bitangent

		# Godot front faces are CLOCKWISE (verified against BoxMesh: a +Y-facing face has
		# right-hand-rule normal -Y), so wind the quad so its RH-rule normal is -normal —
		# the rendered FRONT then faces +normal, the side you stand on.
		st.set_color(colour)
		st.set_normal(normal)
		st.add_vertex(p0)
		st.add_vertex(p2)
		st.add_vertex(p1)
		st.add_vertex(p0)
		st.add_vertex(p3)
		st.add_vertex(p2)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Back-face culling: quads face along their surface normal, so surfaces pointing away
	# (e.g. a wall's far side) don't bleed through and clutter the view.
	material.cull_mode = BaseMaterial3D.CULL_BACK

	var mesh := st.commit()
	mesh.surface_set_material(0, material)

	_debug_mesh_instance = MeshInstance3D.new()
	_debug_mesh_instance.mesh = mesh
	_debug_mesh_instance.top_level = true
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Unowned child (never saved into the scene) — same pattern as the force-field gizmo.
	add_child(_debug_mesh_instance)
	_debug_mesh_instance.global_transform = Transform3D.IDENTITY


# Cyan wireframe showing bake_bounds. A LOCAL-space child (follows the node as you move it);
# the bake itself uses the node's world position, so keep the node unrotated.
func _rebuild_bounds_gizmo() -> void:
	if _bounds_gizmo_instance != null:
		_bounds_gizmo_instance.queue_free()
		_bounds_gizmo_instance = null

	if bake_bounds_size == Vector3.ZERO:
		return

	var half := bake_bounds_size * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	st.set_color(Color(0.2, 0.9, 1.0))

	var corners: Array[Vector3] = []

	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				corners.append(Vector3(half.x * sx, half.y * sy, half.z * sz))

	# The 12 box edges: corner pairs differing in exactly one axis sign.
	for i in range(corners.size()):
		for j in range(i + 1, corners.size()):
			var diff := corners[i] - corners[j]
			var changed := int(absf(diff.x) > 0.01) + int(absf(diff.y) > 0.01) + int(absf(diff.z) > 0.01)

			if changed == 1:
				st.add_vertex(corners[i])
				st.add_vertex(corners[j])

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	var mesh := st.commit()
	mesh.surface_set_material(0, material)

	_bounds_gizmo_instance = MeshInstance3D.new()
	_bounds_gizmo_instance.mesh = mesh
	_bounds_gizmo_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bounds_gizmo_instance)
