extends RefCounted
class_name GameSettings

# Persistent player settings. Static (like GameLaunch) so it survives scene changes
# without an autoload. load_and_apply() runs once at startup from the start menu and
# applies everything (keybinds -> InputMap, audio, video). Gameplay values (fov,
# mouse_sensitivity) are READ by the player/camera when it spawns.

const CONFIG_PATH := "user://settings.cfg"

const MIN_FOV := 70.0
const MAX_FOV := 110.0
const DEFAULT_FOV := 90.0
const DEFAULT_SENSITIVITY := 0.0025
const DEFAULT_VOLUME := 1.0
const DEFAULT_FULLSCREEN := false
const DEFAULT_SLIDE_TOGGLE := false
const DEFAULT_SLIDE_ON_BY_DEFAULT := false
# Sentinel for the roll settings: below zero = "player never touched this slider" — the
# game's export defaults on PlayerMovementController apply (so re-tuning those defaults
# reaches every player who hasn't customized).
const ROLL_UNSET := -1.0

static var fov: float = DEFAULT_FOV
static var mouse_sensitivity: float = DEFAULT_SENSITIVITY
static var master_volume: float = DEFAULT_VOLUME
static var fullscreen: bool = DEFAULT_FULLSCREEN
# Slide input mode: false = HOLD the slide key to keep sliding (default); true = TOGGLE —
# press once to slide, again to stop. (Ground-mode mounting itself is always automatic.)
static var slide_toggle_mode: bool = DEFAULT_SLIDE_TOGGLE
# Inverts the slide key: true = you slide AUTOMATICALLY whenever you're grounded with
# overspeed, and the slide key ENDS the slide instead of starting it (hold mode: holding
# interrupts; toggle mode: press to stop, press to resume).
static var slide_on_by_default: bool = DEFAULT_SLIDE_ON_BY_DEFAULT
# Zero-G roll feel — PER-PLAYER OVERRIDES of the movement controller's export defaults
# (ROLL_UNSET = follow the game). Read live via the coordinator's get_roll_*() getters.
# start/max in deg/s; the change rate (deg/s^2) governs the ramp up, the stop on release,
# and the shift-stabilize spin kill.
static var roll_start_speed: float = ROLL_UNSET
static var roll_max_speed: float = ROLL_UNSET
static var roll_speed_change_rate: float = ROLL_UNSET
# Remembered admin-menu password, so it only has to be typed once. Persisted to settings.cfg.
static var admin_password: String = ""
# Path to blender.exe for map-creator .blend imports (auto-detected when blank; the map
# creator asks for it once if detection fails). Persisted to settings.cfg.
static var blender_path: String = ""

# The project's original keybinds, captured before any saved overrides are applied,
# so "Reset to Defaults" can restore them.
static var _defaults_captured: bool = false
static var _default_events_by_action: Dictionary = {}


static func load_and_apply() -> void:
	capture_keybind_defaults_once()

	var config := ConfigFile.new()

	if config.load(CONFIG_PATH) == OK:
		fov = clampf(float(config.get_value("gameplay", "fov", DEFAULT_FOV)), MIN_FOV, MAX_FOV)
		mouse_sensitivity = float(config.get_value("gameplay", "mouse_sensitivity", DEFAULT_SENSITIVITY))
		master_volume = clampf(float(config.get_value("audio", "master_volume", DEFAULT_VOLUME)), 0.0, 1.0)
		fullscreen = bool(config.get_value("video", "fullscreen", DEFAULT_FULLSCREEN))
		slide_toggle_mode = bool(config.get_value("gameplay", "slide_toggle_mode", DEFAULT_SLIDE_TOGGLE))
		slide_on_by_default = bool(config.get_value("gameplay", "slide_on_by_default", DEFAULT_SLIDE_ON_BY_DEFAULT))
		roll_start_speed = _load_roll_override(config, "roll_start_speed", 0.0, 720.0)
		roll_max_speed = _load_roll_override(config, "roll_max_speed", 30.0, 1080.0)
		roll_speed_change_rate = _load_roll_override(config, "roll_speed_change_rate", 60.0, 2880.0)
		admin_password = String(config.get_value("admin", "password", ""))
		blender_path = String(config.get_value("tools", "blender_path", ""))
		apply_keybinds_from_config(config)

	apply_audio()
	apply_video()


