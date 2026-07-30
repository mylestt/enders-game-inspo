class_name Drone
extends RigidBody3D

# Test-Arena hostile drone. Physics-flown (forces only, so weapon hits shove it around),
# seeks the player but keeps its distance, never sits still (wander), dodges walls with one
# whisker ray, and fires a bolt straight out of the barrel (+X) once it's pointed on target.

const DroneBoltScript := preload("res://Resources/Scripts/Enemies/drone_bolt.gd")

@export var aggressive: bool = true   # peaceful drones fly and chase but never shoot
@export var max_health: float = 50.0
@export var accel_force: float = 14.0
@export var preferred_range: float = 9.0
@export var wander_strength: float = 3.0
@export var turn_rate: float = 4.0
@export var wall_check_distance: float = 3.5
@export var fire_interval: float = 1.6
@export var aim_dot_to_fire: float = 0.94
@export var bullet_damage: float = 6.0
@export var bullet_speed: float = 28.0

var health: float = 50.0
var fire_cooldown: float = 2.0
var wander_phase: float = 0.0

@onready var barrel: Marker3D = $BarrelOpening


func _ready() -> void:
	add_to_group("drones")
	health = max_health
	wander_phase = randf() * TAU


func _physics_process(delta: float) -> void:
	fire_cooldown -= delta
	wander_phase += delta * 1.6

	# Wander keeps it drifting even with no target; the axes use unrelated frequencies so
	# the path never settles into a loop.
	var force := Vector3(
		sin(wander_phase),
		sin(wander_phase * 0.63 + 1.7),
		cos(wander_phase * 0.81)
	) * wander_strength

	var target := find_player()

	if target != null:
		var to_target: Vector3 = target.global_position - global_position
		var distance := to_target.length()
		var aim := to_target / maxf(distance, 0.001)

		# Close in until preferred range, back off inside it.
		force += aim * clampf(distance - preferred_range, -1.0, 1.0) * accel_force

		# Torque-free steering: cross(barrel, aim) is the swing axis, sin-scaled so it
		# eases out as the barrel settles on target. Hit spin decays via angular_damp.
		angular_velocity = angular_velocity.lerp(global_transform.basis.x.cross(aim) * turn_rate, 0.2)

		if aggressive and fire_cooldown <= 0.0 and global_transform.basis.x.dot(aim) >= aim_dot_to_fire:
			fire()

	# One whisker along the flight path: steer off whatever is coming.
	if linear_velocity.length() > 0.5:
		var query := PhysicsRayQueryParameters3D.create(
			global_position,
			global_position + linear_velocity.normalized() * wall_check_distance
		)
		query.exclude = [get_rid()]
		var ahead := get_world_3d().direct_space_state.intersect_ray(query)

		if not ahead.is_empty():
			force += (ahead["normal"] as Vector3) * accel_force

	apply_central_force(force)


func find_player() -> Node3D:
	var nearest: Node3D = null
	var best := INF

	for node in get_tree().get_nodes_in_group("players"):
		var p := node as Node3D

		if p == null or p.get("is_dead") == true:
			continue

		var d := global_position.distance_squared_to(p.global_position)

		if d < best:
			best = d
			nearest = p

	return nearest


func fire() -> void:
	fire_cooldown = fire_interval * randf_range(0.8, 1.2)
	var bolt: Area3D = DroneBoltScript.new(global_transform.basis.x, bullet_speed, bullet_damage)
	get_parent().add_child(bolt)
	bolt.global_position = barrel.global_position


# Same interface the weapons' damage path calls on players; the hit impulse comes from
# player.submit_weapon_hit's local branch.
func apply_weapon_damage(damage: float, _attacker_peer_id: int = 0) -> void:
	health -= damage

	if health <= 0.0:
		explode()


func explode() -> void:
	var boom := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.6
	ball.height = 1.2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.55, 0.15, 0.9)
	ball.material = mat
	boom.mesh = ball
	get_parent().add_child(boom)
	boom.global_position = global_position

	var tween := boom.create_tween()
	tween.tween_property(boom, "scale", Vector3.ONE * 3.5, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.3)
	tween.tween_callback(boom.queue_free)

	queue_free()
