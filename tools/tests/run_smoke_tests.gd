extends SceneTree

# Headless smoke-test suite. Run from the project root:
#
#   <godot> --headless --path . -s tools/tests/run_smoke_tests.gd
#
# Exits 0 when every check passes, 1 otherwise (CI-friendly). Covers:
#   - every registered map / weapon / tracer / muzzle-flash / core scene instantiates
#   - server-economy hit validation (fire-rate tokens, damage clamp, plasma per-target dedup)
#   - lobby-settings sanitation against hostile client dictionaries
#   - network state hygiene (basis orthonormalization, transform validation, spawn slots)
#
# Scenes are instantiated WITHOUT entering the tree (no _ready side effects), which still
# proves the resource graph loads and the script attaches. Gameplay behavior beyond that
# needs a real (or loopback) session.

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_run_all()


func _run_all() -> void:
	print("=== Zero-G smoke tests ===")

	test_scene_instantiation()
	test_economy_hitscan_validation()
	test_economy_plasma_target_dedup()
	test_economy_ffa_exclusive_grant()
	test_lobby_settings_sanitation()
	test_network_state_hygiene()
	test_surface_walk_wall_slide()
	await test_grapple_multiwrap()

	# Runtime (in-tree, physics-active) checks per registered arena. `grounded` asserts
	# every spawn stands on a surface within the 8 m ground-mode probe. Both current arenas
	# ground all spawns (Diamond on its pole faces, Sphere on its pentagon faces). This
	# guards the Diamond spawns against an arena-wide rescale silently floating them again
	# (a 2.45x root scale once pushed the pole spawns past the probe — see git history).
	var map_expectations := {"diamond": true, "sphere": true}

	for entry in MapGenerator.MAPS:
		var id := String(entry["id"])
		await test_map_runtime(id, entry["scene"] as PackedScene, bool(map_expectations.get(id, false)))

	print("")

	if _failures == 0:
		print("PASS: all %d checks passed." % _checks)
	else:
		print("FAIL: %d of %d checks failed." % [_failures, _checks])

	quit(0 if _failures == 0 else 1)


func check(condition: bool, label: String) -> void:
	_checks += 1

	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		printerr("  FAIL  ", label)


# --- Scene integrity ---------------------------------------------------------------------

const SCENE_PATHS := [
	"res://player.tscn",
	"res://scenes/main.tscn",
	"res://scenes/start_menu.tscn",
	"res://scenes/test_map.tscn",
	"res://DiamondArena.tscn",
	"res://scenes/sphere.tscn",
	"res://scenes/spawn_point.tscn",
	"res://testingdrone.tscn",
	"res://scenes/minigun.tscn",
	"res://scenes/railgun.tscn",
	"res://scenes/rifle.tscn",
	"res://scenes/plasma_cannon.tscn",
	"res://scenes/plasma_projectile.tscn",
	"res://scenes/hitscan_tracer_effect.tscn",
	"res://scenes/minigun_tracer_effect.tscn",
	"res://scenes/railgun_tracer_effect.tscn",
	"res://scenes/rifle_tracer_effect.tscn",
	"res://scenes/minigun_muzzle_flash.tscn",
	"res://scenes/railgun_muzzle_flash.tscn",
	"res://scenes/rifle_muzzle_flash.tscn",
]


func test_scene_instantiation() -> void:
	print("- scene instantiation")

	for path in SCENE_PATHS:
		var scene := load(path) as PackedScene

		if scene == null:
			check(false, path + " loads")
			continue

		var instance := scene.instantiate()
		check(instance != null, path + " instantiates")

		if instance != null:
			instance.free()

	# The weapon registry itself: every id must resolve to a Weapon-rooted scene.
	for weapon_id in WeaponInventory.SLOT_IDS:
		var weapon_scene := WeaponInventory.get_weapon_scene(weapon_id)
		var weapon = weapon_scene.instantiate() if weapon_scene != null else null
		check(weapon is Weapon, "weapon registry '%s' roots a Weapon" % weapon_id)

		if weapon != null:
			weapon.free()


