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
#   - map creator: document round-trip + hostile-JSON sanitation, bevel mesh generation
#     (winding checked against engine convention), OBJ/STL runtime parsers, and built-map
#     runtime guarantees (spawn groups, analytic-vs-trimesh colliders, solid geometry)
#   - cylindrical force field: ring weight profile, local-axis push + height gating,
#     generated collider/gizmo children, Diamond arena placement
#   - spinning skybox rig: fullbright shader loads, spin accumulation/orthonormality
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
	test_rpc_protocol_fingerprint()
	test_economy_hitscan_validation()
	test_economy_plasma_target_dedup()
	test_economy_ffa_exclusive_grant()
	test_lobby_settings_sanitation()
	test_network_state_hygiene()
	test_surface_walk_wall_slide()
	test_surface_walk_pitch_gimbal()
	test_charge_weapon_scaling()
	await test_grapple_multiwrap()
	await test_cylindrical_force_field()
	test_spinning_skybox()
	test_map_creator_document_roundtrip()
	test_bevel_mesh_generators()
	test_model_importer_parsers()
	await test_map_creator_builder()
	test_map_creator_gizmos()

	# Runtime (in-tree, physics-active) checks per registered arena. `grounded` asserts
	# every spawn stands on a surface within the 8 m ground-mode probe. Both current arenas
	# ground all spawns (Diamond on its pole faces, Sphere on its pentagon faces). This
	# guards the Diamond spawns against an arena-wide rescale silently floating them again
	# (a 2.45x root scale once pushed the pole spawns past the probe — see git history).
	var map_expectations := {"diamond": true, "sphere": true}

	for entry in MapGenerator.get_map_entries():
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
	"res://Resources/Objects/player.tscn",
	"res://scenes/main.tscn",
	"res://scenes/start_menu.tscn",
	"res://scenes/test_map.tscn",
	"res://scenes/map_creator.tscn",
	"res://DiamondArena.tscn",
	"res://scenes/sphere.tscn",
	"res://spin_space_ball.tscn",
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
	for weapon_id in WeaponInventory.get_weapon_ids():
		var weapon_scene := WeaponInventory.get_weapon_scene(weapon_id)
		var weapon = weapon_scene.instantiate() if weapon_scene != null else null
		check(weapon is Weapon, "weapon registry '%s' roots a Weapon" % weapon_id)

		if weapon != null:
			weapon.free()


# --- RPC protocol fingerprint --------------------------------------------------------------
# Godot sends RPCs as an index into each node's alphabetically-sorted @rpc method table, so
# ANY change to the project's @rpc surface breaks wire compatibility with older builds (calls
# decode as the wrong methods). The connect-time handshake rejects mismatched builds — but
# only if NET_PROTOCOL_VERSION was actually bumped. This check recomputes a fingerprint of
# every @rpc declaration and fails when it drifts from the recorded one, printing the new
# hash to paste into network_manager.gd alongside the version bump.

func test_rpc_protocol_fingerprint() -> void:
	print("- rpc protocol fingerprint")

	var declarations: Array = []
	_collect_rpc_declarations("res://", declarations)
	declarations.sort()

	var fingerprint := String("\n".join(declarations)).md5_text()
	var network_manager_script := preload("res://scenes/network_manager.gd")
	var recorded := String(network_manager_script.NET_RPC_FINGERPRINT)

	check(declarations.size() > 0, "project declares @rpc methods (%d found)" % declarations.size())
	check(
		fingerprint == recorded,
		"@rpc surface matches NET_RPC_FINGERPRINT — on change, bump NET_PROTOCOL_VERSION and set fingerprint to \"%s\"" % fingerprint
	)


func _collect_rpc_declarations(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)

	if dir == null:
		return

	dir.list_dir_begin()
	var entry := dir.get_next()

	while entry != "":
		var path := dir_path.path_join(entry)

		if dir.current_is_dir():
			# Skip hidden dirs (.godot, .git) and export output; everything else may hold
			# networked scripts.
			if not entry.begins_with(".") and entry != "build":
				_collect_rpc_declarations(path, out)
		elif entry.ends_with(".gd"):
			_scan_script_for_rpc_declarations(path, out)

		entry = dir.get_next()


func _scan_script_for_rpc_declarations(path: String, out: Array) -> void:
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return

	var lines := file.get_as_text().split("\n")
	var pending_annotation := ""

	for line in lines:
		var stripped := String(line).strip_edges()

		if stripped.begins_with("@rpc"):
			pending_annotation = stripped
		elif pending_annotation != "" and stripped.begins_with("func "):
			# Only the method NAME matters on the wire (table order is sorted names); the
			# annotation matters for mode/channel. Argument names/types are free to change.
			var name_end := stripped.find("(")
			var func_name := stripped.substr(5, name_end - 5).strip_edges() if name_end > 5 else stripped
			out.append(path + " | " + pending_annotation + " | " + func_name)
			pending_annotation = ""
		elif pending_annotation != "" and stripped != "" and not stripped.begins_with("#") and not stripped.begins_with("@"):
			# Something other than the func landed after @rpc — don't mis-attribute it.
			pending_annotation = ""


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
	var player_scene := load("res://Resources/Objects/player.tscn") as PackedScene
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

	var mc := GroundMovementController

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


