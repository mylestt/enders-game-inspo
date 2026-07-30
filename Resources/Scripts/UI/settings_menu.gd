extends Control
class_name SettingsMenu

# Reusable settings overlay. Built procedurally; emits `closed` when the player backs
# out. Reads/writes GameSettings and applies changes live. Can be parented over the
# start menu now, and reused for an in-game pause menu later.

signal closed

var fov_slider: HSlider
var fov_value_label: Label
var sensitivity_slider: HSlider
var sensitivity_value_label: Label
var volume_slider: HSlider
var volume_value_label: Label
var fullscreen_check: CheckBox
var slide_toggle_check: CheckBox
var slide_default_check: CheckBox
var ground_mode_default_check: CheckBox
var mouse_roll_check: CheckBox
var mouse_roll_sens_container: Control
var mouse_roll_sens_value_label: Label
var roll_start_value_label: Label
var roll_max_value_label: Label
var roll_rate_value_label: Label

var keybind_buttons: Dictionary = {}
var listening_action: String = ""
var listening_button: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	build_ui()


func build_ui() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.02, 0.03, 0.05, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(660.0, 580.0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 30)
	column.add_child(title)

	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0.0, 440.0)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(tabs)

	var game_tab := build_game_tab()
	game_tab.name = "Game"
	tabs.add_child(game_tab)

	var keybinds_tab := build_keybinds_tab()
	keybinds_tab.name = "Keybinds"
	tabs.add_child(keybinds_tab)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	column.add_child(bottom)

	var reset_button := make_button("Reset to Defaults", _on_reset_pressed)
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(reset_button)

	var back_button := make_button("Back", _on_back_pressed)
	back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(back_button)


