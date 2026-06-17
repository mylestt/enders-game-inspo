class_name PlayerHealthController
extends Node

@export var max_hits: int = 5
@export var show_debug_health_label: bool = true

var player: RigidBody3D
var hud: Control
var health_label: Label

var hit_count: int = 0
var combat_disabled: bool = false
var is_local_player: bool = false


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player
	hud = player.get_node_or_null("UI/HUD") as Control
	
	setup_health_label()
	update_health_label()
	
	print("HealthController setup complete")


func setup_health_label() -> void:
	if hud == null:
		return
	
	health_label = hud.get_node_or_null("HealthStatusLabel") as Label
	
	if health_label == null:
		health_label = Label.new()
		health_label.name = "HealthStatusLabel"
		hud.add_child(health_label)
	
	health_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	health_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	health_label.anchor_left = 0.5
	health_label.anchor_right = 0.5
	health_label.anchor_top = 0.0
	health_label.anchor_bottom = 0.0
	
	health_label.offset_left = -180.0
	health_label.offset_right = 180.0
	health_label.offset_top = 24.0
	health_label.offset_bottom = 80.0
	
	health_label.add_theme_font_size_override("font_size", 22)
	health_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))


func set_is_local_player(value: bool) -> void:
	is_local_player = value
	update_health_label()


func add_hit(amount: int = 1) -> void:
	if combat_disabled:
		return
	
	hit_count += amount
	hit_count = clampi(hit_count, 0, max_hits)
	
	if hit_count >= max_hits:
		combat_disabled = true
	
	update_health_label()


func set_network_state(new_hit_count: int, new_combat_disabled: bool) -> void:
	hit_count = clampi(new_hit_count, 0, max_hits)
	combat_disabled = new_combat_disabled
	
	update_health_label()


func reset_health() -> void:
	hit_count = 0
	combat_disabled = false
	
	update_health_label()


func get_hit_count() -> int:
	return hit_count


func is_combat_disabled() -> bool:
	return combat_disabled


func update_health_label() -> void:
	if health_label == null:
		return
	
	health_label.visible = show_debug_health_label and is_local_player
	
	if not health_label.visible:
		return
	
	if combat_disabled:
		health_label.text = "DISABLED\nHits: " + str(hit_count) + " / " + str(max_hits)
		health_label.add_theme_color_override("font_color", Color(1.0, 0.25, 0.25, 0.95))
	else:
		health_label.text = "Hits: " + str(hit_count) + " / " + str(max_hits)
		health_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))
