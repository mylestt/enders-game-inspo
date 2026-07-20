@tool
extends Resource
class_name SurfaceGraph

# Baked walkable-surface graph (built by SurfaceGraphBaker, consumed by the surface-walk
# runtime). VOXELS establish which surfaces exist and which connect — robust to maps built
# from many DISCONNECTED objects (flush boxes weld, a wall rising mid-floor blocks, a real
# gap reads as an open edge) because connectivity is sampled from space, never from shared
# vertices. Each cell's stored normal is sampled from the REAL collider triangle nearest
# that voxel, so orientation is exact — a 45-degree ramp reads 45 degrees, never voxel
# stair-steps.
#
# Only GEOMETRY is stored. The walkable-angle threshold is applied per query
# (is_link_walkable), so retuning the angle reclassifies instantly — NO rebake. Rebaking is
# only needed when collision geometry or voxel size changes.

@export var voxel_size: float = 0.5
@export var grid_origin: Vector3 = Vector3.ZERO
@export var grid_size: Vector3i = Vector3i.ZERO

# Per cell: exact surface point, exact surface normal, voxel coord (flat x,y,z triplets).
@export var cell_positions: PackedVector3Array = PackedVector3Array()
@export var cell_normals: PackedVector3Array = PackedVector3Array()
@export var cell_coords: PackedInt32Array = PackedInt32Array()

# CSR adjacency: neighbours of cell i are link_targets[link_starts[i] .. link_starts[i + 1]).
@export var link_starts: PackedInt32Array = PackedInt32Array()
@export var link_targets: PackedInt32Array = PackedInt32Array()

# Per cell: tangent sides with NO surface continuation (> 0 = candidate ledge rim).
@export var open_side_counts: PackedInt32Array = PackedInt32Array()

@export var bake_stats: Dictionary = {}

# Voxel-coord -> Array of cell indices (thin-shell voxels carry one cell PER SIDE), rebuilt
# on demand (derived data, never serialized).
var _lookup: Dictionary = {}
var _lookup_built := false


func cell_count() -> int:
	return cell_positions.size()


func cell_coord(index: int) -> Vector3i:
	var base := index * 3
	return Vector3i(cell_coords[base], cell_coords[base + 1], cell_coords[base + 2])


func get_cell_links(index: int) -> PackedInt32Array:
	return link_targets.slice(link_starts[index], link_starts[index + 1])


func link_angle_degrees(a: int, b: int) -> float:
	return rad_to_deg(cell_normals[a].angle_to(cell_normals[b]))


# THE walkable gate. Evaluated live against stored normals — changing the threshold never
# needs a rebake.
func is_link_walkable(a: int, b: int, max_walkable_angle_degrees: float) -> bool:
	return link_angle_degrees(a, b) <= max_walkable_angle_degrees


func build_lookup() -> void:
	_lookup.clear()

	for i in range(cell_count()):
		var key := cell_coord(i)

		if _lookup.has(key):
			(_lookup[key] as Array).append(i)
		else:
			_lookup[key] = [i]

	_lookup_built = true


# First cell at a voxel (a thin-shell voxel may have two — see cells_at).
func cell_at(coord: Vector3i) -> int:
	if not _lookup_built:
		build_lookup()

	var bucket = _lookup.get(coord, null)
	return -1 if bucket == null else bucket[0]


func cells_at(coord: Vector3i) -> Array:
	if not _lookup_built:
		build_lookup()

	return _lookup.get(coord, [])


func world_to_voxel(world_position: Vector3) -> Vector3i:
	var local := (world_position - grid_origin) / maxf(voxel_size, 0.0001)
	return Vector3i(floori(local.x), floori(local.y), floori(local.z))


# Nearest cell to a world position, searching outward ring by ring. The radius is METRES
# (converted to voxel rings internally), so callers are independent of the bake resolution.
# Returns -1 if none within range.
func find_nearest_cell(world_position: Vector3, max_radius_m: float = 2.0) -> int:
	if not _lookup_built:
		build_lookup()

	var max_radius_voxels := maxi(ceili(max_radius_m / maxf(voxel_size, 0.0001)), 1)
	var centre := world_to_voxel(world_position)
	var best := -1
	var best_distance := INF

	for radius in range(max_radius_voxels + 1):
		for x in range(-radius, radius + 1):
			for y in range(-radius, radius + 1):
				for z in range(-radius, radius + 1):
					if maxi(maxi(absi(x), absi(y)), absi(z)) != radius:
						continue

					var bucket = _lookup.get(centre + Vector3i(x, y, z), null)

					if bucket == null:
						continue

					for idx in bucket:
						var d := cell_positions[idx].distance_squared_to(world_position)

						if d < best_distance:
							best_distance = d
							best = idx

		# A hit in this ring can't be beaten badly enough by outer rings to matter for a
		# spawn/ground lookup — stop at the first ring that found anything.
		if best >= 0:
			return best

	return best


# Link classification counts at a threshold: {walkable, blocked, total}. Cheap (one angle
# per stored link) — this is the "retune without rebake" pass.
func classify_all_links(max_walkable_angle_degrees: float) -> Dictionary:
	var walkable := 0
	var blocked := 0

	for i in range(cell_count()):
		for j in get_cell_links(i):
			if j <= i:
				continue

			if is_link_walkable(i, j, max_walkable_angle_degrees):
				walkable += 1
			else:
				blocked += 1

	return {"walkable": walkable, "blocked": blocked, "total": walkable + blocked}
