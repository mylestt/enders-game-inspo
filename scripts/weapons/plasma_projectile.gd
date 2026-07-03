class_name PlasmaProjectile
extends Node3D

const SHOCKWAVE_SHADER := preload("res://shaders/plasma_shockwave.gdshader")

# Travelling zero-G plasma bolt. The scene exposes all gameplay and visual tuning while this
# script owns flight, swept collision, radial damage, radial impulse, and the impact animation.

enum ParticleMeshType {
	BILLBOARD_QUAD,
	LOW_POLY_SPHERE,
}

@export_group("Flight")
@export_range(0.1, 20.0, 0.1, "or_greater") var lifetime: float = 2.5
@export_flags_3d_physics var collision_mask: int = 0xffffffff

@export_group("Projectile Visual")
@export var projectile_color: Color = Color(0.99, 0.915, 0.512, 1.0)
@export_range(0.01, 2.0, 0.01, "or_greater") var projectile_radius: float = 0.11
@export_range(0.0, 32.0, 0.1, "or_greater") var projectile_emission_energy: float = 4.0
@export_range(0.0, 32.0, 0.1, "or_greater") var projectile_light_energy: float = 2.4
@export_range(0.1, 50.0, 0.1, "or_greater") var projectile_light_range: float = 6.0

@export_group("Explosion Visual")
@export_range(0.1, 30.0, 0.1, "or_greater") var explosion_radius: float = 3.2
@export_range(0.01, 5.0, 0.01, "or_greater") var explosion_duration: float = 0.42
@export var explosion_color: Color = Color(0.22, 0.78, 1.0, 1.0)
@export_range(0.0, 1.0, 0.01) var explosion_start_alpha: float = 0.78
@export_range(0.0, 32.0, 0.1, "or_greater") var explosion_emission_energy: float = 8.0
@export_range(0.0, 32.0, 0.1, "or_greater") var explosion_light_energy: float = 8.0
@export_range(0.1, 100.0, 0.1, "or_greater") var explosion_light_range: float = 11.0
@export_range(0.01, 5.0, 0.01, "or_greater") var explosion_light_fade_time: float = 0.58

@export_group("White-Hot Impact Core")
@export var impact_core_enabled: bool = true
@export var impact_core_color: Color = Color(1.0, 0.96, 0.72, 1.0)
@export_range(0.01, 1.0, 0.01, "or_greater") var impact_core_radius_multiplier: float = 0.32
@export_range(0.01, 2.0, 0.01, "or_greater") var impact_core_duration: float = 0.14
@export_range(0.0, 64.0, 0.1, "or_greater") var impact_core_emission_energy: float = 24.0

@export_group("Pressure Shockwave")
@export var shockwave_enabled: bool = true
@export var shockwave_color: Color = Color(0.32, 0.82, 1.0, 1.0)
@export_range(0.1, 3.0, 0.01, "or_greater") var shockwave_radius_multiplier: float = 1.18
@export_range(0.01, 3.0, 0.01, "or_greater") var shockwave_duration: float = 0.3
@export_range(0.0, 1.0, 0.01) var shockwave_opacity: float = 0.9
@export_range(0.0, 64.0, 0.1, "or_greater") var shockwave_emission_energy: float = 14.0

@export_group("Player Impact Feedback")
@export var screen_shake_enabled: bool = true
@export_range(0.1, 10.0, 0.1, "or_greater") var screen_shake_radius_multiplier: float = 2.5
@export_range(0.01, 3.0, 0.01, "or_greater") var screen_shake_duration: float = 0.58
@export_range(0.0, 2.0, 0.01, "or_greater") var screen_shake_position_amplitude: float = 0.16
@export_range(0.0, 20.0, 0.1, "or_greater") var screen_shake_rotation_degrees: float = 2.4
@export_range(0.1, 100.0, 0.1, "or_greater") var screen_shake_frequency_hz: float = 18.0
@export_range(0.0, 2.0, 0.01, "or_greater") var screen_shake_directional_punch: float = 0.22
@export var screen_shake_falloff_curve: Curve
@export var view_flash_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var view_flash_max_alpha: float = 0.13
@export_range(0.01, 1.0, 0.01, "or_greater") var view_flash_duration: float = 0.12
@export var controller_rumble_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var controller_rumble_weak: float = 0.35
@export_range(0.0, 1.0, 0.01) var controller_rumble_strong: float = 0.85
@export_range(0.01, 3.0, 0.01, "or_greater") var controller_rumble_duration: float = 0.38
@export var explosion_sound: AudioStream
@export_range(-80.0, 24.0, 0.5) var explosion_sound_volume_db: float = 0.0
@export_range(0.1, 200.0, 0.1, "or_greater") var explosion_sound_max_distance: float = 60.0

