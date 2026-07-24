extends Node
class_name PlayerMovementController

enum MovementMode {
	ZERO_G,
	SURFACE_WALK
}

@export var mouse_sensitivity: float = 0.0025
@export var look_neck_limit_degrees: float = 70.0
@export var body_follow_speed: float = 6.0

# Weapon camera recoil: kicks ease in over a few frames (no one-frame snap), then auto-recenter
# after a short pause — minus whatever the player already pulled back themselves. Between shots a
# fraction of the recovery still runs, so sprays micro-bounce as they climb. Only
# recoil_recovery_fraction of each kick's climb recenters; the rest is permanent aim climb the
# player must pull down (side wander always fully recenters).
@export var recoil_apply_speed: float = 26.0
@export var recoil_recovery_delay: float = 0.22
@export var recoil_recovery_speed: float = 5.5
@export var recoil_fire_settle_fraction: float = 1.0
@export var recoil_recovery_fraction: float = 0.15

# Zero-G roll (A/D), velocity-driven. These exports are the GAME's baked defaults — the
# feel every player gets out of the box. The settings-menu sliders store a PER-PLAYER
# override in GameSettings (-1 = untouched, follow these defaults); the get_roll_*()
# getters resolve override-else-default live, so both layers apply immediately.
@export var roll_start_speed: float = 120.0        # deg/s the instant you press
@export var roll_max_speed: float = 140.0          # deg/s cap while held
@export var roll_speed_change_rate: float = 500.0  # deg/s^2 — ramp AND stop rate

@export var ctrl_push_check_distance: float = 2.75

# Charged push/launch (space): the force starts EMPTY (min_jump_force) and builds toward
# max while space is HELD (JUMP_CHARGE_TIME seconds to full); releasing fires — zero-G
# pushes off the surface, ground mode launches into zero-G. A tap barely nudges, a full
# hold launches hard. jump_force is the LIVE charge; the HUD force bar reads it per frame,
# so the bar itself is the charge meter.
@export var min_jump_force: float = 2.0
@export var max_jump_force: float = 30.0
const JUMP_CHARGE_TIME := 1.0
var jump_force: float = 2.0

@export var max_grab_speed: float = 10.0

@export var use_limb_push_system: bool = true
@export var auto_create_limb_push_controller: bool = true
@export var limb_push_controller_path: NodePath
@export var use_limb_push_force_scaling: bool = true
@export var allow_legacy_center_push_fallback: bool = true
@export var show_limb_push_debug_ui: bool = true
@export var show_limb_push_ui_when_no_limb_near: bool = true
@export var debug_print_limb_pushes: bool = false

@export var grab_distance_base: float = 2.1
@export var grab_distance_level_1: float = 2.75
@export var grab_distance_level_2: float = 3.4
@export var grab_distance_level_3: float = 4.2

# Ground (surface-walk) movement lives on the GroundMovementController sibling node —
# Source-style accelerate/friction/air recipes, jumping, orientation, probes and all its
# tuning exports. This node coordinates modes, owns zero-G movement, and shares look/recoil.

var player: RigidBody3D
var camera: Camera3D
var hud_controller: PlayerHUDController
var limb_push_controller: LimbPushController
var _ray_query: PhysicsRayQueryParameters3D

var movement_mode: int = MovementMode.ZERO_G

var mouse_motion: Vector2 = Vector2.ZERO

# Zero-G WALL PUSH (space release pushing off nearby geometry, limb pushes included):
# DISABLED for now — the whole mechanic stays in the file, flip this to re-enable. While
# false the zero-G charge stays parked, the push never fires, and every HUD affordance for
# it (push prompt, ctrl-push arrow, limb-push readout) hides. The ground-mode charged
# launch is a separate path and is unaffected.
var wall_push_enabled: bool = false

var look_pitch: float = 0.0
var view_initialized: bool = false

# Camera-space weapon recoil (x = pitch, y = yaw, radians): pending eases into offset, offset
# recenters. Lives outside look_pitch so body-follow never bleeds it into body orientation.
var recoil_pending: Vector2 = Vector2.ZERO
var recoil_offset: Vector2 = Vector2.ZERO
var recoil_recovery_wait: float = 0.0

