class_name LaserController
extends Node3D

const LASER_FOLLOW_SPEED_BY_LEVEL := [7.0, 10.0, 14.0, 20.0]
const LASER_FIRE_COOLDOWN_BY_LEVEL := [0.20, 0.16, 0.12, 0.085]

@export var laser_range: float = 120.0

@export var laser_screen_sensitivity: float = 1.0
@export var laser_crosshair_margin: float = 28.0

@export var muzzle_right_offset: float = 0.38
@export var muzzle_up_offset: float = -0.22
@export var muzzle_forward_offset: float = 0.45

@export var laser_follow_speed: float = 7.0
@export var laser_fire_cooldown: float = 0.20

@export var shot_laser_thickness: float = 0.045
@export var shot_laser_lifetime: float = 0.09

@export var shot_laser_radial_segments: int = 32
@export var shot_laser_glow_thickness_multiplier: float = 3.0
@export var shot_laser_core_emission_energy: float = 9.0
@export var shot_laser_glow_emission_energy: float = 3.5

@export var shot_laser_core_color: Color = Color(1.0, 0.08, 0.02, 1.0)
@export var shot_laser_glow_color: Color = Color(1.0, 0.02, 0.0, 0.22)

@export var actual_dot_size: float = 8.0
@export var desired_circle_size: float = 22.0
@export var desired_circle_border_width: int = 2

@export var surface_center_reticle_size: float = 10.0

@export var reticle_core_color: Color = Color(1.0, 1.0, 1.0, 0.96)
@export var reticle_soft_color: Color = Color(0.75, 0.95, 1.0, 0.65)

var input_enabled: bool = true
var is_aiming: bool = false

# Player.gd turns this on during surface-walk mode.
# When true, the laser becomes a normal centered FPS reticle.
var force_aiming: bool = false

var laser_follow_speed_level: int = 0
var laser_attack_speed_level: int = 0

var camera: Camera3D
var owning_player: Node

var screen_aim_position: Vector2 = Vector2.ZERO
var desired_aim_direction: Vector3 = Vector3.FORWARD
var actual_aim_direction: Vector3 = Vector3.FORWARD

var fire_cooldown_remaining: float = 0.0

var shot_beam_core_material: StandardMaterial3D
var shot_beam_glow_material: StandardMaterial3D

var ui_layer: CanvasLayer
var actual_laser_dot: Panel
var desired_aim_circle: Panel
var surface_center_reticle: Panel


func _ready() -> void:
	camera = get_parent() as Camera3D
	
	if camera == null:
		push_error("LaserController must be a child of Camera3D.")
		return
	
	owning_player = camera
	while owning_player != null and not (owning_player is CollisionObject3D):
		owning_player = owning_player.get_parent()
	
	var center := get_viewport().get_visible_rect().size * 0.5
	screen_aim_position = center
	
	desired_aim_direction = (-camera.global_transform.basis.z).normalized()
	actual_aim_direction = desired_aim_direction
	
	setup_materials()
	setup_ui()


func setup_materials() -> void:
	shot_beam_core_material = BeamRenderer.make_material(shot_laser_core_color, shot_laser_core_emission_energy, false)
	shot_beam_glow_material = BeamRenderer.make_material(shot_laser_glow_color, shot_laser_glow_emission_energy, true)


func setup_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "LaserUILayer"
	ui_layer.layer = 90
	add_child(ui_layer)
	
	actual_laser_dot = create_filled_reticle(
		"ActualLaserDot",
		actual_dot_size,
		reticle_core_color
	)
	
	desired_aim_circle = create_hollow_reticle(
		"DesiredAimCircle",
		desired_circle_size,
		reticle_soft_color,
		desired_circle_border_width
	)
	
	surface_center_reticle = create_filled_reticle(
		"SurfaceCenterReticle",
		surface_center_reticle_size,
		reticle_core_color
	)
	
	ui_layer.visible = false
	hide_all_reticles()


func create_filled_reticle(reticle_name: String, size: float, color: Color) -> Panel:
	var reticle := Panel.new()
	reticle.name = reticle_name
	ui_layer.add_child(reticle)
	
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reticle.custom_minimum_size = Vector2(size, size)
	reticle.size = Vector2(size, size)
	reticle.pivot_offset = Vector2(size * 0.5, size * 0.5)
	
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color(0.75, 0.95, 1.0, 0.55)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 100
	style.corner_radius_top_right = 100
	style.corner_radius_bottom_left = 100
	style.corner_radius_bottom_right = 100
	
	reticle.add_theme_stylebox_override("panel", style)
	
	return reticle


