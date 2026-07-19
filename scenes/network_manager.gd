extends Node

signal scoreboard_changed(entries: Array)
# Fired when a join/host connection attempt resolves, so the lobby browser can show
# "couldn't reach the server" instead of leaving the player on a silent grey screen.
signal connection_attempt_finished(success: bool, message: String)

# Godot sends RPCs as an INDEX into each node's alphabetically-sorted @rpc method table,
# so two builds with different @rpc sets silently decode each other's calls as the WRONG
# methods (symptom: endless "RPC 'x' is not allowed on node ... from <peer>" spam, frozen
# remote players, dropped state). The connect-time auth handshake compares this version and
# rejects a mismatched peer cleanly instead. BUMP IT whenever any @rpc method is added,
# removed, or renamed on any script — the smoke suite fingerprints the project's @rpc
# surface and fails when it drifts without a bump (it prints the new hash to paste below).
# v2: the weapon-shot relay (server_relay_weapon_shot / client_play_weapon_shot) gained a
# trailing tracer_scale arg for the charge railgun's variable-width beam. The @rpc NAMES are
# unchanged (fingerprint is name-based, so it stays put) but the argument COUNT changed, which
# is wire-incompatible with a v1 build — hence the version bump so stale builds are rejected.
const NET_PROTOCOL_VERSION := 2
const NET_RPC_FINGERPRINT := "70be130b6cf8442a918cd869ee124150"
# Distinguishes our version payload from garbage/foreign auth data.
const NET_AUTH_MAGIC := 0x5A47_4653  # "ZGFS"

@export var player_scene: PackedScene
@export var players_parent_path: NodePath
@export var spawn_a_path: NodePath
@export var spawn_b_path: NodePath
@export var buy_menu_path: NodePath

@export var port: int = 7000
@export var max_players: int = 10
@export var default_join_ip: String = "127.0.0.1"
@export var starting_cash: int = 200000
# A dead/unreachable server can leave ENet in CONNECTING forever (no failure event); give
# up after this long so the player gets feedback instead of an eternal grey screen.
@export var connect_timeout_seconds: float = 8.0

@export var body_slam_server_cooldown: float = 0.2
@export var body_slam_validation_distance: float = 4.0
@export var body_slam_max_impulse: float = 18.0
# Anti-cheat clamp: the per-weapon damage a client reports is capped to this server-side.
@export var weapon_hit_max_damage: float = 250.0
@export var weapon_hit_max_range: float = 280.0
@export var weapon_hit_origin_validation_distance: float = 8.0
@export var weapon_hit_target_validation_radius: float = 4.0
@export var weapon_hit_server_cooldown: float = 0.02
# How long after dying a peer's damage claims are still honoured. Covers same-moment trade
# kills and plasma bolts already in flight when the shooter died; after this window a dead
# (or cheating) client can no longer deal damage until it respawns.
@export var weapon_hit_dead_attacker_grace: float = 2.5
# Fallback tracer for an unrecognized/blank weapon_id. Each real weapon relays its OWN
# hitscan_tracer_scene (see get_tracer_scene_for_weapon) so every gun keeps its distinct
# look for every client, not just the shooter.
@export var weapon_tracer_scene: PackedScene = preload("res://scenes/hitscan_tracer_effect.tscn")

@export_group("Plasma Explosion Validation")
@export var plasma_projectile_scene: PackedScene = preload("res://scenes/plasma_projectile.tscn")
@export var plasma_explosion_max_damage: float = 100.0
@export var plasma_explosion_max_radius: float = 12.0
@export var plasma_explosion_max_impulse: float = 80.0
@export var plasma_explosion_origin_validation_distance: float = 20.0
@export var plasma_explosion_path_tolerance: float = 2.5
@export var plasma_explosion_target_tolerance: float = 1.5

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

# FFA loadout fallbacks for OFFLINE / non-lobby sessions (read from GameLaunch). Online,
# each lobby carries its own ffa_weapons / booster_fuel in its settings dict.
var ffa_weapons: Array = []
var ffa_booster_fuel: float = 100.0

var players_by_peer_id: Dictionary = {}
var spawn_index_by_peer_id: Dictionary = {}
var player_names_by_peer_id: Dictionary = {}
var player_stats_by_peer_id: Dictionary = {}
var scoreboard_entries: Array = []
var last_body_slam_time_by_pair: Dictionary = {}
var last_weapon_hit_time_by_pair: Dictionary = {}
# peer_id -> server time (seconds) the peer was last confirmed killed. Server-only; backs
# the dead-attacker grace check on damage claims.
var server_death_time_by_peer_id: Dictionary = {}
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
# Sticky copy of the lobby action ("browse"/"host"); pending_lobby_action is consumed on
# connect, but the browser UI and retry_connection() still need to know the session intent.
var lobby_flow_action: String = ""
var last_join_ip: String = ""
var _awaiting_connection: bool = false
var _connect_wait: float = 0.0
# Set when the version handshake rejects a peer, so the client-facing failure message says
# "build mismatch" instead of the generic "couldn't reach the server".
var _auth_fail_message: String = ""
var lobby_manager: Node

# Server-authoritative cash / ownership / ammo ledger. Created on every machine (the RPC
# node path must match), populated only on the server. See scripts/server_economy.gd.
var server_economy: ServerEconomy


func _ready() -> void:
	GameLaunch.apply_cmdline_overrides()
	starting_cash = GameLaunch.starting_cash
	ffa_weapons = GameLaunch.ffa_weapons.duplicate()
	ffa_booster_fuel = maxf(GameLaunch.ffa_booster_fuel, 0.0)

	players_parent = get_node_or_null(players_parent_path) as Node3D
	buy_menu = get_node_or_null(buy_menu_path)
	lobby_manager = get_node_or_null("../LobbyManager")

	if players_parent == null:
		push_error("NetworkManager could not find Players parent. Assign Players Parent Path.")
	
	if buy_menu == null:
		push_warning("NetworkManager could not find BuyMenu. Assign Buy Menu Path if you want multiplayer buy menu support.")
	
	connect_multiplayer_signals()

	round_manager = get_node_or_null("../RoundManager")

	if round_manager != null:
		# Client machines: their own lobby's replicated state drives the net report window.
		if round_manager.has_signal("round_state_changed"):
			round_manager.round_state_changed.connect(_on_round_state_changed_for_report)

		# Server: per-lobby session transitions drive ammo refills, telemetry, and reports.
		if round_manager.has_signal("session_state_changed"):
			round_manager.session_state_changed.connect(_on_session_state_changed)

	server_economy = ServerEconomy.new()
	server_economy.name = "ServerEconomy"
	add_child(server_economy)
	server_economy.setup(self)

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
			lobby_flow_action = "browse"
			var direct_ip := GameLaunch.join_ip if GameLaunch.join_ip != "" else default_join_ip
			print("Launch mode: Direct join ", direct_ip, ":", port, ".")
			call_deferred("join_game", direct_ip)

		GameLaunch.Mode.MULTIPLAYER_BROWSE:
			pending_lobby_action = "browse"
			lobby_flow_action = "browse"
			var browse_ip := _resolve_server_ip()
			print("Launch mode: Browse lobbies on ", browse_ip, ":", port, ".")
			call_deferred("join_game", browse_ip)

		GameLaunch.Mode.MULTIPLAYER_HOST:
			pending_lobby_action = "host"
			lobby_flow_action = "host"
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
		"game_mode": GameLaunch.game_mode_id,
		"respawn_time": GameLaunch.ffa_respawn_time,
		"booster_fuel": GameLaunch.ffa_booster_fuel,
		"ffa_weapons": GameLaunch.ffa_weapons.duplicate(),
		"kill_limit": GameLaunch.ffa_kill_limit,
		"heal_on_kill": GameLaunch.heal_on_kill,
		"ammo_on_kill": GameLaunch.ammo_on_kill,
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

	# Build-version handshake (see NET_PROTOCOL_VERSION). The auth phase runs BEFORE any
	# RPC exchange, so it stays intact even when the two builds' RPC tables disagree.
	var scene_multiplayer := multiplayer as SceneMultiplayer

	if scene_multiplayer != null:
		scene_multiplayer.auth_callback = _on_peer_auth_received
		scene_multiplayer.auth_timeout = 5.0

		if not scene_multiplayer.peer_authenticating.is_connected(_on_peer_authenticating):
			scene_multiplayer.peer_authenticating.connect(_on_peer_authenticating)

		if not scene_multiplayer.peer_authentication_failed.is_connected(_on_peer_authentication_failed):
			scene_multiplayer.peer_authentication_failed.connect(_on_peer_authentication_failed)


