extends Node
class_name PlayerHUDController

var player: RigidBody3D

var hud_layer: CanvasLayer
var root: Control

var velocity_label: Label
var health_label: Label
var jump_force_label: Label
var fps_label: Label
var booster_label: Label
var ground_lock_label: Label
var limb_push_label: Label
var ammo_label: Label

var reticle: Panel
var ctrl_push_arrow: Label

var death_screen: ColorRect
var hurt_shadow: ColorRect
var hurt_flash: ColorRect
var hurt_effect_strength: float = 0.0

var hitmarker_label: Label
var hitmarker_time: float = 0.0
var hitmarker_color: Color = Color(1.0, 1.0, 1.0)
const HITMARKER_DURATION := 0.18

var current_jump_force: float = 10.0

var _last_viewport_size: Vector2 = Vector2.ZERO

@export var hurt_effect_fade_speed: float = 7.0
@export var hurt_flash_alpha: float = 0.34
@export var hurt_shadow_alpha: float = 0.24


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player

	# A dedicated server has no screen; every update_* method already null-checks its
	# controls, so skipping the build makes the whole HUD a no-op there.
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return

	build_hud()
	update_jump_force(current_jump_force)


func _process(delta: float) -> void:
	update_fps_label()
	update_hitmarker(delta)
	update_hurt_effect(delta)

	var viewport_size := get_viewport().get_visible_rect().size

	if viewport_size != _last_viewport_size:
		_last_viewport_size = viewport_size
		layout_dynamic_controls()


# Hide the whole HUD for non-local players (each player instance builds its own HUD;
# only the local player's should be visible).
func set_hud_active(active: bool) -> void:
	if hud_layer != null:
		hud_layer.visible = active

	set_process(active)


func show_hitmarker(is_kill: bool = false) -> void:
	if hitmarker_label == null:
		return

	# White for a normal hit, red when this shot was the kill (dropped them to zero health).
	hitmarker_color = Color(1.0, 0.22, 0.22) if is_kill else Color(1.0, 1.0, 1.0)
	hitmarker_time = HITMARKER_DURATION
	hitmarker_label.visible = true
	hitmarker_label.modulate = Color(hitmarker_color.r, hitmarker_color.g, hitmarker_color.b, 1.0)
	center_control(hitmarker_label)


func update_hitmarker(delta: float) -> void:
	if hitmarker_label == null or hitmarker_time <= 0.0:
		return

	hitmarker_time -= delta

	if hitmarker_time <= 0.0:
		hitmarker_label.visible = false
		return

	var fade := clampf(hitmarker_time / HITMARKER_DURATION, 0.0, 1.0)
	hitmarker_label.modulate = Color(hitmarker_color.r, hitmarker_color.g, hitmarker_color.b, fade)


func show_hurt_effect(damage_ratio: float = 0.15) -> void:
	var strength := clampf(0.25 + damage_ratio * 1.8, 0.25, 1.0)
	hurt_effect_strength = maxf(hurt_effect_strength, strength)
	update_hurt_effect(0.0)


func update_hurt_effect(delta: float) -> void:
	if hurt_flash == null or hurt_shadow == null:
		return

	if hurt_effect_strength > 0.0 and delta > 0.0:
		hurt_effect_strength = lerpf(
			hurt_effect_strength,
			0.0,
			1.0 - exp(-hurt_effect_fade_speed * delta)
		)

		if hurt_effect_strength < 0.01:
			hurt_effect_strength = 0.0

	hurt_shadow.color = Color(0.35, 0.0, 0.0, hurt_effect_strength * hurt_shadow_alpha)
	hurt_flash.color = Color(1.0, 0.0, 0.0, hurt_effect_strength * hurt_flash_alpha)


func set_dead_screen_active(active: bool) -> void:
	if death_screen != null:
		death_screen.visible = active

	hurt_effect_strength = 0.0
	update_hurt_effect(0.0)


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
	
	build_damage_state_effects()
	build_top_left_stats()
	build_center_reticle()
	build_ctrl_push_arrow()
	build_hitmarker()


func build_hitmarker() -> void:
	hitmarker_label = Label.new()
	hitmarker_label.name = "Hitmarker"
	root.add_child(hitmarker_label)
	hitmarker_label.text = "✕"
	hitmarker_label.visible = false
	hitmarker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hitmarker_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hitmarker_label.size = Vector2(44.0, 44.0)
	hitmarker_label.pivot_offset = Vector2(22.0, 22.0)
	hitmarker_label.add_theme_font_size_override("font_size", 30)
	hitmarker_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	hitmarker_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center_control(hitmarker_label)