# --- Surface-walk pitch gimbal ----------------------------------------------------------
# When the walked-surface normal tilts fore/aft, the body noses up/down; the stabilizer stores
# a camera-pitch offset that CANCELS that nod (so only the mouse pitches the view). Assert the
# offset takes the opposing sign, that recenter <= 0 disables it, and that the applied pitch is
# clamped to the pitch limit. Uses a bare controller instance — align_surface_walk_normal_toward
# only touches member vectors/floats (no player/camera needed).

func test_surface_walk_pitch_gimbal() -> void:
	print("- movement: surface-walk pitch gimbal")

	var mc := GroundMovementController.new()
	mc.surface_walk_forward = Vector3(0, 0, -1)
	mc.surface_walk_align_rate = 1000.0   # keep the step off the rate limiter so a nod accrues

	# Normal tilted +10 deg about +X (body right) noses the forward UP -> offset must go negative.
	mc.surface_walk_normal = Vector3.UP
	mc.surface_walk_pitch_stabilize = 0.0
	mc.align_surface_walk_normal_toward(Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(10.0)), 0.1)
	check(mc.surface_walk_pitch_stabilize < -0.0001, "nose-up nod is cancelled by a negative pitch offset")

	# Opposite tilt noses the forward DOWN -> offset must go positive.
	mc.surface_walk_normal = Vector3.UP
	mc.surface_walk_forward = Vector3(0, 0, -1)
	mc.surface_walk_align_rate = 1000.0
	mc.surface_walk_pitch_stabilize = 0.0
	mc.align_surface_walk_normal_toward(Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(-10.0)), 0.1)
	check(mc.surface_walk_pitch_stabilize > 0.0001, "nose-down nod is cancelled by a positive pitch offset")

	# pitch_gimbal_strength = 0 disables the stabilizer: no offset accrues from alignment.
	# (recenter = 0 now means "never wash out" — an absolute hold — not "off".)
	mc.surface_walk_normal = Vector3.UP
	mc.surface_walk_forward = Vector3(0, 0, -1)
	mc.surface_walk_align_rate = 1000.0
	mc.surface_walk_pitch_stabilize = 0.0
	mc.pitch_gimbal_strength = 0.0
	mc.align_surface_walk_normal_toward(Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(10.0)), 0.1)
	check(is_equal_approx(mc.surface_walk_pitch_stabilize, 0.0), "gimbal strength 0 disables the stabilizer")

	# Applied pitch (aim + offset) is clamped to the pitch limit so it can't invert the view.
	mc.surface_walk_pitch = 0.0
	mc.surface_walk_pitch_stabilize = deg_to_rad(200.0)
	var applied := mc.get_surface_walk_applied_pitch()
	check(is_equal_approx(applied, deg_to_rad(mc.surface_walk_pitch_limit_degrees)),
		"applied pitch clamps to the pitch limit")

	mc.free()


# --- Charge railgun scaling -------------------------------------------------------------
# A charge weapon scales damage AND tracer width from a floor (a tap) to full (a complete
# charge), and its hitscan_damage is the FULL value the server clamps claims to.

func test_charge_weapon_scaling() -> void:
	print("- weapons: charge railgun scaling")

	var gun := ChargeHitscanWeapon.new()
	gun.hitscan_damage = 100.0
	gun.charge_min_damage_fraction = 0.35
	gun.tracer_charge_min_scale = 0.4
	gun.tracer_charge_max_scale = 1.8
	gun.max_charge_time = 1.0

	gun._fire_charge_ratio = 0.0
	check(is_equal_approx(gun.get_effective_hitscan_damage(), 35.0), "uncharged shot deals the floor damage")
	check(is_equal_approx(gun.get_tracer_size_scale(), 0.4), "uncharged tracer is the min width")

	gun._fire_charge_ratio = 1.0
	check(is_equal_approx(gun.get_effective_hitscan_damage(), 100.0), "full charge deals the full (clamp) damage")
	check(is_equal_approx(gun.get_tracer_size_scale(), 1.8), "full-charge tracer is the max width")

	gun._fire_charge_ratio = 0.5
	check(is_equal_approx(gun.get_effective_hitscan_damage(), 67.5), "half charge interpolates damage")

	gun.charge_time = 5.0   # beyond max
	check(is_equal_approx(gun.charge_ratio(), 1.0), "charge ratio clamps at full")
	gun.charge_time = 0.25
	check(is_equal_approx(gun.charge_ratio(), 0.25), "charge ratio tracks hold time")
	gun.free()

	# The REGISTERED railgun is a charge weapon, and the economy clamps claims to its full-charge
	# damage, so a charged shot always validates (no economy change needed for the charge).
	var scene := WeaponInventory.get_weapon_scene(&"railgun")
	var railgun = scene.instantiate() if scene != null else null
	check(railgun is ChargeHitscanWeapon, "the registered railgun is a ChargeHitscanWeapon")

	if railgun != null:
		var economy := _make_economy()
		var stats := economy.get_weapon_stats("railgun")
		check(
			is_equal_approx(float(stats["damage"]), float(railgun.hitscan_damage)),
			"economy clamps railgun claims to its full-charge damage"
		)
		economy.free()
		railgun.free()

	# The tracer effect's width scale multiplies its beam width (so bystanders see the charge).
	var tracer := WeaponHitscanTracerEffect.new()
	tracer.tracer_width = 0.1
	tracer.tail_width_multiplier = 1.0
	tracer.size_scale = 1.0
	var base_width := tracer.get_width_at_ratio(1.0)
	tracer.size_scale = 2.0
	check(is_equal_approx(tracer.get_width_at_ratio(1.0), base_width * 2.0), "tracer width scales with the charge")
	tracer.free()


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


