class_name PlayerMovementController
extends Node

const GRAB_RANGE_BY_LEVEL := [2.5, 3.25, 4.25, 5.5]

@export var min_push_strength: float = 4.0
@export var max_push_strength: float = 24.0
@export var max_charge_time: float = 2.0

@export var push_range: float = 2.5
@export var grab_range: float = 2.5

@export var max_speed: float = 18.0
@export var max_angular_speed: float = 8.0

@export var mouse_sensitivity: float = 0.01
@export var aim_turn_rate: float = 6.0     # rad/s per unit of (sensitivity-scaled) mouse motion
@export var aim_response: float = 14.0     # how fast angular_velocity eases toward target (higher = snappier)
@export var aim_float_decay: float = 6.0   # how fast the target decays to 0 after mouse stops (lower = more float)
@export var roll_torque: float = 4.0
@export var stabilize_strength: float = 2.0

@export var free_look_sensitivity: float = 0.006
@export var free_look_max_angle_degrees: float = 80.0
@export var free_look_return_speed: float = 12.0

@export var grab_wall_offset: float = 0.75
@export var grab_roll_speed: float = 2.5
@export var grab_position_snap_speed: float = 10.0
@export var grab_rotation_snap_speed: float = 8.0

var player: RigidBody3D
var camera: Camera3D
var hud_controller: PlayerHUDController
var push_ray: RayCast3D

var mouse_motion: Vector2 = Vector2.ZERO
var target_angular_velocity: Vector3 = Vector3.ZERO
var free_look_mouse_motion: Vector2 = Vector2.ZERO
var free_look_yaw: float = 0.0
var free_look_pitch: float = 0.0
var camera_default_rotation: Vector3 = Vector3.ZERO

var is_charging_push: bool = false
var push_charge_time: float = 0.0

var is_grabbing: bool = false
var grabbed_normal: Vector3 = Vector3.UP
var grabbed_position: Vector3 = Vector3.ZERO
var grabbed_up_reference: Vector3 = Vector3.UP
var grabbed_roll_angle: float = 0.0

var grab_distance_level: int = 0


func setup(owner_player: RigidBody3D, owner_hud: PlayerHUDController) -> void:
	player = owner_player
	hud_controller = owner_hud
	
	camera = player.get_node_or_null("Camera3D") as Camera3D
	push_ray = player.get_node_or_null("Camera3D/RayCast3D") as RayCast3D
	
	if camera == null:
		push_error("MovementController could not find Camera3D.")
		return
	
	if push_ray == null:
		push_error("MovementController could not find Camera3D/RayCast3D.")
		return
	
	camera_default_rotation = camera.rotation
	
	grab_range = GRAB_RANGE_BY_LEVEL[grab_distance_level]
	
	push_ray.enabled = true
	set_push_ray_range(max(push_range, grab_range))
	
	print("MovementController setup complete")


func add_mouse_motion(relative_motion: Vector2) -> void:
	mouse_motion += relative_motion


func clear_mouse_motion() -> void:
	mouse_motion = Vector2.ZERO


func add_free_look_mouse_motion(relative_motion: Vector2) -> void:
	free_look_mouse_motion += relative_motion


func clear_free_look_mouse_motion() -> void:
	free_look_mouse_motion = Vector2.ZERO


func physics_update(
	delta: float,
	laser_aiming: bool,
	free_look_active: bool,
	input_locked: bool
) -> void:
	if player == null or push_ray == null:
		return
	
	if input_locked:
		cancel_push_charge()
		clear_mouse_motion()
		clear_free_look_mouse_motion()
		target_angular_velocity = Vector3.ZERO
		update_free_look(delta, false)
		return
	
	update_free_look(delta, free_look_active)
	handle_grab_input(laser_aiming)
	
	if is_grabbing:
		handle_grab_rotation(delta)
	elif free_look_active:
		clear_mouse_motion()
		handle_roll_and_stabilize()
	else:
		handle_rotation(delta)
	
	handle_push_charge(delta, laser_aiming)


func update_free_look(delta: float, free_look_active: bool) -> void:
	if camera == null:
		return
	
	if free_look_active:
		free_look_yaw -= free_look_mouse_motion.x * free_look_sensitivity
		free_look_pitch -= free_look_mouse_motion.y * free_look_sensitivity
		
		var max_angle := deg_to_rad(free_look_max_angle_degrees)
		free_look_yaw = clampf(free_look_yaw, -max_angle, max_angle)
		free_look_pitch = clampf(free_look_pitch, -max_angle, max_angle)
		
		free_look_mouse_motion = Vector2.ZERO
	else:
		var return_weight := 1.0 - exp(-free_look_return_speed * delta)
		free_look_yaw = lerpf(free_look_yaw, 0.0, return_weight)
		free_look_pitch = lerpf(free_look_pitch, 0.0, return_weight)
	
	camera.rotation = Vector3(
		camera_default_rotation.x + free_look_pitch,
		camera_default_rotation.y + free_look_yaw,
		camera_default_rotation.z
	)


