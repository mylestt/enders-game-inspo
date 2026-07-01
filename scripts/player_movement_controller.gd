extends Node
class_name PlayerMovementController

enum MovementMode {
	ZERO_G,
	SURFACE_WALK
}

@export var mouse_sensitivity: float = 0.0025
@export var free_look_sensitivity: float = 0.0025
@export var look_neck_limit_degrees: float = 70.0
@export var body_follow_speed: float = 6.0

@export var roll_torque: float = 10.0
@export var roll_start_torque: float = 1.5
@export var roll_ramp_time: float = 1.2
@export var roll_settle_rate: float = 8.0
@export var stabilize_strength: float = 7.5

@export var surface_check_distance: float = 2.25
@export var ctrl_push_check_distance: float = 2.75

@export var jump_force: float = 10.0
@export var min_jump_force: float = 2.0
@export var max_jump_force: float = 30.0
@export var jump_force_scroll_step: float = 1.0

@export var max_grab_speed: float = 10.0

@export var use_limb_push_system: bool = true
@export var auto_create_limb_push_controller: bool = true
@export var limb_push_controller_path: NodePath
@export var use_limb_push_force_scaling: bool = true
@export var allow_legacy_center_push_fallback: bool = true
@export var show_limb_push_debug_ui: bool = true
@export var show_limb_push_ui_when_no_limb_near: bool = true
@export var debug_print_limb_pushes: bool = true

@export var grab_distance_base: float = 2.1
@export var grab_distance_level_1: float = 2.75
@export var grab_distance_level_2: float = 3.4
@export var grab_distance_level_3: float = 4.2

@export var grabbed_linear_damp: float = 12.0
@export var grabbed_angular_damp: float = 4.0

@export var surface_walk_speed: float = 3.0
@export var surface_walk_sprint_multiplier: float = 1.6

@export var surface_walk_use_auto_acceleration: bool = true
@export var surface_walk_time_to_full_speed: float = 0.18
@export var surface_walk_acceleration: float = 60.0
@export var surface_walk_sprint_acceleration_multiplier: float = 1.25

@export var surface_walk_body_offset: float = 0.85
@export var surface_walk_snap_strength: float = 10.0
@export var surface_walk_max_snap_speed: float = 8.0
@export var surface_walk_mouse_sensitivity: float = 0.0025
@export var surface_walk_pitch_limit_degrees: float = 82.0
@export var surface_walk_space_launches_off: bool = true

@export var surface_walk_transition_duration: float = 0.14
@export var surface_walk_entry_shake_duration: float = 0.18
@export var surface_walk_entry_shake_strength: float = 0.07
@export var surface_walk_entry_shake_frequency: float = 52.0

@export var surface_walk_edge_check_extra_distance: float = 0.35
@export var surface_walk_edge_grace_time: float = 0.06
@export var surface_walk_surface_normal_min_dot: float = 0.65

# Slope alignment: while ground-walking, ease the body's orientation onto the surface
# under it (up or down) as long as the slope change stays under the threshold. Past the
# threshold the slope is "too steep" and you drop off into zero-G.
@export var surface_walk_slope_align_max_degrees: float = 45.0
@export var surface_walk_slope_align_speed: float = 10.0
@export var surface_walk_slope_align_max_turn_speed_degrees: float = 240.0
@export var surface_walk_foot_check_distance: float = 0.4
@export var surface_walk_required_foot_count: int = 2
@export var surface_walk_foot_surface_normal_min_dot: float = 0.75
@export var surface_walk_friction: float = 0.0

# Ground-lock timing: angle your body so your feet face a surface, then press C to lock onto
# it. You can lock from up to `max_distance` metres away (measured straight off your feet);
# locking exactly at `sweet_spot` metres is clean. Missing the sweet spot — too far (toward
# max) OR too close (toward the surface) — temporarily "dazes" the first-person camera with
# look-inertia that scales with how far off the timing was. Hit the sweet spot: no daze.
@export var surface_walk_lock_max_distance: float = 4.0          # metres: farthest you can lock from
@export var surface_walk_lock_sweet_spot: float = 1.5            # metres: perfect-timing distance
@export var surface_walk_lock_daze_max_strength: float = 0.85    # 0..1: worst-case look sluggishness
@export var surface_walk_lock_daze_max_duration: float = 1.1     # seconds the worst-case daze lasts
@export var surface_walk_lock_daze_curve: float = 1.5            # >1 = forgiving near the sweet spot
@export var surface_walk_look_responsiveness: float = 60.0       # un-dazed look response (per second)
@export var surface_walk_lock_daze_min_responsiveness: float = 8.0  # most-dazed look response

var player: RigidBody3D
var camera: Camera3D
var hud_controller: PlayerHUDController
var limb_push_controller: LimbPushController

var movement_mode: int = MovementMode.ZERO_G

var mouse_motion: Vector2 = Vector2.ZERO
var free_look_mouse_motion: Vector2 = Vector2.ZERO

var roll_hold_time: float = 0.0

var look_pitch: float = 0.0
var view_initialized: bool = false

var grabbing_wall: bool = false
var grab_position: Vector3 = Vector3.ZERO
var grab_distance_level: int = 0

var surface_walk_normal: Vector3 = Vector3.UP
var surface_walk_forward: Vector3 = Vector3.FORWARD
var surface_walk_anchor_point: Vector3 = Vector3.ZERO
var surface_walk_pitch: float = 0.0

var surface_walk_transition_active: bool = false
var surface_walk_transition_timer: float = 0.0
var surface_walk_transition_start_transform: Transform3D
var surface_walk_transition_target_transform: Transform3D

