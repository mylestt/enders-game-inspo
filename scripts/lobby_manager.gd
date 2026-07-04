extends Node
class_name LobbyManager

# Server-authoritative lobby system. Up to MAX_LOBBIES lobbies run CONCURRENTLY, each with
# its own RoundManager session (state machine, scores, mode, rules); every game relay
# (player state, tracers, damage, scoreboard) is scoped to the lobby's members by
# NetworkManager. Clients connect to the server only to BROWSE; they spawn into the world
# only when they JOIN a lobby. A lobby closes when its last member leaves.
#
# All lobbies currently share the server's single loaded map: spawn markers are read from
# scene-tree groups, which can only hold one map at a time, so a created lobby's map is
# forced to the server's active map. Per-lobby maps need per-instance marker lookup.

signal lobby_list_received(lobbies: Array)
signal lobby_result(success: bool, message: String)

@export var network_manager_path: NodePath = NodePath("../NetworkManager")
@export var round_manager_path: NodePath = NodePath("../RoundManager")
@export var generated_map_path: NodePath = NodePath("../GeneratedMap")

const MAX_LOBBIES := 5

var network_manager: Node
var round_manager: Node
var generated_map: Node

var lobbies: Dictionary = {}            # lobby_id -> lobby dict
var lobby_id_by_peer: Dictionary = {}   # peer_id -> lobby_id (only joined/spawned peers)
var next_lobby_id: int = 1


func _ready() -> void:
	network_manager = get_node_or_null(network_manager_path)
	round_manager = get_node_or_null(round_manager_path)
	generated_map = get_node_or_null(generated_map_path)


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

func _server_handle_create_lobby(peer_id: int, settings: Dictionary) -> void:
	if lobby_id_by_peer.has(peer_id):
		_send_result_to(peer_id, false, "Already in a lobby.")
		return

	if lobbies.size() >= MAX_LOBBIES:
		_send_result_to(
			peer_id,
			false,
			"Max lobbies reached (" + str(MAX_LOBBIES) + "/" + str(MAX_LOBBIES) + "). Join an existing lobby or try again later."
		)
		return

	var lobby := _create_lobby(settings)
	print("LobbyManager: lobby ", lobby["id"], " created by ", peer_id, ": ", lobby["name"])
	_join_peer_to_lobby(peer_id, int(lobby["id"]))


func _create_lobby(settings: Dictionary) -> Dictionary:
	var lobby_id := next_lobby_id
	next_lobby_id += 1

	var lobby := {
		"id": lobby_id,
		"name": String(settings.get("name", "Lobby " + str(lobby_id))),
		"password": String(settings.get("password", "")),
		"max_players": clampi(int(settings.get("max_players", GameLaunch.max_players)), 2, 64),
		"min_players": clampi(int(settings.get("min_players", GameLaunch.min_players_to_start)), 1, 64),
		"starting_cash": maxi(int(settings.get("starting_cash", GameLaunch.starting_cash)), 0),
		"points_to_win": maxi(int(settings.get("points_to_win", GameLaunch.points_to_win)), 1),
		"round_time": maxf(float(settings.get("round_time", GameLaunch.round_time_limit)), 0.0),
		"game_mode": GameLaunch.normalize_game_mode(String(settings.get("game_mode", GameLaunch.game_mode_id))),
		"respawn_time": maxf(float(settings.get("respawn_time", GameLaunch.ffa_respawn_time)), 0.5),
		"booster_fuel": maxf(float(settings.get("booster_fuel", GameLaunch.ffa_booster_fuel)), 0.0),
		"ffa_weapons": (settings.get("ffa_weapons", GameLaunch.ffa_weapons) as Array).duplicate(),
		"kill_limit": maxi(int(settings.get("kill_limit", GameLaunch.ffa_kill_limit)), 0),
		"heal_on_kill": bool(settings.get("heal_on_kill", GameLaunch.heal_on_kill)),
		"ammo_on_kill": bool(settings.get("ammo_on_kill", GameLaunch.ammo_on_kill)),
		# Forced to the server's active map — see the header note.
		"map": {"id": GameLaunch.map_id},
		"members": [],
	}

	lobbies[lobby_id] = lobby

	if round_manager != null and round_manager.has_method("server_create_session"):
		round_manager.call("server_create_session", lobby_id, lobby)

	return lobby


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

	# Make the joining client's map match the lobby (skips the rebuild when it's already
	# the same map, which it currently always is).
	if peer_id != 1:
		rpc_id(peer_id, "client_apply_map_config", lobby["map"])

	# Spawn them via NetworkManager (assigns the lobby's next alternating team slot and
	# replicates only to this lobby's members).
	if network_manager != null and network_manager.has_method("server_spawn_in_lobby"):
		network_manager.call("server_spawn_in_lobby", peer_id, members.duplicate(), lobby)

	# Catch the newcomer up on the lobby's mode, score, and round state.
	if peer_id != 1 and round_manager != null and round_manager.has_method("server_sync_session_to_peer"):
		round_manager.call("server_sync_session_to_peer", lobby_id, peer_id)

	_send_result_to(peer_id, true, "Joined " + String(lobby["name"]) + ".")


