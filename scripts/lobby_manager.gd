extends Node
class_name LobbyManager

# Server-authoritative lobby system. ONE active lobby for now, but the data model and
# RPCs are shaped to grow into many. Clients connect to the server only to BROWSE; they
# spawn into the world only when they JOIN a lobby. The server owns all lobby state.
#
# Flow:
#   client connects -> (no spawn) -> browse list / create lobby / join lobby -> spawn.

signal lobby_list_received(lobbies: Array)
signal lobby_result(success: bool, message: String)

@export var network_manager_path: NodePath = NodePath("../NetworkManager")
@export var round_manager_path: NodePath = NodePath("../RoundManager")
@export var generated_map_path: NodePath = NodePath("../GeneratedMap")

const SINGLE_LOBBY_ID := 1

var network_manager: Node
var round_manager: Node
var generated_map: Node

var lobbies: Dictionary = {}            # lobby_id -> lobby dict
var lobby_id_by_peer: Dictionary = {}   # peer_id -> lobby_id (only joined/spawned peers)


func _ready() -> void:
	network_manager = get_node_or_null(network_manager_path)
	round_manager = get_node_or_null(round_manager_path)
	generated_map = get_node_or_null(generated_map_path)

	if is_server():
		call_deferred("_ensure_default_lobby")


func is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


# --- Client-side request helpers (also work when the caller IS the server/host) -----

func client_request_lobby_list() -> void:
	if is_server():
		_send_lobby_list_to(1)
	elif multiplayer.multiplayer_peer != null:
		rpc_id(1, "server_request_lobby_list")


func client_request_create_lobby(settings: Dictionary) -> void:
	if is_server():
		_server_handle_create_lobby(1, settings)
	elif multiplayer.multiplayer_peer != null:
		rpc_id(1, "server_request_create_lobby", settings)


func client_request_join_lobby(lobby_id: int, password: String) -> void:
	if is_server():
		_server_handle_join_lobby(1, lobby_id, password)
	elif multiplayer.multiplayer_peer != null:
		rpc_id(1, "server_request_join_lobby", lobby_id, password)


# --- Server RPC entry points -------------------------------------------------------

@rpc("any_peer", "reliable")
func server_request_lobby_list() -> void:
	if not is_server():
		return

	_send_lobby_list_to(multiplayer.get_remote_sender_id())


@rpc("any_peer", "reliable")
func server_request_create_lobby(settings: Dictionary) -> void:
	if not is_server():
		return

	_server_handle_create_lobby(multiplayer.get_remote_sender_id(), settings)


@rpc("any_peer", "reliable")
func server_request_join_lobby(lobby_id: int, password: String) -> void:
	if not is_server():
		return

	_server_handle_join_lobby(multiplayer.get_remote_sender_id(), lobby_id, password)


# --- Server logic ------------------------------------------------------------------

func _ensure_default_lobby() -> void:
	if not is_server() or not lobbies.is_empty():
		return

	# Test Arena / local host don't use the lobby system; only lobby-mode servers do.
	if network_manager != null and "lobby_mode" in network_manager and not network_manager.lobby_mode:
		return

	_create_or_reconfigure_lobby(_default_lobby_settings())
	print("LobbyManager: default lobby ready.")


func _server_handle_create_lobby(peer_id: int, settings: Dictionary) -> void:
	# One lobby for now: only allow (re)configuring when no game is in progress.
	if _any_lobby_in_progress():
		_send_result_to(peer_id, false, "A game is already running. Try again after it ends.")
		return

	var lobby := _create_or_reconfigure_lobby(settings)
	print("LobbyManager: lobby created/reconfigured by ", peer_id, ": ", lobby["name"])
	_join_peer_to_lobby(peer_id, int(lobby["id"]))


func _server_handle_join_lobby(peer_id: int, lobby_id: int, password: String) -> void:
	if not lobbies.has(lobby_id):
		_send_result_to(peer_id, false, "Lobby no longer exists.")
		return

	var lobby: Dictionary = lobbies[lobby_id]
	var members: Array = lobby["members"]

	if lobby_id_by_peer.has(peer_id):
		_send_result_to(peer_id, false, "Already in a lobby.")
		return

	if members.size() >= int(lobby["max_players"]):
		_send_result_to(peer_id, false, "Lobby is full.")
		return

	if String(lobby["password"]) != "" and password != String(lobby["password"]):
		_send_result_to(peer_id, false, "Wrong password.")
		return

	_join_peer_to_lobby(peer_id, lobby_id)


func _join_peer_to_lobby(peer_id: int, lobby_id: int) -> void:
	var lobby: Dictionary = lobbies[lobby_id]
	var members: Array = lobby["members"]

	if not members.has(peer_id):
		members.append(peer_id)

	lobby_id_by_peer[peer_id] = lobby_id

	# Make the joining client's map match the lobby (the server already built its own).
	if peer_id != 1:
		rpc_id(peer_id, "client_apply_map_config", lobby["map"])

	# Spawn them via NetworkManager (assigns the next alternating team slot).
	if network_manager != null and network_manager.has_method("server_spawn_in_lobby"):
		network_manager.call("server_spawn_in_lobby", peer_id, members.duplicate())

	_send_result_to(peer_id, true, "Joined " + String(lobby["name"]) + ".")


