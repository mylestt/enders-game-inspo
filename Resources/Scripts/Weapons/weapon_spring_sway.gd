class_name WeaponSpringSway
extends Node3D

# Viewmodel animator on the WeaponMount (a child of Camera3D). It reads the camera's motion
# from parent-transform deltas — no player contract needed, so it is zero-G / 6DOF safe — and
# composes, each frame: sway (weapon lags the camera), a dedicated visual-recoil spring, idle
# breathing, ADS sight-centring (on the weapon child), and equip/reload poses (on the mount).
# Bob/landing are inherited for free from CameraRig, which already bobs the parent camera.

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

@export_group("Visual Recoil")
# The dedicated recoil spring (snappier recovery than the sway spring).
@export var visual_recoil_stiffness: float = 95.0
@export var visual_recoil_damping: float = 24.0
# How fast the viewmodel eases to/from the weapon's sustained_kickback hold while firing.
@export var sustained_kickback_speed: float = 8.0

@export_group("Idle")
@export var idle_amplitude: Vector3 = Vector3(0.0012, 0.0016, 0.0)
@export var idle_frequency: Vector2 = Vector2(1.3, 1.7)

@export_group("Equip")
@export var equip_lowered_position: Vector3 = Vector3(0.0, -0.32, 0.12)
@export var equip_lowered_pitch_degrees: float = 42.0
@export var equip_raise_speed: float = 9.0

@export_group("Reload Pose")
@export var reload_lowered_position: Vector3 = Vector3(0.0, -0.12, 0.02)
@export var reload_tilt_degrees: float = 14.0
@export var reload_pose_speed: float = 10.0

@export_group("ADS")
@export var ads_sway_reduction: float = 0.7

var equipped_weapon: Weapon
var rest_position: Vector3
var rest_rotation: Vector3
var position_offset: Vector3 = Vector3.ZERO
var position_velocity: Vector3 = Vector3.ZERO
var rotation_offset: Vector3 = Vector3.ZERO
var rotation_velocity: Vector3 = Vector3.ZERO
var previous_parent_transform: Transform3D
var has_previous_parent_transform: bool = false

var _recoil_pos_offset: Vector3 = Vector3.ZERO
var _recoil_pos_velocity: Vector3 = Vector3.ZERO
var _recoil_rot_offset: Vector3 = Vector3.ZERO
var _recoil_rot_velocity: Vector3 = Vector3.ZERO
var _fire_hold: Vector3 = Vector3.ZERO

var _idle_time: float = 0.0
var _idle_offset: Vector3 = Vector3.ZERO

var _equip_blend: float = 0.0
var _equip_pos_offset: Vector3 = Vector3.ZERO
var _equip_rot_offset: Vector3 = Vector3.ZERO

var _reload_blend: float = 0.0
var _reload_target: float = 0.0
var _reload_pos_offset: Vector3 = Vector3.ZERO
var _reload_rot_offset: Vector3 = Vector3.ZERO

var _ads_blend: float = 0.0
var _equipped: Node3D
var _sight: Node3D
var _weapon_rest_pos: Vector3 = Vector3.ZERO
var _weapon_rest_basis: Basis = Basis.IDENTITY
var _ads_target_pos: Vector3 = Vector3.ZERO
var _ads_target_dirty: bool = true


func _ready() -> void:
	process_priority = -50
	# Animated per render frame in _process — opt out of physics interpolation, or the 60 Hz
	# tick snapshots override the writes and the viewmodel judders on >60 Hz displays.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	rest_position = position
	rest_rotation = rotation
	cache_parent_transform()


func _process(delta: float) -> void:
	if delta <= 0.0:
		return

	var parent_node := get_parent() as Node3D

	if parent_node == null:
		return

	if has_previous_parent_transform:
		var parent_transform := parent_node.global_transform
		var look_velocity := get_local_look_velocity(parent_transform, delta)
		var move_velocity := get_local_move_velocity(parent_transform, delta)
		var weapon_weight := get_equipped_weapon_weight()
		var amplitude_factor := get_weight_amplitude_factor(weapon_weight)
		var lag_factor := get_weight_lag_factor(weapon_weight)
		var target_rotation := get_target_rotation(look_velocity, amplitude_factor)
		var target_position := get_target_position(look_velocity, move_velocity, amplitude_factor)
		update_spring(delta, target_rotation, target_position, lag_factor)
		previous_parent_transform = parent_transform
	else:
		cache_parent_transform()

	update_recoil_spring(delta)
	update_idle(delta)
	update_pose_blends(delta)
	update_fire_hold(delta)

	# Sway + idle shrink while aiming; recoil and equip/reload poses stay full.
	var proc := 1.0 - _ads_blend * ads_sway_reduction
	position = (
		rest_position
		+ (position_offset + _idle_offset) * proc
		+ _recoil_pos_offset + _fire_hold + _equip_pos_offset + _reload_pos_offset
	)
	rotation = (
		rest_rotation
		+ rotation_offset * proc
		+ _recoil_rot_offset + _equip_rot_offset + _reload_rot_offset
	)

	if _equipped != null and is_instance_valid(_equipped):
		_ensure_ads_target()
		_equipped.position = _weapon_rest_pos.lerp(_ads_target_pos, _ads_blend)


