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
@export var surface_walk_jump_momentum_carry: float = 1.35  # run speed kept (and boosted) on jump-off

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

@export var grabbed_linear_damp: float = 12.0
@export var grabbed_angular_damp: float = 4.0

# Walk / sprint speed as CURVES instead of a pile of scalars. Each curve is speed (Y, m/s)
# over seconds-since-you-started-moving (X, the curve's DOMAIN). Three control points do the
# whole job: bottom-left = start/creep speed, middle = shapes the acceleration ramp (drag it
# around, use the tangent handles to ease), top-right = top speed. The curve's SLOPE *is* the
# acceleration, so there's no separate accel/time/multiplier knob. Sprint just swaps in the
# sprint curve; a shared ramp timer keeps walk<->sprint smooth. Leave them null and setup()
# builds sensible defaults (walk 0->3, sprint 0->6 m/s); edit in the inspector's curve editor.
@export var walk_speed_curve: Curve
@export var sprint_speed_curve: Curve

@export var surface_walk_body_offset: float = 0.85
@export var surface_walk_snap_strength: float = 10.0
@export var surface_walk_max_snap_speed: float = 8.0
@export var surface_walk_mouse_sensitivity: float = 0.0025
@export var surface_walk_pitch_limit_degrees: float = 82.0
# View-pitch stabilizer ("gimbal"): the camera pitch you set with the mouse is held steady
# against the body's own pitch nod as it re-orients to follow the surface — walking over bumps,
# seams and curves no longer rocks your aim up/down; only the mouse (and recoil) pitch the view.
# It works by measuring the pitch the alignment adds to the body each frame and cancelling it on
# the camera, then washing that cancellation out at this per-second rate so a SUSTAINED
# reorientation (deliberately climbing onto a wall/ceiling) still settles the view onto the new
# surface instead of leaving you looking the wrong way. LOWER = more locked / gimbaled (quick
# nods held out harder, big transitions settle slower); HIGHER = looser (follows the surface
# sooner). Keep it > 0 so transitions always settle. 0 disables the stabilizer entirely.
@export var surface_walk_pitch_stabilize_recenter: float = 3.0
@export var surface_walk_space_launches_off: bool = true

@export var surface_walk_transition_duration: float = 0.14
@export var surface_walk_entry_shake_duration: float = 0.18
@export var surface_walk_entry_shake_strength: float = 0.07
@export var surface_walk_entry_shake_frequency: float = 52.0

# Spawn ground-lock: how far to search around a spawn point for a surface to stand on. It
# always snaps to the NEAREST surface found (instant, no slide), so a generous radius only
# widens coverage — a capsule resting ~1 m off a floor still lands on that floor. If nothing
# is within range the player just spawns free-floating (zero-G) instead.
@export var surface_walk_spawn_probe_distance: float = 8.0

@export var surface_walk_edge_check_extra_distance: float = 0.35

# Edge traversal: a surface ahead in the walk direction takes over as the walked surface once
# it's within stand range (concave seam), and forward-down rays carry the body over a convex
# crest. Only REASONABLE seams are walkable: candidates angled further than max_edge_angle
# from the current surface are ignored — sharp rims are a drop-off, steep walls a jam.surface_walk_max_concave_angle_degrees
@export var surface_walk_wrap_probe: bool = true
@export var surface_walk_max_edge_angle_degrees: float = 70.0
# Concave handover limit for the FEELER ray only (walking INTO a surface). Kept a bit
# above max_edge_angle so a deliberate walk-in still climbs steep-but-walkable seams (the
# Diamond arena's ~70.5° interior seams must keep working at speed), but BELOW vertical:
# a face ~90° off the one you stand on is a WALL — it blocks you like a wall instead of
# rotating you onto it. Raise back toward 120 to restore walk-up-any-wall traversal;
# lower toward max_edge_angle for stricter walls.
@export var surface_walk_max_concave_angle_degrees: float = 95.0
# What happens when you WALK INTO a face too steep to climb (steeper than the concave limit
# above). OFF (default): you stop dead against it and slide along its base, staying grounded
# — a wall behaves like a wall. ON: you detach into zero-G instead. Either way the wall is
# never auto-aligned to. This exists because, without it, physics depenetration off a
# rejected steep face randomly LIFTS you off some walls (inward-leaning/curved ones) but not
# others, which reads as "sometimes I leave ground mode against a wall, sometimes I don't".
@export var surface_walk_wall_forces_zero_g: bool = false
# The ground orientation target is BLENDED from several probes (down ray + four foot rays
# + the crest sweeps), weighted by hit distance, instead of one winner-takes-all ray.
# Crossing a seam the weight hands over gradually — no face-to-face flip-flopping — and on
# curved colliders (SphereShape3D etc.) the target varies continuously. This is the spacing
# of the foot probes around the body (metres).
@export var surface_walk_probe_foot_offset: float = 0.28
# Anchor hysteresis: standing exactly ON an edge, the nearest-hit ray alternates faces every
# physics frame. The anchored face (snap plane / movement tangent / gate reference) only
# SWITCHES once a different face has been the dominant support for this long — alternation
# never persists, so the anchor can't flip-flop. Curved surfaces drift a fraction of
# same_face_degrees per frame, so they track continuously and never engage the timer.
@export var surface_walk_anchor_switch_time: float = 0.12
@export var surface_walk_anchor_same_face_degrees: float = 15.0
# Sticky blending: hits on faces OTHER than the anchored one contribute at most this weight
# fraction, scaled further down toward 0 at standstill — standing on a corner the body hugs
# the anchored face (no rocking, no averaged 45° lean), while at walk speed the new face
# blends in for a smooth handover.
@export var surface_walk_foreign_face_weight: float = 0.35
# Low-pass on the orientation target (per-second rate): absorbs the residual per-frame ray
# alternation right on an edge; the align tween below handles the rest.
@export var surface_walk_target_smoothing: float = 22.0