# --- Server economy ----------------------------------------------------------------------

func _make_economy() -> ServerEconomy:
	var economy := ServerEconomy.new()
	# Ledgers are injected directly; no server peer or NetworkManager needed for validation.
	return economy


func test_economy_hitscan_validation() -> void:
	print("- economy: hitscan claims")

	var economy := _make_economy()
	var stats := economy.get_weapon_stats("railgun")
	check(not stats.is_empty(), "railgun stats build from the weapon scene")

	economy.ammo_by_peer_id[7] = {"railgun": economy._fresh_ammo_entry(stats)}

	# Damage clamps to the weapon's real damage.
	var approved := economy.server_validate_hitscan_hit(7, "railgun", 9999.0)
	check(is_equal_approx(approved, float(stats["damage"])), "claimed damage clamps to weapon damage")

	# Token bucket: capacity is burst+2, so two more instant claims pass, the next is rejected.
	check(economy.server_validate_hitscan_hit(7, "railgun", 10.0) >= 0.0, "claim 2 within token capacity passes")
	check(economy.server_validate_hitscan_hit(7, "railgun", 10.0) >= 0.0, "claim 3 within token capacity passes")
	check(economy.server_validate_hitscan_hit(7, "railgun", 10.0) < 0.0, "claim 4 beyond fire rate is rejected")

	# Unknown weapon / unowned weapon claims fail closed.
	check(economy.server_validate_hitscan_hit(7, "bogus_gun", 10.0) < 0.0, "unknown weapon rejected")
	check(economy.server_validate_hitscan_hit(8, "railgun", 10.0) < 0.0, "unowned ledger rejected")

	economy.free()


func test_economy_plasma_target_dedup() -> void:
	print("- economy: plasma per-target dedup")

	var economy := _make_economy()
	var stats := economy.get_weapon_stats("plasma_cannon")
	check(not stats.is_empty(), "plasma stats build from the bolt scene")

	economy.ammo_by_peer_id[7] = {"plasma_cannon": economy._fresh_ammo_entry(stats)}

	var blast := Vector3(3.0, 1.0, -2.0)
	check(economy.server_validate_plasma_hit(7, "plasma_cannon", 100.0, blast, 42) >= 0.0, "first claim on target A passes")
	check(economy.server_validate_plasma_hit(7, "plasma_cannon", 100.0, blast, 42) < 0.0, "repeat claim on target A is rejected")
	check(economy.server_validate_plasma_hit(7, "plasma_cannon", 100.0, blast, 43) >= 0.0, "same blast, target B passes")
	check(economy.server_validate_plasma_hit(7, "plasma_cannon", 100.0, blast, 43) < 0.0, "repeat claim on target B is rejected")

	# A blast far outside the merge window is a NEW blast: same target is damageable again.
	var far_blast := blast + Vector3(50.0, 0.0, 0.0)
	check(economy.server_validate_plasma_hit(7, "plasma_cannon", 100.0, far_blast, 42) >= 0.0, "new blast re-allows target A")

	economy.free()


func test_economy_ffa_exclusive_grant() -> void:
	print("- economy: FFA grants are exclusive")

	var economy := _make_economy()
	# server_grant_ffa_weapon requires is_server(); exercise the revoke logic directly the
	# way the server path composes it.
	economy.owned_by_peer_id[7] = {"minigun": 1, "grab_distance": 2, "suit_boosters": 1}
	economy.ammo_by_peer_id[7] = {"minigun": economy._fresh_ammo_entry(economy.get_weapon_stats("minigun"))}

	var owned: Dictionary = economy.owned_by_peer_id[7]

	for group in owned.keys():
		if economy.is_weapon_group(String(group)) and String(group) != "railgun":
			owned.erase(group)

	owned["railgun"] = 1

	check(not owned.has("minigun"), "prior FFA weapon ownership revoked")
	check(owned.has("grab_distance") and owned.has("suit_boosters"), "non-weapon groups preserved")

	economy.free()


