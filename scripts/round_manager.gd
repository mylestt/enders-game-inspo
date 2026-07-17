extends Node
class_name RoundManager

# Server-authoritative round flow, one independent SESSION per open lobby (LobbyManager runs
# up to MAX_LOBBIES concurrently). Each session owns its own state machine, scores, timers,
# mode, and rules; only the server drives transitions, and every broadcast goes to that
# lobby's members only. Clients keep a flat mirror of THEIR lobby's state (the client_*
# RPC handlers below), so client UI reads the same fields it always did. Player and UI
# scripts may REPORT events and READ state, but must never change round state directly.

signal round_state_changed(state: int)
signal round_time_changed(seconds_remaining: float)
signal team_scores_changed(team_scores: Dictionary)
# Fired once when a match is decided; `result` carries the winner for the GameOverHUD.
signal match_ended(result: Dictionary)
# Fired when this client's game mode is (re)configured, so mode-aware UI can relayout.
signal game_mode_changed(mode_id: String)
# Server-only: some lobby's session changed state. NetworkManager hooks telemetry, network
# reports, and round-start ammo refills onto this.
signal session_state_changed(lobby_id: int, state: int)

enum State {
	WAITING_FOR_PLAYERS,
	COUNTDOWN,
	ACTIVE,
	ROUND_END,
	MATCH_END,     # terminal: the match is over and the game-over screen is up
}

enum GameMode {
	TEAM,     # team elimination — round ends when a whole team is wiped; first to points_to_win
	FFA,      # free-for-all deathmatch — timed, per-player K/D, auto-respawn; most kills wins
	CTF,
}

# FFA falls back to this many seconds when no positive round_time is configured, so a
# free-for-all always has an end.
const FFA_DEFAULT_TIME_LIMIT := 300.0
# Implicit session covering ALL players on servers that don't run the lobby system
# (direct-connect/testing setups). Lobby servers never create it.
const DEFAULT_SESSION_ID := 0

@export var network_manager_path: NodePath = NodePath("../NetworkManager")
@export var lobby_manager_path: NodePath = NodePath("../LobbyManager")
@export var countdown_duration: float = 3.0
@export var round_end_duration: float = 4.0

var network_manager: Node
var lobby_manager: Node

# --- Client-side mirror of THIS machine's lobby (set by the client_* RPCs) -------------
var state: int = State.WAITING_FOR_PLAYERS
var state_timer: float = 0.0
var team_scores: Dictionary = {"a": 0, "b": 0}
var game_mode: int = GameMode.TEAM

# --- Server-side sessions: lobby_id -> session Dictionary (see _make_session) ----------
var sessions: Dictionary = {}

# Players whose `died` signal we have already connected, so we only hook each once.
var death_handler_by_peer_id: Dictionary = {}


func _ready() -> void:
	GameLaunch.apply_cmdline_overrides()
	game_mode = mode_from_id(GameLaunch.game_mode_id)

	network_manager = get_node_or_null(network_manager_path)
	lobby_manager = get_node_or_null(lobby_manager_path)

	if network_manager == null:
		push_warning("RoundManager could not find NetworkManager at " + str(network_manager_path) + ".")


func _process(delta: float) -> void:
	if not is_server():
		return

	hook_player_death_signals()
	_ensure_default_session()

	for lobby_id in sessions.keys():
		advance_session(sessions[lobby_id], delta)


# --- Session lifecycle (server) ---------------------------------------------------------

func _make_session(lobby_id: int, settings: Dictionary) -> Dictionary:
	return {
		"lobby_id": lobby_id,
		"state": State.WAITING_FOR_PLAYERS,
		"timer": 0.0,
		"team_scores": {"a": 0, "b": 0},
		"mode": mode_from_id(GameLaunch.normalize_game_mode(String(settings.get("game_mode", GameLaunch.game_mode_id)))),
		"min_players": maxi(int(settings.get("min_players", GameLaunch.min_players_to_start)), 1),
		"points_to_win": maxi(int(settings.get("points_to_win", GameLaunch.points_to_win)), 1),
		"round_time": maxf(float(settings.get("round_time", GameLaunch.round_time_limit)), 0.0),
		"respawn_time": maxf(float(settings.get("respawn_time", GameLaunch.ffa_respawn_time)), 0.5),
		"kill_limit": maxi(int(settings.get("kill_limit", GameLaunch.ffa_kill_limit)), 0),
		"pending_respawns": {},   # FFA: peer_id -> seconds until respawn
	}


