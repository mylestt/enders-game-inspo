extends CanvasLayer

@export var starting_cash: int = 20000
@export var pause_game_when_open: bool = false
@export var player_path: NodePath
@export var laser_controller_relative_path: NodePath = NodePath("Camera3D/LaserController")

var cash: int = 0
var is_open: bool = false

var player: Node
var laser_controller: Node

var menu_root: Control
var background: ColorRect
var panel: PanelContainer
var cash_label: Label
var message_label: Label
var status_label: Label
var category_container: VBoxContainer

var upgrade_buttons: Dictionary = {}

var shop_items: Array[Dictionary] = [
	{
		"id": "laser_follow_1",
		"category": "WEAPON UPGRADES",
		"upgrade_type": "laser_follow_speed",
		"level": 1,
		"name": "Laser Tracking Level 1",
		"price": 1000,
		"description": "Laser catches up to your mouse faster."
	},
	{
		"id": "laser_follow_2",
		"category": "WEAPON UPGRADES",
		"upgrade_type": "laser_follow_speed",
		"level": 2,
		"name": "Laser Tracking Level 2",
		"price": 2750,
		"description": "Noticeably faster tracking for aggressive aiming."
	},
	{
		"id": "laser_follow_3",
		"category": "WEAPON UPGRADES",
		"upgrade_type": "laser_follow_speed",
		"level": 3,
		"name": "Laser Tracking Level 3",
		"price": 5000,
		"description": "High-end tracking with very little aiming lag."
	},
	{
		"id": "laser_size_1",
		"category": "WEAPON UPGRADES",
		"upgrade_type": "laser_size",
		"level": 1,
		"name": "Laser Width Level 1",
		"price": 1250,
		"description": "Slightly thicker laser with small hit forgiveness."
	},
	{
		"id": "laser_size_2",
		"category": "WEAPON UPGRADES",
		"upgrade_type": "laser_size",
		"level": 2,
		"name": "Laser Width Level 2",
		"price": 3250,
		"description": "Wider beam and better close-miss forgiveness."
	},
	{
		"id": "laser_size_3",
		"category": "WEAPON UPGRADES",
		"upgrade_type": "laser_size",
		"level": 3,
		"name": "Laser Width Level 3",
		"price": 5500,
		"description": "Largest beam profile and strongest hit forgiveness."
	},
	{
		"id": "grab_distance_1",
		"category": "SUIT UPGRADES",
		"upgrade_type": "grab_distance",
		"level": 1,
		"name": "Grab Distance Level 1",
		"price": 1000,
		"description": "Slightly extends your wall grab range."
	},
	{
		"id": "grab_distance_2",
		"category": "SUIT UPGRADES",
		"upgrade_type": "grab_distance",
		"level": 2,
		"name": "Grab Distance Level 2",
		"price": 2500,
		"description": "Makes saving yourself from missed jumps easier."
	},
	{
		"id": "grab_distance_3",
		"category": "SUIT UPGRADES",
		"upgrade_type": "grab_distance",
		"level": 3,
		"name": "Grab Distance Level 3",
		"price": 4250,
		"description": "Maximum grab range for this test setup."
	},
	{
		"id": "suit_boosters",
		"category": "SPECIAL SUIT SYSTEMS",
		"upgrade_type": "suit_boosters",
		"level": 1,
		"name": "Suit Boosters",
		"price": 6000,
		"description": "Unlocks limited W/S propulsion. Fuel does not recharge."
	}
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	cash = starting_cash
	
	find_references()
	build_ui()
	close_menu()


func find_references() -> void:
	if player_path != NodePath(""):
		player = get_node_or_null(player_path)
	
	if player == null:
		push_warning("BuyMenu: Player Path is not assigned. Drag your Player node into Player Path.")
		return
	
	laser_controller = player.get_node_or_null(laser_controller_relative_path)
	
	if laser_controller == null:
		push_warning("BuyMenu: Could not find LaserController at " + str(laser_controller_relative_path))


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_buy_menu"):
		toggle_menu()
		get_viewport().set_input_as_handled()
	
	if is_open and event.is_action_pressed("ui_cancel"):
		close_menu()
		get_viewport().set_input_as_handled()


func build_ui() -> void:
	menu_root = Control.new()
	menu_root.name = "MenuRoot"
	menu_root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(menu_root)
	
	menu_root.anchor_left = 0.0
	menu_root.anchor_top = 0.0
	menu_root.anchor_right = 1.0
	menu_root.anchor_bottom = 1.0
	menu_root.offset_left = 0.0
	menu_root.offset_top = 0.0
	menu_root.offset_right = 0.0
	menu_root.offset_bottom = 0.0
	
	background = ColorRect.new()
	background.name = "Background"
	background.color = Color(0.0, 0.0, 0.0, 0.62)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	menu_root.add_child(background)
	
	background.anchor_left = 0.0
	background.anchor_top = 0.0
	background.anchor_right = 1.0
	background.anchor_bottom = 1.0
	background.offset_left = 0.0
	background.offset_top = 0.0
	background.offset_right = 0.0
	background.offset_bottom = 0.0
	
	panel = PanelContainer.new()
	panel.name = "BuyPanel"
	menu_root.add_child(panel)
	
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -520.0
	panel.offset_top = -330.0
	panel.offset_right = 520.0
	panel.offset_bottom = 330.0
	
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.06, 0.075, 0.97)
	panel_style.border_color = Color(1.0, 1.0, 1.0, 0.22)
	panel_style.set_border_width_all(2)
	panel_style.corner_radius_top_left = 10
	panel_style.corner_radius_top_right = 10
	panel_style.corner_radius_bottom_left = 10
	panel_style.corner_radius_bottom_right = 10
	panel.add_theme_stylebox_override("panel", panel_style)
	
	var margin := MarginContainer.new()
	panel.add_child(margin)
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	
	var main_box := VBoxContainer.new()
	main_box.add_theme_constant_override("separation", 12)
	margin.add_child(main_box)
	
	var title := Label.new()
	title.text = "BUY MENU"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	main_box.add_child(title)
	
	cash_label = Label.new()
	cash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cash_label.add_theme_font_size_override("font_size", 22)
	main_box.add_child(cash_label)
	
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_font_size_override("font_size", 15)
	status_label.modulate = Color(1.0, 1.0, 1.0, 0.75)
	main_box.add_child(status_label)
	
	message_label = Label.new()
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.add_theme_font_size_override("font_size", 16)
	message_label.modulate = Color(1.0, 1.0, 1.0, 0.9)
	main_box.add_child(message_label)
	
	var separator := HSeparator.new()
	main_box.add_child(separator)
	
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(960.0, 430.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_box.add_child(scroll)
	
	category_container = VBoxContainer.new()
	category_container.add_theme_constant_override("separation", 18)
	scroll.add_child(category_container)
	
	build_shop_sections()
	
	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", 12)
	main_box.add_child(bottom_row)
	
	var hint := Label.new()
	hint.text = "Press B or Escape to close."
	hint.modulate = Color(1.0, 1.0, 1.0, 0.65)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_row.add_child(hint)
	
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(140.0, 38.0)
	close_button.pressed.connect(close_menu)
	bottom_row.add_child(close_button)
	
	update_ui()


func build_shop_sections() -> void:
	upgrade_buttons.clear()
	
	for child in category_container.get_children():
		child.queue_free()
	
	var categories: Array[String] = [
		"WEAPON UPGRADES",
		"SUIT UPGRADES",
		"SPECIAL SUIT SYSTEMS"
	]
	
	for category in categories:
		var category_box := VBoxContainer.new()
		category_box.add_theme_constant_override("separation", 8)
		category_container.add_child(category_box)
		
		var category_label := Label.new()
		category_label.text = category
		category_label.add_theme_font_size_override("font_size", 22)
		category_label.modulate = Color(1.0, 1.0, 1.0, 0.9)
		category_box.add_child(category_label)
		
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		category_box.add_child(grid)
		
		for item in shop_items:
			if str(item["category"]) != category:
				continue
			
			var card := make_upgrade_card(item)
			grid.add_child(card)


func make_upgrade_card(item: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(300.0, 120.0)
	
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.11, 0.12, 0.15, 0.92)
	card_style.border_color = Color(1.0, 1.0, 1.0, 0.16)
	card_style.set_border_width_all(1)
	card_style.corner_radius_top_left = 8
	card_style.corner_radius_top_right = 8
	card_style.corner_radius_bottom_left = 8
	card_style.corner_radius_bottom_right = 8
	card.add_theme_stylebox_override("panel", card_style)
	
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	card.add_child(margin)
	
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	
	var name_label := Label.new()
	name_label.text = str(item["name"])
	name_label.add_theme_font_size_override("font_size", 17)
	box.add_child(name_label)
	
	var description_label := Label.new()
	description_label.text = str(item["description"])
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.modulate = Color(1.0, 1.0, 1.0, 0.68)
	description_label.add_theme_font_size_override("font_size", 13)
	box.add_child(description_label)
	
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)
	
	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	
	var price_label := Label.new()
	price_label.text = "$" + str(item["price"])
	price_label.add_theme_font_size_override("font_size", 16)
	price_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(price_label)
	
	var buy_button := Button.new()
	buy_button.text = "Buy"
	buy_button.custom_minimum_size = Vector2(84.0, 34.0)
	buy_button.pressed.connect(_on_buy_pressed.bind(item))
	bottom.add_child(buy_button)
	
	upgrade_buttons[str(item["id"])] = buy_button
	
	return card


