class_name WeaponSpringSway
extends Node3D

@export var rotation_sway_strength: Vector3 = Vector3(0.055, 0.07, 0.03)
@export var position_sway_strength: Vector3 = Vector3(0.014, 0.011, 0.004)
@export var max_rotation_degrees: Vector3 = Vector3(6.5, 8.0, 3.5)
@export var max_position_offset: Vector3 = Vector3(0.055, 0.04, 0.025)

@export var rotation_stiffness: float = 46.0
@export var rotation_damping: float = 9.0
@export var position_stiffness: float = 52.0
@export var position_damping: float = 10.5

@export var weight_amplitude_multiplier: float = 0.045
@export var weight_lag_multiplier: float = 0.065
@export var max_weight_amplitude_factor: float = 1.85
@export var max_weight_lag_factor: float = 2.6

@export var max_look_speed: float = 9.0
@export var max_move_speed: float = 22.0
@export var reset_when_no_weapon: bool = true

@export_group("Recoil")
@export var recoil_rotation_velocity_scale: float = 16.0
@export var recoil_position_velocity_scale: float = 18.0
@export var recoil_weight_resistance: float = 0.0
@export var min_recoil_weight_factor: float = 0.35

var equipped_weapon: Weapon
var rest_position: Vector3
var rest_rotation: Vector3
var position_offset: Vector3 = Vector3.ZERO
var position_velocity: Vector3 = Vector3.ZERO
var rotation_offset: Vector3 = Vector3.ZERO
var rotation_velocity: Vector3 = Vector3.ZERO
var previous_parent_transform: Transform3D
var has_previous_parent_transform: bool = false


func _ready() -> void:
	process_priority = -50
	rest_position = position
	rest_rotation = rotation
	cache_parent_transform()


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	
	var parent_node := get_parent() as Node3D
	
	if parent_node == null:
		return
	
	if not has_previous_parent_transform:
		cache_parent_transform()
		return
	
	var parent_transform := parent_node.global_transform
	var look_velocity := get_local_look_velocity(parent_transform, delta)
	var move_velocity := get_local_move_velocity(parent_transform, delta)
	var weapon_weight := get_equipped_weapon_weight()
	var amplitude_factor := get_weight_amplitude_factor(weapon_weight)
	var lag_factor := get_weight_lag_factor(weapon_weight)
	
	var target_rotation := get_target_rotation(look_velocity, amplitude_factor)
	var target_position := get_target_position(look_velocity, move_velocity, amplitude_factor)
	
	update_spring(
		delta,
		target_rotation,
		target_position,
		lag_factor
	)
	
	rotation = rest_rotation + rotation_offset
	position = rest_position + position_offset
	previous_parent_transform = parent_transform


func set_equipped_weapon(new_weapon: Weapon) -> void:
	equipped_weapon = new_weapon
	
	if equipped_weapon == null and reset_when_no_weapon:
		reset_sway()


func reset_sway() -> void:
	position_offset = Vector3.ZERO
	position_velocity = Vector3.ZERO
	rotation_offset = Vector3.ZERO
	rotation_velocity = Vector3.ZERO
	position = rest_position
	rotation = rest_rotation
	cache_parent_transform()


func apply_recoil(rotation_degrees: Vector3, position_kick: Vector3) -> void:
	var recoil_weight_factor := get_recoil_weight_factor(get_equipped_weapon_weight())
	var rotation_kick := Vector3(
		deg_to_rad(rotation_degrees.x),
		deg_to_rad(rotation_degrees.y),
		deg_to_rad(rotation_degrees.z)
	) * recoil_weight_factor
	var weighted_position_kick := position_kick * recoil_weight_factor
	
	rotation_offset = clamp_rotation(rotation_offset + rotation_kick)
	position_offset = clamp_position(position_offset + weighted_position_kick)
	rotation_velocity += rotation_kick * recoil_rotation_velocity_scale
	position_velocity += weighted_position_kick * recoil_position_velocity_scale


func get_target_rotation(look_velocity: Vector3, amplitude_factor: float) -> Vector3:
	look_velocity = clamp_vector3(look_velocity, -max_look_speed, max_look_speed)
	
	var target := Vector3(
		-look_velocity.x * rotation_sway_strength.x,
		-look_velocity.y * rotation_sway_strength.y,
		look_velocity.y * rotation_sway_strength.z
	) * amplitude_factor
	
	return clamp_rotation(target)


