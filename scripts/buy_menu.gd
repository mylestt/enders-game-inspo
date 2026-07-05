extends CanvasLayer

@export var player_path: NodePath

@export var starting_cash: int = 20000
@export var pause_game_when_open: bool = false
@export var close_on_purchase: bool = false

@export var panel_max_width: float = 940.0
@export var panel_max_height: float = 660.0
@export var panel_screen_margin: float = 32.0

# Single-purchase weapon groups. Each group name doubles as the WeaponInventory weapon id,
# so adding a gun to the shop is just a shop_items entry with group == its weapon id.
const WEAPON_GROUPS: Array[String] = ["minigun", "railgun", "rifle", "plasma_cannon"]

# Display copy of this player's cash. Online, the server's ledger (ServerEconomy) is
# authoritative and every change arrives through purchase results / cash syncs; offline
# (Test Arena) this is the real wallet.
var cash: int = 0
var menu_open: bool = false

var local_player: Node
# ServerEconomy node, assigned by NetworkManager. Null in offline Test Arena.
var economy: Node

var menu_root: Control
var dim_background: ColorRect
var shop_panel: PanelContainer
var cash_label: Label
var status_label: Label
var scroll: ScrollContainer

var item_buttons_by_id: Dictionary = {}
var item_price_labels_by_id: Dictionary = {}

