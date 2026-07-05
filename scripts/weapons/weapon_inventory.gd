class_name WeaponInventory
extends Node

signal weapon_equipped(weapon_id: StringName, weapon: Weapon)

const MINIGUN_ID: StringName = &"minigun"
const RAILGUN_ID: StringName = &"railgun"
const RIFLE_ID: StringName = &"rifle"
const PLASMA_CANNON_ID: StringName = &"plasma_cannon"
# Quick-swap slots: key 1 -> index 0, key 2 -> index 1, key 3 -> index 2, key 4 -> index 3.
const SLOT_IDS: Array[StringName] = [MINIGUN_ID, RAILGUN_ID, RIFLE_ID, PLASMA_CANNON_ID]

# The single weapon registry. Static so the server (which never equips weapons) can read the
# same scenes to build its validation stats — see ServerEconomy.get_weapon_stats.
const WEAPON_SCENES: Dictionary = {
	MINIGUN_ID: preload("res://scenes/minigun.tscn"),
	RAILGUN_ID: preload("res://scenes/railgun.tscn"),
	RIFLE_ID: preload("res://scenes/rifle.tscn"),
	PLASMA_CANNON_ID: preload("res://scenes/plasma_cannon.tscn"),
}

@export var weapon_mount_path: NodePath = NodePath("../CameraRig/Camera3D/WeaponMount")
@export var ads_blend_speed: float = 12.0

var owner_player: Node
var weapon_mount: Node3D
var weapon_spring_sway: WeaponSpringSway
var camera_node: Camera3D
var unlocked_weapon_ids: Dictionary = {}
var equipped_weapon_id: StringName = &""
var equipped_weapon: Weapon
var ads_blend: float = 0.0
# Ammo carried between swaps. Each equip() creates a fresh Weapon instance (and resets its
# ammo to full), so a weapon's mag/reserve is snapshotted here right before swapping away
# and restored right after swapping back in — otherwise switching weapons would silently
# refill every mag.
var ammo_by_weapon_id: Dictionary = {}


func setup(new_owner: Node) -> void:
	owner_player = new_owner
	weapon_mount = get_node_or_null(weapon_mount_path) as Node3D

	if weapon_mount == null:
		push_error("WeaponInventory could not find WeaponMount at " + str(weapon_mount_path) + ".")
		return

	weapon_spring_sway = weapon_mount as WeaponSpringSway
	camera_node = weapon_mount.get_parent() as Camera3D
	clear_mount()


# Full per-frame local update: fire / aim / ADS blend + FOV. Reload and swap are edge-driven
# from player._input. `input_enabled` is false while dead, in a menu, or buy menu is open.
func update(delta: float, input_enabled: bool) -> void:
	var can_act := input_enabled and not is_swapping()
	var aiming := false

	if equipped_weapon != null:
		equipped_weapon.set_trigger_held(can_act and _fire_pressed())
		aiming = can_act and _aim_pressed()
		equipped_weapon.set_aiming(aiming)

	var blend_speed := ads_blend_speed

	if aiming:
		blend_speed *= equipped_weapon.ads_in_speed_mult

	ads_blend = WeaponFeel.decay(ads_blend, 1.0 if aiming else 0.0, blend_speed, delta)

	if weapon_spring_sway != null:
		weapon_spring_sway.set_ads_blend(ads_blend)

	_update_ads_fov()


# Release-only path for one-shot state changes (death, menu open) that lack a delta.
func release() -> void:
	if equipped_weapon != null:
		equipped_weapon.set_trigger_held(false)
		equipped_weapon.set_aiming(false)


func request_reload() -> void:
	if equipped_weapon != null and not is_swapping():
		equipped_weapon.start_reload()


func try_quick_swap(slot: int) -> void:
	if slot < 0 or slot >= SLOT_IDS.size():
		return

	var weapon_id := SLOT_IDS[slot]

	if not has_weapon(weapon_id) or weapon_id == equipped_weapon_id:
		return

	if is_swapping():
		return

	equip_weapon(weapon_id)


func is_swapping() -> bool:
	return weapon_spring_sway != null and weapon_spring_sway.is_equipping()


func reset_state() -> void:
	ads_blend = 0.0
	# A respawn/round-reset refills every owned weapon, not just the held one, so drop any
	# stashed ammo from the life that just ended.
	ammo_by_weapon_id.clear()

	if weapon_spring_sway != null:
		weapon_spring_sway.set_ads_blend(0.0)
		weapon_spring_sway.reset_sway()

	if equipped_weapon != null:
		equipped_weapon.reset_ammo()

	if camera_node != null and camera_node.current:
		camera_node.fov = GameSettings.fov

	_refresh_ammo_hud()


func purchase_weapon(weapon_id: StringName) -> bool:
	if not can_purchase_weapon(weapon_id):
		return false

	unlocked_weapon_ids[weapon_id] = true

	if equip_weapon(weapon_id):
		return true

	unlocked_weapon_ids.erase(weapon_id)
	return false


# Refills every owned weapon's ammo without touching equips/ADS (the "ammo on kill" rule).
# Clearing the swap stash means any weapon swapped to next comes up full.
func refill_all_ammo() -> void:
	ammo_by_weapon_id.clear()

	if equipped_weapon != null:
		equipped_weapon.reset_ammo()

	_refresh_ammo_hud()


