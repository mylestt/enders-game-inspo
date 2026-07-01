class_name Weapon
extends Node3D

signal firing_state_changed(is_firing: bool)
signal recoil_requested(rotation_impulse_degrees: Vector3, position_impulse: Vector3)
signal ammo_changed(current_ammo: int, reserve_ammo: int)
signal reload_started()
signal reload_finished()
signal ads_changed(aiming: bool)

@export var weapon_weight: float = 1.0
@export var aim_origin_node_path: NodePath
@export var aim_local_direction: Vector3 = Vector3.FORWARD

@export_group("Recoil")
@export var recoil_enabled: bool = true
@export var recoil_rotation_degrees: Vector3 = Vector3.ZERO
@export var recoil_position_offset: Vector3 = Vector3.ZERO
@export var recoil_random_rotation_degrees: Vector3 = Vector3.ZERO
@export var recoil_random_position_offset: Vector3 = Vector3.ZERO
# Persistent camera recoil (you pull down to counter), degrees per shot. Applies in all states.
@export var recoil_kick_up: float = 0.0
@export var recoil_kick_side: float = 0.0        # random +/- horizontal wander
# Viewmodel offset held while firing (e.g. minigun kicks back and stays back). Eased in/out.
@export var sustained_kickback: Vector3 = Vector3.ZERO

@export_group("Hitscan")
@export var hitscan_range: float = 260.0
@export var hitscan_damage: float = 15.0
@export var hitscan_collision_mask: int = 0xffffffff
@export var hitscan_collide_with_bodies: bool = true
@export var hitscan_collide_with_areas: bool = true
@export var hitscan_spread_degrees: Vector2 = Vector2.ZERO
@export var hitscan_tracer_scene: PackedScene
@export var hitscan_effect_parent_path: NodePath

@export_group("Body Recoil")
@export var fire_knockback_enabled: bool = true
# Per-round backward impulse pushing the owner opposite the barrel. Only applied
# while free-floating; high fire-rate weapons apply it many times per second.
@export var fire_knockback_force: float = 0.0
# Per-round spin imparted to the owner around its center of mass, as if the
# off-center barrel torqued the body. Only applied while free-floating.
@export var fire_torque_strength: float = 0.0
# Hard cap (rad/s) on how fast recoil alone can spin the owner. Recoil never spins
# the body past this, but won't fight a faster spin the player created themselves.
@export var max_recoil_angular_speed: float = 4.0

@export_group("Ammo")
# 0 = no ammo system (infinite, never reloads). >0 enables mags + reload.
@export var mag_size: int = 0
@export var starting_reserve: int = 0
@export var reload_time: float = 2.0

@export_group("ADS")
# 0 = no FOV zoom. >0 = camera FOV while aiming (the rig lerps to it).
@export var ads_fov: float = 0.0
@export var ads_spread_mult: float = 0.35
@export var ads_recoil_mult: float = 0.5
# Extra local offset the viewmodel takes while aiming, on top of sight centring.
@export var ads_position_offset: Vector3 = Vector3.ZERO

var owner_player: Node
var equipped: bool = false
var trigger_held: bool = false
var firing: bool = false
var is_ads: bool = false

var current_ammo: int = 0
var current_reserve: int = 0
var reloading: bool = false
var reload_timer: float = 0.0


func equip(new_owner: Node) -> void:
	owner_player = new_owner
	equipped = true
	visible = true
	set_trigger_held(false)
	set_aiming(false)
	reset_ammo()


func unequip() -> void:
	equipped = false
	visible = false
	set_trigger_held(false)
	set_firing(false)
	set_aiming(false)


func set_trigger_held(value: bool) -> void:
	trigger_held = value and equipped


func is_trigger_held() -> bool:
	return trigger_held


func is_firing() -> bool:
	return firing


func get_weapon_weight() -> float:
	return maxf(weapon_weight, 0.01)


func get_aim_origin() -> Vector3:
	if String(aim_origin_node_path) != "":
		var aim_origin_node := get_node_or_null(aim_origin_node_path) as Node3D

		if aim_origin_node != null:
			return aim_origin_node.global_position

	return global_position


func get_aim_direction() -> Vector3:
	var local_direction := aim_local_direction

	if local_direction.length() < 0.001:
		local_direction = Vector3.FORWARD

	return (global_transform.basis * local_direction.normalized()).normalized()


# ----- Ammo / reload -----

func uses_ammo() -> bool:
	return mag_size > 0


func reset_ammo() -> void:
	if not uses_ammo():
		return

	current_ammo = mag_size
	current_reserve = starting_reserve
	reloading = false
	reload_timer = 0.0
	ammo_changed.emit(current_ammo, current_reserve)


