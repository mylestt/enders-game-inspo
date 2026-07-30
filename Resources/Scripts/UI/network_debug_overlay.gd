extends CanvasLayer

# Procedural F3 network-stats overlay (built in code, per project convention — no .tscn).
# Polls NetworkManager.get_network_debug_stats() while visible. Toggle with F3.

const TOGGLE_KEYCODE := KEY_F3

var network_manager: Node
var panel: PanelContainer
var label: Label
var overlay_visible: bool = false


func setup(manager: Node) -> void:
	network_manager = manager


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS

	panel = PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.modulate = Color(1.0, 1.0, 1.0, 0.95)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	label = Label.new()
	label.add_theme_font_size_override("font_size", 13)
	margin.add_child(label)

	panel.visible = false
	set_process(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == TOGGLE_KEYCODE:
			overlay_visible = not overlay_visible
			panel.visible = overlay_visible
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not overlay_visible or network_manager == null:
		return

	if not network_manager.has_method("get_network_debug_stats"):
		return

	label.text = format_stats(network_manager.call("get_network_debug_stats"))


func format_stats(stats: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("NETWORK  [F3]")
	lines.append("role: %s   peer: %s   players: %s" % [
		str(stats.get("role", "?")),
		str(stats.get("local_peer_id", 0)),
		str(stats.get("player_count", 0)),
	])
	lines.append("fps: %s   phys: %s Hz   send: %.0f Hz" % [
		str(stats.get("fps", 0)),
		str(stats.get("physics_tps", 0)),
		float(stats.get("send_rate_hz", 0.0)),
	])

	var connections: Array = stats.get("connections", [])

	if not connections.is_empty():
		lines.append("--- connection ---")

		for entry in connections:
			lines.append("peer %s  ping %.0fms (~%.0f jit)  loss %.2f%%" % [
				str(entry.get("peer_id", 0)),
				float(entry.get("rtt_ms", 0.0)),
				float(entry.get("rtt_var_ms", 0.0)),
				float(entry.get("loss_pct", 0.0)),
			])

	var remote_updates: Array = stats.get("remote_updates", [])

	if not remote_updates.is_empty():
		lines.append("--- remote players (arrival here) ---")

		for entry in remote_updates:
			lines.append("peer %s  %.0f Hz  gap now %.0fms  worst %.0fms" % [
				str(entry.get("peer_id", 0)),
				float(entry.get("hz", 0.0)),
				float(entry.get("last_gap_ms", 0.0)),
				float(entry.get("max_gap_ms", 0.0)),
			])

	return "\n".join(lines)
