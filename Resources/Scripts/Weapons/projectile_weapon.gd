class_name ProjectileWeapon
extends HitscanWeapon

# PROJECTILE gun (travel time, dodgeable). HitscanWeapon supplies the whole fire cadence
# (cooldown, semi-auto, bursts) and the base Weapon does ammo, reload, ADS, spread, and all
# three recoil channels; this subclass only swaps what a fired round launches: a
# PlasmaProjectile instead of a ray.
#
# The bolt is client-simulated on the shooter's machine. On impact its scene queries the
# spherical blast and submits per-player damage + radial impulse through NetworkManager's
# validated plasma-explosion path. Other clients get a cosmetic/prop-physics copy.

@export_group("Projectile")
@export var projectile_scene: PackedScene = preload("res://Resources/Objects/Weapons/Effects/plasma_projectile.tscn")
# Bolt flight speed (m/s). Faster = harder to dodge, shorter server-validation gap.
@export var projectile_speed: float = 55.0


func perform_shot() -> void:
	fire_projectile()


func fire_projectile() -> Node:
	var origin := get_aim_origin()
	var direction := get_aim_direction()

	if direction.length() < 0.001:
		return null

	# Reuse the base spread model (hitscan_spread_degrees + ADS multiplier).
	direction = get_hitscan_shot_direction(direction.normalized())

	# The bolt SPAWNS at the barrel but flies toward the point the camera ray is actually
	# aiming at (raycast from the eye), so it leaves the gun visually yet still lands where
	# the player is looking — same eye-ray/barrel-visual split as the hitscan tracers.
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

	if projectile_scene == null:
		push_error("ProjectileWeapon has no projectile_scene assigned.")
		return null

	var instance := projectile_scene.instantiate()
	var bolt := instance as PlasmaProjectile

	if bolt == null:
		push_error("ProjectileWeapon projectile_scene root must be a PlasmaProjectile.")
		instance.free()
		return null

	bolt.owner_player = owner_player
	bolt.can_deal_damage = true

	if inventory_id != &"":
		bolt.source_weapon_id = String(inventory_id)

	# Same world-space parent the hitscan tracers use.
	var parent := get_hitscan_effect_parent()

	if parent == null:
		bolt.free()
		return null

	parent.add_child(bolt)
	bolt.launch(origin, direction, projectile_speed, owner_player)

	# Relay a cosmetic copy of the bolt to the other clients.
	if owner_player != null and owner_player.has_method("report_projectile_shot"):
		owner_player.call("report_projectile_shot", origin, direction * projectile_speed)

	return bolt