func build_game_tab() -> Control:
	var margin := make_tab_margin()

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)

	var fov_row := make_slider_row("Field of View", GameSettings.MIN_FOV, GameSettings.MAX_FOV, 1.0, GameSettings.fov)
	fov_slider = fov_row[1] as HSlider
	fov_value_label = fov_row[2] as Label
	fov_value_label.text = str(int(GameSettings.fov))
	fov_slider.value_changed.connect(_on_fov_changed)
	root.add_child(fov_row[0] as Control)

	# Sensitivity is scaled by 10000 to give a readable 5–100 dial.
	var sens_row := make_slider_row("Mouse Sensitivity", 5.0, 100.0, 1.0, GameSettings.mouse_sensitivity * 10000.0)
	sensitivity_slider = sens_row[1] as HSlider
	sensitivity_value_label = sens_row[2] as Label
	sensitivity_value_label.text = str(int(GameSettings.mouse_sensitivity * 10000.0))
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	root.add_child(sens_row[0] as Control)

	var vol_row := make_slider_row("Master Volume", 0.0, 100.0, 1.0, GameSettings.master_volume * 100.0)
	volume_slider = vol_row[1] as HSlider
	volume_value_label = vol_row[2] as Label
	volume_value_label.text = str(int(GameSettings.master_volume * 100.0)) + "%"
	volume_slider.value_changed.connect(_on_volume_changed)
	root.add_child(vol_row[0] as Control)

	var fs_row := HBoxContainer.new()
	fs_row.add_theme_constant_override("separation", 10)

	var fs_label := Label.new()
	fs_label.text = "Fullscreen"
	fs_label.custom_minimum_size = Vector2(200.0, 0.0)
	fs_row.add_child(fs_label)

	fullscreen_check = CheckBox.new()
	fullscreen_check.button_pressed = GameSettings.fullscreen
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	fs_row.add_child(fullscreen_check)

	root.add_child(fs_row)

	var slide_row := HBoxContainer.new()
	slide_row.add_theme_constant_override("separation", 10)

	var slide_setting_label := Label.new()
	slide_setting_label.text = "Slide Input"
	slide_setting_label.tooltip_text = "Hold: slide only while the key is held (default).\nToggle: press once to slide, press again to stop."
	slide_setting_label.custom_minimum_size = Vector2(200.0, 0.0)
	slide_row.add_child(slide_setting_label)

	slide_toggle_check = CheckBox.new()
	slide_toggle_check.button_pressed = GameSettings.slide_toggle_mode
	slide_toggle_check.text = "Toggle (off = Hold)"
	slide_toggle_check.toggled.connect(_on_slide_toggle_toggled)
	slide_row.add_child(slide_toggle_check)

	root.add_child(slide_row)

	var slide_default_row := HBoxContainer.new()
	slide_default_row.add_theme_constant_override("separation", 10)

	var slide_default_label := Label.new()
	slide_default_label.text = "Slide On By Default"
	slide_default_label.tooltip_text = "On: you slide automatically whenever you land with overspeed — the slide key STOPS the slide instead of starting it.\nOff: the slide key starts the slide (default)."
	slide_default_label.custom_minimum_size = Vector2(200.0, 0.0)
	slide_default_row.add_child(slide_default_label)

	slide_default_check = CheckBox.new()
	slide_default_check.button_pressed = GameSettings.slide_on_by_default
	slide_default_check.text = "Auto-slide (key ends the slide)"
	slide_default_check.toggled.connect(_on_slide_default_toggled)
	slide_default_row.add_child(slide_default_check)

	root.add_child(slide_default_row)

	var ground_mode_default_row := HBoxContainer.new()
	ground_mode_default_row.add_theme_constant_override("separation", 10)

	var ground_mode_default_label := Label.new()
	ground_mode_default_label.text = "Ground Mode On By Default"
	ground_mode_default_label.tooltip_text = "On: surface mounting is automatic; hold the Ground Mode Modifier to disengage and block it.\nOff: ground mode is blocked unless the modifier is held, and releasing it disengages immediately."
	ground_mode_default_label.custom_minimum_size = Vector2(200.0, 0.0)
	ground_mode_default_row.add_child(ground_mode_default_label)

	ground_mode_default_check = CheckBox.new()
	ground_mode_default_check.button_pressed = GameSettings.ground_mode_on_by_default
	ground_mode_default_check.toggled.connect(_on_ground_mode_default_toggled)
	ground_mode_default_row.add_child(ground_mode_default_check)
	refresh_ground_mode_default_text()

	root.add_child(ground_mode_default_row)

	# Zero-G roll feel. The sliders display the EFFECTIVE value: the player's saved
	# override, or the game's export defaults (PlayerMovementController) when untouched.
	# Moving a slider stores an override; Reset to Defaults clears them so the player
	# follows the game's tuning again. Applied live either way.
	var roll_defaults := get_roll_defaults()
	var start_value: float = GameSettings.roll_start_speed \
		if GameSettings.roll_start_speed >= 0.0 else float(roll_defaults["start"])
	var roll_start_row := make_slider_row("Roll Start Speed", 0.0, 360.0, 5.0, start_value)
	roll_start_value_label = roll_start_row[2] as Label
	roll_start_value_label.text = str(int(start_value)) + "°/s"
	(roll_start_row[1] as HSlider).value_changed.connect(_on_roll_start_changed)
	root.add_child(roll_start_row[0] as Control)

	var max_value: float = GameSettings.roll_max_speed \
		if GameSettings.roll_max_speed >= 0.0 else float(roll_defaults["max"])
	var roll_max_row := make_slider_row("Roll Max Speed", 60.0, 720.0, 10.0, max_value)
	roll_max_value_label = roll_max_row[2] as Label
	roll_max_value_label.text = str(int(max_value)) + "°/s"
	(roll_max_row[1] as HSlider).value_changed.connect(_on_roll_max_changed)
	root.add_child(roll_max_row[0] as Control)

	var rate_value: float = GameSettings.roll_speed_change_rate \
		if GameSettings.roll_speed_change_rate >= 0.0 else float(roll_defaults["rate"])
	var roll_rate_row := make_slider_row("Roll Responsiveness", 60.0, 2880.0, 30.0, rate_value)
	roll_rate_value_label = roll_rate_row[2] as Label
	roll_rate_value_label.text = str(int(rate_value)) + "°/s²"
	(roll_rate_row[1] as HSlider).value_changed.connect(_on_roll_rate_changed)
	root.add_child(roll_rate_row[0] as Control)

	# Mouse-roll modifier: while the Mouse Roll bind is held in zero-G, mouse X drives ROLL
	# around the aim instead of yaw, on its own sensitivity. Slider only shows while enabled.
	var mouse_roll_row := HBoxContainer.new()
	mouse_roll_row.add_theme_constant_override("separation", 10)

	var mouse_roll_label := Label.new()
	mouse_roll_label.text = "Mouse Roll Modifier"
	mouse_roll_label.tooltip_text = "Zero-G only: while the Mouse Roll key is held (rebind in Keybinds),\nmoving the mouse left/right ROLLS you around your aim instead of turning.\nA/D roll is ignored while held."
	mouse_roll_label.custom_minimum_size = Vector2(200.0, 0.0)
	mouse_roll_row.add_child(mouse_roll_label)

	mouse_roll_check = CheckBox.new()
	mouse_roll_check.button_pressed = GameSettings.mouse_roll_enabled
	mouse_roll_check.text = "Enabled (hold %s)" % get_action_display("mouse_roll")
	mouse_roll_check.toggled.connect(_on_mouse_roll_toggled)
	mouse_roll_row.add_child(mouse_roll_check)

	root.add_child(mouse_roll_row)

	var mouse_roll_sens_row := make_slider_row(
		"Mouse Roll Sensitivity", 5.0, 200.0, 1.0, GameSettings.mouse_roll_sensitivity * 10000.0
	)
	mouse_roll_sens_container = mouse_roll_sens_row[0] as Control
	mouse_roll_sens_value_label = mouse_roll_sens_row[2] as Label
	mouse_roll_sens_value_label.text = str(int(GameSettings.mouse_roll_sensitivity * 10000.0))
	(mouse_roll_sens_row[1] as HSlider).value_changed.connect(_on_mouse_roll_sens_changed)
	mouse_roll_sens_container.visible = GameSettings.mouse_roll_enabled
	root.add_child(mouse_roll_sens_container)

	return margin


