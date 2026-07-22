extends Node3D
class_name CameraRig

# Procedural camera offsets layered on top of the existing look.
# Headbob, landing dip and strafe-lean only apply while surface-walking;
# look-sway applies in every mode. Runs in _physics_process so the physics
# interpolation enabled project-wide smooths it up to the render rate.

@export var top_speed: float = 12.5

# Headbob (figure-8: vertical bobs twice per horizontal sway). Tuned heavy — slow, deep
# steps like a weighted space suit.
@export var bob_amp_walk: float = 0.05
@export var bob_amp_sprint: float = 0.13
@export var bob_freq_walk: float = 1.6
@export var bob_freq_sprint: float = 2.3
@export var bob_intensity: float = 2.5
@export var bob_smoothing: float = 8.0

# Landing dip (damped spring) fired when you touch down on a surface
@export var land_dip_per_mps: float = 0.012
@export var land_dip_max: float = 0.24
@export var land_threshold: float = 2.0
@export var land_spring: float = 220.0
@export var land_damping: float = 22.0

# Look-sway (view lags fast turns) + strafe lean
@export var sway_amount: float = 0.02
@export var sway_max_degrees: float = 0.9
@export var sway_smoothing: float = 22.0
@export var tilt_max_degrees: float = 1.8
@export var tilt_smoothing: float = 8.0

var player: RigidBody3D
var camera: Camera3D

var bob_time: float = 0.0
var bob_amp: float = 0.0
var dip: float = 0.0
var dip_velocity: float = 0.0
var sway: Vector2 = Vector2.ZERO
var tilt: float = 0.0

var prev_look_basis: Basis = Basis.IDENTITY
var prev_speed: float = 0.0
var was_grounded: bool = false

# Transient explosion feedback is layered on this parent rig so it never fights the movement
# controller or ImpactController, both of which legitimately write to the child Camera3D.
var explosion_shake_time: float = 0.0
var explosion_shake_duration: float = 0.0
var explosion_shake_elapsed: float = 0.0
var explosion_shake_frequency: float = 18.0
var explosion_position_amplitude: float = 0.0
var explosion_rotation_amplitude: float = 0.0
var explosion_directional_punch: float = 0.0
var explosion_direction_local: Vector3 = Vector3.BACK
var explosion_phase: float = 0.0
var explosion_position_offset: Vector3 = Vector3.ZERO
var explosion_rotation_offset: Vector3 = Vector3.ZERO


func _ready() -> void:
	player = get_parent() as RigidBody3D
	camera = get_node_or_null("Camera3D") as Camera3D
	prev_look_basis = get_look_basis()


# Call on touchdown with the approach speed; small impacts are ignored.
func kick_landing(fall_speed: float) -> void:
	if fall_speed < land_threshold:
		return

	dip = -clampf((fall_speed - land_threshold) * land_dip_per_mps, 0.0, land_dip_max)
	dip_velocity = 0.0


func _physics_process(delta: float) -> void:
	if player == null:
		return

	# Normalize defensively: slide() requires a unit normal, and a body that briefly carries
	# scale (e.g. a spawn transform authored with a scaled marker) would error every frame.
	var up := player.global_transform.basis.y

	if up.length_squared() < 0.0001:
		up = Vector3.UP
	else:
		up = up.normalized()

	var tangent_velocity := player.linear_velocity.slide(up)
	var grounded := is_surface_walking()

	if grounded and not was_grounded:
		kick_landing(prev_speed)

	was_grounded = grounded
	prev_speed = player.linear_velocity.length()

	update_headbob(delta, tangent_velocity.length(), grounded)
	update_landing(delta)
	update_sway(delta)
	update_tilt(delta, tangent_velocity, grounded)
	update_explosion_shake(delta)

	position = Vector3(0.0, dip, 0.0) + headbob_offset() + explosion_position_offset
	rotation = Vector3(sway.y, sway.x, tilt) + explosion_rotation_offset


# `world_direction` points outward from the blast toward the viewer. A short counter-motion
# provides the initial pressure punch, followed by a higher-frequency decaying vibration.
func trigger_explosion_shake(
	world_direction: Vector3,
	strength: float,
	position_amplitude: float,
	rotation_amplitude_degrees: float,
	duration: float,
	frequency_hz: float,
	directional_punch: float
) -> void:
	var clamped_strength := clampf(strength, 0.0, 1.0)

	if clamped_strength <= 0.0:
		return

	var local_direction := global_transform.basis.inverse() * world_direction.normalized()
	var new_position_amplitude := maxf(position_amplitude, 0.0) * clamped_strength
	var new_rotation_amplitude := (
		deg_to_rad(maxf(rotation_amplitude_degrees, 0.0))
		* clamped_strength
	)
	var new_punch := maxf(directional_punch, 0.0) * clamped_strength
	var new_duration := maxf(duration, 0.01)
	var was_inactive := explosion_shake_time <= 0.0

	# Stronger/newer blasts take priority while still allowing nearby blasts to extend a shake.
	if new_position_amplitude >= explosion_position_amplitude or was_inactive:
		explosion_direction_local = local_direction
		explosion_position_amplitude = new_position_amplitude
		explosion_rotation_amplitude = new_rotation_amplitude
		explosion_directional_punch = new_punch
		explosion_shake_frequency = maxf(frequency_hz, 0.1)
		explosion_phase = randf() * TAU

	explosion_shake_duration = new_duration if was_inactive else maxf(explosion_shake_duration, new_duration)
	explosion_shake_time = maxf(explosion_shake_time, new_duration)
	explosion_shake_elapsed = 0.0