var camera_base_position: Vector3 = Vector3.ZERO
var surface_walk_shake_timer: float = 0.0
var surface_walk_no_surface_timer: float = 0.0
var _pre_surface_walk_material: PhysicsMaterial = null

# Ground-lock daze state: how much/long the camera is sluggish after a mistimed lock, plus
# the low-passed look deltas that produce the inertia feel.
var surface_walk_daze_timer: float = 0.0
var surface_walk_daze_duration: float = 0.0
var surface_walk_daze_strength: float = 0.0
var surface_walk_look_yaw_vel: float = 0.0
var surface_walk_look_pitch_vel: float = 0.0

var last_surface_result: Dictionary = {}
var last_ctrl_push_result: Dictionary = {}
var last_limb_push_state: Dictionary = {}
var last_surface_walk_entry_result: Dictionary = {}


func setup(owner_player: RigidBody3D, owner_hud_controller: PlayerHUDController) -> void:
	player = owner_player
	hud_controller = owner_hud_controller
	camera = player.get_node_or_null("CameraRig/Camera3D") as Camera3D
	
	if camera != null:
		camera_base_position = camera.position

	if GameSettings.mouse_sensitivity > 0.0:
		mouse_sensitivity = GameSettings.mouse_sensitivity

	setup_limb_push_controller()
	
	jump_force = clampf(jump_force, min_jump_force, max_jump_force)
	
	if hud_controller != null:
		hud_controller.update_jump_force(jump_force)


func setup_limb_push_controller() -> void:
	if not use_limb_push_system:
		return
	
	if String(limb_push_controller_path) != "":
		limb_push_controller = get_node_or_null(limb_push_controller_path) as LimbPushController
		
		if limb_push_controller == null and player != null:
			limb_push_controller = player.get_node_or_null(limb_push_controller_path) as LimbPushController
	
	if limb_push_controller == null:
		limb_push_controller = get_node_or_null("LimbPushController") as LimbPushController
	
	if limb_push_controller == null and player != null:
		limb_push_controller = player.get_node_or_null("LimbPushController") as LimbPushController
	
	if limb_push_controller == null and auto_create_limb_push_controller and player != null:
		limb_push_controller = LimbPushController.new()
		limb_push_controller.name = "LimbPushController"
		player.add_child(limb_push_controller)
		limb_push_controller.position = Vector3.ZERO
		limb_push_controller.rotation = Vector3.ZERO
	
	if limb_push_controller != null:
		limb_push_controller.setup(player)


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
	
	var local_value = player.get("is_local_player")
	
	if local_value is bool and local_value == false:
		return false
	
	var buy_menu_value = player.get("buy_menu_open")
	
	if buy_menu_value is bool and buy_menu_value == true:
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
	delta: float,
	free_look_active: bool,
	input_locked: bool
) -> void:
	if player == null:
		return
	
	update_surface_cache()
	update_ctrl_push_cache()
	update_limb_push_cache()
	update_surface_walk_entry_cache()
	update_hud_values(input_locked)
	handle_movement_mode_toggle(input_locked)
	update_surface_walk_entry_shake(delta)
	
	if input_locked:
		handle_input_locked_state()
		clear_mouse_motion()
		clear_free_look_mouse_motion()
		return
	
	match movement_mode:
		MovementMode.ZERO_G:
			physics_update_zero_g(delta, free_look_active)
		
		MovementMode.SURFACE_WALK:
			physics_update_surface_walk(delta)
	
	clear_mouse_motion()
	clear_free_look_mouse_motion()


func update_hud_values(input_locked: bool) -> void:
	if hud_controller != null:
		hud_controller.update_jump_force(jump_force)
		
		var should_show_limb_ui := (
			show_limb_push_debug_ui
			and movement_mode == MovementMode.ZERO_G
			and not input_locked
		)
		
		if not show_limb_push_ui_when_no_limb_near:
			should_show_limb_ui = should_show_limb_ui and bool(last_limb_push_state.get("has_limb_contact", false))
		
		if hud_controller.has_method("update_limb_push_indicator"):
			hud_controller.update_limb_push_indicator(should_show_limb_ui, last_limb_push_state)
		
		if hud_controller.has_method("update_ground_lock_indicator"):
			hud_controller.update_ground_lock_indicator(
				not input_locked,
				can_ground_lock(),
				movement_mode == MovementMode.SURFACE_WALK
			)


func handle_input_locked_state() -> void:
	if movement_mode == MovementMode.SURFACE_WALK:
		player.linear_velocity = Vector3.ZERO
		player.angular_velocity = Vector3.ZERO


func integrate_forces(_state: PhysicsDirectBodyState3D) -> void:
	if player == null:
		return
	
	match movement_mode:
		MovementMode.ZERO_G:
			integrate_zero_g_forces()
		
		MovementMode.SURFACE_WALK:
			integrate_surface_walk_forces()


func integrate_zero_g_forces() -> void:
	if grabbing_wall:
		player.linear_velocity = player.linear_velocity.lerp(Vector3.ZERO, 0.55)
		player.angular_velocity = player.angular_velocity.lerp(Vector3.ZERO, 0.25)


func integrate_surface_walk_forces() -> void:
	player.angular_velocity = Vector3.ZERO


func physics_update_zero_g(delta: float, free_look_active: bool) -> void:
	if free_look_active:
		handle_free_look_rotation()
	else:
		handle_body_mouse_rotation()
		update_body_follow(delta)

	handle_jump_input()
	handle_grab_input()
	handle_roll_input(delta)
	handle_stabilize_input()