@export_group("Explosion Damage")
@export var damage_enabled: bool = true
@export_range(0.0, 1000.0, 1.0, "or_greater") var maximum_damage: float = 100.0
@export_range(0.0, 1000.0, 1.0, "or_greater") var minimum_damage: float = 5.0
# X = normalized distance from the center (0 center, 1 edge).
# Y = blend from minimum damage (0) to maximum damage (1).
@export var damage_falloff_curve: Curve
@export var damage_owner: bool = true

@export_group("Airburst Force")
@export var airburst_enabled: bool = true
@export_range(0.0, 250.0, 0.5, "or_greater") var airburst_center_impulse: float = 24.0
@export_range(0.0, 250.0, 0.5, "or_greater") var airburst_edge_impulse: float = 2.0
# Uses the same normalized distance convention as damage_falloff_curve.
@export var airburst_falloff_curve: Curve
@export var airburst_push_players: bool = true
@export var airburst_push_rigid_bodies: bool = true
@export var airburst_push_owner: bool = true
@export_range(1, 512, 1) var airburst_max_bodies: int = 128

@export_group("Ion Particles")
@export var particles_enabled: bool = true
@export var particle_mesh_type: ParticleMeshType = ParticleMeshType.BILLBOARD_QUAD
@export_range(1, 2048, 1) var particle_amount: int = 84
@export_range(0.05, 10.0, 0.05, "or_greater") var particle_lifetime: float = 1.05
@export_range(0.0, 100.0, 0.1, "or_greater") var particle_min_speed: float = 3.5
@export_range(0.0, 100.0, 0.1, "or_greater") var particle_max_speed: float = 9.5
@export_range(0.001, 2.0, 0.005, "or_greater") var particle_size: float = 0.105
@export_range(0.01, 10.0, 0.01, "or_greater") var particle_min_scale: float = 0.55
@export_range(0.01, 10.0, 0.01, "or_greater") var particle_max_scale: float = 1.5
@export_range(0.0, 20.0, 0.1, "or_greater") var particle_min_damping: float = 1.0
@export_range(0.0, 20.0, 0.1, "or_greater") var particle_max_damping: float = 2.8
@export_range(0.0, 1.0, 0.01) var particle_randomness: float = 0.42
@export_range(0.0, 32.0, 0.1, "or_greater") var particle_emission_energy: float = 5.5
@export var particle_color_over_lifetime: Gradient

@export_group("Fast Ion Streaks")
@export var ion_streaks_enabled: bool = true
@export_range(1, 512, 1) var ion_streak_amount: int = 72
@export_range(0.05, 3.0, 0.01, "or_greater") var ion_streak_lifetime: float = 0.48
@export_range(0.0, 200.0, 0.1, "or_greater") var ion_streak_min_speed: float = 24.0
@export_range(0.0, 200.0, 0.1, "or_greater") var ion_streak_max_speed: float = 52.0
@export_range(0.001, 1.0, 0.001, "or_greater") var ion_streak_width: float = 0.026
@export_range(0.01, 5.0, 0.01, "or_greater") var ion_streak_length: float = 0.52
@export_range(0.0, 30.0, 0.1, "or_greater") var ion_streak_damping: float = 7.0
@export_range(0.0, 64.0, 0.1, "or_greater") var ion_streak_emission_energy: float = 16.0
@export var ion_streak_color_over_lifetime: Gradient

var owner_player: Node = null
var can_deal_damage: bool = false
# WeaponInventory id of the gun that fired this bolt; damage claims carry it so the server
# validates against the right weapon's ownership/ammo/damage.
var source_weapon_id: String = "plasma_cannon"
var speed: float = 55.0
var fire_origin: Vector3 = Vector3.ZERO
var fire_direction: Vector3 = Vector3.FORWARD

var velocity: Vector3 = Vector3.ZERO
var exclusions: Array[RID] = []
var age: float = 0.0
var exploded: bool = false

