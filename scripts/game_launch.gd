extends RefCounted
class_name GameLaunch

# Carries the player's start-menu choice across the scene change into the game scene.
# Static so it survives changing scenes without needing an autoload. This only records
# "what did the player click" — NetworkManager / RoundManager own the actual logic.

enum Mode {
	NONE,
	TEST_ARENA,
	MULTIPLAYER,          # direct IP join (advanced)
	MULTIPLAYER_BROWSE,   # connect to a server to browse its lobbies
	MULTIPLAYER_HOST,     # connect to a server and create a lobby
	HOST_SERVER,
	DEDICATED_SERVER,
}

# The dedicated server players reach from the Multiplayer menu without typing an IP.
const DEFAULT_SERVER_IP := "147.182.160.52"

static var pending_mode: int = Mode.NONE
static var join_ip: String = ""

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
static var admin_key: String = ""

# Map selection from the map-setup menu, consumed by MapGenerator at runtime.
static var map_configured: bool = false
static var map_use_default_arena: bool = false
static var map_style: int = 3
static var map_seed: int = 1
static var map_length: float = 90.0
static var map_width: float = 50.0
static var map_height: float = 40.0
static var map_density: float = 1.0
static var map_boundary: bool = true


static func apply_cmdline_overrides() -> void:
	min_players_to_start = read_cmdline_int("--min-players", min_players_to_start)
	starting_cash = read_cmdline_int("--starting-cash", starting_cash)
	points_to_win = read_cmdline_int("--points-to-win", points_to_win)
	round_time_limit = read_cmdline_float("--round-time", round_time_limit)
	admin_key = read_cmdline_value("--admin-key", admin_key)

	if (
		read_cmdline_value("--min-players", "") != ""
		or read_cmdline_value("--starting-cash", "") != ""
		or read_cmdline_value("--points-to-win", "") != ""
		or read_cmdline_value("--round-time", "") != ""
	):
		rules_configured = true

	var map_value := read_cmdline_value("--map", "")

	if map_value != "":
		apply_map_name(map_value)

	var map_style_value := read_cmdline_value("--map-style", "")

	if map_style_value != "":
		map_configured = true
		map_use_default_arena = false
		map_style = clampi(int(map_style_value), 0, 4)

	var default_arena_value := read_cmdline_value("--default-arena", "")

	if default_arena_value != "":
		map_configured = true
		map_use_default_arena = read_cmdline_bool("--default-arena", map_use_default_arena)

	map_seed = read_cmdline_int("--map-seed", map_seed)
	map_length = read_cmdline_float("--map-length", map_length)
	map_width = read_cmdline_float("--map-width", map_width)
	map_height = read_cmdline_float("--map-height", map_height)
	map_density = read_cmdline_float("--map-density", map_density)
	map_boundary = read_cmdline_bool("--map-boundary", map_boundary)

	if (
		map_value != ""
		or map_style_value != ""
		or default_arena_value != ""
		or read_cmdline_value("--map-seed", "") != ""
		or read_cmdline_value("--map-length", "") != ""
		or read_cmdline_value("--map-width", "") != ""
		or read_cmdline_value("--map-height", "") != ""
		or read_cmdline_value("--map-density", "") != ""
		or read_cmdline_value("--map-boundary", "") != ""
	):
		map_configured = true


static func apply_map_name(value: String) -> void:
	var key := value.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	map_configured = true

	match key:
		"default", "arena3", "default_arena", "default_arena_3":
			map_use_default_arena = true
		"core":
			map_use_default_arena = false
			map_style = 0
		"module", "module_station", "station":
			map_use_default_arena = false
			map_style = 1
		"asteroid", "asteroid_field":
			map_use_default_arena = false
			map_style = 2
		"designed":
			map_use_default_arena = false
			map_style = 3
		"2v2", "arena_2v2", "twovtwo":
			map_use_default_arena = false
			map_style = 4
		_:
			if key.is_valid_int():
				map_use_default_arena = false
				map_style = clampi(int(key), 0, 4)


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
