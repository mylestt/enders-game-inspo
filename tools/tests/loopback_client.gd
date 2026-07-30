extends SceneTree

# Headless loopback client for integration testing. Start a dedicated server first:
#
#   <godot> --headless --path . -- --server --port 7777
#
# then run:
#
#   <godot> --headless --path . -s tools/tests/loopback_client.gd
#
# Connects to 127.0.0.1:7777, creates a lobby, and reports whether the local player
# spawned. Exits 0 on success, 1 on timeout/failure.

const TIMEOUT_SECONDS := 15.0

var _elapsed: float = 0.0
var _done: bool = false


func _initialize() -> void:
	GameLaunch.pending_mode = GameLaunch.Mode.MULTIPLAYER_HOST
	GameLaunch.server_ip = "127.0.0.1"
	GameLaunch.player_username = "LoopbackTester"
	GameLaunch.username_configured = true
	GameLaunch.lobby_name = "Loopback Test Lobby"

	change_scene_to_file("res://Resources/Scenes/Core/main.tscn")
	print("Loopback client: connecting to 127.0.0.1 and creating a lobby...")


func _process(delta: float) -> bool:
	if _done:
		return true

	_elapsed += delta

	var scene := current_scene

	if scene != null:
		var nm := scene.get_node_or_null("NetworkManager")

		if nm != null and nm.has_method("get_local_player"):
			var player = nm.call("get_local_player")

			if player != null:
				print("LOOPBACK PASS: local player spawned in a lobby (peer ",
					nm.call("get_local_peer_id"), ").")
				_done = true
				quit(0)
				return true

	if _elapsed >= TIMEOUT_SECONDS:
		printerr("LOOPBACK FAIL: no spawn within ", TIMEOUT_SECONDS, "s.")
		_done = true
		quit(1)
		return true

	return false
