class_name PlayerHUDController
extends Node

@export var reticle_size: float = 6.0
@export var reticle_max_alpha: float = 0.45
@export var reticle_fade_speed: float = 18.0

@export var push_arrow_size: float = 48.0
@export var push_arrow_max_alpha: float = 0.75
@export var push_arrow_fade_speed: float = 20.0
@export var push_arrow_vertical_offset: float = -105.0

@export var impact_shadow_max_alpha: float = 0.8
@export var impact_shadow_border_width: int = 95
@export var impact_flash_max_alpha: float = 0.12
@export var show_impact_value_label: bool = true

@export var show_velocity_indicator: bool = true
@export var velocity_indicator_alpha: float = 0.65
@export var velocity_indicator_font_size: int = 18

@export var booster_bar_alpha: float = 0.8

var player: RigidBody3D
var hud: Control

var push_charge_bar: ProgressBar

var reticle_dot: Panel
var reticle_alpha: float = 0.0

var push_direction_arrow: Label
var push_arrow_alpha: float = 0.0

var impact_shadow: Panel
var impact_shadow_style: StyleBoxFlat
var impact_flash: ColorRect
var impact_value_label: Label

var velocity_label: Label

var booster_bar: ProgressBar
var booster_label: Label


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player
	hud = player.get_node_or_null("UI/HUD") as Control
	
	if hud == null:
		push_error("PlayerHUDController could not find UI/HUD under the Player scene.")
		return
	
	setup_hud_root()
	setup_push_charge_ui()
	setup_reticle()
	setup_push_direction_arrow()
	setup_velocity_indicator()
	setup_booster_ui()
	setup_impact_effect()
	
	print("PlayerHUDController setup complete")


func setup_hud_root() -> void:
	hud.anchor_left = 0.0
	hud.anchor_top = 0.0
	hud.anchor_right = 1.0
	hud.anchor_bottom = 1.0
	hud.offset_left = 0.0
	hud.offset_top = 0.0
	hud.offset_right = 0.0
	hud.offset_bottom = 0.0


func setup_push_charge_ui() -> void:
	push_charge_bar = hud.get_node_or_null("PushChargeBar") as ProgressBar
	
	if push_charge_bar == null:
		push_warning("PushChargeBar was not found. Make sure the path is UI/HUD/PushChargeBar.")
		return
	
	push_charge_bar.min_value = 0.0
	push_charge_bar.max_value = 100.0
	push_charge_bar.step = 0.1
	push_charge_bar.value = 0.0
	push_charge_bar.visible = false
	push_charge_bar.show_percentage = false
	
	push_charge_bar.anchor_left = 0.5
	push_charge_bar.anchor_right = 0.5
	push_charge_bar.anchor_top = 1.0
	push_charge_bar.anchor_bottom = 1.0
	
	push_charge_bar.offset_left = -150.0
	push_charge_bar.offset_right = 150.0
	push_charge_bar.offset_top = -90.0
	push_charge_bar.offset_bottom = -66.0


func setup_reticle() -> void:
	reticle_dot = hud.get_node_or_null("ReticleDot") as Panel
	
	if reticle_dot == null:
		reticle_dot = Panel.new()
		reticle_dot.name = "ReticleDot"
		hud.add_child(reticle_dot)
	
	reticle_dot.visible = false
	reticle_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	reticle_dot.anchor_left = 0.5
	reticle_dot.anchor_right = 0.5
	reticle_dot.anchor_top = 0.5
	reticle_dot.anchor_bottom = 0.5
	
	reticle_dot.offset_left = -reticle_size / 2.0
	reticle_dot.offset_right = reticle_size / 2.0
	reticle_dot.offset_top = -reticle_size / 2.0
	reticle_dot.offset_bottom = reticle_size / 2.0
	
	var reticle_style := StyleBoxFlat.new()
	reticle_style.bg_color = Color.WHITE
	reticle_style.corner_radius_top_left = 100
	reticle_style.corner_radius_top_right = 100
	reticle_style.corner_radius_bottom_left = 100
	reticle_style.corner_radius_bottom_right = 100
	
	reticle_dot.add_theme_stylebox_override("panel", reticle_style)
	reticle_dot.modulate = Color(1.0, 1.0, 1.0, 0.0)