# --- Lobby settings sanitation -------------------------------------------------------------

func test_lobby_settings_sanitation() -> void:
	print("- lobby: hostile settings dictionaries")

	check(LobbyManager._safe_int({}, 5) == 5, "_safe_int rejects Dictionary")
	check(LobbyManager._safe_int("12", 5) == 5, "_safe_int rejects String (no implicit parse)")
	check(LobbyManager._safe_int(9, 5) == 9, "_safe_int passes int")
	check(LobbyManager._safe_float(NAN, 3.0) == 3.0, "_safe_float rejects NaN")
	check(LobbyManager._safe_float([], 3.0) == 3.0, "_safe_float rejects Array")
	check(LobbyManager._safe_bool(1, false) == false, "_safe_bool rejects int")
	check(LobbyManager._safe_string(123, "x", 10) == "x", "_safe_string rejects int")

	var long_name := "A".repeat(500)
	check(LobbyManager._safe_string(long_name, "x", 40).length() == 40, "_safe_string clamps length")

	check(LobbyManager._safe_weapon_list({"a": 1}, ["rifle"]) == ["rifle"], "_safe_weapon_list rejects Dictionary")
	check(LobbyManager._safe_weapon_list(["railgun", "bogus", 7, "railgun"], []) == ["railgun"], "_safe_weapon_list filters to known ids, deduplicated")


# --- Network state hygiene -------------------------------------------------------------------

func test_network_state_hygiene() -> void:
	print("- network: transform validation and spawn slots")

	var nm_script := load("res://scenes/network_manager.gd")
	var nm: Node = nm_script.new()   # not added to the tree: _ready never runs

	var good := Transform3D(Basis.IDENTITY.rotated(Vector3(0.3, 0.8, 0.52).normalized(), 1.2), Vector3(1, 2, 3))
	check(nm.is_valid_transform(good), "orthonormal transform accepted")

	var scaled := Transform3D(Basis.IDENTITY.scaled(Vector3(3, 3, 3)), Vector3.ZERO)
	check(not nm.is_valid_transform(scaled), "scaled basis rejected")

	var degenerate := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
	check(not nm.is_valid_transform(degenerate), "degenerate basis rejected")

	var nan_transform := Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0))
	check(not nm.is_valid_transform(nan_transform), "non-finite origin rejected")

	# Spawn slots fill the lowest gap left by a disconnect (never .size()-collide).
	nm.spawn_index_by_peer_id = {101: 0, 102: 1, 103: 2}
	nm.spawn_index_by_peer_id.erase(102)
	check(nm._lowest_free_spawn_slot() == 1, "disconnect gap is refilled first")
	nm.spawn_index_by_peer_id[104] = 1
	check(nm._lowest_free_spawn_slot() == 3, "full slots append at the end")

	nm.free()

	# Replica state receipt orthonormalizes hostile scale away.
	var player_scene := load("res://player.tscn") as PackedScene
	var player = player_scene.instantiate()
	var skewed := Transform3D(Basis.IDENTITY.scaled(Vector3(4.0, 0.5, 2.0)).rotated(Vector3.UP, 0.7), Vector3(5, 6, 7))
	player.receive_network_state(skewed, Vector3.ZERO, Vector3.ZERO, 1)

	var received: Transform3D = player.network_target_transform
	check(absf(received.basis.determinant() - 1.0) < 0.01, "received basis is orthonormalized")
	check(received.origin == Vector3(5, 6, 7), "received origin preserved")
	check(player.network_last_received_seq == 1, "state_seq recorded")

	# Stale packet (same seq) must not overwrite.
	player.receive_network_state(Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3.ZERO, Vector3.ZERO, 1)
	check(player.network_target_transform.origin == Vector3(5, 6, 7), "stale state_seq is dropped")

	player.free()


