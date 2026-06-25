extends Node

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
@export var weapon_hit_max_range: float = 280.0
@export var weapon_hit_origin_validation_distance: float = 8.0
@export var weapon_hit_target_validation_radius: float = 4.0
@export var weapon_hit_server_cooldown: float = 0.02
@export var weapon_tracer_scene: PackedScene = preload("res://scenes/hitscan_tracer_effect.tscn")

var players_parent: Node3D
var buy_menu: Node

var players_by_peer_id: Dictionary = {}
var spawn_index_by_peer_id: Dictionary = {}
var last_body_slam_time_by_pair: Dictionary = {}
var last_weapon_hit_time_by_pair: Dictionary = {}

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

	print("NetworkManager ready.")
	print("Current multiplayer peer active: ", has_active_multiplayer_peer())
	print("Press H to host, J to join.")

	apply_launch_mode()


# Acts on the choice the start menu recorded. Test Arena auto-hosts a solo session
# (same path as pressing H); Dedicated Server hosts headless with no local player.
func apply_launch_mode() -> void:
	match GameLaunch.consume_mode():
		GameLaunch.Mode.TEST_ARENA:
			print("Launch mode: Test Arena — auto-hosting solo.")
			call_deferred("host_game")

		GameLaunch.Mode.DEDICATED_SERVER:
			var server_port := int(GameLaunch.read_cmdline_value("--port", str(port)))
			print("Launch mode: Dedicated server on port ", server_port, ".")
			call_deferred("start_dedicated_server", server_port)

		GameLaunch.Mode.HOST_SERVER:
			print("Launch mode: Local server.")
			call_deferred("host_game")

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
		"map_use_default_arena": GameLaunch.map_use_default_arena,
		"map_style": GameLaunch.map_style,
		"map_seed": GameLaunch.map_seed,
		"map_length": GameLaunch.map_length,
		"map_width": GameLaunch.map_width,
		"map_height": GameLaunch.map_height,
		"map_density": GameLaunch.map_density,
		"map_boundary": GameLaunch.map_boundary,
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

	print("Dedicated server listening on port ", server_port, ". Waiting for clients.")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	
	var wants_host := false
	var wants_join := false
	
	if InputMap.has_action("host_game") and event.is_action_pressed("host_game"):
		wants_host = true
	
	if InputMap.has_action("join_game") and event.is_action_pressed("join_game"):
		wants_join = true
	
	if wants_host and wants_join:
		push_warning("host_game and join_game are both triggered by this key. Fix Project Settings > Input Map.")
		return
	
	if wants_host:
		host_game()
		get_viewport().set_input_as_handled()
		return
	
	if wants_join:
		join_game(default_join_ip)
		get_viewport().set_input_as_handled()


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


func host_game() -> void:
	if has_active_multiplayer_peer():
		if multiplayer.is_server() and not players_by_peer_id.has(1):
			spawn_index_by_peer_id[1] = 0
			client_spawn_player(1, 0, starting_cash)
		
		print("Already connected to an active multiplayer peer.")
		return
	
	clear_runtime_multiplayer_state()
	
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, max_players - 1)
	
	if error != OK:
		push_error("Failed to host game. Error: " + str(error))
		multiplayer.multiplayer_peer = null
		return
	
	multiplayer.multiplayer_peer = peer
	
	spawn_index_by_peer_id[1] = 0
	client_spawn_player(1, 0, starting_cash)
	
	print("Hosting 1v1 on port ", port)


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
	last_body_slam_time_by_pair.clear()
	last_weapon_hit_time_by_pair.clear()
	
	var peer := multiplayer.multiplayer_peer
	
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	
	multiplayer.multiplayer_peer = null


func _on_connected_to_server() -> void:
	print("Connected to server. My peer id: ", multiplayer.get_unique_id())
	call_deferred("_handle_pending_lobby_action")


func _on_connection_failed() -> void:
	push_error("Connection failed.")
	clear_runtime_multiplayer_state()


func _on_server_disconnected() -> void:
	print("Disconnected from server.")
	clear_runtime_multiplayer_state()


func _on_peer_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("Peer connected: ", peer_id)

	# Lobby servers don't auto-spawn; the player spawns when they join a lobby.
	if lobby_mode:
		return

	for existing_peer_id in spawn_index_by_peer_id.keys():
		rpc_id(
			peer_id,
			"client_spawn_player",
			int(existing_peer_id),
			int(spawn_index_by_peer_id[existing_peer_id]),
			starting_cash
		)

	var spawn_index := spawn_index_by_peer_id.size()
	spawn_index_by_peer_id[peer_id] = spawn_index

	rpc("client_spawn_player", peer_id, spawn_index, starting_cash)