func set_push_ray_range(ray_range: float) -> void:
	if push_ray == null:
		return
	
	push_ray.target_position = Vector3(0.0, 0.0, -ray_range)


func is_surface_in_interaction_range() -> bool:
	if push_ray == null:
		return false
	
	set_push_ray_range(max(push_range, grab_range))
	push_ray.force_raycast_update()
	
	return push_ray.is_colliding()


func handle_grab_input(laser_aiming: bool) -> void:
	if laser_aiming:
		return
	
	if Input.is_action_just_pressed("grab"):
		try_grab_wall()
	
	if Input.is_action_just_released("grab"):
		release_grab()


func try_grab_wall() -> void:
	set_push_ray_range(grab_range)
	push_ray.force_raycast_update()
	
	if not push_ray.is_colliding():
		print("No surface to grab")
		return
	
	var collision_point := push_ray.get_collision_point()
	var collision_normal := push_ray.get_collision_normal().normalized()
	
	is_grabbing = true
	
	grabbed_normal = collision_normal
	grabbed_position = collision_point + grabbed_normal * grab_wall_offset
	grabbed_up_reference = player.global_transform.basis.y
	grabbed_roll_angle = 0.0
	
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	
	print("Grabbed wall")


func release_grab() -> void:
	if not is_grabbing:
		return
	
	is_grabbing = false
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	
	print("Released wall")


func handle_rotation(delta: float) -> void:
	var body_basis := player.global_transform.basis

	# Decay the aim target toward rest so the view always settles (short float).
	var decay_weight := 1.0 - exp(-aim_float_decay * delta)
	target_angular_velocity = target_angular_velocity.lerp(Vector3.ZERO, decay_weight)

	# Replace (not accumulate) the target so a fresh flick overrides residual spin.
	if mouse_motion != Vector2.ZERO:
		var pitch := -mouse_motion.y * mouse_sensitivity * aim_turn_rate
		var yaw := -mouse_motion.x * mouse_sensitivity * aim_turn_rate

		target_angular_velocity = body_basis.x * pitch + body_basis.y * yaw

		mouse_motion = Vector2.ZERO

	handle_roll_and_stabilize()


func handle_roll_and_stabilize() -> void:
	var body_basis := player.global_transform.basis
	
	var roll := Input.get_axis("roll_right", "roll_left")
	var roll_torque_vector := -body_basis.z * roll * roll_torque
	
	player.apply_torque(roll_torque_vector)
	
	if Input.is_action_pressed("stabilize_rotation"):
		player.apply_torque(-player.angular_velocity * stabilize_strength)


func handle_grab_rotation(delta: float) -> void:
	mouse_motion = Vector2.ZERO
	
	var roll := Input.get_axis("roll_right", "roll_left")
	grabbed_roll_angle += roll * grab_roll_speed * delta


func handle_push_charge(delta: float, laser_aiming: bool) -> void:
	if laser_aiming:
		cancel_push_charge()
		return
	
	if Input.is_action_just_pressed("push"):
		is_charging_push = true
		push_charge_time = 0.0
		
		if hud_controller != null:
			hud_controller.update_push_charge_ui(0.0, true)
		
		print("Started charging push")
	
	if is_charging_push and Input.is_action_pressed("push"):
		push_charge_time += delta
		push_charge_time = min(push_charge_time, max_charge_time)

		var charge_percent := get_push_charge_percent()

		if hud_controller != null:
			hud_controller.update_push_charge_ui(charge_percent, true, has_push_target())
	
	if is_charging_push and Input.is_action_just_released("push"):
		var charge_percent := get_push_charge_percent()
		var final_push_strength := lerpf(min_push_strength, max_push_strength, charge_percent)
		
		if hud_controller != null:
			hud_controller.update_push_charge_ui(0.0, false)
		
		if is_grabbing:
			is_grabbing = false
		
		if is_ctrl_push_active():
			try_ctrl_push_off(final_push_strength, charge_percent)
		else:
			try_push_off(final_push_strength, charge_percent)
		
		is_charging_push = false
		push_charge_time = 0.0


func cancel_push_charge() -> void:
	if not is_charging_push:
		return
	
	is_charging_push = false
	push_charge_time = 0.0
	
	if hud_controller != null:
		hud_controller.update_push_charge_ui(0.0, false)


func get_push_charge_percent() -> float:
	if max_charge_time <= 0.0:
		return 1.0
	
	return clampf(push_charge_time / max_charge_time, 0.0, 1.0)


func is_ctrl_push_active() -> bool:
	return Input.is_action_pressed("ctrl_push")


# Whether releasing now would actually push off a surface (ahead, or behind for ctrl push).
func has_push_target() -> bool:
	if is_ctrl_push_active():
		return not get_back_push_result().is_empty()

	set_push_ray_range(push_range)
	push_ray.force_raycast_update()
	return push_ray.is_colliding()


func get_normal_push_direction() -> Vector3:
	# Player faces -Z, so +Z is directly behind the player.
	return player.global_transform.basis.z.normalized()


func get_ctrl_push_direction() -> Vector3:
	# Ctrl push launches in the direction the player is facing.
	return (-player.global_transform.basis.z).normalized()


