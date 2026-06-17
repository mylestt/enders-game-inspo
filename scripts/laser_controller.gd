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

@export var shot_laser_thickness: float = 0.055
@export var shot_laser_lifetime: float = 0.08

@export var hipfire_bloom: float = 0.025      # base random spread when not aiming
@export var hipfire_move_bloom: float = 0.04  # extra spread at full speed
@export var hipfire_move_bias: float = 0.01   # how much movement drifts the shot
@export var hipfire_speed_ref: float = 18.0   # speed treated as "full" (matches max_speed)

@export var actual_dot_size: float = 8.0
@export var desired_circle_size: float = 22.0
@export var desired_circle_border_width: int = 2

var input_enabled: bool = true
var is_aiming: bool = false

var laser_follow_speed_level: int = 0
var laser_attack_speed_level: int = 0

var camera: Camera3D
var owning_player: Node
var weapon: Node

var screen_aim_position: Vector2 = Vector2.ZERO
var desired_aim_direction: Vector3 = Vector3.FORWARD
var actual_aim_direction: Vector3 = Vector3.FORWARD
var last_fire_direction: Vector3 = Vector3.FORWARD

var fire_cooldown_remaining: float = 0.0

var shot_beam_material: StandardMaterial3D

var ui_layer: CanvasLayer
var actual_laser_dot: Panel
var desired_aim_circle: Panel


func _ready() -> void:
	camera = get_parent() as Camera3D
	
	if camera == null:
		push_error("LaserController must be a child of Camera3D.")
		return
	
	owning_player = camera.get_parent()
	weapon = camera.get_node_or_null("HandHolster")

	var center := get_viewport().get_visible_rect().size * 0.5
	screen_aim_position = center
	
	desired_aim_direction = (-camera.global_transform.basis.z).normalized()
	actual_aim_direction = desired_aim_direction
	
	setup_materials()
	setup_ui()


func setup_materials() -> void:
	shot_beam_material = StandardMaterial3D.new()
	shot_beam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shot_beam_material.albedo_color = Color(1.0, 0.0, 0.0, 0.95)
	shot_beam_material.emission_enabled = true
	shot_beam_material.emission = Color(1.0, 0.0, 0.0, 1.0)
	shot_beam_material.emission_energy_multiplier = 6.0
	shot_beam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


func setup_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "LaserUILayer"
	ui_layer.layer = 90
	add_child(ui_layer)
	
	actual_laser_dot = create_filled_reticle(
		"ActualLaserDot",
		actual_dot_size,
		Color(1.0, 1.0, 1.0, 0.95)
	)
	
	desired_aim_circle = create_hollow_reticle(
		"DesiredAimCircle",
		desired_circle_size,
		Color(1.0, 1.0, 1.0, 0.8),
		desired_circle_border_width
	)
	
	ui_layer.visible = false


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
	style.bg_color = Color(1.0, 1.0, 1.0, 0.0)
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
	
	if is_aiming:
		update_aim_direction(delta)
		update_aim_visuals()
	else:
		hide_aim_visuals()

	# Fire in both modes; not aiming just means no reticle, so it's inaccurate.
	if Input.is_action_pressed("laser_fire"):
		try_fire_laser()


func start_laser_aim() -> void:
	if camera == null:
		return
	
	is_aiming = true
	
	if ui_layer != null:
		ui_layer.visible = true
	
	if screen_aim_position == Vector2.ZERO:
		screen_aim_position = get_viewport().get_visible_rect().size * 0.5
	
	clamp_screen_aim_position()


func stop_laser_aim() -> void:
	is_aiming = false
	hide_aim_visuals()


func hide_aim_visuals() -> void:
	if ui_layer != null:
		ui_layer.visible = false


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


func update_aim_direction(delta: float) -> void:
	desired_aim_direction = camera.project_ray_normal(screen_aim_position).normalized()
	
	var follow_weight := 1.0 - exp(-laser_follow_speed * delta)
	actual_aim_direction = actual_aim_direction.lerp(desired_aim_direction, follow_weight).normalized()


func update_aim_visuals() -> void:
	if camera == null:
		return
	
	if ui_layer != null:
		ui_layer.visible = true
	
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
	last_fire_direction = compute_fire_direction()
	var end := get_laser_visual_end(origin, last_fire_direction)

	create_shot_beam(origin, end)

	if weapon != null and weapon.has_method("fire"):
		weapon.call("fire")

	fire_cooldown_remaining = laser_fire_cooldown


func create_shot_beam(origin: Vector3, end: Vector3) -> void:
	var beam := MeshInstance3D.new()
	beam.name = "LocalShotLaserBeam"
	
	var mesh := CylinderMesh.new()
	mesh.top_radius = shot_laser_thickness
	mesh.bottom_radius = shot_laser_thickness
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.material = shot_beam_material
	
	beam.mesh = mesh
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	add_child(beam)
	draw_beam(beam, mesh, origin, end, shot_laser_thickness)
	
	var timer := get_tree().create_timer(shot_laser_lifetime)
	timer.timeout.connect(
		func() -> void:
			if is_instance_valid(beam):
				beam.queue_free()
	)


func draw_beam(
	beam: MeshInstance3D,
	mesh: CylinderMesh,
	origin: Vector3,
	end: Vector3,
	radius: float
) -> void:
	if beam == null or mesh == null:
		return
	
	var direction := end - origin
	var length := direction.length()
	
	if length < 0.05:
		beam.visible = false
		return
	
	mesh.height = length
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	
	var midpoint := origin + direction * 0.5
	var beam_basis := make_y_aligned_basis(direction.normalized())
	
	beam.global_transform = Transform3D(beam_basis, midpoint)
	beam.visible = true


func make_y_aligned_basis(y_axis: Vector3) -> Basis:
	y_axis = y_axis.normalized()
	
	var helper := Vector3.UP
	
	if absf(y_axis.dot(helper)) > 0.95:
		helper = Vector3.RIGHT
	
	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	
	return Basis(x_axis, y_axis, z_axis).orthonormalized()


func get_muzzle_position() -> Vector3:
	if weapon != null and weapon.has_method("get_muzzle_world_position"):
		return weapon.call("get_muzzle_world_position")

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
		stop_laser_aim()


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


# Returns the direction of the most recent shot, so the local beam and the
# networked hit-reg use the exact same (bloomed) ray.
func get_fire_direction() -> Vector3:
	return last_fire_direction


# Accurate down the reticle when aiming; loose hip-fire with movement-driven
# spread otherwise. Movement bias is deterministic; only a little is random.
func compute_fire_direction() -> Vector3:
	if is_aiming:
		return actual_aim_direction.normalized()

	if camera == null:
		return actual_aim_direction.normalized()

	var cam_basis := camera.global_transform.basis
	var velocity := Vector3.ZERO
	if owning_player is RigidBody3D:
		velocity = (owning_player as RigidBody3D).linear_velocity

	var speed_factor := clampf(velocity.length() / hipfire_speed_ref, 0.0, 1.0)
	var spread := hipfire_bloom + speed_factor * hipfire_move_bloom

	var offset := Vector2(
		cam_basis.x.dot(velocity) * hipfire_move_bias + randf_range(-spread, spread),
		cam_basis.y.dot(velocity) * hipfire_move_bias + randf_range(-spread, spread)
	)

	return (-cam_basis.z + cam_basis.x * offset.x + cam_basis.y * offset.y).normalized()


func get_laser_muzzle_world_position() -> Vector3:
	return get_muzzle_position()


func get_laser_range() -> float:
	return laser_range
