extends CanvasLayer
class_name AdminConsole

@export var server_admin_path: NodePath = NodePath("../ServerAdmin")
@export var network_manager_path: NodePath = NodePath("../NetworkManager")

var panel: PanelContainer
var key_field: LineEdit
var command_field: LineEdit
var output_label: Label
var server_admin: ServerAdmin


func _ready() -> void:
	layer = 120
	server_admin = get_node_or_null(server_admin_path) as ServerAdmin

	if server_admin != null:
		server_admin.admin_response_received.connect(_on_admin_response_received)

	build_ui()
	close_console()


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey

	if key_event == null or not key_event.pressed or key_event.echo:
		return

	if key_event.physical_keycode == KEY_F10:
		toggle_console()
		get_viewport().set_input_as_handled()


func build_ui() -> void:
	panel = PanelContainer.new()
	panel.name = "AdminConsolePanel"
	add_child(panel)
	panel.anchor_left = 1.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -560.0
	panel.offset_top = 18.0
	panel.offset_right = -18.0
	panel.offset_bottom = 260.0

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.04, 0.055, 0.96)
	style.border_color = Color(0.35, 0.42, 0.55, 0.75)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var title := Label.new()
	title.text = "ADMIN"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	column.add_child(title)

	key_field = LineEdit.new()
	key_field.placeholder_text = "Admin key"
	key_field.secret = true
	key_field.custom_minimum_size = Vector2(0.0, 34.0)
	column.add_child(key_field)

	var command_row := HBoxContainer.new()
	command_row.add_theme_constant_override("separation", 8)
	column.add_child(command_row)

	command_field = LineEdit.new()
	command_field.placeholder_text = "Command"
	command_field.custom_minimum_size = Vector2(0.0, 36.0)
	command_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_field.text_submitted.connect(_on_command_submitted)
	command_row.add_child(command_field)

	var send_button := Button.new()
	send_button.text = "Send"
	send_button.custom_minimum_size = Vector2(84.0, 36.0)
	send_button.focus_mode = Control.FOCUS_NONE
	send_button.pressed.connect(send_current_command)
	command_row.add_child(send_button)

	output_label = Label.new()
	output_label.text = ""
	output_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	output_label.add_theme_font_size_override("font_size", 13)
	output_label.add_theme_color_override("font_color", Color(0.78, 0.9, 1.0, 0.9))
	output_label.custom_minimum_size = Vector2(0.0, 94.0)
	column.add_child(output_label)


func toggle_console() -> void:
	if panel == null:
		return

	if panel.visible:
		close_console()
	else:
		open_console()


func open_console() -> void:
	panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_player_menu_lock(true)

	if command_field != null:
		command_field.grab_focus()


func close_console() -> void:
	var was_open := panel != null and panel.visible

	if panel != null:
		panel.visible = false

	# Only restore player input/mouse when the console was actually open (this also runs
	# once from _ready, before any player exists).
	if not was_open:
		return

	set_player_menu_lock(false)

	# Recapture only when there is a local player to give control back to; in menus (lobby
	# browser, pre-spawn) the mouse must stay visible.
	if get_local_player() != null:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func get_local_player() -> Node:
	var network_manager := get_node_or_null(network_manager_path)

	if network_manager != null and network_manager.has_method("get_local_player"):
		return network_manager.call("get_local_player")

	return null


func set_player_menu_lock(locked: bool) -> void:
	var player := get_local_player()

	if player != null and player.has_method("set_external_menu_open"):
		player.call("set_external_menu_open", locked)


func _on_command_submitted(_text: String) -> void:
	send_current_command()


func send_current_command() -> void:
	if server_admin == null:
		output_label.text = "ServerAdmin node missing."
		return

	var command := command_field.text.strip_edges()

	if command == "":
		return

	output_label.text = "> " + command
	server_admin.submit_client_command(command, key_field.text)
	command_field.clear()
	command_field.grab_focus()


func _on_admin_response_received(response: String) -> void:
	if output_label == null:
		return

	output_label.text = response