# A peer just connected and both sides must prove they run the same net protocol: send ours.
func _on_peer_authenticating(peer_id: int) -> void:
	var payload := PackedByteArray()
	payload.resize(8)
	payload.encode_u32(0, NET_AUTH_MAGIC)
	payload.encode_u32(4, NET_PROTOCOL_VERSION)
	(multiplayer as SceneMultiplayer).send_auth(peer_id, payload)


# The remote's version payload arrived: admit on match, drop on anything else. A peer on a
# build too old to even send auth never lands here — auth_timeout drops it instead.
func _on_peer_auth_received(peer_id: int, data: PackedByteArray) -> void:
	var scene_multiplayer := multiplayer as SceneMultiplayer
	var remote_version := -1

	if data.size() >= 8 and data.decode_u32(0) == NET_AUTH_MAGIC:
		remote_version = int(data.decode_u32(4))

	if remote_version != NET_PROTOCOL_VERSION:
		_auth_fail_message = (
			"Build mismatch: remote net protocol v" + str(remote_version)
			+ " vs local v" + str(NET_PROTOCOL_VERSION) + "."
		)
		print("Rejecting peer ", peer_id, ". ", _auth_fail_message)
		scene_multiplayer.disconnect_peer(peer_id)
		return

	scene_multiplayer.complete_auth(peer_id)


func _on_peer_authentication_failed(peer_id: int) -> void:
	if multiplayer.is_server():
		# Covers both an explicit version rejection and the auth_timeout on clients too old
		# to send auth at all. One line per rejected peer; they never spawn or join a lobby.
		print("Peer ", peer_id, " failed the build-version handshake — dropped. ",
			_auth_fail_message)
		_auth_fail_message = ""
		return

	# Client: peer 1 never authenticated. The engine emits server_disconnected (or
	# connection_failed) immediately after this signal, so don't emit a result here — just
	# pin the cause and let that handler report it via _consume_auth_fail_message, otherwise
	# its generic transport message would overwrite this specific one in the lobby browser.
	if _auth_fail_message == "":
		_auth_fail_message = (
			"The server never answered the version handshake — it is likely running an"
			+ " older build than this client."
		)

	push_warning("Connection rejected: " + _auth_fail_message)


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

	# Offline FFA (RoundManager stays dormant without a peer), so arm the solo player here.
	if is_ffa():
		server_apply_ffa_loadout(1)

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
		connection_attempt_finished.emit(false, "Could not start a connection to " + ip + ".")
		return

	multiplayer.multiplayer_peer = peer
	last_join_ip = ip
	_awaiting_connection = true
	_connect_wait = 0.0
	_auth_fail_message = ""

	print("Joining ", ip, ":", port)


# Re-attempts the last join (used by the lobby browser's Retry after a failed/timed-out
# connect). Re-arms the original browse/host intent so the flow resumes on connect.
func retry_connection() -> void:
	if has_active_multiplayer_peer() or last_join_ip == "":
		return

	pending_lobby_action = lobby_flow_action
	join_game(last_join_ip)


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
	server_death_time_by_peer_id.clear()
	player_state_history.clear()

	if server_economy != null:
		server_economy.reset_all()

	var peer := multiplayer.multiplayer_peer
	
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	
	multiplayer.multiplayer_peer = null


func _on_connected_to_server() -> void:
	print("Connected to server. My peer id: ", multiplayer.get_unique_id())
	_awaiting_connection = false
	connection_attempt_finished.emit(true, "Connected.")
	rpc_id(1, "server_register_player_name", GameLaunch.player_username)
	call_deferred("_handle_pending_lobby_action")


func _on_connection_failed() -> void:
	push_error("Connection failed.")
	_awaiting_connection = false
	clear_runtime_multiplayer_state()
	connection_attempt_finished.emit(false, _consume_auth_fail_message(
		"Couldn't reach the server at " + last_join_ip + "."))


func _on_server_disconnected() -> void:
	print("Disconnected from server.")
	_awaiting_connection = false
	clear_runtime_multiplayer_state()
	connection_attempt_finished.emit(false, _consume_auth_fail_message(
		"Lost connection to the server."))


# If the version handshake already pinned the cause, report that instead of the generic
# transport-level message (whichever engine signal happens to deliver the drop).
func _consume_auth_fail_message(fallback: String) -> String:
	if _auth_fail_message == "":
		return fallback

	var message := "Version mismatch — update your game. (" + _auth_fail_message + ")"
	_auth_fail_message = ""
	return message


# ENet can sit in CONNECTING forever against a dead address (no failure event ever fires,
# which used to leave the player on a silent grey screen). Give up after the timeout.
func _tick_connect_timeout(delta: float) -> void:
	if not _awaiting_connection:
		return

	_connect_wait += delta

	if _connect_wait < connect_timeout_seconds:
		return

	_awaiting_connection = false
	print("Connection attempt to ", last_join_ip, " timed out.")
	clear_runtime_multiplayer_state()
	connection_attempt_finished.emit(false, "Server not responding at " + last_join_ip + ".")


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

	# Lowest unused slot, not the dictionary size: after a disconnect, size() would hand a
	# newcomer a slot an existing player still occupies (same team + same spawn point).
	var spawn_index := _lowest_free_spawn_slot()
	spawn_index_by_peer_id[peer_id] = spawn_index

	if server_economy != null:
		server_economy.server_init_peer(peer_id, starting_cash)

	rpc("client_spawn_player", peer_id, spawn_index, starting_cash, get_player_name(peer_id))

	if is_ffa():
		server_apply_ffa_loadout(peer_id)

	server_broadcast_scoreboard()


