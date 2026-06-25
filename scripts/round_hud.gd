extends CanvasLayer
class_name RoundHUD

# Top-center round bar: Team A score | round state / countdown | Team B score.
# Listens to RoundManager's replicated signals. The countdown ticks locally between
# state changes (the server only replicates the timer at each transition).

@export var round_manager_path: NodePath = NodePath("../RoundManager")

var round_manager: Node
var team_a_label: Label
var team_b_label: Label
var center_label: Label

var current_state: int = 0
var current_timer: float = 0.0


func _ready() -> void:
	layer = 65
	round_manager = get_node_or_null(round_manager_path)
	_build_ui()

	if round_manager != null:
		if round_manager.has_signal("team_scores_changed"):
			round_manager.connect("team_scores_changed", _on_team_scores_changed)
		if round_manager.has_signal("round_state_changed"):
			round_manager.connect("round_state_changed", _on_round_state_changed)

		if "state" in round_manager:
			_on_round_state_changed(int(round_manager.get("state")))
		if "team_scores" in round_manager:
			_on_team_scores_changed(round_manager.get("team_scores"))


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 24)
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.anchor_top = 0.0
	bar.offset_top = 14.0
	bar.offset_left = -260.0
	bar.offset_right = 260.0
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)

	team_a_label = _make_label("0", 36, Color(0.45, 0.7, 1.0, 0.96))
	team_a_label.custom_minimum_size = Vector2(70.0, 0.0)
	team_a_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(team_a_label)

	center_label = _make_label("Waiting for players…", 18, Color(1.0, 1.0, 1.0, 0.85))
	center_label.custom_minimum_size = Vector2(300.0, 0.0)
	center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(center_label)

	team_b_label = _make_label("0", 36, Color(1.0, 0.6, 0.4, 0.96))
	team_b_label.custom_minimum_size = Vector2(70.0, 0.0)
	team_b_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	bar.add_child(team_b_label)


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _process(delta: float) -> void:
	if current_timer <= 0.0:
		return

	if current_state == 1 or current_state == 2:   # COUNTDOWN or ACTIVE (timed)
		current_timer = maxf(current_timer - delta, 0.0)
		_update_center()


func _on_team_scores_changed(scores: Dictionary) -> void:
	if team_a_label != null:
		team_a_label.text = str(int(scores.get("a", 0)))

	if team_b_label != null:
		team_b_label.text = str(int(scores.get("b", 0)))


func _on_round_state_changed(new_state: int) -> void:
	current_state = new_state

	if round_manager != null and "state_timer" in round_manager:
		current_timer = float(round_manager.get("state_timer"))
	else:
		current_timer = 0.0

	_update_center()


func _update_center() -> void:
	if center_label == null:
		return

	match current_state:
		1:   # COUNTDOWN
			center_label.text = "Round starts in " + str(ceili(current_timer))
		2:   # ACTIVE
			if current_timer > 0.0:
				center_label.text = "ROUND ACTIVE   " + str(ceili(current_timer))
			else:
				center_label.text = "ROUND ACTIVE"
		3:   # ROUND_END
			center_label.text = "Round over"
		_:   # WAITING_FOR_PLAYERS
			center_label.text = "Waiting for players…"
