class_name WeaponHitscanTracerEffect
extends Node3D

# Short-lived world-space hitscan shot effect: a jagged multi-strand streak whose visible
# span travels muzzle -> impact, plus impact sparks on hit. Muzzle flashes are NOT part of
# this effect — each gun has its own WeaponMuzzleFlash scene (see Weapon.muzzle_flash_scene).
#
# All geometry is built ONCE per shot; every frame after that only writes a few
# per-instance shader uniforms and a node scale. The old implementation re-committed
# SurfaceTool meshes per tracer per frame, which multiplied badly under minigun
# fire. One ShaderMaterial (shaders/tracer_streak.gdshader) is shared by every tracer in
# the game — instance uniforms keep each effect's animation independent.

const STREAK_SHADER := preload("res://shaders/tracer_streak.gdshader")

@export_group("Tracer")
@export var visual_speed: float = 900.0
@export var min_travel_time: float = 0.018
@export var max_travel_time: float = 0.055
@export var fade_time: float = 0.08
@export var max_visible_length: float = 28.0
@export var tracer_width: float = 0.035
@export var jagged_radius: float = 0.22
@export_range(1, 18, 1) var segment_count: int = 9
@export_range(1, 4, 1) var strand_count: int = 2
@export var tail_width_multiplier: float = 0.18
@export var tracer_color: Color = Color(1.0, 0.68, 0.15, 0.9)
@export var tracer_emission_energy: float = 7.0
# Hot leading edge: extra emission within this many metres of the streak head. 0 = off.
@export var head_glow_length: float = 1.4
@export var head_glow_boost: float = 2.2

@export_group("Impact Spark")
@export var impact_spark_enabled: bool = true
@export var impact_spark_time: float = 0.09
@export_range(1, 24, 1) var impact_spark_count: int = 8
@export var impact_spark_length: float = 0.45
@export var impact_spark_width: float = 0.018
@export var impact_spark_color: Color = Color(1.0, 0.52, 0.12, 0.8)
@export var impact_spark_emission_energy: float = 6.5

var tracer_mesh: MeshInstance3D
var impact_spark_mesh: MeshInstance3D

var shot_distance: float = 0.0
var hit_something: bool = false
var elapsed: float = 0.0
var travel_time: float = 0.035
var effect_end_time: float = 0.1
var initialized: bool = false

# One material for every tracer instance in the game; per-instance uniforms carry all
# animation state (same shared-material pattern as the death glow / team indicators).
static var _shared_material: ShaderMaterial


static func get_shared_material() -> ShaderMaterial:
	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		_shared_material.shader = STREAK_SHADER

	return _shared_material


func _ready() -> void:
	ensure_visual_nodes()
	set_process(initialized)


func play(
	start_position: Vector3,
	end_position: Vector3,
	did_hit: bool,
	normal: Vector3
) -> void:
	ensure_visual_nodes()

	var shot_vector := end_position - start_position

	if shot_vector.length() < 0.001:
		queue_free()
		return

	hit_something = did_hit
	shot_distance = shot_vector.length()
	travel_time = clampf(
		shot_distance / maxf(visual_speed, 0.001),
		min_travel_time,
		max_travel_time
	)
	elapsed = 0.0
	effect_end_time = travel_time + maxf(fade_time, impact_spark_time if did_hit else 0.0)
	initialized = true
	global_transform = get_transform_from_shot(start_position, shot_vector.normalized())

	build_streak_mesh()
	build_impact_spark_mesh(normal)

	set_process(true)
	update_animation()


func _process(delta: float) -> void:
	if not initialized:
		return

	elapsed += delta
	update_animation()

	if elapsed >= effect_end_time:
		queue_free()


# The whole per-frame cost: a handful of instance uniforms and two node scales.
func update_animation() -> void:
	var head_distance := shot_distance * get_travel_ratio()
	var tail_distance := 0.0

	if max_visible_length > 0.0:
		tail_distance = maxf(head_distance - max_visible_length, 0.0)

	var fade := get_fade_alpha()

	tracer_mesh.visible = fade > 0.0
	tracer_mesh.set_instance_shader_parameter(&"head_distance", head_distance)
	tracer_mesh.set_instance_shader_parameter(&"tail_distance", tail_distance)
	tracer_mesh.set_instance_shader_parameter(&"fade_alpha", fade)

	update_impact_sparks()


