extends Control

# Front-end menu. Pure UI: it records the player's choice on GameLaunch and changes
# scene. It does not host, join, or own any game state. The arena scene's
# NetworkManager reads the launch mode and acts on it.

var main_view: VBoxContainer
var multiplayer_view: VBoxContainer
var ip_field: LineEdit
var status_label: Label
var multiplayer_status_label: Label


func _ready() -> void:
	# Load + apply saved settings (keybinds, FOV, audio, video) before any launch path,
	# so they take effect even when we boot straight into a server/client below.
	GameSettings.load_and_apply()
	GameLaunch.apply_cmdline_overrides()

	# Headless/dedicated launch (e.g. `godot --headless -- --server --port 7000`):
	# skip the menu entirely and boot straight into the game scene as a server.
	if GameLaunch.read_cmdline_flag("--server"):
		GameLaunch.pending_mode = GameLaunch.Mode.DEDICATED_SERVER
		get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
		return

	# Client launch (e.g. `godot -- --join 127.0.0.1`): connect automatically.
	if has_join_argument():
		GameLaunch.join_ip = resolve_join_ip()
		GameLaunch.pending_mode = GameLaunch.Mode.MULTIPLAYER
		get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	build_ui()


func has_join_argument() -> bool:
	return GameLaunch.read_cmdline_flag("--join") or GameLaunch.read_cmdline_value("--join", "") != ""


func resolve_join_ip() -> String:
	var ip := GameLaunch.read_cmdline_value("--join", "127.0.0.1")

	if ip == "":
		ip = "127.0.0.1"

	return ip


func build_ui() -> void:
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color(0.04, 0.05, 0.07, 1.0)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	main_view = build_main_view()
	center.add_child(main_view)

	multiplayer_view = build_multiplayer_view()
	multiplayer_view.visible = false
	center.add_child(multiplayer_view)


func build_main_view() -> VBoxContainer:
	var column := make_column()

	column.add_child(make_title("ZERO-G ARENA"))

	var subtitle := Label.new()
	subtitle.text = "Prototype Build"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.75, 0.82, 1.0, 0.6))
	column.add_child(subtitle)

	column.add_child(make_spacer(18.0))

	add_menu_button(column, "Test Arena", _on_test_arena_pressed)
	add_menu_button(column, "Multiplayer", _on_multiplayer_pressed)
	add_menu_button(column, "Settings", _on_settings_pressed)
	add_menu_button(column, "Quit", _on_quit_pressed)

	column.add_child(make_spacer(8.0))

	status_label = make_status_label("Test Arena drops you into the arena solo.")
	column.add_child(status_label)

	return column


func build_multiplayer_view() -> VBoxContainer:
	var column := make_column()

	column.add_child(make_title("MULTIPLAYER"))
	column.add_child(make_spacer(10.0))

	add_menu_button(column, "Join", _on_join_pressed)
	add_menu_button(column, "Host", _on_host_pressed)
	add_menu_button(column, "Back", _on_back_pressed)

	column.add_child(make_spacer(10.0))

	var ip_label := Label.new()
	ip_label.text = "Advanced — Direct Server IP (blank = default)"
	ip_label.add_theme_font_size_override("font_size", 13)
	ip_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	column.add_child(ip_label)

	ip_field = LineEdit.new()
	ip_field.placeholder_text = GameLaunch.DEFAULT_SERVER_IP
	ip_field.custom_minimum_size = Vector2(0.0, 40.0)
	ip_field.add_theme_font_size_override("font_size", 16)
	column.add_child(ip_field)

	column.add_child(make_spacer(6.0))

	multiplayer_status_label = make_status_label("Join browses lobbies on the server. Host creates one.")
	column.add_child(multiplayer_status_label)

	return column


func make_column() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(380.0, 0.0)
	column.add_theme_constant_override("separation", 14)
	return column


func make_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 46)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.96))
	return label


func make_status_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	return label


func add_menu_button(parent: Node, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 52.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func make_spacer(height: float) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, height)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func show_view(view: Control) -> void:
	if main_view != null:
		main_view.visible = view == main_view

	if multiplayer_view != null:
		multiplayer_view.visible = view == multiplayer_view


func _on_test_arena_pressed() -> void:
	var menu := MapSetupMenu.new()
	menu.launch_mode = GameLaunch.Mode.TEST_ARENA
	menu.title_text = "TEST ARENA SETUP"
	menu.default_min_players = 1
	add_child(menu)
	menu.closed.connect(_on_map_setup_closed.bind(menu))


func _on_map_setup_closed(menu: MapSetupMenu) -> void:
	menu.queue_free()


func _on_multiplayer_pressed() -> void:
	show_view(multiplayer_view)


func _on_host_pressed() -> void:
	GameLaunch.server_ip = _direct_server_ip()
	var menu := MapSetupMenu.new()
	menu.launch_mode = GameLaunch.Mode.MULTIPLAYER_HOST
	menu.title_text = "HOST LOBBY"
	menu.default_min_players = 2
	menu.show_lobby_fields = true
	add_child(menu)
	menu.closed.connect(_on_map_setup_closed.bind(menu))


func _direct_server_ip() -> String:
	# Blank means "use the default server" (NetworkManager fills in DEFAULT_SERVER_IP).
	if ip_field != null and ip_field.text.strip_edges() != "":
		return ip_field.text.strip_edges()

	return ""


func _on_back_pressed() -> void:
	show_view(main_view)


func _on_settings_pressed() -> void:
	var settings := SettingsMenu.new()
	add_child(settings)
	settings.closed.connect(_on_settings_closed.bind(settings))


func _on_settings_closed(settings: SettingsMenu) -> void:
	settings.queue_free()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_join_pressed() -> void:
	GameLaunch.server_ip = _direct_server_ip()
	GameLaunch.pending_mode = GameLaunch.Mode.MULTIPLAYER_BROWSE
	get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