# Called by LobbyManager when a player joins a lobby: assigns the lobby's next alternating
# team slot (even=A, odd=B → 1v1 at 2, 2v1 at 3, 2v2 at 4) and replicates the spawn only to
# that lobby's members. `lobby` carries the lobby's own rules (starting cash, mode, …).
func server_spawn_in_lobby(peer_id: int, members: Array, lobby: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return

	if players_by_peer_id.has(peer_id):
		return

	ensure_player_metadata(peer_id)

	var lobby_cash := maxi(int(lobby.get("starting_cash", starting_cash)), 0)

	# Send already-spawned players of THIS LOBBY to the newcomer — members only, so other
	# lobbies' players never replicate across.
	for member in members:
		var member_id := int(member)

		if member_id == peer_id or not spawn_index_by_peer_id.has(member_id):
			continue

		rpc_id(
			peer_id,
			"client_spawn_player",
			member_id,
			int(spawn_index_by_peer_id[member_id]),
			lobby_cash,
			get_player_name(member_id)
		)

	# Team slots alternate PER LOBBY: take the lowest slot not used by a current member, so
	# teams stay balanced within the lobby regardless of what other lobbies are doing.
	var used_slots: Dictionary = {}

	for member in members:
		var member_id := int(member)

		if member_id != peer_id and spawn_index_by_peer_id.has(member_id):
			used_slots[int(spawn_index_by_peer_id[member_id])] = true

	var spawn_index := 0

	while used_slots.has(spawn_index):
		spawn_index += 1

	spawn_index_by_peer_id[peer_id] = spawn_index

	if server_economy != null:
		server_economy.server_init_peer(peer_id, lobby_cash)

	# Server's authoritative copy.
	client_spawn_player(peer_id, spawn_index, lobby_cash, get_player_name(peer_id))

	# Replicate the newcomer to every other lobby member (clients).
	for member in members:
		var member_id := int(member)

		if member_id != 1 and member_id != peer_id:
			rpc_id(member_id, "client_spawn_player", peer_id, spawn_index, lobby_cash, get_player_name(peer_id))

	# And give the newcomer their own player.
	if peer_id != 1:
		rpc_id(peer_id, "client_spawn_player", peer_id, spawn_index, lobby_cash, get_player_name(peer_id))

	if String(lobby.get("game_mode", "team")) == "ffa":
		server_apply_ffa_loadout(peer_id)

	server_broadcast_scoreboard()


# The lowest spawn slot no current player occupies (fills disconnect gaps first, keeping
# team parity balanced as players churn).
func _lowest_free_spawn_slot() -> int:
	var used_slots: Dictionary = {}

	for slot in spawn_index_by_peer_id.values():
		used_slots[int(slot)] = true

	var spawn_index := 0

	while used_slots.has(spawn_index):
		spawn_index += 1

	return spawn_index


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	spawn_index_by_peer_id.erase(peer_id)
	player_names_by_peer_id.erase(peer_id)
	player_stats_by_peer_id.erase(peer_id)
	player_state_history.erase(peer_id)
	server_death_time_by_peer_id.erase(peer_id)
	clear_body_slam_pairs_for_peer(peer_id)
	clear_net_diag_for_peer(peer_id)

	if server_economy != null:
		server_economy.server_remove_peer(peer_id)

	# Capture the lobby audience BEFORE the lobby drops the member (only they have a copy).
	var audience := _lobby_client_peers_for(peer_id)

	if lobby_manager != null and lobby_manager.has_method("server_on_peer_left"):
		lobby_manager.call("server_on_peer_left", peer_id)

	client_remove_player(peer_id)   # server's own copy

	for audience_id in audience:
		if int(audience_id) != peer_id:
			rpc_id(int(audience_id), "client_remove_player", peer_id)

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
	# Clients need the spawn slot too: team = slot parity (get_team_for_peer), which drives
	# the friendly/enemy indicator dots. The server already stored its own copy.
	spawn_index_by_peer_id[peer_id] = spawn_index

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

		# Spawn onto the nearest surface (ground mode) for the initial pre-round spawn too, so
		# players start standing rather than floating. Round start / respawn re-runs this.
		if player.has_method("request_spawn_ground_mode"):
			player.call("request_spawn_ground_mode")

	refresh_player_health_bars()

	print("Spawned player ", peer_id, ". Local: ", is_local)


# Colors the health bar above every remote player: green = same team as this machine's
# player, red = enemy. Re-run after every spawn — the local player may spawn after others
# were replayed to us, and only then can earlier bars be resolved against our own team.
func refresh_player_health_bars() -> void:
	if DisplayServer.get_name() == "headless":
		return   # nothing renders on a dedicated server

	var local_id := get_local_peer_id()

	if not players_by_peer_id.has(local_id):
		return

	var ffa := is_ffa()
	var local_team := get_team_for_peer(local_id)

	for peer_id in players_by_peer_id.keys():
		if int(peer_id) == local_id:
			continue

		var player = players_by_peer_id[peer_id]

		if player != null and player.has_method("set_health_bar_friendly"):
			# FFA has no teammates: every other player reads as an enemy (red).
			var friendly := false if ffa else (get_team_for_peer(int(peer_id)) == local_team)
			player.call("set_health_bar_friendly", friendly)


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

		# Online purchases route through the server-authoritative economy.
		if server_economy != null and buy_menu.has_method("set_economy"):
			buy_menu.call("set_economy", server_economy)

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
			# orthonormalized(): a spawn marker scaled in the editor (easy to do to the
			# SpawnPoint capsules) must never leak scale into the player's basis — a scaled
			# player body breaks every unit-vector assumption downstream (camera, walk).
			return marker.global_transform.orthonormalized()

	# Fallback to the two primary markers if the map's spawn groups aren't present.
	var spawn_node: Node3D

	if team == "a":
		spawn_node = get_node_or_null(spawn_a_path) as Node3D
	else:
		spawn_node = get_node_or_null(spawn_b_path) as Node3D

	if spawn_node != null:
		return spawn_node.global_transform.orthonormalized()

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


# True when THIS machine's session is a free-for-all. Client-side display checks only —
# reads GameLaunch, which RoundManager.client_sync_game_mode keeps in sync with the lobby.
# Server-side logic must use the per-peer lobby helpers below instead (each lobby has its
# own mode).
func is_ffa() -> bool:
	return GameLaunch.game_mode_id == "ffa"


# --- Per-lobby lookups (server) -------------------------------------------------------
# With multiple concurrent lobbies, every relay/broadcast and every rules check is scoped
# to ONE lobby. These resolve a peer's lobby via LobbyManager; on non-lobby servers they
# fall back to "everyone / GameLaunch defaults" so direct-connect and offline still work.

func _lobby_for_peer(peer_id: int) -> Dictionary:
	if lobby_mode and lobby_manager != null and lobby_manager.has_method("get_lobby_for_peer"):
		return lobby_manager.call("get_lobby_for_peer", peer_id)

	return {}


# The connected client peer ids sharing `peer_id`'s lobby (including peer_id itself when
# it's a client). Fallback: every connected peer.
func _lobby_client_peers_for(peer_id: int) -> Array:
	var lobby := _lobby_for_peer(peer_id)
	var connected := multiplayer.get_peers()

	if lobby.is_empty():
		return Array(connected)

	var out: Array = []

	for member in lobby.get("members", []):
		var member_id := int(member)

		if member_id != 1 and connected.has(member_id):
			out.append(member_id)

	return out


func _same_lobby(peer_a: int, peer_b: int) -> bool:
	if not lobby_mode or lobby_manager == null or not lobby_manager.has_method("get_lobby_id_for_peer"):
		return true

	return int(lobby_manager.call("get_lobby_id_for_peer", peer_a)) == int(lobby_manager.call("get_lobby_id_for_peer", peer_b))


func _is_ffa_for_peer(peer_id: int) -> bool:
	var lobby := _lobby_for_peer(peer_id)

	if lobby.is_empty():
		return is_ffa()

	return String(lobby.get("game_mode", "team")) == "ffa"


# All arena-edge spawn markers, both team groups pooled (FFA ignores teams).
func get_all_spawn_markers() -> Array:
	var markers: Array = []
	markers.append_array(get_team_spawn_markers("a"))
	markers.append_array(get_team_spawn_markers("b"))
	return markers


# --- FFA spawning ----------------------------------------------------------------------
# FFA spawns players all around the arena shell, not just at the authored markers: a ray is
# cast from the arena's centre in a random direction, and the player is placed just inside
# whatever wall it hits, standing on it (the ground-mode spawn probe then locks them to the
# surface). Several candidates are sampled and the one farthest from the other players wins
# (anti-spawn-camping). Falls back to a random authored marker if the rays find nothing
# (open/unenclosed maps, or collision not ready yet).

const FFA_SPAWN_CANDIDATES := 6
const FFA_SPAWN_SURFACE_OFFSET := 1.4

func get_ffa_spawn_transform(avoid_positions: Array = []) -> Transform3D:
	var center := _arena_center()
	var best: Dictionary = {}
	var best_score := -INF

	for i in range(FFA_SPAWN_CANDIDATES):
		var candidate := _random_edge_spawn(center)

		if candidate.is_empty():
			continue

		var score: float

		if avoid_positions.is_empty():
			score = randf()
		else:
			score = INF

			for avoid in avoid_positions:
				score = minf(score, (candidate["position"] as Vector3).distance_to(avoid))

		if score > best_score:
			best_score = score
			best = candidate

	if not best.is_empty():
		return _edge_spawn_transform(best, center)

	# Fallback: random authored marker (orthonormalized — see get_spawn_transform).
	var markers := get_all_spawn_markers()

	if markers.size() > 0:
		var marker := markers[randi() % markers.size()] as Node3D

		if marker != null:
			return marker.global_transform.orthonormalized()

	return get_spawn_transform(0)


# The arena's rough centre: the centroid of every authored spawn marker.
func _arena_center() -> Vector3:
	var markers := get_all_spawn_markers()

	if markers.is_empty():
		return Vector3.ZERO

	var sum := Vector3.ZERO

	for marker in markers:
		sum += (marker as Node3D).global_position

	return sum / float(markers.size())


# One random point on the arena shell: {position (offset off the wall), normal} or {}.
func _random_edge_spawn(center: Vector3) -> Dictionary:
	if players_parent == null:
		return {}

	var world := players_parent.get_world_3d()

	if world == null:
		return {}

	var direction := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))

	if direction.length() < 0.05:
		direction = Vector3.UP

	direction = direction.normalized()

	var query := PhysicsRayQueryParameters3D.create(center, center + direction * 1000.0)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = _player_body_rids()

	var hit := world.direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return {}

	var normal: Vector3 = hit.get("normal", Vector3.ZERO)

	if normal.length() < 0.01:
		return {}

	normal = normal.normalized()
	return {
		"position": (hit["position"] as Vector3) + normal * FFA_SPAWN_SURFACE_OFFSET,
		"normal": normal,
	}


