extends Node3D

@export var player_path: NodePath
@export var player_camera_name: String = "Camera3D"
@export var debug_camera: Camera3D

var player_camera: Camera3D


func _ready() -> void:
	var player := get_node_or_null(player_path)
	
	if player == null:
		push_error("Player path is not assigned or is wrong.")
		return
	
	player_camera = player.get_node_or_null(player_camera_name)
	
	if player_camera == null:
		push_error("Could not find Camera3D inside the Player scene.")
		return
	
	if debug_camera == null:
		push_error("DebugTopCamera is not assigned.")
		return
	
	player_camera.make_current()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_camera"):
		toggle_debug_camera()


func toggle_debug_camera() -> void:
	if debug_camera.is_current():
		player_camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		debug_camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
