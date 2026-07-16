class_name DroneSpawner
extends Node3D

# Test Arena only: spawns drones on a timer per GameLaunch.drone_mode (set by the map-setup
# menu's Drones dropdown; peaceful drones never shoot). Drones spawn above random map spawn
# markers; the cap counts live drones (they're this node's children).

const DRONE_SCENE := preload("res://Resources/Objects/testingdrone.tscn")

@export var spawn_interval: float = 5.0
@export var max_drones: int = 4
@export var spawn_height: float = 4.0

var spawn_timer: float = 2.0


func _ready() -> void:
	if GameLaunch.drone_mode == GameLaunch.DRONES_NONE:
		queue_free()


func _physics_process(delta: float) -> void:
	spawn_timer -= delta

	if spawn_timer > 0.0 or get_child_count() >= max_drones:
		return

	var markers := get_tree().get_nodes_in_group("spawn_team_a") + get_tree().get_nodes_in_group("spawn_team_b")

	if markers.is_empty():
		return

	spawn_timer = spawn_interval
	var marker := markers.pick_random() as Node3D
	var drone := DRONE_SCENE.instantiate() as Node3D
	drone.set("aggressive", GameLaunch.drone_mode == GameLaunch.DRONES_AGGRESSIVE)
	add_child(drone)
	drone.global_position = (
		marker.global_position
		+ marker.global_transform.basis.y * spawn_height
		+ Vector3(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0), randf_range(-2.0, 2.0))
	)
