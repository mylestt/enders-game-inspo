class_name WeaponInventory
extends Node

signal weapon_equipped(weapon_id: StringName, weapon: Weapon)

const MINIGUN_ID: StringName = &"minigun"

@export var weapon_mount_path: NodePath = NodePath("../CameraRig/Camera3D/WeaponMount")
@export var minigun_scene: PackedScene = preload("res://scenes/minigun.tscn")

var owner_player: Node
var weapon_mount: Node3D
var weapon_spring_sway: WeaponSpringSway
var unlocked_weapon_ids: Dictionary = {}
var equipped_weapon_id: StringName = &""
var equipped_weapon: Weapon


func setup(new_owner: Node) -> void:
	owner_player = new_owner
	weapon_mount = get_node_or_null(weapon_mount_path) as Node3D
	
	if weapon_mount == null:
		push_error("WeaponInventory could not find WeaponMount at " + str(weapon_mount_path) + ".")
		return
	
	weapon_spring_sway = weapon_mount as WeaponSpringSway
	clear_mount()


func update_weapon_input(input_enabled: bool) -> void:
	if equipped_weapon == null:
		return
	
	if not input_enabled:
		equipped_weapon.set_trigger_held(false)
		return
	
	equipped_weapon.set_trigger_held(InputMap.has_action("weapon_fire") and Input.is_action_pressed("weapon_fire"))


func purchase_weapon(weapon_id: StringName) -> bool:
	if not can_purchase_weapon(weapon_id):
		return false
	
	unlocked_weapon_ids[weapon_id] = true
	
	if equip_weapon(weapon_id):
		return true
	
	unlocked_weapon_ids.erase(weapon_id)
	return false


func can_purchase_weapon(weapon_id: StringName) -> bool:
	if has_weapon(weapon_id):
		return false
	
	return get_weapon_scene(weapon_id) != null


func has_weapon(weapon_id: StringName) -> bool:
	return bool(unlocked_weapon_ids.get(weapon_id, false))


func equip_weapon(weapon_id: StringName) -> bool:
	if weapon_mount == null:
		return false
	
	if not has_weapon(weapon_id):
		return false
	
	if equipped_weapon_id == weapon_id and equipped_weapon != null:
		return true
	
	var scene := get_weapon_scene(weapon_id)
	
	if scene == null:
		return false
	
	clear_mount()
	
	var instance := scene.instantiate()
	weapon_mount.add_child(instance)
	
	equipped_weapon = instance as Weapon
	
	if equipped_weapon == null:
		push_error("Weapon scene for " + str(weapon_id) + " must inherit Weapon.")
		instance.queue_free()
		equipped_weapon_id = &""
		return false
	
	equipped_weapon.align_pivot_to_parent_origin()
	equipped_weapon_id = weapon_id
	equipped_weapon.equip(owner_player)
	connect_weapon_signals(equipped_weapon)
	
	if weapon_spring_sway != null:
		weapon_spring_sway.set_equipped_weapon(equipped_weapon)
		weapon_spring_sway.reset_sway()
	
	weapon_equipped.emit(equipped_weapon_id, equipped_weapon)
	return true


func clear_mount() -> void:
	if equipped_weapon != null:
		disconnect_weapon_signals(equipped_weapon)
		equipped_weapon.unequip()
	
	equipped_weapon = null
	equipped_weapon_id = &""
	
	if weapon_spring_sway != null:
		weapon_spring_sway.set_equipped_weapon(null)
	
	if weapon_mount == null:
		return
	
	for child in weapon_mount.get_children():
		child.queue_free()


func get_weapon_scene(weapon_id: StringName) -> PackedScene:
	match weapon_id:
		MINIGUN_ID:
			return minigun_scene
	
	return null


func connect_weapon_signals(weapon: Weapon) -> void:
	if weapon == null:
		return
	
	if not weapon.recoil_requested.is_connected(_on_weapon_recoil_requested):
		weapon.recoil_requested.connect(_on_weapon_recoil_requested)


func disconnect_weapon_signals(weapon: Weapon) -> void:
	if weapon == null:
		return
	
	if weapon.recoil_requested.is_connected(_on_weapon_recoil_requested):
		weapon.recoil_requested.disconnect(_on_weapon_recoil_requested)


func _on_weapon_recoil_requested(
	rotation_impulse_degrees: Vector3,
	position_impulse: Vector3
) -> void:
	if weapon_spring_sway == null:
		return
	
	weapon_spring_sway.apply_recoil(rotation_impulse_degrees, position_impulse)


func purchase_minigun() -> bool:
	return purchase_weapon(MINIGUN_ID)


func get_has_minigun() -> bool:
	return has_weapon(MINIGUN_ID)


func get_equipped_weapon_id() -> StringName:
	return equipped_weapon_id


func has_equipped_weapon() -> bool:
	return equipped_weapon != null


func get_weapon_aim_origin() -> Vector3:
	if equipped_weapon == null:
		return Vector3.ZERO
	
	return equipped_weapon.get_aim_origin()


func get_weapon_aim_direction() -> Vector3:
	if equipped_weapon == null:
		return Vector3.FORWARD
	
	return equipped_weapon.get_aim_direction()
