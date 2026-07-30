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
#   - uploaded glTF test maps: marker naming, triplanar fallback material, environment,
#     and MeshInstance3D -> StaticBody3D -> trimesh CollisionShape3D generation
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
	await test_player_weapon_mass_model()
	test_surface_walk_wall_slide()
	test_ground_mode_modifier_policy()
	test_surface_walk_entry_aim_lock()
	test_charge_weapon_scaling()
	await test_grapple_multiwrap()
	await test_cylindrical_force_field()
	test_spinning_skybox()
	await test_uploaded_map_preparation()

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

const SCENE_ROOT := "res://Resources"


func test_scene_instantiation() -> void:
	print("- scene instantiation")

	var scene_paths := find_files_recursive(SCENE_ROOT, ".tscn")
	check(not scene_paths.is_empty(), "Resources contains discoverable scenes")

	for path in scene_paths:
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


func find_files_recursive(directory_path: String, extension: String) -> Array[String]:
	var found: Array[String] = []
	var directory := DirAccess.open(directory_path)

	if directory == null:
		return found

	directory.list_dir_begin()
	var entry := directory.get_next()

	while entry != "":
		var is_directory := directory.current_is_dir()

		if not entry.begins_with("."):
			var path := directory_path.path_join(entry)

			if is_directory:
				found.append_array(find_files_recursive(path, extension))
			elif entry.to_lower().ends_with(extension.to_lower()):
				found.append(path)

		entry = directory.get_next()

	directory.list_dir_end()
	found.sort()
	return found


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
	var network_manager_script := preload("res://Resources/Scripts/Networking/network_manager.gd")
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

	var nm_script := load("res://Resources/Scripts/Networking/network_manager.gd")
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


# --- Player + equipped-weapon mass -------------------------------------------------------

func test_player_weapon_mass_model() -> void:
	print("- movement: player + equipped-weapon mass")

	var player_scene := load("res://Resources/Objects/player.tscn") as PackedScene
	var player := player_scene.instantiate() as RigidBody3D if player_scene != null else null
	check(player != null, "runtime player instantiates for mass checks")

	if player == null:
		return

	root.add_child(player)
	await process_frame

	player.call("set_equipped_weapon_mass", 1.0)
	var reference_damp := player.linear_damp
	check(is_equal_approx(float(player.call("get_total_carried_mass")), 6.0), "5 body + 1 weapon reports 6 total mass")
	check(is_equal_approx(player.mass, 1.0), "reference loadout preserves physics mass 1")
	check(is_equal_approx(player.inertia.x, 0.3), "reference loadout preserves rotational inertia")

	player.call("set_equipped_weapon_mass", 2.0)
	check(is_equal_approx(float(player.call("get_total_carried_mass")), 7.0), "heavier weapon increases total carried mass")
	check(player.mass > 1.0, "heavier weapon increases rigid-body mass")
	check(player.inertia.x > 0.3, "heavier weapon increases rotational inertia")
	check(player.linear_damp < reference_damp, "heavier weapon loses zero-G drift more slowly")
	check(float(player.call("get_inverse_mass_response_scale")) < 1.0, "heavier weapon reduces manual movement response")

	var movement := PlayerMovementController.new()
	movement.player = player
	check(
		movement.get_mass_scaled_response_fraction(0.55) < 0.55,
		"heavier weapon slows zero-G grab/stabilization response"
	)
	movement.free()

	var min_weapon_mass := INF
	var max_weapon_mass := 0.0

	for weapon_id in WeaponInventory.get_weapon_ids():
		var weapon_scene := WeaponInventory.get_weapon_scene(weapon_id)
		var weapon := weapon_scene.instantiate() as Weapon if weapon_scene != null else null

		if weapon == null:
			continue

		var weapon_mass := weapon.get_weapon_mass()
		check(weapon_mass > 0.0, "weapon '%s' has positive carried mass" % weapon_id)
		min_weapon_mass = minf(min_weapon_mass, weapon_mass)
		max_weapon_mass = maxf(max_weapon_mass, weapon_mass)
		weapon.free()

	check(max_weapon_mass > min_weapon_mass, "weapon roster contains meaningfully different masses")

	var inventory := player.get_node_or_null("WeaponInventory") as WeaponInventory
	check(inventory != null, "runtime player exposes its weapon inventory")

	if inventory != null:
		inventory.unlocked_weapon_ids[&"railgun"] = true
		check(inventory.equip_weapon(&"railgun"), "equipping a registered weapon succeeds")
		check(
			is_equal_approx(float(player.call("get_equipped_weapon_mass")), 2.02),
			"inventory propagates the equipped weapon's mass to the player"
		)
		inventory.clear_mount()
		check(
			is_zero_approx(float(player.call("get_equipped_weapon_mass"))),
			"clearing the weapon removes its mass from the player"
		)

	player.queue_free()
	await process_frame


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


# --- Ground-mode modifier ---------------------------------------------------------------