func toggle_menu() -> void:
	if is_open:
		close_menu()
	else:
		open_menu()


func open_menu() -> void:
	is_open = true
	
	if menu_root != null:
		menu_root.visible = true
	
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	if player != null and player.has_method("set_buy_menu_open"):
		player.call("set_buy_menu_open", true)
	
	if pause_game_when_open:
		get_tree().paused = true
	
	message_label.text = "Choose suit and weapon upgrades."
	update_ui()


func close_menu() -> void:
	is_open = false
	
	if menu_root != null:
		menu_root.visible = false
	
	if pause_game_when_open:
		get_tree().paused = false
	
	if player != null and player.has_method("set_buy_menu_open"):
		player.call("set_buy_menu_open", false)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_buy_pressed(item: Dictionary) -> void:
	var upgrade_type := str(item["upgrade_type"])
	var level := int(item["level"])
	var item_name := str(item["name"])
	var price := int(item["price"])
	
	if is_item_already_owned(upgrade_type, level):
		message_label.text = item_name + " is already owned."
		update_ui()
		return
	
	if cash < price:
		message_label.text = "Not enough cash for " + item_name + "."
		update_ui()
		return
	
	var applied := apply_upgrade(upgrade_type, level)
	
	if not applied:
		message_label.text = "Could not apply " + item_name + ". Check player/laser references."
		update_ui()
		return
	
	cash -= price
	message_label.text = "Purchased " + item_name + "."
	print("Purchased: ", item_name, " for $", price)
	update_ui()


