extends CanvasLayer

# In-game Escape menu (Resume / Settings / Admin / Leave). Procedural per project convention.
# Works in both single-player Test Arena and multiplayer. Hosts the Settings panel and the
# password-gated Admin panel as sub-menus. Does NOT pause the SceneTree (that would freeze a
# multiplayer session); instead it locks the local player via set_external_menu_open().

var network_manager: Node
var server_admin: Node

var root: Control
var is_open: bool = false
var submenu: Node          # open Settings/Admin sub-menu, or null


func setup(nm: Node, sa: Node) -> void:
	network_manager = nm
	server_admin = sa


func _ready() -> void:
	layer = 110
	process_mode = Node.PROCESS_MODE_ALWAYS
	build_ui()
	root.visible = false


func build_ui() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.98)
	style.border_color = Color(0.4, 0.5, 0.65, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 26
	style.content_margin_right = 26
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(320.0, 0.0)
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	column.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	column.add_child(spacer)

	add_button(column, "Resume", _on_resume)
	add_button(column, "Settings", _on_settings)
	add_button(column, "Admin", _on_admin)
	add_button(column, "Leave Game", _on_leave)


func add_button(parent: Node, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 48.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 19)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return

	# A sub-menu (Settings/Admin) owns its own Escape; don't double-handle.
	if submenu != null and is_instance_valid(submenu):
		return

	# While closed, let an open buy menu keep Escape for itself.
	if not is_open and is_buy_menu_open():
		return

	toggle()
	get_viewport().set_input_as_handled()


func is_buy_menu_open() -> bool:
	if network_manager != null and "buy_menu" in network_manager and network_manager.buy_menu != null:
		var bm = network_manager.buy_menu

		if "menu_open" in bm:
			return bool(bm.menu_open)

	return false


func toggle() -> void:
	if is_open:
		close()
	else:
		open()


func open() -> void:
	is_open = true
	root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_player_menu_lock(true)


func close() -> void:
	is_open = false
	root.visible = false
	close_submenu()
	set_player_menu_lock(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_player_menu_lock(locked: bool) -> void:
	var player: Node = null

	if network_manager != null and network_manager.has_method("get_local_player"):
		player = network_manager.get_local_player()

	if player != null and player.has_method("set_external_menu_open"):
		player.call("set_external_menu_open", locked)


func _on_resume() -> void:
	close()


func _on_settings() -> void:
	if submenu != null and is_instance_valid(submenu):
		return

	var settings := SettingsMenu.new()
	submenu = settings
	add_child(settings)
	settings.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings.closed.connect(_on_submenu_closed.bind(settings))


func _on_admin() -> void:
	if submenu != null and is_instance_valid(submenu):
		return

	var admin = preload("res://Resources/Scripts/UI/admin_menu.gd").new()
	submenu = admin
	add_child(admin)

	if admin.has_method("setup"):
		admin.call("setup", network_manager, server_admin)

	if admin.has_signal("closed"):
		admin.connect("closed", _on_submenu_closed.bind(admin))


func _on_submenu_closed(menu: Node) -> void:
	if menu != null and is_instance_valid(menu):
		menu.queue_free()

	if submenu == menu:
		submenu = null


func close_submenu() -> void:
	if submenu != null and is_instance_valid(submenu):
		submenu.queue_free()

	submenu = null


func _on_leave() -> void:
	set_player_menu_lock(false)
	get_tree().paused = false

	if network_manager != null and network_manager.has_method("clear_runtime_multiplayer_state"):
		network_manager.call("clear_runtime_multiplayer_state")

	get_tree().change_scene_to_file.call_deferred("res://Resources/Scenes/Core/start_menu.tscn")