func _player_body_rids() -> Array[RID]:
	var rids: Array[RID] = []

	for peer_id in players_by_peer_id.keys():
		var player = players_by_peer_id[peer_id]

		if player is CollisionObject3D:
			rids.append((player as CollisionObject3D).get_rid())

	return rids


# Stands the spawn on the wall: up = surface normal, facing back toward the arena centre.
func _edge_spawn_transform(spot: Dictionary, center: Vector3) -> Transform3D:
	var up: Vector3 = spot["normal"]
	var origin: Vector3 = spot["position"]
	var forward := (center - origin).slide(up)

	if forward.length() < 0.01:
		forward = Vector3.FORWARD.slide(up)

	if forward.length() < 0.01:
		forward = Vector3.RIGHT.slide(up)

	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	var corrected_forward := up.cross(right).normalized()

	return Transform3D(Basis(right, up, -corrected_forward), origin)


# --- FFA loadout (server) ------------------------------------------------------------
# FFA has no buy menu: the server picks a random gun per life from the lobby's weapon pool,
# grants it in the economy ledger (so hit claims validate) and the lobby's booster fuel,
# and tells the owning client to equip. The `ffa_weapons` / `ffa_booster_fuel` fields are
# the offline/non-lobby fallbacks.

func _pick_ffa_weapon(allowed: Array) -> StringName:
	var pool: Array = []

	for id in allowed:
		var weapon_id := StringName(String(id))

		if WeaponInventory.get_weapon_scene(weapon_id) != null:
			pool.append(weapon_id)

	if pool.is_empty():
		pool = WeaponInventory.get_weapon_ids()

	return pool[randi() % pool.size()]


func server_apply_ffa_loadout(peer_id: int) -> void:
	if not _is_ffa_for_peer(peer_id):
		return

	# Server (or offline) only: a plain client must never pick its own loadout.
	if has_active_multiplayer_peer() and not multiplayer.is_server():
		return

	if not players_by_peer_id.has(peer_id):
		return

	var lobby := _lobby_for_peer(peer_id)
	var allowed: Array = lobby.get("ffa_weapons", ffa_weapons)
	var booster_fuel := maxf(float(lobby.get("booster_fuel", ffa_booster_fuel)), 0.0)
	var weapon_id := _pick_ffa_weapon(allowed)

	if server_economy != null and server_economy.has_method("server_grant_ffa_weapon"):
		server_economy.server_grant_ffa_weapon(peer_id, String(weapon_id))

	# Apply directly for the local/offline player, or send to the owning client.
	if not has_active_multiplayer_peer() or peer_id == get_local_peer_id():
		client_apply_ffa_loadout(peer_id, String(weapon_id), booster_fuel)
	else:
		rpc_id(peer_id, "client_apply_ffa_loadout", peer_id, String(weapon_id), booster_fuel)


@rpc("authority", "reliable")
func client_apply_ffa_loadout(peer_id: int, weapon_id: String, booster_fuel: float) -> void:
	var player = players_by_peer_id.get(peer_id)

	if player != null and player.has_method("apply_ffa_loadout"):
		player.call("apply_ffa_loadout", StringName(weapon_id), booster_fuel)


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


# Resets K/D for the given peers (empty = everyone). Sessions pass their own member list so
# one lobby's round start doesn't wipe another lobby's stats.
func server_reset_player_stats(peer_ids: Array = []) -> void:
	if not multiplayer.is_server():
		return

	var targets := peer_ids if not peer_ids.is_empty() else player_stats_by_peer_id.keys()

	for peer_id in targets:
		if player_stats_by_peer_id.has(peer_id):
			player_stats_by_peer_id[peer_id] = {
				"kills": 0,
				"deaths": 0,
			}

	server_broadcast_scoreboard()


# Rebuilds and sends every lobby its OWN scoreboard (players + sort order are per lobby).
# Cheap at MAX_LOBBIES scale, so any stat change just refreshes them all.
func server_broadcast_scoreboard() -> void:
	if not multiplayer.is_server():
		return

	if lobby_mode and lobby_manager != null and "lobbies" in lobby_manager:
		for lobby_id in lobby_manager.lobbies.keys():
			var lobby: Dictionary = lobby_manager.lobbies[lobby_id]
			var members: Array = lobby.get("members", [])
			var entries := build_scoreboard_entries(members, String(lobby.get("game_mode", "team")) == "ffa")

			for member in members:
				var member_id := int(member)

				if member_id != 1 and Array(multiplayer.get_peers()).has(member_id):
					rpc_id(member_id, "client_sync_scoreboard", entries)

		return

	# Non-lobby servers: one global board, as before.
	var all_entries := build_scoreboard_entries([], is_ffa())
	client_sync_scoreboard(all_entries)

	for remote_peer_id in multiplayer.get_peers():
		rpc_id(remote_peer_id, "client_sync_scoreboard", all_entries)


# `filter_ids` limits the board to those peers (empty = all spawned players); `ffa` picks
# the sort: one kill-ranked list vs grouped-by-team.
func build_scoreboard_entries(filter_ids: Array = [], ffa: bool = false) -> Array:
	var entries: Array = []

	for peer_id in players_by_peer_id.keys():
		var id := int(peer_id)

		if not filter_ids.is_empty() and not filter_ids.has(id):
			continue

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

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _compare_scoreboard_entries(a, b, ffa))
	return entries


func _compare_scoreboard_entries(a: Dictionary, b: Dictionary, ffa: bool) -> bool:
	# FFA is a single kill-ranked list; team mode groups by team first.
	if not ffa:
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


# Admin cash commands mutate the authoritative ledger; ServerEconomy syncs the new balance
# down to the affected client's buy-menu display.
func server_set_player_cash(peer_id: int, amount: int) -> bool:
	if not multiplayer.is_server() or server_economy == null:
		return false

	return server_economy.server_set_cash(peer_id, amount)


func server_add_player_cash(peer_id: int, amount: int) -> bool:
	if not multiplayer.is_server() or server_economy == null:
		return false

	return server_economy.server_add_cash(peer_id, amount)


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