var shop_items: Array[Dictionary] = [
	{
		"id": "minigun",
		"section": "WEAPONS",
		"group": "minigun",
		"level": 1,
		"title": "Minigun",
		"description": "Equips a wind-up minigun. Hold left mouse to spin it up.",
		"price": 8000
	},
	{
		"id": "railgun",
		"section": "WEAPONS",
		"group": "railgun",
		"level": 1,
		"title": "Railgun",
		"description": "High-damage single-shot rail rifle. Slow fire rate, heavy recoil.",
		"price": 5000
	},
	{
		"id": "rifle",
		"section": "WEAPONS",
		"group": "rifle",
		"level": 1,
		"title": "Battle Rifle",
		"description": "3-round burst. Semi-auto, punchy left/right recoil, aim down sights.",
		"price": 4500
	},
	{
		"id": "plasma_cannon",
		"section": "WEAPONS",
		"group": "plasma_cannon",
		"level": 1,
		"title": "Plasma Cannon",
		"description": "Fires a slow travelling plasma bolt. Big damage, big kick — lead your shots.",
		"price": 6000
	},
	{
		"id": "grab_distance_1",
		"section": "SUIT UPGRADES",
		"group": "grab_distance",
		"level": 1,
		"title": "Grab Distance I",
		"description": "Increases wall grab range.",
		"price": 1000
	},
	{
		"id": "grab_distance_2",
		"section": "SUIT UPGRADES",
		"group": "grab_distance",
		"level": 2,
		"title": "Grab Distance II",
		"description": "Further increases wall grab range.",
		"price": 2500
	},
	{
		"id": "grab_distance_3",
		"section": "SUIT UPGRADES",
		"group": "grab_distance",
		"level": 3,
		"title": "Grab Distance III",
		"description": "Maximum wall grab range.",
		"price": 4250
	},
	{
		"id": "suit_boosters",
		"section": "SPECIAL SUIT SYSTEMS",
		"group": "suit_boosters",
		"level": 1,
		"title": "Suit Boosters",
		"description": "Unlocks W/S propulsion with limited fuel.",
		"price": 6000
	},
	{
		"id": "grapple_wire",
		"section": "SPECIAL SUIT SYSTEMS",
		"group": "grapple_wire",
		"level": 1,
		"title": "Grapple Wire",
		"description": "E fires a fixed-length wire that hooks surfaces. Swing at speed, wrap around cover, MMB reels in, Q releases.",
		"price": 5000
	}
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100

	if GameLaunch.rules_configured:
		starting_cash = GameLaunch.starting_cash

	cash = starting_cash

	# The dedicated server only needs shop_items as the purchase-validation catalog
	# (ServerEconomy reads it via get_item_by_id); it has no screen to draw the menu on.
	if DisplayServer.get_name() == "headless":
		set_process_unhandled_input(false)
		return

	build_ui()
	resize_menu_to_viewport()
	close_menu(false)

	if not get_viewport().size_changed.is_connected(resize_menu_to_viewport):
		get_viewport().size_changed.connect(resize_menu_to_viewport)

	if String(player_path) != "":
		var found_player := get_node_or_null(player_path)

		if found_player != null:
			set_local_player(found_player)


func _unhandled_input(event: InputEvent) -> void:
	if not InputMap.has_action("toggle_buy_menu"):
		return
	
	if event.is_action_pressed("toggle_buy_menu"):
		toggle_menu()
		get_viewport().set_input_as_handled()
	
	if menu_open and event.is_action_pressed("ui_cancel"):
		close_menu()
		get_viewport().set_input_as_handled()


func set_local_player(player_node: Node) -> void:
	local_player = player_node
	
	update_menu_state()
	
	print("BuyMenu local player set to: ", local_player)


func set_starting_cash(amount: int) -> void:
	starting_cash = maxi(amount, 0)
	cash = starting_cash
	update_menu_state()


# Wires the server-authoritative economy in. Online purchases stop deducting locally and
# instead wait for the server's confirmation.
func set_economy(economy_node: Node) -> void:
	economy = economy_node

	if economy == null:
		return

	if economy.has_signal("purchase_result") and not economy.is_connected("purchase_result", _on_purchase_result):
		economy.connect("purchase_result", _on_purchase_result)

	if economy.has_signal("cash_changed") and not economy.is_connected("cash_changed", _on_cash_changed):
		economy.connect("cash_changed", _on_cash_changed)

	# Catch up on a balance the server pushed before we were wired up.
	var synced = economy.get("last_synced_cash")

	if synced != null and int(synced) >= 0:
		cash = int(synced)
		update_menu_state()


func _on_cash_changed(new_cash: int) -> void:
	cash = maxi(new_cash, 0)
	update_menu_state()


func _on_purchase_result(item_id: String, success: bool, message: String, new_cash: int) -> void:
	cash = maxi(new_cash, 0)

	if success:
		var item := get_item_by_id(item_id)

		if not item.is_empty():
			apply_item_upgrade(item)

		update_menu_state()

		if close_on_purchase:
			close_menu()

		return

	update_menu_state()

	if status_label != null:
		status_label.text = "Purchase failed: " + message


func is_purchase_server_validated() -> bool:
	return economy != null and economy.has_method("is_online") and bool(economy.call("is_online"))


func toggle_menu() -> void:
	if menu_open:
		close_menu()
	else:
		open_menu()


# FFA has no economy: players spawn with a random gun, so the buy menu is disabled.
func is_buy_menu_enabled() -> bool:
	return GameLaunch.game_mode_id != "ffa"


func open_menu() -> void:
	if not is_buy_menu_enabled():
		return

	if local_player == null:
		push_warning("BuyMenu has no local player assigned yet.")
		return

	menu_open = true
	
	if menu_root != null:
		menu_root.visible = true
	
	resize_menu_to_viewport()
	
	if pause_game_when_open:
		get_tree().paused = true
	
	if local_player.has_method("set_buy_menu_open"):
		local_player.call("set_buy_menu_open", true)
	
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	update_menu_state()


func close_menu(notify_player: bool = true) -> void:
	menu_open = false
	
	if menu_root != null:
		menu_root.visible = false
	
	if pause_game_when_open:
		get_tree().paused = false
	
	if notify_player and local_player != null and local_player.has_method("set_buy_menu_open"):
		local_player.call("set_buy_menu_open", false)


func resize_menu_to_viewport() -> void:
	if shop_panel == null:
		return
	
	var viewport_size := get_viewport().get_visible_rect().size
	
	if menu_root != null:
		menu_root.anchor_left = 0.0
		menu_root.anchor_top = 0.0
		menu_root.anchor_right = 0.0
		menu_root.anchor_bottom = 0.0
		menu_root.position = Vector2.ZERO
		menu_root.size = viewport_size
	
	if dim_background != null:
		dim_background.anchor_left = 0.0
		dim_background.anchor_top = 0.0
		dim_background.anchor_right = 0.0
		dim_background.anchor_bottom = 0.0
		dim_background.position = Vector2.ZERO
		dim_background.size = viewport_size
	
	var target_width := minf(panel_max_width, viewport_size.x - panel_screen_margin * 2.0)
	var target_height := minf(panel_max_height, viewport_size.y - panel_screen_margin * 2.0)
	
	target_width = maxf(target_width, 420.0)
	target_height = maxf(target_height, 360.0)
	
	var panel_size := Vector2(target_width, target_height)
	var panel_position := (viewport_size - panel_size) * 0.5
	
	shop_panel.anchor_left = 0.0
	shop_panel.anchor_top = 0.0
	shop_panel.anchor_right = 0.0
	shop_panel.anchor_bottom = 0.0
	shop_panel.position = panel_position
	shop_panel.size = panel_size
	
	if scroll != null:
		scroll.custom_minimum_size = Vector2(0.0, maxf(target_height - 150.0, 180.0))


func build_ui() -> void:
	menu_root = Control.new()
	menu_root.name = "BuyMenuRoot"
	add_child(menu_root)
	menu_root.mouse_filter = Control.MOUSE_FILTER_STOP
	
	var viewport_size := get_viewport().get_visible_rect().size
	
	menu_root.anchor_left = 0.0
	menu_root.anchor_top = 0.0
	menu_root.anchor_right = 0.0
	menu_root.anchor_bottom = 0.0
	menu_root.position = Vector2.ZERO
	menu_root.size = viewport_size
	
	dim_background = ColorRect.new()
	dim_background.name = "DimBackground"
	menu_root.add_child(dim_background)
	dim_background.color = Color(0.0, 0.0, 0.0, 0.55)
	dim_background.mouse_filter = Control.MOUSE_FILTER_STOP
	dim_background.anchor_left = 0.0
	dim_background.anchor_top = 0.0
	dim_background.anchor_right = 0.0
	dim_background.anchor_bottom = 0.0
	dim_background.position = Vector2.ZERO
	dim_background.size = viewport_size
	
	shop_panel = PanelContainer.new()
	shop_panel.name = "ShopPanel"
	menu_root.add_child(shop_panel)
	shop_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.055, 0.07, 0.96)
	panel_style.border_color = Color(0.45, 0.48, 0.55, 0.65)
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left = 10
	panel_style.corner_radius_top_right = 10
	panel_style.corner_radius_bottom_left = 10
	panel_style.corner_radius_bottom_right = 10
	shop_panel.add_theme_stylebox_override("panel", panel_style)
	
	var margin := MarginContainer.new()
	shop_panel.add_child(margin)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	
	var main_vbox := VBoxContainer.new()
	margin.add_child(main_vbox)
	main_vbox.add_theme_constant_override("separation", 10)
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var top_bar := HBoxContainer.new()
	main_vbox.add_child(top_bar)
	top_bar.add_theme_constant_override("separation", 12)
	top_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var title_label := Label.new()
	top_bar.add_child(title_label)
	title_label.text = "BUY MENU"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", 26)
	title_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	
	cash_label = Label.new()
	top_bar.add_child(cash_label)
	cash_label.text = "$0"
	cash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cash_label.add_theme_font_size_override("font_size", 24)
	cash_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55, 0.95))
	
	var close_button := Button.new()
	top_bar.add_child(close_button)
	close_button.text = "CLOSE"
	close_button.custom_minimum_size = Vector2(100.0, 36.0)
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close_menu)
	
	status_label = Label.new()
	main_vbox.add_child(status_label)
	status_label.text = "Press B to close."
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.62))
	
	scroll = ScrollContainer.new()
	main_vbox.add_child(scroll)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	
	var item_vbox := VBoxContainer.new()
	scroll.add_child(item_vbox)
	item_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_vbox.add_theme_constant_override("separation", 12)
	
	var sections := get_shop_sections()
	
	for section_name in sections:
		add_section_header(item_vbox, section_name)
		
		for item in shop_items:
			if String(item["section"]) == section_name:
				add_shop_item_row(item_vbox, item)
	
	resize_menu_to_viewport()


