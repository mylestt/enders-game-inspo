extends Node3D

const LASER_FOLLOW_SPEED_BY_LEVEL := [7.0, 10.0, 14.0, 20.0]
const AIM_LASER_THICKNESS_BY_LEVEL := [0.018, 0.028, 0.042, 0.06]
const SHOT_LASER_THICKNESS_BY_LEVEL := [0.055, 0.075, 0.105, 0.145]
const LASER_SPREAD_DEGREES_BY_LEVEL := [0.0, 0.8, 1.6, 2.8]

@export var laser_range: float = 80.0

@export var laser_screen_sensitivity: float = 1.0
@export var laser_crosshair_margin: float = 10.0

@export var muzzle_right_offset: float = 0.45
@export var muzzle_up_offset: float = 0.28
@export var muzzle_forward_offset: float = 0.15

@export var laser_follow_speed: float = 7.0

@export var laser_fire_cooldown: float = 0.2
@export var laser_beam_flash_time: float = 0.06

@export var aim_laser_thickness: float = 0.018
@export var shot_laser_thickness: float = 0.055
@export var aim_laser_alpha: float = 0.22
@export var shot_laser_alpha: float = 0.9
@export var laser_spread_degrees: float = 0.0

@export var reset_aim_when_starting: bool = true

@export var mouse_reticle_size: float = 24.0
@export var mouse_reticle_thickness: float = 2.0
@export var mouse_reticle_alpha: float = 0.65

@export var holo_reticle_size: float = 18.0
@export var holo_reticle_thickness: float = 2.0
@export var holo_reticle_alpha: float = 0.45

@export var reticle_fade_speed: float = 28.0

@export var camera_path: NodePath = NodePath("..")
@export var hud_path: NodePath = NodePath("../../UI/HUD")

var input_enabled: bool = true
var is_aiming: bool = false
var laser_fire_timer: float = 0.0
var laser_beam_timer: float = 0.0

var laser_follow_speed_level: int = 0
var laser_size_level: int = 0

var reticle_alpha: float = 0.0
var screen_aim_position: Vector2 = Vector2.ZERO

var desired_aim_direction: Vector3 = Vector3.FORWARD
var actual_aim_direction: Vector3 = Vector3.FORWARD
var last_laser_end_point: Vector3 = Vector3.ZERO

var laser_ray: RayCast3D
var laser_beam: MeshInstance3D
var laser_beam_mesh: BoxMesh
var laser_beam_material: StandardMaterial3D

var camera: Camera3D
var hud: Control

var mouse_reticle: Control
var mouse_reticle_circle: Panel

var holo_reticle: Control
var holo_reticle_circle: Panel


func _ready() -> void:
	camera = get_node_or_null(camera_path) as Camera3D
	hud = get_node_or_null(hud_path) as Control
	
	setup_laser_ray()
	setup_laser_beam()
	setup_reticles()
	center_screen_aim_position()
	
	apply_laser_follow_speed_upgrade(0)
	apply_laser_size_upgrade(0)
	
	actual_aim_direction = get_camera_forward_direction()
	desired_aim_direction = actual_aim_direction
	last_laser_end_point = global_position + actual_aim_direction * laser_range
	
	print("Laser controller setup complete")


func setup_laser_ray() -> void:
	laser_ray = get_node_or_null("LaserRay") as RayCast3D
	
	if laser_ray == null:
		laser_ray = RayCast3D.new()
		laser_ray.name = "LaserRay"
		add_child(laser_ray)
	
	laser_ray.enabled = true
	laser_ray.target_position = Vector3(0.0, 0.0, -laser_range)
	laser_ray.collide_with_bodies = true
	laser_ray.collide_with_areas = true
	
	var owner_body := get_owner_collision_body()
	
	if owner_body is CollisionObject3D:
		laser_ray.add_exception(owner_body)


