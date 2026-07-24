class_name FlakShotgunWeapon
extends Weapon

@export_group("Flak Pellets (Primary / Ricochet)")
@export var flak_projectile_scene: PackedScene
@export_range(1, 40, 1) var flak_pellet_count: int = 10
@export_range(1.0, 150.0, 0.5, "or_greater") var flak_pellet_speed: float = 38.0
@export_range(0.0, 200.0, 0.5, "or_greater") var flak_base_damage: float = 4.0
@export_range(1.0, 5.0, 0.01, "or_greater") var flak_ricochet_damage_multiplier: float = 1.6
@export_range(1.0, 3.0, 0.01, "or_greater") var flak_ricochet_speed_multiplier: float = 1.25
@export_range(1.0, 300.0, 1.0, "or_greater") var flak_max_speed: float = 140.0
@export_range(0, 20, 1) var flak_max_multiplying_ricochets: int = 5
@export_range(0.1, 20.0, 0.1, "or_greater") var flak_lifetime: float = 4.0
@export_range(0.1, 10.0, 0.05, "or_greater") var flak_rounds_per_second: float = 0.9
@export var flak_semi_auto: bool = true

@export_group("Frag Pellets (Secondary / Mini-Explosions)")
@export var frag_projectile_scene: PackedScene
@export_range(1, 40, 1) var frag_pellet_count: int = 8
@export_range(1.0, 150.0, 0.5, "or_greater") var frag_pellet_speed: float = 42.0
@export_range(0.1, 10.0, 0.05, "or_greater") var frag_rounds_per_second: float = 0.9
@export var frag_semi_auto: bool = true

var primary_cooldown: float = 0.0
var secondary_cooldown: float = 0.0
var primary_trigger_was_held: bool = false
var secondary_trigger_was_held: bool = false


func _physics_process(delta: float) -> void:
	advance(delta)
	primary_cooldown = maxf(primary_cooldown - delta, 0.0)
	secondary_cooldown = maxf(secondary_cooldown - delta, 0.0)

	var secondary_want := is_ads and secondary_cooldown <= 0.0 and not reloading
	var primary_want := (
		trigger_held and not is_ads and primary_cooldown <= 0.0 and not reloading
	)

	if flak_semi_auto and primary_trigger_was_held:
		primary_want = false

	if frag_semi_auto and secondary_trigger_was_held:
		secondary_want = false

	if secondary_want:
		fire_frag_blast()
	elif primary_want:
		fire_flak_blast()

	primary_trigger_was_held = trigger_held and not is_ads
	secondary_trigger_was_held = is_ads
	set_firing((trigger_held or is_ads) and not reloading)


func fire_flak_blast() -> void:
	if not can_fire():
		primary_cooldown = 0.0

		if uses_ammo() and current_ammo <= 0:
			start_reload()

		return

	if flak_projectile_scene == null:
		push_error("FlakShotgunWeapon has no flak_projectile_scene assigned.")
		return

	for i in range(maxi(flak_pellet_count, 1)):
		_spawn_flak_pellet()

	consume_round()
	apply_fire_recoil()
	trigger_muzzle_flash()
	primary_cooldown = 1.0 / maxf(flak_rounds_per_second, 0.001)


func fire_frag_blast() -> void:
	if not can_fire():
		secondary_cooldown = 0.0

		if uses_ammo() and current_ammo <= 0:
			start_reload()

		return

	if frag_projectile_scene == null:
		push_error("FlakShotgunWeapon has no frag_projectile_scene assigned.")
		return

	for i in range(maxi(frag_pellet_count, 1)):
		_spawn_frag_pellet()

	consume_round()
	apply_fire_recoil()
	trigger_muzzle_flash()
	secondary_cooldown = 1.0 / maxf(frag_rounds_per_second, 0.001)


func _spawn_flak_pellet() -> void:
	var launch := _compute_pellet_launch()

	if launch.is_empty():
		return

	var instance := flak_projectile_scene.instantiate()
	var pellet := instance as FlakProjectile

	if pellet == null:
		push_error("FlakShotgunWeapon flak_projectile_scene root must be a FlakProjectile.")
		instance.free()
		return

	pellet.owner_player = owner_player
	pellet.can_deal_damage = true
	pellet.base_damage = flak_base_damage * get_owner_damage_multiplier()
	pellet.ricochet_damage_multiplier = flak_ricochet_damage_multiplier
	pellet.ricochet_speed_multiplier = flak_ricochet_speed_multiplier
	pellet.max_speed = flak_max_speed
	pellet.max_multiplying_ricochets = flak_max_multiplying_ricochets
	pellet.lifetime = flak_lifetime

	if inventory_id != &"":
		pellet.source_weapon_id = String(inventory_id)

	var parent := get_hitscan_effect_parent()

	if parent == null:
		pellet.free()
		return

	parent.add_child(pellet)
	pellet.launch(launch["origin"], launch["direction"], flak_pellet_speed, owner_player)


func _spawn_frag_pellet() -> void:
	var launch := _compute_pellet_launch()

	if launch.is_empty():
		return

	var instance := frag_projectile_scene.instantiate()
	var bolt := instance as PlasmaProjectile

	if bolt == null:
		push_error("FlakShotgunWeapon frag_projectile_scene root must be a PlasmaProjectile.")
		instance.free()
		return

	bolt.owner_player = owner_player
	bolt.can_deal_damage = true

	if inventory_id != &"":
		bolt.source_weapon_id = String(inventory_id)

	var parent := get_hitscan_effect_parent()

	if parent == null:
		bolt.free()
		return

	parent.add_child(bolt)
	bolt.launch(launch["origin"], launch["direction"], frag_pellet_speed, owner_player)

func _compute_pellet_launch() -> Dictionary:
	var origin := get_aim_origin()
	var direction := get_aim_direction()

	if direction.length() < 0.001:
		return {}

	direction = get_hitscan_shot_direction(direction.normalized())

	var aim_target := origin + direction * hitscan_range
	var aim_query := PhysicsRayQueryParameters3D.create(origin, aim_target)
	aim_query.collision_mask = hitscan_collision_mask
	aim_query.exclude = get_owner_collision_exclusions()
	var aim_hit := get_world_3d().direct_space_state.intersect_ray(aim_query)

	if not aim_hit.is_empty():
		aim_target = aim_hit["position"]

	var muzzle := get_tracer_origin()
	var converge := aim_target - muzzle

	if converge.length() > 0.05:
		origin = muzzle
		direction = converge.normalized()

	return {"origin": origin, "direction": direction}
