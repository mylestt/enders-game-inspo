extends Node
class_name GroundMovementController

# SOURCE-STYLE ground movement on ANY surface orientation (floors, walls, ceilings, curved
# shells). Extracted from PlayerMovementController: this node owns everything that runs
# while the player is in ground mode; the coordinator dispatches to it and keeps zero-G.
#
# The movement model is the classic Source/Quake recipe re-expressed in the SURFACE frame —
# wherever the original says "the horizontal plane" we use the stood-on surface's tangent
# plane, and "up" is the surface normal:
#  - GROUNDED: accelerate (add only the shortfall of velocity along the steer direction, up
#    to move speed) then friction (multiplicative drop per tick) — crisp starts, soft stops.
#  - Launch (space, CHARGED): holding space builds the coordinator's jump_force from min
#    toward max (the HUD force bar is the charge meter); releasing launches you OUT of
#    ground mode into zero-G along the surface normal — a tap barely nudges off, a full
#    hold blasts. Walking off a ledge still FALLS (AIRBORNE: gravity along -normal, Source
#    air control, no friction) and lands or times out to zero-G.
#  - Walking off a ledge also goes AIRBORNE (you fall like a normal FPS); if nothing
#    catches you within airborne_max_time you hand off to zero-G with momentum.
#  - C disengages passively; auto ground lock (see the coordinator) can re-engage when
#    your feet point at a surface in reach.
#
# The surface SENSOR is unchanged from the proven system: probe fan + distance-weighted
# blend + anchor hysteresis feed the eased reorientation; the snap spring holds stand
# height while GROUNDED. Orientation is written kinematically; all recipes just steer
# player.linear_velocity.

enum GroundState { GROUNDED, AIRBORNE }

# --- Source movement (near-verbatim from the reference controller) ---
@export var move_speed := 8.5             # base ground speed (walking)
@export var sprint_multiplier := 1.5      # shift (stabilize_rotation) scales move_speed by this
# TIGHTNESS dials: accel = how fast you reach speed (higher = snappier starts), friction =
# how fast you shed it (higher = crisper stops, less glide), decel = the floor on friction's
# bite at low speed (higher = the last metre of a stop ends decisively instead of tapering).
@export var ground_accel := 14.0          # in units of move_speed per second
@export var ground_decel := 10.0          # friction's minimum "control" speed
@export var ground_friction := 4.5
# OVERSPEED regime: momentum above move_speed (a fast, shallow landing) is a skill reward —
# it bleeds at this fraction of the EXCESS per second instead of full Source friction
# (which halves speed every ~0.2 s). 0.35 = the excess halves every ~2 s: land at 30 with
# move_speed 12 and you carry a meaningful edge for several seconds, steerable but never
# pumpable. Below move_speed, normal Source friction applies unchanged.
@export var overspeed_friction := 0.35
@export var hop_gravity := 15.2           # pull along -normal while AIRBORNE/falling (Source ~800u/s^2)
@export var airborne_max_time := 2.0      # falling in ground mode this long, no landing -> zero-G
@export var air_cap := 0.85               # max speed the air recipe adds along the steer dir
@export var air_accel := 800.0
@export var air_move_speed := 500.0

# --- Orientation / feel (migrated unchanged from the old surface walk) ---
# Standing height of the body CENTRE off the surface. MUST be >= the collision shape's own
# rest height (capsule height/2 = 1.0 for the default capsule), or the physics contact
# holds the body where the landing gate can never pass (jumps get stuck AIRBORNE until the
# timeout dumps you to zero-G) and the snap spring endlessly fights depenetration while
# walking. 1.02 = capsule rest + 2 cm skin, so the snap owns the height cleanly.
@export var surface_walk_body_offset: float = 1.02
@export var surface_walk_pitch_limit_degrees: float = 90.0   # hard look clamp (full up/down)
# View-pitch gimbal wash-out rate: how fast a held camera offset settles onto the surface
# after the body reorients. 0 = NEVER (absolute hold — the view stays where you put it
# until the mouse moves it); higher = the view follows big transitions sooner. The gimbal
# itself is switched by pitch_gimbal_strength below.
@export var surface_walk_pitch_stabilize_recenter: float = 0.5
# How much of the body's alignment nod the gimbal cancels each frame: 1 = camera pitch
# fully decoupled from the body (your view holds where you put it until the MOUSE moves
# it), 0 = camera rigidly bolted to the body like a helmet cam. Pairs with the recenter
# rate above (how fast the held offset settles onto a NEW surface after big transitions).
@export_range(0.0, 1.0) var pitch_gimbal_strength := 1.0
# PUSH-past-the-stop release: with the look pinned at the pitch limit, dragging the mouse
# a further (accumulated) this-many degrees releases ground mode into zero-G — a
# deliberate "stare into space and keep pulling" gesture. An absolute release ANGLE false-
# fired constantly on downhill faces (aim is surface-relative, so a world-level gaze on a
# steep slope already sits near the limit). <= 0 disables the release.
@export var pitch_release_push_degrees := 12.0
# Entering ground mode auto-releases an attached grapple wire.
@export var release_grapple_on_entry := true
# THE walkable-angle gate: surfaces angled further than this from the one you stand on are
# WALLS (stop you); within it they're ground you reorient across.
@export var surface_walk_max_edge_angle_degrees: float = 80.0
# Transition speed: how eagerly the body banks onto new surface orientations (per second).
@export var surface_walk_slope_align_speed: float = 10.0