func setup_laser_beam() -> void:
	laser_beam = get_node_or_null("LaserBeam") as MeshInstance3D
	
	if laser_beam == null:
		laser_beam = MeshInstance3D.new()
		laser_beam.name = "LaserBeam"
		add_child(laser_beam)
	
	laser_beam_mesh = BoxMesh.new()
	laser_beam_mesh.size = Vector3(aim_laser_thickness, aim_laser_thickness, 1.0)
	laser_beam.mesh = laser_beam_mesh
	
	laser_beam_material = StandardMaterial3D.new()
	laser_beam_material.albedo_color = Color(1.0, 1.0, 1.0, aim_laser_alpha)
	laser_beam_material.emission_enabled = true
	laser_beam_material.emission = Color.WHITE
	laser_beam_material.emission_energy_multiplier = 1.8
	laser_beam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	laser_beam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	laser_beam.material_override = laser_beam_material
	laser_beam.visible = false


func setup_reticles() -> void:
	if hud == null:
		push_warning("Laser HUD was not found. Expected path: ../../UI/HUD")
		return
	
	setup_mouse_reticle()
	setup_holo_reticle()


func setup_mouse_reticle() -> void:
	mouse_reticle = hud.get_node_or_null("LaserMouseReticle") as Control
	
	if mouse_reticle == null:
		mouse_reticle = Control.new()
		mouse_reticle.name = "LaserMouseReticle"
		hud.add_child(mouse_reticle)
	
	mouse_reticle.visible = false
	mouse_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_reticle.size = Vector2(mouse_reticle_size, mouse_reticle_size)
	mouse_reticle.modulate = Color(1.0, 1.0, 1.0, 0.0)
	
	mouse_reticle_circle = mouse_reticle.get_node_or_null("Circle") as Panel
	
	if mouse_reticle_circle == null:
		mouse_reticle_circle = Panel.new()
		mouse_reticle_circle.name = "Circle"
		mouse_reticle.add_child(mouse_reticle_circle)
	
	mouse_reticle_circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_reticle_circle.position = Vector2.ZERO
	mouse_reticle_circle.size = Vector2(mouse_reticle_size, mouse_reticle_size)
	
	var circle_style := StyleBoxFlat.new()
	circle_style.bg_color = Color(1.0, 1.0, 1.0, 0.0)
	circle_style.border_color = Color.WHITE
	circle_style.set_border_width_all(int(mouse_reticle_thickness))
	circle_style.corner_radius_top_left = 100
	circle_style.corner_radius_top_right = 100
	circle_style.corner_radius_bottom_left = 100
	circle_style.corner_radius_bottom_right = 100
	
	mouse_reticle_circle.add_theme_stylebox_override("panel", circle_style)


func setup_holo_reticle() -> void:
	holo_reticle = hud.get_node_or_null("LaserHoloReticle") as Control
	
	if holo_reticle == null:
		holo_reticle = Control.new()
		holo_reticle.name = "LaserHoloReticle"
		hud.add_child(holo_reticle)
	
	holo_reticle.visible = false
	holo_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holo_reticle.size = Vector2(holo_reticle_size, holo_reticle_size)
	holo_reticle.modulate = Color(1.0, 1.0, 1.0, 0.0)
	
	holo_reticle_circle = holo_reticle.get_node_or_null("Circle") as Panel
	
	if holo_reticle_circle == null:
		holo_reticle_circle = Panel.new()
		holo_reticle_circle.name = "Circle"
		holo_reticle.add_child(holo_reticle_circle)
	
	holo_reticle_circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holo_reticle_circle.position = Vector2.ZERO
	holo_reticle_circle.size = Vector2(holo_reticle_size, holo_reticle_size)
	
	var circle_style := StyleBoxFlat.new()
	circle_style.bg_color = Color(1.0, 1.0, 1.0, 0.0)
	circle_style.border_color = Color.WHITE
	circle_style.set_border_width_all(int(holo_reticle_thickness))
	circle_style.corner_radius_top_left = 100
	circle_style.corner_radius_top_right = 100
	circle_style.corner_radius_bottom_left = 100
	circle_style.corner_radius_bottom_right = 100
	
	holo_reticle_circle.add_theme_stylebox_override("panel", circle_style)


