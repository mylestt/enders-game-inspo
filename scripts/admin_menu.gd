extends CanvasLayer

# Password-gated admin panel (centered). Opened from the pause menu. Actions route through
# ServerAdmin.submit_client_command(cmd, key); the server validates the key (which is the
# same password). The password is typed once, then remembered in GameSettings.

signal closed

const ADMIN_PASSWORD := "Aa123456!"

var network_manager: Node
var server_admin: Node

var password_box: VBoxContainer
var panel_box: VBoxContainer
var password_field: LineEdit
var password_status: Label
var players_column: VBoxContainer
var output_label: Label


func setup(nm: Node, sa: Node) -> void:
	network_manager = nm
	server_admin = sa

	if server_admin == null:
		server_admin = find_server_admin()

	if server_admin != null and server_admin.has_signal("admin_response_received"):
		server_admin.admin_response_received.connect(_on_admin_response)

	# Skip the prompt if the correct password was already entered and saved.
	if GameSettings.admin_password == ADMIN_PASSWORD:
		show_panel()
	else:
		show_password()


func _ready() -> void:
	layer = 130
	process_mode = Node.PROCESS_MODE_ALWAYS
	build_ui()


func build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.99)
	style.border_color = Color(0.6, 0.42, 0.42, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 26
	style.content_margin_right = 26
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var holder := VBoxContainer.new()
	holder.custom_minimum_size = Vector2(400.0, 0.0)
	holder.add_theme_constant_override("separation", 12)
	panel.add_child(holder)

	var title := Label.new()
	title.text = "ADMIN"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	holder.add_child(title)

	# --- Password view -------------------------------------------------------------
	password_box = VBoxContainer.new()
	password_box.add_theme_constant_override("separation", 10)
	holder.add_child(password_box)

	var pw_label := Label.new()
	pw_label.text = "Enter admin password"
	pw_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	password_box.add_child(pw_label)

	password_field = LineEdit.new()
	password_field.secret = true
	password_field.placeholder_text = "Password"
	password_field.custom_minimum_size = Vector2(0.0, 40.0)
	password_field.text_submitted.connect(_on_password_submitted)
	password_box.add_child(password_field)

	add_button(password_box, "Unlock", _on_unlock_pressed)

	password_status = Label.new()
	password_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	password_status.add_theme_color_override("font_color", Color(1.0, 0.6, 0.6, 0.9))
	password_box.add_child(password_status)

	add_button(password_box, "Close", _on_close_pressed)

	# --- Admin panel view ----------------------------------------------------------
	panel_box = VBoxContainer.new()
	panel_box.add_theme_constant_override("separation", 8)
	holder.add_child(panel_box)

	add_button(panel_box, "Restart Round", send_command.bind("restart_round"))
	add_button(panel_box, "Restart Match", send_command.bind("restart_match"))
	add_button(panel_box, "End Round", send_command.bind("end_round"))

	var players_title := Label.new()
	players_title.text = "Players   ( +1 point  /  +$1000  /  Kick )"
	players_title.add_theme_font_size_override("font_size", 15)
	panel_box.add_child(players_title)

	players_column = VBoxContainer.new()
	players_column.add_theme_constant_override("separation", 6)
	panel_box.add_child(players_column)

	output_label = Label.new()
	output_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	output_label.add_theme_font_size_override("font_size", 13)
	output_label.add_theme_color_override("font_color", Color(0.78, 0.9, 1.0, 0.9))
	output_label.custom_minimum_size = Vector2(0.0, 38.0)
	panel_box.add_child(output_label)

	add_button(panel_box, "Close", _on_close_pressed)

	password_box.visible = false
	panel_box.visible = false


func add_button(parent: Node, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 42.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 17)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func add_small_button(parent: Node, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(52.0, 32.0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func show_password() -> void:
	password_field.text = ""
	password_status.text = ""
	password_box.visible = true
	panel_box.visible = false
	password_field.grab_focus()


func show_panel() -> void:
	password_box.visible = false
	panel_box.visible = true
	refresh_players()


func refresh_players() -> void:
	for child in players_column.get_children():
		child.queue_free()

	if network_manager == null or not ("players_by_peer_id" in network_manager):
		return

	for peer_id in network_manager.players_by_peer_id.keys():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		var name_label := Label.new()
		var display_name := str(peer_id)

		if network_manager.has_method("get_player_name"):
			display_name = str(network_manager.call("get_player_name", peer_id)) + " (" + str(peer_id) + ")"

		name_label.text = display_name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		add_small_button(row, "+1", send_command.bind("add_score " + str(peer_id) + " 1"))
		add_small_button(row, "+$", send_command.bind("give_money " + str(peer_id) + " 1000"))
		add_small_button(row, "Kick", send_command.bind("kick " + str(peer_id)))

		players_column.add_child(row)


func send_command(command: String) -> void:
	if server_admin == null:
		server_admin = find_server_admin()

	if server_admin == null:
		output_label.text = "ServerAdmin node not found."
		return

	output_label.text = "> " + command
	server_admin.call("submit_client_command", command, GameSettings.admin_password)


func find_server_admin() -> Node:
	var scene := get_tree().current_scene

	if scene != null:
		return scene.get_node_or_null("ServerAdmin")

	return null


func _on_password_submitted(_text: String) -> void:
	try_unlock()


func _on_unlock_pressed() -> void:
	try_unlock()


func try_unlock() -> void:
	if password_field.text == ADMIN_PASSWORD:
		GameSettings.admin_password = password_field.text
		GameSettings.save()
		show_panel()
	else:
		password_status.text = "Incorrect password."
		password_field.text = ""


func _on_admin_response(response: String) -> void:
	if output_label != null:
		output_label.text = response


func _on_close_pressed() -> void:
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		closed.emit()
		get_viewport().set_input_as_handled()