# Internal tuning (edit here if the feel needs it).
const SURFACE_WALK_SNAP_STRENGTH := 10.0
const SURFACE_WALK_MAX_SNAP_SPEED := 8.0
const SURFACE_WALK_TRANSITION_DURATION := 0.1
const SURFACE_WALK_ENTRY_SHAKE_DURATION := 0.18
const SURFACE_WALK_ENTRY_SHAKE_STRENGTH := 0.07
const SURFACE_WALK_ENTRY_SHAKE_FREQUENCY := 52.0
const SURFACE_WALK_SPAWN_PROBE_DISTANCE := 8.0
const SURFACE_WALK_LOCK_MAX_DISTANCE := 4.0
const AUTO_GROUND_LOCK_DISTANCE := 2.0    # auto-lock reach (feet ray only; see coordinator)
const SURFACE_WALK_EDGE_CHECK_EXTRA_DISTANCE := 0.35
const SURFACE_WALK_PROBE_FOOT_OFFSET := 0.28
const SURFACE_WALK_ANCHOR_SWITCH_TIME := 0.12
const SURFACE_WALK_ANCHOR_SAME_FACE_DEGREES := 15.0
const SURFACE_WALK_FOREIGN_FACE_WEIGHT := 0.35
const SURFACE_WALK_TARGET_SMOOTHING := 22.0
const SURFACE_WALK_MAX_TURN_SPEED_DEGREES := 175.0
const SURFACE_WALK_ALIGN_ACCEL := 6.5
# Downhill stick: downward probes reach an extra (speed x seconds) so surfaces CURVING
# away below stay in sensor range at speed; far hits only count when their normal differs
# from the anchored face by at least the min-curve angle (a curving continuation) — a
# PARALLEL floor further below is a drop-off you fall from, and a face past the walkable
# gate (a skate-lip's far side) is rejected entirely, so ramp lips still launch you.
const STICK_LOOKDOWN_SECONDS := 0.35
const STICK_MIN_CURVE_DEGREES := 8.0
# Tight turns at speed need the body to ROTATE as fast as the curve demands (a 3 m radius
# at 25 m/s is ~480 deg/s — far past the walking-tuned align caps). All three align limits
# scale with tangential speed above this reference so fast curves track without lag; at
# walk speeds the boost is 1 and nothing changes.
const STICK_SPEED_BOOST_REFERENCE := 8.0
# Even with airborne_max_time tuned to 0, a single-tick sensor blip must not eject to
# zero-G — the effective timeout never drops below this grace.
const AIRBORNE_MIN_GRACE := 0.15
const DETACH_MOMENTUM_CARRY := 1.35       # run speed kept (boosted) on Alt-detach
# Fall gravity is heavier than rise gravity (the classic anti-float trick): symmetric
# gravity hangs ~0.25 s of near-weightlessness at the apex, which reads as floaty/"a second
# push". Rise keeps hop_gravity; descent uses hop_gravity * this.
const FALL_GRAVITY_MULTIPLIER := 1.6

var coordinator: Node = null              # PlayerMovementController (mode owner, shared look)
var player: RigidBody3D
var camera: Camera3D
var _ray_query: PhysicsRayQueryParameters3D

var ground_state: int = GroundState.GROUNDED
var airborne_time: float = 0.0

var surface_walk_normal: Vector3 = Vector3.UP
var surface_walk_forward: Vector3 = Vector3.FORWARD
var surface_walk_anchor_point: Vector3 = Vector3.ZERO
# The anchor's own raw hit normal: the snap measures stand distance along THIS — measuring
# along the smoothed body normal launches the body when a seam swaps the anchor.
var surface_walk_anchor_normal: Vector3 = Vector3.UP
var surface_walk_pitch: float = 0.0
# Accumulated mouse drag past the pinned pitch stop (the push-past release gesture).
var pitch_release_accum: float = 0.0
# Camera-pitch offset cancelling the body's alignment nod (the gimbal); applied on camera
# writes only, washed toward 0 each frame.
var surface_walk_pitch_stabilize: float = 0.0
var surface_walk_smoothed_target: Vector3 = Vector3.UP
var surface_walk_anchor_foreign_time: float = 0.0
var surface_walk_align_rate: float = 0.0

var surface_walk_transition_active: bool = false
var surface_walk_transition_timer: float = 0.0
var surface_walk_transition_start_transform: Transform3D
var surface_walk_transition_target_transform: Transform3D
# Tangential momentum carried through entry, handed back when the slide-in completes.
var surface_walk_entry_carry: Vector3 = Vector3.ZERO

var camera_base_position: Vector3 = Vector3.ZERO
var surface_walk_shake_timer: float = 0.0
var _pre_surface_walk_material: PhysicsMaterial = null

# --- Movement flight recorder -------------------------------------------------------------
# Writes user://movement_log.txt (fresh file each launch): one line per physics tick while
# in ground mode (inputs, state, velocities, orientation) plus EVENT lines for every
# transition (ENTER/EXIT/JUMP/AIRBORNE/LAND/DETACH). Local player only — the ground tick
# never runs for remotes or the server. Turn off once the movement feel is settled.
@export var debug_movement_log := true
@export var debug_log_every_n_frames := 1

var _log_file: FileAccess = null
var _log_tick_count := 0


func setup(owner_coordinator: Node, owner_player: RigidBody3D, owner_camera: Camera3D) -> void:
	coordinator = owner_coordinator
	player = owner_player
	camera = owner_camera

	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false

	if player is CollisionObject3D:
		_ray_query.exclude = [player.get_rid()]

	if camera != null:
		camera_base_position = camera.position


func is_active() -> bool:
	return coordinator != null and coordinator.is_surface_walk_active()


# ---------------------------------------------------------------- per-tick drive


func physics_update_ground(delta: float) -> void:
	log_movement_tick()

	if surface_walk_transition_active:
		update_surface_walk_transition(delta)
		return

	update_surface_walk_mouse_look(delta)

	# Looking past the release angle exits inside the mouse-look handler.
	if not is_active():
		return

	# Space RELEASED: fire the charged launch (grounded) or let go passively (mid-fall —
	# there's nothing under your feet to push from). The charge lives on the coordinator.
	if is_action_just_released_if_exists("push"):
		if ground_state == GroundState.AIRBORNE:
			log_movement_event("DETACH (space, airborne -> passive release)")
			exit_surface_walk_mode()
		else:
			log_movement_event("DETACH (space, charged %.1f)" % coordinator.jump_force)
			detach_to_zero_g()

		coordinator.reset_jump_charge()
		return

	match ground_state:
		GroundState.GROUNDED:
			physics_grounded(delta)

		GroundState.AIRBORNE:
			physics_airborne(delta)