# Slope alignment: while ground-walking, ease the body's (and camera's) orientation onto the
# surface under it. Full ease-in/ease-out tween: the turn rate ramps up (align_accel), is
# capped (max_turn_speed), and decays exponentially (align_speed) — never a linear snap.
@export var surface_walk_slope_align_speed: float = 10.0
@export var surface_walk_slope_align_max_turn_speed_degrees: float = 175.0
@export var surface_walk_align_accel: float = 6.5
@export var surface_walk_friction: float = 0.0

# Ground-lock timing: angle your body so your feet face a surface, then press C to lock onto
# it. You can lock from up to `max_distance` metres away (measured straight off your feet);
# locking exactly at `sweet_spot` metres is clean. Missing the sweet spot — too far (toward
# max) OR too close (toward the surface) — temporarily "dazes" the first-person camera with
# look-inertia that scales with how far off the timing was. Hit the sweet spot: no daze.
# Entry ALIGNMENT gate: C only accepts a surface whose normal is within
# `entry_max_angle_degrees` of the body's own up — your feet must genuinely face it. Spawn
# grounding (round start / respawn) is exempt and still snaps to the nearest surface.
@export var surface_walk_entry_max_angle_degrees: float = 20.0
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
var _ray_query: PhysicsRayQueryParameters3D

var movement_mode: int = MovementMode.ZERO_G

var mouse_motion: Vector2 = Vector2.ZERO
var free_look_mouse_motion: Vector2 = Vector2.ZERO

var roll_hold_time: float = 0.0

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

var surface_walk_normal: Vector3 = Vector3.UP
var surface_walk_forward: Vector3 = Vector3.FORWARD
var surface_walk_anchor_point: Vector3 = Vector3.ZERO
# The anchor's own raw hit normal. The snap measures stand distance along THIS — measuring
# along the smoothed body normal launches the body when a seam swaps the anchor ~90 degrees.
var surface_walk_anchor_normal: Vector3 = Vector3.UP
var surface_walk_pitch: float = 0.0
# Camera-pitch offset that cancels the body's alignment-induced nod (the "gimbal", see
# surface_walk_pitch_stabilize_recenter). Added to surface_walk_pitch only when writing the
# camera; the aim value itself stays mouse/recoil-driven. Washes toward 0 each frame.
var surface_walk_pitch_stabilize: float = 0.0
# Low-passed orientation target (see surface_walk_target_smoothing) and how long a face
# OTHER than the anchored one has been the nearest support (drives the anchor switch).
var surface_walk_smoothed_target: Vector3 = Vector3.UP
var surface_walk_anchor_foreign_time: float = 0.0

# Curve-driven speed: shared ramp timer (seconds spent moving, drives the X of the speed
# curve), the last move direction (to detect a sharp reversal), and each curve's cached
# steepest slope (the move_toward rate, so velocity tracks the curve with no accel knob).
var surface_walk_accel_time: float = 0.0
var surface_walk_last_move_dir: Vector3 = Vector3.ZERO
var _walk_curve_max_slope: float = 60.0
var _sprint_curve_max_slope: float = 60.0

var surface_walk_transition_active: bool = false
var surface_walk_transition_timer: float = 0.0
var surface_walk_transition_start_transform: Transform3D
var surface_walk_transition_target_transform: Transform3D

var camera_base_position: Vector3 = Vector3.ZERO
var surface_walk_shake_timer: float = 0.0
var surface_walk_align_rate: float = 0.0   # rad/s, eased by surface_walk_align_accel
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

	if camera != null:
		camera_base_position = camera.position

	if GameSettings.mouse_sensitivity > 0.0:
		mouse_sensitivity = GameSettings.mouse_sensitivity

	setup_limb_push_controller()
	init_surface_walk_speed_curves()

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

	# A fresh spawn requested ground mode; resolve it now that we're in a physics frame (the
	# surface raycasts need it). Runs even while input_locked so the daze/immobilize on spawn
	# doesn't leave the player floating. Retries a few frames, then gives up (stays zero-G).
	if pending_spawn_ground_mode:
		if enter_spawn_surface_walk() or pending_spawn_ground_frames <= 0:
			pending_spawn_ground_mode = false
		else:
			pending_spawn_ground_frames -= 1

	update_surface_cache()
	update_ctrl_push_cache()
	update_limb_push_cache()
	update_surface_walk_entry_cache()
	update_hud_values(input_locked)
	handle_movement_mode_toggle(input_locked)
	update_surface_walk_entry_shake(delta)
	
	if input_locked:
		handle_input_locked_state()
		update_recoil(delta)
		clear_mouse_motion()
		clear_free_look_mouse_motion()
		return

	consume_recoil_compensation()

	match movement_mode:
		MovementMode.ZERO_G:
			physics_update_zero_g(delta, free_look_active)

		MovementMode.SURFACE_WALK:
			physics_update_surface_walk(delta)

	update_recoil(delta)
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
		print(
			"Ground lock failed: no surface within ", surface_walk_lock_max_distance,
			" m aligned with your feet (within ", surface_walk_entry_max_angle_degrees, " degrees)."
		)
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