func try_push_off(final_push_strength: float, charge_percent: float) -> void:
	set_push_ray_range(push_range)
	push_ray.force_raycast_update()
	
	if not push_ray.is_colliding():
		print("No surface to push from")
		return
	
	var collider := push_ray.get_collider()
	var collision_point := push_ray.get_collision_point()
	
	var push_direction := get_normal_push_direction()
	var impulse := push_direction * final_push_strength
	
	player.apply_central_impulse(impulse)
	
	print("Push released")
	print("Charge: ", round(charge_percent * 100.0), "%")
	print("Strength: ", final_push_strength)
	print("Push direction: ", push_direction)
	print("Pushed from: ", collider)
	
	if collider is RigidBody3D:
		collider.apply_impulse(-impulse, collision_point - collider.global_position)


func try_ctrl_push_off(final_push_strength: float, charge_percent: float) -> void:
	var result := get_back_push_result()
	
	if result.is_empty():
		print("No surface behind you for ctrl push")
		return
	
	var collider = result["collider"]
	var collision_point: Vector3 = result["position"]
	
	var push_direction := get_ctrl_push_direction()
	var impulse := push_direction * final_push_strength
	
	player.apply_central_impulse(impulse)
	
	print("Ctrl push released")
	print("Charge: ", round(charge_percent * 100.0), "%")
	print("Strength: ", final_push_strength)
	print("Ctrl push direction: ", push_direction)
	print("Pushed from behind surface: ", collider)
	
	if collider is RigidBody3D:
		collider.apply_impulse(-impulse, collision_point - collider.global_position)


func get_back_push_result() -> Dictionary:
	if player == null:
		return {}
	
	var from := player.global_position
	var backward_direction := player.global_transform.basis.z.normalized()
	var to := from + backward_direction * push_range
	
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	if player is CollisionObject3D:
		query.exclude = [player.get_rid()]
	
	var result := player.get_world_3d().direct_space_state.intersect_ray(query)
	
	return result


func should_show_ctrl_push_arrow(
	buy_menu_open: bool,
	free_look_active: bool,
	laser_aiming: bool,
	input_locked: bool
) -> bool:
	if buy_menu_open:
		return false
	
	if free_look_active:
		return false
	
	if laser_aiming:
		return false
	
	if input_locked:
		return false
	
	if not is_ctrl_push_active():
		return false
	
	return not get_back_push_result().is_empty()


func get_predicted_ctrl_push_direction() -> Vector3:
	return get_ctrl_push_direction()


func make_grab_basis(surface_normal: Vector3, roll_angle: float) -> Basis:
	var z_axis := surface_normal.normalized()
	
	var y_axis := grabbed_up_reference - z_axis * grabbed_up_reference.dot(z_axis)
	
	if y_axis.length() < 0.001:
		y_axis = Vector3.UP - z_axis * Vector3.UP.dot(z_axis)
	
	if y_axis.length() < 0.001:
		y_axis = Vector3.RIGHT - z_axis * Vector3.RIGHT.dot(z_axis)
	
	y_axis = y_axis.normalized()
	
	var x_axis := y_axis.cross(z_axis).normalized()
	y_axis = z_axis.cross(x_axis).normalized()
	
	var base_basis := Basis(x_axis, y_axis, z_axis).orthonormalized()
	var roll_basis := Basis(z_axis, roll_angle)
	
	return (roll_basis * base_basis).orthonormalized()


func integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if is_grabbing:
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		
		var delta := state.step
		
		var target_basis := make_grab_basis(grabbed_normal, grabbed_roll_angle)
		var target_position := grabbed_position
		
		var position_weight := 1.0 - exp(-grab_position_snap_speed * delta)
		var rotation_weight := 1.0 - exp(-grab_rotation_snap_speed * delta)
		
		var current_transform := state.transform
		
		var new_position := current_transform.origin.lerp(target_position, position_weight)
		var new_basis := current_transform.basis.slerp(target_basis, rotation_weight).orthonormalized()
		
		state.transform = Transform3D(new_basis, new_position)
		
		return
	
	if state.linear_velocity.length() > max_speed:
		state.linear_velocity = state.linear_velocity.normalized() * max_speed

	# Zero-G aim: ease body spin toward the desired aim velocity (1:1 with a little float).
	var aim_weight := 1.0 - exp(-aim_response * state.step)
	state.angular_velocity = state.angular_velocity.lerp(target_angular_velocity, aim_weight)

	if state.angular_velocity.length() > max_angular_speed:
		state.angular_velocity = state.angular_velocity.normalized() * max_angular_speed


func apply_grab_distance_upgrade(level: int) -> void:
	grab_distance_level = clampi(level, 0, 3)
	grab_range = GRAB_RANGE_BY_LEVEL[grab_distance_level]
	set_push_ray_range(max(push_range, grab_range))
	
	print("Grab distance upgraded to level ", grab_distance_level, ". Range: ", grab_range)


func get_grab_distance_level() -> int:
	return grab_distance_level


func is_grabbing_wall() -> bool:
	return is_grabbing