func update_impact_sparks() -> void:
	if not impact_spark_enabled or not hit_something:
		return

	var impact_elapsed := elapsed - travel_time

	if impact_elapsed < 0.0:
		impact_spark_mesh.visible = false
		return

	var spark_alpha := clampf(1.0 - impact_elapsed / maxf(impact_spark_time, 0.001), 0.0, 1.0)

	if spark_alpha <= 0.0:
		impact_spark_mesh.visible = false
		return

	impact_spark_mesh.visible = true
	impact_spark_mesh.scale = Vector3.ONE * maxf(spark_alpha, 0.001)
	impact_spark_mesh.set_instance_shader_parameter(&"fade_alpha", spark_alpha)


func get_transform_from_shot(start_position: Vector3, direction: Vector3) -> Transform3D:
	var up := Vector3.UP

	if absf(direction.dot(up)) > 0.98:
		up = Vector3.RIGHT

	var right := up.cross(direction).normalized()
	var corrected_up := direction.cross(right).normalized()
	return Transform3D(Basis(right, corrected_up, direction), start_position)


func get_travel_ratio() -> float:
	var raw_ratio := clampf(elapsed / maxf(travel_time, 0.001), 0.0, 1.0)
	return 1.0 - pow(1.0 - raw_ratio, 2.0)


func get_fade_alpha() -> float:
	if elapsed <= travel_time:
		return 1.0

	return clampf(1.0 - (elapsed - travel_time) / maxf(fade_time, 0.001), 0.0, 1.0)


# --- One-time geometry builds ---------------------------------------------------------
# Local +Z runs along the shot. UV.x carries each vertex's distance (metres) along the
# shot so the shader can slide the visible window; vertex COLOR carries the tint.

func build_streak_mesh() -> void:
	var surface_tool := SurfaceTool.new()
	var point_count := maxi(segment_count + 1, 2)

	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	for strand_index in range(maxi(strand_count, 1)):
		var points := build_strand_points(strand_index, point_count)
		add_strand_to_surface(surface_tool, points, Vector3.RIGHT)
		add_strand_to_surface(surface_tool, points, Vector3.UP)

	tracer_mesh.mesh = surface_tool.commit()
	tracer_mesh.set_instance_shader_parameter(&"emission_energy", tracer_emission_energy)
	tracer_mesh.set_instance_shader_parameter(&"head_glow_length", head_glow_length)
	tracer_mesh.set_instance_shader_parameter(&"head_glow_boost", head_glow_boost)


func build_strand_points(strand_index: int, point_count: int) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var strand_phase := float(strand_index) / maxf(float(strand_count), 1.0)
	var strand_center := Vector2(
		cos(strand_phase * TAU),
		sin(strand_phase * TAU)
	) * tracer_width * 0.8

	for point_index in range(point_count):
		var ratio := float(point_index) / maxf(float(point_count - 1), 1.0)
		var z_distance := shot_distance * ratio
		var offset := strand_center

		# End points stay on the shot line so the streak starts at the muzzle and ends
		# exactly at the impact; middle points scatter for the jagged-energy look.
		if point_index != 0 and point_index != point_count - 1:
			offset += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * (
				sin(ratio * PI) * jagged_radius
			)

		points.append(Vector3(offset.x, offset.y, z_distance))

	return points


func add_strand_to_surface(
	surface_tool: SurfaceTool,
	points: Array[Vector3],
	width_axis: Vector3
) -> void:
	for point_index in range(points.size() - 1):
		var start_ratio := float(point_index) / maxf(float(points.size() - 1), 1.0)
		var end_ratio := float(point_index + 1) / maxf(float(points.size() - 1), 1.0)

		add_ribbon_segment(
			surface_tool,
			points[point_index],
			points[point_index + 1],
			width_axis,
			get_width_at_ratio(start_ratio),
			get_width_at_ratio(end_ratio)
		)


