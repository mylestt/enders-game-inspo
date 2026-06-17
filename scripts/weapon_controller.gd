class_name WeaponController
extends Node3D

# Procedural FPS weapon: tracks the laser reticle, sways with look, recoils when
# the laser fires (driven by laser_controller.fire()), and knocks the player back.

@export var sway_amount: float = 0.03      # radians of sway per rad/s of look speed (60% of original)
@export var sway_max: float = 0.054        # clamp so it stays subtle
@export var sway_speed: float = 9.0        # how fast sway eases (higher = tighter)

@export var aim_follow: float = 0.2        # fraction of the reticle offset the gun visually leans
@export var aim_max_degrees: float = 14.0  # hard cap on that lean, so it stays forward in-hand

@export var recoil_kick: float = 0.10      # metres the gun jerks backward (+z)
@export var recoil_pitch: float = 7.0      # degrees the muzzle flips up
@export var recoil_recover: float = 13.0   # how fast recoil settles

@export var knockback: float = 2.5         # impulse pushing the player backward

var player: RigidBody3D
var camera: Camera3D
var laser: Node

var rest_position: Vector3
var rest_rotation: Vector3
var current_sway: Vector2 = Vector2.ZERO
var recoil: float = 0.0

@onready var barrel: Node3D = get_node_or_null("RifleTest/Barrel")


func _ready() -> void:
	rest_position = position
	rest_rotation = rotation

	var node := get_parent()
	while node != null and not (node is RigidBody3D):
		node = node.get_parent()
	player = node as RigidBody3D

	camera = get_parent() as Camera3D
	if camera != null:
		laser = camera.get_node_or_null("LaserController")


func _process(delta: float) -> void:
	if player == null or camera == null or not player.is_local_player:
		return

	recoil = lerpf(recoil, 0.0, 1.0 - exp(-recoil_recover * delta))

	# Sway lags the gun against the body's turn rate (camera-local yaw/pitch).
	var cam_basis := camera.global_transform.basis
	var target := Vector2(
		clampf(-player.angular_velocity.dot(cam_basis.y) * sway_amount, -sway_max, sway_max),
		clampf(player.angular_velocity.dot(cam_basis.x) * sway_amount, -sway_max, sway_max)
	)
	current_sway = current_sway.lerp(target, 1.0 - exp(-sway_speed * delta))

	# Lean the gun slightly toward the reticle while aiming, heavily capped, so it
	# always reads as held forward in-hand. Purely visual — shots ignore this.
	var aim_dir := -cam_basis.z
	if laser != null and laser.has_method("is_laser_aiming") and laser.call("is_laser_aiming"):
		aim_dir = laser.call("get_actual_laser_direction")

	var local_aim := (cam_basis.inverse() * aim_dir).normalized()
	var offset := Vector3.FORWARD.angle_to(local_aim)
	var lean := minf(aim_follow, deg_to_rad(aim_max_degrees) / maxf(offset, 0.0001))
	var aim_basis := Basis.looking_at(Vector3.FORWARD.slerp(local_aim, lean))
	var sway_recoil := Basis.from_euler(Vector3(
		current_sway.y + deg_to_rad(recoil_pitch) * recoil,
		current_sway.x,
		0.0
	))

	basis = aim_basis * Basis.from_euler(rest_rotation) * sway_recoil
	position = Vector3(rest_position.x, rest_position.y, rest_position.z + recoil_kick * recoil)


# Called by laser_controller each time a shot fires.
func fire() -> void:
	recoil = 1.0
	# +z is directly behind the player, so this shoves them back.
	player.apply_central_impulse(player.global_transform.basis.z * knockback)


func get_muzzle_world_position() -> Vector3:
	return barrel.global_position if barrel != null else global_position