func physics_update_surface_walk(delta: float) -> void:
	release_grab()

	# Tick down the mistimed-lock daze for the whole time we're in ground mode.
	if surface_walk_daze_timer > 0.0:
		surface_walk_daze_timer = maxf(surface_walk_daze_timer - delta, 0.0)

	if surface_walk_transition_active:
		update_surface_walk_transition(delta)
		return

	if update_surface_walk_edge_check(delta):
		return

	update_surface_walk_mouse_look(delta)
	update_surface_walk_orientation()
	handle_surface_walk_movement(delta)
	handle_surface_walk_jump()


func handle_movement_mode_toggle(input_locked: bool) -> void:
	if not is_action_just_pressed_if_exists("toggle_surface_walk"):
		return
	
	if movement_mode == MovementMode.SURFACE_WALK:
		exit_surface_walk_mode()
		return
	
	if input_locked:
		return
	
	try_enter_surface_walk_mode()


func try_enter_surface_walk_mode() -> void:
	var result := get_ground_lock_probe()

	if result.is_empty():
		print("Ground lock failed: no surface within ", surface_walk_lock_max_distance, " m ahead.")
		return

	var surface_normal: Vector3 = result.get("normal", Vector3.ZERO)
	var hit_position: Vector3 = result.get("position", player.global_position)
	var distance: float = result.get("distance", surface_walk_lock_sweet_spot)

	if surface_normal.length() < 0.01:
		print("Ground lock failed: invalid surface normal.")
		return

	# Timing penalty: how far the lock distance was from the sweet spot decides the daze.
	apply_ground_lock_daze(distance)

	enter_surface_walk_mode(hit_position, surface_normal.normalized())


# Probes straight off the player's feet (body -Y) for a lockable surface within the max lock
# distance. Returns {position, normal, distance(metres)} or {} if nothing is in range. You must
# first angle your body so your feet face the surface, then time the press as you approach.
func get_ground_lock_probe() -> Dictionary:
	if player == null:
		return {}

	var origin := player.global_position
	var direction := get_ground_lock_probe_direction()

	if direction.length() < 0.01:
		return {}

	direction = direction.normalized()
	var end := origin + direction * surface_walk_lock_max_distance
	var result := raycast_from_player(origin, end)

	if result.is_empty():
		return {}

	var hit_position: Vector3 = result.get("position", end)
	var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

	if hit_normal.length() < 0.01:
		return {}

	return {
		"position": hit_position,
		"normal": hit_normal.normalized(),
		"distance": origin.distance_to(hit_position),
	}


func get_ground_lock_probe_direction() -> Vector3:
	# Probe toward the player's FEET, not their view. Surface-walk aligns the body's up to the
	# surface normal, so the feet point along the body's down (-basis.y). The player must angle
	# their body so their feet face the surface; this measures the distance straight off them.
	if player != null:
		return -player.global_transform.basis.y

	return Vector3.ZERO


# 0.0 at the sweet spot, ramping to 1.0 at either extreme (touching the surface, or out at the
# max lock distance). Each side is normalised by its own range so both extremes max out.
func ground_lock_error_ratio(distance: float) -> float:
	var sweet := surface_walk_lock_sweet_spot

	if distance >= sweet:
		var far_range := maxf(surface_walk_lock_max_distance - sweet, 0.001)
		return clampf((distance - sweet) / far_range, 0.0, 1.0)

	var near_range := maxf(sweet, 0.001)
	return clampf((sweet - distance) / near_range, 0.0, 1.0)


# Sets the camera daze from how badly the lock distance missed the sweet spot. A perfect lock
# clears the daze entirely; worse misses give stronger, longer-lasting look-inertia.
func apply_ground_lock_daze(distance: float) -> void:
	surface_walk_look_yaw_vel = 0.0
	surface_walk_look_pitch_vel = 0.0

	var ratio := ground_lock_error_ratio(distance)

	if ratio <= 0.0:
		surface_walk_daze_timer = 0.0
		surface_walk_daze_duration = 0.0
		surface_walk_daze_strength = 0.0
		return

	var curved := pow(ratio, maxf(surface_walk_lock_daze_curve, 0.01))
	surface_walk_daze_strength = curved * surface_walk_lock_daze_max_strength
	surface_walk_daze_duration = curved * surface_walk_lock_daze_max_duration
	surface_walk_daze_timer = surface_walk_daze_duration

	print("Ground lock: ", snappedf(distance, 0.01), " m (sweet ", surface_walk_lock_sweet_spot,
		" m) -> daze ", snappedf(surface_walk_daze_strength, 0.01),
		" for ", snappedf(surface_walk_daze_duration, 0.01), " s.")


# Current daze amount (0..1), fading out linearly over the daze duration.
func current_surface_walk_daze() -> float:
	if surface_walk_daze_timer <= 0.0 or surface_walk_daze_duration <= 0.0:
		return 0.0

	return surface_walk_daze_strength * clampf(surface_walk_daze_timer / surface_walk_daze_duration, 0.0, 1.0)


func update_surface_walk_entry_cache() -> void:
	if movement_mode != MovementMode.ZERO_G:
		last_surface_walk_entry_result = {}
		return

	last_surface_walk_entry_result = get_ground_lock_probe()


func can_ground_lock() -> bool:
	return movement_mode == MovementMode.ZERO_G and not last_surface_walk_entry_result.is_empty()