func setup_push_direction_arrow() -> void:
	push_direction_arrow = hud.get_node_or_null("PushDirectionArrow") as Label
	
	if push_direction_arrow == null:
		push_direction_arrow = Label.new()
		push_direction_arrow.name = "PushDirectionArrow"
		hud.add_child(push_direction_arrow)
	
	push_direction_arrow.text = "▲"
	push_direction_arrow.visible = false
	push_direction_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	push_direction_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	push_direction_arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	push_direction_arrow.add_theme_font_size_override("font_size", int(push_arrow_size))
	push_direction_arrow.add_theme_color_override("font_color", Color.WHITE)
	
	push_direction_arrow.anchor_left = 0.5
	push_direction_arrow.anchor_right = 0.5
	push_direction_arrow.anchor_top = 0.5
	push_direction_arrow.anchor_bottom = 0.5
	
	push_direction_arrow.offset_left = -push_arrow_size / 2.0
	push_direction_arrow.offset_right = push_arrow_size / 2.0
	push_direction_arrow.offset_top = push_arrow_vertical_offset - push_arrow_size / 2.0
	push_direction_arrow.offset_bottom = push_arrow_vertical_offset + push_arrow_size / 2.0
	
	push_direction_arrow.pivot_offset = Vector2(push_arrow_size / 2.0, push_arrow_size / 2.0)
	push_direction_arrow.modulate = Color(1.0, 1.0, 1.0, 0.0)


func setup_impact_effect() -> void:
	impact_flash = hud.get_node_or_null("ImpactFlash") as ColorRect
	
	if impact_flash == null:
		impact_flash = ColorRect.new()
		impact_flash.name = "ImpactFlash"
		hud.add_child(impact_flash)
	
	impact_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	impact_flash.anchor_left = 0.0
	impact_flash.anchor_top = 0.0
	impact_flash.anchor_right = 1.0
	impact_flash.anchor_bottom = 1.0
	impact_flash.offset_left = 0.0
	impact_flash.offset_top = 0.0
	impact_flash.offset_right = 0.0
	impact_flash.offset_bottom = 0.0
	impact_flash.color = Color(0.0, 0.0, 0.0, 0.0)
	impact_flash.visible = false
	
	impact_shadow = hud.get_node_or_null("ImpactShadow") as Panel
	
	if impact_shadow == null:
		impact_shadow = Panel.new()
		impact_shadow.name = "ImpactShadow"
		hud.add_child(impact_shadow)
	
	impact_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	impact_shadow.anchor_left = 0.0
	impact_shadow.anchor_top = 0.0
	impact_shadow.anchor_right = 1.0
	impact_shadow.anchor_bottom = 1.0
	impact_shadow.offset_left = 0.0
	impact_shadow.offset_top = 0.0
	impact_shadow.offset_right = 0.0
	impact_shadow.offset_bottom = 0.0
	impact_shadow.visible = false
	
	impact_shadow_style = StyleBoxFlat.new()
	impact_shadow_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	impact_shadow_style.border_color = Color(0.0, 0.0, 0.0, 0.0)
	impact_shadow_style.border_width_left = impact_shadow_border_width
	impact_shadow_style.border_width_right = impact_shadow_border_width
	impact_shadow_style.border_width_top = impact_shadow_border_width
	impact_shadow_style.border_width_bottom = impact_shadow_border_width
	
	impact_shadow.add_theme_stylebox_override("panel", impact_shadow_style)
	
	impact_value_label = hud.get_node_or_null("ImpactValueLabel") as Label
	
	if impact_value_label == null:
		impact_value_label = Label.new()
		impact_value_label.name = "ImpactValueLabel"
		hud.add_child(impact_value_label)
	
	impact_value_label.visible = false
	impact_value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	impact_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	impact_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	impact_value_label.add_theme_font_size_override("font_size", 20)
	impact_value_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.75))
	
	impact_value_label.anchor_left = 0.5
	impact_value_label.anchor_right = 0.5
	impact_value_label.anchor_top = 0.5
	impact_value_label.anchor_bottom = 0.5
	
	impact_value_label.offset_left = -160.0
	impact_value_label.offset_right = 160.0
	impact_value_label.offset_top = 95.0
	impact_value_label.offset_bottom = 145.0