func server_create_session(lobby_id: int, settings: Dictionary) -> void:
	if not is_server():
		return

	sessions[lobby_id] = _make_session(lobby_id, settings)
	print("RoundManager: session created for lobby ", lobby_id, " (", mode_to_id(int(sessions[lobby_id]["mode"])), ").")


func server_close_session(lobby_id: int) -> void:
	if sessions.erase(lobby_id):
		print("RoundManager: session closed for lobby ", lobby_id, ".")


# Direct-connect servers (no lobby system) get one implicit session over all players.
func _ensure_default_session() -> void:
	if sessions.has(DEFAULT_SESSION_ID):
		return

	if network_manager != null and bool(network_manager.get("lobby_mode")):
		return

	if get_players().is_empty():
		return

	sessions[DEFAULT_SESSION_ID] = _make_session(DEFAULT_SESSION_ID, {})


# Catches a freshly-joined peer up on its lobby's mode, scores, and state (also fixes the
# old late-joiner-sees-0-0 gap).
func server_sync_session_to_peer(lobby_id: int, peer_id: int) -> void:
	if not is_server() or not sessions.has(lobby_id) or peer_id == 1:
		return

	var s: Dictionary = sessions[lobby_id]
	rpc_id(peer_id, "client_sync_game_mode", mode_to_id(int(s["mode"])))
	rpc_id(peer_id, "client_sync_team_scores", s["team_scores"])
	rpc_id(peer_id, "client_sync_state", int(s["state"]), float(s["timer"]))


# --- Session state machine (server) -----------------------------------------------------

func advance_session(s: Dictionary, delta: float) -> void:
	var player_count := session_player_ids(s).size()
	var min_players := int(s["min_players"])

	match int(s["state"]):
		State.WAITING_FOR_PLAYERS:
			if player_count >= min_players:
				set_session_state(s, State.COUNTDOWN, countdown_duration)

		State.COUNTDOWN:
			if player_count < min_players:
				set_session_state(s, State.WAITING_FOR_PLAYERS)
				return

			s["timer"] = float(s["timer"]) - delta

			if float(s["timer"]) <= 0.0:
				session_start_round(s)

		State.ACTIVE:
			if player_count < min_players:
				set_session_state(s, State.WAITING_FOR_PLAYERS)
				return

			if session_is_ffa(s):
				_tick_session_respawns(s, delta)

			if session_time_limit(s) > 0.0:
				s["timer"] = float(s["timer"]) - delta

				if float(s["timer"]) <= 0.0:
					if session_is_ffa(s):
						session_end_match_ffa(s)
					else:
						session_end_round_team(s, "")   # "" = timed out, no winner

		State.ROUND_END:
			s["timer"] = float(s["timer"]) - delta

			if float(s["timer"]) <= 0.0:
				if session_match_over(s):
					session_end_match_team(s, session_leading_team(s))
				else:
					set_session_state(s, State.COUNTDOWN, countdown_duration)

		State.MATCH_END:
			# Terminal: hold on the game-over screen. If the lobby empties below the start
			# threshold, reset so a fresh match can begin when players return.
			if player_count < min_players:
				session_reset_match(s)


func session_start_round(s: Dictionary) -> void:
	(s["pending_respawns"] as Dictionary).clear()

	# The FFA "round" is the whole match, so its per-player K/D starts fresh here.
	if session_is_ffa(s) and network_manager != null and network_manager.has_method("server_reset_player_stats"):
		network_manager.call("server_reset_player_stats", session_player_ids(s))

	reset_session_players(s)
	set_session_state(s, State.ACTIVE, session_time_limit(s))