func add_ribbon_segment(
	surface_tool: SurfaceTool,
	start: Vector3,
	end: Vector3,
	width_axis: Vector3,
	start_width: float,
	end_width: float
) -> void:
	var start_a := start + width_axis * start_width
	var start_b := start - width_axis * start_width
	var end_a := end + width_axis * end_width
	var end_b := end - width_axis * end_width

	add_streak_vertex(surface_tool, start_a)
	add_streak_vertex(surface_tool, start_b)
	add_streak_vertex(surface_tool, end_a)
	add_streak_vertex(surface_tool, start_b)
	add_streak_vertex(surface_tool, end_b)
	add_streak_vertex(surface_tool, end_a)


func add_streak_vertex(surface_tool: SurfaceTool, vertex: Vector3) -> void:
	surface_tool.set_color(tracer_color)
	surface_tool.set_uv(Vector2(vertex.z, 0.0))
	surface_tool.add_vertex(vertex)


func get_width_at_ratio(ratio: float) -> float:
	var tail_width := tracer_width * maxf(tail_width_multiplier, 0.01)
	return lerpf(tail_width, tracer_width, ratio)


# Sparks live in their OWN local space centred on the impact point (the node sits at
# z = shot_distance), so animating the node's scale grows/shrinks the whole burst
# radially — no rebuilds. The hit normal is folded in once, at build time.
func build_impact_spark_mesh(hit_normal: Vector3) -> void:
	if not impact_spark_enabled or not hit_something:
		impact_spark_mesh.visible = false
		return

	impact_spark_mesh.position = Vector3(0.0, 0.0, shot_distance)

	var surface_tool := SurfaceTool.new()
	var local_normal := global_transform.basis.inverse() * hit_normal

	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_diamond(surface_tool, impact_spark_color, Vector3.ZERO, impact_spark_width * 4.0)

	for spark_index in range(maxi(impact_spark_count, 1)):
		var scatter := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			randf_range(-0.45, 0.2)
		)

		if scatter.length() < 0.001:
			scatter = Vector3.RIGHT

		scatter = scatter.normalized() * randf_range(0.45, 1.0)
		add_spark_shard(surface_tool, scatter, local_normal)

	impact_spark_mesh.mesh = surface_tool.commit()
	impact_spark_mesh.set_instance_shader_parameter(&"emission_energy", impact_spark_emission_energy)
	impact_spark_mesh.visible = false   # revealed when the streak head arrives


func add_spark_shard(
	surface_tool: SurfaceTool,
	spark_offset: Vector3,
	local_normal: Vector3
) -> void:
	var spark_direction := (spark_offset + local_normal * 0.45).normalized()
	var spark_end := spark_direction * impact_spark_length
	var side_axis := spark_direction.cross(Vector3.FORWARD)

	if side_axis.length() < 0.001:
		side_axis = Vector3.RIGHT

	side_axis = side_axis.normalized() * impact_spark_width

	add_flat_triangle(surface_tool, impact_spark_color, side_axis, -side_axis, spark_end)


func add_flat_triangle(
	surface_tool: SurfaceTool,
	color: Color,
	a: Vector3,
	b: Vector3,
	c: Vector3
) -> void:
	for vertex in [a, b, c]:
		surface_tool.set_color(color)
		surface_tool.set_uv(Vector2.ZERO)
		surface_tool.add_vertex(vertex)


func add_diamond(
	surface_tool: SurfaceTool,
	color: Color,
	center: Vector3,
	radius: float
) -> void:
	var top := center + Vector3.UP * radius
	var right := center + Vector3.RIGHT * radius
	var bottom := center - Vector3.UP * radius
	var left := center - Vector3.RIGHT * radius

	add_flat_triangle(surface_tool, color, top, right, bottom)
	add_flat_triangle(surface_tool, color, top, bottom, left)


func ensure_visual_nodes() -> void:
	if tracer_mesh == null:
		tracer_mesh = make_effect_mesh("TracerMesh")

	if impact_spark_mesh == null:
		impact_spark_mesh = make_effect_mesh("ImpactSparkMesh")


func make_effect_mesh(mesh_name: String) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = mesh_name
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.material_override = get_shared_material()
	add_child(mesh_instance)
	return mesh_instance