func setup_velocity_indicator() -> void:
	velocity_label = hud.get_node_or_null("VelocityIndicator") as Label
	
	if velocity_label == null:
		velocity_label = Label.new()
		velocity_label.name = "VelocityIndicator"
		hud.add_child(velocity_label)
	
	velocity_label.visible = show_velocity_indicator
	velocity_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	velocity_label.anchor_left = 0.0
	velocity_label.anchor_right = 0.0
	velocity_label.anchor_top = 0.0
	velocity_label.anchor_bottom = 0.0
	
	velocity_label.offset_left = 24.0
	velocity_label.offset_right = 420.0
	velocity_label.offset_top = 24.0
	velocity_label.offset_bottom = 90.0
	
	velocity_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, velocity_indicator_alpha))
	velocity_label.add_theme_font_size_override("font_size", velocity_indicator_font_size)
	
	update_velocity_indicator(Vector3.ZERO)


func setup_booster_ui() -> void:
	booster_label = hud.get_node_or_null("BoosterFuelLabel") as Label
	
	if booster_label == null:
		booster_label = Label.new()
		booster_label.name = "BoosterFuelLabel"
		hud.add_child(booster_label)
	
	booster_label.text = "BOOSTER FUEL"
	booster_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	booster_label.add_theme_font_size_override("font_size", 14)
	booster_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, booster_bar_alpha))
	
	booster_label.anchor_left = 1.0
	booster_label.anchor_right = 1.0
	booster_label.anchor_top = 1.0
	booster_label.anchor_bottom = 1.0
	
	booster_label.offset_left = -250.0
	booster_label.offset_right = -24.0
	booster_label.offset_top = -86.0
	booster_label.offset_bottom = -62.0
	
	booster_bar = hud.get_node_or_null("BoosterFuelBar") as ProgressBar
	
	if booster_bar == null:
		booster_bar = ProgressBar.new()
		booster_bar.name = "BoosterFuelBar"
		hud.add_child(booster_bar)
	
	booster_bar.min_value = 0.0
	booster_bar.max_value = 100.0
	booster_bar.value = 0.0
	booster_bar.show_percentage = false
	booster_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	booster_bar.anchor_left = 1.0
	booster_bar.anchor_right = 1.0
	booster_bar.anchor_top = 1.0
	booster_bar.anchor_bottom = 1.0
	
	booster_bar.offset_left = -250.0
	booster_bar.offset_right = -24.0
	booster_bar.offset_top = -60.0
	booster_bar.offset_bottom = -36.0
	
	update_booster_ui(false, 0.0, 100.0)


func update_push_charge_ui(charge_percent: float, should_show: bool, can_push: bool = true) -> void:
	if push_charge_bar == null:
		return

	push_charge_bar.visible = should_show
	push_charge_bar.value = clampf(charge_percent * 100.0, 0.0, 100.0)
	push_charge_bar.modulate = Color.WHITE if can_push else Color(1.0, 0.5, 0.5, 0.55)


