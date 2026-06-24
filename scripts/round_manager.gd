extends Node
class_name RoundManager

# Server-authoritative round flow. RoundManager is the "boss": it owns round state,
# score, timers, and player resets. Only the server drives transitions; clients receive
# replicated state to display. Player and UI scripts may REPORT events and READ state,
# but must never change round state directly.
#
# Hooks into the rest of the game:
#   - Reads players/spawns from NetworkManager (public state, no edits needed there).
#   - Listens to each player's PlayerHealth.died to detect eliminations. That stays
#     dormant until a PlayerHealth node is added under the player scene.

signal round_state_changed(state: int)
signal score_changed(score_by_peer_id: Dictionary)
signal round_time_changed(seconds_remaining: float)

enum State {
	WAITING_FOR_PLAYERS,
	COUNTDOWN,
	ACTIVE,
	ROUND_END,
}

@export var network_manager_path: NodePath = NodePath("../NetworkManager")

@export var min_players_to_start: int = 2
@export var countdown_duration: float = 3.0
@export var round_time_limit: float = 0.0          # 0 = no round time limit
@export var round_end_duration: float = 4.0
@export var points_to_win: int = 8

var network_manager: Node

var state: int = State.WAITING_FOR_PLAYERS
var state_timer: float = 0.0
var score_by_peer_id: Dictionary = {}

# Players whose `died` signal we have already connected, so we only hook each once.
var death_handler_by_peer_id: Dictionary = {}


func _ready() -> void:
	network_manager = get_node_or_null(network_manager_path)

	if network_manager == null:
		push_warning("RoundManager could not find NetworkManager at " + str(network_manager_path) + ".")

	set_state(State.WAITING_FOR_PLAYERS)


func _process(delta: float) -> void:
	if not is_server():
		return

	hook_player_death_signals()
	advance_state(delta)


# --- State machine (server only) ---------------------------------------------------

func advance_state(delta: float) -> void:
	match state:
		State.WAITING_FOR_PLAYERS:
			if get_player_count() >= min_players_to_start:
				server_begin_countdown()

		State.COUNTDOWN:
			if get_player_count() < min_players_to_start:
				set_state(State.WAITING_FOR_PLAYERS)
				return

			state_timer -= delta
			round_time_changed.emit(maxf(state_timer, 0.0))

			if state_timer <= 0.0:
				server_start_round()

		State.ACTIVE:
			if get_player_count() < min_players_to_start:
				set_state(State.WAITING_FOR_PLAYERS)
				return

			if round_time_limit > 0.0:
				state_timer -= delta
				round_time_changed.emit(maxf(state_timer, 0.0))

				if state_timer <= 0.0:
					server_end_round(0)   # 0 = no winner (timed out / draw)

		State.ROUND_END:
			state_timer -= delta

			if state_timer <= 0.0:
				if is_match_over():
					server_restart_match()
				else:
					server_begin_countdown()


# --- Server API (the methods game logic and console commands call) -----------------

func server_begin_countdown() -> void:
	if not is_server():
		return

	set_state(State.COUNTDOWN, countdown_duration)


func server_start_round() -> void:
	if not is_server():
		return

	reset_all_players()
	set_state(State.ACTIVE, round_time_limit)


func server_end_round(winner_peer_id: int) -> void:
	if not is_server():
		return

	if winner_peer_id != 0:
		award_point(winner_peer_id)

	set_state(State.ROUND_END, round_end_duration)


func server_restart_round() -> void:
	if not is_server():
		return

	server_begin_countdown()


func server_restart_match() -> void:
	if not is_server():
		return

	score_by_peer_id.clear()
	broadcast_score()
	set_state(State.WAITING_FOR_PLAYERS)


# Called when a player is eliminated. 1v1 slice: the surviving player wins the round.
func server_on_player_died(dead_peer_id: int, attacker_peer_id: int) -> void:
	if not is_server():
		return

	if state != State.ACTIVE:
		return

	var winner := attacker_peer_id

	if winner == 0 or winner == dead_peer_id:
		winner = find_other_player(dead_peer_id)

	server_end_round(winner)


