extends RefCounted
class_name GameLaunch

# Carries the player's start-menu choice across the scene change into the game scene.
# Static so it survives changing scenes without needing an autoload. This only records
# "what did the player click" — NetworkManager / RoundManager own the actual logic.

enum Mode {
	NONE,
	TEST_ARENA,           # offline single-player
	MULTIPLAYER,          # direct IP join via --join cmdline
	MULTIPLAYER_BROWSE,   # connect to the VPS to browse its lobbies
	MULTIPLAYER_HOST,     # create a lobby on the VPS (you are still a client)
	DEDICATED_SERVER,     # headless server (runs on the VPS)
}

# The dedicated server players reach from the Multiplayer menu without typing an IP.
const DEFAULT_SERVER_IP := "147.182.160.52"

static var pending_mode: int = Mode.NONE
static var join_ip: String = ""
static var player_username: String = "Player"
static var username_configured: bool = false

# Which server the Multiplayer browse/host flow connects to (blank = DEFAULT_SERVER_IP).
static var server_ip: String = ""

# Lobby creation settings (Host flow); map/rules reuse the fields below.
static var lobby_name: String = ""
static var lobby_password: String = ""
static var max_players: int = 10

# Session rules. Dedicated servers can override these with command-line flags, and
# UI launch flows can set them before changing into the game scene.
static var rules_configured: bool = false
static var min_players_to_start: int = 2
static var starting_cash: int = 200000
static var points_to_win: int = 8
static var round_time_limit: float = 0.0
# Server admin key. In-game admin commands are DISABLED unless the server is started with
# --admin-key <key> (or ADMIN_KEY for tools/launch/run_server.sh) — never ship a real key as a default
# here, since it ends up readable inside every client build. The polled admin command file
# works regardless.
static var admin_key: String = ""

# Map selection from the map-setup menu, consumed by MapGenerator at runtime.
# Maps are hand-built scenes referenced by id; see Resources/Registries/map_registry.tres / MapGenerator.
static var map_configured: bool = false
static var map_id: String = "diamond"

# Start-menu Upload Test Map flow. The parsed scene is held only long enough to survive the
# scene change into main.tscn, then MapGenerator consumes it. This is deliberately local,
# transient, and unsupported by multiplayer/dedicated servers.
static var uploaded_test_map_path: String = ""
static var uploaded_test_map_scene: Node3D = null
static var uploaded_test_map_report: Dictionary = {}

# Test Arena only: AI drones (DroneSpawner in main.tscn reads this). Peaceful drones fly
# and chase but never shoot. Only the Test Arena map-setup menu can set this; every other
# launch path resets it to none.
const DRONES_NONE := 0
const DRONES_PEACEFUL := 1
const DRONES_AGGRESSIVE := 2
static var drone_mode: int = DRONES_NONE

# Game mode. "team" = team elimination (the original mode), "ffa" = free-for-all
# deathmatch (random edge spawns, per-player K/D, timed match, auto-respawn, random gun).
# RoundManager owns the authoritative copy and syncs it to clients; UI reads this field.
const GAME_MODES := ["team", "ffa", "ctf"]
static var game_mode_id: String = "team"
# FFA tuning, also settable in the host menu. round_time_limit doubles as the FFA time
# limit (0 → RoundManager falls back to a default). ffa_weapons lists the weapon ids a
# player may randomly spawn with; empty = every weapon. ffa_kill_limit ends the FFA match
# early when a player reaches that many kills (0 = time limit only).
static var ffa_respawn_time: float = 5.0
static var ffa_booster_fuel: float = 100.0
static var ffa_weapons: Array = []
static var ffa_kill_limit: int = 0
# Kill-reward rules (both modes): the killer is fully healed / has their ammo refilled on
# every confirmed kill.
static var heal_on_kill: bool = false
static var ammo_on_kill: bool = false


static func apply_cmdline_overrides() -> void:
	var username_value := read_cmdline_value("--username", "")

	if username_value == "":
		username_value = read_cmdline_value("--name", "")

	if username_value != "":
		set_player_username(username_value)

	min_players_to_start = read_cmdline_int("--min-players", min_players_to_start)
	starting_cash = read_cmdline_int("--starting-cash", starting_cash)
	points_to_win = read_cmdline_int("--points-to-win", points_to_win)
	round_time_limit = read_cmdline_float("--round-time", round_time_limit)
	ffa_respawn_time = read_cmdline_float("--respawn-time", ffa_respawn_time)
	ffa_booster_fuel = read_cmdline_float("--booster-fuel", ffa_booster_fuel)
	ffa_kill_limit = read_cmdline_int("--kill-limit", ffa_kill_limit)
	heal_on_kill = read_cmdline_bool("--heal-on-kill", heal_on_kill)
	ammo_on_kill = read_cmdline_bool("--ammo-on-kill", ammo_on_kill)
	admin_key = read_cmdline_value("--admin-key", admin_key)

	var mode_value := read_cmdline_value("--mode", "")

	if mode_value != "":
		game_mode_id = normalize_game_mode(mode_value)

	var weapons_value := read_cmdline_value("--ffa-weapons", "")

	if weapons_value != "":
		ffa_weapons = parse_weapon_list(weapons_value)

	if (
		read_cmdline_value("--min-players", "") != ""
		or read_cmdline_value("--starting-cash", "") != ""
		or read_cmdline_value("--points-to-win", "") != ""
		or read_cmdline_value("--round-time", "") != ""
		or read_cmdline_value("--respawn-time", "") != ""
		or read_cmdline_value("--booster-fuel", "") != ""
		or mode_value != ""
	):
		rules_configured = true

	var map_value := read_cmdline_value("--map", "")

	if map_value != "":
		apply_map_name(map_value)