func get_shop_sections() -> Array[String]:
	var sections: Array[String] = []
	
	for item in shop_items:
		var section := String(item["section"])
		
		if not sections.has(section):
			sections.append(section)
	
	return sections


func add_section_header(parent: VBoxContainer, text: String) -> void:
	var label := Label.new()
	parent.add_child(label)
	label.text = text
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0, 0.95))


func add_shop_item_row(parent: VBoxContainer, item: Dictionary) -> void:
	var row_panel := PanelContainer.new()
	parent.add_child(row_panel)
	row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var row_style := StyleBoxFlat.new()
	row_style.bg_color = Color(0.11, 0.12, 0.15, 0.92)
	row_style.border_color = Color(0.28, 0.3, 0.36, 0.7)
	row_style.border_width_left = 1
	row_style.border_width_right = 1
	row_style.border_width_top = 1
	row_style.border_width_bottom = 1
	row_style.corner_radius_top_left = 6
	row_style.corner_radius_top_right = 6
	row_style.corner_radius_bottom_left = 6
	row_style.corner_radius_bottom_right = 6
	row_panel.add_theme_stylebox_override("panel", row_style)
	
	var margin := MarginContainer.new()
	row_panel.add_child(margin)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	
	var row := HBoxContainer.new()
	margin.add_child(row)
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var text_box := VBoxContainer.new()
	row.add_child(text_box)
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var title := Label.new()
	text_box.add_child(title)
	title.text = String(item["title"])
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	
	var description := Label.new()
	text_box.add_child(description)
	description.text = String(item["description"])
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_font_size_override("font_size", 13)
	description.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	
	var price_label := Label.new()
	row.add_child(price_label)
	price_label.custom_minimum_size = Vector2(95.0, 0.0)
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	price_label.add_theme_font_size_override("font_size", 17)
	price_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55, 0.95))
	
	var buy_button := Button.new()
	row.add_child(buy_button)
	buy_button.custom_minimum_size = Vector2(110.0, 40.0)
	buy_button.focus_mode = Control.FOCUS_NONE
	buy_button.pressed.connect(_on_buy_pressed.bind(String(item["id"])))
	
	item_price_labels_by_id[String(item["id"])] = price_label
	item_buttons_by_id[String(item["id"])] = buy_button


