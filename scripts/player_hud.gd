extends Node
class_name PlayerHUDController

var player: RigidBody3D

var hud_layer: CanvasLayer
var root: Control

var velocity_label: Label
var jump_force_label: Label
var fps_label: Label
var booster_label: Label
var limb_push_label: Label

var health_panel: PanelContainer
var health_label: Label

var reticle: Panel
var ctrl_push_arrow: Label

var impact_flash: ColorRect
var impact_shadow: ColorRect
var impact_value_label: Label

var current_jump_force: float = 10.0

var _last_viewport_size: Vector2 = Vector2.ZERO

var health_hits: int = 0
var health_max_hits: int = 3
var health_disabled: bool = false


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player
	
	hide_old_push_charge_bar()
	build_hud()
	update_jump_force(current_jump_force)
	update_health_status(health_hits, health_max_hits, health_disabled)


func _process(_delta: float) -> void:
	update_fps_label()

	var viewport_size := get_viewport().get_visible_rect().size

	if viewport_size != _last_viewport_size:
		_last_viewport_size = viewport_size
		layout_dynamic_controls()


func hide_old_push_charge_bar() -> void:
	if player == null:
		return
	
	var old_bar := player.get_node_or_null("UI/HUD/PushChargeBar")
	
	if old_bar is Control:
		old_bar.visible = false


func build_hud() -> void:
	if hud_layer != null:
		return
	
	hud_layer = CanvasLayer.new()
	hud_layer.name = "GeneratedPlayerHUDLayer"
	hud_layer.layer = 60
	add_child(hud_layer)
	
	root = Control.new()
	root.name = "GeneratedHUDRoot"
	hud_layer.add_child(root)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 0.0
	root.offset_top = 0.0
	root.offset_right = 0.0
	root.offset_bottom = 0.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	build_top_left_stats()
	build_top_right_health()
	build_center_reticle()
	build_ctrl_push_arrow()
	build_impact_effects()


func build_top_left_stats() -> void:
	var stats_box := VBoxContainer.new()
	stats_box.name = "StatsBox"
	root.add_child(stats_box)
	stats_box.anchor_left = 0.0
	stats_box.anchor_top = 0.0
	stats_box.anchor_right = 0.0
	stats_box.anchor_bottom = 0.0
	stats_box.offset_left = 16.0
	stats_box.offset_top = 14.0
	stats_box.offset_right = 436.0
	stats_box.offset_bottom = 190.0
	stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_box.add_theme_constant_override("separation", 4)

	velocity_label = add_stat_label(stats_box, "VelocityLabel", "Speed: 0.0", 18, Color(1.0, 1.0, 1.0, 0.92), true)
	jump_force_label = add_stat_label(stats_box, "JumpForceLabel", "Jump Force: 10.0", 18, Color(1.0, 1.0, 1.0, 0.92), true)
	fps_label = add_stat_label(stats_box, "FPSLabel", "FPS: 0", 16, Color(1.0, 1.0, 1.0, 0.85), true)
	booster_label = add_stat_label(stats_box, "BoosterLabel", "", 16, Color(0.75, 0.9, 1.0, 0.88), false)
	limb_push_label = add_stat_label(stats_box, "LimbPushLabel", "", 16, Color(0.75, 1.0, 0.75, 0.9), false)


func add_stat_label(parent: Node, label_name: String, text: String, font_size: int, color: Color, visible: bool) -> Label:
	var label := Label.new()
	label.name = label_name
	parent.add_child(label)
	label.text = text
	label.visible = visible
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func build_top_right_health() -> void:
	health_panel = PanelContainer.new()
	health_panel.name = "HealthPanel"
	root.add_child(health_panel)
	health_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.0, 0.0, 0.0, 0.42)
	panel_style.border_color = Color(1.0, 1.0, 1.0, 0.22)
	panel_style.border_width_left = 1
	panel_style.border_width_right = 1
	panel_style.border_width_top = 1
	panel_style.border_width_bottom = 1
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 8
	panel_style.content_margin_bottom = 8
	health_panel.add_theme_stylebox_override("panel", panel_style)
	
	health_label = Label.new()
	health_label.name = "HealthLabel"
	health_panel.add_child(health_label)
	health_label.text = "Hits: 0 / 3"
	health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	health_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	health_label.add_theme_font_size_override("font_size", 18)
	health_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	health_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	place_top_right_control(health_panel, 230.0, 58.0, 16.0)