# Called on (re)spawn: find the nearest surface around the spawn point and drop straight into
# ground mode on it (no transition, no daze). Returns true if a surface was found; if not, the
# player is left free-floating in zero-G. Facing comes from the spawn transform's forward.
func request_spawn_ground_mode() -> void:
	pending_spawn_ground_mode = true
	pending_spawn_ground_frames = SPAWN_GROUND_MODE_MAX_FRAMES


func enter_spawn_surface_walk() -> bool:
	var surface := find_spawn_surface(surface_walk_spawn_probe_distance)

	if surface.is_empty():
		return false

	# Fresh spawn: no leftover mistimed-lock daze.
	surface_walk_daze_timer = 0.0
	surface_walk_daze_duration = 0.0
	surface_walk_daze_strength = 0.0

	enter_surface_walk_mode(surface["position"], (surface["normal"] as Vector3).normalized(), true)
	return true


# The nearest lockable surface around the player, probing the body's own axes (feet first, so
# an upright spawn capsule resting on a floor wins). `max_normal_angle_degrees` > 0 filters
# out surfaces whose normal is further than that from the body's up (the manual ground-lock
# alignment gate); the spawn path passes no limit and takes the nearest surface regardless.
# Returns {position, normal} or {}.
func find_spawn_surface(max_distance: float, max_normal_angle_degrees: float = -1.0) -> Dictionary:
	if player == null:
		return {}

	var basis := player.global_transform.basis
	# Feet first (-Y), then the remaining five body axes.
	var directions := [-basis.y, basis.y, basis.x, -basis.x, -basis.z, basis.z]

	var best: Dictionary = {}
	var best_distance := INF
	var origin := player.global_position

	for i in range(directions.size()):
		var direction: Vector3 = directions[i]

		if direction.length() < 0.01:
			continue

		direction = direction.normalized()
		var result := raycast_from_player(origin, origin + direction * max_distance)

		if result.is_empty():
			continue

		var normal: Vector3 = result.get("normal", Vector3.ZERO)

		if normal.length() < 0.01:
			continue

		normal = normal.normalized()

		if max_normal_angle_degrees > 0.0 and rad_to_deg(basis.y.angle_to(normal)) > max_normal_angle_degrees:
			continue

		var hit_position: Vector3 = result.get("position", origin)
		var distance := origin.distance_to(hit_position)

		# Tiny bias toward the feet direction so a clean upright placement wins near-ties.
		if i == 0:
			distance -= 0.01

		if distance < best_distance:
			best_distance = distance
			best = {"position": hit_position, "normal": normal}

	return best