var core_mesh: MeshInstance3D
var glow_light: OmniLight3D
var explosion_sphere: MeshInstance3D
var explosion_material: StandardMaterial3D
var ion_particles: GPUParticles3D
var impact_core: MeshInstance3D
var impact_core_material: StandardMaterial3D
var shockwave_shell: MeshInstance3D
var shockwave_material: ShaderMaterial
var ion_streaks: GPUParticles3D


func launch(
	start_position: Vector3,
	direction: Vector3,
	new_speed: float,
	exclude_root: Node = null
) -> void:
	global_position = start_position
	fire_origin = start_position
	fire_direction = direction.normalized()
	speed = new_speed
	velocity = fire_direction * speed
	collect_exclusions(exclude_root)


func collect_exclusions(node: Node) -> void:
	if node == null:
		return

	if node is CollisionObject3D:
		exclusions.append((node as CollisionObject3D).get_rid())

	for child in node.get_children():
		collect_exclusions(child)


func _ready() -> void:
	build_projectile_visuals()


func build_projectile_visuals() -> void:
	core_mesh = MeshInstance3D.new()
	core_mesh.name = "PlasmaCore"
	core_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sphere := SphereMesh.new()
	sphere.radius = projectile_radius
	sphere.height = projectile_radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	core_mesh.mesh = sphere

	var material := StandardMaterial3D.new()
	material.albedo_color = projectile_color
	material.emission_enabled = true
	material.emission = projectile_color
	material.emission_energy_multiplier = projectile_emission_energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mesh.material_override = material
	add_child(core_mesh)

	glow_light = OmniLight3D.new()
	glow_light.name = "PlasmaGlow"
	glow_light.light_color = projectile_color
	glow_light.light_energy = projectile_light_energy
	glow_light.omni_range = projectile_light_range
	glow_light.shadow_enabled = false
	add_child(glow_light)


func _physics_process(delta: float) -> void:
	if exploded:
		return

	age += delta

	if age >= lifetime:
		queue_free()
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
		global_position = to
		return

	var hit_position: Vector3 = hit.get("position", to)
	global_position = hit_position
	on_impact(hit.get("collider"), hit_position)


func on_impact(_collider: Object, hit_position: Vector3) -> void:
	if exploded:
		return

	exploded = true
	global_position = hit_position
	velocity = Vector3.ZERO
	set_physics_process(false)

	if can_deal_damage:
		apply_player_blast_effects(hit_position)

	if airburst_enabled and airburst_push_rigid_bodies:
		apply_local_rigid_body_airburst(hit_position)

	apply_local_impact_feedback(hit_position)
	play_impact_effect()


# Queries everything touched by the spherical blast, deduplicates compound colliders, then
# submits one damage+impulse claim per player. NetworkManager validates radius/path and owns
# the actual multiplayer application; offline play applies through Player directly.
func apply_player_blast_effects(blast_position: Vector3) -> void:
	if owner_player == null or (not damage_enabled and not airburst_enabled):
		return

	var seen_targets: Dictionary = {}

	for result in query_blast_colliders(blast_position):
		var target := find_player_target(result.get("collider"))

		if target == null:
			continue

		var target_id := target.get_instance_id()

		if seen_targets.has(target_id):
			continue

		seen_targets[target_id] = true
		var is_owner := target == owner_player

		if is_owner and not damage_owner and not airburst_push_owner:
			continue

		var target_position := (target as Node3D).global_position
		var normalized_distance := clampf(
			blast_position.distance_to(target_position) / maxf(explosion_radius, 0.001),
			0.0,
			1.0
		)
		var damage := calculate_damage(normalized_distance) if damage_enabled else 0.0
		var impulse := Vector3.ZERO

		if airburst_enabled and airburst_push_players and (not is_owner or airburst_push_owner):
			impulse = calculate_airburst_impulse(
				blast_position,
				target_position,
				normalized_distance
			)

		if is_owner and not damage_owner:
			damage = 0.0

		if damage <= 0.0 and impulse.is_zero_approx():
			continue

		if owner_player.has_method("submit_plasma_explosion_hit"):
			owner_player.call(
				"submit_plasma_explosion_hit",
				target,
				damage,
				impulse,
				blast_position,
				explosion_radius,
				fire_origin,
				fire_direction,
				source_weapon_id
			)


