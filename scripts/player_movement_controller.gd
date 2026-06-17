extends Node
class_name PlayerMovementController

@export var mouse_sensitivity: float = 0.0025
@export var free_look_sensitivity: float = 0.0025

@export var roll_torque: float = 10.0
@export var stabilize_strength: float = 7.5

@export var surface_check_distance: float = 2.25
@export var ctrl_push_check_distance: float = 2.75

@export var jump_force: float = 10.0
@export var min_jump_force: float = 2.0
@export var max_jump_force: float = 30.0
@export var jump_force_scroll_step: float = 1.0

@export var max_grab_speed: float = 10.0

@export var grab_distance_base: float = 2.1
@export var grab_distance_level_1: float = 2.75
@export var grab_distance_level_2: float = 3.4
@export var grab_distance_level_3: float = 4.2

@export var grabbed_linear_damp: float = 12.0
@export var grabbed_angular_damp: float = 4.0

var player: RigidBody3D
var hud_controller: PlayerHUDController

var mouse_motion: Vector2 = Vector2.ZERO
var free_look_mouse_motion: Vector2 = Vector2.ZERO

var grabbing_wall: bool = false
var grab_position: Vector3 = Vector3.ZERO
var grab_distance_level: int = 0

var last_surface_result: Dictionary = {}
var last_ctrl_push_result: Dictionary = {}


func setup(owner_player: RigidBody3D, owner_hud_controller: PlayerHUDController) -> void:
	player = owner_player
	hud_controller = owner_hud_controller
	
	jump_force = clampf(jump_force, min_jump_force, max_jump_force)
	
	if hud_controller != null:
		hud_controller.update_jump_force(jump_force)


func _input(event: InputEvent) -> void:
	if not can_adjust_jump_force():
		return
	
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		
		if not mouse_event.pressed:
			return
		
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			change_jump_force(jump_force_scroll_step)
			get_viewport().set_input_as_handled()
		
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			change_jump_force(-jump_force_scroll_step)
			get_viewport().set_input_as_handled()


func can_adjust_jump_force() -> bool:
	if player == null:
		return false
	
	if "is_local_player" in player and not player.is_local_player:
		return false
	
	if "buy_menu_open" in player and player.buy_menu_open:
		return false
	
	if player.has_method("is_input_locked") and player.call("is_input_locked"):
		return false
	
	return true


func change_jump_force(amount: float) -> void:
	jump_force = clampf(jump_force + amount, min_jump_force, max_jump_force)
	
	if hud_controller != null:
		hud_controller.update_jump_force(jump_force)


func add_mouse_motion(relative_motion: Vector2) -> void:
	mouse_motion += relative_motion


func add_free_look_mouse_motion(relative_motion: Vector2) -> void:
	free_look_mouse_motion += relative_motion


func clear_mouse_motion() -> void:
	mouse_motion = Vector2.ZERO


func clear_free_look_mouse_motion() -> void:
	free_look_mouse_motion = Vector2.ZERO


func physics_update(
	_delta: float,
	laser_aiming: bool,
	free_look_active: bool,
	input_locked: bool
) -> void:
	if player == null:
		return
	
	update_surface_cache()
	update_ctrl_push_cache()
	
	if hud_controller != null:
		hud_controller.update_jump_force(jump_force)
	
	if input_locked:
		clear_mouse_motion()
		clear_free_look_mouse_motion()
		return
	
	if free_look_active:
		handle_free_look_rotation()
	else:
		handle_body_mouse_rotation()
	
	if not laser_aiming:
		handle_jump_input()
		handle_grab_input()
		handle_roll_input()
		handle_stabilize_input()
	else:
		release_grab()
	
	clear_mouse_motion()
	clear_free_look_mouse_motion()


func integrate_forces(_state: PhysicsDirectBodyState3D) -> void:
	if player == null:
		return
	
	if grabbing_wall:
		player.linear_velocity = player.linear_velocity.lerp(Vector3.ZERO, 0.55)
		player.angular_velocity = player.angular_velocity.lerp(Vector3.ZERO, 0.25)


func handle_body_mouse_rotation() -> void:
	if mouse_motion == Vector2.ZERO:
		return
	
	player.rotate_object_local(Vector3.UP, -mouse_motion.x * mouse_sensitivity)
	player.rotate_object_local(Vector3.RIGHT, -mouse_motion.y * mouse_sensitivity)
	player.global_transform.basis = player.global_transform.basis.orthonormalized()


func handle_free_look_rotation() -> void:
	free_look_mouse_motion = Vector2.ZERO


func handle_jump_input() -> void:
	if not InputMap.has_action("push"):
		return
	
	if not Input.is_action_just_pressed("push"):
		return
	
	if InputMap.has_action("ctrl_push") and Input.is_action_pressed("ctrl_push"):
		try_ctrl_push()
	else:
		try_normal_push()


