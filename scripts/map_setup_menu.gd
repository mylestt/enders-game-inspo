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

var map_option: OptionButton
var game_mode_option: OptionButton
var min_players_spin: SpinBox
var starting_cash_spin: SpinBox
var points_to_win_spin: SpinBox
var round_time_spin: SpinBox
var heal_on_kill_check: CheckBox
var ammo_on_kill_check: CheckBox
var drones_option: OptionButton

# Mode-specific control groups: exactly one is visible at a time, driven by the mode
# dropdown (_on_game_mode_selected), so each mode only shows its own settings.
var team_section: VBoxContainer
var ffa_section: VBoxContainer
var respawn_time_spin: SpinBox
var booster_fuel_spin: SpinBox
var kill_limit_spin: SpinBox
var weapon_checks: Dictionary = {}


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

	# Map picker — entries come from the MapGenerator registry (hand-built scenes).
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 12)
	var map_label := Label.new()
	map_label.text = "Map"
	map_label.custom_minimum_size = Vector2(160.0, 0.0)
	map_row.add_child(map_label)
	map_option = OptionButton.new()
	map_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var map_ids := MapGenerator.get_map_ids()

	# Custom (map-creator) maps are local files, so they're only offered for the offline
	# Test Arena — an online lobby's server has no way to load them (yet).
	if launch_mode == GameLaunch.Mode.TEST_ARENA:
		map_ids = map_ids + MapGenerator.get_custom_map_ids()

	for i in range(map_ids.size()):
		var id := String(map_ids[i])
		var label := MapGenerator.get_map_name(id)

		if MapGenerator.is_custom_map_id(id):
			label = "Custom: " + label

		map_option.add_item(label, i)
		map_option.set_item_metadata(i, id)

		if id == GameLaunch.map_id:
			map_option.selected = i

	map_row.add_child(map_option)
	column.add_child(map_row)

	# Online lobbies all share the server's one loaded map (spawn markers are global scene
	# groups). The first lobby on an empty server sets that map; later lobbies inherit it.
	# (the host pick below is honored server-side by LobbyManager._resolve_lobby_map_id).
	if show_lobby_fields:
		var map_note := Label.new()
		map_note.text = "The first lobby sets the map; later lobbies share it."
		map_note.add_theme_font_size_override("font_size", 12)
		map_note.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.45))
		column.add_child(map_note)

	# Game mode picker. Team = the original elimination mode; FFA reveals the extra
	# free-for-all settings below.
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 12)
	var mode_label := Label.new()
	mode_label.text = "Game Mode"
	mode_label.custom_minimum_size = Vector2(160.0, 0.0)
	mode_row.add_child(mode_label)
	game_mode_option = OptionButton.new()
	game_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_mode_option.add_item("Team Elimination", 0)
	game_mode_option.set_item_metadata(0, "team")
	game_mode_option.add_item("Free-For-All", 1)
	game_mode_option.set_item_metadata(1, "ffa")
	game_mode_option.add_item("Capture The Flag", 2)
	game_mode_option.set_item_metadata(2, "ctf")
	
	match GameLaunch.game_mode_id:
		"ffa":
			game_mode_option.selected = 1
		"ctf":
			game_mode_option.selected = 2
		_:
			game_mode_option.selected = 0
	
	game_mode_option.item_selected.connect(_on_game_mode_selected)
	mode_row.add_child(game_mode_option)
	column.add_child(mode_row)

	var rules_header := Label.new()
	rules_header.text = "RULES"
	rules_header.add_theme_font_size_override("font_size", 18)
	rules_header.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0, 0.95))
	column.add_child(rules_header)

	var min_players_value := GameLaunch.min_players_to_start

	if not GameLaunch.rules_configured:
		min_players_value = default_min_players

	# Shared rules — apply in every mode.
	min_players_spin = _add_spin(column, "Min Players", 1, 10, 1, min_players_value)
	round_time_spin = _add_spin(column, "Round Time / Time Limit", 0, 3600, 30, int(GameLaunch.round_time_limit))
	heal_on_kill_check = _add_check(column, "Full Heal On Kill", GameLaunch.heal_on_kill)
	ammo_on_kill_check = _add_check(column, "Ammo Refill On Kill", GameLaunch.ammo_on_kill)

	if launch_mode == GameLaunch.Mode.TEST_ARENA:
		var drones_row := HBoxContainer.new()
		drones_row.add_theme_constant_override("separation", 12)
		var drones_label := Label.new()
		drones_label.text = "Drones"
		drones_label.custom_minimum_size = Vector2(160.0, 0.0)
		drones_row.add_child(drones_label)
		drones_option = OptionButton.new()
		drones_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		drones_option.add_item("No Drones", GameLaunch.DRONES_NONE)
		drones_option.add_item("Peaceful Drones", GameLaunch.DRONES_PEACEFUL)
		drones_option.add_item("Aggressive Drones", GameLaunch.DRONES_AGGRESSIVE)
		drones_option.selected = GameLaunch.drone_mode
		drones_row.add_child(drones_option)
		column.add_child(drones_row)

	_build_team_section(column)
	_build_ffa_section(column)
	_on_game_mode_selected(game_mode_option.selected)

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