# A hacked client can put NaN/Inf into any RPC float; clampf(NaN) stays NaN, which would
# poison health, transforms, and physics on every peer that applies it. Every
# client-supplied vector/float must pass these before it is used or relayed.
func is_valid_vector(v: Vector3) -> bool:
	return v.is_finite()


func is_valid_transform(t: Transform3D) -> bool:
	if not (
		t.origin.is_finite()
		and t.basis.x.is_finite()
		and t.basis.y.is_finite()
		and t.basis.z.is_finite()
	):
		return false

	# An honest client's basis is orthonormal (determinant ~1). A scaled, mirrored, or
	# degenerate basis would scale the replica's collision shape (Jolt error spam on the
	# server) and break the unit-vector math everywhere the transform is consumed; the
	# receiver additionally orthonormalizes, which a zero/degenerate basis would turn to NaN.
	return absf(t.basis.determinant() - 1.0) < 0.35


# `state_seq` is a per-sender monotonic counter; unreliable packets can arrive out of
# order, and applying an older state after a newer one visibly rubber-bands the replica.
func submit_local_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	state_seq: int
) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_relay_player_state(peer_id, player_transform, linear_velocity, angular_velocity, state_seq)
	else:
		rpc_id(
			1,
			"server_receive_player_state",
			peer_id,
			player_transform,
			linear_velocity,
			angular_velocity,
			state_seq
		)


@rpc("any_peer", "unreliable")
func server_receive_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	state_seq: int
) -> void:
	if not multiplayer.is_server():
		return

	if multiplayer.get_remote_sender_id() != peer_id:
		return

	if not is_valid_transform(player_transform):
		return

	if not is_valid_vector(linear_velocity) or not is_valid_vector(angular_velocity):
		return

	_relay_player_state(peer_id, player_transform, linear_velocity, angular_velocity, state_seq)


# Server-side: records lag-comp history, applies to the server's own replica, and forwards
# to every OTHER member of the sender's lobby (other lobbies don't have this player).
func _relay_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	state_seq: int
) -> void:
	server_record_state_history(peer_id, player_transform.origin)
	client_receive_player_state(peer_id, player_transform, linear_velocity, angular_velocity, state_seq)

	for remote_peer_id in _lobby_client_peers_for(peer_id):
		if int(remote_peer_id) != peer_id:
			rpc_id(
				int(remote_peer_id),
				"client_receive_player_state",
				peer_id,
				player_transform,
				linear_velocity,
				angular_velocity,
				state_seq
			)


@rpc("authority", "unreliable")
func client_receive_player_state(
	peer_id: int,
	player_transform: Transform3D,
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	state_seq: int
) -> void:
	if peer_id == multiplayer.get_unique_id():
		return

	track_incoming_state_timing(peer_id)

	if not players_by_peer_id.has(peer_id):
		return

	var player = players_by_peer_id[peer_id]

	if player != null and player.has_method("receive_network_state"):
		player.call("receive_network_state", player_transform, linear_velocity, angular_velocity, state_seq)


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

	if not is_valid_vector(impulse) or not is_valid_vector(contact_position):
		return

	# Players can only interact with their own lobby (a hacked client could claim any id).
	if not _same_lobby(attacker_peer_id, target_peer_id):
		return

	# Honest clients never report slams while dead (see detect_player_body_slam_contacts).
	if not server_attacker_may_deal_damage(attacker_peer_id, attacker):
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
	
	client_apply_body_slam_impulse(target_peer_id, clamped_impulse, contact_position)

	for peer_id in _lobby_client_peers_for(target_peer_id):
		rpc_id(int(peer_id), "client_apply_body_slam_impulse", target_peer_id, clamped_impulse, contact_position)


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

func request_environmental_kill(peer_id: int, damage: float) -> void:
	if multiplayer.multiplayer_peer == null:
		var player = players_by_peer_id.get(peer_id)

		if player != null and player.has_method("apply_weapon_damage"):
			player.call("apply_weapon_damage", damage, 0)

		return

	if multiplayer.is_server():
		server_process_environmental_kill(peer_id, damage)
	else:
		rpc_id(1, "server_request_environmental_kill", damage)


@rpc("any_peer", "reliable")
func server_request_environmental_kill(damage: float) -> void:
	if not multiplayer.is_server():
		return

	var peer_id := multiplayer.get_remote_sender_id()
	server_process_environmental_kill(peer_id, damage)


func server_process_environmental_kill(peer_id: int, damage: float) -> void:
	if not multiplayer.is_server():
		return

	if not players_by_peer_id.has(peer_id):
		return

	if damage <= 0.0:
		return

	apply_confirmed_damage(peer_id, 0, damage)

	for member_peer_id in _lobby_client_peers_for(peer_id):
		rpc_id(int(member_peer_id), "client_apply_weapon_damage", peer_id, 0, damage)