func create_hollow_reticle(reticle_name: String, size: float, color: Color, border_width: int) -> Panel:
	var reticle := Panel.new()
	reticle.name = reticle_name
	ui_layer.add_child(reticle)
	
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reticle.custom_minimum_size = Vector2(size, size)
	reticle.size = Vector2(size, size)
	reticle.pivot_offset = Vector2(size * 0.5, size * 0.5)
	
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.35, 0.8, 1.0, 0.05)
	style.border_color = color
	style.border_width_left = border_width
	style.border_width_right = border_width
	style.border_width_top = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = 100
	style.corner_radius_top_right = 100
	style.corner_radius_bottom_left = 100
	style.corner_radius_bottom_right = 100
	
	reticle.add_theme_stylebox_override("panel", style)
	
	return reticle


func _input(event: InputEvent) -> void:
	if not input_enabled:
		return
	
	if force_aiming:
		return
	
	if event.is_action_pressed("laser_aim"):
		start_laser_aim()
	
	if event.is_action_released("laser_aim"):
		stop_laser_aim()
	
	if is_aiming and event is InputEventMouseMotion:
		screen_aim_position += event.relative * laser_screen_sensitivity
		clamp_screen_aim_position()


func _process(delta: float) -> void:
	if fire_cooldown_remaining > 0.0:
		fire_cooldown_remaining -= delta
		fire_cooldown_remaining = maxf(fire_cooldown_remaining, 0.0)
	
	if not input_enabled:
		stop_laser_aim()
		return
	
	if force_aiming:
		if not is_aiming:
			start_laser_aim()
		
		update_surface_center_aim()
		
		if Input.is_action_pressed("laser_fire"):
			try_fire_laser()
		
		return
	
	if is_aiming:
		update_follow_aim_direction(delta)
		update_follow_aim_visuals()
		
		if Input.is_action_pressed("laser_fire"):
			try_fire_laser()
	else:
		hide_aim_visuals()


func start_laser_aim() -> void:
	if camera == null:
		return
	
	is_aiming = true
	
	if ui_layer != null:
		ui_layer.visible = true
	
	if force_aiming:
		set_screen_aim_to_center()
		update_surface_center_aim()
		return
	
	if screen_aim_position == Vector2.ZERO:
		set_screen_aim_to_center()
	
	clamp_screen_aim_position()


func stop_laser_aim() -> void:
	if force_aiming and input_enabled:
		return
	
	is_aiming = false
	hide_aim_visuals()


func hide_aim_visuals() -> void:
	if ui_layer != null:
		ui_layer.visible = false
	
	hide_all_reticles()


func hide_all_reticles() -> void:
	if actual_laser_dot != null:
		actual_laser_dot.visible = false
	
	if desired_aim_circle != null:
		desired_aim_circle.visible = false
	
	if surface_center_reticle != null:
		surface_center_reticle.visible = false


func set_screen_aim_to_center() -> void:
	screen_aim_position = get_viewport().get_visible_rect().size * 0.5


func clamp_screen_aim_position() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	
	screen_aim_position.x = clampf(
		screen_aim_position.x,
		laser_crosshair_margin,
		viewport_size.x - laser_crosshair_margin
	)
	
	screen_aim_position.y = clampf(
		screen_aim_position.y,
		laser_crosshair_margin,
		viewport_size.y - laser_crosshair_margin
	)


func update_follow_aim_direction(delta: float) -> void:
	desired_aim_direction = camera.project_ray_normal(screen_aim_position).normalized()
	
	var follow_weight := 1.0 - exp(-laser_follow_speed * delta)
	actual_aim_direction = actual_aim_direction.lerp(desired_aim_direction, follow_weight).normalized()


func update_follow_aim_visuals() -> void:
	if camera == null:
		return
	
	if ui_layer != null:
		ui_layer.visible = true
	
	if surface_center_reticle != null:
		surface_center_reticle.visible = false
	
	update_desired_aim_circle()
	update_actual_laser_dot()


func update_desired_aim_circle() -> void:
	if desired_aim_circle == null:
		return
	
	desired_aim_circle.visible = true
	desired_aim_circle.position = screen_aim_position - desired_aim_circle.size * 0.5


