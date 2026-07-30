extends Node

# Server-only per-round telemetry recorder. Created ONLY on the dedicated server (see
# NetworkManager.start_dedicated_server / create_round_telemetry) because the server is the
# one place with a view of every connected player at once — nobody has to dig a report out
# of their own AppData and send it over anymore.
#
# Two files are written per round to user://round_telemetry/ on the machine running the
# server (the VPS, for a real match):
#   round_<timestamp>_timeline.csv   - one row per (tick, player): fps/ping/loss/position,
#                                       sampled at a fixed interval. Opens directly in
#                                       Excel/Sheets for graphing trends over the round.
#   round_<timestamp>_events.txt     - shots fired, deaths, spawns, as they happen.
#
# Performance note: sampling reads values Godot already has resident in memory (ENet peer
# stats, player positions) and just appends to an in-memory array — nothing touches disk
# until the round ends, so the per-tick cost is a handful of array appends, not file I/O.
# The only new network traffic is each client sending its own FPS (the one thing the server
# can't observe itself) as a single float on an unreliable RPC a few times a second — trivial
# next to the existing 30Hz per-player position sync.

@export var sample_interval: float = 0.1
# Safety cap so an untimed round can't grow the in-memory buffers forever
# (~10 rows/s x players; 200k rows is hours of play).
@export var max_rows_per_file: int = 200000

var network_manager: Node
var is_recording: bool = false

var _round_start_time: float = 0.0
var _sample_timer: float = 0.0
var _timeline_rows: Array[String] = []
var _event_rows: Array[String] = []
var _client_fps_by_peer: Dictionary = {}


func setup(nm: Node) -> void:
	network_manager = nm


func _process(delta: float) -> void:
	if not is_recording:
		return

	_sample_timer -= delta

	if _sample_timer > 0.0:
		return

	_sample_timer = sample_interval
	_sample_tick()


func start_round() -> void:
	is_recording = true
	_round_start_time = Time.get_ticks_msec() / 1000.0
	_sample_timer = 0.0
	_timeline_rows.clear()
	_event_rows.clear()
	# update_hz / gap_ms = how regularly THIS player's state packets arrive at the server.
	# A player whose update_hz collapses (or gap_ms spikes) is the one everyone else sees
	# stutter, even though their own screen looks smooth. That's the direct fingerprint of
	# the "I see them lag but they don't feel it" case.
	_timeline_rows.append("t,peer_id,player_name,fps,ping_ms,loss_pct,update_hz,gap_ms,pos_x,pos_y,pos_z")


func end_round() -> void:
	if not is_recording:
		return

	is_recording = false
	_write_files()


func record_client_fps(peer_id: int, fps: float) -> void:
	_client_fps_by_peer[peer_id] = fps


func record_weapon_fired(shooter_peer_id: int, origin: Vector3, did_hit: bool) -> void:
	if not is_recording or _event_rows.size() >= max_rows_per_file:
		return

	_event_rows.append(
		"[%s] SHOT peer=%d (%s) pos=(%.2f,%.2f,%.2f) hit=%s"
		% [
			_elapsed_label(),
			shooter_peer_id,
			_player_name(shooter_peer_id),
			origin.x, origin.y, origin.z,
			str(did_hit)
		]
	)


func record_player_died(dead_peer_id: int, attacker_peer_id: int) -> void:
	if not is_recording:
		return

	_event_rows.append(
		"[%s] DIED victim=%d (%s) attacker=%d (%s)"
		% [
			_elapsed_label(),
			dead_peer_id, _player_name(dead_peer_id),
			attacker_peer_id, _player_name(attacker_peer_id)
		]
	)


func record_player_spawned(peer_id: int, position: Vector3) -> void:
	if not is_recording:
		return

	_event_rows.append(
		"[%s] SPAWN peer=%d (%s) pos=(%.2f,%.2f,%.2f)"
		% [_elapsed_label(), peer_id, _player_name(peer_id), position.x, position.y, position.z]
	)


func record_round_state(state_name: String) -> void:
	if not is_recording:
		return

	_event_rows.append("[%s] ROUND_STATE -> %s" % [_elapsed_label(), state_name])


func _sample_tick() -> void:
	if network_manager == null:
		return

	if _timeline_rows.size() >= max_rows_per_file:
		return

	var t := _elapsed()

	# The server's own frame health (headless main-loop throughput), not tied to any player.
	# Built as an explicit array join (not a hand-counted comma literal) so the empty
	# player-specific fields can't silently drift the column count vs. the CSV header.
	_timeline_rows.append(",".join([
		"%.2f" % t, "0", "SERVER", "%.0f" % Engine.get_frames_per_second(),
		"", "", "", "", "", "", ""
	]))

	for peer_id in network_manager.players_by_peer_id.keys():
		var player = network_manager.players_by_peer_id[peer_id]

		if player == null or not (player is Node3D):
			continue

		var pos: Vector3 = (player as Node3D).global_position
		var fps: float = _client_fps_by_peer.get(peer_id, 0.0)
		# Explicitly typed: network_manager is a plain Node here, so GDScript can't infer the
		# float return type of get_enet_peer_stat() and := would fail to parse.
		var ping: float = network_manager.get_enet_peer_stat(int(peer_id), ENetPacketPeer.PEER_ROUND_TRIP_TIME)
		var loss: float = network_manager.get_enet_peer_stat(int(peer_id), ENetPacketPeer.PEER_PACKET_LOSS)
		var loss_pct := 0.0

		if loss >= 0.0:
			loss_pct = (loss / float(ENetPacketPeer.PACKET_LOSS_SCALE)) * 100.0

		# Server's inbound view of this player: how fast/steady their packets are arriving.
		var update_hz: float = network_manager.net_diag_rate_by_peer.get(peer_id, 0.0)
		var gap_ms: float = float(network_manager.net_diag_last_gap_by_peer.get(peer_id, 0.0)) * 1000.0

		_timeline_rows.append(",".join([
			"%.2f" % t, str(int(peer_id)), _player_name(int(peer_id)),
			"%.0f" % fps, "%.0f" % maxf(ping, 0.0), "%.2f" % loss_pct,
			"%.1f" % update_hz, "%.0f" % gap_ms,
			"%.2f" % pos.x, "%.2f" % pos.y, "%.2f" % pos.z
		]))


func _write_files() -> void:
	if _timeline_rows.size() <= 1 and _event_rows.is_empty():
		return   # nothing happened this round (e.g. it ended before any sample/event)

	var dir_path := "user://round_telemetry"
	DirAccess.make_dir_recursive_absolute(dir_path)

	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")

	var timeline_file := FileAccess.open(dir_path + "/round_" + stamp + "_timeline.csv", FileAccess.WRITE)

	if timeline_file != null:
		timeline_file.store_string("\n".join(_timeline_rows))
		timeline_file.close()

	var events_file := FileAccess.open(dir_path + "/round_" + stamp + "_events.txt", FileAccess.WRITE)

	if events_file != null:
		events_file.store_string("\n".join(_event_rows))
		events_file.close()

	print("Round telemetry written: ", ProjectSettings.globalize_path(dir_path), " (round_", stamp, "_*)")


func _elapsed() -> float:
	return (Time.get_ticks_msec() / 1000.0) - _round_start_time


func _elapsed_label() -> String:
	return "%.2fs" % _elapsed()


func _player_name(peer_id: int) -> String:
	if network_manager != null and network_manager.has_method("get_player_name"):
		return String(network_manager.call("get_player_name", peer_id))

	return "Player " + str(peer_id)