func center_screen_aim_position() -> void:
	var viewport_size := get_viewport_rect_size()
	screen_aim_position = viewport_size / 2.0


func get_viewport_rect_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _input(event: InputEvent) -> void:
	if not input_enabled:
		return
	
	if event is InputEventMouseMotion and is_aiming:
		screen_aim_position += event.relative * laser_screen_sensitivity
		clamp_screen_aim_position()
	
	if event.is_action_pressed("laser_fire") and is_aiming:
		try_fire_laser()


func _physics_process(delta: float) -> void:
	update_aim_state()
	
	if is_aiming:
		update_laser_aim(delta)
		update_laser_ray_and_beam()
	else:
		laser_beam.visible = false
	
	if laser_fire_timer > 0.0:
		laser_fire_timer -= delta
	
	if laser_beam_timer > 0.0:
		laser_beam_timer -= delta


func _process(delta: float) -> void:
	update_reticles(delta)


func update_aim_state() -> void:
	if not input_enabled:
		if is_aiming:
			stop_laser_aim()
		return
	
	var should_aim := Input.is_action_pressed("laser_aim")
	
	if should_aim and not is_aiming:
		start_laser_aim()
	elif not should_aim and is_aiming:
		stop_laser_aim()


func start_laser_aim() -> void:
	is_aiming = true
	
	if reset_aim_when_starting:
		center_screen_aim_position()
	
	clamp_screen_aim_position()
	
	desired_aim_direction = get_desired_direction_from_mouse_reticle()
	actual_aim_direction = desired_aim_direction
	
	update_laser_aim(0.0)
	update_laser_ray_and_beam()


func stop_laser_aim() -> void:
	is_aiming = false
	laser_beam.visible = false


func clamp_screen_aim_position() -> void:
	var viewport_size := get_viewport_rect_size()
	
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


func update_laser_aim(delta: float) -> void:
	desired_aim_direction = get_desired_direction_from_mouse_reticle()
	
	if delta <= 0.0:
		actual_aim_direction = desired_aim_direction
		return
	
	var follow_weight := 1.0 - exp(-laser_follow_speed * delta)
	actual_aim_direction = actual_aim_direction.slerp(desired_aim_direction, follow_weight).normalized()


func get_desired_direction_from_mouse_reticle() -> Vector3:
	if camera == null:
		return get_camera_forward_direction()
	
	var muzzle_position := get_muzzle_position()
	var camera_ray_origin := camera.project_ray_origin(screen_aim_position)
	var camera_ray_direction := camera.project_ray_normal(screen_aim_position).normalized()
	
	var target_point := camera_ray_origin + camera_ray_direction * laser_range
	
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera_ray_origin,
		camera_ray_origin + camera_ray_direction * laser_range
	)
	
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	var owner_body := get_owner_collision_body()
	
	if owner_body is CollisionObject3D:
		query.exclude = [owner_body.get_rid()]
	
	var result := space_state.intersect_ray(query)
	
	if result.has("position"):
		target_point = result["position"]
	
	var direction := target_point - muzzle_position
	
	if direction.length() < 0.001:
		return get_camera_forward_direction()
	
	return direction.normalized()


func update_laser_ray_and_beam() -> void:
	var muzzle_position := get_muzzle_position()
	
	global_position = muzzle_position
	
	var up_direction := get_laser_up_direction()
	look_at(muzzle_position + actual_aim_direction, up_direction)
	
	laser_ray.target_position = Vector3(0.0, 0.0, -laser_range)
	laser_ray.force_raycast_update()
	
	last_laser_end_point = get_laser_end_point()
	
	var beam_length := muzzle_position.distance_to(last_laser_end_point)
	update_laser_beam_visual(beam_length)