func request_plasma_explosion_hit(
	attacker_peer_id: int,
	target_peer_id: int,
	damage: float,
	impulse: Vector3,
	explosion_position: Vector3,
	explosion_radius: float,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		server_process_plasma_explosion_hit(
			attacker_peer_id,
			target_peer_id,
			damage,
			impulse,
			explosion_position,
			explosion_radius,
			shot_origin,
			shot_direction,
			weapon_id
		)
	else:
		rpc_id(
			1,
			"server_request_plasma_explosion_hit",
			target_peer_id,
			damage,
			impulse,
			explosion_position,
			explosion_radius,
			shot_origin,
			shot_direction,
			weapon_id
		)


@rpc("any_peer", "reliable")
func server_request_plasma_explosion_hit(
	target_peer_id: int,
	damage: float,
	impulse: Vector3,
	explosion_position: Vector3,
	explosion_radius: float,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
) -> void:
	if not multiplayer.is_server():
		return

	server_process_plasma_explosion_hit(
		multiplayer.get_remote_sender_id(),
		target_peer_id,
		damage,
		impulse,
		explosion_position,
		explosion_radius,
		shot_origin,
		shot_direction,
		weapon_id
	)


func server_process_plasma_explosion_hit(
	attacker_peer_id: int,
	target_peer_id: int,
	damage: float,
	impulse: Vector3,
	explosion_position: Vector3,
	explosion_radius: float,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
) -> void:
	if not multiplayer.is_server():
		return

	if not players_by_peer_id.has(attacker_peer_id):
		return

	if not players_by_peer_id.has(target_peer_id):
		return

	var attacker := players_by_peer_id[attacker_peer_id] as Node3D
	var target := players_by_peer_id[target_peer_id] as Node3D

	if attacker == null or target == null:
		return

	if not is_finite(damage) or not is_valid_vector(impulse):
		return

	if not _same_lobby(attacker_peer_id, target_peer_id):
		return

	if not server_attacker_may_deal_damage(attacker_peer_id, attacker):
		return

	var validated_radius := clampf(explosion_radius, 0.0, plasma_explosion_max_radius)

	if not is_plasma_explosion_hit_plausible(
		attacker_peer_id,
		target_peer_id,
		attacker,
		target,
		explosion_position,
		validated_radius,
		shot_origin,
		shot_direction
	):
		return

	if not can_process_weapon_hit_pair(attacker_peer_id, target_peer_id):
		return

	# Ownership + ammo + fire-rate check (one round per blast, however many players it
	# hits), and clamp claimed damage to the weapon's real blast damage.
	var applied_damage := clampf(damage, 0.0, plasma_explosion_max_damage)

	if server_economy != null:
		applied_damage = server_economy.server_validate_plasma_hit(
			attacker_peer_id,
			weapon_id,
			applied_damage,
			explosion_position,
			target_peer_id
		)

		if applied_damage < 0.0:
			return

	mark_weapon_hit_pair(attacker_peer_id, target_peer_id)
	var applied_impulse_magnitude := clampf(impulse.length(), 0.0, plasma_explosion_max_impulse)
	var outward_direction := target.global_position - explosion_position

	if outward_direction.length_squared() < 0.0001:
		outward_direction = -shot_direction.normalized()
	else:
		outward_direction = outward_direction.normalized()

	var applied_impulse := outward_direction * applied_impulse_magnitude

	# Server's own copy first (captures whether this blast was the killing blow), then the
	# lobby's members.
	var killed := apply_confirmed_damage(target_peer_id, attacker_peer_id, applied_damage)

	for peer_id in _lobby_client_peers_for(target_peer_id):
		rpc_id(
			int(peer_id),
			"client_apply_plasma_explosion_hit",
			target_peer_id,
			attacker_peer_id,
			applied_damage,
			applied_impulse
		)

	if killed:
		_handle_kill_rewards(attacker_peer_id, target_peer_id)


func is_plasma_explosion_hit_plausible(
	attacker_peer_id: int,
	target_peer_id: int,
	attacker: Node3D,
	target: Node3D,
	explosion_position: Vector3,
	explosion_radius: float,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> bool:
	if not is_valid_vector(explosion_position) or not is_valid_vector(shot_origin) or not is_valid_vector(shot_direction):
		return false

	if not is_finite(explosion_radius):
		return false

	if shot_direction.length_squared() < 0.0001 or explosion_radius <= 0.0:
		return false

	if shot_origin.distance_to(attacker.global_position) > plasma_explosion_origin_validation_distance:
		return false

	var direction := shot_direction.normalized()
	var to_explosion := explosion_position - shot_origin
	var distance_along_shot := to_explosion.dot(direction)

	if distance_along_shot < -plasma_explosion_path_tolerance:
		return false

	if distance_along_shot > weapon_hit_max_range:
		return false

	var closest_path_point := shot_origin + direction * maxf(distance_along_shot, 0.0)

	if closest_path_point.distance_to(explosion_position) > plasma_explosion_path_tolerance:
		return false

	var validated_target_position := target.global_position

	if lag_comp_enabled and target_peer_id != attacker_peer_id:
		var rewound_position = get_rewound_position(
			target_peer_id,
			compute_rewind_for_peer(attacker_peer_id)
		)

		if rewound_position != null:
			validated_target_position = rewound_position

	return (
		explosion_position.distance_to(validated_target_position)
		<= explosion_radius + plasma_explosion_target_tolerance
	)


@rpc("authority", "call_local", "reliable")
func client_apply_plasma_explosion_hit(
	target_peer_id: int,
	attacker_peer_id: int,
	damage: float,
	impulse: Vector3
) -> void:
	apply_confirmed_damage(target_peer_id, attacker_peer_id, damage)

	var target = players_by_peer_id.get(target_peer_id)

	if target != null and not impulse.is_zero_approx() and target.has_method("apply_network_plasma_impulse"):
		target.call("apply_network_plasma_impulse", impulse)


# Server-confirmed damage, applied to this machine's copy of the target. Runs on the server
# directly and on lobby members via the client_apply_* RPCs. Shows the attacker's hitmarker
# on their own machine and — on the server — records the kill time backing the dead-attacker
# grace check. Returns true when this damage was the killing blow (on this machine's copy).
func apply_confirmed_damage(target_peer_id: int, attacker_peer_id: int, damage: float) -> bool:
	var target = players_by_peer_id.get(target_peer_id)
	var killed := false

	if target != null and damage > 0.0 and target.has_method("apply_weapon_damage"):
		# Capture alive-state first so only the actual killing blow (alive -> dead) reads as a
		# kill — shots that land on an already-down corpse stay a normal hit.
		var was_alive: bool = target.get("is_dead") != true
		target.call("apply_weapon_damage", damage, attacker_peer_id)
		killed = was_alive and target.get("is_dead") == true

	if killed and multiplayer.multiplayer_peer != null and multiplayer.is_server():
		server_death_time_by_peer_id[target_peer_id] = Time.get_ticks_msec() / 1000.0

	# Hit feedback: only the attacker's own client shows the hitmarker (red on a kill), and
	# never for self-damage (plasma splash can hit the shooter).
	if (
		damage > 0.0
		and attacker_peer_id != target_peer_id
		and attacker_peer_id == multiplayer.get_unique_id()
	):
		var attacker = players_by_peer_id.get(attacker_peer_id)

		if attacker != null and attacker.has_method("show_hitmarker"):
			attacker.call("show_hitmarker", killed)

	return killed


# --- Kill rewards (server) --------------------------------------------------------------
# Optional per-lobby rules: on a confirmed kill the killer is fully healed and/or has all
# their ammo refilled. Heals replicate to every lobby member's copy (health must agree
# everywhere); the ammo refill mirrors into the server ledger and the killer's own client.

func _handle_kill_rewards(attacker_peer_id: int, target_peer_id: int) -> void:
	if attacker_peer_id == 0 or attacker_peer_id == target_peer_id:
		return

	if not players_by_peer_id.has(attacker_peer_id):
		return

	var lobby := _lobby_for_peer(attacker_peer_id)
	var heal := bool(lobby.get("heal_on_kill", GameLaunch.heal_on_kill))
	var refill := bool(lobby.get("ammo_on_kill", GameLaunch.ammo_on_kill))

	if heal:
		client_apply_heal(attacker_peer_id)   # server's own copy

		for peer_id in _lobby_client_peers_for(attacker_peer_id):
			rpc_id(int(peer_id), "client_apply_heal", attacker_peer_id)

	if refill:
		if server_economy != null and server_economy.has_method("server_refill_peer_ammo"):
			server_economy.server_refill_peer_ammo(attacker_peer_id)

		if attacker_peer_id == get_local_peer_id():
			client_refill_ammo(attacker_peer_id)
		elif Array(multiplayer.get_peers()).has(attacker_peer_id):
			rpc_id(attacker_peer_id, "client_refill_ammo", attacker_peer_id)


@rpc("authority", "reliable")
func client_apply_heal(peer_id: int) -> void:
	var player = players_by_peer_id.get(peer_id)

	if player != null and player.has_method("apply_full_heal"):
		player.call("apply_full_heal")


@rpc("authority", "reliable")
func client_refill_ammo(peer_id: int) -> void:
	var player = players_by_peer_id.get(peer_id)

	if player != null and player.has_method("refill_all_ammo"):
		player.call("refill_all_ammo")


func request_weapon_hit(
	attacker_peer_id: int,
	target_peer_id: int,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
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
			shot_direction,
			weapon_id
		)
	else:
		rpc_id(
			1,
			"server_request_weapon_hit",
			target_peer_id,
			damage,
			hit_position,
			shot_origin,
			shot_direction,
			weapon_id
		)


@rpc("any_peer", "reliable")
func server_request_weapon_hit(
	target_peer_id: int,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
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
		shot_direction,
		weapon_id
	)


func server_process_weapon_hit(
	attacker_peer_id: int,
	target_peer_id: int,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
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

	if not is_finite(damage):
		return

	if not _same_lobby(attacker_peer_id, target_peer_id):
		return

	if not server_attacker_may_deal_damage(attacker_peer_id, attacker):
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
	
	# Ownership + ammo + fire-rate check, and clamp the claimed damage to what the claimed
	# weapon actually deals. Consumes a round, so it runs after the cheaper checks above.
	var applied_damage := clampf(damage, 0.0, weapon_hit_max_damage)

	if server_economy != null:
		applied_damage = server_economy.server_validate_hitscan_hit(
			attacker_peer_id,
			weapon_id,
			applied_damage
		)

		if applied_damage < 0.0:
			return

	mark_weapon_hit_pair(attacker_peer_id, target_peer_id)

	# Server's own copy first (captures whether this shot was the killing blow), then the
	# lobby's members.
	var killed := apply_confirmed_damage(target_peer_id, attacker_peer_id, applied_damage)

	for peer_id in _lobby_client_peers_for(target_peer_id):
		rpc_id(int(peer_id), "client_apply_weapon_damage", target_peer_id, attacker_peer_id, applied_damage)

	if killed:
		_handle_kill_rewards(attacker_peer_id, target_peer_id)


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


# A dead client must not keep dealing damage/impulses for the rest of the round. Checked
# against the server's own copy of the attacker's health; the grace window keeps legitimate
# same-moment trades and projectiles that were in flight when the shooter died.
func server_attacker_may_deal_damage(attacker_peer_id: int, attacker: Node) -> bool:
	var attacker_health := attacker.get_node_or_null("PlayerHealth") as PlayerHealth

	if attacker_health == null or attacker_health.current_health > 0.0:
		return true

	var died_at: float = float(server_death_time_by_peer_id.get(attacker_peer_id, -INF))
	return (Time.get_ticks_msec() / 1000.0) - died_at <= weapon_hit_dead_attacker_grace


func is_weapon_hit_plausible(
	attacker_peer_id: int,
	target_peer_id: int,
	attacker: Node3D,
	target: Node3D,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> bool:
	if not is_valid_vector(hit_position) or not is_valid_vector(shot_origin) or not is_valid_vector(shot_direction):
		return false

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
	apply_confirmed_damage(target_peer_id, attacker_peer_id, damage)
	
	
# --- Power-up replication ------------------------------------------------------------

func request_environmental_heal(peer_id: int, amount: float) -> void:
	if multiplayer.multiplayer_peer == null:
		var player = players_by_peer_id.get(peer_id)

		if player != null and player.has_method("apply_full_heal_amount"):
			player.call("apply_full_heal_amount", amount)

		return

	if multiplayer.is_server():
		server_process_environmental_heal(peer_id, amount)
	else:
		rpc_id(1, "server_request_environmental_heal", amount)


@rpc("any_peer", "reliable")
func server_request_environmental_heal(amount: float) -> void:
	if not multiplayer.is_server():
		return

	server_process_environmental_heal(multiplayer.get_remote_sender_id(), amount)


func server_process_environmental_heal(peer_id: int, amount: float) -> void:
	if not multiplayer.is_server():
		return

	if not players_by_peer_id.has(peer_id) or amount <= 0.0:
		return

	var player = players_by_peer_id[peer_id]

	if player != null and player.has_method("apply_full_heal_amount"):
		player.call("apply_full_heal_amount", amount)

	for member_peer_id in _lobby_client_peers_for(peer_id):
		rpc_id(int(member_peer_id), "client_apply_heal_amount", peer_id, amount)


@rpc("authority", "reliable")
func client_apply_heal_amount(peer_id: int, amount: float) -> void:
	var player = players_by_peer_id.get(peer_id)

	if player != null and player.has_method("apply_full_heal_amount"):
		player.call("apply_full_heal_amount", amount)


func broadcast_powerup_state(peer_id: int, kind: String, active: bool, value: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_relay_powerup_state(peer_id, kind, active, value)
	else:
		rpc_id(1, "server_relay_powerup_state", kind, active, value)


@rpc("any_peer", "reliable")
func server_relay_powerup_state(kind: String, active: bool, value: float) -> void:
	if not multiplayer.is_server():
		return

	_relay_powerup_state(multiplayer.get_remote_sender_id(), kind, active, value)


func _relay_powerup_state(peer_id: int, kind: String, active: bool, value: float) -> void:
	if not players_by_peer_id.has(peer_id):
		return

	client_apply_powerup_state(peer_id, kind, active, value)

	for member_peer_id in _lobby_client_peers_for(peer_id):
		if int(member_peer_id) != peer_id:
			rpc_id(int(member_peer_id), "client_apply_powerup_state", peer_id, kind, active, value)


@rpc("authority", "reliable")
func client_apply_powerup_state(peer_id: int, kind: String, active: bool, value: float) -> void:
	var player = players_by_peer_id.get(peer_id)

	if player != null and player.has_method("apply_powerup_state"):
		player.call("apply_powerup_state", kind, active, value)


# --- Weapon shot tracer replication ------------------------------------------------
# The shooter already drew its own tracer locally (using its own weapon's
# hitscan_tracer_scene); this relays the shot so every OTHER client draws the SAME gun's
# tracer, not a generic one. Unreliable on purpose — tracers are cosmetic.

# weapon_id (WeaponInventory slot id, e.g. "minigun") -> that weapon's own
# hitscan_tracer_scene. Built lazily by instantiating each weapon scene once — cheap
# because it only happens once per weapon type per client process, same pattern as
# ServerEconomy.get_weapon_stats.
var _tracer_scene_by_weapon_id: Dictionary = {}


func get_tracer_scene_for_weapon(weapon_id: String) -> PackedScene:
	if weapon_id == "":
		return weapon_tracer_scene

	if _tracer_scene_by_weapon_id.has(weapon_id):
		return _tracer_scene_by_weapon_id[weapon_id]

	var tracer_scene := weapon_tracer_scene
	var weapon_scene := WeaponInventory.get_weapon_scene(StringName(weapon_id))

	if weapon_scene != null:
		var weapon := weapon_scene.instantiate() as Weapon

		if weapon != null:
			if weapon.hitscan_tracer_scene != null:
				tracer_scene = weapon.hitscan_tracer_scene

			weapon.free()

	_tracer_scene_by_weapon_id[weapon_id] = tracer_scene
	return tracer_scene


func broadcast_weapon_shot(
	shooter_peer_id: int,
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3,
	weapon_id: String,
	tracer_scale: float = 1.0
) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_relay_weapon_shot(shooter_peer_id, origin, shot_end, did_hit, normal, weapon_id, tracer_scale)
	else:
		rpc_id(1, "server_relay_weapon_shot", origin, shot_end, did_hit, normal, weapon_id, tracer_scale)


@rpc("any_peer", "unreliable")
func server_relay_weapon_shot(
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3,
	weapon_id: String,
	tracer_scale: float = 1.0
) -> void:
	if not multiplayer.is_server():
		return

	_relay_weapon_shot(multiplayer.get_remote_sender_id(), origin, shot_end, did_hit, normal, weapon_id, tracer_scale)


# True when the server machine itself should also PLAY a relayed cosmetic effect: a listen
# host is a player with a screen, so it must see other players' tracers/bolts/ropes like any
# client. Dedicated servers (headless, or windowed with no local player) skip the work.
func _server_views_relayed_effects(shooter_peer_id: int) -> bool:
	if DisplayServer.get_name() == "headless":
		return false

	var local_id := get_local_peer_id()

	if shooter_peer_id == local_id or not players_by_peer_id.has(local_id):
		return false

	return _same_lobby(shooter_peer_id, local_id)


func _relay_weapon_shot(
	shooter_peer_id: int,
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3,
	weapon_id: String,
	tracer_scale: float = 1.0
) -> void:
	# Only spawned players get their effects relayed (a connected-but-unspawned peer in
	# lobby mode has nothing to shoot with).
	if not players_by_peer_id.has(shooter_peer_id):
		return

	if not is_valid_vector(origin) or not is_valid_vector(shot_end) or not is_valid_vector(normal):
		return

	if round_telemetry != null:
		round_telemetry.call("record_weapon_fired", shooter_peer_id, origin, did_hit)

	if _server_views_relayed_effects(shooter_peer_id):
		client_play_weapon_shot(origin, shot_end, did_hit, normal, weapon_id, tracer_scale)

	for peer_id in _lobby_client_peers_for(shooter_peer_id):
		if int(peer_id) != shooter_peer_id:
			rpc_id(int(peer_id), "client_play_weapon_shot", origin, shot_end, did_hit, normal, weapon_id, tracer_scale)


@rpc("authority", "unreliable")
func client_play_weapon_shot(
	origin: Vector3,
	shot_end: Vector3,
	did_hit: bool,
	normal: Vector3,
	weapon_id: String,
	tracer_scale: float = 1.0
) -> void:
	var parent := get_world_effect_parent()
	var tracer_scene := get_tracer_scene_for_weapon(weapon_id)

	if parent == null or tracer_scene == null:
		return

	var tracer := tracer_scene.instantiate()
	parent.add_child(tracer)

	if tracer.has_method("play"):
		# tracer_scale is the charge weapon's per-shot width multiplier (1.0 for normal guns),
		# so bystanders see the same-sized beam the shooter fired.
		tracer.call("play", origin, shot_end, did_hit, normal, tracer_scale)


# Where relayed shot effects live: the current scene's WeaponEffects node, or the scene
# root as a fallback (matches Weapon.get_hitscan_effect_parent on the shooter's side).
func get_world_effect_parent() -> Node:
	var scene := get_tree().current_scene

	if scene == null:
		return null

	var parent := scene.get_node_or_null("WeaponEffects")
	return parent if parent != null else scene


# --- Projectile replication ---------------------------------------------------------
# The shooter already simulates its own damage-dealing bolt locally; this relays the launch
# so every OTHER client spawns a cosmetic copy (flight, VFX, and local prop impulse only).
# Reliable, unlike tracers: bolts are rare and long-lived, and a dropped launch would leave
# other players eating a blast from a projectile they never saw.

func broadcast_projectile_shot(shooter_peer_id: int, origin: Vector3, velocity: Vector3) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_relay_projectile_shot(shooter_peer_id, origin, velocity)
	else:
		rpc_id(1, "server_relay_projectile_shot", origin, velocity)


@rpc("any_peer", "reliable")
func server_relay_projectile_shot(origin: Vector3, velocity: Vector3) -> void:
	if not multiplayer.is_server():
		return

	_relay_projectile_shot(multiplayer.get_remote_sender_id(), origin, velocity)


func _relay_projectile_shot(shooter_peer_id: int, origin: Vector3, velocity: Vector3) -> void:
	if not players_by_peer_id.has(shooter_peer_id):
		return

	if not is_valid_vector(origin) or not is_valid_vector(velocity):
		return

	if round_telemetry != null:
		round_telemetry.call("record_weapon_fired", shooter_peer_id, origin, false)

	if _server_views_relayed_effects(shooter_peer_id):
		client_play_projectile_shot(shooter_peer_id, origin, velocity)

	for peer_id in _lobby_client_peers_for(shooter_peer_id):
		if int(peer_id) != shooter_peer_id:
			rpc_id(int(peer_id), "client_play_projectile_shot", shooter_peer_id, origin, velocity)


@rpc("authority", "reliable")
func client_play_projectile_shot(shooter_peer_id: int, origin: Vector3, velocity: Vector3) -> void:
	var parent := get_world_effect_parent()

	if parent == null or plasma_projectile_scene == null:
		return

	var instance := plasma_projectile_scene.instantiate()
	var bolt := instance as PlasmaProjectile

	if bolt == null:
		push_error("NetworkManager plasma_projectile_scene root must be a PlasmaProjectile.")
		instance.free()
		return

	bolt.can_deal_damage = false
	parent.add_child(bolt)

	# Exclude the shooter's own body so the bolt doesn't pop at their muzzle.
	var shooter: Node = players_by_peer_id.get(shooter_peer_id)
	bolt.launch(origin, velocity.normalized(), velocity.length(), shooter)


# --- Grapple wire replication ---------------------------------------------------------
# Purely cosmetic on other clients: the wire's physics runs only on the owning player's
# machine (client-simulated movement, like everything else). These events keep every lobby
# member's copy of the pivot chain in sync so they draw the same rope. Kinds are
# GrappleController.EVENT_* (attach/bend/unwrap/release). Reliable — rare, and a dropped
# attach would leave a phantom rope.

func broadcast_grapple_event(peer_id: int, kind: int, point: Vector3) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_relay_grapple_event(peer_id, kind, point)
	else:
		rpc_id(1, "server_relay_grapple_event", kind, point)


@rpc("any_peer", "reliable")
func server_relay_grapple_event(kind: int, point: Vector3) -> void:
	if not multiplayer.is_server():
		return

	_relay_grapple_event(multiplayer.get_remote_sender_id(), kind, point)


func _relay_grapple_event(peer_id: int, kind: int, point: Vector3) -> void:
	if not players_by_peer_id.has(peer_id):
		return

	if not is_valid_vector(point):
		return

	if _server_views_relayed_effects(peer_id):
		client_play_grapple_event(peer_id, kind, point)

	for remote_peer_id in _lobby_client_peers_for(peer_id):
		if int(remote_peer_id) != peer_id:
			rpc_id(int(remote_peer_id), "client_play_grapple_event", peer_id, kind, point)


@rpc("authority", "reliable")
func client_play_grapple_event(peer_id: int, kind: int, point: Vector3) -> void:
	var player = players_by_peer_id.get(peer_id)

	if player != null and player.has_method("apply_grapple_event"):
		player.call("apply_grapple_event", kind, point)


# === Network diagnostics ============================================================
# An F3 overlay of live connection stats, plus a per-round report file written to
# user://net_reports/. Each machine measures its OWN view, so the laggy end's report is the
# one that matters. "remote update" timings are how smoothly other players' packets arrive
# here — the direct measure of the freeze/skip symptom.

func _process(delta: float) -> void:
	_tick_connect_timeout(delta)

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

	# Only after the server is admitted into the session. The transport can sit CONNECTED
	# while the version handshake is still pending (indefinitely against a pre-handshake
	# server build), and rpc_id(1, ...) errors "unknown peer ID: 1" the whole time.
	if not multiplayer.get_peers().has(1):
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


# Arrival-timing entries would otherwise linger until the next round-start clear; on a
# long-running lobby server with player churn that's an unbounded dictionary.
func clear_net_diag_for_peer(peer_id: int) -> void:
	net_diag_last_recv_by_peer.erase(peer_id)
	net_diag_rate_by_peer.erase(peer_id)
	net_diag_last_gap_by_peer.erase(peer_id)
	net_diag_round_max_gap_by_peer.erase(peer_id)


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

# Client-side: this machine's own lobby round window drives its net report.
func _on_round_state_changed_for_report(new_state: int) -> void:
	if new_state == RoundManager.State.ACTIVE:
		reset_net_report()          # start a clean measurement window for the round
	elif new_state == RoundManager.State.ROUND_END:
		write_net_report()          # flush what we measured during the round


# Server-side: one lobby's session changed state. Refills that lobby's ammo ledgers on
# round start (clients refill via WeaponInventory.reset_state, so the ledger must match)
# and feeds telemetry/reports. With several lobbies the report window is approximate.
func _on_session_state_changed(lobby_id: int, new_state: int) -> void:
	if new_state == RoundManager.State.ACTIVE:
		reset_net_report()

		if server_economy != null:
			var members: Array = []

			if lobby_manager != null and lobby_manager.has_method("get_lobby_members"):
				members = lobby_manager.call("get_lobby_members", lobby_id)

			if members.is_empty():
				server_economy.server_refill_all_ammo()
			else:
				for member in members:
					server_economy.server_refill_peer_ammo(int(member))
	elif new_state == RoundManager.State.ROUND_END:
		write_net_report()

	if round_telemetry != null:
		var label: String = "L" + str(lobby_id) + ":" + String(round_manager.call("state_name", new_state))

		if new_state == RoundManager.State.ACTIVE:
			round_telemetry.call("start_round")     # clears last round's buffers first
			round_telemetry.call("record_round_state", label)
		elif new_state == RoundManager.State.ROUND_END:
			round_telemetry.call("record_round_state", label)
			round_telemetry.call("end_round")       # flushes to disk, includes the line above
		else:
			round_telemetry.call("record_round_state", label)


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