# --- Cylindrical force field --------------------------------------------------------------
# Profile checks for the lateral repulsor volume (CylindricalForceField): the three rings
# gate the radial weight curve (zero inside start, peak at full, zero at end), the falloff
# exponents shape the ramps, the push is radially outward off the LOCAL axis (rotation
# respected) and gated by the height band, and the generated collider/gizmo children track
# the exported sizes without ever being owned (so the editor never saves them). Also
# asserts the Diamond arena actually ships one with sanely ordered rings.

func test_cylindrical_force_field() -> void:
	print("- cylindrical force field")

	var field := CylindricalForceField.new()
	field.height = 10.0
	field.start_radius = 2.0
	field.full_radius = 4.0
	field.end_radius = 8.0
	field.force_strength = 10.0
	field.blend_in_falloff = 1.0
	field.blend_out_falloff = 1.0
	root.add_child(field)

	check(field.get_force_weight(1.0) == 0.0, "no force inside the start (green) ring")
	check(field.get_force_weight(2.0) == 0.0, "start ring is the zero edge of the blend-in")
	check(absf(field.get_force_weight(3.0) - 0.5) < 0.0001, "linear blend-in midpoint at half strength")
	check(absf(field.get_force_weight(4.0) - 1.0) < 0.0001, "full force at the full (yellow) ring")
	check(absf(field.get_force_weight(6.0) - 0.5) < 0.0001, "linear blend-out midpoint at half strength")
	check(field.get_force_weight(8.0) == 0.0, "force ends at the end (red) ring")
	check(field.get_force_weight(9.0) == 0.0, "no force outside the volume")

	field.blend_in_falloff = 2.0
	field.blend_out_falloff = 3.0
	check(absf(field.get_force_weight(3.0) - 0.25) < 0.0001, "blend-in falloff exponent shapes the ramp")
	check(absf(field.get_force_weight(6.0) - 0.125) < 0.0001, "blend-out falloff exponent shapes the ramp")
	field.blend_in_falloff = 1.0
	field.blend_out_falloff = 1.0

	var push := field.get_force_for_global_position(Vector3(4.0, 0.0, 0.0))
	check(push.is_equal_approx(Vector3(10.0, 0.0, 0.0)), "push points radially outward at force_strength")
	check(field.get_force_for_global_position(Vector3(4.0, 5.1, 0.0)) == Vector3.ZERO, "no force outside the height band")
	check(field.get_force_for_global_position(Vector3.ZERO) == Vector3.ZERO, "a body on the axis is not pushed")

	# The cylinder axis is LOCAL Y: rotate the field 90° about X (axis now world +Z) and a
	# point that sits on that axis gets nothing, while radial points still push outward.
	field.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	check(field.get_force_for_global_position(Vector3(0.0, 0.0, 4.0)) == Vector3.ZERO, "rotated field: on-axis point gets no push")
	var rotated_push := field.get_force_for_global_position(Vector3(4.0, 0.0, 0.0))
	check(rotated_push.is_equal_approx(Vector3(10.0, 0.0, 0.0)), "rotated field pushes radially off its local axis")
	field.rotation_degrees = Vector3.ZERO

	var collider: CollisionShape3D = null
	var gizmo: MeshInstance3D = null

	for child in field.get_children(true):
		if child is CollisionShape3D:
			collider = child
		elif child is MeshInstance3D:
			gizmo = child

	check(collider != null and collider.shape is CylinderShape3D, "field builds its own cylinder collider")
	check(gizmo != null and gizmo.mesh != null and gizmo.mesh.get_surface_count() == 1, "field builds the three-ring wireframe gizmo")
	check(collider != null and gizmo != null and collider.owner == null and gizmo.owner == null, "generated children are never scene-owned")

	if gizmo != null and gizmo.mesh != null and gizmo.mesh.get_surface_count() == 1:
		var arrays: Array = gizmo.mesh.surface_get_arrays(0)
		var vert_count: int = arrays[Mesh.ARRAY_VERTEX].size()
		check(vert_count > 0 and vert_count % 2 == 0 and arrays[Mesh.ARRAY_COLOR].size() == vert_count, "gizmo line list is well-formed (paired verts, per-vertex colors)")
	else:
		check(false, "gizmo line list is well-formed (paired verts, per-vertex colors)")

	field.end_radius = 12.0
	check(collider != null and (collider.shape as CylinderShape3D).radius == 12.0, "collider tracks end_radius edits")
	check(collider != null and (collider.shape as CylinderShape3D).height == 10.0, "collider height matches the exported height")

	# End-to-end with live physics: a default-layer unfrozen body inside the band must be
	# detected by the overlap volume and accelerate radially outward; a frozen body (what
	# remote player replicas are) must be left untouched.
	var pushed := RigidBody3D.new()
	pushed.gravity_scale = 0.0
	var pushed_shape := CollisionShape3D.new()
	pushed_shape.shape = SphereShape3D.new()
	pushed.add_child(pushed_shape)
	root.add_child(pushed)
	pushed.global_position = Vector3(4.0, 0.0, 0.0)

	var frozen := RigidBody3D.new()
	frozen.gravity_scale = 0.0
	frozen.freeze = true
	var frozen_shape := CollisionShape3D.new()
	frozen_shape.shape = SphereShape3D.new()
	frozen.add_child(frozen_shape)
	root.add_child(frozen)
	frozen.global_position = Vector3(-4.0, 0.0, 0.0)

	for _i in 12:
		await physics_frame

	var v := pushed.linear_velocity
	check(v.x > 0.2 and absf(v.y) < 0.01 and absf(v.z) < 0.01, "live rigid body accelerates radially outward (v=%s)" % v)
	check(frozen.linear_velocity.is_equal_approx(Vector3.ZERO) and frozen.global_position.is_equal_approx(Vector3(-4.0, 0.0, 0.0)), "frozen body (remote replica) is never pushed")

	pushed.free()
	frozen.free()

	# The Diamond arena ships one as its midline hazard (instantiated out of tree — the
	# setters must tolerate running before _ready builds the children).
	var diamond = (MapGenerator.get_map_entry("diamond")["scene"] as PackedScene).instantiate()
	var shipped := _find_force_field(diamond)
	check(shipped != null, "Diamond arena ships a CylindricalForceField")
	check(shipped != null and shipped.start_radius < shipped.full_radius and shipped.full_radius < shipped.end_radius, "Diamond field rings are ordered start < full < end")
	diamond.free()

	field.free()