func reset_session_players(s: Dictionary) -> void:
	if network_manager == null:
		return

	var ffa := session_is_ffa(s)

	for peer_id in session_player_ids(s):
		var pid := int(peer_id)
		var spawn_transform: Transform3D

		if ffa:
			spawn_transform = network_manager.get_ffa_spawn_transform(session_player_positions(s, pid))
		else:
			var spawn_index := 0

			if "spawn_index_by_peer_id" in network_manager and network_manager.spawn_index_by_peer_id.has(pid):
				spawn_index = int(network_manager.spawn_index_by_peer_id[pid])

			spawn_transform = network_manager.get_spawn_transform(spawn_index)

		session_reset_player(s, pid, spawn_transform)

		# Fresh random gun + full boosters each FFA life (FFA has no buy menu).
		if ffa and network_manager.has_method("server_apply_ffa_loadout"):
			network_manager.call("server_apply_ffa_loadout", pid)


# Resets one player everywhere in the lobby: directly on the server's own copy, then on
# every member client.
func session_reset_player(s: Dictionary, peer_id: int, spawn_transform: Transform3D) -> void:
	client_reset_player(peer_id, spawn_transform)
	session_rpc(s, "client_reset_player", [peer_id, spawn_transform])


# --- FFA respawns & match end ------------------------------------------------------------

func _tick_session_respawns(s: Dictionary, delta: float) -> void:
	var pending: Dictionary = s["pending_respawns"]

	if pending.is_empty():
		return

	var ready_to_respawn: Array = []

	for peer_id in pending.keys():
		var remaining := float(pending[peer_id]) - delta

		if remaining <= 0.0:
			ready_to_respawn.append(peer_id)
		else:
			pending[peer_id] = remaining

	for peer_id in ready_to_respawn:
		pending.erase(peer_id)
		_ffa_respawn_player(s, int(peer_id))


func _ffa_respawn_player(s: Dictionary, peer_id: int) -> void:
	if network_manager == null or not get_players().has(peer_id):
		return

	var spawn_transform: Transform3D = network_manager.get_ffa_spawn_transform(session_player_positions(s, peer_id))
	session_reset_player(s, peer_id, spawn_transform)

	if network_manager.has_method("server_apply_ffa_loadout"):
		network_manager.call("server_apply_ffa_loadout", peer_id)


# Ends an FFA match: most kills wins (ties → draw).
func session_end_match_ffa(s: Dictionary) -> void:
	var leader := session_ffa_leader(s)
	var is_draw: bool = leader.is_empty() or bool(leader.get("tie", false))

	var result := {
		"mode": "ffa",
		"is_draw": is_draw,
		"winner_peer_id": 0 if is_draw else int(leader.get("peer_id", 0)),
		"winner_name": "" if is_draw else String(leader.get("name", "")),
		"winner_kills": int(leader.get("kills", 0)),
	}

	session_rpc(s, "client_match_ended", [result])
	match_ended.emit(result)
	set_session_state(s, State.MATCH_END)


# Ends a team match on the given winning team ("" = draw).
func session_end_match_team(s: Dictionary, winning_team: String) -> void:
	var result := {
		"mode": "team",
		"is_draw": winning_team == "",
		"winner_team": winning_team,
		"team_scores": (s["team_scores"] as Dictionary).duplicate(),
	}

	session_rpc(s, "client_match_ended", [result])
	match_ended.emit(result)
	set_session_state(s, State.MATCH_END)


func session_reset_match(s: Dictionary) -> void:
	s["team_scores"] = {"a": 0, "b": 0}
	(s["pending_respawns"] as Dictionary).clear()

	if network_manager != null and network_manager.has_method("server_reset_player_stats"):
		network_manager.call("server_reset_player_stats", session_player_ids(s))

	session_rpc(s, "client_sync_team_scores", [s["team_scores"]])
	set_session_state(s, State.WAITING_FOR_PLAYERS)