func can_fire() -> bool:
	if not uses_ammo():
		return true

	return not reloading and current_ammo > 0


func consume_round() -> void:
	if not uses_ammo():
		return

	current_ammo = maxi(current_ammo - 1, 0)
	ammo_changed.emit(current_ammo, current_reserve)


func start_reload() -> bool:
	if not uses_ammo() or reloading:
		return false

	if current_ammo >= mag_size or current_reserve <= 0:
		return false

	reloading = true
	reload_timer = reload_time
	reload_started.emit()
	return true


# Ticks the reload timer; subclasses call this once per physics frame.
func advance(delta: float) -> void:
	if not reloading:
		return

	reload_timer -= delta

	if reload_timer > 0.0:
		return

	var needed := mag_size - current_ammo
	var taken := mini(needed, current_reserve)
	current_ammo += taken
	current_reserve -= taken
	reloading = false
	reload_finished.emit()
	ammo_changed.emit(current_ammo, current_reserve)


# ----- ADS -----

func set_aiming(value: bool) -> void:
	value = value and equipped

	if is_ads == value:
		return

	is_ads = value
	ads_changed.emit(is_ads)


func get_ads_spread_mult() -> float:
	return ads_spread_mult if is_ads else 1.0


func get_ads_recoil_mult() -> float:
	return ads_recoil_mult if is_ads else 1.0


# ----- Recoil -----

func request_recoil(multiplier: float = 1.0) -> void:
	if not equipped or not recoil_enabled:
		return

	var clamped_multiplier := maxf(multiplier, 0.0) * get_ads_recoil_mult()

	if clamped_multiplier <= 0.0:
		return

	recoil_requested.emit(
		get_recoil_rotation_impulse(clamped_multiplier),
		get_recoil_position_impulse(clamped_multiplier)
	)


# A fired round's recoil, in three independent channels every gun shares: viewmodel spring kick
# (cosmetic), a persistent camera climb you pull down against (all states), and — only while
# free-floating — a body shove straight back along the barrel, so where you aim is where you're
# pushed in 0g.
func apply_fire_recoil(multiplier: float = 1.0) -> void:
	var m := maxf(multiplier, 0.0)
	request_recoil(m)
	apply_camera_kick(m)

	if not is_owner_braced():
		apply_body_push(m)


# Persistent aim climb (+ side wander), fed into the look so the player corrects it with the mouse.
func apply_camera_kick(multiplier: float) -> void:
	if owner_player == null or not owner_player.has_method("apply_camera_recoil"):
		return

	var scale := multiplier * get_ads_recoil_mult()
	var up := recoil_kick_up * scale
	var side := randf_range(-recoil_kick_side, recoil_kick_side) * scale

	if up != 0.0 or side != 0.0:
		owner_player.call("apply_camera_recoil", up, side)


# Free-float reaction: a central impulse opposite the barrel (follows the aim). Optional off-centre
# tumble via fire_torque_strength, but that spins a fixed body-space direction, so default it to 0.
func apply_body_push(multiplier: float) -> void:
	if not fire_knockback_enabled or fire_knockback_force <= 0.0:
		return

	var rigid := owner_player as RigidBody3D

	if rigid == null:
		return

	var barrel := get_aim_direction()

	if barrel.length() < 0.001:
		return

	var reaction := -barrel.normalized() * fire_knockback_force * multiplier
	rigid.sleeping = false
	rigid.apply_central_impulse(reaction)

	if fire_torque_strength <= 0.0:
		return

	var spin_before := rigid.angular_velocity.length()
	rigid.apply_torque_impulse((get_aim_origin() - rigid.global_position).cross(reaction) * fire_torque_strength)
	var cap := maxf(max_recoil_angular_speed, spin_before)

	if rigid.angular_velocity.length() > cap:
		rigid.angular_velocity = rigid.angular_velocity.normalized() * cap


func is_owner_braced() -> bool:
	if owner_player != null and owner_player.has_method("is_recoil_braced"):
		return bool(owner_player.call("is_recoil_braced"))

	return false


func fire_hitscan() -> Dictionary:
	var origin := get_aim_origin()
	var direction := get_aim_direction()

	if direction.length() < 0.001:
		return {}

	direction = get_hitscan_shot_direction(direction.normalized())
	var trace_end := origin + direction * hitscan_range
	var query := PhysicsRayQueryParameters3D.create(origin, trace_end)
	query.collision_mask = hitscan_collision_mask
	query.collide_with_bodies = hitscan_collide_with_bodies
	query.collide_with_areas = hitscan_collide_with_areas
	query.exclude = get_owner_collision_exclusions()

	var hit_result := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_position := trace_end
	var hit_normal := Vector3.ZERO
	var hit_collider: Object = null
	var hit_something := false

	if not hit_result.is_empty():
		hit_something = true
		hit_position = hit_result["position"]
		hit_normal = hit_result.get("normal", Vector3.ZERO)
		hit_collider = hit_result.get("collider")
		submit_hitscan_damage(hit_collider, hit_position, origin, direction)

	spawn_hitscan_tracer(origin, hit_position, hit_something, hit_normal)

	if owner_player != null and owner_player.has_method("report_weapon_shot"):
		owner_player.call("report_weapon_shot", origin, hit_position, hit_something, hit_normal)

	return {
		"origin": origin,
		"end": hit_position,
		"direction": direction,
		"hit": hit_something,
		"normal": hit_normal,
		"collider": hit_collider
	}