func apply_local_rigid_body_airburst(blast_position: Vector3) -> void:
	var seen_bodies: Dictionary = {}

	for result in query_blast_colliders(blast_position):
		var collider = result.get("collider")

		# Player bodies are network-owned and are handled by the validated player path above.
		if find_player_target(collider) != null:
			continue

		var body := find_rigid_body(collider)

		if body == null or body.freeze:
			continue

		var body_id := body.get_instance_id()

		if seen_bodies.has(body_id):
			continue

		seen_bodies[body_id] = true
		var normalized_distance := clampf(
			blast_position.distance_to(body.global_position) / maxf(explosion_radius, 0.001),
			0.0,
			1.0
		)
		var impulse := calculate_airburst_impulse(
			blast_position,
			body.global_position,
			normalized_distance
		)

		if not impulse.is_zero_approx():
			body.sleeping = false
			body.apply_central_impulse(impulse)


func query_blast_colliders(blast_position: Vector3) -> Array[Dictionary]:
	var sphere := SphereShape3D.new()
	sphere.radius = maxf(explosion_radius, 0.001)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, blast_position)
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false

	return get_world_3d().direct_space_state.intersect_shape(query, airburst_max_bodies)


func calculate_damage(normalized_distance: float) -> float:
	var falloff := sample_falloff(damage_falloff_curve, normalized_distance)
	return lerpf(minimum_damage, maximum_damage, falloff)


func calculate_airburst_impulse(
	blast_position: Vector3,
	target_position: Vector3,
	normalized_distance: float
) -> Vector3:
	var direction := target_position - blast_position

	if direction.length_squared() < 0.0001:
		direction = -fire_direction
	else:
		direction = direction.normalized()

	var falloff := sample_falloff(airburst_falloff_curve, normalized_distance)
	var magnitude := lerpf(airburst_edge_impulse, airburst_center_impulse, falloff)
	return direction * maxf(magnitude, 0.0)


func sample_falloff(curve: Curve, normalized_distance: float) -> float:
	var distance := clampf(normalized_distance, 0.0, 1.0)

	if curve == null or curve.point_count == 0:
		return 1.0 - distance

	return clampf(curve.sample_baked(distance), 0.0, 1.0)


func apply_local_impact_feedback(blast_position: Vector3) -> void:
	if not screen_shake_enabled and not view_flash_enabled:
		return

	var active_camera := get_viewport().get_camera_3d()

	if active_camera == null:
		return

	var feedback_radius := explosion_radius * maxf(screen_shake_radius_multiplier, 0.1)
	var distance := active_camera.global_position.distance_to(blast_position)

	if distance > feedback_radius:
		return

	var normalized_distance := clampf(distance / maxf(feedback_radius, 0.001), 0.0, 1.0)
	var strength := 0.0

	if screen_shake_falloff_curve == null or screen_shake_falloff_curve.point_count == 0:
		strength = pow(1.0 - normalized_distance, 2.0)
	else:
		strength = sample_falloff(screen_shake_falloff_curve, normalized_distance)

	var outward_direction := active_camera.global_position - blast_position

	if outward_direction.length_squared() < 0.0001:
		outward_direction = -fire_direction
	else:
		outward_direction = outward_direction.normalized()

	if screen_shake_enabled:
		var camera_rig := active_camera.get_parent()

		if camera_rig != null and camera_rig.has_method("trigger_explosion_shake"):
			camera_rig.call(
				"trigger_explosion_shake",
				outward_direction,
				strength,
				screen_shake_position_amplitude,
				screen_shake_rotation_degrees,
				screen_shake_duration,
				screen_shake_frequency_hz,
				screen_shake_directional_punch
			)

	if view_flash_enabled:
		build_view_flash(strength)

	if controller_rumble_enabled and strength > 0.01:
		for joypad_id in Input.get_connected_joypads():
			Input.start_joy_vibration(
				joypad_id,
				controller_rumble_weak * strength,
				controller_rumble_strong * strength,
				controller_rumble_duration
			)


