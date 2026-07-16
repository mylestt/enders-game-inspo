class_name GrappleController
extends Node

# Purchasable grapple wire (shop: SPECIAL SUIT SYSTEMS). Fire (grapple_fire, E) casts a wire
# along the camera aim up to max_range; on hitting STATIC world geometry it attaches, and
# the wire's length locks to the attach distance — a fixed-length tether, not a spring.
#
# Physics: inside the radius you float freely (slack). Moving past it, the taut wire kills
# only the OUTWARD radial velocity and keeps the tangential part — at speed that whips the
# player into a circular swing around the pivot (release, grapple_release/Q, to slingshot
# off with everything the swing gave you). Holding grapple_reel (MMB) spools the wire in:
# floating, it tows you to the anchor; mid-swing it tightens the orbit and speeds the turn.
#
# Wrapping: the wire is a real line. When it touches geometry mid-swing it BENDS there — a
# new pivot chained after the anchor — and the active radius shrinks to the remaining
# length (tetherball spiral). Bend points STICK where they first touch (deliberate no-slip,
# per design) and unwrap in reverse: when the rope geometrically straightens back past a
# bend (and the previous pivot is in clear line of sight), the bend releases.
#
# Only the LOCAL player simulates; remote copies just mirror the pivot chain for the rope
# visual via NetworkManager's lobby-scoped grapple-event relay (attach/bend/unwrap/release).

# Relay event kinds (NetworkManager.broadcast_grapple_event / player.apply_grapple_event).
const EVENT_ATTACH := 0
const EVENT_BEND := 1
const EVENT_UNWRAP := 2
const EVENT_RELEASE := 3

# Hard bounds independent of the tunable wrap_min_pivot_separation (which may be set to 0
# for maximally tight wraps): a floor that still rejects true duplicate bend points, and a
# chain cap. Both bound the pivots array AND the reliable bend-event RPC traffic — sliding
# along curved geometry with no separation floor could otherwise add a pivot every frame,
# forever.
#
# MAX_PIVOTS is the ceiling on the pivot chain. It has to be generous: a full wrap around a
# body plants one bend every few degrees (denser the closer wrap_surface_offset hugs the
# surface — a small offset roughly doubles the count), so a low cap silently stops the wrap
# mid-orbit and the live segment then chords STRAIGHT THROUGH the body ("can't wrap more
# than once"). 512 covers many full loops even with tight, surface-hugging tuning; it still
# bounds memory (~a few KB) and a forged-event flood. If you routinely loop huge objects and
# still hit it, raise wrap_surface_offset (fewer, wider-spaced bends) rather than lowering it.
const WRAP_PIVOT_EPSILON := 0.005
const MAX_PIVOTS := 512

@export var max_range: float = 30.0
# OFF: the wire's length locks to the attach distance — taut almost immediately, snappy.
# ON: the full max_range pays out on attach, leaving slack until you drift out to it.
@export var shoot_out_full_length: bool = false
# Spool-in rate (metres/second) while grapple_reel is held; also the top towing speed.
@export var reel_speed: float = 7.0
# The wire never reels shorter than this (keeps the pivot math sane at point-blank).
@export var min_length: float = 1.2
# How softly the wire catches when it snaps taut: the seconds over which the outward
# velocity is absorbed. This does NOT change how HARD the catch is — the velocity removed is
# always your full outward-radial speed (∝ how badly you entered, which is the skill signal).
# It only sets over how many frames that removal renders. ~0.01 kills it in one 60 Hz tick,
# which reads as a teleport-stutter rather than a slam; ~0.03 spreads a deserved hard catch
# over 3-4 frames so it reads as weight you can learn from. 0 = one-frame rigid snap.
@export var taut_give: float = 0.03
# Positional leash back onto the radius (inward m/s per metre of overshoot, and its cap).
# This is a STABILISER, not the catch — the outward-velocity absorption above is what stops
# you. Kept gentle so that when a wrap plants a new pivot and the radius steps down, you're
# eased back onto it instead of yanked (a hard yank there punishes a CLEAN wrap, the opposite
# of a skill signal). Raise the cap for a stiffer, more steel-cable leash.
@export var taut_snap_strength: float = 14.0
@export var taut_max_snap_speed: float = 12.0
# Bend points sit this far off the surface they touch (prevents the wrap ray re-hitting
# the same face forever).
@export var wrap_surface_offset: float = 0.07
# A new bend must be at least this far from the current pivot (kills duplicate bends on
# the same corner).
@export var wrap_min_pivot_separation: float = 0.15
@export var rope_width: float = 0.03
@export var rope_color: Color = Color(0.82, 0.88, 1.0)