# Called by LobbyManager when a player joins a lobby: assigns the next alternating
# team slot (even=A, odd=B → 1v1 at 2, 2v1 at 3, 2v2 at 4) and replicates the spawn
# only to that lobby's members.
func server_spawn_in_lobby(peer_id: int, members: Array) -> void:
	if not multiplayer.is_server():
		return

	if players_by_peer_id.has(peer_id):
		return

	# Send already-spawned lobby players to the newcomer.
	for existing_peer_id in spawn_index_by_peer_id.keys():
		rpc_id(
			peer_id,
			"client_spawn_player",
			int(existing_peer_id),
			int(spawn_index_by_peer_id[existing_peer_id]),
			starting_cash
		)

	var spawn_index := spawn_index_by_peer_id.size()
	spawn_index_by_peer_id[peer_id] = spawn_index

	# Server's authoritative copy.
	client_spawn_player(peer_id, spawn_index, starting_cash)

	# Replicate the newcomer to every other lobby member (clients).
	for member in members:
		var member_id := int(member)

		if member_id != 1 and member_id != peer_id:
			rpc_id(member_id, "client_spawn_player", peer_id, spawn_index, starting_cash)

	# And give the newcomer their own player.
	if peer_id != 1:
		rpc_id(peer_id, "client_spawn_player", peer_id, spawn_index, starting_cash)


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	spawn_index_by_peer_id.erase(peer_id)
	clear_body_slam_pairs_for_peer(peer_id)

	if lobby_manager != null and lobby_manager.has_method("server_on_peer_left"):
		lobby_manager.call("server_on_peer_left", peer_id)

	rpc("client_remove_player", peer_id)


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


@rpc("authority", "call_local", "reliable")
func client_spawn_player(peer_id: int, spawn_index: int, server_starting_cash: int = -1) -> void:
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
	
	var player := player_scene.instantiate()
	player.name = "Player_" + str(peer_id)
	players_parent.add_child(player)
	
	if player is Node3D:
		player.global_transform = get_spawn_transform(spawn_index)
		player.reset_physics_interpolation()
	
	var is_local := peer_id == multiplayer.get_unique_id()
	
	if player.has_method("set_multiplayer_player"):
		player.call("set_multiplayer_player", peer_id, is_local, self)
	
	players_by_peer_id[peer_id] = player
	
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
		parts.append(str(peer_id) + " spawn=" + str(spawn_index))

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
	_damage: float,
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
			hit_position,
			shot_origin,
			shot_direction
		)
	else:
		rpc_id(
			1,
			"server_request_weapon_hit",
			target_peer_id,
			hit_position,
			shot_origin,
			shot_direction
		)


@rpc("any_peer", "reliable")
func server_request_weapon_hit(
	target_peer_id: int,
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
		hit_position,
		shot_origin,
		shot_direction
	)


func server_process_weapon_hit(
	attacker_peer_id: int,
	target_peer_id: int,
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
	
	if not is_weapon_hit_plausible(attacker, target, hit_position, shot_origin, shot_direction):
		return
	
	mark_weapon_hit_pair(attacker_peer_id, target_peer_id)
	rpc("client_apply_weapon_damage", target_peer_id, attacker_peer_id, weapon_hit_damage)
	
	print(
		"Weapon hit: ",
		attacker_peer_id,
		" -> ",
		target_peer_id,
		" damage ",
		weapon_hit_damage
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
	attacker: Node3D,
	target: Node3D,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> bool:
	if shot_direction.length() < 0.001:
		return false
	
	if shot_origin.distance_to(attacker.global_position) > weapon_hit_origin_validation_distance:
		return false
	
	if shot_origin.distance_to(hit_position) > weapon_hit_max_range:
		return false
	
	var target_distance_to_hit := target.global_position.distance_to(hit_position)
	
	if target_distance_to_hit > weapon_hit_target_validation_radius:
		return false
	
	return true


@rpc("authority", "call_local", "reliable")
func client_apply_weapon_damage(
	target_peer_id: int,
	attacker_peer_id: int,
	damage: float
) -> void:
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var target = players_by_peer_id[target_peer_id]

	if target != null and target.has_method("apply_weapon_damage"):
		target.call("apply_weapon_damage", damage, attacker_peer_id)

	# Hit feedback: only the attacker's own client shows the hitmarker.
	if attacker_peer_id == multiplayer.get_unique_id() and players_by_peer_id.has(attacker_peer_id):
		var attacker = players_by_peer_id[attacker_peer_id]

		if attacker != null and attacker.has_method("show_hitmarker"):
			attacker.call("show_hitmarker")


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