func apply_upgrade(upgrade_type: String, level: int) -> bool:
	match upgrade_type:
		"laser_follow_speed":
			if laser_controller != null and laser_controller.has_method("apply_laser_follow_speed_upgrade"):
				laser_controller.call("apply_laser_follow_speed_upgrade", level)
				return true
		
		"laser_size":
			if laser_controller != null and laser_controller.has_method("apply_laser_size_upgrade"):
				laser_controller.call("apply_laser_size_upgrade", level)
				return true
		
		"grab_distance":
			if player != null and player.has_method("apply_grab_distance_upgrade"):
				player.call("apply_grab_distance_upgrade", level)
				return true
		
		"suit_boosters":
			if player != null and player.has_method("purchase_suit_boosters"):
				player.call("purchase_suit_boosters")
				return true
	
	return false


func is_item_already_owned(upgrade_type: String, level: int) -> bool:
	match upgrade_type:
		"laser_follow_speed":
			return get_laser_follow_speed_level() >= level
		
		"laser_size":
			return get_laser_size_level() >= level
		
		"grab_distance":
			return get_grab_distance_level() >= level
		
		"suit_boosters":
			return get_has_suit_boosters()
	
	return false


func update_ui() -> void:
	if cash_label != null:
		cash_label.text = "Cash: $" + str(cash)
	
	if status_label != null:
		status_label.text = (
			"Laser Tracking: Lv." + str(get_laser_follow_speed_level())
			+ "   |   Laser Width: Lv." + str(get_laser_size_level())
			+ "   |   Grab Distance: Lv." + str(get_grab_distance_level())
			+ "   |   Boosters: " + ("Owned" if get_has_suit_boosters() else "Not Owned")
		)
	
	update_button_states()


func update_button_states() -> void:
	for item in shop_items:
		var item_id := str(item["id"])
		
		if not upgrade_buttons.has(item_id):
			continue
		
		var button := upgrade_buttons[item_id] as Button
		var upgrade_type := str(item["upgrade_type"])
		var level := int(item["level"])
		var price := int(item["price"])
		
		if is_item_already_owned(upgrade_type, level):
			button.disabled = true
			button.text = "Owned"
		elif cash < price:
			button.disabled = true
			button.text = "Need $"
		else:
			button.disabled = false
			button.text = "Buy"


func get_laser_follow_speed_level() -> int:
	if laser_controller != null and laser_controller.has_method("get_laser_follow_speed_level"):
		return int(laser_controller.call("get_laser_follow_speed_level"))
	
	return 0


func get_laser_size_level() -> int:
	if laser_controller != null and laser_controller.has_method("get_laser_size_level"):
		return int(laser_controller.call("get_laser_size_level"))
	
	return 0


func get_grab_distance_level() -> int:
	if player != null and player.has_method("get_grab_distance_level"):
		return int(player.call("get_grab_distance_level"))
	
	return 0


func get_has_suit_boosters() -> bool:
	if player != null and player.has_method("get_has_suit_boosters"):
		return bool(player.call("get_has_suit_boosters"))
	
	return false


func add_cash(amount: int) -> void:
	cash += amount
	update_ui()


func set_cash(new_cash: int) -> void:
	cash = max(new_cash, 0)
	update_ui()