var player: RigidBody3D
# Standard-issue kit: every player has the grapple by default (no purchase needed). Flip to
# false to gate it behind the shop again (see buy_menu.gd's SPECIAL SUIT SYSTEMS catalog).
var has_grapple: bool = true
var attached: bool = false

# The pivot chain: [anchor, bend, bend, ...] — the LAST entry is the active swing pivot.
var pivots: Array[Vector3] = []
# Rope length consumed by the segments anchor -> ... -> active pivot.
var consumed_length: float = 0.0
# Total wire length (locked at attach distance, only ever shortened by reeling).
var total_length: float = 0.0
# Per-bend wrap orientation at creation (axis of (prev - bend) x (player - bend)); the
# sign flipping is the "rope straightened back past this bend" unwrap test.
var bend_axes: Array[Vector3] = []

var initial_total_length: float = 0.0

var rope_visual: MeshInstance3D
var rope_mesh: ImmediateMesh
var rope_material: StandardMaterial3D

# Reused for every wrap/unwrap/attach ray (several per physics tick while attached), same
# pattern as LimbPushController's cached query.
var _ray_query: PhysicsRayQueryParameters3D


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player

	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false

	if player is CollisionObject3D:
		_ray_query.exclude = [player.get_rid()]

	_create_rope_visual()


func purchase_grapple() -> void:
	has_grapple = true
	print("Grapple wire purchased.")


func get_has_grapple() -> bool:
	return has_grapple


# --- Fire / release (local player) ----------------------------------------------------

func try_fire() -> bool:
	if not has_grapple or attached or player == null:
		return false

	var camera := player.get_node_or_null("CameraRig/Camera3D") as Camera3D

	if camera == null:
		return false

	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var hit := _raycast(origin, origin + direction * max_range)

	if hit.is_empty():
		return false

	# Static world geometry only: no players, no shoveable props (a moving anchor with
	# stuck bend points gets weird — future feature, not this one).
	var collider = hit.get("collider")

	if collider is RigidBody3D or _belongs_to_player(collider):
		return false

	var normal: Vector3 = hit.get("normal", Vector3.ZERO)

	if normal.length() < 0.01:
		normal = -direction

	var anchor: Vector3 = (hit["position"] as Vector3) + normal.normalized() * wrap_surface_offset

	attached = true
	pivots = [anchor]
	bend_axes = []
	consumed_length = 0.0

	# Fixed wire length: the attach distance (taut almost immediately) or the tool's full
	# range with slack — see shoot_out_full_length.
	if shoot_out_full_length:
		total_length = maxf(max_range, min_length)
	else:
		total_length = maxf(player.global_position.distance_to(anchor), min_length)
		
		
	initial_total_length = total_length

	_report_event(EVENT_ATTACH, anchor)
	return true


func release() -> void:
	if not attached:
		return

	attached = false
	pivots = []
	bend_axes = []
	consumed_length = 0.0
	total_length = 0.0
	initial_total_length = 0.0

	_report_event(EVENT_RELEASE, Vector3.ZERO)


# --- Physics (local player, called from player._physics_process) -----------------------

func physics_update(delta: float, input_enabled: bool) -> void:
	if not attached or player == null:
		return

	# Spool in (never out). Reeling below the current distance makes the taut correction
	# below tow the player toward the pivot at roughly reel_speed.
	if input_enabled and InputMap.has_action("grapple_reel") and Input.is_action_pressed("grapple_reel"):
		total_length = maxf(total_length - reel_speed * delta, consumed_length + min_length)

	_update_wrap()
	_update_unwrap()
	_apply_tether_constraint(delta)