var grabbing_wall: bool = false
var grab_position: Vector3 = Vector3.ZERO
var grab_distance_level: int = 0

# The ground-movement node (found on the player, auto-created if missing). All surface-walk
# state lives on it; this coordinator only tracks WHICH mode is active.
var ground: GroundMovementController = null

# Re-entry cooldown for AUTO ground lock: set on every ground-mode exit so a C-release,
# Alt launch or knockback exit isn't instantly re-locked while still near the surface.
var auto_ground_cooldown: float = 0.0

var last_surface_result: Dictionary = {}
var last_ctrl_push_result: Dictionary = {}
var last_limb_push_state: Dictionary = {}

# Set when the player (re)spawns: the next physics tick drops them into ground mode on the
# nearest surface. Deferred to a physics frame so the surface raycasts run safely; retried for
# a few frames in case the map/collision isn't queryable yet on the very first tick.
var pending_spawn_ground_mode: bool = false
var pending_spawn_ground_frames: int = 0
const SPAWN_GROUND_MODE_MAX_FRAMES := 20


func setup(owner_player: RigidBody3D, owner_hud_controller: PlayerHUDController) -> void:
	player = owner_player
	hud_controller = owner_hud_controller
	camera = player.get_node_or_null("CameraRig/Camera3D") as Camera3D

	# One reused query object for every probe ray (surface cache, push probes, the whole
	# surface-walk probe set — 10-20 casts per physics tick), instead of allocating a fresh
	# PhysicsRayQueryParameters3D per cast. Same pattern as LimbPushController.
	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false

	if player is CollisionObject3D:
		_ray_query.exclude = [player.get_rid()]

	if GameSettings.mouse_sensitivity > 0.0:
		mouse_sensitivity = GameSettings.mouse_sensitivity

	setup_limb_push_controller()

	# Ground movement is its own node on the player (auto-created if the scene lacks one).
	ground = player.get_node_or_null("GroundMovementController") as GroundMovementController

	if ground == null:
		ground = GroundMovementController.new()
		ground.name = "GroundMovementController"
		player.add_child(ground)

	ground.setup(self, player, camera)

	jump_force = min_jump_force
	
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


# Space held = the charge builds; release fires. A blocked context (menu open, dead)
# drains the charge so it can't fire stale.
func update_jump_charge(delta: float) -> void:
	if not can_adjust_jump_force():
		jump_force = min_jump_force
		return

	# No wall push = nothing for a zero-G charge to fire; keep the bar parked.
	if movement_mode == MovementMode.ZERO_G and not wall_push_enabled:
		jump_force = min_jump_force
		return

	if is_action_pressed_if_exists("push"):
		var rate := (max_jump_force - min_jump_force) / JUMP_CHARGE_TIME
		jump_force = minf(jump_force + rate * delta, max_jump_force)


func reset_jump_charge() -> void:
	jump_force = min_jump_force


# Live mouse sensitivity: the settings slider writes GameSettings mid-game, so read it on
# every use instead of caching at spawn — the slider takes effect immediately.
func get_mouse_sensitivity() -> float:
	if GameSettings.mouse_sensitivity > 0.0:
		return GameSettings.mouse_sensitivity

	return mouse_sensitivity


func add_mouse_motion(relative_motion: Vector2) -> void:
	mouse_motion += relative_motion


func clear_mouse_motion() -> void:
	mouse_motion = Vector2.ZERO


func physics_update(
	delta: float,
	free_look_active: bool,
	input_locked: bool
) -> void:
	if player == null:
		return

	# A fresh spawn requested ground mode; resolve it now that we're in a physics frame (the
	# surface raycasts need it). Runs even while input_locked so the immobilize on spawn
	# doesn't leave the player floating. Retries a few frames, then gives up (stays zero-G).
	if pending_spawn_ground_mode:
		if ground.enter_spawn_surface_walk() or pending_spawn_ground_frames <= 0:
			pending_spawn_ground_mode = false
		else:
			pending_spawn_ground_frames -= 1

	update_surface_cache()
	update_ctrl_push_cache()
	update_limb_push_cache()
	update_hud_values(input_locked)
	update_auto_ground_lock(delta, input_locked)
	ground.update_surface_walk_entry_shake(delta)
	
	if input_locked:
		handle_input_locked_state()
		update_recoil(delta)
		clear_mouse_motion()
		return

	consume_recoil_compensation()
	update_jump_charge(delta)

	match movement_mode:
		MovementMode.ZERO_G:
			physics_update_zero_g(delta, free_look_active)

		MovementMode.SURFACE_WALK:
			physics_update_surface_walk(delta)

	update_recoil(delta)
	clear_mouse_motion()