func _find_force_field(node: Node) -> CylindricalForceField:
	if node is CylindricalForceField:
		return node

	for child in node.get_children():
		var found := _find_force_field(child)

		if found != null:
			return found

	return null


# --- Spinning skybox rig ------------------------------------------------------------------
# The rig (SpinningSkybox) pins a sky sphere to the camera and spins it independently. The
# spin math is a pure static function so it's checked directly: it advances by
# deg_per_sec * delta about the axis, accumulates across frames, no-ops on zero speed/axis,
# and stays orthonormal (so per-frame multiplication never drifts into skew/scale). Also
# confirms the fullbright shader resource loads as a spatial shader.

func test_spinning_skybox() -> void:
	print("- spinning skybox rig")

	var shader = load("res://shaders/skybox_fullbright.gdshader")
	check(shader is Shader, "skybox shader resource loads")
	check(shader is Shader and shader.get_mode() == Shader.MODE_SPATIAL, "skybox shader is a spatial shader")

	var material := ShaderMaterial.new()
	material.shader = shader
	check(material.shader == shader, "skybox shader assigns to a ShaderMaterial")

	var one_second := SpinningSkybox.advance_spin(Basis.IDENTITY, Vector3.UP, 90.0, 1.0)
	check(one_second.is_equal_approx(Basis(Vector3.UP, deg_to_rad(90.0))), "advance_spin turns by deg/sec * delta about the axis")
	check(one_second.orthonormalized().is_equal_approx(one_second), "spun basis stays orthonormal")

	var half := SpinningSkybox.advance_spin(Basis.IDENTITY, Vector3.UP, 90.0, 0.5)
	var accumulated := SpinningSkybox.advance_spin(half, Vector3.UP, 90.0, 0.5)
	check(accumulated.is_equal_approx(Basis(Vector3.UP, deg_to_rad(90.0))), "spin accumulates across frames")

	check(SpinningSkybox.advance_spin(Basis.IDENTITY, Vector3.UP, 0.0, 1.0).is_equal_approx(Basis.IDENTITY), "zero speed leaves orientation unchanged")
	check(SpinningSkybox.advance_spin(Basis.IDENTITY, Vector3.ZERO, 90.0, 1.0).is_equal_approx(Basis.IDENTITY), "zero axis leaves orientation unchanged")

	# Non-up axis is normalized before use (an unnormalized axis must not scale the basis).
	var tilted := SpinningSkybox.advance_spin(Basis.IDENTITY, Vector3(0.0, 3.0, 0.0), 90.0, 1.0)
	check(tilted.is_equal_approx(Basis(Vector3.UP, deg_to_rad(90.0))), "spin axis is normalized regardless of length")


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


