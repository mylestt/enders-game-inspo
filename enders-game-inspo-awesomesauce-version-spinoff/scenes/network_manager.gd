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
@export var min_server_laser_cooldown: float = 0.08
@export var max_laser_origin_distance_from_player: float = 4.0

@export var remote_laser_lifetime: float = 0.08
@export var remote_laser_radius: float = 0.045

@export var body_slam_server_cooldown: float = 0.2
@export var body_slam_validation_distance: float = 4.0
@export var body_slam_max_impulse: float = 18.0

var players_parent: Node3D
var buy_menu: Node

var players_by_peer_id: Dictionary = {}
var spawn_index_by_peer_id: Dictionary = {}
var last_fire_time_by_peer_id: Dictionary = {}
var last_body_slam_time_by_pair: Dictionary = {}

var remote_laser_material: StandardMaterial3D


func _ready() -> void:
	players_parent = get_node_or_null(players_parent_path) as Node3D
	buy_menu = get_node_or_null(buy_menu_path)
	
	if players_parent == null:
		push_error("NetworkManager could not find Players parent. Assign Players Parent Path.")
	
	if buy_menu == null:
		push_warning("NetworkManager could not find BuyMenu. Assign Buy Menu Path if you want multiplayer buy menu support.")
	
	setup_remote_laser_material()
	connect_multiplayer_signals()
	
	print("NetworkManager ready.")
	print("Current multiplayer peer active: ", has_active_multiplayer_peer())
	print("Press H to host, J to join.")


func setup_remote_laser_material() -> void:
	remote_laser_material = StandardMaterial3D.new()
	remote_laser_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	remote_laser_material.albedo_color = Color(1.0, 0.0, 0.0, 0.95)
	remote_laser_material.emission_enabled = true
	remote_laser_material.emission = Color(1.0, 0.0, 0.0, 1.0)
	remote_laser_material.emission_energy_multiplier = 5.0


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
		return


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
			client_spawn_player(1, 0)
		
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
	client_spawn_player(1, 0)
	
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
	last_fire_time_by_peer_id.clear()
	last_body_slam_time_by_pair.clear()
	
	var peer := multiplayer.multiplayer_peer
	
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	
	multiplayer.multiplayer_peer = null


func _on_connected_to_server() -> void:
	print("Connected to server. My peer id: ", multiplayer.get_unique_id())


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
	clear_body_slam_pairs_for_peer(peer_id)
	rpc("client_remove_player", peer_id)


func clear_body_slam_pairs_for_peer(peer_id: int) -> void:
	var keys_to_remove: Array = []
	
	for key in last_body_slam_time_by_pair.keys():
		var key_text := String(key)
		
		if key_text.begins_with(str(peer_id) + "_") or key_text.ends_with("_" + str(peer_id)):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		last_body_slam_time_by_pair.erase(key)


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
	
	if attacker.has_method("is_combat_disabled") and attacker.call("is_combat_disabled"):
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


func request_laser_fire(
	shooter_peer_id: int,
	origin: Vector3,
	direction: Vector3,
	requested_range: float,
	requested_cooldown: float
) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	
	if multiplayer.is_server():
		server_process_laser_fire(shooter_peer_id, origin, direction, requested_range, requested_cooldown)
	else:
		rpc_id(1, "server_request_laser_fire", origin, direction, requested_range, requested_cooldown)


@rpc("any_peer", "reliable")
func server_request_laser_fire(
	origin: Vector3,
	direction: Vector3,
	requested_range: float,
	requested_cooldown: float
) -> void:
	if not multiplayer.is_server():
		return
	
	var shooter_peer_id := multiplayer.get_remote_sender_id()
	server_process_laser_fire(shooter_peer_id, origin, direction, requested_range, requested_cooldown)


func server_process_laser_fire(
	shooter_peer_id: int,
	origin: Vector3,
	direction: Vector3,
	requested_range: float,
	requested_cooldown: float
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
	
	var allowed_cooldown := clampf(requested_cooldown, min_server_laser_cooldown, server_laser_cooldown)
	var current_time := Time.get_ticks_msec() / 1000.0
	
	if last_fire_time_by_peer_id.has(shooter_peer_id):
		var last_fire_time: float = last_fire_time_by_peer_id[shooter_peer_id]
		
		if current_time - last_fire_time < allowed_cooldown:
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
	var visual_end := end
	
	if not result.is_empty():
		visual_end = result["position"]
	
	rpc("client_show_remote_laser", shooter_peer_id, origin, visual_end)
	
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


@rpc("authority", "call_local", "unreliable")
func client_show_remote_laser(shooter_peer_id: int, origin: Vector3, end: Vector3) -> void:
	if shooter_peer_id == multiplayer.get_unique_id():
		return
	
	create_remote_laser_beam(origin, end)


func create_remote_laser_beam(origin: Vector3, end: Vector3) -> void:
	var direction := end - origin
	var length := direction.length()
	
	if length < 0.05:
		return
	
	var beam := MeshInstance3D.new()
	beam.name = "RemoteRedLaserBeam"
	
	var mesh := CylinderMesh.new()
	mesh.top_radius = remote_laser_radius
	mesh.bottom_radius = remote_laser_radius
	mesh.height = length
	mesh.radial_segments = 8
	mesh.material = remote_laser_material
	
	beam.mesh = mesh
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	var midpoint := origin + direction * 0.5
	var beam_basis := make_y_aligned_basis(direction.normalized())
	beam.global_transform = Transform3D(beam_basis, midpoint)
	
	var laser_parent: Node = self
	
	if players_parent != null and players_parent.get_parent() != null:
		laser_parent = players_parent.get_parent()
	
	laser_parent.add_child(beam)
	
	var timer := get_tree().create_timer(remote_laser_lifetime)
	timer.timeout.connect(
		func() -> void:
			if is_instance_valid(beam):
				beam.queue_free()
	)


func make_y_aligned_basis(y_axis: Vector3) -> Basis:
	y_axis = y_axis.normalized()
	
	var helper := Vector3.UP
	
	if absf(y_axis.dot(helper)) > 0.95:
		helper = Vector3.RIGHT
	
	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	
	return Basis(x_axis, y_axis, z_axis).orthonormalized()


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