func build_center_reticle() -> void:
	reticle = Panel.new()
	reticle.name = "InteractionReticle"
	root.add_child(reticle)
	reticle.size = Vector2(8.0, 8.0)
	reticle.pivot_offset = Vector2(4.0, 4.0)
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 1.0, 1.0, 0.8)
	style.corner_radius_top_left = 100
	style.corner_radius_top_right = 100
	style.corner_radius_bottom_left = 100
	style.corner_radius_bottom_right = 100
	reticle.add_theme_stylebox_override("panel", style)
	
	center_control(reticle)


func build_ctrl_push_arrow() -> void:
	ctrl_push_arrow = Label.new()
	ctrl_push_arrow.name = "CtrlPushArrow"
	root.add_child(ctrl_push_arrow)
	ctrl_push_arrow.text = "▲"
	ctrl_push_arrow.visible = false
	ctrl_push_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ctrl_push_arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ctrl_push_arrow.size = Vector2(50.0, 50.0)
	ctrl_push_arrow.pivot_offset = Vector2(25.0, 25.0)
	ctrl_push_arrow.add_theme_font_size_override("font_size", 34)
	ctrl_push_arrow.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0, 0.9))
	ctrl_push_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE


func build_impact_effects() -> void:
	impact_shadow = ColorRect.new()
	impact_shadow.name = "ImpactShadow"
	root.add_child(impact_shadow)
	impact_shadow.set_anchors_preset(Control.PRESET_FULL_RECT)
	impact_shadow.offset_left = 0.0
	impact_shadow.offset_top = 0.0
	impact_shadow.offset_right = 0.0
	impact_shadow.offset_bottom = 0.0
	impact_shadow.color = Color(0.0, 0.0, 0.0, 0.0)
	impact_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	impact_flash = ColorRect.new()
	impact_flash.name = "ImpactFlash"
	root.add_child(impact_flash)
	impact_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	impact_flash.offset_left = 0.0
	impact_flash.offset_top = 0.0
	impact_flash.offset_right = 0.0
	impact_flash.offset_bottom = 0.0
	impact_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	impact_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	impact_value_label = Label.new()
	impact_value_label.name = "ImpactValueLabel"
	root.add_child(impact_value_label)
	impact_value_label.text = ""
	impact_value_label.visible = false
	impact_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	impact_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	impact_value_label.size = Vector2(500.0, 90.0)
	impact_value_label.add_theme_font_size_override("font_size", 32)
	impact_value_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	impact_value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	center_control(impact_value_label)
	impact_value_label.position.y += 120.0


func layout_dynamic_controls() -> void:
	if root == null:
		return
	
	if reticle != null:
		center_control(reticle)
	
	if impact_value_label != null:
		center_control(impact_value_label)
		impact_value_label.position.y += 120.0
	
	if health_panel != null:
		place_top_right_control(health_panel, 230.0, 58.0, 16.0)


func center_control(control: Control) -> void:
	if control == null:
		return
	
	var viewport_size := get_viewport().get_visible_rect().size
	control.position = viewport_size * 0.5 - control.size * 0.5


func place_top_right_control(
	control: Control,
	width: float,
	height: float,
	margin: float
) -> void:
	if control == null:
		return
	
	control.anchor_left = 1.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 0.0
	
	control.offset_left = -width - margin
	control.offset_top = margin
	control.offset_right = -margin
	control.offset_bottom = margin + height


func update_fps_label() -> void:
	if fps_label == null:
		return

	var text := "FPS: " + str(Engine.get_frames_per_second())

	if text != fps_label.text:
		fps_label.text = text


func update_velocity_indicator(velocity: Vector3) -> void:
	if velocity_label == null:
		return
	
	var speed := velocity.length()
	
	velocity_label.text = (
		"Speed: " + format_number(speed) +
		"   Vel: " +
		format_number(velocity.x) + ", " +
		format_number(velocity.y) + ", " +
		format_number(velocity.z)
	)


func update_jump_force(force: float) -> void:
	current_jump_force = force
	
	if jump_force_label == null:
		return
	
	jump_force_label.text = "Jump Force: " + format_number(force)


func update_health_status(hits: int, max_hits: int, disabled: bool) -> void:
	health_hits = hits
	health_max_hits = max_hits
	health_disabled = disabled
	
	if health_panel == null or health_label == null:
		return
	
	health_panel.visible = true
	
	if disabled:
		health_label.text = "DISABLED\nHits: " + str(hits) + " / " + str(max_hits)
		health_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35, 0.96))
	else:
		health_label.text = "Hits: " + str(hits) + " / " + str(max_hits)
		health_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))