func physics_grounded(delta: float) -> void:
	var result := get_surface_walk_ground_result()

	if result.is_empty():
		# Walked off a ledge: FALL (stay in ground mode, gravity along the old -normal).
		# If nothing catches us the airborne timeout hands off to zero-G.
		begin_airborne()
		physics_airborne(delta)
		return

	apply_ground_sensing(result, delta)
	update_surface_walk_orientation()

	handle_source_ground_move(delta)


func physics_airborne(delta: float) -> void:
	airborne_time += delta

	# Gravity along the surface's -normal (heavier on the way down — see
	# FALL_GRAVITY_MULTIPLIER), Source air control, no friction, no snap.
	var rising := player.linear_velocity.dot(surface_walk_normal) > 0.0
	var gravity := hop_gravity if rising else hop_gravity * FALL_GRAVITY_MULTIPLIER
	player.linear_velocity += -surface_walk_normal * gravity * delta
	handle_source_air_move(delta)

	# A controlled ground-mode descent is its own landing gear: keep impact detection
	# suppressed while falling, so a fast-but-clean landing takes NO impact shake at all.
	# Genuine zero-G crashes (outside ground mode) still register normally.
	if not rising and player.has_method("suppress_launch_impact"):
		player.call("suppress_launch_impact")

	update_surface_walk_orientation()

	# Landing: falling toward the surface AND genuinely at stand height (within 5 cm) — a
	# looser gate "lands" you early, deleting fall velocity while still visibly off the
	# ground and handing the last stretch to the slow snap spring, which reads as hovering
	# mid-jump. Fast falls that skip the window are caught by the physics contact (which
	# zeroes approach velocity at the floor), landing them the next tick.
	if player.linear_velocity.dot(surface_walk_normal) <= 0.01:
		var result := get_surface_walk_ground_result()

		if not result.is_empty():
			var hit_distance := (player.global_position - (result["position"] as Vector3)).dot(surface_walk_normal)

			if hit_distance <= surface_walk_body_offset + 0.1:
				log_movement_event("LAND  dist=%.3f  air_t=%.2f  v=%s" % [
					hit_distance, airborne_time, _fmt_v(player.linear_velocity)])
				apply_ground_sensing(result, delta)
				ground_state = GroundState.GROUNDED

				if player.has_method("suppress_launch_impact"):
					player.call("suppress_launch_impact")

				return

	# Nothing caught us: float off into zero-G with momentum (walking off into the void).
	# The grace floor means even airborne_max_time = 0 tolerates single-tick sensor blips.
	if airborne_time > maxf(airborne_max_time, AIRBORNE_MIN_GRACE):
		log_movement_event("AIRBORNE TIMEOUT -> zero-G")
		exit_surface_walk_mode()


func begin_airborne() -> void:
	if ground_state != GroundState.AIRBORNE:
		log_movement_event("AIRBORNE begins  v=%s" % _fmt_v(player.linear_velocity))

	ground_state = GroundState.AIRBORNE
	airborne_time = 0.0


# Feed one sensor result through the smoothing/align/anchor pipeline (shared by grounded
# ticks and the landing frame).
func apply_ground_sensing(result: Dictionary, delta: float) -> void:
	var raw_normal := (result["normal"] as Vector3).normalized()
	var target_normal := (result.get("target_normal", raw_normal) as Vector3).normalized()

	# nlerp, NOT slerp: near-identical vectors degenerate slerp's axis into float noise.
	var smooth_weight := clampf(1.0 - exp(-SURFACE_WALK_TARGET_SMOOTHING * delta), 0.0, 1.0)
	var smoothed := surface_walk_smoothed_target.lerp(target_normal, smooth_weight)
	surface_walk_smoothed_target = smoothed.normalized() if smoothed.length() > 0.01 else target_normal
	align_surface_walk_normal_toward(surface_walk_smoothed_target, delta)

	# Anchor with hysteresis: a DIFFERENT face only takes the anchor after persisting as
	# the dominant support; per-frame ray alternation on an edge never wins.
	if rad_to_deg(raw_normal.angle_to(surface_walk_anchor_normal)) <= SURFACE_WALK_ANCHOR_SAME_FACE_DEGREES:
		surface_walk_anchor_foreign_time = 0.0
		surface_walk_anchor_point = result["position"]
		surface_walk_anchor_normal = raw_normal
	else:
		surface_walk_anchor_foreign_time += delta

		if result.has("same_face_normal") and surface_walk_anchor_foreign_time < SURFACE_WALK_ANCHOR_SWITCH_TIME:
			surface_walk_anchor_point = result["same_face_position"]
			surface_walk_anchor_normal = (result["same_face_normal"] as Vector3).normalized()
		else:
			surface_walk_anchor_foreign_time = 0.0
			surface_walk_anchor_point = result["position"]
			surface_walk_anchor_normal = raw_normal


# ---------------------------------------------------------------- Source recipes


func get_move_speed() -> float:
	return move_speed * (sprint_multiplier if is_sprinting() else 1.0)


func is_sprinting() -> bool:
	return is_action_pressed_if_exists("stabilize_rotation")


# Steer direction in the stood surface's tangent plane (the Source "wish_dir").
func get_wish_dir() -> Vector3:
	var input_vector := get_surface_walk_input_vector()

	if input_vector.length() < 0.01:
		return Vector3.ZERO

	var forward := (-player.global_transform.basis.z).slide(surface_walk_normal)
	var right := player.global_transform.basis.x.slide(surface_walk_normal)

	if forward.length() < 0.01:
		forward = surface_walk_forward

	if right.length() < 0.01:
		right = forward.cross(surface_walk_normal)

	var wish := right.normalized() * input_vector.x + forward.normalized() * input_vector.y
	return wish.normalized() if wish.length() > 0.01 else Vector3.ZERO