func enter_surface_walk_mode(hit_position: Vector3, surface_normal: Vector3) -> void:
	release_grab()
	
	movement_mode = MovementMode.SURFACE_WALK

	# Surface-walk drives the body's velocity directly each frame; contact friction
	# with the walked surface fights that and drags walk speed below target (sprint's
	# higher accel hides it). Suspend friction while walking, restore it on exit.
	_pre_surface_walk_material = player.physics_material_override
	var walk_material := PhysicsMaterial.new()
	walk_material.friction = surface_walk_friction
	player.physics_material_override = walk_material

	surface_walk_normal = surface_normal.normalized()
	surface_walk_anchor_point = hit_position
	surface_walk_no_surface_timer = 0.0
	
	var look_forward := (-player.global_transform.basis.z).normalized()
	var projected_forward := look_forward.slide(surface_walk_normal)
	
	if projected_forward.length() < 0.01:
		projected_forward = player.global_transform.basis.y.slide(surface_walk_normal)
	
	if projected_forward.length() < 0.01:
		projected_forward = get_fallback_surface_forward(surface_walk_normal)
	
	surface_walk_forward = projected_forward.normalized()
	surface_walk_pitch = 0.0
	
	var target_position := hit_position + surface_walk_normal * surface_walk_body_offset
	var target_basis := make_surface_walk_basis(surface_walk_forward, surface_walk_normal)
	var target_transform := Transform3D(target_basis, target_position)
	
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false
	
	if camera != null:
		camera.rotation = Vector3.ZERO
	
	start_surface_walk_transition(target_transform)
	start_surface_walk_entry_shake()
	
	print("Entered surface-walk mode.")


func start_surface_walk_transition(target_transform: Transform3D) -> void:
	surface_walk_transition_active = true
	surface_walk_transition_timer = 0.0
	surface_walk_transition_start_transform = player.global_transform
	surface_walk_transition_target_transform = target_transform
	
	if surface_walk_transition_duration <= 0.0:
		player.global_transform = surface_walk_transition_target_transform
		surface_walk_transition_active = false


func update_surface_walk_transition(delta: float) -> void:
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false
	
	surface_walk_transition_timer += delta
	
	var raw_t := clampf(
		surface_walk_transition_timer / maxf(surface_walk_transition_duration, 0.001),
		0.0,
		1.0
	)
	
	var smooth_t := raw_t * raw_t * (3.0 - 2.0 * raw_t)
	
	var new_position := surface_walk_transition_start_transform.origin.lerp(
		surface_walk_transition_target_transform.origin,
		smooth_t
	)
	
	var new_basis := surface_walk_transition_start_transform.basis.slerp(
		surface_walk_transition_target_transform.basis,
		smooth_t
	).orthonormalized()
	
	player.global_transform = Transform3D(new_basis, new_position)
	
	if raw_t >= 1.0:
		player.global_transform = surface_walk_transition_target_transform
		surface_walk_transition_active = false
		surface_walk_no_surface_timer = 0.0


func start_surface_walk_entry_shake() -> void:
	surface_walk_shake_timer = surface_walk_entry_shake_duration


func update_surface_walk_entry_shake(delta: float) -> void:
	if camera == null:
		return
	
	if surface_walk_shake_timer <= 0.0:
		return
	
	surface_walk_shake_timer -= delta
	
	var remaining_ratio := clampf(
		surface_walk_shake_timer / maxf(surface_walk_entry_shake_duration, 0.001),
		0.0,
		1.0
	)
	
	var time := Time.get_ticks_msec() / 1000.0
	var shake_amount := surface_walk_entry_shake_strength * remaining_ratio
	
	var x_offset := sin(time * surface_walk_entry_shake_frequency) * shake_amount
	var y_offset := cos(time * surface_walk_entry_shake_frequency * 1.37) * shake_amount * 0.65
	
	camera.position = camera_base_position + Vector3(x_offset, y_offset, 0.0)
	
	if surface_walk_shake_timer <= 0.0:
		camera.position = camera_base_position


func update_surface_walk_edge_check(delta: float) -> bool:
	var result := get_surface_walk_ground_result()
	
	if result.is_empty():
		surface_walk_no_surface_timer += delta
		
		if surface_walk_no_surface_timer >= surface_walk_edge_grace_time:
			print("Surface walk ended: walked off edge.")
			exit_surface_walk_mode()
			return true
		
		return false
	
	var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)
	
	if hit_normal.length() < 0.01:
		surface_walk_no_surface_timer += delta
		
		if surface_walk_no_surface_timer >= surface_walk_edge_grace_time:
			print("Surface walk ended: invalid surface under player.")
			exit_surface_walk_mode()
			return true
		
		return false
	
	var target_normal := hit_normal.normalized()
	var slope_change_degrees := rad_to_deg(surface_walk_normal.angle_to(target_normal))

	if slope_change_degrees > surface_walk_slope_align_max_degrees:
		print("Surface walk ended: slope too steep to align (", roundi(slope_change_degrees), " deg).")
		exit_surface_walk_mode()
		return true

	align_surface_walk_normal_toward(target_normal, delta)

	surface_walk_no_surface_timer = 0.0
	surface_walk_anchor_point = result.get("position", surface_walk_anchor_point)

	return false


# Eases the walked-surface normal toward the ground under the player, so stepping onto a
# (shallow enough) ramp smoothly banks into its orientation instead of staying locked to
# the old one. Capped per frame so a sharp crease can't whip the camera. Forward is
# re-projected onto the new plane so facing stays consistent.
func align_surface_walk_normal_toward(target_normal: Vector3, delta: float) -> void:
	if target_normal.length() < 0.01:
		return

	target_normal = target_normal.normalized()
	var full_angle := surface_walk_normal.angle_to(target_normal)

	if full_angle < 0.0001:
		return

	var exp_weight := 1.0 - exp(-surface_walk_slope_align_speed * delta)
	var max_step := deg_to_rad(surface_walk_slope_align_max_turn_speed_degrees) * delta
	var step_angle := minf(full_angle * exp_weight, max_step)
	var t := clampf(step_angle / full_angle, 0.0, 1.0)

	surface_walk_normal = surface_walk_normal.slerp(target_normal, t).normalized()

	var projected_forward := surface_walk_forward.slide(surface_walk_normal)

	if projected_forward.length() < 0.01:
		projected_forward = get_fallback_surface_forward(surface_walk_normal)

	surface_walk_forward = projected_forward.normalized()