func build_damage_state_effects() -> void:
	death_screen = ColorRect.new()
	death_screen.name = "DeathScreen"
	root.add_child(death_screen)
	death_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	death_screen.offset_left = 0.0
	death_screen.offset_top = 0.0
	death_screen.offset_right = 0.0
	death_screen.offset_bottom = 0.0
	death_screen.color = Color(0.0, 0.0, 0.0, 0.98)
	death_screen.visible = false
	death_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE

	hurt_shadow = ColorRect.new()
	hurt_shadow.name = "HurtShadow"
	root.add_child(hurt_shadow)
	hurt_shadow.set_anchors_preset(Control.PRESET_FULL_RECT)
	hurt_shadow.offset_left = 0.0
	hurt_shadow.offset_top = 0.0
	hurt_shadow.offset_right = 0.0
	hurt_shadow.offset_bottom = 0.0
	hurt_shadow.color = Color(0.35, 0.0, 0.0, 0.0)
	hurt_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE

	hurt_flash = ColorRect.new()
	hurt_flash.name = "HurtFlash"
	root.add_child(hurt_flash)
	hurt_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	hurt_flash.offset_left = 0.0
	hurt_flash.offset_top = 0.0
	hurt_flash.offset_right = 0.0
	hurt_flash.offset_bottom = 0.0
	hurt_flash.color = Color(1.0, 0.0, 0.0, 0.0)
	hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE


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
	stats_box.offset_bottom = 220.0
	stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_box.add_theme_constant_override("separation", 4)

	health_label = add_stat_label(stats_box, "HealthLabel", "Health: 100 / 100", 18, Color(0.95, 1.0, 0.95, 0.94), true)
	velocity_label = add_stat_label(stats_box, "VelocityLabel", "Speed: 0.0", 18, Color(1.0, 1.0, 1.0, 0.92), true)
	jump_force_label = add_stat_label(stats_box, "JumpForceLabel", "Jump Force: 10.0", 18, Color(1.0, 1.0, 1.0, 0.92), true)
	fps_label = add_stat_label(stats_box, "FPSLabel", "FPS: 0", 16, Color(1.0, 1.0, 1.0, 0.85), true)
	booster_label = add_stat_label(stats_box, "BoosterLabel", "", 16, Color(0.75, 0.9, 1.0, 0.88), false)
	ground_lock_label = add_stat_label(stats_box, "GroundLockLabel", "", 16, Color(0.65, 1.0, 0.75, 0.94), false)
	limb_push_label = add_stat_label(stats_box, "LimbPushLabel", "", 16, Color(0.75, 1.0, 0.75, 0.9), false)
	ammo_label = add_stat_label(stats_box, "AmmoLabel", "", 18, Color(1.0, 0.95, 0.75, 0.95), false)


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


func layout_dynamic_controls() -> void:
	if root == null:
		return

	if reticle != null:
		center_control(reticle)


func center_control(control: Control) -> void:
	if control == null:
		return
	
	var viewport_size := get_viewport().get_visible_rect().size
	control.position = viewport_size * 0.5 - control.size * 0.5


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


func update_health(current_health: float, max_health: float) -> void:
	if health_label == null:
		return
	
	health_label.text = (
		"Health: " +
		str(roundi(current_health)) +
		" / " +
		str(roundi(max_health))
	)
	
	var ratio := 0.0
	
	if max_health > 0.0:
		ratio = clampf(current_health / max_health, 0.0, 1.0)
	
	if ratio <= 0.25:
		health_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3, 0.96))
	elif ratio <= 0.55:
		health_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.35, 0.96))
	else:
		health_label.add_theme_color_override("font_color", Color(0.95, 1.0, 0.95, 0.94))


func update_jump_force(force: float) -> void:
	# Called every physics frame by the movement controller; skip the label rebuild
	# unless the value actually changed.
	if is_equal_approx(force, current_jump_force) and jump_force_label != null and jump_force_label.text != "":
		return

	current_jump_force = force

	if jump_force_label == null:
		return

	jump_force_label.text = "Jump Force: " + format_number(force)


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


func update_ground_lock_indicator(
	should_show: bool,
	can_ground_lock: bool,
	is_ground_locked: bool
) -> void:
	if ground_lock_label == null:
		return
	
	if not should_show or (not can_ground_lock and not is_ground_locked):
		ground_lock_label.visible = false
		return
	
	ground_lock_label.visible = true
	
	if is_ground_locked:
		ground_lock_label.text = "Ground Lock: ON (C)"
		ground_lock_label.add_theme_color_override("font_color", Color(0.65, 0.9, 1.0, 0.94))
	else:
		ground_lock_label.text = "Ground Lock: READY (C)"
		ground_lock_label.add_theme_color_override("font_color", Color(0.65, 1.0, 0.75, 0.94))


func update_reticle(
	_delta: float,
	surface_in_range: bool,
	hidden: bool
) -> void:
	if reticle == null:
		return
	
	center_control(reticle)
	
	if hidden:
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


func update_ammo(current_ammo: int, reserve_ammo: int, reloading: bool) -> void:
	if ammo_label == null:
		return

	if current_ammo < 0:
		ammo_label.visible = false
		return

	ammo_label.visible = true

	if reloading:
		ammo_label.text = "Ammo: reloading…"
	else:
		ammo_label.text = "Ammo: " + str(current_ammo) + " / " + str(reserve_ammo)


func format_number(value: float) -> String:
	return "%0.1f" % value