# Classic Source ground move: accelerate along wish_dir up to move speed, then friction —
# applied to the TANGENTIAL velocity only; the snap spring owns the normal axis.
func handle_source_ground_move(delta: float) -> void:
	var wish_dir := get_wish_dir()
	var target_speed := get_move_speed()
	# The overspeed (landing-carry) regime starts above SPRINT speed, not the current
	# target — releasing shift settles sprint surplus with crisp normal friction instead
	# of the ultra-slow landing bleed.
	var top_ground_speed := move_speed * sprint_multiplier
	var tangent := player.linear_velocity.slide(surface_walk_anchor_normal)

	if wish_dir != Vector3.ZERO:
		var cur_speed_in_wish_dir := tangent.dot(wish_dir)
		var add_speed_till_cap := target_speed - cur_speed_in_wish_dir

		if add_speed_till_cap > 0.0:
			var accel_speed := minf(ground_accel * delta * target_speed, add_speed_till_cap)
			var speed_before := tangent.length()
			tangent += wish_dir * accel_speed

			# Overspeed steering guard: past the target, input REDIRECTS the carried
			# momentum but can never grow it (else wiggle-strafing pumps speed forever).
			var speed_limit := maxf(speed_before, target_speed)

			if tangent.length() > speed_limit:
				tangent = tangent.normalized() * speed_limit

	var speed := tangent.length()

	if speed > top_ground_speed + 0.05:
		# Overspeed: only the excess bleeds, gently (see overspeed_friction) — carried
		# landing momentum is a lasting reward, not food for full Source friction. The
		# small constant floor guarantees the decay actually reaches sprint speed.
		var excess := speed - top_ground_speed
		var drop := maxf(excess * overspeed_friction, 0.75) * delta
		tangent *= maxf(speed - drop, 0.0) / speed
	elif speed > 0.0:
		# Normal Source friction (multiplicative drop per tick).
		var control := maxf(speed, ground_decel)
		var drop := control * ground_friction * delta
		tangent *= maxf(speed - drop, 0.0) / speed

	# Wall: a face ahead steeper than the walkable angle blocks — strip into-wall motion.
	var wall_normal := get_surface_walk_wall_block_normal()

	if wall_normal != Vector3.ZERO:
		var wall_tangent := wall_normal.slide(surface_walk_anchor_normal)

		if wall_tangent.length() > 0.001:
			tangent = strip_into_wall_component(tangent, wall_tangent.normalized())

	player.linear_velocity = tangent + get_surface_walk_snap_velocity()
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false


# The fan-favourite Source air recipe: steering can ALWAYS add up to air_cap along the wish
# direction regardless of current speed — air-strafing, bhop, surf all fall out of this.
func handle_source_air_move(delta: float) -> void:
	var wish_dir := get_wish_dir()

	if wish_dir == Vector3.ZERO:
		return

	var cur_speed_in_wish_dir := player.linear_velocity.dot(wish_dir)
	var capped_speed := minf((air_move_speed * wish_dir).length(), air_cap)
	var add_speed_till_cap := capped_speed - cur_speed_in_wish_dir

	if add_speed_till_cap > 0.0:
		var accel_speed := minf(air_accel * air_move_speed * delta, add_speed_till_cap)
		player.linear_velocity += accel_speed * wish_dir

	player.angular_velocity = Vector3.ZERO


# ---------------------------------------------------------------- entry / exit


func try_enter_surface_walk_mode() -> void:
	var result := get_ground_lock_probe()

	if result.is_empty():
		print("Ground lock failed: no surface within ", SURFACE_WALK_LOCK_MAX_DISTANCE, " m.")
		return

	var surface_normal: Vector3 = result.get("normal", Vector3.ZERO)

	if surface_normal.length() < 0.01:
		return

	enter_surface_walk_mode(result.get("position", player.global_position), surface_normal.normalized())


func enter_spawn_surface_walk() -> bool:
	var surface := find_spawn_surface(SURFACE_WALK_SPAWN_PROBE_DISTANCE)

	if surface.is_empty():
		return false

	enter_surface_walk_mode(surface["position"], (surface["normal"] as Vector3).normalized(), true)
	return true


func enter_surface_walk_mode(hit_position: Vector3, surface_normal: Vector3, instant: bool = false) -> void:
	# Capture the actual view direction BEFORE anything realigns, so the entry can keep the
	# player looking at exactly what they were looking at.
	var entry_view_dir: Vector3 = -coordinator.get_control_look_basis().z

	coordinator.begin_surface_walk_mode()

	# Entering at speed (auto-lock mid-flight, C-lock on approach): the mode absorbs the
	# arrival — no impact shake from the touchdown contact.
	if player.has_method("suppress_launch_impact"):
		player.call("suppress_launch_impact")

	# An attached grapple wire makes no sense while standing — let it go on entry.
	if release_grapple_on_entry:
		var grapple = player.get("grapple_controller")

		if grapple != null and grapple.get("attached"):
			grapple.release()

	# Surface-walk drives velocity directly; contact friction would fight it.
	_pre_surface_walk_material = player.physics_material_override
	var walk_material := PhysicsMaterial.new()
	walk_material.friction = 0.0
	player.physics_material_override = walk_material

	surface_walk_normal = surface_normal.normalized()
	surface_walk_anchor_point = hit_position
	surface_walk_anchor_normal = surface_walk_normal
	surface_walk_smoothed_target = surface_walk_normal
	surface_walk_anchor_foreign_time = 0.0
	surface_walk_align_rate = 0.0
	ground_state = GroundState.GROUNDED
	airborne_time = 0.0

	var look_forward := (-player.global_transform.basis.z).normalized()
	var projected_forward := look_forward.slide(surface_walk_normal)

	if projected_forward.length() < 0.01:
		projected_forward = player.global_transform.basis.y.slide(surface_walk_normal)

	if projected_forward.length() < 0.01:
		projected_forward = get_fallback_surface_forward(surface_walk_normal)

	surface_walk_forward = projected_forward.normalized()

	# Preserve the ENTRY view pitch: whatever you were looking at when ground mode engaged
	# stays on screen — the aim seeds from the view's angle to the new surface plane
	# instead of snapping to the horizon (clamped just inside the hard stop).
	var seed_pitch := asin(clampf(entry_view_dir.dot(surface_walk_normal), -1.0, 1.0))
	var seed_cap := deg_to_rad(surface_walk_pitch_limit_degrees - 2.0)
	surface_walk_pitch = clampf(seed_pitch, -seed_cap, seed_cap)
	surface_walk_pitch_stabilize = 0.0
	pitch_release_accum = 0.0
	coordinator.reset_recoil()

	var target_position := hit_position + surface_walk_normal * surface_walk_body_offset
	var target_basis := make_surface_walk_basis(surface_walk_forward, surface_walk_normal)
	var target_transform := Transform3D(target_basis, target_position)

	# Keep the flight's momentum along the surface (spawns enter stationary). Velocity stays
	# LIVE through the whole entry — the transition eases rotation and closes the stand
	# height, so entering at speed is a continuous glide-in, never stop-then-pop.
	surface_walk_entry_carry = Vector3.ZERO if instant else player.linear_velocity.slide(surface_walk_normal)

	player.linear_velocity = surface_walk_entry_carry
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false

	if camera != null:
		camera.rotation = Vector3(get_surface_walk_applied_pitch(), 0.0, 0.0)

	log_movement_event("ENTER mode  instant=%s  normal=%s  carry=%s" % [
		instant, _fmt_v(surface_walk_normal), _fmt_v(surface_walk_entry_carry)])

	if instant:
		surface_walk_transition_active = false
		player.global_transform = target_transform
		player.reset_physics_interpolation()
		print("Spawned in surface-walk mode.")
		return

	start_surface_walk_transition(target_transform)
	surface_walk_shake_timer = SURFACE_WALK_ENTRY_SHAKE_DURATION
	print("Entered surface-walk mode.")