func update_actual_laser_dot() -> void:
	if actual_laser_dot == null:
		return
	
	var origin := get_muzzle_position()
	var actual_end := get_laser_visual_end(origin, actual_aim_direction)
	
	if camera.is_position_behind(actual_end):
		actual_laser_dot.visible = false
		return
	
	var actual_screen_position := camera.unproject_position(actual_end)
	
	actual_laser_dot.visible = true
	actual_laser_dot.position = actual_screen_position - actual_laser_dot.size * 0.5


func update_surface_center_aim() -> void:
	if camera == null:
		return
	
	set_screen_aim_to_center()
	
	desired_aim_direction = camera.project_ray_normal(screen_aim_position).normalized()
	actual_aim_direction = desired_aim_direction
	
	if ui_layer != null:
		ui_layer.visible = true
	
	if actual_laser_dot != null:
		actual_laser_dot.visible = false
	
	if desired_aim_circle != null:
		desired_aim_circle.visible = false
	
	update_surface_center_reticle()


func update_surface_center_reticle() -> void:
	if surface_center_reticle == null:
		return
	
	var center := get_viewport().get_visible_rect().size * 0.5
	
	surface_center_reticle.visible = true
	surface_center_reticle.position = center - surface_center_reticle.size * 0.5


func get_laser_visual_end(origin: Vector3, direction: Vector3) -> Vector3:
	var end := origin + direction.normalized() * laser_range
	
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	if owning_player is CollisionObject3D:
		query.exclude = [owning_player.get_rid()]
	
	var result: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	
	if result.is_empty():
		return end
	
	return result["position"]


func try_fire_laser() -> void:
	if fire_cooldown_remaining > 0.0:
		return
	
	var origin := get_muzzle_position()
	var end := get_laser_visual_end(origin, actual_aim_direction)
	
	create_shot_beam(origin, end)
	
	fire_cooldown_remaining = laser_fire_cooldown


func create_shot_beam(origin: Vector3, end: Vector3) -> void:
	BeamRenderer.spawn(
		get_laser_beam_parent(),
		origin,
		end,
		shot_beam_core_material,
		shot_beam_glow_material,
		shot_laser_thickness,
		shot_laser_glow_thickness_multiplier,
		shot_laser_radial_segments,
		shot_laser_lifetime,
		"LocalShotLaser"
	)


func get_laser_beam_parent() -> Node:
	if owning_player != null:
		var player_parent := owning_player.get_parent()
		
		if player_parent != null:
			var world_parent := player_parent.get_parent()
			
			if world_parent != null:
				return world_parent
			
			return player_parent
	
	return self


func get_muzzle_position() -> Vector3:
	if camera == null:
		return global_position
	
	var camera_basis := camera.global_transform.basis
	
	return (
		camera.global_position
		+ camera_basis.x * muzzle_right_offset
		+ camera_basis.y * muzzle_up_offset
		+ (-camera_basis.z) * muzzle_forward_offset
	)


func set_input_enabled(value: bool) -> void:
	input_enabled = value
	
	if not input_enabled:
		force_aiming = false
		stop_laser_aim()


func set_force_aiming(value: bool) -> void:
	force_aiming = value
	
	if force_aiming and input_enabled:
		start_laser_aim()
		update_surface_center_aim()
	else:
		if not Input.is_action_pressed("laser_aim"):
			is_aiming = false
			hide_aim_visuals()


func is_laser_aiming() -> bool:
	return is_aiming and input_enabled


func apply_laser_follow_speed_upgrade(level: int) -> void:
	laser_follow_speed_level = clampi(level, 0, 3)
	laser_follow_speed = LASER_FOLLOW_SPEED_BY_LEVEL[laser_follow_speed_level]
	
	print("Laser follow speed upgraded to level ", laser_follow_speed_level, ". Speed: ", laser_follow_speed)


func get_laser_follow_speed_level() -> int:
	return laser_follow_speed_level


func apply_laser_attack_speed_upgrade(level: int) -> void:
	laser_attack_speed_level = clampi(level, 0, 3)
	laser_fire_cooldown = LASER_FIRE_COOLDOWN_BY_LEVEL[laser_attack_speed_level]
	
	print("Laser attack speed upgraded to level ", laser_attack_speed_level, ". Cooldown: ", laser_fire_cooldown)


func get_laser_attack_speed_level() -> int:
	return laser_attack_speed_level


func get_laser_fire_cooldown() -> float:
	return laser_fire_cooldown


func get_actual_laser_direction() -> Vector3:
	return actual_aim_direction.normalized()


func get_laser_muzzle_world_position() -> Vector3:
	return get_muzzle_position()


func get_laser_range() -> float:
	return laser_range