static func apply_map_name(value: String) -> void:
	map_configured = true
	map_id = MapGenerator.normalize_map_id(value)


static func set_uploaded_test_map(path: String, scene: Node3D, report: Dictionary) -> void:
	clear_uploaded_test_map()
	uploaded_test_map_path = path
	uploaded_test_map_scene = scene
	uploaded_test_map_report = report.duplicate()
	uploaded_test_map_report.erase("scene")


static func consume_uploaded_test_map_scene() -> Node3D:
	var scene := uploaded_test_map_scene
	uploaded_test_map_scene = null
	return scene


static func clear_uploaded_test_map() -> void:
	if uploaded_test_map_scene != null and is_instance_valid(uploaded_test_map_scene):
		uploaded_test_map_scene.free()

	uploaded_test_map_scene = null
	uploaded_test_map_path = ""
	uploaded_test_map_report = {}


static func normalize_game_mode(value: String) -> String:
	match value.strip_edges().to_lower():
		"team", "teams", "elimination", "team_elimination":
			return "team"
		"ffa", "free_for_all", "freeforall", "free-for-all", "deathmatch", "dm":
			return "ffa"
		"ctf", "capture_the_flag", "capture-the-flag":
			return "ctf"

	return "team"


# Parses a comma-separated weapon-id list ("minigun,rifle") into normalized lowercase ids.
static func parse_weapon_list(value: String) -> Array:
	var out: Array = []

	for part in value.split(",", false):
		var id := String(part).strip_edges().to_lower()

		if id != "" and not out.has(id):
			out.append(id)

	return out


static func set_player_username(value: String) -> void:
	player_username = sanitize_username(value)
	username_configured = true


static func sanitize_username(value: String) -> String:
	var clean := value.strip_edges()

	if clean == "":
		return "Player"

	clean = clean.replace("\n", " ").replace("\r", " ").replace("\t", " ")

	while clean.find("  ") != -1:
		clean = clean.replace("  ", " ")

	if clean.length() > 18:
		clean = clean.substr(0, 18)

	return clean


# Reads the pending mode once, then clears it, so reloading the game scene later
# (e.g. returning to the menu and back) does not re-trigger an auto-start.
static func consume_mode() -> int:
	var mode := pending_mode
	pending_mode = Mode.NONE
	return mode


# True if `flag` was passed on the command line (engine args or user args after `--`).
static func read_cmdline_flag(flag: String) -> bool:
	for arg in _all_cmdline_args():
		if arg == flag:
			return true

	return false


# Reads a value passed as `--key value` or `--key=value`, else returns the default.
static func read_cmdline_value(key: String, default_value: String) -> String:
	var args := _all_cmdline_args()

	for i in range(args.size()):
		var arg := String(args[i])

		if arg == key and i + 1 < args.size():
			return String(args[i + 1])

		var prefix := key + "="

		if arg.begins_with(prefix):
			return arg.substr(prefix.length())

	return default_value


static func read_cmdline_int(key: String, default_value: int) -> int:
	var value := read_cmdline_value(key, "")

	if value == "" or not value.is_valid_int():
		return default_value

	return int(value)


static func read_cmdline_float(key: String, default_value: float) -> float:
	var value := read_cmdline_value(key, "")

	if value == "" or not value.is_valid_float():
		return default_value

	return float(value)


static func read_cmdline_bool(key: String, default_value: bool) -> bool:
	var value := read_cmdline_value(key, "")

	if value == "":
		return default_value

	match value.strip_edges().to_lower():
		"1", "true", "yes", "y", "on", "enabled":
			return true
		"0", "false", "no", "n", "off", "disabled":
			return false

	return default_value


static func _all_cmdline_args() -> PackedStringArray:
	var combined := PackedStringArray()
	combined.append_array(OS.get_cmdline_args())
	combined.append_array(OS.get_cmdline_user_args())
	return combined