func exit_surface_walk_mode() -> void:
	if not is_active():
		return

	log_movement_event("EXIT mode  v=%s" % _fmt_v(player.linear_velocity))
	surface_walk_transition_active = false
	surface_walk_shake_timer = 0.0
	surface_walk_align_rate = 0.0
	surface_walk_pitch_stabilize = 0.0
	ground_state = GroundState.GROUNDED

	coordinator.fold_view_into_body()
	player.physics_material_override = _pre_surface_walk_material
	coordinator.end_surface_walk_mode()

	if camera != null:
		camera.position = camera_base_position

	print("Exited surface-walk mode.")


# The charged launch OUT of ground mode into zero-G (space release); force = the
# coordinator's charged jump_force at the moment of release.
func detach_to_zero_g() -> void:
	var launch_direction := surface_walk_normal.normalized()
	var carried := player.linear_velocity.slide(launch_direction) * DETACH_MOMENTUM_CARRY
	exit_surface_walk_mode()

	player.linear_velocity = carried
	player.sleeping = false
	player.apply_central_impulse(launch_direction * coordinator.jump_force)

	if player.has_method("suppress_launch_impact"):
		player.call("suppress_launch_impact")


# ---------------------------------------------------------------- transition / shake


func start_surface_walk_transition(target_transform: Transform3D) -> void:
	surface_walk_transition_active = true
	surface_walk_transition_timer = 0.0
	surface_walk_transition_start_transform = player.global_transform
	surface_walk_transition_target_transform = target_transform

	if SURFACE_WALK_TRANSITION_DURATION <= 0.0:
		player.global_transform = surface_walk_transition_target_transform
		surface_walk_transition_active = false
		player.linear_velocity = surface_walk_entry_carry


# Entry transition: ROTATION eases onto the surface while momentum keeps flowing. (The old
# version zeroed velocity and lerped the whole transform — a dead stop for 0.14 s, then the
# carried momentum popping back in one lump. Jarring.) Tangential velocity runs
# uninterrupted from the first frame; the stand-height gap closes as a velocity along the
# anchor normal over the remaining transition time.
func update_surface_walk_transition(delta: float) -> void:
	player.angular_velocity = Vector3.ZERO
	player.sleeping = false

	# The glide-in may brush the surface at speed — that contact is the landing, not a hit.
	if player.has_method("suppress_launch_impact"):
		player.call("suppress_launch_impact")

	surface_walk_transition_timer += delta

	var raw_t := clampf(surface_walk_transition_timer / maxf(SURFACE_WALK_TRANSITION_DURATION, 0.001), 0.0, 1.0)
	var smooth_t := raw_t * raw_t * (3.0 - 2.0 * raw_t)

	var new_basis := surface_walk_transition_start_transform.basis.slerp(
		surface_walk_transition_target_transform.basis, smooth_t
	).orthonormalized()
	player.global_transform.basis = new_basis

	# Close the remaining stand-height gap over the time left, riding on top of the carry.
	var stand_error := surface_walk_body_offset - surface_walk_anchor_normal.dot(
		player.global_position - surface_walk_anchor_point
	)
	var remaining := maxf(SURFACE_WALK_TRANSITION_DURATION - surface_walk_transition_timer, delta)
	var approach := clampf(stand_error / remaining, -40.0, 40.0)
	player.linear_velocity = surface_walk_entry_carry + surface_walk_anchor_normal * approach

	if raw_t >= 1.0:
		player.global_transform.basis = surface_walk_transition_target_transform.basis
		surface_walk_transition_active = false
		player.linear_velocity = surface_walk_entry_carry


func update_surface_walk_entry_shake(delta: float) -> void:
	if camera == null or surface_walk_shake_timer <= 0.0:
		return

	surface_walk_shake_timer -= delta

	var remaining_ratio := clampf(surface_walk_shake_timer / maxf(SURFACE_WALK_ENTRY_SHAKE_DURATION, 0.001), 0.0, 1.0)
	var time := Time.get_ticks_msec() / 1000.0
	var shake_amount := SURFACE_WALK_ENTRY_SHAKE_STRENGTH * remaining_ratio

	var x_offset := sin(time * SURFACE_WALK_ENTRY_SHAKE_FREQUENCY) * shake_amount
	var y_offset := cos(time * SURFACE_WALK_ENTRY_SHAKE_FREQUENCY * 1.37) * shake_amount * 0.65

	camera.position = camera_base_position + Vector3(x_offset, y_offset, 0.0)

	if surface_walk_shake_timer <= 0.0:
		camera.position = camera_base_position


# ---------------------------------------------------------------- look