# --- Map creator: document persistence ------------------------------------------------------
# Custom maps are data-only JSON under user://custom_maps. Round-trip must preserve every
# entry, and a hostile/hand-mangled file must degrade to defaults instead of crashing.

const SMOKE_MAP_SLUG := "zz_smoke_suite"


func test_map_creator_document_roundtrip() -> void:
	print("- map creator document roundtrip")

	MapDocument.delete_map(SMOKE_MAP_SLUG)

	var doc := MapDocument.create_new("Smoke Suite Map")
	doc.slug = SMOKE_MAP_SLUG

	var box := doc.make_primitive_entry("box")
	box["position"] = [1.0, 2.0, 3.0]
	box["bevel_radius"] = 0.25
	box["bevel_segments"] = 2
	box["material"]["color"] = [0.9, 0.2, 0.1]
	doc.objects.append(box)

	var spot := doc.make_light_entry("spot")
	spot["energy"] = 7.5
	doc.objects.append(spot)

	var model := doc.make_model_entry("assets/thing.glb", "Thing")
	model["scale"] = [2.0, 2.0, 2.0]
	doc.objects.append(model)

	check(doc.save() == OK, "document saves to user://custom_maps")
	check(MapDocument.map_exists(SMOKE_MAP_SLUG), "saved map is listed as existing")

	var loaded := MapDocument.load_map(SMOKE_MAP_SLUG)
	check(loaded != null, "saved map loads back")

	if loaded != null:
		check(loaded.map_name == "Smoke Suite Map", "map name survives the round trip")
		check(loaded.objects.size() == doc.objects.size(), "all %d entries survive (got %d)" % [doc.objects.size(), loaded.objects.size()])

		var loaded_box := loaded.get_entry(int(box["id"]))
		check(not loaded_box.is_empty(), "box entry found by id after reload")
		check(MapDocument.vec3_from(loaded_box.get("position")).is_equal_approx(Vector3(1, 2, 3)), "box position survives")
		check(absf(MapDocument._safe_float(loaded_box.get("bevel_radius"), 0.0) - 0.25) < 0.001, "bevel radius survives")

		var loaded_model := loaded.get_entry(int(model["id"]))
		check(String(loaded_model.get("source", "")) == "assets/thing.glb", "model source path survives")

	# Custom map ids resolve through MapGenerator while the file exists.
	check(MapGenerator.is_custom_map_id("custom:" + SMOKE_MAP_SLUG), "custom: prefix detected")
	check(MapGenerator.has_map("custom:" + SMOKE_MAP_SLUG), "has_map true for an existing custom map")
	check(MapGenerator.get_map_name("custom:" + SMOKE_MAP_SLUG) == "Smoke Suite Map", "custom map display name resolves")
	check(MapGenerator.normalize_map_id("CUSTOM:Zz Smoke Suite") == "custom:zz_smoke_suite", "custom id normalization slugs the tail")
	check(not MapGenerator.has_map("custom:definitely_missing_zz"), "has_map false for a missing custom map")

	var copy_slug := MapDocument.duplicate_map(SMOKE_MAP_SLUG, "Smoke Suite Copy")
	check(copy_slug != "" and MapDocument.map_exists(copy_slug), "duplicate_map creates a new save")
	MapDocument.delete_map(copy_slug)

	# Hostile input: junk types, path traversal in a model source, unknown kinds. Must not
	# crash, must drop what cannot be trusted (same ethos as the lobby-settings guards).
	var hostile := MapDocument.new()
	hostile.load_from_dict({
		"name": 42,
		"next_object_id": "lots",
		"environment": "nope",
		"objects": [
			"not a dict",
			{"kind": "warp_core"},
			{"kind": "model", "source": "../../outside.glb"},
			{"kind": "model", "source": "C:/windows/system32/evil.glb"},
			{"kind": "primitive", "shape": "box", "position": [1, "a", 3], "size": "huge"},
			{"kind": "light", "type": "spot", "energy": 99999.0, "color": [9, 9, 9]},
		],
	})
	check(hostile.map_name == "Untitled Map", "hostile name degrades to default")
	check(hostile.objects.size() == 2, "hostile entries: only sanitizable ones survive (got %d)" % hostile.objects.size())

	for entry in hostile.objects:
		if String(entry.get("kind", "")) == "light":
			check(MapDocument._safe_float(entry.get("energy"), 0.0) <= 64.0, "hostile light energy is clamped")

	MapDocument.delete_map(SMOKE_MAP_SLUG)
	check(not MapDocument.map_exists(SMOKE_MAP_SLUG), "delete_map removes the save")


