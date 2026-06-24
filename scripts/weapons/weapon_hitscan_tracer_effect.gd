class_name WeaponHitscanTracerEffect
extends Node3D

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

@export_group("Muzzle Flash")
@export var muzzle_flash_enabled: bool = true
@export var muzzle_flash_time: float = 0.04
@export var muzzle_flash_radius: float = 0.2
@export var muzzle_flash_length: float = 0.55
@export var muzzle_flash_color: Color = Color(1.0, 0.75, 0.24, 0.82)
@export var muzzle_flash_emission_energy: float = 8.0

@export_group("Impact Spark")
@export var impact_spark_enabled: bool = true
@export var impact_spark_time: float = 0.09
@export_range(1, 24, 1) var impact_spark_count: int = 8
@export var impact_spark_length: float = 0.45
@export var impact_spark_width: float = 0.018
@export var impact_spark_color: Color = Color(1.0, 0.52, 0.12, 0.8)
@export var impact_spark_emission_energy: float = 6.5

var tracer_mesh: MeshInstance3D
var muzzle_flash_mesh: MeshInstance3D
var impact_spark_mesh: MeshInstance3D
var tracer_material: StandardMaterial3D
var muzzle_flash_material: StandardMaterial3D
var impact_spark_material: StandardMaterial3D

var shot_distance: float = 0.0
var hit_something: bool = false
var hit_normal: Vector3 = Vector3.ZERO
var elapsed: float = 0.0
var travel_time: float = 0.035
var jagged_offsets: Array[Array] = []
var impact_spark_offsets: Array[Vector3] = []
var initialized: bool = false


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
	hit_normal = normal
	shot_distance = shot_vector.length()
	travel_time = clampf(
		shot_distance / maxf(visual_speed, 0.001),
		min_travel_time,
		max_travel_time
	)
	elapsed = 0.0
	initialized = true
	global_transform = get_transform_from_shot(start_position, shot_vector.normalized())
	randomize_visual_offsets()
	set_process(true)
	update_visuals()


func _process(delta: float) -> void:
	if not initialized:
		return
	
	elapsed += delta
	update_visuals()
	
	if elapsed >= travel_time + fade_time:
		queue_free()


func update_visuals() -> void:
	var travel_ratio := get_travel_ratio()
	var fade_alpha := get_fade_alpha()
	var head_distance := shot_distance * travel_ratio
	var tail_distance := get_tail_distance(head_distance)
	
	build_tracer_mesh(tail_distance, head_distance, fade_alpha)
	build_muzzle_flash_mesh()
	build_impact_spark_mesh()


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


func get_tail_distance(head_distance: float) -> float:
	if max_visible_length <= 0.0:
		return 0.0
	
	return maxf(head_distance - max_visible_length, 0.0)


func randomize_visual_offsets() -> void:
	var rng := RandomNumberGenerator.new()
	var point_count := maxi(segment_count + 1, 2)
	
	rng.randomize()
	jagged_offsets.clear()
	impact_spark_offsets.clear()
	
	for strand_index in range(maxi(strand_count, 1)):
		var strand_offsets: Array[Vector2] = []
		
		for point_index in range(point_count):
			if point_index == 0 or point_index == point_count - 1:
				strand_offsets.append(Vector2.ZERO)
			else:
				strand_offsets.append(Vector2(
					rng.randf_range(-1.0, 1.0),
					rng.randf_range(-1.0, 1.0)
				))
		
		jagged_offsets.append(strand_offsets)
	
	for spark_index in range(maxi(impact_spark_count, 1)):
		var direction := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-0.45, 0.2)
		)
		
		if direction.length() < 0.001:
			direction = Vector3.RIGHT
		
		impact_spark_offsets.append(direction.normalized() * rng.randf_range(0.45, 1.0))