func server_on_peer_left(peer_id: int) -> void:
	if not is_server():
		return

	if not lobby_id_by_peer.has(peer_id):
		return

	var lobby_id := int(lobby_id_by_peer[peer_id])
	lobby_id_by_peer.erase(peer_id)

	if not lobbies.has(lobby_id):
		return

	var members: Array = lobbies[lobby_id]["members"]
	members.erase(peer_id)

	if members.is_empty():
		_close_lobby(lobby_id)


func _close_lobby(lobby_id: int) -> void:
	lobbies.erase(lobby_id)

	if round_manager != null and round_manager.has_method("server_close_session"):
		round_manager.call("server_close_session", lobby_id)

	print("LobbyManager: lobby ", lobby_id, " closed (empty).")


# --- Lookups used by NetworkManager / RoundManager ----------------------------------

func get_lobby(lobby_id: int) -> Dictionary:
	return lobbies.get(lobby_id, {})


func get_lobby_members(lobby_id: int) -> Array:
	var lobby: Dictionary = lobbies.get(lobby_id, {})
	return (lobby.get("members", []) as Array).duplicate()


func get_lobby_id_for_peer(peer_id: int) -> int:
	return int(lobby_id_by_peer.get(peer_id, -1))


func get_lobby_for_peer(peer_id: int) -> Dictionary:
	return get_lobby(get_lobby_id_for_peer(peer_id))


# --- Map sync ------------------------------------------------------------------------

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
	var new_id := String(map_cfg.get("id", ""))

	if GameLaunch.map_configured and new_id == GameLaunch.map_id:
		return   # already on this map; skip the rebuild

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
			"mode": _mode_label(String(lobby.get("game_mode", "team"))),
			"state": _lobby_state_label(int(lobby["id"])),
		})

	return list


@rpc("authority", "reliable")
func client_receive_lobby_list(list: Array) -> void:
	lobby_list_received.emit(list)


func _send_result_to(peer_id: int, success: bool, message: String) -> void:
	if peer_id == 1:
		lobby_result.emit(success, message)
	elif Array(multiplayer.get_peers()).has(peer_id):
		rpc_id(peer_id, "client_lobby_result", success, message)
	else:
		print("LobbyManager: result for gone peer ", peer_id, ": ", message)


@rpc("authority", "reliable")
func client_lobby_result(success: bool, message: String) -> void:
	lobby_result.emit(success, message)


# --- Helpers ------------------------------------------------------------------------

func _map_label(map_cfg: Dictionary) -> String:
	return MapGenerator.get_map_name(String(map_cfg.get("id", "")))


func _mode_label(mode_id: String) -> String:
	return "FFA" if mode_id == "ffa" else "Team"


func _lobby_state_label(lobby_id: int) -> String:
	if round_manager != null and round_manager.has_method("get_session_state_label"):
		return String(round_manager.call("get_session_state_label", lobby_id))

	return "waiting"
