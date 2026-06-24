extends RefCounted
class_name GameLaunch

# Carries the player's start-menu choice across the scene change into the game scene.
# Static so it survives changing scenes without needing an autoload. This only records
# "what did the player click" — NetworkManager / RoundManager own the actual logic.

enum Mode {
	NONE,
	TEST_ARENA,
	MULTIPLAYER,
	DEDICATED_SERVER,
}

static var pending_mode: int = Mode.NONE
static var join_ip: String = ""


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


static func _all_cmdline_args() -> PackedStringArray:
	var combined := PackedStringArray()
	combined.append_array(OS.get_cmdline_args())
	combined.append_array(OS.get_cmdline_user_args())
	return combined
