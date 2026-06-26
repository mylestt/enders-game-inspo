extends CanvasLayer
class_name ScoreboardOverlay

@export var network_manager_path: NodePath = NodePath("../NetworkManager")

var network_manager: Node
var panel: PanelContainer
var team_a_rows: VBoxContainer
var team_b_rows: VBoxContainer
var latest_entries: Array = []


func _ready() -> void:
	layer = 95
	network_manager = get_node_or_null(network_manager_path)
	build_ui()
	hide_scoreboard()

	if network_manager != null:
		if network_manager.has_signal("scoreboard_changed"):
			network_manager.connect("scoreboard_changed", _on_scoreboard_changed)

		if network_manager.has_method("get_scoreboard_entries"):
			_on_scoreboard_changed(network_manager.call("get_scoreboard_entries"))


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey

	if key_event == null or key_event.echo:
		return

	if key_event.physical_keycode != KEY_TAB and key_event.keycode != KEY_TAB:
		return

	if key_event.pressed:
		show_scoreboard()
	else:
		hide_scoreboard()

	get_viewport().set_input_as_handled()


func build_ui() -> void:
	var root := Control.new()
	root.name = "ScoreboardRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	panel = PanelContainer.new()
	panel.name = "ScoreboardPanel"
	panel.custom_minimum_size = Vector2(780.0, 360.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.03, 0.04, 0.92)
	style.border_color = Color(0.45, 0.55, 0.72, 0.72)
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
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)

	var title := Label.new()
	title.text = "SCOREBOARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.96))
	column.add_child(title)

	var teams := HBoxContainer.new()
	teams.add_theme_constant_override("separation", 18)
	column.add_child(teams)

	team_a_rows = build_team_panel(teams, "TEAM A", Color(0.45, 0.7, 1.0, 0.96))
	team_b_rows = build_team_panel(teams, "TEAM B", Color(1.0, 0.6, 0.42, 0.96))


func build_team_panel(parent: Node, title_text: String, title_color: Color) -> VBoxContainer:
	var team_panel := PanelContainer.new()
	team_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	team_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(team_panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.62)
	style.border_color = Color(title_color.r, title_color.g, title_color.b, 0.35)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	team_panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	team_panel.add_child(margin)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	margin.add_child(rows)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", title_color)
	rows.add_child(title)

	return rows


func show_scoreboard() -> void:
	if panel != null:
		panel.visible = true
		refresh_rows()


func hide_scoreboard() -> void:
	if panel != null:
		panel.visible = false


func _on_scoreboard_changed(entries: Array) -> void:
	latest_entries = entries.duplicate(true)

	if panel != null and panel.visible:
		refresh_rows()


func refresh_rows() -> void:
	if team_a_rows == null or team_b_rows == null:
		return

	clear_dynamic_rows(team_a_rows)
	clear_dynamic_rows(team_b_rows)

	add_table_header(team_a_rows)
	add_table_header(team_b_rows)

	var added_a := false
	var added_b := false

	for entry in latest_entries:
		if not (entry is Dictionary):
			continue

		var data: Dictionary = entry

		var team := String(data.get("team", "a")).to_lower()

		if team == "b":
			add_player_row(team_b_rows, data)
			added_b = true
		else:
			add_player_row(team_a_rows, data)
			added_a = true

	if not added_a:
		add_empty_row(team_a_rows)

	if not added_b:
		add_empty_row(team_b_rows)


func clear_dynamic_rows(rows: VBoxContainer) -> void:
	while rows.get_child_count() > 1:
		var child := rows.get_child(1)
		rows.remove_child(child)
		child.queue_free()


func add_table_header(rows: VBoxContainer) -> void:
	var row := make_row()
	rows.add_child(row)
	row.add_child(make_cell("Player", 16, Color(1.0, 1.0, 1.0, 0.58), 1.0, HORIZONTAL_ALIGNMENT_LEFT))
	row.add_child(make_cell("K", 16, Color(1.0, 1.0, 1.0, 0.58), 0.0, HORIZONTAL_ALIGNMENT_CENTER, 42.0))
	row.add_child(make_cell("D", 16, Color(1.0, 1.0, 1.0, 0.58), 0.0, HORIZONTAL_ALIGNMENT_CENTER, 42.0))
	row.add_child(make_cell("", 16, Color(1.0, 1.0, 1.0, 0.58), 0.0, HORIZONTAL_ALIGNMENT_RIGHT, 58.0))


func add_player_row(rows: VBoxContainer, entry: Dictionary) -> void:
	var row := make_row()
	rows.add_child(row)

	var peer_id := int(entry.get("peer_id", 0))
	var is_local := peer_id == multiplayer.get_unique_id()
	var alive := bool(entry.get("alive", true))
	var name := String(entry.get("name", "Player"))
	var name_color := Color(1.0, 1.0, 1.0, 0.92)

	if not alive:
		name_color = Color(1.0, 1.0, 1.0, 0.44)
	elif is_local:
		name_color = Color(0.75, 0.95, 1.0, 1.0)

	row.add_child(make_cell(name, 17, name_color, 1.0, HORIZONTAL_ALIGNMENT_LEFT))
	row.add_child(make_cell(str(int(entry.get("kills", 0))), 17, name_color, 0.0, HORIZONTAL_ALIGNMENT_CENTER, 42.0))
	row.add_child(make_cell(str(int(entry.get("deaths", 0))), 17, name_color, 0.0, HORIZONTAL_ALIGNMENT_CENTER, 42.0))
	row.add_child(make_cell("OUT" if not alive else "", 14, Color(1.0, 0.42, 0.38, 0.86), 0.0, HORIZONTAL_ALIGNMENT_RIGHT, 58.0))


func add_empty_row(rows: VBoxContainer) -> void:
	var row := make_row()
	rows.add_child(row)
	row.add_child(make_cell("No players", 16, Color(1.0, 1.0, 1.0, 0.36), 1.0, HORIZONTAL_ALIGNMENT_LEFT))


func make_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


func make_cell(
	text: String,
	font_size: int,
	color: Color,
	expand_ratio: float,
	alignment: HorizontalAlignment,
	min_width: float = 0.0
) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)

	if min_width > 0.0:
		label.custom_minimum_size = Vector2(min_width, 0.0)

	if expand_ratio > 0.0:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_stretch_ratio = expand_ratio

	return label