func get_surface_walk_ground_result() -> Dictionary:
	if player == null:
		return {}
	
	var start := player.global_position + surface_walk_normal * 0.08
	var end := player.global_position - surface_walk_normal * (
		surface_walk_body_offset + surface_walk_edge_check_extra_distance
	)
	
	return raycast_from_player(start, end)


func exit_surface_walk_mode() -> void:
	if movement_mode != MovementMode.SURFACE_WALK:
		return
	
	surface_walk_transition_active = false
	surface_walk_shake_timer = 0.0
	surface_walk_no_surface_timer = 0.0

	surface_walk_daze_timer = 0.0
	surface_walk_daze_duration = 0.0
	surface_walk_daze_strength = 0.0
	surface_walk_look_yaw_vel = 0.0
	surface_walk_look_pitch_vel = 0.0

	if camera != null:
		var camera_basis := get_control_look_basis()
		player.global_transform = Transform3D(camera_basis, player.global_position)
		camera.rotation = Vector3.ZERO
		camera.position = camera_base_position
		player.reset_physics_interpolation()
	
	player.physics_material_override = _pre_surface_walk_material

	movement_mode = MovementMode.ZERO_G
	view_initialized = false   # re-sync head-up to the post-exit orientation
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false

	print("Exited surface-walk mode.")


func update_surface_walk_mouse_look(delta: float) -> void:
	var raw_yaw := -mouse_motion.x * surface_walk_mouse_sensitivity
	var raw_pitch := -mouse_motion.y * surface_walk_mouse_sensitivity

	var yaw_delta := raw_yaw
	var pitch_delta := raw_pitch

	var daze := current_surface_walk_daze()

	if daze > 0.001:
		# A mistimed lock makes the view feel heavy: low-pass the look so it lags the input
		# (slow to start, drifts on stop) — i.e. camera inertia. The laggier the response, the
		# stronger the daze. Fades to 1:1 as the daze runs out.
		var response := lerpf(surface_walk_look_responsiveness, surface_walk_lock_daze_min_responsiveness, daze)
		var smooth := clampf(1.0 - exp(-response * delta), 0.0, 1.0)
		surface_walk_look_yaw_vel = lerpf(surface_walk_look_yaw_vel, raw_yaw, smooth)
		surface_walk_look_pitch_vel = lerpf(surface_walk_look_pitch_vel, raw_pitch, smooth)
		yaw_delta = surface_walk_look_yaw_vel
		pitch_delta = surface_walk_look_pitch_vel
	else:
		# No daze: 1:1 look, identical to the original feel.
		surface_walk_look_yaw_vel = raw_yaw
		surface_walk_look_pitch_vel = raw_pitch

	if absf(yaw_delta) > 0.0000001:
		surface_walk_forward = surface_walk_forward.rotated(surface_walk_normal, yaw_delta).normalized()

	surface_walk_pitch += pitch_delta

	var pitch_limit := deg_to_rad(surface_walk_pitch_limit_degrees)
	surface_walk_pitch = clampf(surface_walk_pitch, -pitch_limit, pitch_limit)

	if camera != null:
		camera.rotation = Vector3(surface_walk_pitch, 0.0, 0.0)


func update_surface_walk_orientation() -> void:
	player.global_transform = Transform3D(
		make_surface_walk_basis(surface_walk_forward, surface_walk_normal),
		player.global_position
	)
	
	player.angular_velocity = Vector3.ZERO


func handle_surface_walk_movement(delta: float) -> void:
	var input_vector := get_surface_walk_input_vector()
	var sprinting := is_surface_walk_sprinting()
	
	var target_speed := get_surface_walk_target_speed(sprinting)
	var current_acceleration := get_surface_walk_current_acceleration(sprinting)
	
	var forward := (-player.global_transform.basis.z).slide(surface_walk_normal).normalized()
	var right := player.global_transform.basis.x.slide(surface_walk_normal).normalized()
	
	if forward.length() < 0.01:
		forward = surface_walk_forward.normalized()
	
	if right.length() < 0.01:
		right = forward.cross(surface_walk_normal).normalized()
	
	var desired_tangent_velocity := Vector3.ZERO
	
	if input_vector.length() > 0.01:
		desired_tangent_velocity = (
			right * input_vector.x +
			forward * input_vector.y
		).normalized() * target_speed
	
	var current_tangent_velocity := player.linear_velocity.slide(surface_walk_normal)
	var new_tangent_velocity := current_tangent_velocity.move_toward(
		desired_tangent_velocity,
		current_acceleration * delta
	)
	
	var snap_velocity := get_surface_walk_snap_velocity()
	
	player.linear_velocity = new_tangent_velocity + snap_velocity
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false


func get_surface_walk_target_speed(sprinting: bool) -> float:
	var target_speed := surface_walk_speed
	
	if sprinting:
		target_speed *= surface_walk_sprint_multiplier
	
	return target_speed


func get_surface_walk_current_acceleration(sprinting: bool) -> float:
	if not surface_walk_use_auto_acceleration:
		var manual_acceleration := surface_walk_acceleration
		
		if sprinting:
			manual_acceleration *= surface_walk_sprint_acceleration_multiplier
		
		return manual_acceleration
	
	var target_speed := get_surface_walk_target_speed(sprinting)
	var time_to_speed := maxf(surface_walk_time_to_full_speed, 0.01)
	var auto_acceleration := target_speed / time_to_speed
	
	if sprinting:
		auto_acceleration *= surface_walk_sprint_acceleration_multiplier
	
	return auto_acceleration