# --- Map creator: bevel mesh generation ------------------------------------------------------
# The generators must produce watertight-looking geometry at the requested size with unit
# normals, and their winding must MATCH the engine's own convention — checked empirically
# against a BoxMesh so an inside-out regression cannot slip in.

func test_bevel_mesh_generators() -> void:
	print("- bevel mesh generators")

	var reference_sign := _mesh_winding_sign((BoxMesh.new() as Mesh).get_mesh_arrays())

	var rounded := BevelMesh.build_rounded_box(Vector3(2.0, 1.0, 3.0), 0.2, 3)
	check(rounded.get_surface_count() == 1, "rounded box commits one surface")

	var arrays := rounded.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	check(vertices.size() > 24, "rounded box is denser than a plain box (%d verts)" % vertices.size())

	var aabb := rounded.get_aabb()
	check(
		aabb.size.is_equal_approx(Vector3(2.0, 1.0, 3.0)),
		"rounded box AABB matches requested size (got %s)" % str(aabb.size)
	)

	var normals_ok := true

	for normal in normals:
		if absf(normal.length() - 1.0) > 0.01:
			normals_ok = false
			break

	check(normals_ok, "rounded box normals are unit length")
	check(_mesh_winding_sign(arrays) == reference_sign, "rounded box winding matches engine convention")

	# Full round-over (radius = half the smallest dimension) must stay sane.
	var pill := BevelMesh.build_rounded_box(Vector3(1.0, 1.0, 1.0), 0.5, 4)
	check(pill.get_aabb().size.is_equal_approx(Vector3.ONE), "fully-rounded box (sphere case) keeps its size")

	var flat := BevelMesh.build_rounded_box(Vector3(2.0, 2.0, 2.0), 0.0, 3)
	check(flat.get_aabb().size.is_equal_approx(Vector3(2, 2, 2)), "zero bevel falls back to a plain box")

	var cylinder := BevelMesh.build_beveled_cylinder(1.0, 3.0, 0.3, 3, 24)
	var cylinder_aabb := cylinder.get_aabb()
	check(
		absf(cylinder_aabb.size.y - 3.0) < 0.01 and absf(cylinder_aabb.size.x - 2.0) < 0.01,
		"beveled cylinder AABB matches radius/height (got %s)" % str(cylinder_aabb.size)
	)
	check(_mesh_winding_sign(cylinder.surface_get_arrays(0)) == reference_sign, "beveled cylinder winding matches engine convention")


# Sign of (edge cross) · normal for the first indexed triangle — a stable fingerprint of
# front-face winding that both generated meshes must share with built-in meshes.
func _mesh_winding_sign(arrays: Array) -> float:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	for triangle in range(indices.size() / 3):
		var a := vertices[indices[triangle * 3]]
		var b := vertices[indices[triangle * 3 + 1]]
		var c := vertices[indices[triangle * 3 + 2]]
		var cross := (b - a).cross(c - a)

		if cross.length_squared() < 0.000001:
			continue

		var normal := (
			normals[indices[triangle * 3]]
			+ normals[indices[triangle * 3 + 1]]
			+ normals[indices[triangle * 3 + 2]]
		)

		if normal.length_squared() < 0.000001:
			continue

		return signf(cross.dot(normal))

	return 0.0


# --- Map creator: runtime model parsers -------------------------------------------------------