func build_keybinds_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var margin := make_tab_margin()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	margin.add_child(list)

	keybind_buttons.clear()

	for action in GameSettings.get_bindable_actions():
		var action_name := String(action)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var label := Label.new()
		label.text = prettify_action(action_name)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var button := Button.new()
		button.custom_minimum_size = Vector2(220.0, 34.0)
		button.focus_mode = Control.FOCUS_NONE
		button.text = get_action_display(action_name)
		button.pressed.connect(_on_rebind_pressed.bind(action_name, button))
		row.add_child(button)

		keybind_buttons[action_name] = button
		list.add_child(row)

	return scroll


func make_tab_margin() -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	return margin


func make_slider_row(label_text: String, min_value: float, max_value: float, step: float, value: float) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(200.0, 0.0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(0.0, 24.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(64.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	return [row, slider, value_label]


func make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 18)
	button.pressed.connect(handler)
	return button


func _on_fov_changed(value: float) -> void:
	GameSettings.fov = value
	fov_value_label.text = str(int(value))
	GameSettings.save()


func _on_sensitivity_changed(value: float) -> void:
	GameSettings.mouse_sensitivity = value / 10000.0
	sensitivity_value_label.text = str(int(value))
	GameSettings.save()


func _on_volume_changed(value: float) -> void:
	GameSettings.master_volume = value / 100.0
	volume_value_label.text = str(int(value)) + "%"
	GameSettings.apply_audio()
	GameSettings.save()


func _on_fullscreen_toggled(pressed: bool) -> void:
	GameSettings.fullscreen = pressed
	GameSettings.apply_video()
	GameSettings.save()


func _on_slide_toggle_toggled(pressed: bool) -> void:
	GameSettings.slide_toggle_mode = pressed
	GameSettings.save()


func _on_slide_default_toggled(pressed: bool) -> void:
	GameSettings.slide_on_by_default = pressed
	GameSettings.save()


func _on_ground_mode_default_toggled(pressed: bool) -> void:
	GameSettings.ground_mode_on_by_default = pressed
	refresh_ground_mode_default_text()
	GameSettings.save()


func _on_mouse_roll_toggled(pressed: bool) -> void:
	GameSettings.mouse_roll_enabled = pressed

	if mouse_roll_sens_container != null:
		mouse_roll_sens_container.visible = pressed

	GameSettings.save()


func _on_mouse_roll_sens_changed(value: float) -> void:
	GameSettings.mouse_roll_sensitivity = value / 10000.0
	mouse_roll_sens_value_label.text = str(int(value))
	GameSettings.save()


# The game's baked roll defaults, read off a throwaway controller instance so the sliders
# can show them before any player exists (start menu). Scene overrides on the player's
# MovementController would not be seen here — tune the defaults in the SCRIPT exports.
static func get_roll_defaults() -> Dictionary:
	var controller := PlayerMovementController.new()
	var defaults := {
		"start": controller.roll_start_speed,
		"max": controller.roll_max_speed,
		"rate": controller.roll_speed_change_rate,
	}
	controller.free()
	return defaults


func _on_roll_start_changed(value: float) -> void:
	GameSettings.roll_start_speed = value
	roll_start_value_label.text = str(int(value)) + "°/s"
	GameSettings.save()


func _on_roll_max_changed(value: float) -> void:
	GameSettings.roll_max_speed = value
	roll_max_value_label.text = str(int(value)) + "°/s"
	GameSettings.save()


func _on_roll_rate_changed(value: float) -> void:
	GameSettings.roll_speed_change_rate = value
	roll_rate_value_label.text = str(int(value)) + "°/s²"
	GameSettings.save()


func _on_rebind_pressed(action: String, button: Button) -> void:
	if listening_action != "":
		refresh_keybind_button(listening_action)

	listening_action = action
	listening_button = button
	button.text = "Press a key…  (Esc to cancel)"


func _input(event: InputEvent) -> void:
	if listening_action == "":
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			cancel_listening()
			get_viewport().set_input_as_handled()
			return

		var key_event := InputEventKey.new()
		key_event.physical_keycode = (event as InputEventKey).physical_keycode
		commit_rebind(key_event)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event := InputEventMouseButton.new()
		mouse_event.button_index = (event as InputEventMouseButton).button_index
		commit_rebind(mouse_event)
		get_viewport().set_input_as_handled()


func commit_rebind(event: InputEvent) -> void:
	InputMap.action_erase_events(listening_action)
	InputMap.action_add_event(listening_action, event)
	GameSettings.save()
	refresh_keybind_button(listening_action)

	if listening_action == "mouse_roll" and mouse_roll_check != null:
		mouse_roll_check.text = "Enabled (hold %s)" % get_action_display("mouse_roll")

	if listening_action == "ground_mode_modifier":
		refresh_ground_mode_default_text()

	listening_action = ""
	listening_button = null


func refresh_ground_mode_default_text() -> void:
	if ground_mode_default_check == null:
		return

	var modifier := get_action_display("ground_mode_modifier")

	if GameSettings.ground_mode_on_by_default:
		ground_mode_default_check.text = "Automatic (hold %s to disengage)" % modifier
	else:
		ground_mode_default_check.text = "Hold %s to engage" % modifier


func cancel_listening() -> void:
	if listening_action != "":
		refresh_keybind_button(listening_action)

	listening_action = ""
	listening_button = null


func refresh_keybind_button(action: String) -> void:
	if keybind_buttons.has(action):
		(keybind_buttons[action] as Button).text = get_action_display(action)


func get_action_display(action: String) -> String:
	if not InputMap.has_action(action):
		return "Unbound"

	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			var key_event := event as InputEventKey
			var code := key_event.physical_keycode

			if code == 0:
				code = key_event.keycode

			return OS.get_keycode_string(code)

		if event is InputEventMouseButton:
			return mouse_button_name((event as InputEventMouseButton).button_index)

	return "Unbound"


func mouse_button_name(button_index: int) -> String:
	match button_index:
		MOUSE_BUTTON_LEFT:
			return "Mouse Left"
		MOUSE_BUTTON_RIGHT:
			return "Mouse Right"
		MOUSE_BUTTON_MIDDLE:
			return "Mouse Middle"
		MOUSE_BUTTON_WHEEL_UP:
			return "Wheel Up"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "Wheel Down"

	return "Mouse " + str(button_index)


func prettify_action(action: String) -> String:
	var words := action.split("_")

	for i in range(words.size()):
		if words[i].length() > 0:
			words[i] = words[i].substr(0, 1).to_upper() + words[i].substr(1)

	return " ".join(words)


func _on_reset_pressed() -> void:
	GameSettings.reset_to_defaults()
	listening_action = ""
	listening_button = null

	for child in get_children():
		child.queue_free()

	build_ui()


func _on_back_pressed() -> void:
	closed.emit()