func get_surface_walk_snap_velocity() -> Vector3:
	var distance_from_plane := surface_walk_normal.dot(player.global_position - surface_walk_anchor_point)
	var offset_error := surface_walk_body_offset - distance_from_plane
	
	var snap_speed := clampf(
		offset_error * surface_walk_snap_strength,
		-surface_walk_max_snap_speed,
		surface_walk_max_snap_speed
	)
	
	return surface_walk_normal * snap_speed


func is_surface_walk_sprinting() -> bool:
	return (
		is_action_pressed_if_exists("sprint")
		or is_action_pressed_if_exists("stabilize_rotation")
	)


func handle_surface_walk_jump() -> void:
	if not surface_walk_space_launches_off:
		return
	
	if not is_action_just_pressed_if_exists("push"):
		return
	
	var launch_direction := surface_walk_normal.normalized()
	exit_surface_walk_mode()
	
	player.sleeping = false
	player.apply_central_impulse(launch_direction * jump_force)

	if player.has_method("suppress_launch_impact"):
		player.call("suppress_launch_impact")


func get_surface_walk_input_vector() -> Vector2:
	var input_vector := Vector2.ZERO
	
	input_vector.x += get_action_strength_if_exists("walk_right")
	input_vector.x -= get_action_strength_if_exists("walk_left")
	
	input_vector.y += get_action_strength_if_exists("booster_forward")
	input_vector.y -= get_action_strength_if_exists("booster_backward")
	
	if input_vector.length() > 1.0:
		input_vector = input_vector.normalized()
	
	return input_vector


func make_surface_walk_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward = forward.slide(up)
	
	if forward.length() < 0.01:
		forward = get_fallback_surface_forward(up)
	
	forward = forward.normalized()
	
	var right := forward.cross(up).normalized()
	var corrected_forward := up.cross(right).normalized()
	
	return Basis(right, up, -corrected_forward).orthonormalized()


func get_fallback_surface_forward(up: Vector3) -> Vector3:
	var helper := Vector3.FORWARD
	
	if absf(up.dot(helper)) > 0.95:
		helper = Vector3.RIGHT
	
	return helper.slide(up).normalized()


func is_surface_walk_active() -> bool:
	return movement_mode == MovementMode.SURFACE_WALK


func get_control_look_basis() -> Basis:
	var look_basis := player.global_transform.basis.orthonormalized()
	
	if camera != null:
		look_basis = (look_basis * camera.transform.basis).orthonormalized()
	
	return look_basis


func get_screen_roll_axis() -> Vector3:
	# Positive rotation around camera-back moves screen-up toward screen-left,
	# so `roll_left`/A can stay positive regardless of player orientation.
	return get_control_look_basis().z.normalized()


func handle_body_mouse_rotation() -> void:
	if mouse_motion == Vector2.ZERO:
		return

	if not view_initialized:
		look_pitch = 0.0
		view_initialized = true

	var basis := player.global_transform.basis.orthonormalized()

	# Yaw around the body's OWN up axis, so a left flick always turns the view left no matter how
	# the body is oriented. (Yawing around a fixed world-up inverts left/right when upside down.)
	if mouse_motion.x != 0.0:
		basis = basis.rotated(basis.y, -mouse_motion.x * mouse_sensitivity).orthonormalized()

	# Pitch first articulates the neck (camera) up to a limit; the overflow past it tumbles the
	# whole body around its right axis — a free 0g flip — so up/down never hits a hard stop.
	if mouse_motion.y != 0.0:
		var neck_limit := deg_to_rad(look_neck_limit_degrees)
		var desired := look_pitch - mouse_motion.y * mouse_sensitivity
		var overflow := 0.0

		if desired > neck_limit:
			overflow = desired - neck_limit
			look_pitch = neck_limit
		elif desired < -neck_limit:
			overflow = desired + neck_limit
			look_pitch = -neck_limit
		else:
			look_pitch = desired

		if overflow != 0.0:
			basis = basis.rotated(basis.x, overflow).orthonormalized()

	player.global_transform.basis = basis

	if camera != null:
		camera.rotation = Vector3(look_pitch, 0.0, 0.0)


# Each frame the body eases toward the head: the neck pitch bleeds into real body rotation so the
# whole person follows where they look (feet trailing) instead of a swivelling head on a frozen
# torso. The view doesn't move — the body gains exactly the pitch the neck gives up (same axis).
func update_body_follow(delta: float) -> void:
	if camera == null:
		return

	if absf(look_pitch) < 0.0001:
		return

	var follow := look_pitch * (1.0 - exp(-body_follow_speed * delta))
	player.global_transform.basis = player.global_transform.basis.rotated(player.global_transform.basis.x, follow).orthonormalized()
	look_pitch -= follow
	camera.rotation = Vector3(look_pitch, 0.0, 0.0)


# Weapon recoil kick to the aim: climbs the view (+pitch = up) with a little side yaw. It feeds
# the same look state the mouse drives, so it's persistent — the player pulls down to counter it,
# it doesn't auto-recover. Handles both zero-G and surface-walk look.
func apply_look_recoil(pitch_degrees: float, yaw_degrees: float) -> void:
	var pitch := deg_to_rad(pitch_degrees)
	var yaw := deg_to_rad(yaw_degrees)

	if is_surface_walk_active():
		var limit := deg_to_rad(surface_walk_pitch_limit_degrees)
		surface_walk_pitch = clampf(surface_walk_pitch + pitch, -limit, limit)
		if yaw != 0.0:
			surface_walk_forward = surface_walk_forward.rotated(surface_walk_normal, yaw).normalized()
		return

	var basis := player.global_transform.basis.orthonormalized()

	if yaw != 0.0:
		basis = basis.rotated(basis.y, yaw).orthonormalized()

	# Pitch articulates the neck up to its limit; overflow tumbles the body (same as the mouse).
	var neck := deg_to_rad(look_neck_limit_degrees)
	var desired := look_pitch + pitch

	if desired > neck:
		basis = basis.rotated(basis.x, desired - neck).orthonormalized()
		look_pitch = neck
	elif desired < -neck:
		basis = basis.rotated(basis.x, desired + neck).orthonormalized()
		look_pitch = -neck
	else:
		look_pitch = desired

	player.global_transform.basis = basis

	if camera != null:
		camera.rotation = Vector3(look_pitch, 0.0, 0.0)