func get_target_position(
	look_velocity: Vector3,
	move_velocity: Vector3,
	amplitude_factor: float
) -> Vector3:
	look_velocity = clamp_vector3(look_velocity, -max_look_speed, max_look_speed)
	move_velocity = clamp_vector3(move_velocity, -max_move_speed, max_move_speed)
	
	var target := Vector3(
		-look_velocity.y * position_sway_strength.x,
		look_velocity.x * position_sway_strength.y,
		-move_velocity.z * position_sway_strength.z
	) * amplitude_factor
	
	return clamp_position(target)


func update_spring(
	delta: float,
	target_rotation: Vector3,
	target_position: Vector3,
	lag_factor: float
) -> void:
	var effective_rotation_stiffness := rotation_stiffness / lag_factor
	var effective_position_stiffness := position_stiffness / lag_factor
	
	rotation_velocity += (target_rotation - rotation_offset) * effective_rotation_stiffness * delta
	position_velocity += (target_position - position_offset) * effective_position_stiffness * delta
	
	rotation_velocity *= exp(-rotation_damping * delta)
	position_velocity *= exp(-position_damping * delta)
	
	rotation_offset += rotation_velocity * delta
	position_offset += position_velocity * delta
	
	rotation_offset = clamp_rotation(rotation_offset)
	position_offset = clamp_position(position_offset)


func get_local_look_velocity(parent_transform: Transform3D, delta: float) -> Vector3:
	var delta_basis := previous_parent_transform.basis.inverse() * parent_transform.basis
	return delta_basis.get_euler() * (1.0 / delta)


func get_local_move_velocity(parent_transform: Transform3D, delta: float) -> Vector3:
	var world_velocity := (parent_transform.origin - previous_parent_transform.origin) * (1.0 / delta)
	return parent_transform.basis.inverse() * world_velocity


func get_equipped_weapon_weight() -> float:
	if equipped_weapon == null:
		return 1.0
	
	return equipped_weapon.get_weapon_weight()


func get_weight_amplitude_factor(weapon_weight: float) -> float:
	var factor := 1.0 + maxf(weapon_weight - 1.0, 0.0) * weight_amplitude_multiplier
	return minf(factor, max_weight_amplitude_factor)


func get_weight_lag_factor(weapon_weight: float) -> float:
	var factor := 1.0 + maxf(weapon_weight - 1.0, 0.0) * weight_lag_multiplier
	return minf(factor, max_weight_lag_factor)


func get_recoil_weight_factor(weapon_weight: float) -> float:
	if recoil_weight_resistance <= 0.0:
		return 1.0
	
	var factor := 1.0 / (
		1.0
		+ maxf(weapon_weight - 1.0, 0.0) * recoil_weight_resistance
	)
	
	return maxf(factor, min_recoil_weight_factor)


func cache_parent_transform() -> void:
	var parent_node := get_parent() as Node3D
	
	if parent_node == null:
		return
	
	previous_parent_transform = parent_node.global_transform
	has_previous_parent_transform = true


func clamp_position(value: Vector3) -> Vector3:
	return clamp_vector3_by_vector(value, max_position_offset * -1.0, max_position_offset)


func clamp_rotation(value: Vector3) -> Vector3:
	var max_rotation := Vector3(
		deg_to_rad(max_rotation_degrees.x),
		deg_to_rad(max_rotation_degrees.y),
		deg_to_rad(max_rotation_degrees.z)
	)
	
	return clamp_vector3_by_vector(value, max_rotation * -1.0, max_rotation)


func clamp_vector3(value: Vector3, min_value: float, max_value: float) -> Vector3:
	return Vector3(
		clampf(value.x, min_value, max_value),
		clampf(value.y, min_value, max_value),
		clampf(value.z, min_value, max_value)
	)


func clamp_vector3_by_vector(value: Vector3, min_value: Vector3, max_value: Vector3) -> Vector3:
	return Vector3(
		clampf(value.x, min_value.x, max_value.x),
		clampf(value.y, min_value.y, max_value.y),
		clampf(value.z, min_value.z, max_value.z)
	)