func update_explosion_shake(delta: float) -> void:
	if explosion_shake_time <= 0.0:
		explosion_position_offset = explosion_position_offset.lerp(
			Vector3.ZERO,
			1.0 - exp(-28.0 * delta)
		)
		explosion_rotation_offset = explosion_rotation_offset.lerp(
			Vector3.ZERO,
			1.0 - exp(-28.0 * delta)
		)
		return

	explosion_shake_time = maxf(explosion_shake_time - delta, 0.0)
	explosion_shake_elapsed += delta
	var remaining := clampf(
		explosion_shake_time / maxf(explosion_shake_duration, 0.001),
		0.0,
		1.0
	)
	var vibration_envelope := remaining * remaining
	var punch_envelope := remaining * remaining * remaining * remaining
	var phase := explosion_phase + explosion_shake_elapsed * explosion_shake_frequency * TAU
	var noise := Vector3(
		sin(phase),
		cos(phase * 1.37 + 0.8),
		sin(phase * 0.73 + 2.1)
	)

	var vibration := noise * explosion_position_amplitude * vibration_envelope
	var punch := -explosion_direction_local * explosion_directional_punch * punch_envelope
	explosion_position_offset = vibration + punch
	explosion_rotation_offset = (
		Vector3(noise.y, noise.x, noise.z)
		* explosion_rotation_amplitude
		* vibration_envelope
	)


func update_headbob(delta: float, speed: float, grounded: bool) -> void:
	var ratio := clampf(speed / maxf(top_speed, 0.001), 0.0, 1.0)
	var grounded_factor := 1.0 if grounded else 0.0
	var target_amp := lerpf(bob_amp_walk, bob_amp_sprint, ratio) * bob_intensity * ratio * grounded_factor

	bob_amp = lerpf(bob_amp, target_amp, 1.0 - exp(-bob_smoothing * delta))
	bob_time += lerpf(bob_freq_walk, bob_freq_sprint, ratio) * TAU * delta


func headbob_offset() -> Vector3:
	return Vector3(sin(bob_time * 0.5) * bob_amp, sin(bob_time) * bob_amp, 0.0)


func update_landing(delta: float) -> void:
	dip_velocity += (-land_spring * dip - land_damping * dip_velocity) * delta
	dip += dip_velocity * delta


func update_sway(delta: float) -> void:
	var look_basis := get_look_basis()
	var spin := (prev_look_basis.inverse() * look_basis).get_euler()
	prev_look_basis = look_basis

	var max_sway := deg_to_rad(sway_max_degrees)
	var inv_delta := 1.0 / maxf(delta, 1e-4)
	var target := Vector2(
		clampf(-spin.y * inv_delta * sway_amount, -max_sway, max_sway),
		clampf(-spin.x * inv_delta * sway_amount, -max_sway, max_sway)
	)

	sway = sway.lerp(target, 1.0 - exp(-sway_smoothing * delta))


func update_tilt(delta: float, tangent_velocity: Vector3, grounded: bool) -> void:
	var target := 0.0

	if grounded and tangent_velocity.length_squared() > 0.01:
		var right := player.global_transform.basis.x
		target = -right.dot(tangent_velocity.normalized()) * deg_to_rad(tilt_max_degrees)

	tilt = lerpf(tilt, target, 1.0 - exp(-tilt_smoothing * delta))


# The look orientation (body + camera pitch), excluding this rig's own offset,
# so sway never feeds back on itself.
func get_look_basis() -> Basis:
	if player == null:
		return global_transform.basis

	var look := player.global_transform.basis

	if camera != null:
		look = look * camera.transform.basis

	return look


func is_surface_walking() -> bool:
	if player == null:
		return false

	# Prefer the true standing check (excludes mid-hop) so bob/lean stop in the air and the
	# landing dip fires on every hop touchdown.
	if player.has_method("is_surface_grounded"):
		return bool(player.call("is_surface_grounded"))

	if player.has_method("is_surface_walk_mode_active"):
		return bool(player.call("is_surface_walk_mode_active"))

	return false