func update_laser_beam_visual(beam_length: float) -> void:
	beam_length = maxf(beam_length, 0.01)
	
	var current_thickness := aim_laser_thickness
	var current_alpha := aim_laser_alpha
	var emission_power := 1.8
	
	if laser_beam_timer > 0.0:
		current_thickness = shot_laser_thickness
		current_alpha = shot_laser_alpha
		emission_power = 4.0
	
	laser_beam_mesh.size = Vector3(
		current_thickness,
		current_thickness,
		beam_length
	)
	
	laser_beam.position = Vector3(0.0, 0.0, -beam_length / 2.0)
	
	laser_beam_material.albedo_color = Color(1.0, 1.0, 1.0, current_alpha)
	laser_beam_material.emission_energy_multiplier = emission_power
	
	laser_beam.visible = is_aiming


func get_muzzle_position() -> Vector3:
	if camera == null:
		return global_position
	
	var basis := camera.global_transform.basis
	
	return (
		camera.global_position
		+ basis.x * muzzle_right_offset
		+ basis.y * muzzle_up_offset
		+ (-basis.z) * muzzle_forward_offset
	)


func get_laser_up_direction() -> Vector3:
	if camera == null:
		return Vector3.UP
	
	var up_direction := camera.global_transform.basis.y
	
	if abs(actual_aim_direction.dot(up_direction)) > 0.98:
		up_direction = camera.global_transform.basis.x
	
	return up_direction


func get_camera_forward_direction() -> Vector3:
	if camera == null:
		return -global_transform.basis.z
	
	return -camera.global_transform.basis.z


func try_fire_laser() -> void:
	if laser_fire_timer > 0.0:
		return
	
	laser_fire_timer = laser_fire_cooldown
	laser_beam_timer = laser_beam_flash_time
	
	update_laser_ray_and_beam()
	
	var hit := find_laser_fire_hit()
	
	if hit.has("collider"):
		var collider = hit["collider"]
		var hit_point: Vector3 = hit["position"]
		
		print("Laser hit: ", collider, " at ", hit_point)
		
		if collider != null and collider.has_method("take_laser_hit"):
			collider.call("take_laser_hit", self, hit_point)
	else:
		print("Laser missed")


func find_laser_fire_hit() -> Dictionary:
	var muzzle_position := get_muzzle_position()
	var directions := get_laser_fire_directions()
	var best_hit: Dictionary = {}
	var best_distance := INF
	
	var space_state := get_world_3d().direct_space_state
	
	for direction in directions:
		var query := PhysicsRayQueryParameters3D.create(
			muzzle_position,
			muzzle_position + direction * laser_range
		)
		
		query.collide_with_bodies = true
		query.collide_with_areas = true
		
		var owner_body := get_owner_collision_body()
		
		if owner_body is CollisionObject3D:
			query.exclude = [owner_body.get_rid()]
		
		var result := space_state.intersect_ray(query)
		
		if result.has("position"):
			var hit_distance := muzzle_position.distance_to(result["position"])
			
			if hit_distance < best_distance:
				best_distance = hit_distance
				best_hit = result
	
	return best_hit


func get_laser_fire_directions() -> Array[Vector3]:
	var directions: Array[Vector3] = []
	var forward := actual_aim_direction.normalized()
	
	directions.append(forward)
	
	if laser_spread_degrees <= 0.01:
		return directions
	
	var angle := deg_to_rad(laser_spread_degrees)
	var up := get_laser_up_direction().normalized()
	var right := forward.cross(up).normalized()
	up = right.cross(forward).normalized()
	
	var spread_amount := tan(angle)
	
	directions.append((forward + right * spread_amount).normalized())
	directions.append((forward - right * spread_amount).normalized())
	directions.append((forward + up * spread_amount).normalized())
	directions.append((forward - up * spread_amount).normalized())
	
	var diagonal_amount := spread_amount * 0.707
	
	directions.append((forward + right * diagonal_amount + up * diagonal_amount).normalized())
	directions.append((forward - right * diagonal_amount + up * diagonal_amount).normalized())
	directions.append((forward + right * diagonal_amount - up * diagonal_amount).normalized())
	directions.append((forward - right * diagonal_amount - up * diagonal_amount).normalized())
	
	return directions


