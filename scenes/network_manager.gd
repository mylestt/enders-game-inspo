extends Node

@export var player_scene: PackedScene
@export var players_parent_path: NodePath
@export var spawn_a_path: NodePath
@export var spawn_b_path: NodePath
@export var buy_menu_path: NodePath

@export var port: int = 7000
@export var max_players: int = 2
@export var default_join_ip: String = "127.0.0.1"

@export var max_laser_hit_range: float = 120.0
@export var server_laser_cooldown: float = 0.2
@export var max_laser_origin_distance_from_player: float = 4.0

var players_parent: Node3D
var buy_menu: Node

var players_by_peer_id: Dictionary = {}
var spawn_index_by_peer_id: Dictionary = {}
var last_fire_time_by_peer_id: Dictionary = {}


func _ready() -> void:
	players_parent = get_node_or_null(players_parent_path) as Node3D
	buy_menu = get_node_or_null(buy_menu_path)
	
	if players_parent == null:
		push_error("NetworkManager could not find Players parent. Assign Players Parent Path.")
	
	if buy_menu == null:
		push_warning("NetworkManager could not find BuyMenu. Assign Buy Menu Path if you want multiplayer buy menu support.")
	
	connect_multiplayer_signals()
	print("NetworkManager ready. Press H to host, J to join localhost.")


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action("host_game") and event.is_action_pressed("host_game"):
		host_game()
	
	if InputMap.has_action("join_game") and event.is_action_pressed("join_game"):
		join_game(default_join_ip)


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
	
	return peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED


func host_game() -> void:
	if has_active_multiplayer_peer():
		if multiplayer.is_server() and not players_by_peer_id.has(1):
			spawn_index_by_peer_id[1] = 0
			client_spawn_player(1, 0)
		
		print("Already connected to an active multiplayer peer.")
		return
	
	multiplayer.multiplayer_peer = null
	
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, max_players - 1)
	
	if error != OK:
		push_error("Failed to host game. Error: " + str(error))
		return
	
	multiplayer.multiplayer_peer = peer
	
	players_by_peer_id.clear()
	spawn_index_by_peer_id.clear()
	last_fire_time_by_peer_id.clear()
	
	spawn_index_by_peer_id[1] = 0
	client_spawn_player(1, 0)
	
	print("Hosting 1v1 on port ", port)


func join_game(ip: String) -> void:
	if has_active_multiplayer_peer():
		print("Already connected to an active multiplayer peer.")
		return
	
	multiplayer.multiplayer_peer = null
	
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(ip, port)
	
	if error != OK:
		push_error("Failed to join game. Error: " + str(error))
		return
	
	multiplayer.multiplayer_peer = peer
	
	print("Joining ", ip, ":", port)


func _on_connected_to_server() -> void:
	print("Connected to server. My peer id: ", multiplayer.get_unique_id())


func _on_connection_failed() -> void:
	push_error("Connection failed.")
	multiplayer.multiplayer_peer = null


func _on_server_disconnected() -> void:
	print("Disconnected from server.")
	multiplayer.multiplayer_peer = null


func _on_peer_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("Peer connected: ", peer_id)
	
	for existing_peer_id in spawn_index_by_peer_id.keys():
		rpc_id(
			peer_id,
			"client_spawn_player",
			int(existing_peer_id),
			int(spawn_index_by_peer_id[existing_peer_id])
		)
	
	var spawn_index := spawn_index_by_peer_id.size() % max_players
	spawn_index_by_peer_id[peer_id] = spawn_index
	
	rpc("client_spawn_player", peer_id, spawn_index)


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	spawn_index_by_peer_id.erase(peer_id)
	last_fire_time_by_peer_id.erase(peer_id)
	rpc("client_remove_player", peer_id)


@rpc("authority", "call_local", "reliable")
func client_spawn_player(peer_id: int, spawn_index: int) -> void:
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
	
	var is_local := peer_id == multiplayer.get_unique_id()
	
	if player.has_method("set_multiplayer_player"):
		player.call("set_multiplayer_player", peer_id, is_local, self)
	
	players_by_peer_id[peer_id] = player
	
	if is_local:
		call_deferred("bind_local_player_to_buy_menu", player)
	
	print("Spawned player ", peer_id, ". Local: ", is_local)


func bind_local_player_to_buy_menu(player: Node) -> void:
	if buy_menu == null:
		buy_menu = get_node_or_null(buy_menu_path)
	
	if buy_menu == null:
		push_warning("No BuyMenu found, so local player was not assigned to a buy menu.")
		return
	
	if buy_menu.has_method("set_local_player"):
		buy_menu.call("set_local_player", player)
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
	var spawn_node: Node3D
	
	if spawn_index == 0:
		spawn_node = get_node_or_null(spawn_a_path) as Node3D
	else:
		spawn_node = get_node_or_null(spawn_b_path) as Node3D
	
	if spawn_node != null:
		return spawn_node.global_transform
	
	var fallback_position := Vector3(float(spawn_index) * 6.0, 0.0, 0.0)
	return Transform3D(Basis.IDENTITY, fallback_position)


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


