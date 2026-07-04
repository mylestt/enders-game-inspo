extends Control

# Front-end menu. Pure UI: it records the player's choice on GameLaunch and changes
# scene. It does not host, join, or own any game state. The arena scene's
# NetworkManager reads the launch mode and acts on it.

var main_view: VBoxContainer
var multiplayer_view: VBoxContainer
var username_view: VBoxContainer
var username_field: LineEdit
var username_status_label: Label
var server_ip_field: LineEdit
var joke_popup: PanelContainer
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

	username_view = build_username_view()
	center.add_child(username_view)

	main_view = build_main_view()
	center.add_child(main_view)

	multiplayer_view = build_multiplayer_view()
	multiplayer_view.visible = false
	center.add_child(multiplayer_view)

	if GameLaunch.username_configured:
		show_view(main_view)
	else:
		show_view(username_view)


func build_username_view() -> VBoxContainer:
	var column := make_column()

	column.add_child(make_title("ENTER NAME"))
	column.add_child(make_spacer(10.0))

	username_field = LineEdit.new()
	username_field.text = GameLaunch.player_username
	username_field.placeholder_text = "Username"
	username_field.max_length = 18
	username_field.custom_minimum_size = Vector2(0.0, 44.0)
	username_field.add_theme_font_size_override("font_size", 18)
	username_field.text_submitted.connect(_on_username_submitted)
	column.add_child(username_field)

	add_menu_button(column, "Continue", _on_username_continue_pressed)

	username_status_label = make_status_label("Choose the name other players will see.")
	column.add_child(username_status_label)

	call_deferred("_focus_username_field")

	return column


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

	# Which server Join/Host talk to. Blank = the official server; 127.0.0.1 = a local
	# dedicated server (host_server.bat) for development.
	server_ip_field = LineEdit.new()
	server_ip_field.text = GameLaunch.server_ip
	server_ip_field.placeholder_text = "Server IP — blank = official (" + GameLaunch.DEFAULT_SERVER_IP + ")"
	server_ip_field.custom_minimum_size = Vector2(0.0, 40.0)
	server_ip_field.add_theme_font_size_override("font_size", 15)
	column.add_child(server_ip_field)

	add_menu_button(column, "Join", _on_join_pressed)
	add_menu_button(column, "Host", _on_host_pressed)
	add_menu_button(column, "Back", _on_back_pressed)

	column.add_child(make_spacer(10.0))

	multiplayer_status_label = make_status_label("Join lists the server's lobbies. Host creates one. Leave the IP blank for the official server.")
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
	if username_view != null:
		username_view.visible = view == username_view

	if main_view != null:
		main_view.visible = view == main_view

	if multiplayer_view != null:
		multiplayer_view.visible = view == multiplayer_view


func _focus_username_field() -> void:
	if username_field != null and username_view != null and username_view.visible:
		username_field.grab_focus()
		username_field.select_all()


func _on_username_submitted(_text: String) -> void:
	_on_username_continue_pressed()


func _on_username_continue_pressed() -> void:
	if username_field == null:
		return

	var clean := GameLaunch.sanitize_username(username_field.text)

	if clean == "":
		if username_status_label != null:
			username_status_label.text = "Enter a username."
		return

	GameLaunch.set_player_username(clean)
	username_field.text = GameLaunch.player_username
	show_view(main_view)

	if should_show_name_joke(clean):
		show_name_joke_popup()


func should_show_name_joke(player_name: String) -> bool:
	var key := player_name.strip_edges().to_lower()
	return key == "naked snake" or key == "aaron" or key == "leprosy_sowles"


func show_name_joke_popup() -> void:
	if joke_popup != null and is_instance_valid(joke_popup):
		joke_popup.queue_free()

	joke_popup = PanelContainer.new()
	joke_popup.name = "NameJokePopup"
	add_child(joke_popup)
	joke_popup.anchor_left = 0.5
	joke_popup.anchor_right = 0.5
	joke_popup.anchor_top = 0.0
	joke_popup.anchor_bottom = 0.0
	joke_popup.offset_left = -170.0
	joke_popup.offset_right = 170.0
	joke_popup.offset_top = 28.0
	joke_popup.offset_bottom = 92.0
	joke_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.03, 0.045, 0.94)
	style.border_color = Color(1.0, 0.25, 0.34, 0.86)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	joke_popup.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = "HEY WHORE"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.9, 1.0))
	joke_popup.add_child(label)

	var tween := create_tween()
	tween.tween_interval(0.95)
	tween.tween_property(joke_popup, "modulate:a", 0.0, 0.28)
	tween.tween_callback(joke_popup.queue_free)


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
	# Blank falls through to DEFAULT_SERVER_IP in NetworkManager._resolve_server_ip.
	if server_ip_field != null:
		return server_ip_field.text.strip_edges()

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