func server_on_peer_left(peer_id: int) -> void:
	if not is_server():
		return

	if not lobby_id_by_peer.has(peer_id):
		return

	var lobby_id := int(lobby_id_by_peer[peer_id])
	lobby_id_by_peer.erase(peer_id)

	if lobbies.has(lobby_id):
		var members: Array = lobbies[lobby_id]["members"]
		members.erase(peer_id)


func _create_or_reconfigure_lobby(settings: Dictionary) -> Dictionary:
	var lobby := {
		"id": SINGLE_LOBBY_ID,
		"name": String(settings.get("name", "Server Lobby")),
		"password": String(settings.get("password", "")),
		"max_players": clampi(int(settings.get("max_players", GameLaunch.max_players)), 2, 64),
		"min_players": clampi(int(settings.get("min_players", GameLaunch.min_players_to_start)), 1, 64),
		"starting_cash": maxi(int(settings.get("starting_cash", GameLaunch.starting_cash)), 0),
		"points_to_win": maxi(int(settings.get("points_to_win", GameLaunch.points_to_win)), 1),
		"round_time": maxf(float(settings.get("round_time", GameLaunch.round_time_limit)), 0.0),
		"map": _extract_map_settings(settings),
		"members": [],
	}

	lobbies[SINGLE_LOBBY_ID] = lobby
	_apply_lobby_rules_and_map(lobby)
	return lobby


func _extract_map_settings(settings: Dictionary) -> Dictionary:
	return {
		"id": String(settings.get("map_id", GameLaunch.map_id)),
	}


func _apply_lobby_rules_and_map(lobby: Dictionary) -> void:
	if round_manager != null:
		if round_manager.has_method("server_set_min_players_to_start"):
			round_manager.call("server_set_min_players_to_start", int(lobby["min_players"]))
		if round_manager.has_method("server_set_points_to_win"):
			round_manager.call("server_set_points_to_win", int(lobby["points_to_win"]))
		if round_manager.has_method("server_set_round_time_limit"):
			round_manager.call("server_set_round_time_limit", float(lobby["round_time"]))

	if network_manager != null and network_manager.has_method("server_set_starting_cash"):
		network_manager.call("server_set_starting_cash", int(lobby["starting_cash"]))

	_apply_map_config_to_launch(lobby["map"])
	_rebuild_local_map()


func _apply_map_config_to_launch(map_cfg: Dictionary) -> void:
	GameLaunch.map_configured = true
	GameLaunch.map_id = String(map_cfg.get("id", GameLaunch.map_id))


func _rebuild_local_map() -> void:
	if generated_map == null:
		generated_map = get_node_or_null(generated_map_path)

	if generated_map != null and generated_map.has_method("rebuild_from_launch"):
		generated_map.call("rebuild_from_launch")


@rpc("authority", "reliable")
func client_apply_map_config(map_cfg: Dictionary) -> void:
	_apply_map_config_to_launch(map_cfg)
	_rebuild_local_map()


# --- Lobby list ---------------------------------------------------------------------

func _send_lobby_list_to(peer_id: int) -> void:
	var list := _build_lobby_list()

	if peer_id == 1:
		lobby_list_received.emit(list)
	else:
		rpc_id(peer_id, "client_receive_lobby_list", list)


func _build_lobby_list() -> Array:
	var list: Array = []

	for lobby_id in lobbies.keys():
		var lobby: Dictionary = lobbies[lobby_id]
		var members: Array = lobby["members"]

		list.append({
			"id": int(lobby["id"]),
			"name": String(lobby["name"]),
			"has_password": String(lobby["password"]) != "",
			"players": members.size(),
			"max_players": int(lobby["max_players"]),
			"map": _map_label(lobby["map"]),
			"state": _lobby_state_label(),
		})

	return list


@rpc("authority", "reliable")
func client_receive_lobby_list(list: Array) -> void:
	lobby_list_received.emit(list)


func _send_result_to(peer_id: int, success: bool, message: String) -> void:
	if peer_id == 1:
		lobby_result.emit(success, message)
	else:
		rpc_id(peer_id, "client_lobby_result", success, message)


@rpc("authority", "reliable")
func client_lobby_result(success: bool, message: String) -> void:
	lobby_result.emit(success, message)


# --- Helpers ------------------------------------------------------------------------

func _map_label(map_cfg: Dictionary) -> String:
	return MapGenerator.get_map_name(String(map_cfg.get("id", "")))


func _lobby_state_label() -> String:
	if round_manager == null or not ("state" in round_manager):
		return "waiting"

	match int(round_manager.get("state")):
		1:
			return "countdown"
		2:
			return "in round"
		3:
			return "ended"

	return "waiting"


func _any_lobby_in_progress() -> bool:
	if round_manager == null or not ("state" in round_manager):
		return false

	var state := int(round_manager.get("state"))
	return state == 1 or state == 2   # countdown or active


func _default_lobby_settings() -> Dictionary:
	return {
		"name": "Server Lobby",
		"password": "",
		"max_players": GameLaunch.max_players,
		"min_players": GameLaunch.min_players_to_start,
		"starting_cash": GameLaunch.starting_cash,
		"points_to_win": GameLaunch.points_to_win,
		"round_time": GameLaunch.round_time_limit,
		"map_id": GameLaunch.map_id,
	}