func update_reticle(delta: float, surface_in_range: bool, laser_aiming: bool, buy_menu_or_input_locked: bool) -> void:
	if reticle_dot == null:
		return
	
	var target_alpha := 0.0
	
	if surface_in_range and not laser_aiming and not buy_menu_or_input_locked:
		target_alpha = reticle_max_alpha
	
	var fade_weight := 1.0 - exp(-reticle_fade_speed * delta)
	reticle_alpha = lerpf(reticle_alpha, target_alpha, fade_weight)
	
	reticle_dot.modulate = Color(1.0, 1.0, 1.0, reticle_alpha)
	reticle_dot.visible = reticle_alpha > 0.01


func update_push_direction_arrow(
	delta: float,
	should_show: bool,
	launch_direction: Vector3,
	camera: Camera3D
) -> void:
	if push_direction_arrow == null:
		return
	
	var target_alpha := push_arrow_max_alpha if should_show else 0.0
	var fade_weight := 1.0 - exp(-push_arrow_fade_speed * delta)
	push_arrow_alpha = lerpf(push_arrow_alpha, target_alpha, fade_weight)
	
	push_direction_arrow.modulate = Color(1.0, 1.0, 1.0, push_arrow_alpha)
	push_direction_arrow.visible = push_arrow_alpha > 0.01
	
	if camera == null:
		return
	
	if launch_direction.length() < 0.001:
		return
	
	var local_direction := camera.global_transform.basis.inverse() * launch_direction.normalized()
	var screen_direction := Vector2(local_direction.x, -local_direction.y)
	
	if screen_direction.length() < 0.01:
		push_direction_arrow.rotation = 0.0
		return
	
	screen_direction = screen_direction.normalized()
	push_direction_arrow.rotation = atan2(screen_direction.x, -screen_direction.y)


func update_impact_effect(
	_delta: float,
	strength: float,
	impact_value: float,
	immobilize_time_remaining: float
) -> void:
	var clamped_strength := clampf(strength, 0.0, 1.0)
	
	if impact_flash != null:
		var flash_alpha := impact_flash_max_alpha * clamped_strength
		impact_flash.color = Color(0.0, 0.0, 0.0, flash_alpha)
		impact_flash.visible = flash_alpha > 0.01
	
	if impact_shadow != null and impact_shadow_style != null:
		var shadow_alpha := impact_shadow_max_alpha * clamped_strength
		impact_shadow_style.border_color = Color(0.0, 0.0, 0.0, shadow_alpha)
		impact_shadow.visible = shadow_alpha > 0.01
	
	if impact_value_label != null:
		var label_alpha := clampf(clamped_strength * 1.25, 0.0, 1.0)
		
		impact_value_label.visible = show_impact_value_label and label_alpha > 0.01
		impact_value_label.modulate = Color(1.0, 1.0, 1.0, label_alpha)
		
		impact_value_label.text = (
			"IMPACT " + str(roundi(impact_value))
			+ "\nCONTROL LOCK " + str(snappedf(immobilize_time_remaining, 0.01)) + "s"
		)


func update_velocity_indicator(current_velocity: Vector3) -> void:
	if velocity_label == null:
		return
	
	velocity_label.visible = show_velocity_indicator
	
	if not show_velocity_indicator:
		return
	
	var speed := current_velocity.length()
	
	velocity_label.text = (
		"Speed: " + str(snappedf(speed, 0.01)) + " m/s"
		+ "\nVelocity: "
		+ str(snappedf(current_velocity.x, 0.01)) + ", "
		+ str(snappedf(current_velocity.y, 0.01)) + ", "
		+ str(snappedf(current_velocity.z, 0.01))
	)


func update_booster_ui(has_boosters: bool, fuel: float, max_fuel: float) -> void:
	if booster_bar == null or booster_label == null:
		return
	
	booster_bar.visible = has_boosters
	booster_label.visible = has_boosters
	
	booster_bar.max_value = max_fuel
	booster_bar.value = clampf(fuel, 0.0, max_fuel)
