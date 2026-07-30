extends Node3D

@export var players_parent_path: NodePath = NodePath("Players")
@export var player_camera_name: String = "CameraRig/Camera3D"
@export var debug_camera: Camera3D

var debug_camera_active: bool = false


func _ready() -> void:
	if debug_camera == null:
		push_warning("DebugTopCamera is not assigned. Debug camera toggle will not work.")
		return
	
	debug_camera.current = false


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_camera"):
		toggle_debug_camera()


func toggle_debug_camera() -> void:
	if debug_camera == null:
		push_warning("DebugTopCamera is not assigned.")
		return
	
	var player_camera := get_local_player_camera()
	
	if player_camera == null:
		push_warning("No local player camera found yet. Host or join first.")
		return
	
	debug_camera_active = not debug_camera_active
	
	if debug_camera_active:
		debug_camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		player_camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func get_local_player_camera() -> Camera3D:
	var players_parent := get_node_or_null(players_parent_path)
	
	if players_parent == null:
		return null
	
	var local_peer_id := multiplayer.get_unique_id()
	
	for child in players_parent.get_children():
		if child == null:
			continue
		
		if child.has_method("get_peer_id"):
			var child_peer_id: int = int(child.call("get_peer_id"))
			
			if child_peer_id == local_peer_id:
				return child.get_node_or_null(player_camera_name) as Camera3D
	
	# Fallback for solo testing if peer IDs are not ready yet.
	for child in players_parent.get_children():
		var camera := child.get_node_or_null(player_camera_name) as Camera3D
		
		if camera != null:
			return camera
	
	return null