# --- Surface-walk wall slide ------------------------------------------------------------
# strip_into_wall_component removes the part of a walk velocity heading INTO a wall (so you
# stop against it / slide along its base) while leaving parallel motion untouched.

func test_surface_walk_wall_slide() -> void:
	print("- movement: wall-slide velocity strip")

	var mc := PlayerMovementController

	# Wall on +X (its outward normal projected on the floor points -X toward the player).
	var wall_tangent := Vector3(-1, 0, 0)

	# Straight into the wall (+X): fully cancelled.
	var into := mc.strip_into_wall_component(Vector3(5, 0, 0), wall_tangent)
	check(into.is_equal_approx(Vector3.ZERO), "head-on into wall is fully stopped")

	# Diagonal into the wall (+X +Z): the +X part is removed, the +Z slide survives.
	var diagonal := mc.strip_into_wall_component(Vector3(5, 0, 3), wall_tangent)
	check(diagonal.is_equal_approx(Vector3(0, 0, 3)), "diagonal keeps the along-wall component")

	# Moving AWAY from the wall (-X): untouched (you can always walk off it).
	var away := mc.strip_into_wall_component(Vector3(-5, 0, 2), wall_tangent)
	check(away.is_equal_approx(Vector3(-5, 0, 2)), "moving away from the wall is unaffected")

	# Parallel to the wall (pure +Z): untouched.
	var parallel := mc.strip_into_wall_component(Vector3(0, 0, 4), wall_tangent)
	check(parallel.is_equal_approx(Vector3(0, 0, 4)), "parallel motion is unaffected")


# --- Grapple multi-wrap -----------------------------------------------------------------
# Orbits a body several full turns around a solid sphere with the surface-hugging tuning
# from player.tscn and asserts the pivot chain keeps growing (so the wire keeps wrapping)
# and the live segment never chords through the body. Guards MAX_PIVOTS: a cap too low for
# real multi-wrap play silently stops planting bends and the rope cuts through the object.

func test_grapple_multiwrap() -> void:
	print("- grapple: multi-wrap around a body")

	var container := Node3D.new()
	root.add_child(container)

	var body := StaticBody3D.new()
	container.add_child(body)
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 2.0
	shape.shape = sphere
	body.add_child(shape)

	var player := RigidBody3D.new()
	player.freeze = true
	container.add_child(player)

	var grapple = load("res://scripts/grapple_controller.gd").new()
	grapple.wrap_surface_offset = 0.005      # the tight, dense-bend tuning from player.tscn
	grapple.wrap_min_pivot_separation = 0.0
	player.add_child(grapple)
	grapple.setup(player)

	await physics_frame
	await physics_frame

	var orbit_radius := 3.2
	player.global_position = Vector3(orbit_radius, 0.0, 0.0)
	grapple.has_grapple = true
	grapple.attached = true
	grapple.pivots = [Vector3(2.01, 0.0, 0.0)] as Array[Vector3]
	grapple.bend_axes = [] as Array[Vector3]
	grapple.consumed_length = 0.0
	grapple.total_length = 200.0

	var space := container.get_world_3d().direct_space_state
	var max_pivots := 1
	var ever_through := false
	var angle := 4.0

	while angle <= 1440.0:   # four full laps
		player.global_position = Vector3(cos(deg_to_rad(angle)) * orbit_radius, 0.0, sin(deg_to_rad(angle)) * orbit_radius)
		grapple._update_wrap()
		grapple._update_unwrap()

		var count: int = grapple.pivots.size()
		max_pivots = maxi(max_pivots, count)

		var active: Vector3 = grapple.pivots[count - 1]
		var query := PhysicsRayQueryParameters3D.create(player.global_position, active)
		query.exclude = [player.get_rid()]
		var hit := space.intersect_ray(query)

		if not hit.is_empty():
			var hit_d := player.global_position.distance_to(hit["position"])
			var pivot_d := player.global_position.distance_to(active)

			if hit_d < pivot_d - 0.15:
				ever_through = true

		angle += 4.0

	check(max_pivots > 64, "wire keeps wrapping past the old 64-pivot cap (reached %d)" % max_pivots)
	check(max_pivots <= grapple.MAX_PIVOTS, "pivot chain stays bounded by MAX_PIVOTS")
	check(not ever_through, "rope never chords through the body across four full wraps")

	container.free()
	await physics_frame


