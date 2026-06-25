class_name Weapon
extends Node3D

signal firing_state_changed(is_firing: bool)
signal recoil_requested(rotation_impulse_degrees: Vector3, position_impulse: Vector3)

@export var weapon_weight: float = 1.0
@export var pivot_node_path: NodePath
@export var aim_origin_node_path: NodePath
@export var aim_local_direction: Vector3 = Vector3.FORWARD

@export_group("Recoil")
@export var recoil_enabled: bool = true
@export var recoil_rotation_degrees: Vector3 = Vector3.ZERO
@export var recoil_position_offset: Vector3 = Vector3.ZERO
@export var recoil_random_rotation_degrees: Vector3 = Vector3.ZERO
@export var recoil_random_position_offset: Vector3 = Vector3.ZERO

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

var owner_player: Node
var equipped: bool = false
var trigger_held: bool = false
var firing: bool = false


func equip(new_owner: Node) -> void:
	owner_player = new_owner
	equipped = true
	visible = true
	set_trigger_held(false)


func unequip() -> void:
	equipped = false
	visible = false
	set_trigger_held(false)
	set_firing(false)


func set_trigger_held(value: bool) -> void:
	trigger_held = value and equipped


func is_trigger_held() -> bool:
	return trigger_held


func is_firing() -> bool:
	return firing


func get_weapon_weight() -> float:
	return maxf(weapon_weight, 0.01)


func align_pivot_to_parent_origin() -> void:
	if String(pivot_node_path) == "":
		return
	
	var pivot_node := get_node_or_null(pivot_node_path) as Node3D
	var parent_node := get_parent() as Node3D
	
	if pivot_node == null or parent_node == null:
		return
	
	global_position += parent_node.global_position - pivot_node.global_position


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


func request_recoil(multiplier: float = 1.0) -> void:
	if not equipped or not recoil_enabled:
		return
	
	var clamped_multiplier := maxf(multiplier, 0.0)
	
	if clamped_multiplier <= 0.0:
		return
	
	recoil_requested.emit(
		get_recoil_rotation_impulse(clamped_multiplier),
		get_recoil_position_impulse(clamped_multiplier)
	)


# Routes a fired round's recoil. A braced shooter (standing on a surface or gripping
# a wall) gets a normal FPS weapon kick. A free-floating shooter takes the recoil into
# their own body instead — a backward shove plus a spin — while the weapon keeps swaying.
func apply_fire_recoil(multiplier: float = 1.0) -> void:
	if is_owner_braced():
		request_recoil(multiplier)
	else:
		apply_fire_knockback(multiplier)
		apply_fire_torque(multiplier)


# Shoves the owner backwards (opposite the aim/barrel direction) like reaction thrust.
func apply_fire_knockback(multiplier: float = 1.0) -> void:
	if not fire_knockback_enabled or fire_knockback_force <= 0.0:
		return

	var knockback_multiplier := maxf(multiplier, 0.0)

	if knockback_multiplier <= 0.0:
		return

	var rigid_owner := owner_player as RigidBody3D

	if rigid_owner == null:
		return

	var aim_direction := get_aim_direction()

	if aim_direction.length() < 0.001:
		return

	rigid_owner.sleeping = false
	rigid_owner.apply_central_impulse(
		-aim_direction.normalized() * fire_knockback_force * knockback_multiplier
	)


# Spins the owner around its center of mass, as if the off-center barrel torqued the
# body. The spin axis comes from the muzzle's offset off the center-of-mass line, so
# where the gun sits decides which way you tumble. Capped at max_recoil_angular_speed
# so sustained fire can't spin you up uncontrollably.
func apply_fire_torque(multiplier: float = 1.0) -> void:
	if fire_torque_strength <= 0.0:
		return

	var torque_multiplier := maxf(multiplier, 0.0)

	if torque_multiplier <= 0.0:
		return

	var rigid_owner := owner_player as RigidBody3D

	if rigid_owner == null:
		return

	var aim_direction := get_aim_direction()

	if aim_direction.length() < 0.001:
		return

	var muzzle_offset := get_aim_origin() - rigid_owner.global_position
	var spin_axis := muzzle_offset.cross(-aim_direction.normalized())

	if spin_axis.length() < 0.00001:
		return

	var added_angular := spin_axis * fire_torque_strength * torque_multiplier
	var current_angular := rigid_owner.angular_velocity
	var proposed_angular := current_angular + added_angular

	# Cap recoil-driven spin, but never below a faster spin the player made themselves.
	var cap := maxf(max_recoil_angular_speed, current_angular.length())

	if proposed_angular.length() > cap:
		proposed_angular = proposed_angular.normalized() * cap

	rigid_owner.sleeping = false
	rigid_owner.angular_velocity = proposed_angular


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
	if hitscan_spread_degrees.length() <= 0.001:
		return base_direction
	
	var up := Vector3.UP
	
	if absf(base_direction.dot(up)) > 0.98:
		up = Vector3.RIGHT
	
	var right := up.cross(base_direction).normalized()
	var corrected_up := base_direction.cross(right).normalized()
	var horizontal_angle := deg_to_rad(
		randf_range(-absf(hitscan_spread_degrees.x), absf(hitscan_spread_degrees.x))
	)
	var vertical_angle := deg_to_rad(
		randf_range(-absf(hitscan_spread_degrees.y), absf(hitscan_spread_degrees.y))
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