func test_ground_mode_modifier_policy() -> void:
	print("- movement: ground-mode modifier policy")

	var movement := PlayerMovementController
	check(
		movement.is_ground_mode_allowed_for_modifier(true, false),
		"default-on: released modifier allows automatic ground mode"
	)
	check(
		not movement.is_ground_mode_allowed_for_modifier(true, true),
		"default-on: held modifier blocks ground mode"
	)
	check(
		not movement.is_ground_mode_allowed_for_modifier(false, false),
		"default-off: released modifier blocks ground mode"
	)
	check(
		movement.is_ground_mode_allowed_for_modifier(false, true),
		"default-off: held modifier allows ground mode"
	)
	check(
		GameSettings.DEFAULT_GROUND_MODE_ON_BY_DEFAULT,
		"ground mode preserves automatic mounting by default"
	)

	var ctrl_is_default := false

	for event in InputMap.action_get_events("ground_mode_modifier"):
		if event is InputEventKey:
			var key_event := event as InputEventKey
			var code := key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode
			ctrl_is_default = code == KEY_CTRL

	check(ctrl_is_default, "Ground Mode Modifier defaults to Ctrl")

	var original_default := GameSettings.ground_mode_on_by_default
	var player := RigidBody3D.new()
	var controller := PlayerMovementController.new()
	var ground := GroundMovementController.new()
	controller.player = player
	controller.ground = ground
	ground.player = player
	ground.coordinator = controller

	GameSettings.ground_mode_on_by_default = true
	Input.action_press("ground_mode_modifier")
	controller.movement_mode = PlayerMovementController.MovementMode.SURFACE_WALK
	controller.pending_spawn_ground_mode = true
	controller.enforce_ground_mode_input_policy()
	check(
		controller.movement_mode == PlayerMovementController.MovementMode.ZERO_G,
		"default-on: pressing the modifier immediately exits active ground mode"
	)
	check(
		not controller.pending_spawn_ground_mode,
		"a blocking modifier state cancels forced spawn mounting"
	)

	GameSettings.ground_mode_on_by_default = false
	Input.action_release("ground_mode_modifier")
	controller.movement_mode = PlayerMovementController.MovementMode.SURFACE_WALK
	controller.enforce_ground_mode_input_policy()
	check(
		controller.movement_mode == PlayerMovementController.MovementMode.ZERO_G,
		"default-off: releasing the modifier immediately exits active ground mode"
	)

	GameSettings.ground_mode_on_by_default = original_default
	Input.action_release("ground_mode_modifier")
	ground.free()
	controller.free()
	player.free()


# --- Surface-walk entry aim lock ---------------------------------------------------------

func test_surface_walk_entry_aim_lock() -> void:
	print("- movement: surface-walk entry aim lock")

	var player := RigidBody3D.new()
	var ground := GroundMovementController.new()
	ground.player = player

	# A steep view is the failure-prone case: projecting the BODY forward instead of this
	# view ray can turn a small feet/surface mismatch into a large yaw error.
	var surface_normal := Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(14.0)).normalized()
	var entry_view := Vector3(0.03, 0.99, -0.12).normalized()
	var surface_forward := ground.get_surface_forward_for_view(entry_view, surface_normal)
	var surface_pitch := ground.get_surface_pitch_for_view(entry_view, surface_normal)
	var body_basis := ground.make_surface_walk_basis(surface_forward, surface_normal)
	var rebuilt_view := -(body_basis * Basis.from_euler(Vector3(surface_pitch, 0.0, 0.0))).z
	check(
		rebuilt_view.angle_to(entry_view) < 0.00001,
		"surface body heading + camera pitch exactly rebuild the entry aim ray"
	)

	var rig := CameraRig.new()
	var view := Camera3D.new()
	player.add_child(rig)
	rig.add_child(view)
	root.add_child(player)
	rig.player = player
	rig.camera = view
	view.position = Vector3(0.2, 0.6, -0.15)

	var target := Vector3(7.0, 3.5, -18.0)
	rig.begin_world_aim_lock(target)
	player.transform.basis = Basis.from_euler(Vector3(0.7, -0.4, 0.9))
	rig.transform.basis = Basis.from_euler(Vector3(-0.2, 0.3, -0.15))
	rig.apply_world_aim_lock()

	var expected := (target - view.global_position).normalized()
	var actual := -view.global_transform.basis.z
	check(
		actual.angle_to(expected) < 0.00001,
		"camera hierarchy counter-rotates to keep the captured world target under the crosshair"
	)

	ground.free()
	player.free()


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

	var grapple = load("res://Resources/Scripts/Player/grapple_controller.gd").new()
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

	var shader = load("res://Resources/Materials/Shaders/Gameplay/skybox_fullbright.gdshader")
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


# --- Uploaded glTF test-map preparation ----------------------------------------------------