func handle_free_look_rotation() -> void:
	free_look_mouse_motion = Vector2.ZERO


func handle_jump_input() -> void:
	if not is_action_just_pressed_if_exists("push"):
		return
	
	if is_action_pressed_if_exists("ctrl_push"):
		try_ctrl_push()
	else:
		try_normal_push()


func try_normal_push() -> void:
	var surface_check_direction := get_normal_surface_check_direction()
	var desired_push_direction := get_normal_push_direction()
	var limb_state := get_limb_push_state_for_direction(
		surface_check_direction,
		desired_push_direction,
		get_current_grab_distance(),
		false,
		true
	)
	
	if should_use_limb_push_state(limb_state):
		apply_limb_jump_impulse(desired_push_direction, limb_state)
		return
	
	var result := get_normal_push_result()
	
	if result.is_empty():
		return
	
	if allow_legacy_center_push_fallback:
		apply_jump_impulse(desired_push_direction, result)


func try_ctrl_push() -> void:
	var surface_check_direction := get_ctrl_surface_check_direction()
	var desired_push_direction := get_ctrl_push_direction()
	var limb_state := get_limb_push_state_for_direction(
		surface_check_direction,
		desired_push_direction,
		ctrl_push_check_distance,
		true,
		true
	)
	
	if should_use_limb_push_state(limb_state):
		apply_limb_jump_impulse(desired_push_direction, limb_state)
		return
	
	var result := get_ctrl_push_result()
	
	if result.is_empty():
		return
	
	if allow_legacy_center_push_fallback:
		apply_jump_impulse(desired_push_direction, result)


func apply_jump_impulse(direction: Vector3, surface_result: Dictionary) -> void:
	if player == null:
		return
	
	if direction.length() < 0.01:
		return
	
	release_grab()
	
	var impulse := direction.normalized() * jump_force
	player.sleeping = false
	player.apply_central_impulse(impulse)
	
	apply_reaction_impulse_to_surface(impulse, surface_result)


func apply_limb_jump_impulse(fallback_direction: Vector3, limb_state: Dictionary) -> void:
	if player == null:
		return
	
	var impulse_direction := get_limb_push_direction_from_state(limb_state, fallback_direction)
	
	if impulse_direction.length() < 0.01:
		return
	
	release_grab()
	
	var force_multiplier := 1.0
	
	if use_limb_push_force_scaling:
		force_multiplier = float(limb_state.get("force_multiplier", 1.0))
	
	force_multiplier = maxf(force_multiplier, 0.0)
	
	if force_multiplier <= 0.0:
		return
	
	var impulse := impulse_direction.normalized() * jump_force * force_multiplier
	
	player.sleeping = false
	player.apply_central_impulse(impulse)
	
	var surface_result: Dictionary = limb_state.get("primary_surface_result", {})
	apply_reaction_impulse_to_surface(impulse, surface_result)
	
	if debug_print_limb_pushes:
		print(
			"Limb push: ",
			limb_state.get("summary_text", "Unknown"),
			" | Final force: ",
			snappedf(force_multiplier, 0.01),
			"x | Angle alignment: ",
			snappedf(float(limb_state.get("angle_alignment", 0.0)), 0.01),
			" | Direction: ",
			impulse_direction
		)


func get_limb_push_direction_from_state(limb_state: Dictionary, fallback_direction: Vector3) -> Vector3:
	var push_direction: Vector3 = limb_state.get("push_direction", Vector3.ZERO)
	
	if push_direction.length() >= 0.01:
		return push_direction.normalized()
	
	if fallback_direction.length() >= 0.01:
		return fallback_direction.normalized()
	
	return Vector3.ZERO


func apply_reaction_impulse_to_surface(impulse: Vector3, surface_result: Dictionary) -> void:
	if surface_result.is_empty():
		return
	
	var collider = surface_result.get("collider", null)
	var collision_position: Vector3 = surface_result.get("position", player.global_position)
	
	if collider is RigidBody3D:
		var rigid_collider := collider as RigidBody3D
		rigid_collider.sleeping = false
		rigid_collider.apply_impulse(-impulse, collision_position - rigid_collider.global_position)


func should_use_limb_push_state(limb_state: Dictionary) -> bool:
	if not use_limb_push_system:
		return false
	
	if limb_push_controller == null:
		return false
	
	return bool(limb_state.get("has_limb_contact", false))


func get_limb_push_state_for_direction(
	surface_check_direction: Vector3,
	desired_push_direction: Vector3,
	max_check_distance: float,
	using_ctrl_push: bool,
	refresh_now: bool
) -> Dictionary:
	if not use_limb_push_system:
		return {}
	
	if limb_push_controller == null:
		return {}
	
	if refresh_now:
		last_limb_push_state = limb_push_controller.update_limb_push_state(
			surface_check_direction,
			desired_push_direction,
			max_check_distance,
			using_ctrl_push
		)
	
	return last_limb_push_state