func build_view_flash(strength: float) -> void:
	var alpha := view_flash_max_alpha * clampf(strength, 0.0, 1.0)

	if alpha <= 0.001:
		return

	var layer := CanvasLayer.new()
	layer.name = "ExplosionViewFlash"
	layer.layer = 100
	add_child(layer)

	var flash := ColorRect.new()
	flash.name = "Flash"
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash.color = Color(impact_core_color.r, impact_core_color.g, impact_core_color.b, alpha)

	var canvas_material := CanvasItemMaterial.new()
	canvas_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	flash.material = canvas_material
	layer.add_child(flash)

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(
		flash,
		"color",
		Color(impact_core_color.r, impact_core_color.g, impact_core_color.b, 0.0),
		view_flash_duration
	)
	tween.tween_callback(layer.queue_free)


func find_player_target(collider: Object) -> Node3D:
	var current = collider

	while current != null:
		if current is Node3D and current.has_method("get_peer_id"):
			return current as Node3D

		if current is Node:
			current = current.get_parent()
		else:
			break

	return null


func find_rigid_body(collider: Object) -> RigidBody3D:
	var current = collider

	while current != null:
		if current is RigidBody3D:
			return current as RigidBody3D

		if current is Node:
			current = current.get_parent()
		else:
			break

	return null


func play_impact_effect() -> void:
	if core_mesh != null:
		core_mesh.visible = false

	if impact_core_enabled:
		build_impact_core()
		var core_tween := create_tween()
		core_tween.set_trans(Tween.TRANS_QUART)
		core_tween.set_ease(Tween.EASE_OUT)
		core_tween.tween_method(update_impact_core, 0.0, 1.0, impact_core_duration)

	build_explosion_sphere()

	if shockwave_enabled:
		build_shockwave_shell()
		var shockwave_tween := create_tween()
		shockwave_tween.set_trans(Tween.TRANS_QUART)
		shockwave_tween.set_ease(Tween.EASE_OUT)
		shockwave_tween.tween_method(update_shockwave_shell, 0.0, 1.0, shockwave_duration)

	if particles_enabled:
		build_ion_particles()

	if ion_streaks_enabled:
		build_ion_streaks()

	play_explosion_sound()

	if glow_light != null:
		glow_light.light_color = explosion_color
		glow_light.light_energy = explosion_light_energy
		glow_light.omni_range = explosion_light_range

	var sphere_tween := create_tween()
	sphere_tween.set_trans(Tween.TRANS_CUBIC)
	sphere_tween.set_ease(Tween.EASE_OUT)
	sphere_tween.tween_method(update_explosion_sphere, 0.0, 1.0, explosion_duration)

	if glow_light != null:
		var light_tween := create_tween()
		light_tween.set_trans(Tween.TRANS_QUAD)
		light_tween.set_ease(Tween.EASE_OUT)
		light_tween.tween_property(glow_light, "light_energy", 0.0, explosion_light_fade_time)
		light_tween.parallel().tween_property(glow_light, "omni_range", 0.1, explosion_light_fade_time)

	var effect_lifetime := maxf(
		explosion_duration,
		maxf(
			maxf(
				particle_lifetime if particles_enabled else 0.0,
				ion_streak_lifetime if ion_streaks_enabled else 0.0
			),
			maxf(
				explosion_light_fade_time,
				maxf(
					impact_core_duration if impact_core_enabled else 0.0,
					shockwave_duration if shockwave_enabled else 0.0
				)
			)
		)
	)

	if explosion_sound != null:
		effect_lifetime = maxf(effect_lifetime, explosion_sound.get_length())

	var cleanup_tween := create_tween()
	cleanup_tween.tween_interval(effect_lifetime + 0.2)
	cleanup_tween.tween_callback(queue_free)


func build_impact_core() -> void:
	impact_core = MeshInstance3D.new()
	impact_core.name = "WhiteHotImpactCore"
	impact_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 20
	sphere.rings = 10
	impact_core.mesh = sphere

	impact_core_material = StandardMaterial3D.new()
	impact_core_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	impact_core_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	impact_core_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	impact_core_material.albedo_color = impact_core_color
	impact_core_material.emission_enabled = true
	impact_core_material.emission = impact_core_color
	impact_core_material.emission_energy_multiplier = impact_core_emission_energy
	impact_core.material_override = impact_core_material
	impact_core.scale = Vector3.ONE * 0.01
	add_child(impact_core)


