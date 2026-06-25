extends Node
class_name ServerAdmin

signal admin_response_received(response: String)

@export var round_manager_path: NodePath = NodePath("../RoundManager")
@export var network_manager_path: NodePath = NodePath("../NetworkManager")
@export var command_file_path: String = ""
@export var admin_key: String = ""
@export var poll_interval: float = 0.5

var round_manager: RoundManager
var network_manager: Node

var _poll_elapsed: float = 0.0
var _command_file_ready: bool = false
var _command_file_position: int = 0


func _ready() -> void:
	GameLaunch.apply_cmdline_overrides()

	round_manager = get_node_or_null(round_manager_path) as RoundManager
	network_manager = get_node_or_null(network_manager_path)
	admin_key = GameLaunch.read_cmdline_value("--admin-key", GameLaunch.admin_key)
	command_file_path = GameLaunch.read_cmdline_value("--admin-file", command_file_path)

	if command_file_path != "":
		print("Server admin command file: ", command_file_path)

	if admin_key == "":
		print("Server admin in-game commands disabled. Start with --admin-key <key> to enable them.")


func _process(delta: float) -> void:
	if not is_active_server():
		return

	if command_file_path == "":
		return

	_poll_elapsed += delta

	if _poll_elapsed < poll_interval:
		return

	_poll_elapsed = 0.0
	poll_command_file()


func is_active_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func poll_command_file() -> void:
	if not FileAccess.file_exists(command_file_path):
		_command_file_ready = false
		_command_file_position = 0
		return

	var file := FileAccess.open(command_file_path, FileAccess.READ)

	if file == null:
		return

	var length := file.get_length()

	if not _command_file_ready:
		_command_file_ready = true
		_command_file_position = length
		return

	if length < _command_file_position:
		_command_file_position = 0

	if length == _command_file_position:
		return

	file.seek(_command_file_position)

	while not file.eof_reached():
		var line := file.get_line().strip_edges()

		if line != "":
			var response := execute_command(line)
			print("ADMIN> ", line)
			print(response)

	_command_file_position = file.get_position()


func submit_client_command(command: String, key: String) -> void:
	if command.strip_edges() == "":
		return

	if multiplayer.multiplayer_peer == null:
		admin_response_received.emit("No multiplayer server connection.")
		return

	if multiplayer.is_server():
		var response := execute_command(command, multiplayer.get_unique_id())
		admin_response_received.emit(response)
		return

	rpc_id(1, "server_receive_admin_command", command, key)


@rpc("any_peer", "reliable")
func server_receive_admin_command(command: String, key: String) -> void:
	if not is_active_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	if admin_key == "":
		rpc_id(sender_id, "client_receive_admin_response", "In-game admin commands are disabled on this server.")
		return

	if key != admin_key:
		rpc_id(sender_id, "client_receive_admin_response", "Admin key rejected.")
		return

	var response := execute_command(command, sender_id)
	print("ADMIN RPC ", sender_id, "> ", command)
	print(response)
	rpc_id(sender_id, "client_receive_admin_response", response)


@rpc("authority", "reliable")
func client_receive_admin_response(response: String) -> void:
	admin_response_received.emit(response)


func execute_command(raw_command: String, source_peer_id: int = 0) -> String:
	if round_manager == null:
		round_manager = get_node_or_null(round_manager_path) as RoundManager

	if network_manager == null:
		network_manager = get_node_or_null(network_manager_path)

	var raw := raw_command.strip_edges()
	var parts := raw.split(" ", false)

	if parts.is_empty():
		return "No command."

	var command := String(parts[0]).to_lower()

	match command:
		"help":
			return help_text()
		"players":
			return players_text()
		"status", "start", "end", "end_round", "restart", "restart_round", "restart_match", "set_score", "add_score", "set_min_players", "set_points_to_win", "set_round_time", "rules":
			return run_round_command(raw)
		"set_starting_cash":
			return set_starting_cash_command(parts)
		"give_money", "add_money":
			return money_command(parts, true)
		"set_money":
			return money_command(parts, false)

	return "Unknown admin command: " + raw


func run_round_command(command: String) -> String:
	if round_manager == null:
		return "RoundManager missing."

	return round_manager.server_command(command)


func set_starting_cash_command(parts: PackedStringArray) -> String:
	if parts.size() < 2 or not String(parts[1]).is_valid_int():
		return "Usage: set_starting_cash <amount>"

	var amount := maxi(int(parts[1]), 0)
	GameLaunch.starting_cash = amount

	if network_manager != null and network_manager.has_method("server_set_starting_cash"):
		network_manager.call("server_set_starting_cash", amount)

	return "Starting cash set to " + str(amount) + " for future joins."


func money_command(parts: PackedStringArray, add_amount: bool) -> String:
	if parts.size() < 3:
		if add_amount:
			return "Usage: give_money <peer_id|all> <amount>"

		return "Usage: set_money <peer_id|all> <amount>"

	if network_manager == null:
		return "NetworkManager missing."

	var target := String(parts[1]).to_lower()
	var amount := int(parts[2])
	var targets := resolve_player_targets(target)

	if targets.is_empty():
		return "No matching players for target: " + target

	var changed: Array[String] = []

	for peer_id in targets:
		var ok := false

		if add_amount and network_manager.has_method("server_add_player_cash"):
			ok = bool(network_manager.call("server_add_player_cash", int(peer_id), amount))
		elif not add_amount and network_manager.has_method("server_set_player_cash"):
			ok = bool(network_manager.call("server_set_player_cash", int(peer_id), amount))

		if ok:
			changed.append(str(peer_id))

	if changed.is_empty():
		return "No player cash changed."

	var verb := "Added money to " if add_amount else "Set money for "
	return verb + ", ".join(changed) + " amount=" + str(amount)


func resolve_player_targets(target: String) -> Array:
	if network_manager == null:
		return []

	if target == "all":
		if "players_by_peer_id" in network_manager:
			return network_manager.players_by_peer_id.keys()

		return []

	if target.is_valid_int():
		return [int(target)]

	return []


func players_text() -> String:
	if network_manager != null and network_manager.has_method("get_player_summary"):
		return String(network_manager.call("get_player_summary"))

	return "Players unavailable."


func help_text() -> String:
	return (
		"Commands: status, players, rules, start, end_round [winner_peer_id], "
		+ "restart_round, restart_match, set_score <peer> <score>, add_score <peer> <amount>, "
		+ "set_min_players <count>, set_points_to_win <count>, set_round_time <seconds>, "
		+ "set_starting_cash <amount>, give_money <peer|all> <amount>, set_money <peer|all> <amount>"
	)