# --- Per-map runtime checks -------------------------------------------------------------
# The map enters the tree with live physics: spawn groups must populate (5 per team),
# every spawn transform must survive the runtime's orthonormalization (uniform authored
# scale is fine — get_spawn_transform strips it; mirrored/degenerate bases are not), the
# arena must ENCLOSE its centre (random rays from the spawn centroid all hit a wall —
# exactly what FFA edge-spawning does), and — where the map promises grounded spawns —
# every spawn point must have a surface within the player's 8 m six-axis spawn probe.

func test_map_runtime(map_id: String, scene: PackedScene, expect_grounded: bool) -> void:
	print("- map runtime: ", map_id)

	var map = scene.instantiate()
	root.add_child(map)

	await physics_frame
	await physics_frame

	var spawns_a := get_nodes_in_group("spawn_team_a")
	var spawns_b := get_nodes_in_group("spawn_team_b")
	check(spawns_a.size() == 5, "%s: 5 team-A spawn points (got %d)" % [map_id, spawns_a.size()])
	check(spawns_b.size() == 5, "%s: 5 team-B spawn points (got %d)" % [map_id, spawns_b.size()])

	var all_spawns := spawns_a + spawns_b
	var centroid := Vector3.ZERO
	var transforms_ok := true
	var grounded_count := 0
	var space := (map as Node3D).get_world_3d().direct_space_state

	for spawn in all_spawns:
		var xform := (spawn as Node3D).global_transform
		centroid += xform.origin

		# The same normalization the game applies before spawning a player on this marker.
		var normalized := xform.basis.orthonormalized()

		if not xform.basis.x.is_finite() or absf(normalized.determinant() - 1.0) > 0.01:
			transforms_ok = false

		# Game-style spawn probe: nearest surface along any of the six body axes.
		for direction in [-normalized.y, normalized.y, normalized.x, -normalized.x, -normalized.z, normalized.z]:
			var query := PhysicsRayQueryParameters3D.create(
				xform.origin,
				xform.origin + (direction as Vector3) * 8.0
			)

			if not space.intersect_ray(query).is_empty():
				grounded_count += 1
				break

	check(transforms_ok, map_id + ": all spawn bases orthonormalize cleanly")

	if expect_grounded:
		check(
			grounded_count == all_spawns.size(),
			"%s: all spawns grounded within the 8 m probe (%d/%d)" % [map_id, grounded_count, all_spawns.size()]
		)
	else:
		print("  info  %s: %d/%d spawns within ground-probe range (rest float in zero-G by design)" % [map_id, grounded_count, all_spawns.size()])

	if not all_spawns.is_empty():
		centroid /= float(all_spawns.size())

	# Enclosure: 24 random rays outward from the centroid must all hit (FFA edge spawns
	# raycast exactly like this; a miss means a hole or one-sided interior collision).
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var enclosure_hits := 0

	for i in range(24):
		var direction := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)
		)

		if direction.length() < 0.05:
			direction = Vector3.UP

		var query := PhysicsRayQueryParameters3D.create(
			centroid,
			centroid + direction.normalized() * 1000.0
		)

		if not space.intersect_ray(query).is_empty():
			enclosure_hits += 1

	check(enclosure_hits == 24, "%s: arena encloses the spawn centroid (%d/24 rays hit)" % [map_id, enclosure_hits])

	map.free()
	await physics_frame