# FFA loadout: make `weapon_id` the ONLY owned weapon and equip it fresh. Wipes any prior
# unlock + stashed ammo so a new life can't quick-swap to last life's guns.
func set_exclusive_weapon(weapon_id: StringName) -> bool:
	if get_weapon_scene(weapon_id) == null:
		return false

	unlocked_weapon_ids.clear()
	ammo_by_weapon_id.clear()
	unlocked_weapon_ids[weapon_id] = true
	return equip_weapon(weapon_id)


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

	_save_equipped_ammo()
	clear_mount()

	var instance := scene.instantiate()
	weapon_mount.add_child(instance)

	equipped_weapon = instance as Weapon

	if equipped_weapon == null:
		push_error("Weapon scene for " + str(weapon_id) + " must inherit Weapon.")
		instance.queue_free()
		equipped_weapon_id = &""
		return false

	equipped_weapon_id = weapon_id
	equipped_weapon.inventory_id = weapon_id
	equipped_weapon.equip(owner_player)
	_restore_equipped_ammo(weapon_id)
	connect_weapon_signals(equipped_weapon)

	if weapon_spring_sway != null:
		weapon_spring_sway.set_equipped_weapon(equipped_weapon)
		weapon_spring_sway.reset_sway()
		weapon_spring_sway.play_equip_raise()

	_refresh_ammo_hud()
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

	if weapon_mount != null:
		for child in weapon_mount.get_children():
			child.queue_free()

	_refresh_ammo_hud()


func _save_equipped_ammo() -> void:
	if equipped_weapon == null or not equipped_weapon.uses_ammo():
		return

	ammo_by_weapon_id[equipped_weapon_id] = {
		"ammo": equipped_weapon.current_ammo,
		"reserve": equipped_weapon.current_reserve,
	}


func _restore_equipped_ammo(weapon_id: StringName) -> void:
	if equipped_weapon == null or not ammo_by_weapon_id.has(weapon_id):
		return

	var saved: Dictionary = ammo_by_weapon_id[weapon_id]
	equipped_weapon.current_ammo = int(saved.get("ammo", equipped_weapon.current_ammo))
	equipped_weapon.current_reserve = int(saved.get("reserve", equipped_weapon.current_reserve))
	equipped_weapon.ammo_changed.emit(equipped_weapon.current_ammo, equipped_weapon.current_reserve)


static func get_weapon_scene(weapon_id: StringName) -> PackedScene:
	return WEAPON_SCENES.get(weapon_id) as PackedScene


func connect_weapon_signals(weapon: Weapon) -> void:
	if weapon == null:
		return

	if not weapon.recoil_requested.is_connected(_on_weapon_recoil_requested):
		weapon.recoil_requested.connect(_on_weapon_recoil_requested)

	if not weapon.ammo_changed.is_connected(_on_weapon_ammo_changed):
		weapon.ammo_changed.connect(_on_weapon_ammo_changed)

	if not weapon.reload_started.is_connected(_on_weapon_reload_started):
		weapon.reload_started.connect(_on_weapon_reload_started)

	if not weapon.reload_finished.is_connected(_on_weapon_reload_finished):
		weapon.reload_finished.connect(_on_weapon_reload_finished)


func disconnect_weapon_signals(weapon: Weapon) -> void:
	if weapon == null:
		return

	if weapon.recoil_requested.is_connected(_on_weapon_recoil_requested):
		weapon.recoil_requested.disconnect(_on_weapon_recoil_requested)

	if weapon.ammo_changed.is_connected(_on_weapon_ammo_changed):
		weapon.ammo_changed.disconnect(_on_weapon_ammo_changed)

	if weapon.reload_started.is_connected(_on_weapon_reload_started):
		weapon.reload_started.disconnect(_on_weapon_reload_started)

	if weapon.reload_finished.is_connected(_on_weapon_reload_finished):
		weapon.reload_finished.disconnect(_on_weapon_reload_finished)


func _on_weapon_recoil_requested(
	rotation_impulse_degrees: Vector3,
	position_impulse: Vector3
) -> void:
	if weapon_spring_sway == null:
		return

	weapon_spring_sway.apply_recoil(rotation_impulse_degrees, position_impulse)


func _on_weapon_ammo_changed(_current_ammo: int, _reserve_ammo: int) -> void:
	_refresh_ammo_hud()


func _on_weapon_reload_started() -> void:
	if weapon_spring_sway != null:
		weapon_spring_sway.set_reloading(true)

	_refresh_ammo_hud()


func _on_weapon_reload_finished() -> void:
	if weapon_spring_sway != null:
		weapon_spring_sway.set_reloading(false)

	# The server mirrors reloads in its ammo ledger (ServerEconomy) to validate hit claims.
	if owner_player != null and owner_player.has_method("report_weapon_reloaded"):
		owner_player.call("report_weapon_reloaded", equipped_weapon_id)

	_refresh_ammo_hud()


func _update_ads_fov() -> void:
	if camera_node == null or not camera_node.current:
		return

	var base_fov := GameSettings.fov
	var zoom_fov := base_fov

	if equipped_weapon != null and equipped_weapon.ads_fov > 0.0:
		zoom_fov = equipped_weapon.ads_fov

	camera_node.fov = lerpf(base_fov, zoom_fov, ads_blend)


func _refresh_ammo_hud() -> void:
	if owner_player == null or not owner_player.has_method("update_weapon_ammo_hud"):
		return

	if equipped_weapon == null or not equipped_weapon.uses_ammo():
		owner_player.call("update_weapon_ammo_hud", -1, -1, false)
		return

	owner_player.call(
		"update_weapon_ammo_hud",
		equipped_weapon.current_ammo,
		equipped_weapon.current_reserve,
		equipped_weapon.reloading
	)


func _fire_pressed() -> bool:
	return InputMap.has_action("weapon_fire") and Input.is_action_pressed("weapon_fire")


func _aim_pressed() -> bool:
	return InputMap.has_action("aim") and Input.is_action_pressed("aim")


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
