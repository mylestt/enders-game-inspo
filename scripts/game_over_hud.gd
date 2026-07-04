extends CanvasLayer
class_name GameOverHUD

# Full-screen match-over screen (both game modes). Listens to RoundManager.match_ended for
# the result and shows the winner — a team in team mode, the top-kills player in FFA — plus
# a "Return to Main Menu" button. Procedural per project convention. Server-driven: the HUD
# only displays; it never decides the winner.

@export var round_manager_path: NodePath = NodePath("../RoundManager")
@export var network_manager_path: NodePath = NodePath("../NetworkManager")

var round_manager: Node
var network_manager: Node

var root: Control
var title_label: Label
var subtitle_label: Label


func _ready() -> void:
	layer = 120
	# Keep working even if something pauses the tree; nothing to draw on a dedicated server.
	process_mode = Node.PROCESS_MODE_ALWAYS

	if DisplayServer.get_name() == "headless":
		return

	round_manager = get_node_or_null(round_manager_path)
	network_manager = get_node_or_null(network_manager_path)

	_build_ui()
	root.visible = false

	if round_manager != null:
		if round_manager.has_signal("match_ended"):
			round_manager.connect("match_ended", _on_match_ended)
		if round_manager.has_signal("round_state_changed"):
			round_manager.connect("round_state_changed", _on_round_state_changed)


func _build_ui() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.98)
	style.border_color = Color(0.5, 0.6, 0.8, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 40
	style.content_margin_right = 40
	style.content_margin_top = 30
	style.content_margin_bottom = 30
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(420.0, 0.0)
	column.add_theme_constant_override("separation", 16)
	panel.add_child(column)

	var header := Label.new()
	header.text = "MATCH OVER"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 20)
	header.add_theme_color_override("font_color", Color(0.75, 0.82, 1.0, 0.7))
	column.add_child(header)

	title_label = Label.new()
	title_label.text = "—"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.add_theme_font_size_override("font_size", 40)
	title_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.98))
	column.add_child(title_label)

	subtitle_label = Label.new()
	subtitle_label.text = ""
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.add_theme_font_size_override("font_size", 18)
	subtitle_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.6))
	column.add_child(subtitle_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 10.0)
	column.add_child(spacer)

	var button := Button.new()
	button.text = "Return to Main Menu"
	button.custom_minimum_size = Vector2(0.0, 52.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(_on_return_pressed)
	column.add_child(button)


func _on_match_ended(result: Dictionary) -> void:
	_populate(result)
	root.visible = true
	# Lock the local player like the pause menu does, so clicking the button doesn't
	# re-capture the mouse into look control (see player._input recapture path).
	_set_local_player_lock(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _set_local_player_lock(locked: bool) -> void:
	if network_manager != null and network_manager.has_method("get_local_player"):
		var player = network_manager.get_local_player()

		if player != null and player.has_method("set_external_menu_open"):
			player.call("set_external_menu_open", locked)


func _on_round_state_changed(new_state: int) -> void:
	# Hide again if the match resets (e.g. the lobby empties and returns to WAITING).
	if new_state != RoundManager.State.MATCH_END and root != null and root.visible:
		root.visible = false
		_set_local_player_lock(false)


func _populate(result: Dictionary) -> void:
	var mode := String(result.get("mode", "team"))
	var is_draw := bool(result.get("is_draw", false))

	if mode == "ffa":
		if is_draw or int(result.get("winner_peer_id", 0)) == 0:
			title_label.text = "DRAW"
			subtitle_label.text = "No clear winner"
		else:
			title_label.text = String(result.get("winner_name", "Winner")) + " WINS"
			var kills := int(result.get("winner_kills", 0))
			subtitle_label.text = str(kills) + (" kill" if kills == 1 else " kills")
	else:
		var team := String(result.get("winner_team", ""))
		var scores: Dictionary = result.get("team_scores", {})
		var score_text := str(int(scores.get("a", 0))) + " – " + str(int(scores.get("b", 0)))

		if team == "a":
			title_label.text = "TEAM A WINS"
			subtitle_label.text = score_text
		elif team == "b":
			title_label.text = "TEAM B WINS"
			subtitle_label.text = score_text
		else:
			title_label.text = "DRAW"
			subtitle_label.text = score_text


func _on_return_pressed() -> void:
	# Mirror the pause menu's Leave: unlock the player, tear down the session, go to the menu.
	_set_local_player_lock(false)
	get_tree().paused = false

	if network_manager != null and network_manager.has_method("clear_runtime_multiplayer_state"):
		network_manager.call("clear_runtime_multiplayer_state")

	get_tree().change_scene_to_file.call_deferred("res://scenes/start_menu.tscn")