func update_limb_push_cache() -> void:
	if not use_limb_push_system:
		last_limb_push_state = {}
		clear_limb_push_controller_debug(false)
		return
	
	if limb_push_controller == null:
		last_limb_push_state = {}
		return
	
	if movement_mode != MovementMode.ZERO_G:
		last_limb_push_state = {}
		clear_limb_push_controller_debug(false)
		return
	
	var using_ctrl_push := is_action_pressed_if_exists("ctrl_push")
	var surface_check_direction := get_ctrl_surface_check_direction() if using_ctrl_push else get_normal_surface_check_direction()
	var desired_push_direction := get_ctrl_push_direction() if using_ctrl_push else get_normal_push_direction()
	var max_check_distance := ctrl_push_check_distance if using_ctrl_push else get_current_grab_distance()
	
	last_limb_push_state = limb_push_controller.update_limb_push_state(
		surface_check_direction,
		desired_push_direction,
		max_check_distance,
		using_ctrl_push
	)


func clear_limb_push_controller_debug(using_ctrl_push: bool) -> void:
	if limb_push_controller == null:
		return
	
	if limb_push_controller.has_method("clear_limb_push_state"):
		limb_push_controller.clear_limb_push_state(using_ctrl_push)


func get_normal_surface_check_direction() -> Vector3:
	if player == null:
		return Vector3.ZERO
	
	return (-player.global_transform.basis.z).normalized()


func get_ctrl_surface_check_direction() -> Vector3:
	if player == null:
		return Vector3.ZERO
	
	return player.global_transform.basis.z.normalized()


func get_normal_push_direction() -> Vector3:
	if player == null:
		return Vector3.ZERO
	
	return player.global_transform.basis.z.normalized()


func get_ctrl_push_direction() -> Vector3:
	if player == null:
		return Vector3.ZERO
	
	return (-player.global_transform.basis.z).normalized()


func handle_grab_input() -> void:
	if is_action_pressed_if_exists("grab"):
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


func handle_roll_input(delta: float) -> void:
	var roll_input := 0.0

	if is_action_pressed_if_exists("roll_left"):
		roll_input += 1.0

	if is_action_pressed_if_exists("roll_right"):
		roll_input -= 1.0

	var roll_axis := get_screen_roll_axis()

	if roll_input == 0.0:
		roll_hold_time = 0.0

		# Constant decel on the roll axis: drift-angle ~ spin^2, so small turns settle
		# almost instantly while fast spins still coast. Skip while stabilizing.
		if not is_action_pressed_if_exists("stabilize_rotation"):
			var roll_velocity := roll_axis * player.angular_velocity.dot(roll_axis)
			var settled := roll_velocity.move_toward(Vector3.ZERO, roll_settle_rate * delta)
			player.angular_velocity += settled - roll_velocity

		return

	var current_roll_speed := player.angular_velocity.dot(roll_axis)
	
	if current_roll_speed * roll_input < 0.0:
		var opposing_roll_velocity := roll_axis * current_roll_speed
		var settled := opposing_roll_velocity.move_toward(
			Vector3.ZERO,
			roll_settle_rate * delta * 2.0
		)
		player.angular_velocity += settled - opposing_roll_velocity

	roll_hold_time += delta
	var ramp := clampf(roll_hold_time / maxf(roll_ramp_time, 0.001), 0.0, 1.0)
	var torque := lerpf(roll_start_torque, roll_torque, ramp)

	player.apply_torque(roll_axis * roll_input * torque)


func handle_stabilize_input() -> void:
	if not is_action_pressed_if_exists("stabilize_rotation"):
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
	var direction := get_normal_surface_check_direction()
	var end := origin + direction * get_current_grab_distance()
	
	return raycast_from_player(origin, end)


func get_ctrl_push_result() -> Dictionary:
	if player == null:
		return {}
	
	var origin := player.global_position
	var direction := get_ctrl_surface_check_direction()
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
	if not last_surface_result.is_empty():
		return true
	
	if bool(last_limb_push_state.get("has_limb_contact", false)):
		return true
	
	return false


func is_grabbing_wall() -> bool:
	return grabbing_wall


func should_show_ctrl_push_arrow(
	buy_menu_open: bool,
	free_look_active: bool,
	input_locked: bool
) -> bool:
	if movement_mode == MovementMode.SURFACE_WALK:
		return false
	
	if buy_menu_open:
		return false
	
	if free_look_active:
		return false
	
	if input_locked:
		return false
	
	if not is_action_pressed_if_exists("ctrl_push"):
		return false
	
	return not last_ctrl_push_result.is_empty() or bool(last_limb_push_state.get("has_limb_contact", false))


func get_predicted_ctrl_push_direction() -> Vector3:
	if bool(last_limb_push_state.get("has_limb_contact", false)):
		return get_limb_push_direction_from_state(last_limb_push_state, get_ctrl_push_direction())
	
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


func set_limb_disabled(limb_id: String, disabled: bool) -> void:
	if limb_push_controller == null:
		return
	
	limb_push_controller.set_limb_disabled(limb_id, disabled)


func is_limb_disabled(limb_id: String) -> bool:
	if limb_push_controller == null:
		return false
	
	return limb_push_controller.is_limb_disabled(limb_id)


func is_action_pressed_if_exists(action_name: String) -> bool:
	return InputMap.has_action(action_name) and Input.is_action_pressed(action_name)


func is_action_just_pressed_if_exists(action_name: String) -> bool:
	return InputMap.has_action(action_name) and Input.is_action_just_pressed(action_name)


func get_action_strength_if_exists(action_name: String) -> float:
	if not InputMap.has_action(action_name):
		return 0.0
	
	return Input.get_action_strength(action_name)