func update_hud_values(input_locked: bool) -> void:
	if hud_controller != null:
		hud_controller.update_jump_force(jump_force)
		
		var should_show_limb_ui := (
			show_limb_push_debug_ui
			and wall_push_enabled
			and movement_mode == MovementMode.ZERO_G
			and not input_locked
		)
		
		if not show_limb_push_ui_when_no_limb_near:
			should_show_limb_ui = should_show_limb_ui and bool(last_limb_push_state.get("has_limb_contact", false))
		
		if hud_controller.has_method("update_limb_push_indicator"):
			hud_controller.update_limb_push_indicator(should_show_limb_ui, last_limb_push_state)
		
		if hud_controller.has_method("update_slide_indicator"):
			hud_controller.update_slide_indicator(not input_locked and is_sliding())


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


# While free-look is held the buffered aim motion is simply not applied (and cleared at the
# end of the tick), so the mouse moves nothing until it's released.
func physics_update_zero_g(delta: float, free_look_active: bool) -> void:
	if not free_look_active:
		handle_body_mouse_rotation()
		update_body_follow(delta)

	handle_jump_input()
	handle_grab_input()
	handle_roll_input(delta)
	handle_stabilize_input(delta)


func physics_update_surface_walk(delta: float) -> void:
	release_grab()
	ground.physics_update_ground(delta)


# --- Mode transitions (called by GroundMovementController) -------------------------------


func begin_surface_walk_mode() -> void:
	release_grab()
	movement_mode = MovementMode.SURFACE_WALK


func end_surface_walk_mode() -> void:
	movement_mode = MovementMode.ZERO_G
	view_initialized = false   # re-sync head-up to the post-exit orientation
	auto_ground_cooldown = 0.75
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false


# Folds the current view (recoil included) into the body basis on ground-mode exit, so the
# zero-G orientation continues exactly where the player was looking.
func fold_view_into_body() -> void:
	reset_recoil()

	if camera != null:
		var camera_basis := get_control_look_basis()
		player.global_transform = Transform3D(camera_basis, player.global_position)
		camera.rotation = Vector3.ZERO
		player.reset_physics_interpolation()


func reset_recoil() -> void:
	recoil_pending = Vector2.ZERO
	recoil_offset = Vector2.ZERO


# Public exit kept here for external callers (grapple tension, death/respawn resets).
func exit_surface_walk_mode() -> void:
	if movement_mode != MovementMode.SURFACE_WALK:
		return

	ground.exit_surface_walk_mode()


# AUTO ground lock — the ONLY way in: floating with your feet pointing at a surface within
# reach engages ground mode by itself (gated by the entry angle; C is the slide, not a
# mount key, and the only manual exits are the space launch and external forces).
func update_auto_ground_lock(delta: float, input_locked: bool) -> void:
	if auto_ground_cooldown > 0.0:
		auto_ground_cooldown = maxf(auto_ground_cooldown - delta, 0.0)

	if input_locked:
		return

	if movement_mode != MovementMode.ZERO_G or pending_spawn_ground_mode or auto_ground_cooldown > 0.0:
		return

	var probe := ground.get_auto_ground_probe()

	if probe.is_empty():
		return

	ground.enter_surface_walk_mode(probe["position"], (probe["normal"] as Vector3).normalized())


func request_spawn_ground_mode() -> void:
	pending_spawn_ground_mode = true
	pending_spawn_ground_frames = SPAWN_GROUND_MODE_MAX_FRAMES


# --- C# HUD contract (Hud.cs reads/calls these BY NAME on this node) ---------------------

