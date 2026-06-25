extends CanvasLayer
class_name LobbyBrowser

# In-game lobby browser overlay. Lives in the game scene; stays hidden until the client
# receives a lobby list (i.e. it's in a "browse" session). Lets the player pick a lobby,
# enter a password if needed, and join. Hides itself once the player has joined/spawned.

@export var lobby_manager_path: NodePath = NodePath("../LobbyManager")
@export var network_manager_path: NodePath = NodePath("../NetworkManager")

var lobby_manager: Node
var root: Control
var list_box: VBoxContainer
var status_label: Label
var password_panel: PanelContainer
var password_field: LineEdit
var pending_join_id: int = -1


func _ready() -> void:
	layer = 80
	lobby_manager = get_node_or_null(lobby_manager_path)
	_build_ui()
	root.visible = false

	if lobby_manager != null:
		if lobby_manager.has_signal("lobby_list_received"):
			lobby_manager.connect("lobby_list_received", _on_lobby_list_received)
		if lobby_manager.has_signal("lobby_result"):
			lobby_manager.connect("lobby_result", _on_lobby_result)


func _build_ui() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.96)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(700.0, 520.0)
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
	title.text = "LOBBIES"
	title.add_theme_font_size_override("font_size", 30)
	column.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0.0, 330.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)

	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(list_box)

	status_label = Label.new()
	status_label.text = "Connecting…"
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.6))
	column.add_child(status_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	column.add_child(buttons)

	var refresh_btn := _make_button("Refresh", _on_refresh_pressed)
	refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(refresh_btn)

	var leave_btn := _make_button("Leave", _on_leave_pressed)
	leave_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(leave_btn)

	_build_password_panel()


func _build_password_panel() -> void:
	var pw_center := CenterContainer.new()
	pw_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	pw_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pw_center)

	password_panel = PanelContainer.new()
	password_panel.visible = false
	pw_center.add_child(password_panel)

	var pw_margin := MarginContainer.new()
	pw_margin.add_theme_constant_override("margin_left", 16)
	pw_margin.add_theme_constant_override("margin_right", 16)
	pw_margin.add_theme_constant_override("margin_top", 14)
	pw_margin.add_theme_constant_override("margin_bottom", 14)
	password_panel.add_child(pw_margin)

	var pw_col := VBoxContainer.new()
	pw_col.add_theme_constant_override("separation", 10)
	pw_col.custom_minimum_size = Vector2(320.0, 0.0)
	pw_margin.add_child(pw_col)

	var pw_label := Label.new()
	pw_label.text = "Lobby password"
	pw_col.add_child(pw_label)

	password_field = LineEdit.new()
	password_field.secret = true
	pw_col.add_child(password_field)

	var pw_buttons := HBoxContainer.new()
	pw_buttons.add_theme_constant_override("separation", 10)
	pw_col.add_child(pw_buttons)

	var ok := _make_button("Join", _on_password_confirmed)
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw_buttons.add_child(ok)

	var cancel := _make_button("Cancel", _on_password_cancel)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw_buttons.add_child(cancel)


func _on_lobby_list_received(list: Array) -> void:
	root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	for child in list_box.get_children():
		child.queue_free()

	if list.is_empty():
		status_label.text = "No lobbies yet. Back out and use Host to create one."
		return

	status_label.text = "Select a lobby to join."

	for lobby in list:
		_add_lobby_row(lobby)


func _add_lobby_row(lobby: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lock := "[P] " if bool(lobby.get("has_password", false)) else ""
	var info := Label.new()
	info.text = "%s%s    [%s]    %d/%d    %s" % [
		lock,
		String(lobby.get("name", "Lobby")),
		String(lobby.get("map", "Map")),
		int(lobby.get("players", 0)),
		int(lobby.get("max_players", 0)),
		String(lobby.get("state", "waiting")),
	]
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var join_btn := _make_button("Join", _on_join_lobby.bind(int(lobby.get("id", 1)), bool(lobby.get("has_password", false))))
	join_btn.custom_minimum_size = Vector2(120.0, 36.0)
	row.add_child(join_btn)

	list_box.add_child(row)


func _on_join_lobby(lobby_id: int, has_password: bool) -> void:
	if has_password:
		pending_join_id = lobby_id
		password_field.text = ""
		password_panel.visible = true
		return

	_request_join(lobby_id, "")


func _request_join(lobby_id: int, password: String) -> void:
	status_label.text = "Joining…"

	if lobby_manager != null:
		lobby_manager.call("client_request_join_lobby", lobby_id, password)


func _on_password_confirmed() -> void:
	password_panel.visible = false
	_request_join(pending_join_id, password_field.text)


func _on_password_cancel() -> void:
	password_panel.visible = false


func _on_lobby_result(success: bool, message: String) -> void:
	if success:
		root.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		status_label.text = message


func _on_refresh_pressed() -> void:
	status_label.text = "Refreshing…"

	if lobby_manager != null:
		lobby_manager.call("client_request_lobby_list")


func _on_leave_pressed() -> void:
	var network_manager := get_node_or_null(network_manager_path)

	if network_manager != null and network_manager.has_method("clear_runtime_multiplayer_state"):
		network_manager.call("clear_runtime_multiplayer_state")

	GameLaunch.pending_mode = GameLaunch.Mode.NONE
	get_tree().change_scene_to_file.call_deferred("res://scenes/start_menu.tscn")


func _make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 40.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 16)
	button.pressed.connect(handler)
	return button
