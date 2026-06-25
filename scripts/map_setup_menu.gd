extends Control
class_name MapSetupMenu

# Map selection shown before launching a session. Writes the chosen map config onto
# GameLaunch and launches the game scene; the MapGenerator reads it on the other side.
# Built procedurally, reusable for the future multiplayer host flow.

signal closed

var launch_mode: int = GameLaunch.Mode.TEST_ARENA
var title_text: String = "MAP SETUP"
var default_min_players: int = 1
var show_lobby_fields: bool = false

var lobby_name_field: LineEdit
var lobby_password_check: CheckBox
var lobby_password_field: LineEdit
var max_players_spin: SpinBox

var style_option: OptionButton
var seed_spin: SpinBox
var min_players_spin: SpinBox
var starting_cash_spin: SpinBox
var points_to_win_spin: SpinBox
var round_time_spin: SpinBox
var length_slider: HSlider
var width_slider: HSlider
var height_slider: HSlider
var density_slider: HSlider
var boundary_check: CheckBox


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640.0, 600.0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 14)
	scroll.add_child(column)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 30)
	column.add_child(title)

	# Style (Core / Module Station / Asteroid Field / Default Arena 3).
	var style_row := HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 12)
	var style_label := Label.new()
	style_label.text = "Map Style"
	style_label.custom_minimum_size = Vector2(160.0, 0.0)
	style_row.add_child(style_label)
	style_option = OptionButton.new()
	style_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_option.add_item("Core", 0)
	style_option.add_item("Module Station", 1)
	style_option.add_item("Asteroid Field", 2)
	style_option.add_item("Designed", 3)
	style_option.add_item("2v2", 4)
	style_option.add_item("Default Arena 3", 5)
	style_option.selected = 5 if GameLaunch.map_use_default_arena else clampi(GameLaunch.map_style, 0, 4)
	style_row.add_child(style_option)
	column.add_child(style_row)

	# Seed.
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 12)
	var seed_label := Label.new()
	seed_label.text = "Seed"
	seed_label.custom_minimum_size = Vector2(160.0, 0.0)
	seed_row.add_child(seed_label)
	seed_spin = SpinBox.new()
	seed_spin.min_value = 0
	seed_spin.max_value = 999999
	seed_spin.step = 1
	seed_spin.value = GameLaunch.map_seed
	seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(seed_spin)
	column.add_child(seed_row)

	length_slider = _add_slider(column, "Arena Length", 40.0, 160.0, 1.0, GameLaunch.map_length, false, "")
	width_slider = _add_slider(column, "Arena Width", 30.0, 100.0, 1.0, GameLaunch.map_width, false, "")
	height_slider = _add_slider(column, "Arena Height", 25.0, 80.0, 1.0, GameLaunch.map_height, false, "")
	density_slider = _add_slider(column, "Cover Density", 0.3, 2.0, 0.1, GameLaunch.map_density, true, "x")

	# Boundary toggle.
	var boundary_row := HBoxContainer.new()
	boundary_row.add_theme_constant_override("separation", 12)
	var boundary_label := Label.new()
	boundary_label.text = "Boundary Walls"
	boundary_label.custom_minimum_size = Vector2(160.0, 0.0)
	boundary_row.add_child(boundary_label)
	boundary_check = CheckBox.new()
	boundary_check.button_pressed = GameLaunch.map_boundary
	boundary_row.add_child(boundary_check)
	column.add_child(boundary_row)

	var hint := Label.new()
	hint.text = "Size/density sliders are ignored for Designed and Default Arena 3."
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.5))
	column.add_child(hint)

	var rules_header := Label.new()
	rules_header.text = "RULES"
	rules_header.add_theme_font_size_override("font_size", 18)
	rules_header.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0, 0.95))
	column.add_child(rules_header)

	var min_players_value := GameLaunch.min_players_to_start

	if not GameLaunch.rules_configured:
		min_players_value = default_min_players

	min_players_spin = _add_spin(column, "Min Players", 1, 10, 1, min_players_value)
	starting_cash_spin = _add_spin(column, "Starting Cash", 0, 1000000, 1000, GameLaunch.starting_cash)
	points_to_win_spin = _add_spin(column, "Points To Win", 1, 99, 1, GameLaunch.points_to_win)
	round_time_spin = _add_spin(column, "Round Time", 0, 3600, 30, int(GameLaunch.round_time_limit))

	if show_lobby_fields:
		var lobby_header := Label.new()
		lobby_header.text = "LOBBY"
		lobby_header.add_theme_font_size_override("font_size", 18)
		lobby_header.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0, 0.95))
		column.add_child(lobby_header)

		lobby_name_field = _add_text_row(column, "Lobby Name", GameLaunch.lobby_name if GameLaunch.lobby_name != "" else "My Lobby")
		max_players_spin = _add_spin(column, "Max Players", 2, 10, 1, GameLaunch.max_players)

		var pw_row := HBoxContainer.new()
		pw_row.add_theme_constant_override("separation", 12)
		var pw_label := Label.new()
		pw_label.text = "Password"
		pw_label.custom_minimum_size = Vector2(160.0, 0.0)
		pw_row.add_child(pw_label)
		lobby_password_check = CheckBox.new()
		lobby_password_check.text = "On"
		pw_row.add_child(lobby_password_check)
		lobby_password_field = LineEdit.new()
		lobby_password_field.placeholder_text = "password"
		lobby_password_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pw_row.add_child(lobby_password_field)
		column.add_child(pw_row)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	column.add_child(bottom)

	var launch_button := _make_button("Launch", _on_launch_pressed)
	launch_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(launch_button)

	var back_button := _make_button("Back", _on_back_pressed)
	back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(back_button)