func test_model_importer_parsers() -> void:
	print("- model importer parsers")

	check(ClassDB.class_exists("GLTFDocument"), "GLTFDocument available for runtime .glb/.gltf loading")
	check(ClassDB.class_exists("FBXDocument"), "FBXDocument available for runtime .fbx loading")
	check(MapModelImporter.is_supported("user://thing.BLEND"), "extension check is case-insensitive")
	check(not MapModelImporter.is_supported("user://thing.txt"), "unsupported extensions are rejected")

	# OBJ: a unit quad with explicit normals -> one surface, two indexed triangles.
	var obj_path := "user://zz_smoke_model.obj"
	var obj_file := FileAccess.open(obj_path, FileAccess.WRITE)
	obj_file.store_string(
		"# smoke quad\n"
		+ "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\n"
		+ "vn 0 0 1\n"
		+ "f 1//1 2//1 3//1 4//1\n"
	)
	obj_file.close()

	var obj_scene := MapModelImporter.load_model_scene(obj_path)
	check(obj_scene != null, "OBJ parses into a scene")

	if obj_scene != null:
		var mesh_instance := obj_scene.get_node_or_null("Mesh") as MeshInstance3D
		check(mesh_instance != null and mesh_instance.mesh != null, "OBJ scene contains a mesh")

		if mesh_instance != null and mesh_instance.mesh != null:
			var arrays := mesh_instance.mesh.surface_get_arrays(0)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			check(indices.size() == 6, "OBJ quad fan-triangulates into 2 triangles (got %d indices)" % indices.size())
			check(_mesh_winding_sign(arrays) == _mesh_winding_sign((BoxMesh.new() as Mesh).get_mesh_arrays()), "OBJ winding converted to engine convention")

		obj_scene.free()

	DirAccess.remove_absolute(obj_path)

	# ASCII STL: one facet -> one triangle.
	var stl_path := "user://zz_smoke_model.stl"
	var stl_file := FileAccess.open(stl_path, FileAccess.WRITE)
	stl_file.store_string(
		"solid smoke\n"
		+ " facet normal 0 0 1\n  outer loop\n"
		+ "   vertex 0 0 0\n   vertex 1 0 0\n   vertex 0 1 0\n"
		+ "  endloop\n endfacet\nendsolid smoke\n"
	)
	stl_file.close()

	var stl_scene := MapModelImporter.load_model_scene(stl_path)
	check(stl_scene != null, "ASCII STL parses into a scene")

	if stl_scene != null:
		var mesh_instance := stl_scene.get_node_or_null("Mesh") as MeshInstance3D
		var vertex_count := 0

		if mesh_instance != null and mesh_instance.mesh != null:
			var arrays := mesh_instance.mesh.surface_get_arrays(0)
			vertex_count = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

		check(vertex_count == 3, "ASCII STL facet becomes one triangle (got %d verts)" % vertex_count)
		stl_scene.free()

	DirAccess.remove_absolute(stl_path)

	# Binary STL: exact-size detection (84 + 50 * count bytes).
	var bin_path := "user://zz_smoke_model_bin.stl"
	var bin_file := FileAccess.open(bin_path, FileAccess.WRITE)
	bin_file.store_buffer(PackedByteArray("solid-looking header".to_utf8_buffer()))
	bin_file.store_buffer(PackedByteArray())

	var padding := PackedByteArray()
	padding.resize(80 - 20)
	bin_file.store_buffer(padding)
	bin_file.store_32(1)

	for value in [0.0, 0.0, 1.0,  0.0, 0.0, 0.0,  1.0, 0.0, 0.0,  0.0, 1.0, 0.0]:
		bin_file.store_float(value)

	bin_file.store_16(0)
	bin_file.close()

	var bin_scene := MapModelImporter.load_model_scene(bin_path)
	check(bin_scene != null, "binary STL parses into a scene")

	if bin_scene != null:
		bin_scene.free()

	DirAccess.remove_absolute(bin_path)

	# import_file refuses what it cannot read.
	var bogus := MapModelImporter.import_file("user://does_not_exist.glb", SMOKE_MAP_SLUG)
	check(not bool(bogus.get("ok", true)), "import_file fails cleanly on a missing file")
	MapDocument.delete_map(SMOKE_MAP_SLUG)


# --- Map creator: built map runtime behavior ---------------------------------------------------
# A built custom map must carry the same guarantees hand-built arenas do: spawn markers in
# the right groups, analytic colliders for exact primitives, trimesh for curved/bevel
# geometry, physics-solid floors, and lights/environment present. Edit mode must NOT join
# spawn groups (the editor runs in a live scene tree).