func set_equipped_weapon(new_weapon: Weapon) -> void:
	equipped_weapon = new_weapon
	_equipped = new_weapon

	if _equipped != null:
		_weapon_rest_pos = _equipped.position
		_weapon_rest_basis = _equipped.transform.basis
		_sight = _find_sight(_equipped)
		_ads_target_dirty = true

	if equipped_weapon == null and reset_when_no_weapon:
		reset_sway()


func set_ads_blend(value: float) -> void:
	_ads_blend = clampf(value, 0.0, 1.0)


func set_reloading(active: bool) -> void:
	_reload_target = 1.0 if active else 0.0


func play_equip_raise() -> void:
	_equip_blend = 1.0


func is_equipping() -> bool:
	return _equip_blend > 0.05


func reset_sway() -> void:
	position_offset = Vector3.ZERO
	position_velocity = Vector3.ZERO
	rotation_offset = Vector3.ZERO
	rotation_velocity = Vector3.ZERO
	_recoil_pos_offset = Vector3.ZERO
	_recoil_pos_velocity = Vector3.ZERO
	_recoil_rot_offset = Vector3.ZERO
	_recoil_rot_velocity = Vector3.ZERO
	_fire_hold = Vector3.ZERO
	_reload_blend = 0.0
	_reload_target = 0.0
	_ads_blend = 0.0
	position = rest_position
	rotation = rest_rotation
	cache_parent_transform()


func apply_recoil(rotation_degrees: Vector3, position_kick: Vector3) -> void:
	var weight := get_recoil_weight_factor(get_equipped_weapon_weight())

	_recoil_rot_velocity += Vector3(
		deg_to_rad(rotation_degrees.x),
		deg_to_rad(rotation_degrees.y),
		deg_to_rad(rotation_degrees.z)
	) * recoil_rotation_velocity_scale * weight
	_recoil_pos_velocity += position_kick * recoil_position_velocity_scale * weight


func update_recoil_spring(delta: float) -> void:
	_recoil_rot_velocity = WeaponFeel.spring_velocity(
		_recoil_rot_offset, _recoil_rot_velocity, Vector3.ZERO,
		visual_recoil_stiffness, visual_recoil_damping, delta
	)
	_recoil_rot_offset = clamp_rotation(_recoil_rot_offset + _recoil_rot_velocity * delta)

	_recoil_pos_velocity = WeaponFeel.spring_velocity(
		_recoil_pos_offset, _recoil_pos_velocity, Vector3.ZERO,
		visual_recoil_stiffness, visual_recoil_damping, delta
	)
	_recoil_pos_offset = clamp_position(_recoil_pos_offset + _recoil_pos_velocity * delta)


func update_idle(delta: float) -> void:
	_idle_time += delta
	_idle_offset = Vector3(
		sin(_idle_time * idle_frequency.x) * idle_amplitude.x,
		sin(_idle_time * idle_frequency.y) * idle_amplitude.y,
		0.0
	)


func update_fire_hold(delta: float) -> void:
	var target := Vector3.ZERO

	if equipped_weapon != null and equipped_weapon.is_firing():
		target = equipped_weapon.sustained_kickback

	_fire_hold = WeaponFeel.decay_vec3(_fire_hold, target, sustained_kickback_speed, delta)


func update_pose_blends(delta: float) -> void:
	_equip_blend = WeaponFeel.decay(_equip_blend, 0.0, equip_raise_speed, delta)
	_reload_blend = WeaponFeel.decay(_reload_blend, _reload_target, reload_pose_speed, delta)

	_equip_pos_offset = equip_lowered_position * _equip_blend
	_equip_rot_offset = Vector3(deg_to_rad(equip_lowered_pitch_degrees), 0.0, 0.0) * _equip_blend
	_reload_pos_offset = reload_lowered_position * _reload_blend
	_reload_rot_offset = Vector3(deg_to_rad(reload_tilt_degrees), 0.0, 0.0) * _reload_blend


func _find_sight(root: Node) -> Node3D:
	var found := _find_named(root, "Sight")

	if found == null:
		found = _find_named(root, "ADSmarker")

	return found


func _find_named(node: Node, target_name: String) -> Node3D:
	for child in node.get_children():
		if child is Node3D and String(child.name) == target_name:
			return child as Node3D

		var nested := _find_named(child, target_name)

		if nested != null:
			return nested

	return null


# Where the weapon child must sit so its sight lands on the camera's forward axis. Computed
# once per equip from rest transforms (recomputed if the weapon changes). ads_position_offset
# on the weapon is an additive fine-tune.
func _ensure_ads_target() -> void:
	if not _ads_target_dirty:
		return

	_ads_target_dirty = false

	var extra := Vector3.ZERO

	if equipped_weapon != null:
		extra = equipped_weapon.ads_position_offset

	if _sight == null or not is_instance_valid(_sight):
		_ads_target_pos = _weapon_rest_pos + extra
		return

	var sight_in_weapon := _equipped.global_transform.affine_inverse() * _sight.global_position
	var sight_in_mount := _weapon_rest_pos + _weapon_rest_basis * sight_in_weapon
	var correction := Vector3(
		-(sight_in_mount.x + rest_position.x),
		-(sight_in_mount.y + rest_position.y),
		0.0
	)
	_ads_target_pos = _weapon_rest_pos + correction + extra


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