# Dispatch for a future server console / admin panel: start | end | restart | status.
func server_command(command: String) -> String:
	if not is_server():
		return "Not the server."

	match command.strip_edges().to_lower():
		"start":
			server_begin_countdown()
			return "Round starting."
		"end":
			server_end_round(0)
			return "Round ended."
		"restart":
			server_restart_round()
			return "Round restarting."
		"status":
			return server_status_text()

	return "Unknown command: " + command


func server_status_text() -> String:
	return (
		"State: " + state_name(state)
		+ "  Players: " + str(get_player_count())
		+ "  Score: " + str(score_by_peer_id)
	)


# --- Scoring -----------------------------------------------------------------------

func award_point(peer_id: int) -> void:
	score_by_peer_id[peer_id] = int(score_by_peer_id.get(peer_id, 0)) + 1
	broadcast_score()


func is_match_over() -> bool:
	for peer_id in score_by_peer_id.keys():
		if int(score_by_peer_id[peer_id]) >= points_to_win:
			return true

	return false


func find_other_player(excluded_peer_id: int) -> int:
	for peer_id in get_players().keys():
		if int(peer_id) != excluded_peer_id:
			return int(peer_id)

	return 0


# --- Player resets ------------------------------------------------------------------

func reset_all_players() -> void:
	if network_manager == null:
		return

	for peer_id in get_players().keys():
		var spawn_index := 0

		if "spawn_index_by_peer_id" in network_manager and network_manager.spawn_index_by_peer_id.has(peer_id):
			spawn_index = int(network_manager.spawn_index_by_peer_id[peer_id])

		var spawn_transform: Transform3D = network_manager.get_spawn_transform(spawn_index)
		rpc("client_reset_player", int(peer_id), spawn_transform)


@rpc("authority", "call_local", "reliable")
func client_reset_player(peer_id: int, spawn_transform: Transform3D) -> void:
	var players := get_players()

	if not players.has(peer_id):
		return

	var player = players[peer_id]

	if player != null and player.has_method("reset_for_round"):
		player.reset_for_round(spawn_transform)


# --- Death-signal hookup (server only) ---------------------------------------------

func hook_player_death_signals() -> void:
	var players := get_players()

	for peer_id in players.keys():
		if death_handler_by_peer_id.has(peer_id):
			continue

		var player = players[peer_id]

		if player == null:
			continue

		var health := player.get_node_or_null("PlayerHealth") as PlayerHealth

		if health == null or not health.has_signal("died"):
			continue

		var handler := _on_player_health_died.bind(int(peer_id))
		health.died.connect(handler)
		death_handler_by_peer_id[peer_id] = handler


# PlayerHealth.died emits the attacker id; the dead peer id is bound on connection.
func _on_player_health_died(attacker_peer_id: int, dead_peer_id: int) -> void:
	server_on_player_died(dead_peer_id, attacker_peer_id)


# --- State replication --------------------------------------------------------------

func set_state(new_state: int, timer: float = 0.0) -> void:
	state = new_state
	state_timer = timer

	if is_server():
		broadcast_state()

	round_state_changed.emit(state)
	print("Round state: ", state_name(state))


func broadcast_state() -> void:
	rpc("client_sync_state", state, state_timer)


@rpc("authority", "reliable")
func client_sync_state(new_state: int, timer: float) -> void:
	state = new_state
	state_timer = timer
	round_state_changed.emit(state)


func broadcast_score() -> void:
	rpc("client_sync_score", score_by_peer_id)
	score_changed.emit(score_by_peer_id)


@rpc("authority", "reliable")
func client_sync_score(new_score: Dictionary) -> void:
	score_by_peer_id = new_score.duplicate()
	score_changed.emit(score_by_peer_id)


# --- Helpers ------------------------------------------------------------------------

func is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func get_players() -> Dictionary:
	if network_manager != null and "players_by_peer_id" in network_manager:
		return network_manager.players_by_peer_id

	return {}


func get_player_count() -> int:
	return get_players().size()


func get_state() -> int:
	return state


func state_name(value: int) -> String:
	match value:
		State.WAITING_FOR_PLAYERS:
			return "WAITING_FOR_PLAYERS"
		State.COUNTDOWN:
			return "COUNTDOWN"
		State.ACTIVE:
			return "ACTIVE"
		State.ROUND_END:
			return "ROUND_END"

	return "UNKNOWN"
