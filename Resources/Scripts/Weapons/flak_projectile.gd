class_name FlakProjectile
extends Node3D

@export_group("Flight")
@export_range(0.1, 20.0, 0.1, "or_greater") var lifetime: float = 4.0
@export_flags_3d_physics var collision_mask: int = 0xffffffff
@export_range(0.0, 1.0, 0.01) var bounce_speed_retention: float = 0.92

@export_group("Damage")
@export_range(0.0, 500.0, 0.5, "or_greater") var base_damage: float = 4.0
@export_range(1.0, 5.0, 0.01, "or_greater") var ricochet_damage_multiplier: float = 1.6
@export_range(0, 20, 1) var max_multiplying_ricochets: int = 5
@export var damage_owner: bool = false

@export_group("Ricochet Speed")
@export_range(1.0, 3.0, 0.01, "or_greater") var ricochet_speed_multiplier: float = 1.25
@export_range(1.0, 300.0, 1.0, "or_greater") var max_speed: float = 140.0

@export_group("Pellet Visual")
@export var pellet_color: Color = Color(1.0, 0.55, 0.15, 1.0)
@export_range(0.01, 1.0, 0.01, "or_greater") var pellet_radius: float = 0.05
@export_range(0.0, 32.0, 0.1, "or_greater") var pellet_emission_energy: float = 5.0
@export_range(0.0, 32.0, 0.1, "or_greater") var pellet_light_energy: float = 1.4
@export_range(0.1, 30.0, 0.1, "or_greater") var pellet_light_range: float = 3.0

@export_group("Bounce Spark")
@export var spark_enabled: bool = true
@export var spark_color: Color = Color(1.0, 0.8, 0.3, 1.0)
@export var hit_spark_color: Color = Color(1.0, 0.25, 0.15, 1.0)
@export_range(0.01, 3.0, 0.01, "or_greater") var spark_radius: float = 0.35
@export_range(0.01, 1.0, 0.01, "or_greater") var spark_duration: float = 0.12
@export_range(0.0, 32.0, 0.1, "or_greater") var spark_emission_energy: float = 10.0

@export_group("Trail")
@export var trail_enabled: bool = true
@export var trail_color: Color = Color(1.0, 0.7, 0.3, 1.0)
@export_range(1, 128, 1) var trail_amount: int = 24
@export_range(0.02, 2.0, 0.01, "or_greater") var trail_lifetime: float = 0.18
@export_range(0.001, 0.5, 0.001, "or_greater") var trail_width: float = 0.035
@export_range(0.0, 32.0, 0.1, "or_greater") var trail_emission_energy: float = 6.0

var owner_player: Node = null
var can_deal_damage: bool = false
var source_weapon_id: String = "flak_shotgun"

var velocity: Vector3 = Vector3.ZERO
var exclusions: Array[RID] = []
var age: float = 0.0
var spent: bool = false

var current_damage: float = 0.0
var bounce_count: int = 0

var core_mesh: MeshInstance3D
var glow_light: OmniLight3D
var trail_particles: GPUParticles3D
var _last_position: Vector3


func launch(
	start_position: Vector3,
	direction: Vector3,
	speed: float,
	exclude_root: Node = null
) -> void:
	global_position = start_position
	_last_position = start_position
	velocity = direction.normalized() * speed
	current_damage = base_damage
	collect_exclusions(exclude_root)


func collect_exclusions(node: Node) -> void:
	if node == null:
		return

	if node is CollisionObject3D:
		exclusions.append((node as CollisionObject3D).get_rid())

	for child in node.get_children():
		collect_exclusions(child)


func _ready() -> void:
	build_visuals()


func build_visuals() -> void:
	core_mesh = MeshInstance3D.new()
	core_mesh.name = "FlakCore"
	core_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sphere := SphereMesh.new()
	sphere.radius = pellet_radius
	sphere.height = pellet_radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	core_mesh.mesh = sphere

	var material := StandardMaterial3D.new()
	material.albedo_color = pellet_color
	material.emission_enabled = true
	material.emission = pellet_color
	material.emission_energy_multiplier = pellet_emission_energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mesh.material_override = material
	add_child(core_mesh)

	glow_light = OmniLight3D.new()
	glow_light.name = "FlakGlow"
	glow_light.light_color = pellet_color
	glow_light.light_energy = pellet_light_energy
	glow_light.omni_range = pellet_light_range
	glow_light.shadow_enabled = false
	add_child(glow_light)

	if trail_enabled:
		build_trail()