func update_surface_walk_mouse_look(delta: float) -> void:
	var sens: float = coordinator.get_mouse_sensitivity()
	var yaw_delta: float = -coordinator.mouse_motion.x * sens
	var pitch_delta: float = -coordinator.mouse_motion.y * sens

	if absf(yaw_delta) > 0.0000001:
		surface_walk_forward = surface_walk_forward.rotated(surface_walk_normal, yaw_delta).normalized()

	surface_walk_pitch += pitch_delta

	var pitch_limit := deg_to_rad(surface_walk_pitch_limit_degrees)
	# How far this frame's look tried to go PAST the hard stop (0 when inside the range).
	var stop_overshoot := 0.0

	if surface_walk_pitch > pitch_limit:
		stop_overshoot = surface_walk_pitch - pitch_limit
	elif surface_walk_pitch < -pitch_limit:
		stop_overshoot = pitch_limit + surface_walk_pitch   # negative side

	surface_walk_pitch = clampf(surface_walk_pitch, -pitch_limit, pitch_limit)

	# Push-past-the-stop release: keep dragging against the pinned stop and the accumulated
	# pull lets ground mode go — the exit fold carries the view, so you peel off into
	# zero-G still looking exactly where you were looking. Easing off decays the pull.
	if pitch_release_push_degrees > 0.0:
		if absf(stop_overshoot) > 0.0:
			pitch_release_accum += absf(stop_overshoot)

			if pitch_release_accum >= deg_to_rad(pitch_release_push_degrees):
				log_movement_event("PITCH RELEASE (pushed %.1f deg past the stop)" % rad_to_deg(pitch_release_accum))
				pitch_release_accum = 0.0
				exit_surface_walk_mode()
				return
		else:
			pitch_release_accum = maxf(pitch_release_accum - deg_to_rad(45.0) * delta, 0.0)

	# Wash the gimbal offset toward 0 (sustained reorientation still settles the view) and
	# clamp so aim + offset never exceed the pitch limit.
	if pitch_gimbal_strength <= 0.0:
		surface_walk_pitch_stabilize = 0.0
	else:
		# recenter = 0 means the held offset NEVER washes out (absolute hold); higher
		# values settle the view onto NEW surfaces after big deliberate transitions.
		if surface_walk_pitch_stabilize_recenter > 0.0:
			surface_walk_pitch_stabilize *= exp(-surface_walk_pitch_stabilize_recenter * delta)

		surface_walk_pitch_stabilize = clampf(
			surface_walk_pitch_stabilize,
			-pitch_limit - surface_walk_pitch,
			pitch_limit - surface_walk_pitch
		)

	if camera != null:
		camera.rotation = Vector3(get_surface_walk_applied_pitch(), 0.0, 0.0)


func get_surface_walk_applied_pitch() -> float:
	var pitch_limit := deg_to_rad(surface_walk_pitch_limit_degrees)
	return clampf(surface_walk_pitch + surface_walk_pitch_stabilize, -pitch_limit, pitch_limit)


func update_surface_walk_orientation() -> void:
	player.global_transform = Transform3D(
		make_surface_walk_basis(surface_walk_forward, surface_walk_normal),
		player.global_position
	)
	player.angular_velocity = Vector3.ZERO


# Eases the walked-surface normal toward the target with ease-in ramp, exponential ease-out
# and a hard rate cap; forward is parallel-transported so heading survives big swings.
func align_surface_walk_normal_toward(target_normal: Vector3, delta: float) -> void:
	if target_normal.length() < 0.01:
		return

	target_normal = target_normal.normalized()
	var full_angle := surface_walk_normal.angle_to(target_normal)

	if full_angle < 0.0001:
		return

	# Speed boost (see STICK_SPEED_BOOST_REFERENCE): fast runs raise every align limit so
	# tight curves can be tracked; 1.0 at walk speeds and when running headless tests.
	var speed_boost := 1.0

	if player != null:
		speed_boost = maxf(1.0, player.linear_velocity.slide(surface_walk_normal).length() / STICK_SPEED_BOOST_REFERENCE)

	var exp_weight := 1.0 - exp(-surface_walk_slope_align_speed * speed_boost * delta)
	var max_step := deg_to_rad(SURFACE_WALK_MAX_TURN_SPEED_DEGREES) * speed_boost * delta
	var desired_step := minf(full_angle * exp_weight, max_step)
	surface_walk_align_rate = lerpf(
		surface_walk_align_rate,
		desired_step / delta,
		clampf(1.0 - exp(-SURFACE_WALK_ALIGN_ACCEL * speed_boost * delta), 0.0, 1.0)
	)
	var step_angle := minf(desired_step, surface_walk_align_rate * delta)
	var t := clampf(step_angle / full_angle, 0.0, 1.0)

	var old_forward := surface_walk_forward
	var old_up := surface_walk_normal

	var new_normal := surface_walk_normal.slerp(target_normal, t).normalized()
	surface_walk_forward = Quaternion(surface_walk_normal, new_normal) * surface_walk_forward
	surface_walk_normal = new_normal

	var projected_forward := surface_walk_forward.slide(surface_walk_normal)

	if projected_forward.length() < 0.01:
		projected_forward = get_fallback_surface_forward(surface_walk_normal)

	surface_walk_forward = projected_forward.normalized()

	if pitch_gimbal_strength > 0.0:
		surface_walk_pitch_stabilize -= (surface_walk_forward - old_forward).dot(old_up) * pitch_gimbal_strength


# ---------------------------------------------------------------- sensor (unchanged)


