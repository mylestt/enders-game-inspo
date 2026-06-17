extends Node
class_name PlayerHUDController

var player: RigidBody3D

var hud_layer: CanvasLayer
var root: Control

var velocity_label: Label
var jump_force_label: Label
var booster_label: Label

var reticle: Panel
var ctrl_push_arrow: Label

var impact_flash: ColorRect
var impact_shadow: ColorRect
var impact_value_label: Label

var current_jump_force: float = 10.0


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player
	
	hide_old_push_charge_bar()
	build_hud()
	update_jump_force(current_jump_force)


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
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	build_top_left_stats()
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
	stats_box.position = Vector2(16.0, 14.0)
	stats_box.size = Vector2(360.0, 120.0)
	stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_box.add_theme_constant_override("separation", 4)
	
	velocity_label = Label.new()
	velocity_label.name = "VelocityLabel"
	stats_box.add_child(velocity_label)
	velocity_label.text = "Speed: 0.0"
	velocity_label.add_theme_font_size_override("font_size", 18)
	velocity_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	velocity_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	jump_force_label = Label.new()
	jump_force_label.name = "JumpForceLabel"
	stats_box.add_child(jump_force_label)
	jump_force_label.text = "Jump Force: 10.0"
	jump_force_label.add_theme_font_size_override("font_size", 18)
	jump_force_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	jump_force_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	booster_label = Label.new()
	booster_label.name = "BoosterLabel"
	stats_box.add_child(booster_label)
	booster_label.text = ""
	booster_label.visible = false
	booster_label.add_theme_font_size_override("font_size", 16)
	booster_label.add_theme_color_override("font_color", Color(0.75, 0.9, 1.0, 0.88))
	booster_label.mouse_filter = Control.MOUSE_FILTER_IGNORE


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
	impact_shadow.color = Color(0.0, 0.0, 0.0, 0.0)
	impact_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	impact_flash = ColorRect.new()
	impact_flash.name = "ImpactFlash"
	root.add_child(impact_flash)
	impact_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
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


func center_control(control: Control) -> void:
	if control == null:
		return
	
	var viewport_size := get_viewport().get_visible_rect().size
	control.position = viewport_size * 0.5 - control.size * 0.5


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
