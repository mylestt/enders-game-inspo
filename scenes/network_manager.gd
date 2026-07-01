extends Node

signal scoreboard_changed(entries: Array)

@export var player_scene: PackedScene
@export var players_parent_path: NodePath
@export var spawn_a_path: NodePath
@export var spawn_b_path: NodePath
@export var buy_menu_path: NodePath

@export var port: int = 7000
@export var max_players: int = 10
@export var default_join_ip: String = "127.0.0.1"
@export var starting_cash: int = 200000

@export var body_slam_server_cooldown: float = 0.2
@export var body_slam_validation_distance: float = 4.0
@export var body_slam_max_impulse: float = 18.0
@export var weapon_hit_damage: float = 15.0
# Anti-cheat clamp: the per-weapon damage a client reports is capped to this server-side.
@export var weapon_hit_max_damage: float = 250.0
@export var weapon_hit_max_range: float = 280.0
@export var weapon_hit_origin_validation_distance: float = 8.0
@export var weapon_hit_target_validation_radius: float = 4.0
@export var weapon_hit_server_cooldown: float = 0.02
@export var weapon_tracer_scene: PackedScene = preload("res://scenes/hitscan_tracer_effect.tscn")

@export_group("Lag Compensation")
# Server-side "backtracking" (CS/Valorant-style). The server records every player's
# recent positions and, when a shot arrives, rewinds the *target* to where it was on the
# *shooter's* screen when they fired (their latency + interpolation buffer), then verifies
# the shot ray actually passed through the target there. Replaces the old "is the hit near
# the target's CURRENT position" guess, which broke for moving targets under any latency.
@export var lag_comp_enabled: bool = true
# How much position history to keep per player (seconds). Caps the furthest rewind.
@export var lag_comp_history_seconds: float = 1.0
# Clients render other players this far in the past for smoothing; rewind must add it back.
# Should roughly match the client interpolation delay (see player network smoothing).
@export var lag_comp_interpolation_delay: float = 0.1
# Manual fudge added to every rewind, for tuning if hits feel slightly behind/ahead.
@export var lag_comp_extra_rewind: float = 0.0
# Never rewind further than this (seconds), even for very high-ping shooters.
@export var lag_comp_max_rewind: float = 1.0
# Effective hit radius around the rewound target position (metres). Approximates the
# player capsule as a sphere for the validation ray-vs-target test.
@export var lag_comp_hitbox_radius: float = 1.2
# Extra slack added to the hitbox radius to absorb interpolation/sampling error.
@export var lag_comp_position_tolerance: float = 0.75
# If a target has no usable history (just spawned, etc.), fall back to its current position
# instead of rejecting the hit outright.
@export var lag_comp_fallback_to_present: bool = true

var players_parent: Node3D
var buy_menu: Node

var players_by_peer_id: Dictionary = {}
var spawn_index_by_peer_id: Dictionary = {}
var player_names_by_peer_id: Dictionary = {}
var player_stats_by_peer_id: Dictionary = {}
var scoreboard_entries: Array = []
var last_body_slam_time_by_pair: Dictionary = {}
var last_weapon_hit_time_by_pair: Dictionary = {}
# peer_id -> Array of { "t": float (server seconds), "pos": Vector3 }, oldest-first.
# Server-only; the lag-compensation backtracking buffer.
var player_state_history: Dictionary = {}

# --- Network diagnostics (F3 overlay + per-round report) ----------------------------
# Measured arrival timing of remote-player state packets AT THIS MACHINE. This is the key
# signal for the "remote player freezes/skips" symptom: irregular arrival shows up here.
var net_diag_last_recv_by_peer: Dictionary = {}        # peer_id -> last receive time (s)
var net_diag_rate_by_peer: Dictionary = {}             # peer_id -> smoothed updates/sec
var net_diag_last_gap_by_peer: Dictionary = {}         # peer_id -> last inter-packet gap (s)
var net_diag_round_max_gap_by_peer: Dictionary = {}    # peer_id -> worst gap this round (s)
var net_diag_overlay: CanvasLayer
var round_manager: Node
# Per-round aggregate accumulator, flushed to a file on round end.
var net_report: Dictionary = {}

# Full per-round telemetry (timeline + events, all players). Server-only; see round_telemetry.gd.
var round_telemetry: Node
# How often a non-server peer reports its own FPS to the server (the one thing the server
# can't observe itself). Small unreliable RPC, negligible next to the position sync.
@export var client_perf_report_interval: float = 0.2
var _client_perf_report_timer: float = 0.0

# Lobby mode: when true (dedicated server), connecting does NOT auto-spawn — players
# spawn only when they join a lobby through LobbyManager.
var lobby_mode: bool = false
var pending_lobby_action: String = ""
var lobby_manager: Node


func _ready() -> void:
	GameLaunch.apply_cmdline_overrides()
	starting_cash = GameLaunch.starting_cash

	players_parent = get_node_or_null(players_parent_path) as Node3D
	buy_menu = get_node_or_null(buy_menu_path)
	lobby_manager = get_node_or_null("../LobbyManager")

	if players_parent == null:
		push_error("NetworkManager could not find Players parent. Assign Players Parent Path.")
	
	if buy_menu == null:
		push_warning("NetworkManager could not find BuyMenu. Assign Buy Menu Path if you want multiplayer buy menu support.")
	
	connect_multiplayer_signals()

	round_manager = get_node_or_null("../RoundManager")

	if round_manager != null and round_manager.has_signal("round_state_changed"):
		round_manager.round_state_changed.connect(_on_round_state_changed_for_report)

	reset_net_report()
	create_network_debug_overlay()
	create_pause_menu()

	print("NetworkManager ready.")
	print("Current multiplayer peer active: ", has_active_multiplayer_peer())

	apply_launch_mode()


# Acts on the choice the start menu recorded. Test Arena runs a true offline solo session
# (no networking); Dedicated Server hosts headless on the VPS; the rest are VPS clients.
func apply_launch_mode() -> void:
	match GameLaunch.consume_mode():
		GameLaunch.Mode.TEST_ARENA:
			print("Launch mode: Test Arena — offline single-player.")
			call_deferred("start_single_player")

		GameLaunch.Mode.DEDICATED_SERVER:
			var server_port := int(GameLaunch.read_cmdline_value("--port", str(port)))
			print("Launch mode: Dedicated server on port ", server_port, ".")
			call_deferred("start_dedicated_server", server_port)

		GameLaunch.Mode.MULTIPLAYER:
			pending_lobby_action = "browse"
			var direct_ip := GameLaunch.join_ip if GameLaunch.join_ip != "" else default_join_ip
			print("Launch mode: Direct join ", direct_ip, ":", port, ".")
			call_deferred("join_game", direct_ip)

		GameLaunch.Mode.MULTIPLAYER_BROWSE:
			pending_lobby_action = "browse"
			var browse_ip := _resolve_server_ip()
			print("Launch mode: Browse lobbies on ", browse_ip, ":", port, ".")
			call_deferred("join_game", browse_ip)

		GameLaunch.Mode.MULTIPLAYER_HOST:
			pending_lobby_action = "host"
			var host_ip := _resolve_server_ip()
			print("Launch mode: Host lobby on ", host_ip, ":", port, ".")
			call_deferred("join_game", host_ip)


