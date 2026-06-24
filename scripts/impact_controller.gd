class_name PlayerImpactController
extends Node

@export var min_impact_speed: float = 5.0
@export var heavy_impact_speed: float = 18.0
@export var max_impact_value: float = 100.0

@export var min_immobilize_time: float = 0.12
@export var max_immobilize_time: float = 1.15
@export var impact_cooldown_time: float = 0.25

@export var min_camera_shake: float = 0.015
@export var max_camera_shake: float = 0.13
@export var min_shake_duration: float = 0.12
@export var max_shake_duration: float = 0.45

@export var impact_angular_velocity_multiplier: float = 0.25
@export var max_contacts_reported: int = 8

@export var debug_print_impacts: bool = true

var player: RigidBody3D
var camera: Camera3D
var camera_rig: CameraRig
var hud_controller: PlayerHUDController

var camera_default_position: Vector3 = Vector3.ZERO

var previous_linear_velocity: Vector3 = Vector3.ZERO

var immobilize_time_remaining: float = 0.0
var impact_cooldown_remaining: float = 0.0

var shake_time_remaining: float = 0.0
var shake_duration: float = 0.0
var shake_intensity: float = 0.0

var impact_effect_strength: float = 0.0
var last_impact_value: float = 0.0


func setup(owner_player: RigidBody3D, owner_hud: PlayerHUDController) -> void:
	player = owner_player
	hud_controller = owner_hud
	
	camera = player.get_node_or_null("CameraRig/Camera3D") as Camera3D
	camera_rig = player.get_node_or_null("CameraRig") as CameraRig
	
	if camera == null:
		push_error("ImpactController could not find Camera3D.")
		return
	
	camera_default_position = camera.position
	previous_linear_velocity = player.linear_velocity
	
	player.contact_monitor = true
	player.max_contacts_reported = max(player.max_contacts_reported, max_contacts_reported)
	
	print("ImpactController setup complete")


func physics_update(delta: float) -> void:
	if player == null:
		return
	
	if immobilize_time_remaining > 0.0:
		immobilize_time_remaining -= delta
		immobilize_time_remaining = maxf(immobilize_time_remaining, 0.0)
	
	if impact_cooldown_remaining > 0.0:
		impact_cooldown_remaining -= delta
		impact_cooldown_remaining = maxf(impact_cooldown_remaining, 0.0)
	
	update_camera_shake(delta)
	update_impact_effect(delta)


func integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if player == null:
		return
	
	var contact_count := state.get_contact_count()
	
	if contact_count <= 0:
		previous_linear_velocity = state.linear_velocity
		return
	
	var strongest_impact_speed := 0.0
	
	for i in contact_count:
		var local_normal := state.get_contact_local_normal(i).normalized()
		var world_normal := (state.transform.basis * local_normal).normalized()
		
		var normal_impact_speed := absf(previous_linear_velocity.dot(world_normal))
		strongest_impact_speed = maxf(strongest_impact_speed, normal_impact_speed)
	
	var speed_loss := maxf(previous_linear_velocity.length() - state.linear_velocity.length(), 0.0)
	strongest_impact_speed = maxf(strongest_impact_speed, speed_loss * 0.75)
	
	if strongest_impact_speed >= min_impact_speed and impact_cooldown_remaining <= 0.0:
		trigger_impact(strongest_impact_speed)
		state.angular_velocity *= impact_angular_velocity_multiplier
	
	previous_linear_velocity = state.linear_velocity


func trigger_impact(impact_speed: float) -> void:
	var denominator := maxf(heavy_impact_speed - min_impact_speed, 0.001)
	var impact_percent := clampf((impact_speed - min_impact_speed) / denominator, 0.0, 1.0)
	
	var impact_value := lerpf(1.0, max_impact_value, impact_percent)
	var stun_time := lerpf(min_immobilize_time, max_immobilize_time, impact_percent)
	var new_shake_duration := lerpf(min_shake_duration, max_shake_duration, impact_percent)
	var new_shake_intensity := lerpf(min_camera_shake, max_camera_shake, impact_percent)
	
	last_impact_value = impact_value

	if camera_rig != null:
		camera_rig.kick_landing(impact_speed)

	immobilize_time_remaining = maxf(immobilize_time_remaining, stun_time)
	impact_cooldown_remaining = impact_cooldown_time
	
	shake_duration = new_shake_duration
	shake_time_remaining = new_shake_duration
	shake_intensity = new_shake_intensity
	
	impact_effect_strength = maxf(impact_effect_strength, impact_percent)
	
	if debug_print_impacts:
		print("Impact detected")
		print("Impact speed: ", snappedf(impact_speed, 0.01))
		print("Impact value: ", roundi(impact_value))
		print("Immobilized for: ", snappedf(stun_time, 0.01), "s")


func update_camera_shake(delta: float) -> void:
	if camera == null:
		return
	
	if shake_time_remaining <= 0.0:
		camera.position = camera.position.lerp(camera_default_position, 1.0 - exp(-18.0 * delta))
		return
	
	shake_time_remaining -= delta
	shake_time_remaining = maxf(shake_time_remaining, 0.0)
	
	var shake_percent := 0.0
	
	if shake_duration > 0.0:
		shake_percent = clampf(shake_time_remaining / shake_duration, 0.0, 1.0)
	
	var current_intensity := shake_intensity * shake_percent
	
	var random_offset := Vector3(
		randf_range(-current_intensity, current_intensity),
		randf_range(-current_intensity, current_intensity),
		0.0
	)
	
	camera.position = camera_default_position + random_offset


func update_impact_effect(delta: float) -> void:
	var stun_strength := 0.0
	
	if max_immobilize_time > 0.0:
		stun_strength = clampf(immobilize_time_remaining / max_immobilize_time, 0.0, 1.0)
	
	var target_strength := stun_strength
	
	if shake_time_remaining > 0.0:
		target_strength = maxf(target_strength, impact_effect_strength)
	
	var fade_weight := 1.0 - exp(-8.0 * delta)
	impact_effect_strength = lerpf(impact_effect_strength, target_strength, fade_weight)
	
	if immobilize_time_remaining <= 0.0 and shake_time_remaining <= 0.0:
		impact_effect_strength = lerpf(impact_effect_strength, 0.0, 1.0 - exp(-4.0 * delta))
	
	if hud_controller != null:
		hud_controller.update_impact_effect(
			delta,
			impact_effect_strength,
			last_impact_value,
			immobilize_time_remaining
		)


func is_immobilized() -> bool:
	return immobilize_time_remaining > 0.0


# Briefly skip impact detection (e.g. launching off a wall-walk surface).
func ignore_impacts_briefly() -> void:
	impact_cooldown_remaining = maxf(impact_cooldown_remaining, impact_cooldown_time)