# The wire bends where it touches geometry: cast player -> active pivot; an obstruction
# becomes a new pivot (stuck where it touched — no slip). Loops a few times for tight
# corners crossed in one tick.
func _update_wrap() -> void:
	var min_separation := maxf(wrap_min_pivot_separation, WRAP_PIVOT_EPSILON)

	for i in range(3):
		if pivots.size() >= MAX_PIVOTS:
			return   # chain is saturated; the tether still works on the newest pivot

		var active: Vector3 = pivots[pivots.size() - 1]
		var to_pivot := active - player.global_position
		var pivot_distance := to_pivot.length()

		if pivot_distance < min_separation:
			return

		var hit := _raycast(player.global_position, active)

		if hit.is_empty():
			return

		var hit_position: Vector3 = hit["position"]
		var hit_distance := player.global_position.distance_to(hit_position)

		# Reaching (almost) the pivot itself = clear rope, no bend.
		if hit_distance > pivot_distance - 0.08:
			return

		var normal: Vector3 = hit.get("normal", Vector3.ZERO)

		if normal.length() < 0.01:
			return

		var bend := hit_position + normal.normalized() * wrap_surface_offset

		if bend.distance_to(active) < min_separation:
			return

		# Wrap orientation at creation — flipping past zero later = straightened = unwrap.
		var axis := (active - bend).cross(player.global_position - bend)

		if axis.length() < 0.0001:
			return

		consumed_length += bend.distance_to(active)
		pivots.append(bend)
		bend_axes.append(axis.normalized())
		_report_event(EVENT_BEND, bend)


# Reverse of wrapping: when the rope straightens back past the newest bend AND the previous
# pivot is in clear line of sight, the bend releases and the radius grows back.
func _update_unwrap() -> void:
	if pivots.size() < 2:
		return

	var bend: Vector3 = pivots[pivots.size() - 1]
	var previous: Vector3 = pivots[pivots.size() - 2]
	var axis := (previous - bend).cross(player.global_position - bend)

	if axis.length() < 0.0001:
		return

	if axis.normalized().dot(bend_axes[bend_axes.size() - 1]) >= 0.0:
		return   # still wrapped the same way

	# Straightened — confirm nothing solid between us and the previous pivot.
	var previous_distance := player.global_position.distance_to(previous)
	var hit := _raycast(player.global_position, previous)

	if not hit.is_empty():
		var hit_distance := player.global_position.distance_to(hit["position"])

		if hit_distance < previous_distance - 0.08:
			return   # blocked; stay wrapped

	consumed_length = maxf(consumed_length - bend.distance_to(previous), 0.0)
	pivots.pop_back()
	bend_axes.pop_back()
	_report_event(EVENT_UNWRAP, Vector3.ZERO)


# The fixed-length tether: free inside the radius; past it, absorb the outward radial
# velocity (keep the tangent — that's the swing) and pull the overshoot back in. taut_give
# spreads the absorption over time so the catch has some yield instead of a one-frame snap.
func _apply_tether_constraint(delta: float) -> void:
	var active: Vector3 = pivots[pivots.size() - 1]
	var radius := maxf(total_length - consumed_length, min_length)
	var to_player := player.global_position - active
	var distance := to_player.length()

	if distance <= radius or distance < 0.001:
		return

	# Wire tension yanks a surface-walking player off their surface into zero-G.
	if player.has_method("is_surface_walk_mode_active") and player.call("is_surface_walk_mode_active"):
		var movement = player.get("movement_controller")

		if movement != null and movement.has_method("exit_surface_walk_mode"):
			movement.exit_surface_walk_mode()

	var radial := to_player / distance
	var outward_speed := player.linear_velocity.dot(radial)

	if outward_speed > 0.0:
		var absorb := 1.0

		if taut_give > 0.001:
			absorb = clampf(1.0 - exp(-delta / taut_give), 0.0, 1.0)

		player.linear_velocity -= radial * outward_speed * absorb

	var overshoot := distance - radius
	var pull_speed := minf(overshoot * taut_snap_strength, taut_max_snap_speed)
	player.linear_velocity -= radial * pull_speed
	player.sleeping = false


# --- Remote mirroring (other clients' copies of this player) ---------------------------

func apply_remote_event(kind: int, point: Vector3) -> void:
	match kind:
		EVENT_ATTACH:
			attached = true
			pivots = [point]
			bend_axes = []
		EVENT_BEND:
			# Same cap as the local simulation: a hacked sender spamming bend events must
			# not grow every lobby member's mirror of this chain without bound.
			if attached and pivots.size() < MAX_PIVOTS:
				pivots.append(point)
		EVENT_UNWRAP:
			if attached and pivots.size() > 1:
				pivots.pop_back()
		EVENT_RELEASE:
			attached = false
			pivots = []
			bend_axes = []