func _resolve_server_ip() -> String:
	if GameLaunch.server_ip != "":
		return GameLaunch.server_ip

	if GameLaunch.join_ip != "":
		return GameLaunch.join_ip

	return GameLaunch.DEFAULT_SERVER_IP


# Once connected to a lobby server, do what the menu intended: browse or create.
func _handle_pending_lobby_action() -> void:
	if pending_lobby_action == "":
		return

	if lobby_manager == null:
		lobby_manager = get_node_or_null("../LobbyManager")

	if lobby_manager == null:
		push_warning("No LobbyManager found; cannot run lobby action " + pending_lobby_action + ".")
		pending_lobby_action = ""
		return

	match pending_lobby_action:
		"browse":
			lobby_manager.call("client_request_lobby_list")
		"host":
			lobby_manager.call("client_request_create_lobby", _build_lobby_settings_from_launch())

	pending_lobby_action = ""


func _build_lobby_settings_from_launch() -> Dictionary:
	return {
		"name": GameLaunch.lobby_name if GameLaunch.lobby_name != "" else "Lobby",
		"password": GameLaunch.lobby_password,
		"max_players": GameLaunch.max_players,
		"min_players": GameLaunch.min_players_to_start,
		"starting_cash": GameLaunch.starting_cash,
		"points_to_win": GameLaunch.points_to_win,
		"round_time": GameLaunch.round_time_limit,
		"map_id": GameLaunch.map_id,
	}


# Hosts an authoritative server with NO local player. Peer 1 (this process) only runs
# the simulation and RoundManager; all real players are remote clients that join.
func start_dedicated_server(server_port: int = port) -> void:
	if has_active_multiplayer_peer():
		print("Already connected to a multiplayer peer; not starting dedicated server.")
		return

	clear_runtime_multiplayer_state()

	lobby_mode = true

	var peer := ENetMultiplayerPeer.new()
	# Server is not a player, so all max_players slots are available to clients.
	var error := peer.create_server(server_port, max_players)

	if error != OK:
		push_error("Failed to start dedicated server. Error: " + str(error))
		multiplayer.multiplayer_peer = null
		return

	multiplayer.multiplayer_peer = peer

	create_round_telemetry()

	print("Dedicated server listening on port ", server_port, ". Waiting for clients.")


# The full multi-player telemetry recorder only makes sense on the actual dedicated server
# (the one place with a view of every connected player), so it's created here rather than
# unconditionally in _ready like the F3 overlay / pause menu.
func create_round_telemetry() -> void:
	if round_telemetry != null:
		return

	round_telemetry = preload("res://scripts/round_telemetry.gd").new()
	add_child(round_telemetry)
	round_telemetry.call("setup", self)


func connect_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func has_active_multiplayer_peer() -> bool:
	var peer := multiplayer.multiplayer_peer
	
	if peer == null:
		return false
	
	if peer is OfflineMultiplayerPeer:
		return false
	
	var status := peer.get_connection_status()
	
	return (
		status == MultiplayerPeer.CONNECTION_CONNECTING
		or status == MultiplayerPeer.CONNECTION_CONNECTED
	)


# Offline solo Test Arena: no ENet peer at all. Spawns just the local player so you can
# fly and shoot. RoundManager stays dormant (its is_server() is false with no peer).
func start_single_player() -> void:
	clear_runtime_multiplayer_state()
	lobby_mode = false

	ensure_player_metadata(1, GameLaunch.player_username)
	spawn_index_by_peer_id[1] = 0
	client_spawn_player(1, 0, starting_cash, get_player_name(1))

	print("Single-player Test Arena started.")


func join_game(ip: String) -> void:
	if has_active_multiplayer_peer():
		print("Already connected to an active multiplayer peer.")
		print("Peer type: ", multiplayer.multiplayer_peer.get_class())
		print("Peer status: ", multiplayer.multiplayer_peer.get_connection_status())
		return
	
	clear_runtime_multiplayer_state()
	
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(ip, port)
	
	if error != OK:
		push_error("Failed to join game. Error: " + str(error))
		multiplayer.multiplayer_peer = null
		return
	
	multiplayer.multiplayer_peer = peer
	
	print("Joining ", ip, ":", port)


func clear_runtime_multiplayer_state() -> void:
	for existing_peer_id in players_by_peer_id.keys():
		var existing_player = players_by_peer_id[existing_peer_id]
		
		if is_instance_valid(existing_player):
			existing_player.queue_free()
	
	players_by_peer_id.clear()
	spawn_index_by_peer_id.clear()
	player_names_by_peer_id.clear()
	player_stats_by_peer_id.clear()
	scoreboard_entries.clear()
	scoreboard_changed.emit(scoreboard_entries)
	last_body_slam_time_by_pair.clear()
	last_weapon_hit_time_by_pair.clear()
	player_state_history.clear()

	var peer := multiplayer.multiplayer_peer
	
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	
	multiplayer.multiplayer_peer = null


func _on_connected_to_server() -> void:
	print("Connected to server. My peer id: ", multiplayer.get_unique_id())
	rpc_id(1, "server_register_player_name", GameLaunch.player_username)
	call_deferred("_handle_pending_lobby_action")


func _on_connection_failed() -> void:
	push_error("Connection failed.")
	clear_runtime_multiplayer_state()


func _on_server_disconnected() -> void:
	print("Disconnected from server.")
	clear_runtime_multiplayer_state()