func submit_hitscan_damage(
	hit_collider: Object,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> void:
	if owner_player == null:
		return

	var target := find_damage_target(hit_collider)

	if target == null or target == owner_player:
		return

	if owner_player.has_method("submit_weapon_hit"):
		owner_player.call(
			"submit_weapon_hit",
			target,
			hitscan_damage,
			hit_position,
			shot_origin,
			shot_direction
		)


func find_damage_target(collider: Object) -> Node:
	var current = collider

	while current != null:
		if current is Node and current.has_method("apply_weapon_damage"):
			return current

		if current is Node and current.has_method("get_peer_id"):
			return current

		if current is Node:
			current = current.get_parent()
		else:
			break

	return null


func get_hitscan_shot_direction(base_direction: Vector3) -> Vector3:
	var spread := hitscan_spread_degrees * get_ads_spread_mult()

	if spread.length() <= 0.001:
		return base_direction

	var up := Vector3.UP

	if absf(base_direction.dot(up)) > 0.98:
		up = Vector3.RIGHT

	var right := up.cross(base_direction).normalized()
	var corrected_up := base_direction.cross(right).normalized()
	var horizontal_angle := deg_to_rad(
		randf_range(-absf(spread.x), absf(spread.x))
	)
	var vertical_angle := deg_to_rad(
		randf_range(-absf(spread.y), absf(spread.y))
	)
	var spread_direction := (
		base_direction
		+ right * tan(horizontal_angle)
		+ corrected_up * tan(vertical_angle)
	)

	return spread_direction.normalized()


func spawn_hitscan_tracer(
	start_position: Vector3,
	end_position: Vector3,
	hit_something: bool,
	hit_normal: Vector3
) -> Node:
	if hitscan_tracer_scene == null:
		return null

	var tracer := hitscan_tracer_scene.instantiate()
	var effect_parent := get_hitscan_effect_parent()

	if effect_parent == null:
		tracer.queue_free()
		return null

	effect_parent.add_child(tracer)

	if tracer.has_method("play"):
		tracer.call("play", start_position, end_position, hit_something, hit_normal)
	elif tracer is Node3D:
		var tracer_node := tracer as Node3D
		tracer_node.global_position = start_position

	return tracer


func get_hitscan_effect_parent() -> Node:
	if String(hitscan_effect_parent_path) != "":
		var explicit_parent := get_node_or_null(hitscan_effect_parent_path)

		if explicit_parent != null:
			return explicit_parent

	var scene := get_tree().current_scene

	if scene == null:
		return get_tree().root

	var existing_parent := scene.get_node_or_null("WeaponEffects")

	if existing_parent != null:
		return existing_parent

	var created_parent := Node3D.new()
	created_parent.name = "WeaponEffects"
	scene.add_child(created_parent)
	return created_parent


func get_owner_collision_exclusions() -> Array:
	var exclusions: Array = []
	add_collision_exclusions_from_node(owner_player, exclusions)
	return exclusions


func add_collision_exclusions_from_node(node: Node, exclusions: Array) -> void:
	if node == null:
		return

	if node is CollisionObject3D:
		exclusions.append(node.get_rid())

	for child in node.get_children():
		add_collision_exclusions_from_node(child, exclusions)


func get_recoil_rotation_impulse(multiplier: float = 1.0) -> Vector3:
	return (
		recoil_rotation_degrees
		+ get_random_recoil_vector(recoil_random_rotation_degrees)
	) * multiplier


func get_recoil_position_impulse(multiplier: float = 1.0) -> Vector3:
	return (
		recoil_position_offset
		+ get_random_recoil_vector(recoil_random_position_offset)
	) * multiplier


func get_random_recoil_vector(extents: Vector3) -> Vector3:
	return Vector3(
		randf_range(-absf(extents.x), absf(extents.x)),
		randf_range(-absf(extents.y), absf(extents.y)),
		randf_range(-absf(extents.z), absf(extents.z))
	)


func set_firing(value: bool) -> void:
	if firing == value:
		return

	firing = value
	firing_state_changed.emit(firing)