# Ground probe: feeler along the walk direction hands over an approaching seam; otherwise
# the down ray + foot rays + crest sweeps blend a CONTINUOUS orientation target while the
# nearest hit stays the physical anchor. Returns {position, normal, target_normal} or {}.
func get_surface_walk_ground_result() -> Dictionary:
	if player == null:
		return {}

	var origin := player.global_position
	var probe_length := surface_walk_body_offset + SURFACE_WALK_EDGE_CHECK_EXTRA_DISTANCE + 0.08
	var move_dir := get_surface_walk_probe_move_direction()
	# Speed-scaled reach for the DOWNWARD probes only (the feeler keeps base length so
	# walls ahead aren't handed over early). See STICK_LOOKDOWN_SECONDS.
	var tangential_speed := player.linear_velocity.slide(surface_walk_anchor_normal).length()
	var down_length := probe_length + tangential_speed * STICK_LOOKDOWN_SECONDS

	if move_dir != Vector3.ZERO:
		var feeler := probe_surface_walk_ray(origin, move_dir, probe_length)

		if not feeler.is_empty():
			feeler["target_normal"] = feeler["normal"]
			return feeler

	var axis_a := move_dir
	var axis_b := Vector3.ZERO

	if axis_a == Vector3.ZERO:
		axis_a = (-player.global_transform.basis.z).slide(surface_walk_normal)

	if axis_a.length() > 0.01:
		axis_a = axis_a.normalized()
		axis_b = axis_a.cross(surface_walk_normal)

		if axis_b.length() > 0.01:
			axis_b = axis_b.normalized()

	var lifted := origin + surface_walk_normal * 0.08
	var probes: Array = [[lifted, -surface_walk_normal]]

	for axis in [axis_a, axis_b]:
		if axis == Vector3.ZERO:
			continue

		probes.append([lifted + axis * SURFACE_WALK_PROBE_FOOT_OFFSET, -surface_walk_normal])
		probes.append([lifted - axis * SURFACE_WALK_PROBE_FOOT_OFFSET, -surface_walk_normal])

	if move_dir != Vector3.ZERO:
		var wrap_right := move_dir.cross(surface_walk_normal)

		if wrap_right.length() > 0.01:
			wrap_right = wrap_right.normalized()

			for sweep_degrees: float in [30.0, 60.0]:
				probes.append([lifted, (-surface_walk_normal).rotated(wrap_right, deg_to_rad(sweep_degrees))])

	# Sticky blending: foreign faces are down-weighted, further so at standstill.
	var speed_ratio := clampf(
		player.linear_velocity.slide(surface_walk_anchor_normal).length() / maxf(get_move_speed(), 0.01),
		0.0,
		1.0
	)
	var foreign_weight := SURFACE_WALK_FOREIGN_FACE_WEIGHT * lerpf(0.1, 1.0, speed_ratio)
	var same_face_cos := cos(deg_to_rad(SURFACE_WALK_ANCHOR_SAME_FACE_DEGREES))

	# Thin-ledge stability: while the CENTRE down-probe still stands squarely on the
	# anchored face, faces caught only by the outer foot/sweep probes (a narrow sill's side
	# bevels — the probes are wider than the sill) barely steer orientation, so you cross
	# thin beveled ledges upright instead of rolling around their corners and getting
	# bunted off. On a true crest the centre probe LEAVES the old face, suppression lifts,
	# and the blend wraps you over it exactly as before.
	var centre_hit := probe_surface_walk_ray(lifted, -surface_walk_normal, probe_length)

	if not centre_hit.is_empty():
		var centre_normal := (centre_hit["normal"] as Vector3).normalized()

		if centre_normal.dot(surface_walk_anchor_normal) >= same_face_cos:
			foreign_weight *= 0.1

	var best: Dictionary = {}
	var best_distance := INF
	var same_face_best: Dictionary = {}
	var same_face_distance := INF
	var blended_normal := Vector3.ZERO

	for probe in probes:
		var result := probe_surface_walk_ray(probe[0], probe[1], down_length)

		if result.is_empty():
			continue

		var hit_normal := (result["normal"] as Vector3).normalized()
		var hit_distance := origin.distance_to(result["position"])
		var on_anchor_face := hit_normal.dot(surface_walk_anchor_normal) >= same_face_cos

		# Beyond base reach, only a CURVING continuation sticks — a near-parallel surface
		# far below is a drop-off (jump-down ledge), not a bevel to follow.
		if hit_distance > probe_length \
				and hit_normal.angle_to(surface_walk_anchor_normal) < deg_to_rad(STICK_MIN_CURVE_DEGREES):
			continue

		var weight := 1.0 - clampf(hit_distance / down_length, 0.0, 1.0)
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

	if not same_face_best.is_empty():
		best["same_face_position"] = same_face_best["position"]
		best["same_face_normal"] = same_face_best["normal"]

	return best


# One validated probe ray: rejects degenerate normals and faces angled past the walkable
# gate (measured vs the ANCHOR normal, never the eased display normal).
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


# A face ahead too steep to walk (past the walkable gate) is a WALL — return its normal.
func get_surface_walk_wall_block_normal() -> Vector3:
	var move_dir := get_surface_walk_probe_move_direction()

	if move_dir == Vector3.ZERO:
		return Vector3.ZERO

	var origin := player.global_position + surface_walk_normal * 0.08
	var probe_length := surface_walk_body_offset + SURFACE_WALK_EDGE_CHECK_EXTRA_DISTANCE + 0.08
	var result := raycast_from_player(origin, origin + move_dir * probe_length)

	if result.is_empty():
		return Vector3.ZERO

	var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

	if hit_normal.length() < 0.01:
		return Vector3.ZERO

	hit_normal = hit_normal.normalized()

	if rad_to_deg(surface_walk_anchor_normal.angle_to(hit_normal)) <= surface_walk_max_edge_angle_degrees:
		return Vector3.ZERO

	return hit_normal


# Removes the part of `velocity` heading INTO a wall (wall_tangent = outward normal
# projected on the stand plane; "into" is the negative-dot component).
static func strip_into_wall_component(velocity: Vector3, wall_tangent: Vector3) -> Vector3:
	var into := velocity.dot(wall_tangent)

	if into < 0.0:
		return velocity - wall_tangent * into

	return velocity


