extends Node3D
class_name CameraRig

# Procedural camera offsets layered on top of the existing look.
# Headbob, landing dip and strafe-lean only apply while surface-walking;
# look-sway applies in every mode. Runs in _physics_process so the physics
# interpolation enabled project-wide smooths it up to the render rate.

@export var top_speed: float = 12.5

# Headbob (figure-8: vertical bobs twice per horizontal sway)
@export var bob_amp_walk: float = 0.05
@export var bob_amp_sprint: float = 0.13
@export var bob_freq_walk: float = 1.8
@export var bob_freq_sprint: float = 2.6
@export var bob_intensity: float = 1.95
@export var bob_smoothing: float = 8.0

# Landing dip (damped spring) fired when you touch down on a surface
@export var land_dip_per_mps: float = 0.008
@export var land_dip_max: float = 0.18
@export var land_threshold: float = 2.0
@export var land_spring: float = 220.0
@export var land_damping: float = 22.0

# Look-sway (view lags fast turns) + strafe lean
@export var sway_amount: float = 0.02
@export var sway_max_degrees: float = 0.7
@export var sway_smoothing: float = 22.0
@export var tilt_max_degrees: float = 1.3
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

	var up := player.global_transform.basis.y
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

	position = Vector3(0.0, dip, 0.0) + headbob_offset()
	rotation = Vector3(sway.y, sway.x, tilt)


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

	if player.has_method("is_surface_walk_mode_active"):
		return bool(player.call("is_surface_walk_mode_active"))

	return false