# Kept as a readable property mirroring the ground node's lock reach.
var surface_walk_lock_max_distance: float = GroundMovementController.SURFACE_WALK_LOCK_MAX_DISTANCE


func find_spawn_surface(max_distance: float, max_normal_angle_degrees: float = -1.0) -> Dictionary:
	if ground == null:
		return {}

	return ground.find_spawn_surface(max_distance, max_normal_angle_degrees)


func is_surface_walk_active() -> bool:
	return movement_mode == MovementMode.SURFACE_WALK


func is_sliding() -> bool:
	return ground != null and ground.is_sliding()


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
	var sens := get_mouse_sensitivity()

	# Yaw around the body's OWN up axis, so a left flick always turns the view left no matter how
	# the body is oriented. (Yawing around a fixed world-up inverts left/right when upside down.)
	if mouse_motion.x != 0.0:
		basis = basis.rotated(basis.y, -mouse_motion.x * sens).orthonormalized()

	# Pitch first articulates the neck (camera) up to a limit; the overflow past it tumbles the
	# whole body around its right axis — a free 0g flip — so up/down never hits a hard stop.
	if mouse_motion.y != 0.0:
		var neck_limit := deg_to_rad(look_neck_limit_degrees)
		var desired := look_pitch - mouse_motion.y * sens
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


# Weapon recoil kick to the aim (+pitch = up): buffered here, eased into the view by
# update_recoil. Camera-space only — shooting never tumbles or reorients the body.
func apply_look_recoil(pitch_degrees: float, yaw_degrees: float) -> void:
	recoil_pending += Vector2(deg_to_rad(pitch_degrees), deg_to_rad(yaw_degrees))
	recoil_recovery_wait = recoil_recovery_delay


# The player's own counter-pull eats the recoil offset first (1:1) before moving the base look,
# so the later recentering never yanks the view past where they were actually aiming.
func consume_recoil_compensation() -> void:
	if recoil_offset == Vector2.ZERO or mouse_motion == Vector2.ZERO:
		return

	var sens := get_mouse_sensitivity()

	if sens <= 0.0:
		return

	# Look deltas in radians: pitch = -mouse.y * sens, yaw = -mouse.x * sens.
	var eaten := Vector2(
		eat_recoil_offset(recoil_offset.x, -mouse_motion.y * sens),
		eat_recoil_offset(recoil_offset.y, -mouse_motion.x * sens)
	)
	recoil_offset += eaten
	mouse_motion += Vector2(eaten.y, eaten.x) / sens


# Signed portion of look_delta that cancels the offset (opposite signs only).
static func eat_recoil_offset(offset_value: float, look_delta: float) -> float:
	if offset_value == 0.0 or signf(look_delta) != -signf(offset_value):
		return 0.0

	return signf(look_delta) * minf(absf(look_delta), absf(offset_value))


# Ease the pending kick into the camera-space offset, clamp it to the pitch head-room left (a
# spray stops at the limit instead of flipping the body like the mouse does), recenter after the
# delay, and render the offset on top of the base pitch the look handlers wrote this frame.
func update_recoil(delta: float) -> void:
	if recoil_pending == Vector2.ZERO and recoil_offset == Vector2.ZERO:
		return

	var walking := is_surface_walk_active()
	var limit := deg_to_rad(ground.surface_walk_pitch_limit_degrees if walking else look_neck_limit_degrees)

	var step := recoil_pending * clampf(1.0 - exp(-recoil_apply_speed * delta), 0.0, 1.0)
	recoil_pending -= step
	recoil_offset += Vector2(step.x * recoil_recovery_fraction, step.y)

	# The rest of the climb is permanent: folded into the base look (clamped, never tumbling
	# the body), so sustained fire walks the aim up until the player pulls it down.
	var permanent := step.x * (1.0 - recoil_recovery_fraction)

	if permanent != 0.0:
		if walking:
			ground.surface_walk_pitch = clampf(ground.surface_walk_pitch + permanent, -limit, limit)
		else:
			look_pitch = clampf(look_pitch + permanent, -limit, limit)

	if recoil_pending.length_squared() < 0.00000001:
		recoil_pending = Vector2.ZERO

	# Base the recoil around the APPLIED pitch while walking (aim + gimbal stabilizer) so the
	# stabilized view holds under fire too; the permanent climb above still writes the pure aim.
	var base: float = ground.get_surface_walk_applied_pitch() if walking else look_pitch
	recoil_offset.x = clampf(recoil_offset.x, -limit - base, limit - base)

	var recover_rate := recoil_recovery_speed

	if recoil_recovery_wait > 0.0:
		recoil_recovery_wait -= delta
		recover_rate *= recoil_fire_settle_fraction   # recovery keeps running mid-spray

	recoil_offset *= exp(-recover_rate * delta)

	if recoil_offset.length_squared() < 0.00000001:
		recoil_offset = Vector2.ZERO

	if camera != null:
		camera.rotation = Vector3(base + recoil_offset.x, recoil_offset.y, 0.0)