func get_surface_walk_snap_velocity() -> Vector3:
	var distance_from_plane := surface_walk_anchor_normal.dot(player.global_position - surface_walk_anchor_point)
	var offset_error := surface_walk_body_offset - distance_from_plane

	# The PULL-toward-surface cap scales with run speed so fast crossings stay glued to
	# surfaces curving away below; the push-out side keeps the gentle walking cap. At walk
	# speeds both reduce to the old behaviour.
	var pull_cap := maxf(
		SURFACE_WALK_MAX_SNAP_SPEED,
		player.linear_velocity.slide(surface_walk_anchor_normal).length() * 1.5
	)
	var snap_speed := clampf(
		offset_error * SURFACE_WALK_SNAP_STRENGTH,
		-pull_cap,
		SURFACE_WALK_MAX_SNAP_SPEED
	)

	# Fade in with alignment so a freshly acquired seam face can't shove the body sideways.
	snap_speed *= clampf(surface_walk_normal.dot(surface_walk_anchor_normal), 0.0, 1.0)
	return surface_walk_anchor_normal * snap_speed


# ---------------------------------------------------------------- lock / spawn probes


# Nearest lockable surface around the player, feet first. `max_normal_angle_degrees` > 0
# filters by the body's up; spawns pass no limit. Returns {position, normal} or {}.
func find_spawn_surface(max_distance: float, max_normal_angle_degrees: float = -1.0) -> Dictionary:
	if player == null:
		return {}

	var basis := player.global_transform.basis
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

		if i == 0:
			distance -= 0.01   # feet bias wins near-ties

		if distance < best_distance:
			best_distance = distance
			best = {"position": hit_position, "normal": normal}

	return best


func get_ground_lock_probe() -> Dictionary:
	if player == null:
		return {}

	var origin := player.global_position
	var direction := -player.global_transform.basis.y

	if direction.length() >= 0.01:
		direction = direction.normalized()
		var end := origin + direction * SURFACE_WALK_LOCK_MAX_DISTANCE
		var result := raycast_from_player(origin, end)

		if not result.is_empty():
			var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

			if hit_normal.length() >= 0.01:
				return {
					"position": result.get("position", end),
					"normal": hit_normal.normalized(),
				}

	var nearest := find_spawn_surface(SURFACE_WALK_LOCK_MAX_DISTANCE)

	if nearest.is_empty():
		return {}

	return {"position": nearest["position"], "normal": nearest["normal"]}


# AUTO ground lock probe: strictly the FEET ray, strictly short reach — the surface only
# counts if your feet genuinely point at it within AUTO_GROUND_LOCK_DISTANCE. No nearest-
# surface fallback (that would lock you to walls drifting past your side).
func get_auto_ground_probe() -> Dictionary:
	if player == null:
		return {}

	var direction := -player.global_transform.basis.y

	if direction.length() < 0.01:
		return {}

	var origin := player.global_position
	var result := raycast_from_player(origin, origin + direction.normalized() * AUTO_GROUND_LOCK_DISTANCE)

	if result.is_empty():
		return {}

	var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)

	if hit_normal.length() < 0.01:
		return {}

	return {"position": result.get("position", origin), "normal": hit_normal.normalized()}


# ---------------------------------------------------------------- small helpers


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


func get_surface_walk_input_vector() -> Vector2:
	var input_vector := Vector2.ZERO
	input_vector.x += get_action_strength_if_exists("walk_right")
	input_vector.x -= get_action_strength_if_exists("walk_left")
	input_vector.y += get_action_strength_if_exists("booster_forward")
	input_vector.y -= get_action_strength_if_exists("booster_backward")

	if input_vector.length() > 1.0:
		input_vector = input_vector.normalized()

	return input_vector


func raycast_from_player(origin: Vector3, end: Vector3) -> Dictionary:
	_ray_query.from = origin
	_ray_query.to = end
	return player.get_world_3d().direct_space_state.intersect_ray(_ray_query)


# ---------------------------------------------------------------- flight recorder


func _log_open() -> void:
	if _log_file != null:
		return

	_log_file = FileAccess.open("user://movement_log.txt", FileAccess.WRITE)

	if _log_file == null:
		return

	print("Movement log -> ", ProjectSettings.globalize_path("user://movement_log.txt"))
	_log_file.store_line(
		"# time | frame | state airT | in=(fwd,strafe) J=just/held D=detach | " +
		"|v| vTan vNorm | ang(up,anchor)deg standDist | pos | up"
	)
	_log_file.flush()


func log_movement_event(tag: String) -> void:
	if not debug_movement_log:
		return

	_log_open()

	if _log_file == null:
		return

	_log_file.store_line("%8.3f  ===== %s" % [Time.get_ticks_msec() / 1000.0, tag])
	_log_file.flush()


func log_movement_tick() -> void:
	if not debug_movement_log or player == null:
		return

	_log_tick_count += 1

	if debug_log_every_n_frames > 1 and _log_tick_count % debug_log_every_n_frames != 0:
		return

	_log_open()

	if _log_file == null:
		return

	var input_vector := get_surface_walk_input_vector()
	var velocity := player.linear_velocity
	var tangent_speed := velocity.slide(surface_walk_anchor_normal).length()
	var normal_speed := velocity.dot(surface_walk_normal)
	var stand_distance := surface_walk_anchor_normal.dot(player.global_position - surface_walk_anchor_point)
	var state_name := "TRANSIT" if surface_walk_transition_active \
		else ("GROUND" if ground_state == GroundState.GROUNDED else "AIR")

	_log_file.store_line(
		"%8.3f  f%-7d %-7s a=%.2f  in=(%+.1f,%+.1f) J=%d/%d chg=%4.1f  |v|=%6.2f t=%6.2f n=%+6.2f  ang=%5.1f d=%5.2f  p=%s  up=%s" % [
			Time.get_ticks_msec() / 1000.0,
			Engine.get_physics_frames(),
			state_name,
			airborne_time,
			input_vector.y, input_vector.x,
			int(is_action_just_pressed_if_exists("push")), int(is_action_pressed_if_exists("push")),
			coordinator.jump_force if coordinator != null else 0.0,
			velocity.length(), tangent_speed, normal_speed,
			rad_to_deg(surface_walk_normal.angle_to(surface_walk_anchor_normal)),
			stand_distance,
			_fmt_v(player.global_position),
			_fmt_v(surface_walk_normal),
		]
	)

	# Flush periodically so a crash or force-quit still leaves a usable log.
	if _log_tick_count % 30 == 0:
		_log_file.flush()


static func _fmt_v(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]


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