func update_limb_push_indicator(should_show: bool, limb_state: Dictionary) -> void:
	if limb_push_label == null:
		return
	
	if not should_show:
		limb_push_label.visible = false
		return
	
	if limb_state.is_empty():
		limb_push_label.visible = false
		return
	
	var mode_text := String(limb_state.get("mode_text", "Push"))
	var summary_text := String(limb_state.get("summary_text", "No Limbs Near"))
	var has_limb_contact := bool(limb_state.get("has_limb_contact", false))
	var force_multiplier := float(limb_state.get("force_multiplier", 0.0))
	var limb_count := int(limb_state.get("valid_limb_count", 0))
	
	limb_push_label.visible = true
	
	if has_limb_contact:
		limb_push_label.text = (
			"Limb Push: " + mode_text +
			"\n" + summary_text +
			"\nForce: " + format_number(force_multiplier) + "x" +
			"   Limbs: " + str(limb_count)
		)
		limb_push_label.add_theme_color_override("font_color", Color(0.65, 1.0, 0.65, 0.92))
	else:
		limb_push_label.text = (
			"Limb Push: " + mode_text +
			"\nNo Limbs Near" +
			"\nForce: 0.0x"
		)
		limb_push_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.45))


func update_reticle(
	_delta: float,
	surface_in_range: bool,
	laser_aiming: bool,
	hidden: bool
) -> void:
	if reticle == null:
		return
	
	center_control(reticle)
	
	if hidden or laser_aiming:
		reticle.visible = false
		return
	
	reticle.visible = true
	
	var style := reticle.get_theme_stylebox("panel") as StyleBoxFlat
	
	if style == null:
		return
	
	if surface_in_range:
		style.bg_color = Color(0.45, 1.0, 0.55, 0.9)
	else:
		style.bg_color = Color(1.0, 1.0, 1.0, 0.45)


func update_push_direction_arrow(
	_delta: float,
	should_show: bool,
	world_direction: Vector3,
	camera: Camera3D
) -> void:
	if ctrl_push_arrow == null:
		return
	
	if not should_show:
		ctrl_push_arrow.visible = false
		return
	
	if camera == null:
		ctrl_push_arrow.visible = false
		return
	
	if world_direction.length() < 0.01:
		ctrl_push_arrow.visible = false
		return
	
	var point := camera.global_position + world_direction.normalized() * 8.0
	
	if camera.is_position_behind(point):
		ctrl_push_arrow.visible = false
		return
	
	var screen_position := camera.unproject_position(point)
	ctrl_push_arrow.position = screen_position - ctrl_push_arrow.size * 0.5
	ctrl_push_arrow.visible = true


func update_booster_ui(
	has_boosters: bool,
	current_fuel: float,
	max_fuel: float
) -> void:
	if booster_label == null:
		return
	
	if not has_boosters:
		booster_label.visible = false
		return
	
	booster_label.visible = true
	
	if max_fuel <= 0.0:
		booster_label.text = "Boosters: 0%"
		return
	
	var percent := (current_fuel / max_fuel) * 100.0
	booster_label.text = "Boosters: " + format_number(percent) + "%"


func update_impact_effect(
	_delta: float,
	strength: float,
	impact_value: float,
	immobilize_time_remaining: float
) -> void:
	strength = clampf(strength, 0.0, 1.0)
	
	if impact_shadow != null:
		impact_shadow.color = Color(0.0, 0.0, 0.0, strength * 0.42)
	
	if impact_flash != null:
		impact_flash.color = Color(1.0, 1.0, 1.0, strength * 0.18)
	
	if impact_value_label != null:
		if strength > 0.05 or immobilize_time_remaining > 0.0:
			impact_value_label.visible = true
			impact_value_label.text = (
				"IMPACT " + str(roundi(impact_value)) +
				"\nLOCK " + format_number(immobilize_time_remaining) + "s"
			)
		else:
			impact_value_label.visible = false


# Compatibility no-ops for old charge-bar code.
func update_push_charge(_current_charge: float, _max_charge: float = 1.0, _is_charging: bool = false) -> void:
	pass


func update_push_charge_bar(_current_charge: float, _max_charge: float = 1.0, _is_charging: bool = false) -> void:
	pass


func format_number(value: float) -> String:
	return "%0.1f" % value