func try_normal_push() -> void:
	var result := get_normal_push_result()
	
	if result.is_empty():
		return
	
	var direction := get_normal_push_direction()
	apply_jump_impulse(direction, result)


func try_ctrl_push() -> void:
	var result := get_ctrl_push_result()
	
	if result.is_empty():
		return
	
	var direction := get_ctrl_push_direction()
	apply_jump_impulse(direction, result)


func apply_jump_impulse(direction: Vector3, surface_result: Dictionary) -> void:
	if player == null:
		return
	
	if direction.length() < 0.01:
		return
	
	release_grab()
	
	var impulse := direction.normalized() * jump_force
	player.sleeping = false
	player.apply_central_impulse(impulse)
	
	var collider = surface_result.get("collider", null)
	var collision_position: Vector3 = surface_result.get("position", player.global_position)
	
	if collider is RigidBody3D:
		var rigid_collider := collider as RigidBody3D
		rigid_collider.sleeping = false
		rigid_collider.apply_impulse(-impulse, collision_position - rigid_collider.global_position)


func get_normal_push_direction() -> Vector3:
	if player == null:
		return Vector3.ZERO
	
	return player.global_transform.basis.z.normalized()


func get_ctrl_push_direction() -> Vector3:
	if player == null:
		return Vector3.ZERO
	
	return (-player.global_transform.basis.z).normalized()


func handle_grab_input() -> void:
	if not InputMap.has_action("grab"):
		return
	
	if Input.is_action_pressed("grab"):
		try_grab()
	else:
		release_grab()


func try_grab() -> void:
	if player == null:
		return
	
	var current_speed := player.linear_velocity.length()
	
	if current_speed > max_grab_speed:
		release_grab()
		return
	
	var result := get_normal_push_result()
	
	if result.is_empty():
		release_grab()
		return
	
	grabbing_wall = true
	grab_position = result.get("position", player.global_position)
	
	player.linear_velocity = player.linear_velocity.lerp(Vector3.ZERO, 0.8)
	player.angular_velocity = player.angular_velocity.lerp(Vector3.ZERO, 0.35)


func release_grab() -> void:
	grabbing_wall = false


func handle_roll_input() -> void:
	var roll_input := 0.0
	
	if InputMap.has_action("roll_left") and Input.is_action_pressed("roll_left"):
		roll_input += 1.0
	
	if InputMap.has_action("roll_right") and Input.is_action_pressed("roll_right"):
		roll_input -= 1.0
	
	if roll_input == 0.0:
		return
	
	var roll_axis := (-player.global_transform.basis.z).normalized()
	player.apply_torque(roll_axis * roll_input * roll_torque)


func handle_stabilize_input() -> void:
	if not InputMap.has_action("stabilize_rotation"):
		return
	
	if not Input.is_action_pressed("stabilize_rotation"):
		return
	
	player.angular_velocity = player.angular_velocity.lerp(Vector3.ZERO, 0.12)
	player.apply_torque(-player.angular_velocity * stabilize_strength)


func update_surface_cache() -> void:
	last_surface_result = get_normal_push_result()


func update_ctrl_push_cache() -> void:
	last_ctrl_push_result = get_ctrl_push_result()


func get_normal_push_result() -> Dictionary:
	if player == null:
		return {}
	
	var origin := player.global_position
	var direction := (-player.global_transform.basis.z).normalized()
	var end := origin + direction * get_current_grab_distance()
	
	return raycast_from_player(origin, end)


func get_ctrl_push_result() -> Dictionary:
	if player == null:
		return {}
	
	var origin := player.global_position
	var direction := player.global_transform.basis.z.normalized()
	var end := origin + direction * ctrl_push_check_distance
	
	return raycast_from_player(origin, end)


func raycast_from_player(origin: Vector3, end: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	if player is CollisionObject3D:
		query.exclude = [player.get_rid()]
	
	return player.get_world_3d().direct_space_state.intersect_ray(query)


func is_surface_in_interaction_range() -> bool:
	return not last_surface_result.is_empty()


func is_grabbing_wall() -> bool:
	return grabbing_wall


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
	
	if not InputMap.has_action("ctrl_push"):
		return false
	
	if not Input.is_action_pressed("ctrl_push"):
		return false
	
	return not last_ctrl_push_result.is_empty()


func get_predicted_ctrl_push_direction() -> Vector3:
	return get_ctrl_push_direction()


func apply_grab_distance_upgrade(level: int) -> void:
	grab_distance_level = clampi(level, 0, 3)
	print("Grab distance upgraded to level ", grab_distance_level, ". Distance: ", get_current_grab_distance())


func get_grab_distance_level() -> int:
	return grab_distance_level


func get_current_grab_distance() -> float:
	match grab_distance_level:
		1:
			return grab_distance_level_1
		2:
			return grab_distance_level_2
		3:
			return grab_distance_level_3
	
	return grab_distance_base