func test_uploaded_map_preparation() -> void:
	print("- uploaded glTF test-map preparation")

	var loaded := TestMapLoader.load_file("res://Resources/Models/Maps/Diamond.glb")
	check(bool(loaded.get("ok", false)), "an actual project GLB loads through GLTFDocument")

	var loaded_scene := loaded.get("scene") as Node3D

	if loaded_scene != null:
		check(
			int(loaded.get("collision_count", 0)) > 0,
			"loaded GLB receives runtime trimesh collision"
		)

		GameLaunch.set_uploaded_test_map("res://Resources/Models/Maps/Diamond.glb", loaded_scene, loaded)
		GameLaunch.map_configured = true
		GameLaunch.map_id = MapGenerator.UPLOADED_TEST_MAP_ID

		var generator := MapGenerator.new()
		generator.build_on_ready = false
		root.add_child(generator)
		generator.build_map()
		check(
			generator.get_node_or_null("GeneratedMap/UploadedTestMap") == loaded_scene,
			"MapGenerator installs the transient uploaded scene"
		)
		check(
			GameLaunch.uploaded_test_map_scene == null,
			"MapGenerator consumes the transient scene exactly once"
		)
		generator.free()
		await physics_frame

		GameLaunch.map_configured = false
		GameLaunch.map_id = MapGenerator.DEFAULT_MAP_ID
		GameLaunch.clear_uploaded_test_map()

	var map := Node3D.new()

	var geometry := MeshInstance3D.new()
	geometry.name = "BlockoutGeometry"
	geometry.mesh = BoxMesh.new()
	map.add_child(geometry)

	var textured := MeshInstance3D.new()
	textured.name = "TexturedGeometry"
	var textured_mesh := BoxMesh.new()
	var authored_material := StandardMaterial3D.new()
	var authored_image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	authored_image.fill(Color(0.8, 0.2, 0.1))
	authored_material.albedo_texture = ImageTexture.create_from_image(authored_image)
	textured_mesh.material = authored_material
	textured.mesh = textured_mesh
	textured.position = Vector3(3.0, 0.0, 0.0)
	map.add_child(textured)

	var spawn := Marker3D.new()
	spawn.name = "Spawn.001"
	spawn.position = Vector3(0.0, 1.0, 2.0)
	map.add_child(spawn)

	var light_marker := Node3D.new()
	light_marker.name = "Light"
	map.add_child(light_marker)

	var visual_only := Node3D.new()
	visual_only.name = "no_collision_decor"
	var visual_mesh := MeshInstance3D.new()
	visual_mesh.mesh = BoxMesh.new()
	visual_only.add_child(visual_mesh)
	map.add_child(visual_only)

	var result := TestMapLoader.prepare_scene(map)
	check(bool(result.get("ok", false)), "uploaded map preparation succeeds")
	check(int(result.get("mesh_count", 0)) == 2, "only playable geometry is counted")
	check(int(result.get("collision_count", 0)) == 2, "every playable mesh gets collision")
	check(int(result.get("spawn_count", 0)) == 1, "Spawn.001 is recognized as a spawn marker")
	check(int(result.get("light_count", 0)) == 1, "Light marker generates a usable light")
	check(
		int(result.get("blockout_material_count", 0)) == 1,
		"only the untextured mesh gets the triplanar blockout material"
	)
	check(geometry.material_override is ShaderMaterial, "untextured geometry uses the blockout shader")
	check(textured.material_override == null, "authored albedo texture is preserved")
	check(
		geometry.get_node_or_null("StaticBody3D/CollisionShape3D") is CollisionShape3D,
		"collider hierarchy is MeshInstance3D -> StaticBody3D -> CollisionShape3D"
	)

	var collision := geometry.get_node_or_null("StaticBody3D/CollisionShape3D") as CollisionShape3D
	check(
		collision != null and collision.shape is ConcavePolygonShape3D,
		"uploaded geometry uses a trimesh collision shape"
	)
	check(
		visual_mesh.get_node_or_null("StaticBody3D") == null,
		"no_collision branches remain visual-only"
	)
	var generated_light := light_marker.get_node_or_null("GeneratedLight") as OmniLight3D
	check(generated_light != null, "empty Light marker becomes an OmniLight3D")
	check(
		generated_light != null
		and is_equal_approx(generated_light.light_energy, TestMapLoader.TEST_LIGHT_ENERGY),
		"generated omni light uses energy 16"
	)
	check(
		generated_light != null
		and is_equal_approx(generated_light.omni_range, TestMapLoader.TEST_LIGHT_MAX_RANGE),
		"generated omni light uses maximum range 4096"
	)
	check(map.get_node_or_null("TestMapEnvironment") is WorldEnvironment, "uploaded map gets ambient environment lighting")

	root.add_child(map)
	await physics_frame
	check(get_nodes_in_group("spawn_team_a").has(spawn), "uploaded spawn joins spawn_team_a in-tree")
	check(spawn.global_position.is_equal_approx(Vector3(0.0, 1.0, 2.0)), "uploaded spawn transform is preserved")

	map.free()
	await physics_frame