func request_laser_fire(
	shooter_peer_id: int,
	origin: Vector3,
	direction: Vector3,
	requested_range: float
) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	
	if multiplayer.is_server():
		server_process_laser_fire(shooter_peer_id, origin, direction, requested_range)
	else:
		rpc_id(1, "server_request_laser_fire", origin, direction, requested_range)


@rpc("any_peer", "reliable")
func server_request_laser_fire(
	origin: Vector3,
	direction: Vector3,
	requested_range: float
) -> void:
	if not multiplayer.is_server():
		return
	
	var shooter_peer_id := multiplayer.get_remote_sender_id()
	server_process_laser_fire(shooter_peer_id, origin, direction, requested_range)


func server_process_laser_fire(
	shooter_peer_id: int,
	origin: Vector3,
	direction: Vector3,
	requested_range: float
) -> void:
	if not multiplayer.is_server():
		return
	
	if direction.length() < 0.01:
		return
	
	if not players_by_peer_id.has(shooter_peer_id):
		return
	
	var shooter: Node3D = players_by_peer_id[shooter_peer_id] as Node3D
	
	if shooter == null:
		return
	
	if shooter.has_method("is_combat_disabled") and shooter.call("is_combat_disabled"):
		return
	
	var current_time := Time.get_ticks_msec() / 1000.0
	
	if last_fire_time_by_peer_id.has(shooter_peer_id):
		var last_fire_time: float = last_fire_time_by_peer_id[shooter_peer_id]
		
		if current_time - last_fire_time < server_laser_cooldown:
			return
	
	last_fire_time_by_peer_id[shooter_peer_id] = current_time
	
	var shooter_position: Vector3 = shooter.global_position
	
	if origin.distance_to(shooter_position) > max_laser_origin_distance_from_player:
		origin = shooter_position
	
	var laser_range := clampf(requested_range, 1.0, max_laser_hit_range)
	var end := origin + direction.normalized() * laser_range
	
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	if shooter is CollisionObject3D:
		query.exclude = [shooter.get_rid()]
	
	var result: Dictionary = shooter.get_world_3d().direct_space_state.intersect_ray(query)
	
	if result.is_empty():
		return
	
	var collider = result["collider"]
	var hit_player = find_player_from_collider(collider)
	
	if hit_player == null:
		return
	
	if not hit_player.has_method("get_peer_id"):
		return
	
	var hit_peer_id: int = int(hit_player.call("get_peer_id"))
	
	if hit_peer_id == shooter_peer_id:
		return
	
	server_damage_player(hit_peer_id, 1)
	
	print("Server hit reg: ", shooter_peer_id, " hit ", hit_peer_id)


func find_player_from_collider(collider: Object) -> Node:
	if collider == null:
		return null
	
	var current = collider
	
	while current != null:
		if current is Node and current.has_method("get_peer_id"):
			return current
		
		if current is Node:
			current = current.get_parent()
		else:
			break
	
	return null


func server_damage_player(target_peer_id: int, hit_amount: int) -> void:
	if not multiplayer.is_server():
		return
	
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var target = players_by_peer_id[target_peer_id]
	
	if target == null:
		return
	
	if target.has_method("server_add_hit"):
		target.call("server_add_hit", hit_amount)
	
	var hits := 0
	var disabled := false
	
	if target.has_method("get_hit_count"):
		hits = int(target.call("get_hit_count"))
	
	if target.has_method("is_combat_disabled"):
		disabled = bool(target.call("is_combat_disabled"))
	
	rpc("client_set_player_damage_state", target_peer_id, hits, disabled)


@rpc("authority", "call_local", "reliable")
func client_set_player_damage_state(
	target_peer_id: int,
	hits: int,
	disabled: bool
) -> void:
	if not players_by_peer_id.has(target_peer_id):
		return
	
	var target = players_by_peer_id[target_peer_id]
	
	if target != null and target.has_method("apply_network_damage_state"):
		target.call("apply_network_damage_state", hits, disabled)


func reset_all_players() -> void:
	if not multiplayer.is_server():
		return
	
	for peer_id in players_by_peer_id.keys():
		var player = players_by_peer_id[peer_id]
		
		if player != null and player.has_method("server_reset_health"):
			player.call("server_reset_health")
		
		rpc("client_set_player_damage_state", int(peer_id), 0, false)