func build_tracer_mesh(tail_distance: float, head_distance: float, alpha: float) -> void:
	if head_distance - tail_distance < 0.025 or alpha <= 0.0:
		tracer_mesh.visible = false
		return
	
	var surface_tool := SurfaceTool.new()
	var point_count := maxi(segment_count + 1, 2)
	
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	for strand_index in range(maxi(strand_count, 1)):
		var points: Array[Vector3] = get_tracer_points(
			strand_index,
			point_count,
			tail_distance,
			head_distance
		)
		add_strand_to_surface(surface_tool, points, Vector3.RIGHT)
		add_strand_to_surface(surface_tool, points, Vector3.UP)
	
	tracer_mesh.mesh = surface_tool.commit()
	update_material_alpha(tracer_material, tracer_color, tracer_emission_energy, alpha)
	tracer_mesh.visible = true


func get_tracer_points(
	strand_index: int,
	point_count: int,
	tail_distance: float,
	head_distance: float
) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var strand_phase := float(strand_index) / maxf(float(strand_count), 1.0)
	var strand_center := Vector2(
		cos(strand_phase * TAU),
		sin(strand_phase * TAU)
	) * tracer_width * 0.8
	var strand_offsets: Array = jagged_offsets[strand_index]
	
	for point_index in range(point_count):
		var ratio := float(point_index) / maxf(float(point_count - 1), 1.0)
		var z_distance := lerpf(tail_distance, head_distance, ratio)
		var offset_strength := sin(ratio * PI) * jagged_radius
		var offset_seed: Vector2 = strand_offsets[point_index]
		var offset: Vector2 = offset_seed * offset_strength + strand_center
		
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
		var start_width := get_width_at_ratio(start_ratio)
		var end_width := get_width_at_ratio(end_ratio)
		var start_point: Vector3 = points[point_index]
		var end_point: Vector3 = points[point_index + 1]
		
		add_ribbon_segment(
			surface_tool,
			start_point,
			end_point,
			width_axis,
			start_width,
			end_width
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
	
	surface_tool.add_vertex(start_a)
	surface_tool.add_vertex(start_b)
	surface_tool.add_vertex(end_a)
	surface_tool.add_vertex(start_b)
	surface_tool.add_vertex(end_b)
	surface_tool.add_vertex(end_a)


func get_width_at_ratio(ratio: float) -> float:
	var tail_width := tracer_width * maxf(tail_width_multiplier, 0.01)
	return lerpf(tail_width, tracer_width, ratio)


func build_muzzle_flash_mesh() -> void:
	if not muzzle_flash_enabled:
		muzzle_flash_mesh.visible = false
		return
	
	var alpha := clampf(1.0 - elapsed / maxf(muzzle_flash_time, 0.001), 0.0, 1.0)
	
	if alpha <= 0.0:
		muzzle_flash_mesh.visible = false
		return
	
	var surface_tool := SurfaceTool.new()
	var radius := muzzle_flash_radius * alpha
	var length := muzzle_flash_length * alpha
	
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_cone_face(surface_tool, Vector3.ZERO, Vector3(radius, 0.0, length), Vector3(0.0, radius, length))
	add_cone_face(surface_tool, Vector3.ZERO, Vector3(0.0, radius, length), Vector3(-radius, 0.0, length))
	add_cone_face(surface_tool, Vector3.ZERO, Vector3(-radius, 0.0, length), Vector3(0.0, -radius, length))
	add_cone_face(surface_tool, Vector3.ZERO, Vector3(0.0, -radius, length), Vector3(radius, 0.0, length))
	add_billboard_diamond(surface_tool, Vector3.ZERO, radius * 1.35, Vector3.RIGHT, Vector3.UP)
	
	muzzle_flash_mesh.mesh = surface_tool.commit()
	update_material_alpha(muzzle_flash_material, muzzle_flash_color, muzzle_flash_emission_energy, alpha)
	muzzle_flash_mesh.visible = true


func add_cone_face(
	surface_tool: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3
) -> void:
	surface_tool.add_vertex(a)
	surface_tool.add_vertex(b)
	surface_tool.add_vertex(c)


func add_billboard_diamond(
	surface_tool: SurfaceTool,
	center: Vector3,
	radius: float,
	right_axis: Vector3,
	up_axis: Vector3
) -> void:
	var top := center + up_axis * radius
	var right := center + right_axis * radius
	var bottom := center - up_axis * radius
	var left := center - right_axis * radius
	
	surface_tool.add_vertex(top)
	surface_tool.add_vertex(right)
	surface_tool.add_vertex(bottom)
	surface_tool.add_vertex(top)
	surface_tool.add_vertex(bottom)
	surface_tool.add_vertex(left)


func build_impact_spark_mesh() -> void:
	if not impact_spark_enabled or not hit_something:
		impact_spark_mesh.visible = false
		return
	
	var impact_elapsed := elapsed - travel_time
	
	if impact_elapsed < 0.0:
		impact_spark_mesh.visible = false
		return
	
	var alpha := clampf(1.0 - impact_elapsed / maxf(impact_spark_time, 0.001), 0.0, 1.0)
	
	if alpha <= 0.0:
		impact_spark_mesh.visible = false
		return
	
	var surface_tool := SurfaceTool.new()
	var impact_position := Vector3(0.0, 0.0, shot_distance)
	
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_billboard_diamond(
		surface_tool,
		impact_position,
		impact_spark_width * 4.0 * alpha,
		Vector3.RIGHT,
		Vector3.UP
	)
	
	for spark_offset in impact_spark_offsets:
		add_spark_shard(surface_tool, impact_position, spark_offset, alpha)
	
	impact_spark_mesh.mesh = surface_tool.commit()
	update_material_alpha(impact_spark_material, impact_spark_color, impact_spark_emission_energy, alpha)
	impact_spark_mesh.visible = true


func add_spark_shard(
	surface_tool: SurfaceTool,
	origin: Vector3,
	spark_offset: Vector3,
	alpha: float
) -> void:
	var local_normal := global_transform.basis.inverse() * hit_normal
	var spark_direction := (spark_offset + local_normal * 0.45).normalized()
	var spark_end := origin + spark_direction * impact_spark_length * alpha
	var side_axis := spark_direction.cross(Vector3.FORWARD)
	
	if side_axis.length() < 0.001:
		side_axis = Vector3.RIGHT
	
	side_axis = side_axis.normalized() * impact_spark_width * alpha
	surface_tool.add_vertex(origin + side_axis)
	surface_tool.add_vertex(origin - side_axis)
	surface_tool.add_vertex(spark_end)


func ensure_visual_nodes() -> void:
	if tracer_mesh == null:
		tracer_mesh = MeshInstance3D.new()
		tracer_mesh.name = "TracerMesh"
		tracer_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tracer_mesh)
	
	if muzzle_flash_mesh == null:
		muzzle_flash_mesh = MeshInstance3D.new()
		muzzle_flash_mesh.name = "MuzzleFlashMesh"
		muzzle_flash_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(muzzle_flash_mesh)
	
	if impact_spark_mesh == null:
		impact_spark_mesh = MeshInstance3D.new()
		impact_spark_mesh.name = "ImpactSparkMesh"
		impact_spark_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(impact_spark_mesh)
	
	if tracer_material == null:
		tracer_material = create_additive_material(tracer_color, tracer_emission_energy)
		tracer_mesh.material_override = tracer_material
	
	if muzzle_flash_material == null:
		muzzle_flash_material = create_additive_material(
			muzzle_flash_color,
			muzzle_flash_emission_energy
		)
		muzzle_flash_mesh.material_override = muzzle_flash_material
	
	if impact_spark_material == null:
		impact_spark_material = create_additive_material(
			impact_spark_color,
			impact_spark_emission_energy
		)
		impact_spark_mesh.material_override = impact_spark_material


func create_additive_material(
	color: Color,
	emission_energy: float
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = emission_energy
	return material


func update_material_alpha(
	material: StandardMaterial3D,
	base_color: Color,
	emission_energy: float,
	alpha: float
) -> void:
	var visible_alpha := base_color.a * clampf(alpha, 0.0, 1.0)
	material.albedo_color = Color(base_color.r, base_color.g, base_color.b, visible_alpha)
	material.emission = Color(base_color.r, base_color.g, base_color.b, 1.0)
	material.emission_energy_multiplier = emission_energy * clampf(alpha, 0.0, 1.0)