func _on_buy_pressed(item_id: String) -> void:
	var item := get_item_by_id(item_id)

	if item.is_empty():
		return

	var state := get_item_state(item)

	if not bool(state["can_buy"]):
		return

	var price := int(item["price"])

	if cash < price:
		return

	# Online: the server owns cash and ownership. Ask it; the item is applied (and the
	# wallet updated) when _on_purchase_result comes back confirmed.
	if is_purchase_server_validated():
		economy.call("request_purchase", item_id)
		return

	# Offline Test Arena: local wallet.
	if not apply_item_upgrade(item):
		return

	cash -= price

	update_menu_state()

	if close_on_purchase:
		close_menu()


func get_item_by_id(item_id: String) -> Dictionary:
	for item in shop_items:
		if String(item["id"]) == item_id:
			return item
	
	return {}


func get_item_state(item: Dictionary) -> Dictionary:
	var group := String(item["group"])
	var level := int(item["level"])
	var price := int(item["price"])
	
	if local_player == null:
		return {
			"can_buy": false,
			"button_text": "NO PLAYER"
		}
	
	if not can_apply_group(group):
		return {
			"can_buy": false,
			"button_text": "MISSING"
		}
	
	if group == "suit_boosters" or group == "grapple_wire" or group in WEAPON_GROUPS:
		if get_has_single_purchase_item(group):
			return {
				"can_buy": false,
				"button_text": "OWNED"
			}
		
		if cash < price:
			return {
				"can_buy": false,
				"button_text": "NO CASH"
			}
		
		return {
			"can_buy": true,
			"button_text": "BUY"
		}
	
	var current_level := get_current_group_level(group)
	
	if current_level >= level:
		return {
			"can_buy": false,
			"button_text": "OWNED"
		}
	
	if current_level < level - 1:
		return {
			"can_buy": false,
			"button_text": "LOCKED"
		}
	
	if cash < price:
		return {
			"can_buy": false,
			"button_text": "NO CASH"
		}
	
	return {
		"can_buy": true,
		"button_text": "BUY"
	}