func update_impact_core(progress: float) -> void:
	if impact_core == null or impact_core_material == null:
		return

	var remaining := 1.0 - progress
	impact_core.scale = Vector3.ONE * lerpf(
		0.01,
		explosion_radius * impact_core_radius_multiplier,
		progress
	)
	impact_core_material.albedo_color = Color(
		impact_core_color.r,
		impact_core_color.g,
		impact_core_color.b,
		remaining * remaining
	)
	impact_core_material.emission_energy_multiplier = impact_core_emission_energy * remaining

	if progress >= 0.999:
		impact_core.visible = false


func build_shockwave_shell() -> void:
	shockwave_shell = MeshInstance3D.new()
	shockwave_shell.name = "PressureShockwave"
	shockwave_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	shockwave_shell.mesh = sphere

	shockwave_material = ShaderMaterial.new()
	shockwave_material.shader = SHOCKWAVE_SHADER
	shockwave_material.set_shader_parameter("shell_color", shockwave_color)
	shockwave_material.set_shader_parameter("opacity", shockwave_opacity)
	shockwave_material.set_shader_parameter("emission_strength", shockwave_emission_energy)
	shockwave_shell.material_override = shockwave_material
	shockwave_shell.scale = Vector3.ONE * 0.01
	add_child(shockwave_shell)


func update_shockwave_shell(progress: float) -> void:
	if shockwave_shell == null or shockwave_material == null:
		return

	var remaining := 1.0 - progress
	shockwave_shell.scale = Vector3.ONE * lerpf(
		0.01,
		explosion_radius * shockwave_radius_multiplier,
		progress
	)
	shockwave_material.set_shader_parameter(
		"opacity",
		shockwave_opacity * sqrt(maxf(remaining, 0.0))
	)

	if progress >= 0.999:
		shockwave_shell.visible = false


func build_explosion_sphere() -> void:
	explosion_sphere = MeshInstance3D.new()
	explosion_sphere.name = "ExpandingPlasmaSphere"
	explosion_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	explosion_sphere.mesh = sphere

	explosion_material = StandardMaterial3D.new()
	explosion_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	explosion_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	explosion_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	explosion_material.albedo_color = Color(
		explosion_color.r,
		explosion_color.g,
		explosion_color.b,
		explosion_start_alpha
	)
	explosion_material.emission_enabled = true
	explosion_material.emission = explosion_color
	explosion_material.emission_energy_multiplier = explosion_emission_energy
	explosion_sphere.material_override = explosion_material
	explosion_sphere.scale = Vector3.ONE * 0.01
	add_child(explosion_sphere)


func update_explosion_sphere(progress: float) -> void:
	if explosion_sphere == null or explosion_material == null:
		return

	var remaining := 1.0 - progress
	explosion_sphere.scale = Vector3.ONE * lerpf(0.01, explosion_radius, progress)
	explosion_material.albedo_color = Color(
		explosion_color.r,
		explosion_color.g,
		explosion_color.b,
		explosion_start_alpha * remaining * remaining
	)
	explosion_material.emission_energy_multiplier = lerpf(
		explosion_emission_energy,
		0.0,
		progress
	)

	if progress >= 0.999:
		explosion_sphere.visible = false


func build_ion_particles() -> void:
	ion_particles = GPUParticles3D.new()
	ion_particles.name = "IonizedParticleBurst"
	ion_particles.emitting = false
	ion_particles.amount = particle_amount
	ion_particles.lifetime = particle_lifetime
	ion_particles.one_shot = true
	ion_particles.explosiveness = 1.0
	ion_particles.randomness = particle_randomness
	ion_particles.visibility_aabb = AABB(
		Vector3.ONE * -explosion_radius * 2.0,
		Vector3.ONE * explosion_radius * 4.0
	)

	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process_material.emission_sphere_radius = minf(projectile_radius, explosion_radius)
	process_material.direction = Vector3.UP
	process_material.spread = 180.0
	process_material.initial_velocity_min = minf(particle_min_speed, particle_max_speed)
	process_material.initial_velocity_max = maxf(particle_min_speed, particle_max_speed)
	process_material.gravity = Vector3.ZERO
	process_material.damping_min = minf(particle_min_damping, particle_max_damping)
	process_material.damping_max = maxf(particle_min_damping, particle_max_damping)
	process_material.scale_min = minf(particle_min_scale, particle_max_scale)
	process_material.scale_max = maxf(particle_min_scale, particle_max_scale)

	if particle_color_over_lifetime != null:
		var color_ramp := GradientTexture1D.new()
		color_ramp.gradient = particle_color_over_lifetime
		process_material.color_ramp = color_ramp

	ion_particles.process_material = process_material
	ion_particles.draw_pass_1 = build_particle_mesh()
	add_child(ion_particles)
	ion_particles.emitting = true


