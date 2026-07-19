extends CanvasLayer
class_name CtfNotificationHud

# Simple center-screen text callouts for CTF events: stolen/returned/scored/"you have the
# flag". Purely a local display — every message is driven by signals from the LOCAL
# player's own view of the Flag nodes (each client already receives the same
# ClientApplyPickup/Drop/Return/Capture RPCs, so no extra networking is needed here).

@export var display_duration: float = 3.0
@export var fade_duration: float = 0.4

var label: Label
var timer: float = 0.0
var fading: bool = false


func _ready() -> void:
	layer = 70

	if DisplayServer.get_name() == "headless":
		set_process(false)
		return

	_build_ui()
	_connect_flags()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	label = Label.new()
	label.text = ""
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.anchor_left = 0.5
	label.anchor_right = 0.5
	label.offset_left = -300.0
	label.offset_right = 300.0
	label.offset_top = 60.0
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.75, 1.0))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.modulate = Color(1.0, 1.0, 1.0, 0.0)
	root.add_child(label)


# Finds every Flag node currently in the scene (there are normally exactly two — one per
# team) and connects their signals. Flags are scene-placed, not dynamically spawned, so
# this only needs to run once at startup.
func _connect_flags() -> void:
	for flag in get_tree().get_nodes_in_group("ctf_flags"):
		if flag.has_signal("FlagPickedUp"):
			flag.connect("FlagPickedUp", _on_flag_picked_up.bind(flag))

		if flag.has_signal("FlagCaptured"):
			flag.connect("FlagCaptured", _on_flag_captured.bind(flag))

		if flag.has_signal("FlagReturned"):
			flag.connect("FlagReturned", _on_flag_returned.bind(flag))


func _on_flag_picked_up(_player: Node3D, flag: Node) -> void:
	var team_label := _team_label(flag)

	if _is_local_player_carrier(flag):
		show_message("You have the flag!")
	else:
		show_message(team_label + " flag has been stolen!")


func _on_flag_returned(flag: Node) -> void:
	show_message(_team_label(flag) + " flag has returned.")


func _on_flag_captured(_capturing_peer_id: int, flag: Node) -> void:
	var scoring_team := _opposite_team(_team_label_raw(flag))
	show_message(scoring_team.to_upper() + " team scored!")


func _team_label(flag: Node) -> String:
	return _team_label_raw(flag).to_upper() + " team's"


func _team_label_raw(flag: Node) -> String:
	if "flagTeam" in flag:
		var team := String(flag.flagTeam)
		return team if team != "" else "?"

	return "?"


func _opposite_team(team: String) -> String:
	if team == "a":
		return "b"
	if team == "b":
		return "a"

	return team


func _is_local_player_carrier(flag: Node) -> bool:
	if not ("carrierPeerId" in flag):
		return false

	var carrier_peer_id := int(flag.carrierPeerId)

	if carrier_peer_id == 0:
		return false

	var network_manager := get_tree().root.find_child("NetworkManager", true, false)

	if network_manager == null or not network_manager.has_method("get_local_peer_id"):
		return false

	return carrier_peer_id == int(network_manager.call("get_local_peer_id"))


func show_message(text: String) -> void:
	if label == null:
		return

	label.text = text
	label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	timer = display_duration
	fading = false


func _process(delta: float) -> void:
	if label == null or timer <= 0.0 and label.modulate.a <= 0.0:
		return

	if timer > 0.0:
		timer -= delta
		return

	fading = true
	var new_alpha := maxf(label.modulate.a - delta / maxf(fade_duration, 0.001), 0.0)
	label.modulate.a = new_alpha