func test_map_creator_builder() -> void:
	print("- map creator built-map runtime")

	var doc := MapDocument.create_new("Builder Check")
	doc.slug = "zz_smoke_builder"

	# create_new already includes a (beveled) floor box + one spawn per team.
	var plain_box := doc.make_primitive_entry("box")
	plain_box["position"] = [8.0, 6.0, 0.0]
	plain_box["bevel_radius"] = 0.0
	doc.objects.append(plain_box)

	var beveled := doc.make_primitive_entry("box")
	beveled["position"] = [8.0, 2.0, 0.0]
	beveled["bevel_radius"] = 0.3
	beveled["bevel_segments"] = 2
	doc.objects.append(beveled)

	var sphere := doc.make_primitive_entry("sphere")
	sphere["position"] = [-8.0, 2.0, 0.0]
	doc.objects.append(sphere)

	var cylinder := doc.make_primitive_entry("cylinder")
	cylinder["position"] = [0.0, 2.0, 8.0]
	doc.objects.append(cylinder)

	var ramp := doc.make_primitive_entry("ramp")
	ramp["position"] = [0.0, 2.0, -8.0]
	doc.objects.append(ramp)

	var omni := doc.make_light_entry("omni")
	omni["position"] = [0.0, 6.0, 0.0]
	doc.objects.append(omni)

	var map := CustomMapBuilder.build_map_node(doc, false)
	root.add_child(map)

	await physics_frame
	await physics_frame

	check(map.get_node_or_null("MapEnvironment") is WorldEnvironment, "built map has a WorldEnvironment")
	check(map.get_node_or_null("Sun") is DirectionalLight3D, "built map has its sun")

	var spawns_a := get_nodes_in_group("spawn_team_a")
	var spawns_b := get_nodes_in_group("spawn_team_b")
	check(spawns_a.size() == 1, "custom spawn joins spawn_team_a (got %d)" % spawns_a.size())
	check(spawns_b.size() == 1, "custom spawn joins spawn_team_b (got %d)" % spawns_b.size())

	var objects := map.get_node("Objects")
	check(_entry_collider_shape(objects, int(plain_box["id"])) is BoxShape3D, "plain box gets an analytic BoxShape3D")
	check(_entry_collider_shape(objects, 1) is ConcavePolygonShape3D, "beveled starter floor gets a trimesh collider")
	check(_entry_collider_shape(objects, int(beveled["id"])) is ConcavePolygonShape3D, "beveled box gets a trimesh collider")
	check(_entry_collider_shape(objects, int(sphere["id"])) is SphereShape3D, "sphere gets an analytic SphereShape3D")
	check(_entry_collider_shape(objects, int(cylinder["id"])) is CylinderShape3D, "cylinder gets an analytic CylinderShape3D")
	check(_entry_collider_shape(objects, int(ramp["id"])) is ConcavePolygonShape3D, "ramp gets a trimesh collider")

	var light_found := false

	for node in objects.get_children():
		if int(node.get_meta("map_object_id", -1)) == int(omni["id"]):
			light_found = node.get_node_or_null("Light") is OmniLight3D

	check(light_found, "omni light entry builds an OmniLight3D")

	# The floor must actually be solid: a downward ray from above it has to hit.
	var space := (map as Node3D).get_world_3d().direct_space_state
	var floor_query := PhysicsRayQueryParameters3D.create(Vector3(0, 4, 0), Vector3(0, -4, 0))
	check(not space.intersect_ray(floor_query).is_empty(), "built floor is physics-solid")

	map.free()
	await physics_frame
	await physics_frame

	# Edit mode: proxies instead of SpawnPoints — spawn groups must stay EMPTY.
	var edit_map := CustomMapBuilder.build_map_node(doc, true)
	root.add_child(edit_map)

	await physics_frame

	check(get_nodes_in_group("spawn_team_a").is_empty(), "edit-mode build never joins spawn groups")

	var pick_bodies := 0

	for node in edit_map.get_node("Objects").get_children():
		if node.get_node_or_null("PickBody") != null:
			pick_bodies += 1

	check(pick_bodies == 3, "edit-mode spawns/lights carry pick colliders (got %d)" % pick_bodies)

	edit_map.free()
	await physics_frame


func _entry_collider_shape(objects: Node, id: int) -> Shape3D:
	for node in objects.get_children():
		if int(node.get_meta("map_object_id", -1)) != id:
			continue

		var mesh := node.get_node_or_null("Mesh")

		if mesh == null:
			return null

		var body := mesh.get_node_or_null("StaticBody3D")

		if body == null:
			return null

		var collision := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
		return collision.shape if collision != null else null

	return null


# --- Map creator: transform gizmo integrity ----------------------------------------------------
# The gizmo handles are physics bodies on a dedicated layer (object picking masks them
# out). Handle records, metadata, and layer isolation must line up or clicks go to the
# wrong subsystem. Built without entering the tree — construction has no _ready deps.

func test_map_creator_gizmos() -> void:
	print("- map creator transform gizmo")

	var editor = (load("res://scenes/map_creator.tscn") as PackedScene).instantiate()
	editor._build_gizmos()

	# 3 axis handles + 1 centre handle per tool (move / rotate / scale).
	check(editor.gizmo_handles.size() == 12, "gizmo builds 12 handles (got %d)" % editor.gizmo_handles.size())

	var per_tool := {}
	var layers_ok := true
	var metas_ok := true
	var axes_ok := true

	for i in range(editor.gizmo_handles.size()):
		var handle: Dictionary = editor.gizmo_handles[i]
		var tool := int(handle["tool"])
		per_tool[tool] = int(per_tool.get(tool, 0)) + 1

		var body := handle["body"] as StaticBody3D

		if body == null or body.collision_mask != 0:
			layers_ok = false

		if body == null or int(body.get_meta("gizmo_index", -1)) != i:
			metas_ok = false

		var axis := int(handle["axis"])

		if axis < -1 or axis > 2:
			axes_ok = false

	check(
		int(per_tool.get(editor.Tool.MOVE, 0)) == 4
		and int(per_tool.get(editor.Tool.ROTATE, 0)) == 4
		and int(per_tool.get(editor.Tool.SCALE, 0)) == 4,
		"each tool owns 3 axis handles + 1 centre handle"
	)
	check(layers_ok, "handle bodies never collide with anything themselves (mask 0)")
	check(metas_ok, "every handle body carries its gizmo_index metadata")
	check(axes_ok, "handle axes are -1 (free) or 0..2")

	# Object picking must not see the gizmo layer, and vice versa.
	check((editor.OBJECT_PICK_MASK & editor.GIZMO_LAYER) == 0, "object-pick mask excludes the gizmo layer")

	editor.free()