# Team-elimination-only block: economy and round-win settings (FFA has no buy menu and no
# team points, so these hide in FFA).
func _build_team_section(parent: Node) -> void:
	team_section = VBoxContainer.new()
	team_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	team_section.add_theme_constant_override("separation", 14)
	parent.add_child(team_section)

	var header := Label.new()
	header.text = "TEAM ELIMINATION"
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0, 0.95))
	team_section.add_child(header)

	starting_cash_spin = _add_spin(team_section, "Starting Cash", 0, 1000000, 1000, GameLaunch.starting_cash)
	points_to_win_spin = _add_spin(team_section, "Points To Win", 1, 99, 1, GameLaunch.points_to_win)


# Free-for-all-only block: respawn time, booster fuel, kill limit, and the weapon pool.
func _build_ffa_section(parent: Node) -> void:
	ffa_section = VBoxContainer.new()
	ffa_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ffa_section.add_theme_constant_override("separation", 14)
	parent.add_child(ffa_section)

	var header := Label.new()
	header.text = "FREE-FOR-ALL"
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", Color(1.0, 0.78, 0.5, 0.95))
	ffa_section.add_child(header)

	respawn_time_spin = _add_spin(ffa_section, "Respawn Time (s)", 1, 30, 1, int(GameLaunch.ffa_respawn_time))
	booster_fuel_spin = _add_spin(ffa_section, "Booster Fuel", 0, 1000, 10, int(GameLaunch.ffa_booster_fuel))
	kill_limit_spin = _add_spin(ffa_section, "Kill Limit (0 = none)", 0, 100, 1, GameLaunch.ffa_kill_limit)

	var weapons_label := Label.new()
	weapons_label.text = "Available Weapons (random spawn)"
	weapons_label.add_theme_font_size_override("font_size", 14)
	weapons_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.7))
	ffa_section.add_child(weapons_label)

	# Empty ffa_weapons means "all weapons", so every box starts checked in that case.
	var allow_all := GameLaunch.ffa_weapons.is_empty()

	for weapon_id in WeaponInventory.get_weapon_ids():
		var id := String(weapon_id)
		var check := CheckBox.new()
		# Display name comes from the weapon registry (weapon_registry.tres).
		check.text = WeaponInventory.get_weapon_name(weapon_id)
		check.button_pressed = allow_all or GameLaunch.ffa_weapons.has(id)
		ffa_section.add_child(check)
		weapon_checks[id] = check


# Shows exactly the selected mode's section (team settings in team mode, FFA settings in
# FFA) — never both.
func _on_game_mode_selected(_index: int) -> void:
	var mode := _selected_game_mode()
	var ffa := mode == "ffa"

	if team_section != null:
		team_section.visible = not ffa

	if ffa_section != null:
		ffa_section.visible = ffa


func _selected_game_mode() -> String:
	if game_mode_option == null:
		return GameLaunch.game_mode_id

	var meta = game_mode_option.get_item_metadata(game_mode_option.selected)
	return String(meta) if meta != null else "team"


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


func _add_check(parent: Node, label_text: String, value: bool) -> CheckBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(160.0, 0.0)
	row.add_child(label)

	var check := CheckBox.new()
	check.button_pressed = value
	row.add_child(check)

	parent.add_child(row)
	return check


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
	var selected_index := map_option.selected
	var selected_id: Variant = map_option.get_item_metadata(selected_index)

	GameLaunch.map_configured = true

	if selected_id != null:
		GameLaunch.map_id = String(selected_id)

	GameLaunch.rules_configured = true
	GameLaunch.min_players_to_start = int(min_players_spin.value)
	GameLaunch.starting_cash = int(starting_cash_spin.value)
	GameLaunch.points_to_win = int(points_to_win_spin.value)
	GameLaunch.round_time_limit = float(round_time_spin.value)

	GameLaunch.game_mode_id = _selected_game_mode()
	GameLaunch.heal_on_kill = heal_on_kill_check.button_pressed
	GameLaunch.ammo_on_kill = ammo_on_kill_check.button_pressed
	GameLaunch.drone_mode = drones_option.selected if drones_option != null else GameLaunch.DRONES_NONE
	GameLaunch.ffa_respawn_time = float(respawn_time_spin.value)
	GameLaunch.ffa_booster_fuel = float(booster_fuel_spin.value)
	GameLaunch.ffa_kill_limit = int(kill_limit_spin.value)
	GameLaunch.ffa_weapons = _selected_ffa_weapons()

	if show_lobby_fields:
		GameLaunch.lobby_name = lobby_name_field.text.strip_edges()
		GameLaunch.max_players = int(max_players_spin.value)
		GameLaunch.lobby_password = lobby_password_field.text if lobby_password_check.button_pressed else ""

	GameLaunch.pending_mode = launch_mode
	get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _on_back_pressed() -> void:
	closed.emit()


# The checked weapon ids. If every box (or none) is checked it returns [], meaning "all" —
# the server treats an empty pool as every weapon, so there's always something to spawn with.
func _selected_ffa_weapons() -> Array:
	var chosen: Array = []

	for weapon_id in WeaponInventory.get_weapon_ids():
		var id := String(weapon_id)
		var check: CheckBox = weapon_checks.get(id)

		if check != null and check.button_pressed:
			chosen.append(id)

	if chosen.size() == WeaponInventory.get_weapon_ids().size():
		return []

	return chosen