@rpc("any_peer", "reliable")
func server_register_player_name(player_name: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	if sender_id == 0:
		return

	ensure_player_metadata(sender_id, player_name)
	server_broadcast_scoreboard()


func _on_peer_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("Peer connected: ", peer_id)
	ensure_player_metadata(peer_id)

	# Lobby servers don't auto-spawn; the player spawns when they join a lobby.
	if lobby_mode:
		server_broadcast_scoreboard()
		return

	for existing_peer_id in spawn_index_by_peer_id.keys():
		rpc_id(
			peer_id,
			"client_spawn_player",
			int(existing_peer_id),
			int(spawn_index_by_peer_id[existing_peer_id]),
			starting_cash,
			get_player_name(int(existing_peer_id))
		)

	var spawn_index := spawn_index_by_peer_id.size()
	spawn_index_by_peer_id[peer_id] = spawn_index

	rpc("client_spawn_player", peer_id, spawn_index, starting_cash, get_player_name(peer_id))
	server_broadcast_scoreboard()


# Called by LobbyManager when a player joins a lobby: assigns the next alternating
# team slot (even=A, odd=B → 1v1 at 2, 2v1 at 3, 2v2 at 4) and replicates the spawn
# only to that lobby's members.
func server_spawn_in_lobby(peer_id: int, members: Array) -> void:
	if not multiplayer.is_server():
		return

	if players_by_peer_id.has(peer_id):
		return

	ensure_player_metadata(peer_id)

	# Send already-spawned lobby players to the newcomer.
	for existing_peer_id in spawn_index_by_peer_id.keys():
		rpc_id(
			peer_id,
			"client_spawn_player",
			int(existing_peer_id),
			int(spawn_index_by_peer_id[existing_peer_id]),
			starting_cash,
			get_player_name(int(existing_peer_id))
		)

	var spawn_index := spawn_index_by_peer_id.size()
	spawn_index_by_peer_id[peer_id] = spawn_index

	# Server's authoritative copy.
	client_spawn_player(peer_id, spawn_index, starting_cash, get_player_name(peer_id))

	# Replicate the newcomer to every other lobby member (clients).
	for member in members:
		var member_id := int(member)

		if member_id != 1 and member_id != peer_id:
			rpc_id(member_id, "client_spawn_player", peer_id, spawn_index, starting_cash, get_player_name(peer_id))

	# And give the newcomer their own player.
	if peer_id != 1:
		rpc_id(peer_id, "client_spawn_player", peer_id, spawn_index, starting_cash, get_player_name(peer_id))

	server_broadcast_scoreboard()


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	spawn_index_by_peer_id.erase(peer_id)
	player_names_by_peer_id.erase(peer_id)
	player_stats_by_peer_id.erase(peer_id)
	player_state_history.erase(peer_id)
	clear_body_slam_pairs_for_peer(peer_id)

	if lobby_manager != null and lobby_manager.has_method("server_on_peer_left"):
		lobby_manager.call("server_on_peer_left", peer_id)

	rpc("client_remove_player", peer_id)
	server_broadcast_scoreboard()


func clear_body_slam_pairs_for_peer(peer_id: int) -> void:
	var keys_to_remove: Array = []
	
	for key in last_body_slam_time_by_pair.keys():
		var key_text := String(key)
		
		if key_text.begins_with(str(peer_id) + "_") or key_text.ends_with("_" + str(peer_id)):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		last_body_slam_time_by_pair.erase(key)
	
	keys_to_remove.clear()
	
	for key in last_weapon_hit_time_by_pair.keys():
		var key_text := String(key)
		
		if key_text.begins_with(str(peer_id) + "_") or key_text.ends_with("_" + str(peer_id)):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		last_weapon_hit_time_by_pair.erase(key)


# This machine's peer id. In offline single-player there is no peer, so the sole local
# player is peer 1 (asking multiplayer.get_unique_id() with no peer warns and fails).
func get_local_peer_id() -> int:
	if has_active_multiplayer_peer():
		return multiplayer.get_unique_id()

	return 1


# This machine's own player node, or null if not spawned yet.
func get_local_player() -> Node:
	return players_by_peer_id.get(get_local_peer_id(), null)


# Server-side: forcibly disconnect a client (admin "kick"). Returns true if it ran.
func server_kick_peer(peer_id: int) -> bool:
	if not multiplayer.is_server() or peer_id == 1:
		return false

	var mp := multiplayer.multiplayer_peer

	if mp is ENetMultiplayerPeer:
		(mp as ENetMultiplayerPeer).disconnect_peer(peer_id)
		return true

	return false


@rpc("authority", "call_local", "reliable")
func client_spawn_player(
	peer_id: int,
	spawn_index: int,
	server_starting_cash: int = -1,
	player_name: String = ""
) -> void:
	if players_parent == null:
		players_parent = get_node_or_null(players_parent_path) as Node3D
	
	if players_parent == null:
		push_error("Players parent is missing.")
		return
	
	if player_scene == null:
		push_error("Player Scene is missing on NetworkManager.")
		return
	
	if players_by_peer_id.has(peer_id):
		return

	ensure_player_metadata(peer_id, player_name)
	
	var player := player_scene.instantiate()
	player.name = "Player_" + str(peer_id)
	players_parent.add_child(player)
	
	if player is Node3D:
		player.global_transform = get_spawn_transform(spawn_index)
		player.reset_physics_interpolation()
	
	var is_local := peer_id == get_local_peer_id()
	
	if player.has_method("set_multiplayer_player"):
		player.call("set_multiplayer_player", peer_id, is_local, self)
	
	players_by_peer_id[peer_id] = player

	if round_telemetry != null and player is Node3D:
		round_telemetry.call("record_player_spawned", peer_id, (player as Node3D).global_position)

	if is_local:
		call_deferred("bind_local_player_to_buy_menu", player, server_starting_cash)
	
	print("Spawned player ", peer_id, ". Local: ", is_local)


func bind_local_player_to_buy_menu(player: Node, server_starting_cash: int = -1) -> void:
	if buy_menu == null:
		buy_menu = get_node_or_null(buy_menu_path)
	
	if buy_menu == null:
		push_warning("No BuyMenu found, so local player was not assigned to a buy menu.")
		return
	
	if buy_menu.has_method("set_local_player"):
		buy_menu.call("set_local_player", player)
		
		if server_starting_cash >= 0 and buy_menu.has_method("set_starting_cash"):
			buy_menu.call("set_starting_cash", server_starting_cash)
		
		print("BuyMenu assigned to local player: ", player.name)
	else:
		push_warning("BuyMenu does not have set_local_player(). Make sure you are using the multiplayer buy_menu.gd.")


@rpc("authority", "call_local", "reliable")
func client_remove_player(peer_id: int) -> void:
	if not players_by_peer_id.has(peer_id):
		return
	
	var player: Node = players_by_peer_id[peer_id]
	
	if is_instance_valid(player):
		player.queue_free()
	
	players_by_peer_id.erase(peer_id)
	spawn_index_by_peer_id.erase(peer_id)
	player_names_by_peer_id.erase(peer_id)
	player_stats_by_peer_id.erase(peer_id)
	
	print("Removed player ", peer_id)


func get_spawn_transform(spawn_index: int) -> Transform3D:
	# Even indices = team A, odd = team B; the integer half is the slot within that
	# team. This alternates teams (so the first 2 players land one-per-side) and spreads
	# players across the map's 5 spawns per side.
	var team := "a" if spawn_index % 2 == 0 else "b"
	var slot := int(spawn_index / 2)

	var markers := get_team_spawn_markers(team)

	if markers.size() > 0:
		var marker := markers[slot % markers.size()] as Node3D

		if marker != null:
			return marker.global_transform

	# Fallback to the two primary markers if the map's spawn groups aren't present.
	var spawn_node: Node3D

	if team == "a":
		spawn_node = get_node_or_null(spawn_a_path) as Node3D
	else:
		spawn_node = get_node_or_null(spawn_b_path) as Node3D

	if spawn_node != null:
		return spawn_node.global_transform

	var fallback_position := Vector3(float(spawn_index) * 6.0, 0.0, 0.0)
	return Transform3D(Basis.IDENTITY, fallback_position)


func get_team_spawn_markers(team: String) -> Array:
	var markers := get_tree().get_nodes_in_group("spawn_team_" + team)
	markers.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return markers


# Team from the alternating spawn slot: even = A, odd = B.
func get_team_for_peer(peer_id: int) -> String:
	var spawn_index := int(spawn_index_by_peer_id.get(peer_id, 0))
	return "a" if spawn_index % 2 == 0 else "b"


func ensure_player_metadata(peer_id: int, player_name: String = "") -> void:
	if player_name.strip_edges() != "":
		player_names_by_peer_id[peer_id] = GameLaunch.sanitize_username(player_name)
	elif not player_names_by_peer_id.has(peer_id):
		player_names_by_peer_id[peer_id] = "Player " + str(peer_id)

	if not player_stats_by_peer_id.has(peer_id):
		player_stats_by_peer_id[peer_id] = {
			"kills": 0,
			"deaths": 0,
		}


func get_player_name(peer_id: int) -> String:
	if player_names_by_peer_id.has(peer_id):
		return String(player_names_by_peer_id[peer_id])

	return "Player " + str(peer_id)


func get_scoreboard_entries() -> Array:
	return scoreboard_entries.duplicate(true)


func server_record_player_death(dead_peer_id: int, attacker_peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	if round_telemetry != null:
		round_telemetry.call("record_player_died", dead_peer_id, attacker_peer_id)

	ensure_player_metadata(dead_peer_id)
	var dead_stats: Dictionary = player_stats_by_peer_id[dead_peer_id]
	dead_stats["deaths"] = int(dead_stats.get("deaths", 0)) + 1
	player_stats_by_peer_id[dead_peer_id] = dead_stats

	if attacker_peer_id != 0 and attacker_peer_id != dead_peer_id:
		ensure_player_metadata(attacker_peer_id)
		var attacker_stats: Dictionary = player_stats_by_peer_id[attacker_peer_id]
		attacker_stats["kills"] = int(attacker_stats.get("kills", 0)) + 1
		player_stats_by_peer_id[attacker_peer_id] = attacker_stats

	server_broadcast_scoreboard()


func server_reset_player_stats() -> void:
	if not multiplayer.is_server():
		return

	for peer_id in player_stats_by_peer_id.keys():
		player_stats_by_peer_id[peer_id] = {
			"kills": 0,
			"deaths": 0,
		}

	server_broadcast_scoreboard()


func server_broadcast_scoreboard() -> void:
	if not multiplayer.is_server():
		return

	var entries := build_scoreboard_entries()
	client_sync_scoreboard(entries)

	for remote_peer_id in multiplayer.get_peers():
		rpc_id(remote_peer_id, "client_sync_scoreboard", entries)


func build_scoreboard_entries() -> Array:
	var entries: Array = []

	for peer_id in players_by_peer_id.keys():
		var id := int(peer_id)
		ensure_player_metadata(id)

		var stats: Dictionary = player_stats_by_peer_id[id]
		var player = players_by_peer_id[peer_id]
		var alive := true

		if player != null:
			var health := player.get_node_or_null("PlayerHealth") as PlayerHealth

			if health != null:
				alive = health.current_health > 0.0

		entries.append({
			"peer_id": id,
			"name": get_player_name(id),
			"team": get_team_for_peer(id),
			"kills": int(stats.get("kills", 0)),
			"deaths": int(stats.get("deaths", 0)),
			"alive": alive,
		})

	entries.sort_custom(Callable(self, "_sort_scoreboard_entries"))
	return entries


func _sort_scoreboard_entries(a: Dictionary, b: Dictionary) -> bool:
	var team_a := String(a.get("team", "a"))
	var team_b := String(b.get("team", "a"))

	if team_a != team_b:
		return team_a < team_b

	var kills_a := int(a.get("kills", 0))
	var kills_b := int(b.get("kills", 0))

	if kills_a != kills_b:
		return kills_a > kills_b

	var deaths_a := int(a.get("deaths", 0))
	var deaths_b := int(b.get("deaths", 0))

	if deaths_a != deaths_b:
		return deaths_a < deaths_b

	return String(a.get("name", "")) < String(b.get("name", ""))


@rpc("authority", "reliable")
func client_sync_scoreboard(new_entries: Array) -> void:
	scoreboard_entries = new_entries.duplicate(true)
	scoreboard_changed.emit(scoreboard_entries)


func server_set_starting_cash(amount: int) -> void:
	if not multiplayer.is_server():
		return

	starting_cash = maxi(amount, 0)


func server_set_player_cash(peer_id: int, amount: int) -> bool:
	if not multiplayer.is_server():
		return false

	if peer_id != 1 and not players_by_peer_id.has(peer_id):
		return false

	if peer_id == multiplayer.get_unique_id():
		client_admin_set_cash(amount)
	else:
		rpc_id(peer_id, "client_admin_set_cash", amount)

	return true


func server_add_player_cash(peer_id: int, amount: int) -> bool:
	if not multiplayer.is_server():
		return false

	if peer_id != 1 and not players_by_peer_id.has(peer_id):
		return false

	if peer_id == multiplayer.get_unique_id():
		client_admin_add_cash(amount)
	else:
		rpc_id(peer_id, "client_admin_add_cash", amount)

	return true


func get_player_summary() -> String:
	if players_by_peer_id.is_empty():
		return "Players: none"

	var parts: Array[String] = []

	for peer_id in players_by_peer_id.keys():
		var spawn_index := int(spawn_index_by_peer_id.get(peer_id, -1))
		parts.append(
			str(peer_id)
			+ " name=\""
			+ get_player_name(int(peer_id))
			+ "\" team="
			+ get_team_for_peer(int(peer_id)).to_upper()
			+ " spawn="
			+ str(spawn_index)
		)

	return "Players: " + ", ".join(parts)


func submit_local_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3
) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	
	if multiplayer.is_server():
		server_record_state_history(peer_id, player_transform.origin)
		client_receive_player_state(peer_id, player_transform, linear_velocity, angular_velocity)
		rpc("client_receive_player_state", peer_id, player_transform, linear_velocity, angular_velocity)
	else:
		rpc_id(
			1,
			"server_receive_player_state",
			peer_id,
			player_transform,
			linear_velocity,
			angular_velocity
		)


@rpc("any_peer", "unreliable")
func server_receive_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	
	var sender_id := multiplayer.get_remote_sender_id()

	if sender_id != peer_id:
		return

	server_record_state_history(peer_id, player_transform.origin)
	client_receive_player_state(peer_id, player_transform, linear_velocity, angular_velocity)
	rpc("client_receive_player_state", peer_id, player_transform, linear_velocity, angular_velocity)


@rpc("authority", "unreliable")
func client_receive_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3
) -> void:
	if peer_id == multiplayer.get_unique_id():
		return

	track_incoming_state_timing(peer_id)

	if not players_by_peer_id.has(peer_id):
		return

	var player = players_by_peer_id[peer_id]

	if player != null and player.has_method("receive_network_state"):
		player.call("receive_network_state", player_transform, linear_velocity, angular_velocity)