func build_ion_streaks() -> void:
	ion_streaks = GPUParticles3D.new()
	ion_streaks.name = "FastIonStreaks"
	ion_streaks.emitting = false
	ion_streaks.amount = ion_streak_amount
	ion_streaks.lifetime = ion_streak_lifetime
	ion_streaks.one_shot = true
	ion_streaks.explosiveness = 1.0
	ion_streaks.randomness = 0.35
	ion_streaks.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	ion_streaks.visibility_aabb = AABB(
		Vector3.ONE * -explosion_radius * 3.0,
		Vector3.ONE * explosion_radius * 6.0
	)

	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process_material.emission_sphere_radius = minf(projectile_radius, explosion_radius)
	process_material.direction = Vector3.UP
	process_material.spread = 180.0
	process_material.initial_velocity_min = minf(ion_streak_min_speed, ion_streak_max_speed)
	process_material.initial_velocity_max = maxf(ion_streak_min_speed, ion_streak_max_speed)
	process_material.gravity = Vector3.ZERO
	process_material.damping_min = ion_streak_damping
	process_material.damping_max = ion_streak_damping * 1.25

	var streak_gradient := ion_streak_color_over_lifetime

	if streak_gradient == null:
		streak_gradient = Gradient.new()
		streak_gradient.offsets = PackedFloat32Array([0.0, 0.18, 0.72, 1.0])
		streak_gradient.colors = PackedColorArray([
			impact_core_color,
			Color(shockwave_color.r, shockwave_color.g, shockwave_color.b, 1.0),
			Color(explosion_color.r, explosion_color.g, explosion_color.b, 0.55),
			Color(explosion_color.r, explosion_color.g, explosion_color.b, 0.0),
		])

	var color_ramp := GradientTexture1D.new()
	color_ramp.gradient = streak_gradient
	process_material.color_ramp = color_ramp
	ion_streaks.process_material = process_material

	var streak_material := StandardMaterial3D.new()
	streak_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	streak_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	streak_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	streak_material.vertex_color_use_as_albedo = true
	streak_material.albedo_color = Color.WHITE
	streak_material.emission_enabled = true
	streak_material.emission = Color.WHITE
	streak_material.emission_energy_multiplier = ion_streak_emission_energy

	var streak_quad := QuadMesh.new()
	streak_quad.size = Vector2(ion_streak_width, ion_streak_length)
	streak_quad.material = streak_material
	ion_streaks.draw_pass_1 = streak_quad
	add_child(ion_streaks)
	ion_streaks.emitting = true


func play_explosion_sound() -> void:
	if explosion_sound == null:
		return

	var audio_player := AudioStreamPlayer3D.new()
	audio_player.name = "ExplosionAudio"
	audio_player.stream = explosion_sound
	audio_player.volume_db = explosion_sound_volume_db
	audio_player.max_distance = explosion_sound_max_distance
	audio_player.panning_strength = 1.0
	add_child(audio_player)
	audio_player.play()


func build_particle_mesh() -> PrimitiveMesh:
	var particle_material := StandardMaterial3D.new()
	particle_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	particle_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	particle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	particle_material.vertex_color_use_as_albedo = true
	particle_material.albedo_color = Color.WHITE
	particle_material.emission_enabled = true
	particle_material.emission = Color.WHITE
	particle_material.emission_energy_multiplier = particle_emission_energy

	if particle_mesh_type == ParticleMeshType.LOW_POLY_SPHERE:
		var particle_sphere := SphereMesh.new()
		particle_sphere.radius = particle_size * 0.5
		particle_sphere.height = particle_size
		particle_sphere.radial_segments = 6
		particle_sphere.rings = 4
		particle_sphere.material = particle_material
		return particle_sphere

	particle_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var particle_quad := QuadMesh.new()
	particle_quad.size = Vector2.ONE * particle_size
	particle_quad.material = particle_material
	return particle_quad