func _report_event(kind: int, point: Vector3) -> void:
	if player != null and player.has_method("report_grapple_event"):
		player.call("report_grapple_event", kind, point)


# --- Rope visual ------------------------------------------------------------------------
# One camera-facing ribbon through player -> active pivot -> ... -> anchor, rebuilt per
# rendered frame. Runs for local AND remote copies (remote pivots come from the relay).

func _create_rope_visual() -> void:
	if DisplayServer.get_name() == "headless":
		set_process(false)   # _process only draws the rope; nothing renders headless
		return

	rope_mesh = ImmediateMesh.new()
	rope_material = StandardMaterial3D.new()
	rope_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rope_material.albedo_color = rope_color
	rope_material.emission_enabled = true
	rope_material.emission = rope_color
	rope_material.emission_energy_multiplier = 1.4
	rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	rope_visual = MeshInstance3D.new()
	rope_visual.name = "GrappleRope"
	rope_visual.mesh = rope_mesh
	rope_visual.material_override = rope_material
	rope_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rope_visual.top_level = true   # rope lives in world space, not the player's basis
	add_child(rope_visual)


func _process(_delta: float) -> void:
	_draw_rope()


func _draw_rope() -> void:
	if rope_mesh == null:
		return

	rope_mesh.clear_surfaces()

	if not attached or pivots.is_empty() or player == null:
		return

	rope_visual.global_transform = Transform3D.IDENTITY

	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var camera_position := camera.global_position if camera != null else player.global_position + Vector3.UP * 10.0

	# Hand-ish origin on the body so the rope doesn't come out of the face.
	var points: Array[Vector3] = [player.global_position + player.global_transform.basis * Vector3(0.3, -0.25, 0.0)]

	for i in range(pivots.size() - 1, -1, -1):
		points.append(pivots[i])

	rope_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var segment := b - a

		if segment.length() < 0.001:
			continue

		var to_camera := camera_position - (a + b) * 0.5
		var side := segment.cross(to_camera)

		if side.length() < 0.001:
			side = segment.cross(Vector3.UP)

		if side.length() < 0.001:
			continue

		side = side.normalized() * rope_width * 0.5

		rope_mesh.surface_add_vertex(a - side)
		rope_mesh.surface_add_vertex(a + side)
		rope_mesh.surface_add_vertex(b + side)
		rope_mesh.surface_add_vertex(a - side)
		rope_mesh.surface_add_vertex(b + side)
		rope_mesh.surface_add_vertex(b - side)

	rope_mesh.surface_end()


# --- Helpers ----------------------------------------------------------------------------

func _raycast(from: Vector3, to: Vector3) -> Dictionary:
	_ray_query.from = from
	_ray_query.to = to
	return player.get_world_3d().direct_space_state.intersect_ray(_ray_query)


func _belongs_to_player(collider: Object) -> bool:
	var current = collider

	while current != null and current is Node:
		if current.has_method("get_peer_id"):
			return true

		current = (current as Node).get_parent()

	return false
	

func get_aim_target_info() -> Dictionary:
	if attached or not has_grapple or player == null:
		return {"available": false, "distance": 0.0}

	var camera := player.get_node_or_null("CameraRig/Camera3D") as Camera3D

	if camera == null:
		return {"available": false, "distance": 0.0}

	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var hit := _raycast(origin, origin + direction * max_range)

	if hit.is_empty():
		return {"available": false, "distance": 0.0}

	var collider = hit.get("collider")

	if collider is RigidBody3D or _belongs_to_player(collider):
		return {"available": false, "distance": 0.0}

	return {"available": true, "distance": origin.distance_to(hit["position"] as Vector3)}



func get_reel_ratio() -> float:
	if not attached or initial_total_length <= min_length:
		return 0.0

	return clampf(
		(initial_total_length - total_length) / (initial_total_length - min_length),
		0.0,
		1.0
	)
	
func get_camera_look_distance() -> float:
	if player == null:
		return -1.0

	var camera := player.get_node_or_null("CameraRig/Camera3D") as Camera3D

	if camera == null:
		return -1.0

	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var hit := _raycast(origin, origin + direction * 9999)

	if hit.is_empty():
		return -1.0

	return origin.distance_to(hit["position"] as Vector3)