func request_body_slam(
	attacker_peer_id: int,
	target_peer_id: int,
	impulse: Vector3,
	contact_position: Vector3
) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	
	if multiplayer.is_server():
		server_process_body_slam(attacker_peer_id, target_peer_id, impulse, contact_position)
	else:
		rpc_id(1, "server_request_body_slam", target_peer_id, impulse, contact_position)


@rpc("any_peer", "reliable")
func server_request_body_slam(
	target_peer_id: int,
	impulse: Vector3,
	contact_position: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	
	var attacker_peer_id := multiplayer.get_remote_sender_id()
	server_process_body_slam(attacker_peer_id, target_peer_id, impulse, contact_position)


func server_process_body_slam(
	attacker_peer_id: int,
	target_peer_id: int,
	impulse: Vector3,
	contact_position: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	
	if attacker_peer_id == target_peer_id:
		return
	
	if not players_by_peer_id.has(attacker_peer_id):
		return
	
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var attacker: Node3D = players_by_peer_id[attacker_peer_id] as Node3D
	var target: Node3D = players_by_peer_id[target_peer_id] as Node3D
	
	if attacker == null or target == null:
		return
	
	if attacker.global_position.distance_to(target.global_position) > body_slam_validation_distance:
		return
	
	var pair_key := str(attacker_peer_id) + "_" + str(target_peer_id)
	var current_time := Time.get_ticks_msec() / 1000.0
	
	if last_body_slam_time_by_pair.has(pair_key):
		var last_time: float = last_body_slam_time_by_pair[pair_key]
		
		if current_time - last_time < body_slam_server_cooldown:
			return
	
	last_body_slam_time_by_pair[pair_key] = current_time
	
	var clamped_impulse := impulse
	
	if clamped_impulse.length() > body_slam_max_impulse:
		clamped_impulse = clamped_impulse.normalized() * body_slam_max_impulse
	
	rpc("client_apply_body_slam_impulse", target_peer_id, clamped_impulse, contact_position)
	
	print("Body slam: ", attacker_peer_id, " shoved ", target_peer_id, " impulse ", clamped_impulse)


@rpc("authority", "call_local", "reliable")
func client_apply_body_slam_impulse(
	target_peer_id: int,
	impulse: Vector3,
	contact_position: Vector3
) -> void:
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var target = players_by_peer_id[target_peer_id]
	
	if target != null and target.has_method("apply_network_body_slam_impulse"):
		target.call("apply_network_body_slam_impulse", impulse, contact_position)


func request_weapon_hit(
	attacker_peer_id: int,
	target_peer_id: int,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		server_process_weapon_hit(
			attacker_peer_id,
			target_peer_id,
			damage,
			hit_position,
			shot_origin,
			shot_direction
		)
	else:
		rpc_id(
			1,
			"server_request_weapon_hit",
			target_peer_id,
			damage,
			hit_position,
			shot_origin,
			shot_direction
		)


@rpc("any_peer", "reliable")
func server_request_weapon_hit(
	target_peer_id: int,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> void:
	if not multiplayer.is_server():
		return

	var attacker_peer_id := multiplayer.get_remote_sender_id()
	server_process_weapon_hit(
		attacker_peer_id,
		target_peer_id,
		damage,
		hit_position,
		shot_origin,
		shot_direction
	)


func server_process_weapon_hit(
	attacker_peer_id: int,
	target_peer_id: int,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	
	if attacker_peer_id == target_peer_id:
		return
	
	if not players_by_peer_id.has(attacker_peer_id):
		return
	
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var attacker := players_by_peer_id[attacker_peer_id] as Node3D
	var target := players_by_peer_id[target_peer_id] as Node3D
	
	if attacker == null or target == null:
		return
	
	if not can_process_weapon_hit_pair(attacker_peer_id, target_peer_id):
		return
	
	if not is_weapon_hit_plausible(
		attacker_peer_id,
		target_peer_id,
		attacker,
		target,
		hit_position,
		shot_origin,
		shot_direction
	):
		return
	
	mark_weapon_hit_pair(attacker_peer_id, target_peer_id)

	# Use the weapon's own damage (clamped server-side so a client can't report an absurd value).
	var applied_damage := clampf(damage, 0.0, weapon_hit_max_damage)
	rpc("client_apply_weapon_damage", target_peer_id, attacker_peer_id, applied_damage)

	print(
		"Weapon hit: ",
		attacker_peer_id,
		" -> ",
		target_peer_id,
		" damage ",
		applied_damage
	)


func can_process_weapon_hit_pair(attacker_peer_id: int, target_peer_id: int) -> bool:
	var pair_key := str(attacker_peer_id) + "_" + str(target_peer_id)
	var current_time := Time.get_ticks_msec() / 1000.0
	
	if last_weapon_hit_time_by_pair.has(pair_key):
		var last_time: float = last_weapon_hit_time_by_pair[pair_key]
		
		if current_time - last_time < weapon_hit_server_cooldown:
			return false
	
	return true


func mark_weapon_hit_pair(attacker_peer_id: int, target_peer_id: int) -> void:
	var pair_key := str(attacker_peer_id) + "_" + str(target_peer_id)
	last_weapon_hit_time_by_pair[pair_key] = Time.get_ticks_msec() / 1000.0


func is_weapon_hit_plausible(
	attacker_peer_id: int,
	target_peer_id: int,
	attacker: Node3D,
	target: Node3D,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> bool:
	if shot_direction.length() < 0.001:
		return false

	# Sanity: the shot must originate near the attacker and stay within weapon range.
	if shot_origin.distance_to(attacker.global_position) > weapon_hit_origin_validation_distance:
		return false

	if shot_origin.distance_to(hit_position) > weapon_hit_max_range:
		return false

	if not lag_comp_enabled:
		# Legacy path: just check the claimed hit point is near the target's CURRENT position.
		return target.global_position.distance_to(hit_position) <= weapon_hit_target_validation_radius

	# Lag-compensated path: rewind the target to where it was on the shooter's screen, then
	# verify the shot ray actually passed through it there.
	var rewind_seconds := compute_rewind_for_peer(attacker_peer_id)
	# Untyped on purpose: get_rewound_position returns either a Vector3 or null.
	var rewound_position = get_rewound_position(target_peer_id, rewind_seconds)

	if rewound_position == null:
		if not lag_comp_fallback_to_present:
			return false
		rewound_position = target.global_position

	return ray_passes_through_target(shot_origin, shot_direction, rewound_position)


# Records one position sample for a player into the backtracking buffer and trims anything
# older than lag_comp_history_seconds. Server-only.
func server_record_state_history(peer_id: int, position: Vector3) -> void:
	if not lag_comp_enabled or not multiplayer.is_server():
		return

	var now := Time.get_ticks_msec() / 1000.0
	var history: Array = player_state_history.get(peer_id, [])
	history.append({ "t": now, "pos": position })

	var cutoff := now - lag_comp_history_seconds

	while history.size() > 1 and float(history[0]["t"]) < cutoff:
		history.pop_front()

	player_state_history[peer_id] = history


# How far back (seconds) to rewind the world for this shooter: their round-trip latency plus
# the client interpolation delay, clamped to the buffer length.
func compute_rewind_for_peer(peer_id: int) -> float:
	var rewind := get_peer_rtt_seconds(peer_id) + lag_comp_interpolation_delay + lag_comp_extra_rewind
	return clampf(rewind, 0.0, minf(lag_comp_max_rewind, lag_comp_history_seconds))


# Smoothed round-trip time (seconds) for a peer from ENet. The host's own player (peer 1)
# has no network delay. Falls back to 0 if statistics are unavailable.
func get_peer_rtt_seconds(peer_id: int) -> float:
	if peer_id == 1:
		return 0.0

	var mp := multiplayer.multiplayer_peer

	if mp is ENetMultiplayerPeer:
		var enet_peer := (mp as ENetMultiplayerPeer).get_peer(peer_id)

		if enet_peer != null:
			return enet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) / 1000.0

	return 0.0


# Returns the target's interpolated position rewind_seconds in the past, or null if there is
# no usable history.
func get_rewound_position(peer_id: int, rewind_seconds: float):
	var history: Array = player_state_history.get(peer_id, [])

	if history.is_empty():
		return null

	var target_time := (Time.get_ticks_msec() / 1000.0) - rewind_seconds

	# Newer than the most recent sample (e.g. tiny rewind): use the latest position.
	var newest: Dictionary = history[history.size() - 1]

	if target_time >= float(newest["t"]):
		return newest["pos"] as Vector3

	# Older than anything we kept: clamp to the oldest sample.
	var oldest: Dictionary = history[0]

	if target_time <= float(oldest["t"]):
		return oldest["pos"] as Vector3

	# Find the two samples bracketing target_time and lerp between them.
	for i in range(history.size() - 1):
		var a: Dictionary = history[i]
		var b: Dictionary = history[i + 1]
		var ta := float(a["t"])
		var tb := float(b["t"])

		if target_time >= ta and target_time <= tb:
			var span := tb - ta

			if span <= 0.0001:
				return b["pos"] as Vector3

			var f := (target_time - ta) / span
			return (a["pos"] as Vector3).lerp(b["pos"] as Vector3, f)

	return newest["pos"] as Vector3


# Ray-vs-sphere test: did the shot, fired from shot_origin along shot_direction, pass within
# the (approximated) target capsule around target_position, in front of the shooter and in range?
func ray_passes_through_target(
	shot_origin: Vector3,
	shot_direction: Vector3,
	target_position: Vector3
) -> bool:
	var dir := shot_direction.normalized()
	var to_target := target_position - shot_origin
	var along := to_target.dot(dir)

	# Target is behind the shooter or beyond weapon range.
	if along < 0.0 or along > weapon_hit_max_range:
		return false

	var closest_point := shot_origin + dir * along
	var miss_distance := closest_point.distance_to(target_position)
	var hit_radius := lag_comp_hitbox_radius + lag_comp_position_tolerance

	return miss_distance <= hit_radius


@rpc("authority", "call_local", "reliable")
func client_apply_weapon_damage(
	target_peer_id: int,
	attacker_peer_id: int,
	damage: float
) -> void:
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var target = players_by_peer_id[target_peer_id]
	var killed := false

	if target != null and target.has_method("apply_weapon_damage"):
		# Capture alive-state first so only the actual killing blow (alive -> dead) reads as a
		# kill — shots that land on an already-down corpse stay a normal hit.
		var was_alive: bool = target.get("is_dead") != true
		target.call("apply_weapon_damage", damage, attacker_peer_id)
		killed = was_alive and target.get("is_dead") == true

	# Hit feedback: only the attacker's own client shows the hitmarker (red on a kill).
	if attacker_peer_id == multiplayer.get_unique_id() and players_by_peer_id.has(attacker_peer_id):
		var attacker = players_by_peer_id[attacker_peer_id]

		if attacker != null and attacker.has_method("show_hitmarker"):
			attacker.call("show_hitmarker", killed)


@rpc("authority", "call_local", "reliable")
func client_admin_set_cash(amount: int) -> void:
	if buy_menu == null:
		buy_menu = get_node_or_null(buy_menu_path)

	if buy_menu != null and buy_menu.has_method("admin_set_cash"):
		buy_menu.call("admin_set_cash", amount)


@rpc("authority", "call_local", "reliable")
func client_admin_add_cash(amount: int) -> void:
	if buy_menu == null:
		buy_menu = get_node_or_null(buy_menu_path)

	if buy_menu != null and buy_menu.has_method("admin_add_cash"):
		buy_menu.call("admin_add_cash", amount)


# --- Weapon shot tracer replication ------------------------------------------------
# The shooter already drew its own tracer locally; this relays the shot so every OTHER
# client draws the same streak. Unreliable on purpose — tracers are cosmetic.

func broadcast_weapon_shot(
	shooter_peer_id: int,
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3
) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_relay_weapon_shot(shooter_peer_id, origin, shot_end, did_hit, normal)
	else:
		rpc_id(1, "server_relay_weapon_shot", origin, shot_end, did_hit, normal)


@rpc("any_peer", "unreliable")
func server_relay_weapon_shot(
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3
) -> void:
	if not multiplayer.is_server():
		return

	_relay_weapon_shot(multiplayer.get_remote_sender_id(), origin, shot_end, did_hit, normal)


func _relay_weapon_shot(
	shooter_peer_id: int,
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3
) -> void:
	if round_telemetry != null:
		round_telemetry.call("record_weapon_fired", shooter_peer_id, origin, did_hit)

	for peer_id in multiplayer.get_peers():
		if peer_id != shooter_peer_id:
			rpc_id(peer_id, "client_play_weapon_shot", origin, shot_end, did_hit, normal)


@rpc("authority", "unreliable")
func client_play_weapon_shot(
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3
) -> void:
	if weapon_tracer_scene == null:
		return

	var scene := get_tree().current_scene

	if scene == null:
		return

	var parent := scene.get_node_or_null("WeaponEffects")

	if parent == null:
		parent = scene

	var tracer := weapon_tracer_scene.instantiate()
	parent.add_child(tracer)

	if tracer.has_method("play"):
		tracer.call("play", origin, shot_end, did_hit, normal)


# === Network diagnostics ============================================================
# An F3 overlay of live connection stats, plus a per-round report file written to
# user://net_reports/. Each machine measures its OWN view, so the laggy end's report is the
# one that matters. "remote update" timings are how smoothly other players' packets arrive
# here — the direct measure of the freeze/skip symptom.

func _process(delta: float) -> void:
	if not has_active_multiplayer_peer():
		return

	accumulate_net_report(delta)
	_tick_client_perf_report(delta)


# Periodically sends this client's own FPS to the server — the one performance signal the
# server can't observe itself (it doesn't render). Small unreliable RPC, a few times a
# second; negligible next to the 30Hz per-player position sync. No-op on the server itself.
func _tick_client_perf_report(delta: float) -> void:
	if multiplayer.is_server():
		return

	# Only after the handshake completes — during the ~1s connecting window the peer exists
	# but rpc_id(1, ...) would error ("multiplayer peer which is not connected").
	var peer := multiplayer.multiplayer_peer

	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	_client_perf_report_timer -= delta

	if _client_perf_report_timer > 0.0:
		return

	_client_perf_report_timer = client_perf_report_interval
	rpc_id(1, "server_receive_client_perf", Engine.get_frames_per_second())


@rpc("any_peer", "unreliable")
func server_receive_client_perf(fps: float) -> void:
	if not multiplayer.is_server() or round_telemetry == null:
		return

	round_telemetry.call("record_client_fps", multiplayer.get_remote_sender_id(), fps)


# Records how regularly state packets for a remote player arrive at this machine.
func track_incoming_state_timing(peer_id: int) -> void:
	var now := Time.get_ticks_msec() / 1000.0

	if net_diag_last_recv_by_peer.has(peer_id):
		var gap: float = now - float(net_diag_last_recv_by_peer[peer_id])
		net_diag_last_gap_by_peer[peer_id] = gap

		var instant_hz := 1.0 / maxf(gap, 0.0001)
		var previous_hz: float = net_diag_rate_by_peer.get(peer_id, instant_hz)
		net_diag_rate_by_peer[peer_id] = lerpf(previous_hz, instant_hz, 0.1)

		var worst: float = net_diag_round_max_gap_by_peer.get(peer_id, 0.0)

		if gap > worst:
			net_diag_round_max_gap_by_peer[peer_id] = gap

	net_diag_last_recv_by_peer[peer_id] = now


# The remote endpoints whose ENet stats are meaningful here: every client (if we are the
# server) or just the server (if we are a client).
func diag_connection_peers() -> Array:
	if not has_active_multiplayer_peer():
		return []

	if multiplayer.is_server():
		return Array(multiplayer.get_peers())

	return [1]


func get_enet_peer_stat(peer_id: int, statistic: ENetPacketPeer.PeerStatistic) -> float:
	var mp := multiplayer.multiplayer_peer

	if mp is ENetMultiplayerPeer:
		var enet_peer := (mp as ENetMultiplayerPeer).get_peer(peer_id)

		if enet_peer != null:
			return enet_peer.get_statistic(statistic)

	return -1.0


func net_role_name() -> String:
	if not has_active_multiplayer_peer():
		return "Offline"

	if multiplayer.is_server():
		return "Headless Server" if DisplayServer.get_name() == "headless" else "Listen Host"

	return "Client"


func connection_stat_entry(peer_id: int) -> Dictionary:
	var loss := get_enet_peer_stat(peer_id, ENetPacketPeer.PEER_PACKET_LOSS)
	var loss_pct := 0.0

	if loss >= 0.0:
		loss_pct = (loss / float(ENetPacketPeer.PACKET_LOSS_SCALE)) * 100.0

	return {
		"peer_id": peer_id,
		"rtt_ms": get_enet_peer_stat(peer_id, ENetPacketPeer.PEER_ROUND_TRIP_TIME),
		"rtt_var_ms": get_enet_peer_stat(peer_id, ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
		"loss_pct": loss_pct,
	}


# Live snapshot consumed by the F3 overlay.
func get_network_debug_stats() -> Dictionary:
	var connections: Array = []

	for peer_id in diag_connection_peers():
		connections.append(connection_stat_entry(int(peer_id)))

	var remote_updates: Array = []

	for peer_id in net_diag_rate_by_peer.keys():
		remote_updates.append({
			"peer_id": peer_id,
			"hz": float(net_diag_rate_by_peer[peer_id]),
			"last_gap_ms": float(net_diag_last_gap_by_peer.get(peer_id, 0.0)) * 1000.0,
			"max_gap_ms": float(net_diag_round_max_gap_by_peer.get(peer_id, 0.0)) * 1000.0,
		})

	return {
		"role": net_role_name(),
		"local_peer_id": (multiplayer.get_unique_id() if has_active_multiplayer_peer() else 0),
		"player_count": players_by_peer_id.size(),
		"fps": Engine.get_frames_per_second(),
		"physics_tps": Engine.physics_ticks_per_second,
		"send_rate_hz": _local_send_rate_hz(),
		"connections": connections,
		"remote_updates": remote_updates,
	}


func _local_send_rate_hz() -> float:
	for peer_id in players_by_peer_id.keys():
		var player = players_by_peer_id[peer_id]

		if player != null and player.get("is_local_player") and "network_send_rate" in player:
			return float(player.network_send_rate)

	return 0.0


# --- Per-round report ---------------------------------------------------------------

func _on_round_state_changed_for_report(new_state: int) -> void:
	if new_state == RoundManager.State.ACTIVE:
		reset_net_report()          # start a clean measurement window for the round
	elif new_state == RoundManager.State.ROUND_END:
		write_net_report()          # flush what we measured during the round

	if round_telemetry != null:
		if new_state == RoundManager.State.ACTIVE:
			round_telemetry.call("start_round")     # clears last round's buffers first
			round_telemetry.call("record_round_state", round_manager.state_name(new_state))
		elif new_state == RoundManager.State.ROUND_END:
			round_telemetry.call("record_round_state", round_manager.state_name(new_state))
			round_telemetry.call("end_round")       # flushes to disk, includes the line above
		else:
			round_telemetry.call("record_round_state", round_manager.state_name(new_state))


func reset_net_report() -> void:
	net_report = {
		"start_unix": Time.get_unix_time_from_system(),
		"duration": 0.0,
		"samples": 0,
		"fps_min": INF, "fps_sum": 0.0,
		"ping_min": INF, "ping_max": 0.0, "ping_sum": 0.0, "ping_samples": 0,
		"loss_max": 0.0, "loss_sum": 0.0, "loss_samples": 0,
		"worst_gap_ms": 0.0,
		"min_update_hz": INF,
	}
	# Clear ALL per-peer arrival timing, not just the max gap. Otherwise the first packet of
	# the new round is timed against the last packet of the previous round, so every report
	# inherits the ~7s round-end/countdown silence (and that 0.14Hz sample tanks the update
	# rate). Clearing here makes the gap/rate reflect only intra-round arrivals.
	net_diag_round_max_gap_by_peer.clear()
	net_diag_last_recv_by_peer.clear()
	net_diag_last_gap_by_peer.clear()
	net_diag_rate_by_peer.clear()


func accumulate_net_report(delta: float) -> void:
	if net_report.is_empty():
		return

	net_report["duration"] = float(net_report["duration"]) + delta
	net_report["samples"] = int(net_report["samples"]) + 1

	var fps := float(Engine.get_frames_per_second())
	net_report["fps_min"] = minf(float(net_report["fps_min"]), fps)
	net_report["fps_sum"] = float(net_report["fps_sum"]) + fps

	for peer_id in diag_connection_peers():
		var rtt := get_enet_peer_stat(int(peer_id), ENetPacketPeer.PEER_ROUND_TRIP_TIME)

		if rtt >= 0.0:
			net_report["ping_min"] = minf(float(net_report["ping_min"]), rtt)
			net_report["ping_max"] = maxf(float(net_report["ping_max"]), rtt)
			net_report["ping_sum"] = float(net_report["ping_sum"]) + rtt
			net_report["ping_samples"] = int(net_report["ping_samples"]) + 1

		var loss := get_enet_peer_stat(int(peer_id), ENetPacketPeer.PEER_PACKET_LOSS)

		if loss >= 0.0:
			var loss_pct := (loss / float(ENetPacketPeer.PACKET_LOSS_SCALE)) * 100.0
			net_report["loss_max"] = maxf(float(net_report["loss_max"]), loss_pct)
			net_report["loss_sum"] = float(net_report["loss_sum"]) + loss_pct
			net_report["loss_samples"] = int(net_report["loss_samples"]) + 1

	for peer_id in net_diag_round_max_gap_by_peer.keys():
		var gap_ms := float(net_diag_round_max_gap_by_peer[peer_id]) * 1000.0
		net_report["worst_gap_ms"] = maxf(float(net_report["worst_gap_ms"]), gap_ms)

	for peer_id in net_diag_rate_by_peer.keys():
		net_report["min_update_hz"] = minf(float(net_report["min_update_hz"]), float(net_diag_rate_by_peer[peer_id]))


func write_net_report() -> void:
	if net_report.is_empty() or int(net_report["samples"]) <= 0:
		return

	var dir_path := "user://net_reports"
	DirAccess.make_dir_recursive_absolute(dir_path)

	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := dir_path + "/round_" + stamp + ".txt"
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		push_warning("Could not write network report to " + path)
		return

	file.store_string(format_net_report())
	file.close()
	print("Network report written: ", ProjectSettings.globalize_path(path))


func format_net_report() -> String:
	var samples := maxi(int(net_report["samples"]), 1)
	var ping_samples := maxi(int(net_report["ping_samples"]), 1)
	var loss_samples := maxi(int(net_report["loss_samples"]), 1)

	var fps_min := float(net_report["fps_min"])
	var ping_min := float(net_report["ping_min"])
	var min_hz := float(net_report["min_update_hz"])

	var lines: PackedStringArray = []
	lines.append("=== Round network report ===")
	lines.append("Role:            " + net_role_name())
	lines.append("Generated:       " + Time.get_datetime_string_from_system())
	lines.append("Round duration:  %.1f s (%d samples)" % [float(net_report["duration"]), samples])
	lines.append("Players:         " + str(players_by_peer_id.size()))
	lines.append("")
	lines.append("-- Frame rate --")
	lines.append("FPS min/avg:     %.0f / %.0f" % [
		(0.0 if fps_min == INF else fps_min),
		float(net_report["fps_sum"]) / samples,
	])
	lines.append("")
	lines.append("-- Ping (round-trip to %s, ms) --" % ("clients" if multiplayer.is_server() else "server"))
	lines.append("min/avg/max:     %.0f / %.0f / %.0f" % [
		(0.0 if ping_min == INF else ping_min),
		float(net_report["ping_sum"]) / ping_samples,
		float(net_report["ping_max"]),
	])
	lines.append("")
	lines.append("-- Packet loss (%) --")
	lines.append("avg/max:         %.2f / %.2f" % [
		float(net_report["loss_sum"]) / loss_samples,
		float(net_report["loss_max"]),
	])
	lines.append("")
	lines.append("-- Remote player update smoothness --")
	lines.append("min update rate: %.1f Hz" % (0.0 if min_hz == INF else min_hz))
	lines.append("worst gap:       %.0f ms  (longest freeze between packets)" % float(net_report["worst_gap_ms"]))
	lines.append("")
	lines.append("Note: a worst gap well above ~1000/send_rate ms, or a low min update rate,")
	lines.append("means packets are arriving irregularly at this machine -> the visible freeze.")
	return "\n".join(lines)


# --- F3 overlay ---------------------------------------------------------------------

func create_network_debug_overlay() -> void:
	if DisplayServer.get_name() == "headless":
		return        # no display to draw on

	net_diag_overlay = preload("res://scripts/network_debug_overlay.gd").new()
	add_child(net_diag_overlay)

	if net_diag_overlay.has_method("setup"):
		net_diag_overlay.call("setup", self)


# Builds the in-game Escape menu (Resume / Settings / Admin / Leave). Skipped on a headless
# server, which has no screen.
func create_pause_menu() -> void:
	if DisplayServer.get_name() == "headless":
		return

	var pause_menu := preload("res://scripts/pause_menu.gd").new()
	add_child(pause_menu)

	if pause_menu.has_method("setup"):
		pause_menu.call("setup", self, get_node_or_null("../ServerAdmin"))
