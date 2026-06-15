class_name PlayerMovementController
extends Node

const GRAB_RANGE_BY_LEVEL := [2.5, 3.25, 4.25, 5.5]

@export var min_push_strength: float = 4.0
@export var max_push_strength: float = 24.0
@export var max_charge_time: float = 2.0

@export var push_range: float = 2.5
@export var grab_range: float = 2.5

@export var max_speed: float = 18.0
@export var max_angular_speed: float = 5.0

@export var mouse_sensitivity: float = 0.01
@export var mouse_rotation_strength: float = 0.15
@export var roll_torque: float = -4.0
@export var stabilize_strength: float = 2.0

@export var grab_wall_offset: float = 0.75
@export var grab_roll_speed: float = 2.5
@export var grab_position_snap_speed: float = 10.0
@export var grab_rotation_snap_speed: float = 8.0

var player: RigidBody3D
var hud_controller: PlayerHUDController
var push_ray: RayCast3D

var mouse_motion: Vector2 = Vector2.ZERO

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
	
	push_ray = player.get_node_or_null("Camera3D/RayCast3D") as RayCast3D
	
	if push_ray == null:
		push_error("MovementController could not find Camera3D/RayCast3D.")
		return
	
	grab_range = GRAB_RANGE_BY_LEVEL[grab_distance_level]
	
	push_ray.enabled = true
	set_push_ray_range(max(push_range, grab_range))
	
	print("MovementController setup complete")


func add_mouse_motion(relative_motion: Vector2) -> void:
	mouse_motion += relative_motion


func clear_mouse_motion() -> void:
	mouse_motion = Vector2.ZERO


func physics_update(delta: float, laser_aiming: bool) -> void:
	if player == null or push_ray == null:
		return
	
	handle_grab_input(laser_aiming)
	
	if is_grabbing:
		handle_grab_rotation(delta)
	else:
		handle_rotation(delta)
	
	handle_push_charge(delta, laser_aiming)


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


func handle_rotation(_delta: float) -> void:
	var body_basis := player.global_transform.basis
	
	if mouse_motion != Vector2.ZERO:
		var pitch := -mouse_motion.y * mouse_sensitivity * mouse_rotation_strength
		var yaw := -mouse_motion.x * mouse_sensitivity * mouse_rotation_strength
		
		var mouse_torque := Vector3.ZERO
		mouse_torque += body_basis.x * pitch
		mouse_torque += body_basis.y * yaw
		
		player.apply_torque_impulse(mouse_torque)
		
		mouse_motion = Vector2.ZERO
	
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
			hud_controller.update_push_charge_ui(charge_percent, true)
	
	if is_charging_push and Input.is_action_just_released("push"):
		var charge_percent := get_push_charge_percent()
		var final_push_strength := lerpf(min_push_strength, max_push_strength, charge_percent)
		
		if hud_controller != null:
			hud_controller.update_push_charge_ui(0.0, false)
		
		if is_grabbing:
			is_grabbing = false
		
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


func try_push_off(final_push_strength: float, charge_percent: float) -> void:
	set_push_ray_range(push_range)
	push_ray.force_raycast_update()
	
	if not push_ray.is_colliding():
		print("No surface to push from")
		return
	
	var collider := push_ray.get_collider()
	var normal := push_ray.get_collision_normal()
	var collision_point := push_ray.get_collision_point()
	
	var impulse := normal * final_push_strength
	
	player.apply_central_impulse(impulse)
	
	print("Push released")
	print("Charge: ", round(charge_percent * 100.0), "%")
	print("Strength: ", final_push_strength)
	print("Pushed off: ", collider)
	
	if collider is RigidBody3D:
		collider.apply_impulse(-impulse, collision_point - collider.global_position)


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