static func save() -> void:
	var config := ConfigFile.new()
	config.set_value("gameplay", "fov", fov)
	config.set_value("gameplay", "mouse_sensitivity", mouse_sensitivity)
	config.set_value("gameplay", "slide_toggle_mode", slide_toggle_mode)
	config.set_value("gameplay", "slide_on_by_default", slide_on_by_default)
	config.set_value("gameplay", "roll_start_speed", roll_start_speed)
	config.set_value("gameplay", "roll_max_speed", roll_max_speed)
	config.set_value("gameplay", "roll_speed_change_rate", roll_speed_change_rate)
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("video", "fullscreen", fullscreen)
	config.set_value("admin", "password", admin_password)
	config.set_value("tools", "blender_path", blender_path)
	save_keybinds_to_config(config)
	config.save(CONFIG_PATH)


static func apply_audio() -> void:
	var master_index := AudioServer.get_bus_index("Master")

	if master_index < 0:
		master_index = 0

	AudioServer.set_bus_mute(master_index, master_volume <= 0.001)
	AudioServer.set_bus_volume_db(master_index, linear_to_db(maxf(master_volume, 0.001)))


static func apply_video() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


# All custom game actions (skips the engine's built-in `ui_*` so menu nav can't break).
static func get_bindable_actions() -> Array:
	var actions := []

	for action in InputMap.get_actions():
		if String(action).begins_with("ui_"):
			continue

		actions.append(action)

	return actions


static func capture_keybind_defaults_once() -> void:
	if _defaults_captured:
		return

	for action in get_bindable_actions():
		_default_events_by_action[action] = InputMap.action_get_events(action).duplicate()

	_defaults_captured = true


static func save_keybinds_to_config(config: ConfigFile) -> void:
	for action in get_bindable_actions():
		var events := InputMap.action_get_events(action)

		if events.is_empty():
			continue

		var data := event_to_data(events[0])

		if not data.is_empty():
			config.set_value("keybinds", String(action), data)


static func apply_keybinds_from_config(config: ConfigFile) -> void:
	if not config.has_section("keybinds"):
		return

	for action in config.get_section_keys("keybinds"):
		if not InputMap.has_action(action):
			continue

		var event := data_to_event(config.get_value("keybinds", action, {}))

		if event == null:
			continue

		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, event)


static func reset_to_defaults() -> void:
	fov = DEFAULT_FOV
	mouse_sensitivity = DEFAULT_SENSITIVITY
	master_volume = DEFAULT_VOLUME
	fullscreen = DEFAULT_FULLSCREEN
	slide_toggle_mode = DEFAULT_SLIDE_TOGGLE
	slide_on_by_default = DEFAULT_SLIDE_ON_BY_DEFAULT
	roll_start_speed = ROLL_UNSET
	roll_max_speed = ROLL_UNSET
	roll_speed_change_rate = ROLL_UNSET

	for action in _default_events_by_action.keys():
		InputMap.action_erase_events(action)

		for event in _default_events_by_action[action]:
			InputMap.action_add_event(action, event)

	apply_audio()
	apply_video()
	save()


# A stored roll override is clamped to its slider range; anything below zero (including
# the unset sentinel itself) means "no override — follow the game's defaults".
static func _load_roll_override(config: ConfigFile, key: String, lo: float, hi: float) -> float:
	var value := float(config.get_value("gameplay", key, ROLL_UNSET))

	if value < 0.0:
		return ROLL_UNSET

	return clampf(value, lo, hi)


static func event_to_data(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code := key_event.physical_keycode

		if code == 0:
			code = key_event.keycode

		return {"type": "key", "keycode": int(code)}

	if event is InputEventMouseButton:
		return {"type": "mouse", "button": int((event as InputEventMouseButton).button_index)}

	return {}


static func data_to_event(data) -> InputEvent:
	if typeof(data) != TYPE_DICTIONARY:
		return null

	match String(data.get("type", "")):
		"key":
			var key_event := InputEventKey.new()
			key_event.physical_keycode = int(data.get("keycode", 0))
			return key_event
		"mouse":
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = int(data.get("button", 0))
			return mouse_event

	return null
