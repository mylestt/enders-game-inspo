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
signal team_scores_changed(team_scores: Dictionary)

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
var team_scores: Dictionary = {"a": 0, "b": 0}

# Players whose `died` signal we have already connected, so we only hook each once.
var death_handler_by_peer_id: Dictionary = {}


func _ready() -> void:
	GameLaunch.apply_cmdline_overrides()
	min_players_to_start = maxi(GameLaunch.min_players_to_start, 1)
	points_to_win = maxi(GameLaunch.points_to_win, 1)
	round_time_limit = maxf(GameLaunch.round_time_limit, 0.0)

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
	team_scores = {"a": 0, "b": 0}

	if network_manager != null and network_manager.has_method("server_reset_player_stats"):
		network_manager.call("server_reset_player_stats")

	broadcast_score()
	broadcast_team_scores()
	set_state(State.WAITING_FOR_PLAYERS)


# Called when a player is eliminated. The round ends only when a whole team is wiped;
# the surviving team scores the point.
func server_on_player_died(dead_peer_id: int, attacker_peer_id: int) -> void:
	if not is_server():
		return

	if state != State.ACTIVE:
		return

	if network_manager != null and network_manager.has_method("server_record_player_death"):
		network_manager.call("server_record_player_death", dead_peer_id, attacker_peer_id)

	var dead_team := _team_of(dead_peer_id)

	if _is_team_eliminated(dead_team):
		var winning_team := "b" if dead_team == "a" else "a"
		server_end_round_team(winning_team)


func server_end_round_team(winning_team: String) -> void:
	if not is_server():
		return

	if winning_team == "a" or winning_team == "b":
		team_scores[winning_team] = int(team_scores.get(winning_team, 0)) + 1
		broadcast_team_scores()

	set_state(State.ROUND_END, round_end_duration)


func _team_of(peer_id: int) -> String:
	if network_manager != null and network_manager.has_method("get_team_for_peer"):
		return String(network_manager.call("get_team_for_peer", peer_id))

	return "a"


# True only if the team has players and none of them are still alive.
func _is_team_eliminated(team: String) -> bool:
	var players := get_players()
	var found_any := false

	for peer_id in players.keys():
		if _team_of(int(peer_id)) != team:
			continue

		found_any = true
		var player = players[peer_id]

		if player == null:
			continue

		var health := player.get_node_or_null("PlayerHealth") as PlayerHealth

		if health != null and health.current_health > 0.0:
			return false

	return found_any


func broadcast_team_scores() -> void:
	if is_server():
		rpc("client_sync_team_scores", team_scores)

	team_scores_changed.emit(team_scores)


@rpc("authority", "reliable")
func client_sync_team_scores(new_scores: Dictionary) -> void:
	team_scores = new_scores.duplicate()
	team_scores_changed.emit(team_scores)


# Dispatch for server console / admin panel commands.
func server_command(command: String) -> String:
	if not is_server():
		return "Not the server."

	var raw := command.strip_edges()
	var parts := raw.split(" ", false)

	if parts.is_empty():
		return "No command."

	match String(parts[0]).to_lower():
		"start":
			server_begin_countdown()
			return "Round starting."
		"end", "end_round":
			var winner := 0

			if parts.size() >= 2 and String(parts[1]).is_valid_int():
				winner = int(parts[1])

			server_end_round(winner)
			return "Round ended. Winner: " + str(winner)
		"restart", "restart_round":
			server_restart_round()
			return "Round restarting."
		"restart_match":
			server_restart_match()
			return "Match restarting."
		"status":
			return server_status_text()
		"set_score":
			if parts.size() < 3:
				return "Usage: set_score <peer_id> <score>"

			return server_set_score(int(parts[1]), int(parts[2]))
		"add_score":
			if parts.size() < 3:
				return "Usage: add_score <peer_id> <amount>"

			return server_add_score(int(parts[1]), int(parts[2]))
		"set_min_players":
			if parts.size() < 2:
				return "Usage: set_min_players <count>"

			return server_set_min_players_to_start(int(parts[1]))
		"set_points_to_win":
			if parts.size() < 2:
				return "Usage: set_points_to_win <count>"

			return server_set_points_to_win(int(parts[1]))
		"set_round_time":
			if parts.size() < 2:
				return "Usage: set_round_time <seconds>"

			return server_set_round_time_limit(float(parts[1]))
		"rules":
			return server_rules_text()

	return "Unknown command: " + raw


func server_status_text() -> String:
	return (
		"State: " + state_name(state)
		+ "  Players: " + str(get_player_count())
		+ "  Score: " + str(score_by_peer_id)
	)


func server_rules_text() -> String:
	return (
		"Rules: min_players=" + str(min_players_to_start)
		+ "  points_to_win=" + str(points_to_win)
		+ "  round_time=" + str(round_time_limit)
	)


# --- Scoring -----------------------------------------------------------------------

func award_point(peer_id: int) -> void:
	score_by_peer_id[peer_id] = int(score_by_peer_id.get(peer_id, 0)) + 1
	broadcast_score()


func server_set_score(peer_id: int, score: int) -> String:
	if not is_server():
		return "Not the server."

	score_by_peer_id[peer_id] = maxi(score, 0)
	broadcast_score()
	return "Score set: " + str(peer_id) + " = " + str(score_by_peer_id[peer_id])


func server_add_score(peer_id: int, amount: int) -> String:
	if not is_server():
		return "Not the server."

	score_by_peer_id[peer_id] = maxi(int(score_by_peer_id.get(peer_id, 0)) + amount, 0)
	broadcast_score()
	return "Score changed: " + str(peer_id) + " = " + str(score_by_peer_id[peer_id])


func server_set_min_players_to_start(count: int) -> String:
	if not is_server():
		return "Not the server."

	min_players_to_start = clampi(count, 1, 128)
	return "Min players set to " + str(min_players_to_start)


func server_set_points_to_win(count: int) -> String:
	if not is_server():
		return "Not the server."

	points_to_win = clampi(count, 1, 999)
	return "Points to win set to " + str(points_to_win)


func server_set_round_time_limit(seconds: float) -> String:
	if not is_server():
		return "Not the server."

	round_time_limit = maxf(seconds, 0.0)
	return "Round time limit set to " + str(round_time_limit)


func is_match_over() -> bool:
	return (
		int(team_scores.get("a", 0)) >= points_to_win
		or int(team_scores.get("b", 0)) >= points_to_win
	)


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