# The session's top-killer: { peer_id, name, kills, tie }. Empty if it has no players.
func session_ffa_leader(s: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_kills := -1
	var tie := false

	var stats_map: Dictionary = {}

	if network_manager != null and "player_stats_by_peer_id" in network_manager:
		stats_map = network_manager.player_stats_by_peer_id

	for peer_id in session_player_ids(s):
		var pid := int(peer_id)
		var stats: Dictionary = stats_map.get(pid, {})
		var kills := int(stats.get("kills", 0))

		if kills > best_kills:
			best_kills = kills
			tie = false
			var player_name := "Player " + str(pid)

			if network_manager != null and network_manager.has_method("get_player_name"):
				player_name = String(network_manager.call("get_player_name", pid))

			best = {"peer_id": pid, "name": player_name, "kills": kills}
		elif kills == best_kills:
			tie = true

	if not best.is_empty():
		best["tie"] = tie

	return best


# --- Deaths (server) ----------------------------------------------------------------------

# Called when a player is eliminated. Team mode ends the round when a whole team is wiped;
# FFA tallies the kill, queues the respawn, and checks the kill limit.
func server_on_player_died(dead_peer_id: int, attacker_peer_id: int) -> void:
	if not is_server():
		return

	var s := session_for_peer(dead_peer_id)

	if s.is_empty() or int(s["state"]) != State.ACTIVE:
		return

	if network_manager != null and network_manager.has_method("server_record_player_death"):
		network_manager.call("server_record_player_death", dead_peer_id, attacker_peer_id)

	if session_is_ffa(s):
		s["pending_respawns"][dead_peer_id] = float(s["respawn_time"])
		_check_ffa_kill_limit(s, attacker_peer_id, dead_peer_id)
		return

	var dead_team := _team_of(dead_peer_id)

	if _is_session_team_eliminated(s, dead_team):
		session_end_round_team(s, "b" if dead_team == "a" else "a")


func _check_ffa_kill_limit(s: Dictionary, attacker_peer_id: int, dead_peer_id: int) -> void:
	var limit := int(s["kill_limit"])

	if limit <= 0 or attacker_peer_id == 0 or attacker_peer_id == dead_peer_id:
		return

	var stats_map: Dictionary = {}

	if network_manager != null and "player_stats_by_peer_id" in network_manager:
		stats_map = network_manager.player_stats_by_peer_id

	var kills := int((stats_map.get(attacker_peer_id, {}) as Dictionary).get("kills", 0))

	if kills >= limit:
		session_end_match_ffa(s)


# Ends the round. "a"/"b" scores the point for that team; "" ends with no winner (draw).
func session_end_round_team(s: Dictionary, winning_team: String) -> void:
	if winning_team == "a" or winning_team == "b":
		var scores: Dictionary = s["team_scores"]
		scores[winning_team] = int(scores.get(winning_team, 0)) + 1
		session_rpc(s, "client_sync_team_scores", [scores])

	set_session_state(s, State.ROUND_END, round_end_duration)
	
# Called by a Flag node on confirmed capture. Adds the point to the capturing player's
# session/team, then checks the existing points_to_win threshold — reuses the same
# session_match_over / session_end_match_team path team mode already uses.
func server_register_flag_capture(capturing_peer_id: int, capturing_team: String) -> void:
	if not is_server():
		return

	if capturing_team != "a" and capturing_team != "b":
		return

	var s := session_for_peer(capturing_peer_id)

	if s.is_empty() or int(s["state"]) != State.ACTIVE:
		return

	if int(s["mode"]) != GameMode.CTF:
		return

	var scores: Dictionary = s["team_scores"]
	scores[capturing_team] = int(scores.get(capturing_team, 0)) + 1
	session_rpc(s, "client_sync_team_scores", [scores])

	if session_match_over(s):
		session_end_match_team(s, capturing_team)


# True only if the team has players in this session and none of them are still alive.
func _is_session_team_eliminated(s: Dictionary, team: String) -> bool:
	var players := get_players()
	var found_any := false

	for peer_id in session_player_ids(s):
		var pid := int(peer_id)

		if _team_of(pid) != team:
			continue

		found_any = true
		var player = players.get(pid)

		if player == null:
			continue

		var health := player.get_node_or_null("PlayerHealth") as PlayerHealth

		if health != null and health.current_health > 0.0:
			return false

	return found_any


func _team_of(peer_id: int) -> String:
	if network_manager != null and network_manager.has_method("get_team_for_peer"):
		return String(network_manager.call("get_team_for_peer", peer_id))

	return "a"


# --- Session helpers ----------------------------------------------------------------------

func session_is_ffa(s: Dictionary) -> bool:
	return int(s["mode"]) == GameMode.FFA


# FFA always needs an end, so a non-positive round_time falls back to the default.
# Team mode keeps its "0 = unlimited" meaning.
func session_time_limit(s: Dictionary) -> float:
	var limit := float(s["round_time"])

	if session_is_ffa(s):
		return limit if limit > 0.0 else FFA_DEFAULT_TIME_LIMIT

	return limit


func session_match_over(s: Dictionary) -> bool:
	var scores: Dictionary = s["team_scores"]
	var target := int(s["points_to_win"])
	return int(scores.get("a", 0)) >= target or int(scores.get("b", 0)) >= target


func session_leading_team(s: Dictionary) -> String:
	var scores: Dictionary = s["team_scores"]
	var a := int(scores.get("a", 0))
	var b := int(scores.get("b", 0))

	if a == b:
		return ""

	return "a" if a > b else "b"


# The session's spawned players (lobby members that have a player node). The default
# session spans every spawned player.
func session_player_ids(s: Dictionary) -> Array:
	var players := get_players()
	var lobby_id := int(s["lobby_id"])

	if lobby_id == DEFAULT_SESSION_ID:
		return players.keys()

	var ids: Array = []

	if lobby_manager != null and lobby_manager.has_method("get_lobby_members"):
		for peer_id in lobby_manager.call("get_lobby_members", lobby_id):
			if players.has(int(peer_id)):
				ids.append(int(peer_id))

	return ids


# Positions of the session's other players — used to spread FFA spawns away from the fight.
func session_player_positions(s: Dictionary, exclude_peer_id: int = -1) -> Array:
	var out: Array = []
	var players := get_players()

	for peer_id in session_player_ids(s):
		var pid := int(peer_id)

		if pid == exclude_peer_id:
			continue

		var player = players.get(pid)

		if player is Node3D:
			out.append((player as Node3D).global_position)

	return out


# The session's members that are real connected clients (RPC targets).
func session_client_peers(s: Dictionary) -> Array:
	var out: Array = []
	var connected := multiplayer.get_peers()

	for peer_id in session_player_ids(s):
		var pid := int(peer_id)

		if pid != 1 and connected.has(pid):
			out.append(pid)

	return out


# Sends an RPC to every member client of the session (the server's own copy, when needed,
# is handled by a direct local call at the call site).
func session_rpc(s: Dictionary, method: String, args: Array) -> void:
	for peer_id in session_client_peers(s):
		callv("rpc_id", [peer_id, method] + args)


func set_session_state(s: Dictionary, new_state: int, timer: float = 0.0) -> void:
	s["state"] = new_state
	s["timer"] = timer

	session_state_changed.emit(int(s["lobby_id"]), new_state)
	session_rpc(s, "client_sync_state", [new_state, timer])
	print("Lobby ", s["lobby_id"], " round state: ", state_name(new_state))


func session_for_peer(peer_id: int) -> Dictionary:
	if lobby_manager != null and lobby_manager.has_method("get_lobby_id_for_peer"):
		var lobby_id := int(lobby_manager.call("get_lobby_id_for_peer", peer_id))

		if sessions.has(lobby_id):
			return sessions[lobby_id]

	if sessions.has(DEFAULT_SESSION_ID):
		return sessions[DEFAULT_SESSION_ID]

	return {}


func get_session_state_label(lobby_id: int) -> String:
	if not sessions.has(lobby_id):
		return "waiting"

	match int(sessions[lobby_id]["state"]):
		State.COUNTDOWN:
			return "countdown"
		State.ACTIVE:
			return "in round"
		State.ROUND_END:
			return "round over"
		State.MATCH_END:
			return "match over"

	return "waiting"


func is_session_joinable(lobby_id: int) -> bool:
	# Every state is joinable today (late joiners spawn in); kept as the single gate should
	# that change.
	return sessions.has(lobby_id) or lobby_id == DEFAULT_SESSION_ID


# --- Client-side replication (this machine's lobby) ---------------------------------------

@rpc("authority", "reliable")
func client_sync_state(new_state: int, timer: float) -> void:
	state = new_state
	state_timer = timer
	round_state_changed.emit(state)


@rpc("authority", "reliable")
func client_sync_team_scores(new_scores: Dictionary) -> void:
	team_scores = new_scores.duplicate()
	team_scores_changed.emit(team_scores)


@rpc("authority", "reliable")
func client_sync_game_mode(mode_id: String) -> void:
	game_mode = mode_from_id(mode_id)
	GameLaunch.game_mode_id = mode_to_id(game_mode)
	game_mode_changed.emit(GameLaunch.game_mode_id)


@rpc("authority", "reliable")
func client_match_ended(result: Dictionary) -> void:
	match_ended.emit(result)


@rpc("authority", "call_local", "reliable")
func client_reset_player(peer_id: int, spawn_transform: Transform3D) -> void:
	var players := get_players()

	if not players.has(peer_id):
		return

	var player = players[peer_id]

	if player != null and player.has_method("reset_for_round"):
		player.reset_for_round(spawn_transform)


# --- Death-signal hookup (server only) -----------------------------------------------------

func hook_player_death_signals() -> void:
	var players := get_players()

	# Drop entries whose player is gone (disconnect/removal): the signal died with the freed
	# node, and keeping the key would block re-hooking a respawned node for a reused peer id
	# while growing the dictionary forever on a long-running server.
	for peer_id in death_handler_by_peer_id.keys():
		if not players.has(peer_id):
			death_handler_by_peer_id.erase(peer_id)

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


# --- Admin console dispatch ----------------------------------------------------------------
# With multiple concurrent lobbies, round commands apply to EVERY active session; the set_*
# commands also update the GameLaunch defaults new lobbies inherit.

func server_command(command: String) -> String:
	if not is_server():
		return "Not the server."

	var raw := command.strip_edges()
	var parts := raw.split(" ", false)

	if parts.is_empty():
		return "No command."

	match String(parts[0]).to_lower():
		"start":
			for s in sessions.values():
				if int(s["state"]) == State.WAITING_FOR_PLAYERS:
					set_session_state(s, State.COUNTDOWN, countdown_duration)

			return "Countdown started for waiting lobbies."
		"end", "end_round":
			var winner := ""

			if parts.size() >= 2:
				winner = normalize_team(String(parts[1]))

				if winner == "":
					return "Usage: end_round [a|b]  (no team = draw)"

			for s in sessions.values():
				if int(s["state"]) == State.ACTIVE and not session_is_ffa(s):
					session_end_round_team(s, winner)

			return "Round ended for active team lobbies. Winner: " + ("draw" if winner == "" else "team " + winner.to_upper())
		"restart", "restart_round":
			for s in sessions.values():
				set_session_state(s, State.COUNTDOWN, countdown_duration)

			return "Rounds restarting."
		"restart_match":
			for s in sessions.values():
				session_reset_match(s)

			return "Matches restarting."
		"status":
			return server_status_text()
		"set_score":
			if parts.size() < 3 or not String(parts[2]).is_valid_int():
				return "Usage: set_score <a|b> <score>"

			return server_set_team_score(String(parts[1]), int(parts[2]))
		"add_score":
			if parts.size() < 3 or not String(parts[2]).is_valid_int():
				return "Usage: add_score <a|b> <amount>"

			return server_add_team_score(String(parts[1]), int(parts[2]))
		"set_min_players":
			if parts.size() < 2:
				return "Usage: set_min_players <count>"

			GameLaunch.min_players_to_start = clampi(int(parts[1]), 1, 128)

			for s in sessions.values():
				s["min_players"] = GameLaunch.min_players_to_start

			return "Min players set to " + str(GameLaunch.min_players_to_start)
		"set_points_to_win":
			if parts.size() < 2:
				return "Usage: set_points_to_win <count>"

			GameLaunch.points_to_win = clampi(int(parts[1]), 1, 999)

			for s in sessions.values():
				s["points_to_win"] = GameLaunch.points_to_win

			return "Points to win set to " + str(GameLaunch.points_to_win)
		"set_round_time":
			if parts.size() < 2:
				return "Usage: set_round_time <seconds>"

			GameLaunch.round_time_limit = maxf(float(parts[1]), 0.0)

			for s in sessions.values():
				s["round_time"] = GameLaunch.round_time_limit

			return "Round time limit set to " + str(GameLaunch.round_time_limit)
		"set_respawn":
			if parts.size() < 2:
				return "Usage: set_respawn <seconds>"

			GameLaunch.ffa_respawn_time = maxf(float(parts[1]), 0.5)

			for s in sessions.values():
				s["respawn_time"] = GameLaunch.ffa_respawn_time

			return "Respawn time set to " + str(GameLaunch.ffa_respawn_time)
		"set_mode":
			if parts.size() < 2:
				return "Usage: set_mode <team|ffa>  (applies to NEW lobbies)"

			GameLaunch.game_mode_id = GameLaunch.normalize_game_mode(String(parts[1]))
			return "Default game mode for new lobbies: " + GameLaunch.game_mode_id
		"rules":
			return server_rules_text()

	return "Unknown command: " + raw


func server_status_text() -> String:
	if sessions.is_empty():
		return "No active lobby sessions.  Players connected: " + str(get_player_count())

	var lines: Array[String] = []

	for lobby_id in sessions.keys():
		var s: Dictionary = sessions[lobby_id]
		var scores: Dictionary = s["team_scores"]
		lines.append(
			"Lobby " + str(lobby_id)
			+ ": " + state_name(int(s["state"]))
			+ "  mode=" + mode_to_id(int(s["mode"]))
			+ "  players=" + str(session_player_ids(s).size())
			+ "  score A " + str(int(scores.get("a", 0))) + " - " + str(int(scores.get("b", 0))) + " B"
		)

	return "\n".join(lines)


func server_rules_text() -> String:
	return (
		"Defaults for new lobbies: mode=" + GameLaunch.game_mode_id
		+ "  min_players=" + str(GameLaunch.min_players_to_start)
		+ "  points_to_win=" + str(GameLaunch.points_to_win)
		+ "  round_time=" + str(GameLaunch.round_time_limit)
		+ "  respawn_time=" + str(GameLaunch.ffa_respawn_time)
		+ "  kill_limit=" + str(GameLaunch.ffa_kill_limit)
		+ "  sessions=" + str(sessions.size())
	)


func normalize_team(raw: String) -> String:
	var team := raw.strip_edges().to_lower()

	if team == "a" or team == "b":
		return team

	return ""


func server_set_team_score(raw_team: String, score: int) -> String:
	var team := normalize_team(raw_team)

	if team == "":
		return "Unknown team: " + raw_team + " (use a or b)"

	for s in sessions.values():
		(s["team_scores"] as Dictionary)[team] = maxi(score, 0)
		session_rpc(s, "client_sync_team_scores", [s["team_scores"]])

	return "Score set: team " + team.to_upper() + " = " + str(maxi(score, 0)) + " (all lobbies)"


func server_add_team_score(raw_team: String, amount: int) -> String:
	var team := normalize_team(raw_team)

	if team == "":
		return "Unknown team: " + raw_team + " (use a or b)"

	for s in sessions.values():
		var scores: Dictionary = s["team_scores"]
		scores[team] = maxi(int(scores.get(team, 0)) + amount, 0)
		session_rpc(s, "client_sync_team_scores", [scores])

	return "Score changed: team " + team.to_upper() + " (all lobbies)"


# --- Helpers --------------------------------------------------------------------------------

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


func is_ffa() -> bool:
	return game_mode == GameMode.FFA


func is_ctf() -> bool:
	return game_mode == GameMode.CTF


func mode_from_id(mode_id: String) -> int:
	if mode_id == "ffa":
		return GameMode.FFA
	if mode_id == "ctf":
		return GameMode.CTF
	return GameMode.TEAM


func mode_to_id(mode: int) -> String:
	match mode:
		GameMode.FFA:
			return "ffa"
		GameMode.CTF:
			return "ctf"
	return "team"


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
		State.MATCH_END:
			return "MATCH_END"

	return "UNKNOWN"