# Zero-G push fires on RELEASE with the charged force (jump_force = the live charge).
func handle_jump_input() -> void:
	if not wall_push_enabled:
		return

	if not is_action_just_released_if_exists("push"):
		return

	if is_action_pressed_if_exists("ctrl_push"):
		try_ctrl_push()
	else:
		try_normal_push()

	reset_jump_charge()


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

	# Sliding pins the limb dots to their rest state (visually "standing still"); the same
	# flag is the hook any future limb run-cycle animation should key off.
	if limb_push_controller.has_method("set_limbs_frozen"):
		limb_push_controller.set_limbs_frozen(is_sliding())

	if not wall_push_enabled or movement_mode != MovementMode.ZERO_G:
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


func get_roll_start_speed() -> float:
	return GameSettings.roll_start_speed if GameSettings.roll_start_speed >= 0.0 else roll_start_speed


func get_roll_max_speed() -> float:
	return GameSettings.roll_max_speed if GameSettings.roll_max_speed >= 0.0 else roll_max_speed


func get_roll_speed_change_rate() -> float:
	return GameSettings.roll_speed_change_rate if GameSettings.roll_speed_change_rate >= 0.0 else roll_speed_change_rate


# Velocity-driven roll: the speed along the roll axis is steered directly (no torque, no
# inertia float). Press = instant start speed in that direction (any opposing spin dies on
# the spot), hold = ramp to max, release = bleed to zero, all at the one change rate.
func handle_roll_input(delta: float) -> void:
	var roll_input := 0.0

	if is_action_pressed_if_exists("roll_left"):
		roll_input += 1.0

	if is_action_pressed_if_exists("roll_right"):
		roll_input -= 1.0

	var roll_axis := get_screen_roll_axis()
	var current_speed := player.angular_velocity.dot(roll_axis)
	var change_step := deg_to_rad(get_roll_speed_change_rate()) * delta
	var new_speed: float

	if roll_input == 0.0:
		new_speed = move_toward(current_speed, 0.0, change_step)
	else:
		new_speed = current_speed

		if new_speed * roll_input < deg_to_rad(get_roll_start_speed()):
			new_speed = roll_input * deg_to_rad(get_roll_start_speed())

		new_speed = move_toward(new_speed, roll_input * deg_to_rad(get_roll_max_speed()), change_step)

	player.angular_velocity += roll_axis * (new_speed - current_speed)


func handle_stabilize_input(delta: float) -> void:
	if not is_action_pressed_if_exists("stabilize_rotation"):
		return

	player.angular_velocity = player.angular_velocity.move_toward(
		Vector3.ZERO,
		deg_to_rad(get_roll_speed_change_rate()) * delta
	)


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
	_ray_query.from = origin
	_ray_query.to = end
	return player.get_world_3d().direct_space_state.intersect_ray(_ray_query)


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
	if not wall_push_enabled:
		return false

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


func is_action_just_released_if_exists(action_name: String) -> bool:
	return InputMap.has_action(action_name) and Input.is_action_just_released(action_name)


func get_action_strength_if_exists(action_name: String) -> float:
	if not InputMap.has_action(action_name):
		return 0.0
	
	return Input.get_action_strength(action_name)