# Maps a shop group to its target node, the method that applies the purchase/upgrade
# (with optional extra args), the method that reads its current level, and whether apply
# takes a level arg. Weapon groups all route through the player's generic purchase_weapon.
func get_group_handler(group: String) -> Dictionary:
	if group in WEAPON_GROUPS:
		return {"obj": local_player, "apply": "purchase_weapon", "args": [StringName(group)], "level": "", "takes_level": false}

	match group:
		"grab_distance":
			return {"obj": local_player, "apply": "apply_grab_distance_upgrade", "level": "get_grab_distance_level", "takes_level": true}
		"suit_boosters":
			return {"obj": local_player, "apply": "purchase_suit_boosters", "level": "", "takes_level": false}
		"grapple_wire":
			return {"obj": local_player, "apply": "purchase_grapple_wire", "level": "", "takes_level": false}

	return {}


func can_apply_group(group: String) -> bool:
	var handler := get_group_handler(group)
	var obj = handler.get("obj", null)

	return obj != null and obj.has_method(String(handler.get("apply", "")))


func apply_item_upgrade(item: Dictionary) -> bool:
	var handler := get_group_handler(String(item["group"]))
	var obj = handler.get("obj", null)
	var apply_method := String(handler.get("apply", ""))

	if obj == null or not obj.has_method(apply_method):
		return false

	var args: Array = handler.get("args", [])
	var result

	if bool(handler.get("takes_level", false)):
		result = obj.call(apply_method, int(item["level"]))
	elif args.is_empty():
		result = obj.call(apply_method)
	else:
		result = obj.callv(apply_method, args)

	if typeof(result) == TYPE_BOOL:
		return bool(result)

	return true


func get_current_group_level(group: String) -> int:
	var handler := get_group_handler(group)
	var obj = handler.get("obj", null)
	var level_method := String(handler.get("level", ""))

	if obj != null and level_method != "" and obj.has_method(level_method):
		return int(obj.call(level_method))

	return 0


func get_has_suit_boosters() -> bool:
	if local_player != null and local_player.has_method("get_has_suit_boosters"):
		return bool(local_player.call("get_has_suit_boosters"))
	
	return false


func get_has_single_purchase_item(group: String) -> bool:
	if group in WEAPON_GROUPS:
		if local_player != null and local_player.has_method("has_weapon"):
			return bool(local_player.call("has_weapon", StringName(group)))

		return false

	if group == "suit_boosters":
		return get_has_suit_boosters()

	if group == "grapple_wire":
		if local_player != null and local_player.has_method("get_has_grapple_wire"):
			return bool(local_player.call("get_has_grapple_wire"))

		return false

	return false


func update_menu_state() -> void:
	if cash_label != null:
		cash_label.text = "$" + str(cash)
	
	if status_label != null:
		if local_player == null:
			status_label.text = "Waiting for local player..."
		else:
			status_label.text = "Local player: " + local_player.name + "    Press B or Escape to close."
	
	for item in shop_items:
		var item_id := String(item["id"])
		
		if item_price_labels_by_id.has(item_id):
			var price_label: Label = item_price_labels_by_id[item_id]
			price_label.text = "$" + str(int(item["price"]))
		
		if item_buttons_by_id.has(item_id):
			var button: Button = item_buttons_by_id[item_id]
			var state := get_item_state(item)
			
			button.disabled = not bool(state["can_buy"])
			button.text = String(state["button_text"])