func _add_slider(parent: Node, label_text: String, min_value: float, max_value: float, step: float, value: float, is_float: bool, suffix: String) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(160.0, 0.0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0.0, 24.0)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(70.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text = (("%0.1f" % value) if is_float else str(int(value))) + suffix
	row.add_child(value_label)

	slider.value_changed.connect(func(v): value_label.text = (("%0.1f" % v) if is_float else str(int(v))) + suffix)

	parent.add_child(row)
	return slider


func _add_spin(parent: Node, label_text: String, min_value: int, max_value: int, step: int, value: int) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(160.0, 0.0)
	row.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin)

	parent.add_child(row)
	return spin


func _add_text_row(parent: Node, label_text: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(160.0, 0.0)
	row.add_child(label)

	var field := LineEdit.new()
	field.text = value
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)

	parent.add_child(row)
	return field


func _make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 18)
	button.pressed.connect(handler)
	return button


func _on_launch_pressed() -> void:
	var selected := style_option.get_selected_id()

	GameLaunch.map_configured = true
	GameLaunch.map_use_default_arena = selected == 5
	GameLaunch.map_style = clampi(selected, 0, 4)
	GameLaunch.map_seed = int(seed_spin.value)
	GameLaunch.map_length = length_slider.value
	GameLaunch.map_width = width_slider.value
	GameLaunch.map_height = height_slider.value
	GameLaunch.map_density = density_slider.value
	GameLaunch.map_boundary = boundary_check.button_pressed

	GameLaunch.rules_configured = true
	GameLaunch.min_players_to_start = int(min_players_spin.value)
	GameLaunch.starting_cash = int(starting_cash_spin.value)
	GameLaunch.points_to_win = int(points_to_win_spin.value)
	GameLaunch.round_time_limit = float(round_time_spin.value)

	if show_lobby_fields:
		GameLaunch.lobby_name = lobby_name_field.text.strip_edges()
		GameLaunch.max_players = int(max_players_spin.value)
		GameLaunch.lobby_password = lobby_password_field.text if lobby_password_check.button_pressed else ""

	GameLaunch.pending_mode = launch_mode
	get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _on_back_pressed() -> void:
	closed.emit()