# Probes straight off the player's feet (body -Y) for a lockable surface within the max lock
# distance. Returns {position, normal, distance(metres)} or {} if nothing is in range. You must
# first angle your body so your feet face the surface, then time the press as you approach.
func get_ground_lock_probe() -> Dictionary:
	if player == null:
		return {}

	var origin := player.global_position
	var direction := get_ground_lock_probe_direction()

	if direction.length() >= 0.01:
		direction = direction.normalized()
		var end := origin + direction * surface_walk_lock_max_distance
		var result := raycast_from_player(origin, end)

		if not result.is_empty():
			var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

			# Alignment gate: the surface's normal must match the body's up within
			# surface_walk_entry_max_angle_degrees — feet pointing AT a surface isn't
			# enough if the body is tilted across it (e.g. feet ray clipping a wall edge).
			if hit_normal.length() >= 0.01 and rad_to_deg(
				player.global_transform.basis.y.angle_to(hit_normal.normalized())
			) <= surface_walk_entry_max_angle_degrees:
				var hit_position: Vector3 = result.get("position", end)
				return {
					"position": hit_position,
					"normal": hit_normal.normalized(),
					"distance": origin.distance_to(hit_position),
				}

	# 6DOF fallback: the feet ray can miss a surface the body is nonetheless hovering over
	# (uneven ground, edges). Same alignment gate — only surfaces the body's up already
	# agrees with within the entry angle qualify, so you can't lock onto a wall beside you.
	var nearest := find_spawn_surface(surface_walk_lock_max_distance, surface_walk_entry_max_angle_degrees)

	if nearest.is_empty():
		return {}

	var nearest_position: Vector3 = nearest["position"]
	return {
		"position": nearest_position,
		"normal": nearest["normal"],
		"distance": origin.distance_to(nearest_position),
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


func enter_surface_walk_mode(hit_position: Vector3, surface_normal: Vector3, instant: bool = false) -> void:
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
	surface_walk_anchor_normal = surface_walk_normal
	surface_walk_smoothed_target = surface_walk_normal
	surface_walk_anchor_foreign_time = 0.0
	surface_walk_align_rate = 0.0
	surface_walk_accel_time = 0.0
	surface_walk_last_move_dir = Vector3.ZERO

	var look_forward := (-player.global_transform.basis.z).normalized()
	var projected_forward := look_forward.slide(surface_walk_normal)
	
	if projected_forward.length() < 0.01:
		projected_forward = player.global_transform.basis.y.slide(surface_walk_normal)
	
	if projected_forward.length() < 0.01:
		projected_forward = get_fallback_surface_forward(surface_walk_normal)
	
	surface_walk_forward = projected_forward.normalized()
	surface_walk_pitch = 0.0
	surface_walk_pitch_stabilize = 0.0
	recoil_pending = Vector2.ZERO
	recoil_offset = Vector2.ZERO
	
	var target_position := hit_position + surface_walk_normal * surface_walk_body_offset
	var target_basis := make_surface_walk_basis(surface_walk_forward, surface_walk_normal)
	var target_transform := Transform3D(target_basis, target_position)
	
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false

	if camera != null:
		camera.rotation = Vector3.ZERO

	if instant:
		# Spawn path: snap straight onto the surface with no slide-in animation or entry shake.
		surface_walk_transition_active = false
		player.global_transform = target_transform
		player.reset_physics_interpolation()
		print("Spawned in surface-walk mode.")
		return

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
		# No walkable ground under us — walked off an edge / past a drop-off. Let go: exit
		# into zero-G keeping the run's momentum, so you float off the lip naturally. Walls
		# still stop you (the wall block strips into-wall motion before this can fire for
		# them); only genuine loss of ground releases the surface.
		exit_surface_walk_mode()
		return true

	var raw_normal := (result["normal"] as Vector3).normalized()
	var target_normal := (result.get("target_normal", raw_normal) as Vector3).normalized()

	# Orientation eases toward the low-passed BLENDED normal: sticky weighting keeps it near
	# the anchored face at low speed (no corner rocking), the blend is continuous across
	# seams/curves, and the low-pass absorbs per-frame ray alternation right on an edge.
	# nlerp, NOT slerp: slerp's internal rotation axis is the cross product of the two
	# vectors, which degenerates into float noise when they're near-identical (the common
	# case here) and spams "axis must be normalized". At these tiny per-frame steps
	# lerp+normalize is equivalent.
	var smooth_weight := clampf(1.0 - exp(-surface_walk_target_smoothing * delta), 0.0, 1.0)
	var smoothed := surface_walk_smoothed_target.lerp(target_normal, smooth_weight)
	surface_walk_smoothed_target = smoothed.normalized() if smoothed.length() > 0.01 else target_normal
	align_surface_walk_normal_toward(surface_walk_smoothed_target, delta)

	# Anchor (snap plane / movement tangent / gate reference) with hysteresis: standing on an
	# edge the nearest hit alternates faces every frame, so a DIFFERENT face only takes the
	# anchor after persisting as the dominant support — meanwhile the anchor keeps tracking
	# its own face through the same-face hit (curves drift a fraction of the same-face angle
	# per frame, so they track continuously and never engage the timer). A feeler handover
	# has no same-face hit and switches immediately (deliberate walk-in).
	if rad_to_deg(raw_normal.angle_to(surface_walk_anchor_normal)) <= surface_walk_anchor_same_face_degrees:
		surface_walk_anchor_foreign_time = 0.0
		surface_walk_anchor_point = result["position"]
		surface_walk_anchor_normal = raw_normal
	else:
		surface_walk_anchor_foreign_time += delta

		if result.has("same_face_normal") and surface_walk_anchor_foreign_time < surface_walk_anchor_switch_time:
			surface_walk_anchor_point = result["same_face_position"]
			surface_walk_anchor_normal = (result["same_face_normal"] as Vector3).normalized()
		else:
			surface_walk_anchor_foreign_time = 0.0
			surface_walk_anchor_point = result["position"]
			surface_walk_anchor_normal = raw_normal

	return false


# Eases the walked-surface normal toward the ground under the player, so seams and curves
# smoothly bank the body into the new orientation. Capped per frame so a sharp crease can't
# whip the camera. Forward is parallel-transported through the same rotation (not re-projected)
# so heading stays stable across big normal swings — sphere loops, 90-degree seams.
func align_surface_walk_normal_toward(target_normal: Vector3, delta: float) -> void:
	if target_normal.length() < 0.01:
		return

	target_normal = target_normal.normalized()
	var full_angle := surface_walk_normal.angle_to(target_normal)

	if full_angle < 0.0001:
		return

	var exp_weight := 1.0 - exp(-surface_walk_slope_align_speed * delta)
	var max_step := deg_to_rad(surface_walk_slope_align_max_turn_speed_degrees) * delta
	var desired_step := minf(full_angle * exp_weight, max_step)
	# Ease the turn rate toward the desired rate: soft onset; the exponential tail above
	# already softens the stop.
	surface_walk_align_rate = lerpf(
		surface_walk_align_rate,
		desired_step / delta,
		clampf(1.0 - exp(-surface_walk_align_accel * delta), 0.0, 1.0)
	)
	var step_angle := minf(desired_step, surface_walk_align_rate * delta)
	var t := clampf(step_angle / full_angle, 0.0, 1.0)

	# Snapshot before the turn so the stabilizer can measure the PITCH this alignment adds to the
	# body (forward tilting toward the old up axis) and cancel it on the camera — a left/right
	# tilt is roll and stays 0 here, so only the fore/aft nod is compensated.
	var old_forward := surface_walk_forward
	var old_up := surface_walk_normal

	var new_normal := surface_walk_normal.slerp(target_normal, t).normalized()
	surface_walk_forward = Quaternion(surface_walk_normal, new_normal) * surface_walk_forward
	surface_walk_normal = new_normal

	var projected_forward := surface_walk_forward.slide(surface_walk_normal)

	if projected_forward.length() < 0.01:
		projected_forward = get_fallback_surface_forward(surface_walk_normal)

	surface_walk_forward = projected_forward.normalized()

	if surface_walk_pitch_stabilize_recenter > 0.0:
		surface_walk_pitch_stabilize -= (surface_walk_forward - old_forward).dot(old_up)


# Ground probe. A feeler along the walk direction hands over an approaching concave seam
# outright (no blending — competing normal sources stall in an equilibrium and jam the
# player); the feeler uses the LARGER concave limit so a deliberate walk into a steep wall
# always rotates the player onto it. Otherwise the ground is sampled by several rays — the
# down ray, front/back foot rays straddling any seam, and two forward-down sweeps (a convex
# crest's next face sits ahead-below). The NEAREST hit stays the physical anchor (snap plane
# and edge gating), while "target_normal" is the distance-weighted BLEND of every hit: a
# CONTINUOUS orientation target, so seams hand over gradually as the feet cross them and
# curved colliders (analytic sphere/capsule shapes) bank the body smoothly — no
# face-to-face flip-flopping. Returns {position, normal, target_normal} or {}.
func get_surface_walk_ground_result() -> Dictionary:
	if player == null:
		return {}

	var origin := player.global_position
	var probe_length := surface_walk_body_offset + surface_walk_edge_check_extra_distance + 0.08
	var move_dir := get_surface_walk_probe_move_direction()

	if move_dir != Vector3.ZERO:
		var feeler := probe_surface_walk_ray(origin, move_dir, probe_length, surface_walk_max_concave_angle_degrees)

		if not feeler.is_empty():
			feeler["target_normal"] = feeler["normal"]
			return feeler

	# Foot-probe axes: along the walk direction when moving (front foot picks the next face
	# up early, back foot holds the old one), the body's own tangent axes when idle — so
	# standing ON a seam the feet still straddle it and the blend stays well-defined.
	var axis_a := move_dir
	var axis_b := Vector3.ZERO

	if axis_a == Vector3.ZERO:
		axis_a = (-player.global_transform.basis.z).slide(surface_walk_normal)

	if axis_a.length() > 0.01:
		axis_a = axis_a.normalized()
		axis_b = axis_a.cross(surface_walk_normal)

		if axis_b.length() > 0.01:
			axis_b = axis_b.normalized()

	# Each probe: [cast origin, direction].
	var lifted := origin + surface_walk_normal * 0.08
	var probes: Array = [[lifted, -surface_walk_normal]]

	for axis in [axis_a, axis_b]:
		if axis == Vector3.ZERO:
			continue

		probes.append([lifted + axis * surface_walk_probe_foot_offset, -surface_walk_normal])
		probes.append([lifted - axis * surface_walk_probe_foot_offset, -surface_walk_normal])

	if surface_walk_wrap_probe and move_dir != Vector3.ZERO:
		var wrap_right := move_dir.cross(surface_walk_normal)

		if wrap_right.length() > 0.01:
			wrap_right = wrap_right.normalized()

			for sweep_degrees: float in [30.0, 60.0]:
				probes.append([lifted, (-surface_walk_normal).rotated(wrap_right, deg_to_rad(sweep_degrees))])

	# Sticky blending: faces other than the anchored one are down-weighted, and further so
	# at low speed — standing still the body hugs the anchored face instead of averaging
	# across a corner; at walk speed the next face blends in for the handover.
	var speed_ratio := clampf(
		player.linear_velocity.slide(surface_walk_anchor_normal).length() / maxf(get_surface_walk_top_speed(false), 0.01),
		0.0,
		1.0
	)
	var foreign_weight := surface_walk_foreign_face_weight * lerpf(0.1, 1.0, speed_ratio)
	var same_face_cos := cos(deg_to_rad(surface_walk_anchor_same_face_degrees))

	var best: Dictionary = {}
	var best_distance := INF
	var same_face_best: Dictionary = {}
	var same_face_distance := INF
	var blended_normal := Vector3.ZERO

	for probe in probes:
		var result := probe_surface_walk_ray(probe[0], probe[1], probe_length)

		if result.is_empty():
			continue

		var hit_normal := (result["normal"] as Vector3).normalized()
		var hit_distance := origin.distance_to(result["position"])
		var on_anchor_face := hit_normal.dot(surface_walk_anchor_normal) >= same_face_cos

		# Quadratic falloff: near supports dominate; a far face contributes a nudge, never a
		# takeover (the old nearest-wins intent, made continuous).
		var weight := 1.0 - clampf(hit_distance / probe_length, 0.0, 1.0)
		weight = weight * weight + 0.001

		if not on_anchor_face:
			weight *= foreign_weight

		blended_normal += hit_normal * weight

		if hit_distance < best_distance:
			best_distance = hit_distance
			best = result

		if on_anchor_face and hit_distance < same_face_distance:
			same_face_distance = hit_distance
			same_face_best = result

	if best.is_empty():
		return {}

	if blended_normal.length() > 0.01:
		best["target_normal"] = blended_normal.normalized()
	else:
		best["target_normal"] = best["normal"]

	# The nearest hit still ON the anchored face (if any) — the anchor keeps tracking its
	# own face while the hysteresis timer decides whether the nearest FOREIGN face takes over.
	if not same_face_best.is_empty():
		best["same_face_position"] = same_face_best["position"]
		best["same_face_normal"] = same_face_best["normal"]

	return best


# One validated probe ray: discards degenerate normals and surfaces angled further than
# the edge limit from the surface we're ON (anchor normal — never the eased display normal,
# which lags mid-tween and would reject legitimate bevel steps at speed). max_angle_degrees
# overrides the default limit (the concave feeler passes its own, larger one).
func probe_surface_walk_ray(
	origin: Vector3,
	direction: Vector3,
	length: float,
	max_angle_degrees: float = -1.0
) -> Dictionary:
	var result := raycast_from_player(origin, origin + direction * length)

	if result.is_empty():
		return {}

	var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

	if hit_normal.length() < 0.01:
		return {}

	var limit := max_angle_degrees if max_angle_degrees > 0.0 else surface_walk_max_edge_angle_degrees

	if rad_to_deg(surface_walk_anchor_normal.angle_to(hit_normal.normalized())) > limit:
		return {}

	return result


# Tangent direction the player is moving in — actual velocity first, falling back to the
# held input direction (pressed against a wall, velocity dies but intent hasn't), or ZERO
# when idle (no edge can be crossed standing still, so the extra rays are skipped).
func get_surface_walk_probe_move_direction() -> Vector3:
	var tangent := player.linear_velocity.slide(surface_walk_normal)

	if tangent.length() > 0.1:
		return tangent.normalized()

	var input_vector := get_surface_walk_input_vector()

	if input_vector.length() < 0.1:
		return Vector3.ZERO

	var forward := (-player.global_transform.basis.z).slide(surface_walk_normal).normalized()
	var right := player.global_transform.basis.x.slide(surface_walk_normal).normalized()
	var desired := right * input_vector.x + forward * input_vector.y

	if desired.length() < 0.01:
		return Vector3.ZERO

	return desired.normalized()


func exit_surface_walk_mode() -> void:
	if movement_mode != MovementMode.SURFACE_WALK:
		return
	
	surface_walk_transition_active = false
	surface_walk_shake_timer = 0.0
	surface_walk_align_rate = 0.0
	surface_walk_pitch_stabilize = 0.0

	surface_walk_daze_timer = 0.0
	surface_walk_daze_duration = 0.0
	surface_walk_daze_strength = 0.0
	surface_walk_look_yaw_vel = 0.0
	surface_walk_look_pitch_vel = 0.0
	# The fold below keeps the current view (recoil included) as the new body basis; zero the
	# offset so it isn't applied a second time on top.
	recoil_pending = Vector2.ZERO
	recoil_offset = Vector2.ZERO

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

	# Wash the gimbal offset back toward 0 so a sustained reorientation (climbing onto a wall)
	# still settles the view onto the new surface, and clamp it so aim + offset never exceed the
	# pitch limit. Runs every surface-walk frame (this function always does), so it decays even on
	# ground-lost frames where no fresh nod is added.
	if surface_walk_pitch_stabilize_recenter > 0.0:
		surface_walk_pitch_stabilize *= exp(-surface_walk_pitch_stabilize_recenter * delta)
		surface_walk_pitch_stabilize = clampf(
			surface_walk_pitch_stabilize,
			-pitch_limit - surface_walk_pitch,
			pitch_limit - surface_walk_pitch
		)
	else:
		surface_walk_pitch_stabilize = 0.0

	if camera != null:
		camera.rotation = Vector3(get_surface_walk_applied_pitch(), 0.0, 0.0)


# The pitch actually shown on the camera: the mouse/recoil aim plus the gimbal stabilizer offset,
# clamped to the pitch limit. surface_walk_pitch alone stays the pure aim.
func get_surface_walk_applied_pitch() -> float:
	var pitch_limit := deg_to_rad(surface_walk_pitch_limit_degrees)
	return clampf(surface_walk_pitch + surface_walk_pitch_stabilize, -pitch_limit, pitch_limit)


func update_surface_walk_orientation() -> void:
	player.global_transform = Transform3D(
		make_surface_walk_basis(surface_walk_forward, surface_walk_normal),
		player.global_position
	)
	
	player.angular_velocity = Vector3.ZERO


func handle_surface_walk_movement(delta: float) -> void:
	var input_vector := get_surface_walk_input_vector()
	var sprinting := is_surface_walk_sprinting()

	var forward := (-player.global_transform.basis.z).slide(surface_walk_normal).normalized()
	var right := player.global_transform.basis.x.slide(surface_walk_normal).normalized()

	if forward.length() < 0.01:
		forward = surface_walk_forward.normalized()

	if right.length() < 0.01:
		right = forward.cross(surface_walk_normal).normalized()

	# Ramp timer drives the speed curve. It winds UP while a direction is held (reset to 0 on a
	# sharp reversal so you re-accelerate through zero instead of snapping to full speed the
	# other way), and snaps to 0 when idle so the next start ramps from the bottom of the curve;
	# the stop itself is the move_toward-to-zero below. Clamped to the active curve's domain.
	var has_input := input_vector.length() > 0.01
	var move_dir := Vector3.ZERO

	if has_input:
		move_dir = right * input_vector.x + forward * input_vector.y
		move_dir = move_dir.normalized() if move_dir.length() > 0.01 else Vector3.ZERO

	if move_dir != Vector3.ZERO:
		if surface_walk_last_move_dir != Vector3.ZERO and move_dir.dot(surface_walk_last_move_dir) < 0.0:
			surface_walk_accel_time = 0.0
		surface_walk_accel_time += delta
		surface_walk_last_move_dir = move_dir
	else:
		surface_walk_accel_time = 0.0
		surface_walk_last_move_dir = Vector3.ZERO

	var active_curve := get_surface_walk_speed_curve(sprinting)

	if active_curve != null:
		surface_walk_accel_time = clampf(surface_walk_accel_time, 0.0, active_curve.max_domain)

	var target_speed := get_surface_walk_target_speed(sprinting)
	var current_acceleration := get_surface_walk_current_acceleration(sprinting)

	var desired_tangent_velocity := Vector3.ZERO

	if move_dir != Vector3.ZERO:
		desired_tangent_velocity = move_dir * target_speed

	# A face directly ahead that's too steep to climb (steeper than the concave handover
	# limit) is a WALL. Handle it deterministically here instead of leaving it to physics
	# depenetration (which lifts you off some walls and not others). ON -> detach to zero-G;
	# OFF -> strip the into-wall part of the walk so you stop against it and stay grounded.
	var wall_normal := get_surface_walk_wall_block_normal()

	if wall_normal != Vector3.ZERO:
		if surface_walk_wall_forces_zero_g:
			var carried := player.linear_velocity
			exit_surface_walk_mode()
			player.linear_velocity = carried
			return

		var wall_tangent := wall_normal.slide(surface_walk_anchor_normal)

		if wall_tangent.length() > 0.001:
			desired_tangent_velocity = strip_into_wall_component(desired_tangent_velocity, wall_tangent.normalized())

	# Slide on the ANCHOR normal (the snap's axis) so last tick's snap component is removed
	# before the fresh one is added — sliding on the smoothed normal lets snap velocity
	# accumulate into walk speed when the two diverge at a seam (launches the player).
	var current_tangent_velocity := player.linear_velocity.slide(surface_walk_anchor_normal)
	var new_tangent_velocity := current_tangent_velocity.move_toward(
		desired_tangent_velocity,
		current_acceleration * delta
	)

	# Also strip any pre-existing into-wall momentum so a fast run-up can't punch through the
	# wall in one frame before move_toward finishes decelerating it.
	if wall_normal != Vector3.ZERO and not surface_walk_wall_forces_zero_g:
		var wall_tangent := wall_normal.slide(surface_walk_anchor_normal)

		if wall_tangent.length() > 0.001:
			new_tangent_velocity = strip_into_wall_component(new_tangent_velocity, wall_tangent.normalized())

	var snap_velocity := get_surface_walk_snap_velocity()

	player.linear_velocity = new_tangent_velocity + snap_velocity
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false


# Removes the part of `velocity` heading INTO a wall, leaving motion parallel to it (a slide).
# `wall_tangent` is the wall's outward normal projected onto the stand plane (points away from
# the wall toward the player), so "into the wall" is the component with a NEGATIVE dot.
static func strip_into_wall_component(velocity: Vector3, wall_tangent: Vector3) -> Vector3:
	var into := velocity.dot(wall_tangent)

	if into < 0.0:
		return velocity - wall_tangent * into

	return velocity


# A face directly ahead in the walk direction that is too steep to walk up (steeper than the
# concave handover limit, measured against the surface you're standing on) is a wall — return
# its normal. Walkable seams (<= the concave limit) return ZERO: the ground probe's feeler
# already hands those over. ZERO when idle (no walk direction) or nothing ahead.
func get_surface_walk_wall_block_normal() -> Vector3:
	var move_dir := get_surface_walk_probe_move_direction()

	if move_dir == Vector3.ZERO:
		return Vector3.ZERO

	var origin := player.global_position + surface_walk_normal * 0.08
	var probe_length := surface_walk_body_offset + surface_walk_edge_check_extra_distance + 0.08
	var result := raycast_from_player(origin, origin + move_dir * probe_length)

	if result.is_empty():
		return Vector3.ZERO

	var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

	if hit_normal.length() < 0.01:
		return Vector3.ZERO

	hit_normal = hit_normal.normalized()

	# <= concave limit is a walkable seam the feeler hands you over to; only STEEPER blocks.
	if rad_to_deg(surface_walk_anchor_normal.angle_to(hit_normal)) <= surface_walk_max_concave_angle_degrees:
		return Vector3.ZERO

	return hit_normal


# Build sensible default speed curves if none were assigned in the inspector, then cache each
# curve's steepest slope (used as the move_toward acceleration). Walk 0.6->3, sprint 0.8->6 m/s
# to match the old scalar feel (base 3, the scenes' 2x sprint).
func init_surface_walk_speed_curves() -> void:
	if walk_speed_curve == null:
		walk_speed_curve = _default_speed_curve(0.6, 3.0, 0.18)

	if sprint_speed_curve == null:
		sprint_speed_curve = _default_speed_curve(0.8, 6.0, 0.18)

	_walk_curve_max_slope = _curve_max_slope(walk_speed_curve)
	_sprint_curve_max_slope = _curve_max_slope(sprint_speed_curve)


# Three-point speed-vs-time curve: (0, start), an ease-out mid (most of the speed early, then
# settle), and (ramp, top). Domain (X) = seconds; value range (Y) = m/s.
func _default_speed_curve(start_speed: float, top_speed: float, ramp_seconds: float) -> Curve:
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = top_speed
	curve.min_domain = 0.0
	curve.max_domain = ramp_seconds
	curve.add_point(Vector2(0.0, start_speed))
	curve.add_point(Vector2(ramp_seconds * 0.45, lerpf(start_speed, top_speed, 0.75)))
	curve.add_point(Vector2(ramp_seconds, top_speed))
	return curve


# The steepest rise/run over the curve's domain, so move_toward can track the curve on a
# straight-line start (never bottlenecking below the curve's own rate) while still easing
# through zero on a reversal or a stop.
func _curve_max_slope(curve: Curve) -> float:
	if curve == null:
		return 60.0

	var span := curve.max_domain - curve.min_domain

	if span <= 0.0001:
		return 60.0

	var steepest := 0.0
	var steps := 24

	for i in range(steps):
		var t0 := curve.min_domain + span * (float(i) / float(steps))
		var t1 := curve.min_domain + span * (float(i + 1) / float(steps))
		var slope := absf(curve.sample(t1) - curve.sample(t0)) / maxf(t1 - t0, 0.0001)
		steepest = maxf(steepest, slope)

	return maxf(steepest, 1.0)


func get_surface_walk_speed_curve(sprinting: bool) -> Curve:
	return sprint_speed_curve if sprinting else walk_speed_curve


# Top speed of a curve (its highest point = the top-right control point value). Used by the
# sensor to normalise walk speed and as a fallback if a curve is somehow missing.
func get_surface_walk_top_speed(sprinting: bool) -> float:
	var curve := get_surface_walk_speed_curve(sprinting)

	if curve == null:
		return 6.0 if sprinting else 3.0

	return curve.max_value


# Target speed = the speed curve sampled at the shared ramp timer (seconds moving). The curve's
# SLOPE is the acceleration, so no separate acceleration parameter exists.
func get_surface_walk_target_speed(sprinting: bool) -> float:
	var curve := get_surface_walk_speed_curve(sprinting)

	if curve == null:
		return get_surface_walk_top_speed(sprinting)

	return curve.sample(clampf(surface_walk_accel_time, curve.min_domain, curve.max_domain))


# move_toward rate: the active curve's steepest slope (see _curve_max_slope).
func get_surface_walk_current_acceleration(sprinting: bool) -> float:
	var slope := _sprint_curve_max_slope if sprinting else _walk_curve_max_slope
	return maxf(slope, 0.01)


func get_surface_walk_snap_velocity() -> Vector3:
	var distance_from_plane := surface_walk_anchor_normal.dot(player.global_position - surface_walk_anchor_point)
	var offset_error := surface_walk_body_offset - distance_from_plane

	var snap_speed := clampf(
		offset_error * surface_walk_snap_strength,
		-surface_walk_max_snap_speed,
		surface_walk_max_snap_speed
	)

	# Fade the snap in with alignment: a freshly acquired seam face (body not rotated onto it
	# yet) must not shove the body sideways at full spring strength — momentum carries the
	# turn, then the snap settles stand distance as the roll completes.
	snap_speed *= clampf(surface_walk_normal.dot(surface_walk_anchor_normal), 0.0, 1.0)

	return surface_walk_anchor_normal * snap_speed


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
	# Carry the run into the jump: keep the tangential velocity (snap component stripped so
	# jump height stays consistent), boosted a touch, with the launch added on top — never a
	# separate straight-up pop.
	var carried := player.linear_velocity.slide(launch_direction) * surface_walk_jump_momentum_carry
	exit_surface_walk_mode()

	player.linear_velocity = carried
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

	var sens := surface_walk_mouse_sensitivity if is_surface_walk_active() else mouse_sensitivity

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
	var limit := deg_to_rad(surface_walk_pitch_limit_degrees if walking else look_neck_limit_degrees)

	var step := recoil_pending * clampf(1.0 - exp(-recoil_apply_speed * delta), 0.0, 1.0)
	recoil_pending -= step
	recoil_offset += Vector2(step.x * recoil_recovery_fraction, step.y)

	# The rest of the climb is permanent: folded into the base look (clamped, never tumbling
	# the body), so sustained fire walks the aim up until the player pulls it down.
	var permanent := step.x * (1.0 - recoil_recovery_fraction)

	if permanent != 0.0:
		if walking:
			surface_walk_pitch = clampf(surface_walk_pitch + permanent, -limit, limit)
		else:
			look_pitch = clampf(look_pitch + permanent, -limit, limit)

	if recoil_pending.length_squared() < 0.00000001:
		recoil_pending = Vector2.ZERO

	# Base the recoil around the APPLIED pitch while walking (aim + gimbal stabilizer) so the
	# stabilized view holds under fire too; the permanent climb above still writes the pure aim.
	var base := get_surface_walk_applied_pitch() if walking else look_pitch
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