func update_reticles(delta: float) -> void:
	var target_alpha := 0.0
	
	if is_aiming:
		target_alpha = 1.0
	
	var fade_weight := 1.0 - exp(-reticle_fade_speed * delta)
	reticle_alpha = lerpf(reticle_alpha, target_alpha, fade_weight)
	
	update_mouse_reticle_visual()
	update_holo_reticle_visual()


func update_mouse_reticle_visual() -> void:
	if mouse_reticle == null:
		return
	
	mouse_reticle.modulate = Color(1.0, 1.0, 1.0, reticle_alpha * mouse_reticle_alpha)
	mouse_reticle.visible = reticle_alpha > 0.01
	mouse_reticle.position = screen_aim_position - (mouse_reticle.size / 2.0)


func update_holo_reticle_visual() -> void:
	if holo_reticle == null or camera == null:
		return
	
	var holo_world_point := get_holo_world_point()
	
	if camera.is_position_behind(holo_world_point):
		holo_reticle.visible = false
		return
	
	var holo_screen_position := camera.unproject_position(holo_world_point)
	
	holo_reticle.modulate = Color(1.0, 1.0, 1.0, reticle_alpha * holo_reticle_alpha)
	holo_reticle.visible = reticle_alpha > 0.01
	holo_reticle.position = holo_screen_position - (holo_reticle.size / 2.0)


func get_holo_world_point() -> Vector3:
	var muzzle_position := get_muzzle_position()
	
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		muzzle_position,
		muzzle_position + actual_aim_direction * laser_range
	)
	
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	var owner_body := get_owner_collision_body()
	
	if owner_body is CollisionObject3D:
		query.exclude = [owner_body.get_rid()]
	
	var result := space_state.intersect_ray(query)
	
	if result.has("position"):
		return result["position"]
	
	return muzzle_position + actual_aim_direction * laser_range


func get_laser_end_point() -> Vector3:
	if laser_ray.is_colliding():
		return laser_ray.get_collision_point()
	
	return global_position + (-global_transform.basis.z * laser_range)


func get_owner_collision_body() -> CollisionObject3D:
	var node := get_parent()
	
	while node != null:
		if node is CollisionObject3D:
			return node
		
		node = node.get_parent()
	
	return null


func apply_laser_follow_speed_upgrade(level: int) -> void:
	laser_follow_speed_level = clampi(level, 0, 3)
	laser_follow_speed = LASER_FOLLOW_SPEED_BY_LEVEL[laser_follow_speed_level]
	
	print("Laser tracking upgraded to level ", laser_follow_speed_level, ". Follow speed: ", laser_follow_speed)


func get_laser_follow_speed_level() -> int:
	return laser_follow_speed_level


func apply_laser_size_upgrade(level: int) -> void:
	laser_size_level = clampi(level, 0, 3)
	
	aim_laser_thickness = AIM_LASER_THICKNESS_BY_LEVEL[laser_size_level]
	shot_laser_thickness = SHOT_LASER_THICKNESS_BY_LEVEL[laser_size_level]
	laser_spread_degrees = LASER_SPREAD_DEGREES_BY_LEVEL[laser_size_level]
	
	print(
		"Laser size upgraded to level ",
		laser_size_level,
		". Aim thickness: ",
		aim_laser_thickness,
		". Shot thickness: ",
		shot_laser_thickness,
		". Spread degrees: ",
		laser_spread_degrees
	)


func get_laser_size_level() -> int:
	return laser_size_level


func set_input_enabled(value: bool) -> void:
	input_enabled = value
	
	if not input_enabled:
		stop_laser_aim()


func is_laser_aiming() -> bool:
	return is_aiming