func build_trail() -> void:
	trail_particles = GPUParticles3D.new()
	trail_particles.name = "FlakTrail"
	trail_particles.emitting = true
	trail_particles.amount = trail_amount
	trail_particles.lifetime = trail_lifetime
	trail_particles.one_shot = false
	trail_particles.explosiveness = 0.0
	trail_particles.randomness = 0.05
	trail_particles.local_coords = false
	trail_particles.visibility_aabb = AABB(Vector3.ONE * -4.0, Vector3.ONE * 8.0)

	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	process_material.direction = Vector3.ZERO
	process_material.spread = 0.0
	process_material.initial_velocity_min = 0.0
	process_material.initial_velocity_max = 0.0
	process_material.gravity = Vector3.ZERO
	process_material.damping_min = 0.0
	process_material.damping_max = 0.0
	process_material.scale_min = 1.0
	process_material.scale_max = 1.0

	var fade_gradient := Gradient.new()
	fade_gradient.offsets = PackedFloat32Array([0.0, 1.0])
	fade_gradient.colors = PackedColorArray([
		trail_color,
		Color(trail_color.r, trail_color.g, trail_color.b, 0.0),
	])
	var color_ramp := GradientTexture1D.new()
	color_ramp.gradient = fade_gradient
	process_material.color_ramp = color_ramp
	trail_particles.process_material = process_material

	var trail_material := StandardMaterial3D.new()
	trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_material.vertex_color_use_as_albedo = true
	trail_material.albedo_color = Color.WHITE
	trail_material.emission_enabled = true
	trail_material.emission = Color.WHITE
	trail_material.emission_energy_multiplier = trail_emission_energy
	trail_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED

	var trail_quad := QuadMesh.new()
	trail_quad.size = Vector2.ONE * trail_width
	trail_quad.material = trail_material
	trail_particles.draw_pass_1 = trail_quad

	add_child(trail_particles)


func _physics_process(delta: float) -> void:
	if spent:
		return

	age += delta

	if age >= lifetime:
		_expire()
		return

	var from := global_position
	var to := from + velocity * delta
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = exclusions

	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		_last_position = from
		global_position = to
		return

	var hit_position: Vector3 = hit.get("position", to)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
	_handle_hit(hit.get("collider"), hit_position, hit_normal)


func _expire() -> void:
	spent = true
	velocity = Vector3.ZERO
	set_physics_process(false)
	_cleanup()


func _handle_hit(collider: Object, hit_position: Vector3, hit_normal: Vector3) -> void:
	var target := find_damage_target(collider)

	if target != null:
		_detonate_on_target(target, hit_position)
		return

	_ricochet(hit_position, hit_normal)


func _detonate_on_target(target: Node, hit_position: Vector3) -> void:
	spent = true
	global_position = hit_position
	velocity = Vector3.ZERO
	set_physics_process(false)

	if can_deal_damage and owner_player != null:
		var is_owner := target == owner_player

		if (not is_owner or damage_owner) and owner_player.has_method("submit_weapon_hit"):
			owner_player.call(
				"submit_weapon_hit",
				target,
				current_damage,
				hit_position,
				_last_position,
				(hit_position - _last_position).normalized()
			)

	if spark_enabled:
		_spawn_spark(hit_position, Vector3.UP, hit_spark_color)

	_cleanup()


func _ricochet(hit_position: Vector3, hit_normal: Vector3) -> void:
	if hit_normal.length_squared() < 0.0001:
		hit_normal = -velocity.normalized()

	var incoming := velocity
	var reflected := incoming - 2.0 * incoming.dot(hit_normal) * hit_normal
	var new_speed := reflected.length() * bounce_speed_retention

	if bounce_count < max_multiplying_ricochets:
		current_damage *= ricochet_damage_multiplier
		new_speed *= ricochet_speed_multiplier

	new_speed = minf(new_speed, max_speed)
	velocity = reflected.normalized() * new_speed

	global_position = hit_position + hit_normal * 0.02
	_last_position = global_position

	bounce_count += 1

	if spark_enabled:
		_spawn_spark(hit_position, hit_normal, spark_color)


func find_damage_target(collider: Object) -> Node:
	var current = collider

	while current != null:
		if current is Node and current.has_method("apply_weapon_damage"):
			return current

		if current is Node and current.has_method("get_peer_id"):
			return current

		if current is Node:
			current = current.get_parent()
		else:
			break

	return null


func _spawn_spark(position: Vector3, normal: Vector3, color: Color) -> void:
	var spark := MeshInstance3D.new()
	spark.name = "FlakSpark"
	spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	spark.mesh = sphere

	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(color.r, color.g, color.b, 0.85)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = spark_emission_energy
	spark.material_override = material
	spark.global_position = position + normal * 0.01
	spark.scale = Vector3.ONE * 0.01

	var parent := get_parent()

	if parent == null:
		return

	parent.add_child(spark)

	var tween := spark.create_tween()
	tween.set_trans(Tween.TRANS_QUART)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(spark, "scale", Vector3.ONE * spark_radius, spark_duration)
	tween.parallel().tween_property(material, "albedo_color:a", 0.0, spark_duration)
	tween.tween_callback(spark.queue_free)


func _cleanup() -> void:
	if core_mesh != null:
		core_mesh.visible = false

	if glow_light != null:
		var light_tween := create_tween()
		light_tween.tween_property(glow_light, "light_energy", 0.0, 0.1)

	if trail_particles != null:
		trail_particles.emitting = false

	var cleanup_delay := (trail_lifetime + 0.05) if trail_enabled else 0.25
	cleanup_delay = maxf(cleanup_delay, 0.25)
	var cleanup_tween := create_tween()
	cleanup_tween.tween_interval(cleanup_delay)
	cleanup_tween.tween_callback(queue_free)
