extends RigidBody3D

@export var linear_damp_value: float = 0.0
@export var angular_damp_value: float = 1.2

# Uniform (isotropic) rotational inertia. The capsule's natural inertia is anisotropic, which
# made torque-driven roll spin cleanly only around the body's own axes; once the look/neck tilts
# off them, roll precessed instead of banking. A uniform value rolls the same around any axis.
# 0.3 matches the capsule's old perpendicular inertia, so roll feel is unchanged.
@export var rotational_inertia: float = 0.3

@export var network_send_rate: float = 30.0
@export var network_interpolation_speed: float = 18.0
# When packets from a remote player are late/dropped, keep gliding them along their last
# known velocity instead of freezing in place (zero-G motion is inertial, so this predicts
# well). Capped by network_extrapolation_max_time so a long gap can't fling them away.
@export var network_extrapolation_enabled: bool = true
@export var network_extrapolation_max_time: float = 0.25

@export var body_slam_min_speed: float = 3.0
@export var body_slam_impulse_multiplier: float = 1.35
@export var body_slam_max_impulse: float = 18.0
@export var body_slam_local_cooldown: float = 0.2
@export var weapon_aim_reticle_range: float = 200.0
@export var weapon_aim_reticle_use_world_raycast: bool = false

var buy_menu_open: bool = false
# True while the pause/settings/admin menu is open. Locks input the same way the buy menu
# does and stops the mouse from re-capturing on click so the menu stays usable.
var external_menu_open: bool = false
var is_dead: bool = false

var peer_id: int = 0
var is_local_player: bool = false
var network_manager: Node

var network_send_timer: float = 0.0

var network_target_transform: Transform3D
var network_target_linear_velocity: Vector3 = Vector3.ZERO
var network_target_angular_velocity: Vector3 = Vector3.ZERO
var has_network_target: bool = false
# Monotonic per-sender packet counter. Unreliable state packets can arrive out of order;
# applying an older one after a newer one rubber-bands the replica, so stale ones drop.
var network_send_seq: int = 0
var network_last_received_seq: int = -1
# Seconds since the last authoritative state packet for this remote player; drives how far
# we extrapolate before giving up.
var network_time_since_update: float = 0.0
# Cached once: true only on a windowless dedicated server, which has no viewer to smooth for.
var network_is_headless_server: bool = false

var last_body_slam_time_by_target_peer_id: Dictionary = {}

@onready var camera: Camera3D = get_node_or_null("CameraRig/Camera3D") as Camera3D
@onready var movement_controller: PlayerMovementController = get_node_or_null("MovementController") as PlayerMovementController
@onready var suit_boosters: SuitBoosterController = get_node_or_null("SuitBoosters") as SuitBoosterController
@onready var hud_controller: PlayerHUDController = get_node_or_null("PlayerHUD") as PlayerHUDController
@onready var health: PlayerHealth = get_node_or_null("PlayerHealth") as PlayerHealth
@onready var impact_controller: PlayerImpactController = get_node_or_null("ImpactController") as PlayerImpactController
@onready var weapon_inventory: WeaponInventory = get_node_or_null("WeaponInventory") as WeaponInventory


func _ready() -> void:
	add_to_group("players")
	gravity_scale = 0.0
	linear_damp = linear_damp_value
	angular_damp = angular_damp_value
	inertia = Vector3.ONE * rotational_inertia
	can_sleep = false
	continuous_cd = true
	
	contact_monitor = true
	max_contacts_reported = max(max_contacts_reported, 12)
	
	network_target_transform = global_transform
	network_is_headless_server = DisplayServer.get_name() == "headless"

	if camera != null:
		camera.current = false
		camera.fov = GameSettings.fov

	if hud_controller == null:
		push_error("PlayerHUD node is missing or does not have player_hud_controller.gd attached.")
	else:
		hud_controller.setup(self)
	
	if health == null:
		push_warning("PlayerHealth node is missing; weapon damage will be ignored.")
	else:
		health.setup()
		connect_health_signals()
	
	if movement_controller == null:
		push_error("MovementController node is missing or does not have player_movement_controller.gd attached.")
	else:
		movement_controller.setup(self, hud_controller)
	
	if suit_boosters == null:
		push_error("SuitBoosters node is missing or does not have suit_booster_controller.gd attached.")
	else:
		suit_boosters.setup(self)
	
	if impact_controller == null:
		push_warning("ImpactController node is missing or does not have impact_controller.gd attached.")
	else:
		impact_controller.setup(self, hud_controller)
	
	if weapon_inventory == null:
		push_warning("WeaponInventory node is missing; weapon purchases will be unavailable.")
	else:
		weapon_inventory.setup(self)


func set_multiplayer_player(new_peer_id: int, new_is_local_player: bool, new_network_manager: Node) -> void:
	peer_id = new_peer_id
	is_local_player = new_is_local_player
	network_manager = new_network_manager
	
	set_multiplayer_authority(peer_id)
	
	freeze = not is_local_player
	
	if camera != null:
		camera.current = is_local_player

	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if health != null:
			_on_health_changed(health.current_health, health.max_health)

	# Only the local player's HUD should be visible (each player instance builds one).
	if hud_controller != null and hud_controller.has_method("set_hud_active"):
		hud_controller.set_hud_active(is_local_player)

	# Remote replicas only interpolate their network target (_physics_process); the aim
	# reticle (_process), camera-rig feel, and viewmodel animator are local-player-only
	# work that would otherwise tick per replica — including on the dedicated server.
	if not is_local_player:
		set_process(false)

		var camera_rig := get_node_or_null("CameraRig")

		if camera_rig != null:
			camera_rig.set_physics_process(false)

		var weapon_mount := get_node_or_null("CameraRig/Camera3D/WeaponMount")

		if weapon_mount != null:
			weapon_mount.set_process(false)

	print("Player ", peer_id, " multiplayer setup. Local: ", is_local_player)


# Replicates this player's weapon shot so other clients can draw the SAME weapon's tracer
# (weapon_id picks which per-gun tracer scene the relay spawns — see NetworkManager).
func report_weapon_shot(
	origin: Vector3,
	end: Vector3,
	did_hit: bool,
	normal: Vector3,
	weapon_id: String
) -> void:
	if not is_local_player:
		return

	if is_dead:
		return

	if network_manager != null and network_manager.has_method("broadcast_weapon_shot"):
		network_manager.call("broadcast_weapon_shot", peer_id, origin, end, did_hit, normal, weapon_id)


# Replicates a fired projectile so other clients spawn a cosmetic copy of the bolt.
func report_projectile_shot(origin: Vector3, velocity: Vector3) -> void:
	if not is_local_player:
		return

	if is_dead:
		return

	if network_manager != null and network_manager.has_method("broadcast_projectile_shot"):
		network_manager.call("broadcast_projectile_shot", peer_id, origin, velocity)


# Mirrors a finished reload into the server's ammo ledger (ServerEconomy) so hit claims
# keep validating after the mag is refilled.
func report_weapon_reloaded(weapon_id: StringName) -> void:
	if not is_local_player or not has_active_network_session():
		return

	if network_manager != null and "server_economy" in network_manager:
		var economy = network_manager.server_economy

		if economy != null and economy.has_method("notify_weapon_reload"):
			economy.call("notify_weapon_reload", String(weapon_id))


# Shown to the attacker when the server confirms their shot damaged someone.
# `is_kill` is true when this shot dropped the target to zero health → red hitmarker.
func show_hitmarker(is_kill: bool = false) -> void:
	if is_local_player and hud_controller != null and hud_controller.has_method("show_hitmarker"):
		hud_controller.show_hitmarker(is_kill)


# Weapon recoil kick to the aim (climb + side). Smoothed in and auto-recentered by the
# movement controller; the player's counter-pull is consumed 1:1.
func apply_camera_recoil(vertical_degrees: float, horizontal_degrees: float) -> void:
	if movement_controller != null:
		movement_controller.apply_look_recoil(vertical_degrees, horizontal_degrees)


func update_weapon_ammo_hud(current_ammo: int, reserve_ammo: int, reloading: bool) -> void:
	if is_local_player and hud_controller != null and hud_controller.has_method("update_ammo"):
		hud_controller.update_ammo(current_ammo, reserve_ammo, reloading)


func get_peer_id() -> int:
	return peer_id


func _input(event: InputEvent) -> void:
	if not is_local_player:
		return

	if buy_menu_open or is_input_locked():
		if movement_controller != null:
			movement_controller.clear_mouse_motion()
			movement_controller.clear_free_look_mouse_motion()
		return

	var surface_walk_active := is_surface_walk_mode_active()

	if event is InputEventMouseMotion:
		if movement_controller != null:
			if is_free_look_active() and not surface_walk_active:
				movement_controller.add_free_look_mouse_motion(event.relative)
			else:
				movement_controller.add_mouse_motion(event.relative)

	if weapon_inventory != null:
		if event.is_action_pressed("reload"):
			weapon_inventory.request_reload()
		elif event.is_action_pressed("weapon_slot_1"):
			weapon_inventory.try_quick_swap(0)
		elif event.is_action_pressed("weapon_slot_2"):
			weapon_inventory.try_quick_swap(1)
		elif event.is_action_pressed("weapon_slot_3"):
			weapon_inventory.try_quick_swap(2)
		elif event.is_action_pressed("weapon_slot_4"):
			weapon_inventory.try_quick_swap(3)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	if event is InputEventMouseButton and event.pressed and not external_menu_open and not buy_menu_open:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if not is_local_player:
		return
	
	if is_dead:
		if hud_controller != null:
			hud_controller.update_weapon_aim_reticle(delta, camera, Vector3.ZERO, true)
		return

	update_weapon_aim_reticle(delta)


func _physics_process(delta: float) -> void:
	if not is_local_player:
		update_remote_network_state(delta)
		return
	
	if is_dead:
		if movement_controller != null:
			movement_controller.clear_mouse_motion()
			movement_controller.clear_free_look_mouse_motion()

		if weapon_inventory != null:
			weapon_inventory.update(delta, false)

		if suit_boosters != null:
			suit_boosters.physics_update(delta, false, false)

		if hud_controller != null:
			hud_controller.update_velocity_indicator(linear_velocity)
			hud_controller.update_reticle(delta, false, true)
			hud_controller.update_push_direction_arrow(delta, false, Vector3.ZERO, camera)

		# Keep replicating the free-floating corpse so its drift and any shoves it takes
		# are seen by every other peer.
		update_network_send(delta)
		return

	if impact_controller != null:
		impact_controller.physics_update(delta)
	
	var input_locked := is_input_locked()
	var movement_locked := input_locked or buy_menu_open
	var surface_walk_active := is_surface_walk_mode_active()
	var free_look_active := is_free_look_active()
	
	if surface_walk_active:
		free_look_active = false
	
	var surface_in_range := false
	var grabbing := false
	var show_ctrl_push_arrow := false
	var ctrl_push_direction := Vector3.ZERO
	
	if movement_controller != null:
		surface_in_range = movement_controller.is_surface_in_interaction_range()
		show_ctrl_push_arrow = movement_controller.should_show_ctrl_push_arrow(
			buy_menu_open,
			free_look_active,
			movement_locked
		)
		ctrl_push_direction = movement_controller.get_predicted_ctrl_push_direction()
	
	if hud_controller != null:
		hud_controller.update_velocity_indicator(linear_velocity)
		hud_controller.update_reticle(delta, surface_in_range, buy_menu_open or input_locked)
		hud_controller.update_push_direction_arrow(
			delta,
			show_ctrl_push_arrow,
			ctrl_push_direction,
			camera
		)
	
	if movement_controller != null:
		movement_controller.physics_update(delta, free_look_active, movement_locked)
		grabbing = movement_controller.is_grabbing_wall()
	
	if weapon_inventory != null:
		weapon_inventory.update(delta, not buy_menu_open and not input_locked)
	
	if suit_boosters != null:
		var boosters_allowed := not buy_menu_open and not input_locked and not is_surface_walk_mode_active()
		
		suit_boosters.physics_update(delta, boosters_allowed, grabbing)
		
		if hud_controller != null:
			hud_controller.update_booster_ui(
				suit_boosters.get_has_suit_boosters(),
				suit_boosters.get_booster_fuel(),
				suit_boosters.get_max_booster_fuel()
			)
	
	update_network_send(delta)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not is_local_player:
		return
	
	if is_dead:
		return

	if impact_controller != null and not is_surface_walk_mode_active():
		impact_controller.integrate_forces(state)
	
	if movement_controller != null:
		movement_controller.integrate_forces(state)
	
	detect_player_body_slam_contacts(state)


func detect_player_body_slam_contacts(state: PhysicsDirectBodyState3D) -> void:
	if network_manager == null:
		return
	
	var current_speed := linear_velocity.length()
	
	if current_speed < body_slam_min_speed:
		return
	
	for contact_index in range(state.get_contact_count()):
		var collider_object := state.get_contact_collider_object(contact_index)
		var hit_player := find_player_from_collider(collider_object)
		
		if hit_player == null:
			continue
		
		if hit_player == self:
			continue
		
		if not hit_player.has_method("get_peer_id"):
			continue
		
		var target_peer_id: int = int(hit_player.call("get_peer_id"))
		
		if target_peer_id == peer_id or target_peer_id == 0:
			continue
		
		if not can_send_body_slam_to_target(target_peer_id):
			continue
		
		var impulse := linear_velocity * body_slam_impulse_multiplier
		
		if impulse.length() > body_slam_max_impulse:
			impulse = impulse.normalized() * body_slam_max_impulse
		
		var contact_position := state.get_contact_collider_position(contact_index)
		
		mark_body_slam_sent(target_peer_id)
		
		if network_manager.has_method("request_body_slam"):
			network_manager.call(
				"request_body_slam",
				peer_id,
				target_peer_id,
				impulse,
				contact_position
			)
		
		return


func can_send_body_slam_to_target(target_peer_id: int) -> bool:
	var current_time := Time.get_ticks_msec() / 1000.0
	
	if last_body_slam_time_by_target_peer_id.has(target_peer_id):
		var last_time: float = last_body_slam_time_by_target_peer_id[target_peer_id]
		
		if current_time - last_time < body_slam_local_cooldown:
			return false
	
	return true


func mark_body_slam_sent(target_peer_id: int) -> void:
	last_body_slam_time_by_target_peer_id[target_peer_id] = Time.get_ticks_msec() / 1000.0


func find_player_from_collider(collider: Object) -> Node:
	if collider == null:
		return null
	
	var current = collider
	
	while current != null:
		if current is Node and current.has_method("get_peer_id"):
			return current
		
		if current is Node:
			current = current.get_parent()
		else:
			break
	
	return null


func apply_network_body_slam_impulse(impulse: Vector3, contact_position: Vector3) -> void:
	if not is_local_player:
		return

	# Note: dead bodies are intentionally NOT excluded here — a corpse can be shoved around.

	sleeping = false
	
	if movement_controller != null and movement_controller.is_surface_walk_active():
		movement_controller.exit_surface_walk_mode()
	
	var local_contact_position := contact_position - global_position
	
	if local_contact_position.length() > 4.0:
		apply_central_impulse(impulse)
	else:
		apply_impulse(impulse, local_contact_position)
	
	print("Applied body slam impulse: ", impulse)


# Called by RoundManager (via RPC) at the start of each round: snap back to spawn,
# kill momentum, and reset health. Safe to call before a PlayerHealth node exists.
# `ground_mode` drops the local player into surface-walk on the nearest surface at the spawn.
func reset_for_round(spawn_transform: Transform3D, ground_mode: bool = true) -> void:
	is_dead = false

	set_death_glow_active(false)
	set_health_bar_visible(true)

	if hud_controller != null and hud_controller.has_method("set_dead_screen_active"):
		hud_controller.set_dead_screen_active(false)

	if movement_controller != null and movement_controller.is_surface_walk_active():
		movement_controller.exit_surface_walk_mode()

	global_transform = spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	reset_physics_interpolation()

	network_target_transform = spawn_transform
	network_target_linear_velocity = Vector3.ZERO
	network_target_angular_velocity = Vector3.ZERO

	if health != null and health.has_method("reset_health"):
		health.reset_health()

	if suit_boosters != null and suit_boosters.has_method("refill_booster_fuel"):
		suit_boosters.refill_booster_fuel()

	if impact_controller != null:
		impact_controller.ignore_impacts_briefly()

	if weapon_inventory != null:
		weapon_inventory.reset_state()

	# Drop the local player onto the nearest surface at the spawn (all game modes). Remote
	# copies just take the transform; they replicate the walked orientation over the network.
	if ground_mode:
		request_spawn_ground_mode()


# Ask the movement controller to drop the local player onto the nearest surface at the spawn
# (all game modes). No-op for remote copies, which just replicate the walked transform.
func request_spawn_ground_mode() -> void:
	if is_local_player and movement_controller != null and movement_controller.has_method("request_spawn_ground_mode"):
		movement_controller.request_spawn_ground_mode()


# FFA loadout: called (server-driven) each life to arm this player with the random gun the
# server chose and top up boosters to the match's fuel limit. Runs on the owning client
# (its player is the local one) and offline; remote copies never receive it.
func apply_ffa_loadout(weapon_id: StringName, booster_fuel: float) -> void:
	if suit_boosters != null and suit_boosters.has_method("grant_with_fuel"):
		suit_boosters.grant_with_fuel(booster_fuel)

	if weapon_inventory != null and weapon_inventory.has_method("set_exclusive_weapon"):
		weapon_inventory.set_exclusive_weapon(weapon_id)

	update_booster_hud()


# Server-confirmed full heal (the "heal on kill" rule). Runs on every lobby member's copy so
# health stays consistent everywhere (scoreboard alive-flags, overhead bars, dead grace).
func apply_full_heal() -> void:
	if health != null:
		health.reset_health()


# Server-granted ammo refill (the "ammo on kill" rule). Only meaningful on the owning client.
func refill_all_ammo() -> void:
	if weapon_inventory != null and weapon_inventory.has_method("refill_all_ammo"):
		weapon_inventory.refill_all_ammo()


func submit_plasma_explosion_hit(
	target: Node,
	damage: float,
	impulse: Vector3,
	explosion_position: Vector3,
	explosion_radius: float,
	shot_origin: Vector3,
	shot_direction: Vector3,
	weapon_id: String
) -> void:
	if target == null:
		return

	var target_peer_id := get_peer_id_from_node(target)

	if has_active_network_session() and target_peer_id != 0:
		if network_manager.has_method("request_plasma_explosion_hit"):
			network_manager.call(
				"request_plasma_explosion_hit",
				peer_id,
				target_peer_id,
				damage,
				impulse,
				explosion_position,
				explosion_radius,
				shot_origin,
				shot_direction,
				weapon_id
			)

		return

	if damage > 0.0 and target.has_method("apply_weapon_damage"):
		target.call("apply_weapon_damage", damage, peer_id)

	if not impulse.is_zero_approx() and target.has_method("apply_network_plasma_impulse"):
		target.call("apply_network_plasma_impulse", impulse)


func submit_weapon_hit(
	target: Node,
	damage: float,
	hit_position: Vector3,
	shot_origin: Vector3,
	shot_direction: Vector3
) -> void:
	if is_dead:
		return

	if target == null:
		return
	
	if target == self:
		return
	
	var target_peer_id := get_peer_id_from_node(target)

	if target_peer_id == peer_id:
		return

	if has_active_network_session() and target_peer_id != 0:
		if network_manager.has_method("request_weapon_hit"):
			network_manager.call(
				"request_weapon_hit",
				peer_id,
				target_peer_id,
				damage,
				hit_position,
				shot_origin,
				shot_direction,
				String(get_equipped_weapon_id())
			)

		return
	
	if target.has_method("apply_weapon_damage"):
		target.call("apply_weapon_damage", damage, peer_id)

	# Local physics targets (test-arena drones, props) take a shove scaled by the round —
	# off-centre hits spin them. Players are excluded (they have their own hit pipeline).
	if target is RigidBody3D and not target.has_method("get_peer_id"):
		var body := target as RigidBody3D
		body.apply_impulse(shot_direction.normalized() * damage * 0.06, hit_position - body.global_position)


func apply_weapon_damage(damage: float, attacker_peer_id: int = 0) -> void:
	if health == null:
		return
	
	if health.apply_damage(damage, attacker_peer_id):
		if is_local_player and health.current_health > 0.0 and hud_controller != null and hud_controller.has_method("show_hurt_effect"):
			var damage_ratio := damage / maxf(health.max_health, 1.0)
			hud_controller.show_hurt_effect(damage_ratio)

		print(
			"Player ",
			peer_id,
			" took ",
			damage,
			" damage from ",
			attacker_peer_id,
			". Health: ",
			health.current_health,
			"/",
			health.max_health
		)


func apply_network_plasma_impulse(impulse: Vector3) -> void:
	if has_active_network_session() and not is_local_player:
		return

	sleeping = false

	if movement_controller != null and movement_controller.is_surface_walk_active():
		movement_controller.exit_surface_walk_mode()

	apply_central_impulse(impulse)


func get_peer_id_from_node(node: Node) -> int:
	if node == null:
		return 0
	
	if node.has_method("get_peer_id"):
		return int(node.call("get_peer_id"))
	
	return 0


func has_active_network_session() -> bool:
	if network_manager != null and network_manager.has_method("has_active_multiplayer_peer"):
		return bool(network_manager.call("has_active_multiplayer_peer"))
	
	var peer := multiplayer.multiplayer_peer
	
	if peer == null:
		return false
	
	return not (peer is OfflineMultiplayerPeer)


func connect_health_signals() -> void:
	if health == null:
		return
	
	if not health.health_changed.is_connected(_on_health_changed):
		health.health_changed.connect(_on_health_changed)
	
	if not health.died.is_connected(_on_died):
		health.died.connect(_on_died)
	
	_on_health_changed(health.current_health, health.max_health)


func _on_health_changed(current_health: float, max_health: float) -> void:
	if hud_controller != null and is_local_player:
		hud_controller.update_health(current_health, max_health)

	# Remote copies mirror their health into the overhead bar (no-op before it exists).
	update_health_bar_ratio()


func _on_died(attacker_peer_id: int) -> void:
	is_dead = true

	# The corpse stays an active rigid body: keep its current momentum (don't zero
	# velocity) and keep it awake so it free-floats and can be shoved around.
	sleeping = false

	if movement_controller != null:
		# Detach from any surface so the body tumbles freely, then drop all input.
		if movement_controller.is_surface_walk_active():
			movement_controller.exit_surface_walk_mode()
		movement_controller.clear_mouse_motion()
		movement_controller.clear_free_look_mouse_motion()

	if weapon_inventory != null:
		weapon_inventory.release()

	# Runs on every peer's copy of this player, so the red "disabled" glow shows for everyone.
	set_death_glow_active(true)
	set_health_bar_visible(false)

	if is_local_player and hud_controller != null and hud_controller.has_method("set_dead_screen_active"):
		hud_controller.set_dead_screen_active(true)

	print("Player ", peer_id, " died. Attacker: ", attacker_peer_id)


# Adds/removes the red "disabled" indicator on the corpse: an ambient red OmniLight plus a
# red emissive tint on the body mesh. Called from _on_died / reset_for_round, which run on
# every peer's copy of this player, so all clients see (and are lit by) the dead body.
# One material shared by every player's corpse, built once and reused forever. Building a
# fresh lit+emissive StandardMaterial3D per death forced Forward+ to compile that shader
# variant synchronously the first time any player died in a session, causing a visible
# stutter (and, since every peer runs this on death, a matching network-interpolation
# "snap" for everyone). Unshaded matches the tracer effect's material mode, which is
# already warmed up from the first shot fired, so this path costs nothing to compile.
static var _shared_death_glow_material: StandardMaterial3D


static func get_death_glow_material() -> StandardMaterial3D:
	if _shared_death_glow_material == null:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.45, 0.02, 0.02)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.08, 0.08)
		mat.emission_energy_multiplier = 2.5
		_shared_death_glow_material = mat

	return _shared_death_glow_material


# --- Overhead health bar ----------------------------------------------------------------
# Billboard health bar above every REMOTE player's head (replaces the old team-indicator
# dot): green = teammate of this machine's player, red = enemy (always red in FFA). Colored
# by NetworkManager.refresh_player_health_bars after spawns and hidden while dead. Health is
# already replicated — the server-confirmed damage/heal RPCs run on every lobby member's
# copy of the player — so the bar just mirrors this copy's PlayerHealth. One shared
# ShaderMaterial (same shader-compile-hitch reason as the death glow); the per-player fill
# and color are instance shader parameters. Depth-tested, so it can't act as a wallhack.

const HEALTH_BAR_HEIGHT := 1.45
const HEALTH_BAR_SIZE := Vector2(0.95, 0.11)
const HEALTH_BAR_SHADER := preload("res://shaders/health_bar.gdshader")

static var _health_bar_material: ShaderMaterial

var health_bar: MeshInstance3D


static func get_health_bar_material() -> ShaderMaterial:
	if _health_bar_material == null:
		_health_bar_material = ShaderMaterial.new()
		_health_bar_material.shader = HEALTH_BAR_SHADER

	return _health_bar_material


func set_health_bar_friendly(friendly: bool) -> void:
	if is_local_player:
		if health_bar != null:
			health_bar.visible = false

		return

	if health_bar == null:
		health_bar = MeshInstance3D.new()
		health_bar.name = "HealthBar"
		health_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		var quad := QuadMesh.new()
		quad.size = HEALTH_BAR_SIZE
		health_bar.mesh = quad
		health_bar.material_override = get_health_bar_material()
		health_bar.position = Vector3(0.0, HEALTH_BAR_HEIGHT, 0.0)
		add_child(health_bar)

	var color := Color(0.2, 0.95, 0.35) if friendly else Color(1.0, 0.2, 0.16)
	health_bar.set_instance_shader_parameter("bar_color", color)
	update_health_bar_ratio()
	health_bar.visible = not is_dead


func set_health_bar_visible(value: bool) -> void:
	if health_bar != null:
		health_bar.visible = value and not is_local_player


func update_health_bar_ratio() -> void:
	if health_bar == null or health == null:
		return

	health_bar.set_instance_shader_parameter("health_ratio", health.get_health_ratio())


func set_death_glow_active(active: bool) -> void:
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	var glow := get_node_or_null("DeathGlow") as OmniLight3D

	if active:
		if glow == null:
			glow = OmniLight3D.new()
			glow.name = "DeathGlow"
			glow.light_color = Color(1.0, 0.12, 0.12)
			glow.light_energy = 3.0
			glow.omni_range = 9.0
			glow.shadow_enabled = false
			add_child(glow)

		if mesh != null:
			mesh.material_override = get_death_glow_material()
	else:
		if glow != null:
			glow.queue_free()

		if mesh != null:
			mesh.material_override = null


func update_remote_network_state(delta: float) -> void:
	if not has_network_target:
		return

	network_time_since_update += delta

	linear_velocity = network_target_linear_velocity
	angular_velocity = network_target_angular_velocity

	# A windowless dedicated server has no viewer to smooth for, so keep its authoritative
	# body on the freshest received transform (no extrapolation, no interpolation). A
	# listen-server host DOES render, so it falls through and smooths like any client.
	if multiplayer.multiplayer_peer != null and multiplayer.is_server() and network_is_headless_server:
		global_transform = network_target_transform
		return

	# Dead-reckon the target forward along its last velocity to cover packet gaps, so a late
	# or dropped packet keeps the player gliding instead of freezing. The next packet snaps
	# the target back to authoritative truth via receive_network_state(), correcting drift.
	if network_extrapolation_enabled and network_time_since_update <= network_extrapolation_max_time:
		network_target_transform.origin += network_target_linear_velocity * delta

		var angular := network_target_angular_velocity

		if angular.length() > 0.0001:
			network_target_transform.basis = (
				network_target_transform.basis.rotated(angular.normalized(), angular.length() * delta)
			).orthonormalized()

	var weight := 1.0 - exp(-network_interpolation_speed * delta)
	var new_position := global_transform.origin.lerp(network_target_transform.origin, weight)
	var new_basis := global_transform.basis.slerp(network_target_transform.basis, weight).orthonormalized()

	global_transform = Transform3D(new_basis, new_position)


func receive_network_state(
	new_transform: Transform3D,
	new_linear_velocity: Vector3,
	new_angular_velocity: Vector3,
	state_seq: int
) -> void:
	if state_seq <= network_last_received_seq:
		return   # out-of-order packet; a newer state has already been applied

	network_last_received_seq = state_seq
	network_target_transform = new_transform
	network_target_linear_velocity = new_linear_velocity
	network_target_angular_velocity = new_angular_velocity
	has_network_target = true
	network_time_since_update = 0.0


func update_network_send(delta: float) -> void:
	if network_manager == null:
		return
	
	if not has_active_network_session():
		return
	
	if network_send_rate <= 0.0:
		return
	
	network_send_timer -= delta
	
	if network_send_timer > 0.0:
		return
	
	network_send_timer = 1.0 / network_send_rate
	network_send_seq += 1

	if network_manager.has_method("submit_local_player_state"):
		network_manager.call(
			"submit_local_player_state",
			peer_id,
			global_transform,
			linear_velocity,
			angular_velocity,
			network_send_seq
		)


func update_weapon_aim_reticle(delta: float) -> void:
	if hud_controller == null:
		return
	
	if camera == null or weapon_inventory == null:
		hud_controller.update_weapon_aim_reticle(delta, camera, Vector3.ZERO, true)
		return
	
	if buy_menu_open or not weapon_inventory.has_equipped_weapon():
		hud_controller.update_weapon_aim_reticle(delta, camera, Vector3.ZERO, true)
		return
	
	var origin := weapon_inventory.get_weapon_aim_origin()
	var direction := weapon_inventory.get_weapon_aim_direction()
	
	if direction.length() < 0.001:
		hud_controller.update_weapon_aim_reticle(delta, camera, Vector3.ZERO, true)
		return
	
	var aim_point := get_weapon_aim_visual_point(origin, direction.normalized())
	hud_controller.update_weapon_aim_reticle(delta, camera, aim_point, false)


func get_weapon_aim_visual_point(origin: Vector3, direction: Vector3) -> Vector3:
	var end := origin + direction * weapon_aim_reticle_range
	
	if not weapon_aim_reticle_use_world_raycast:
		return end
	
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	if self is CollisionObject3D:
		query.exclude = [get_rid()]
	
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	
	if result.is_empty():
		return end
	
	return result["position"]


func is_free_look_active() -> bool:
	if is_input_locked():
		return false
	
	if is_surface_walk_mode_active():
		return false
	
	return Input.is_action_pressed("free_look")


func is_input_locked() -> bool:
	if is_dead:
		return true

	if external_menu_open:
		return true

	if is_surface_walk_mode_active():
		return false
	
	return is_immobilized()


func is_immobilized() -> bool:
	if impact_controller == null:
		return false
	
	return impact_controller.is_immobilized()


func is_surface_walk_mode_active() -> bool:
	if movement_controller == null:
		return false

	return movement_controller.is_surface_walk_active()


# Braced = recoil should kick the weapon (normal FPS), not the body. True when
# standing on a surface or gripping a wall; false while free-floating in zero-G.
func is_recoil_braced() -> bool:
	if movement_controller == null:
		return false

	return is_surface_walk_mode_active() or movement_controller.is_grabbing_wall()


func set_buy_menu_open(value: bool) -> void:
	if not is_local_player:
		return
	
	buy_menu_open = value
	
	if movement_controller != null:
		movement_controller.clear_mouse_motion()
		movement_controller.clear_free_look_mouse_motion()
	
	if weapon_inventory != null and value:
		weapon_inventory.release()
	
	if value:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Called by the pause/settings/admin menu. Locks player input (via is_input_locked) and
# clears any buffered look motion so the camera doesn't lurch when the menu closes.
func set_external_menu_open(value: bool) -> void:
	if not is_local_player:
		return

	external_menu_open = value

	if movement_controller != null:
		movement_controller.clear_mouse_motion()
		movement_controller.clear_free_look_mouse_motion()

	if value and weapon_inventory != null:
		weapon_inventory.release()


func apply_grab_distance_upgrade(level: int) -> void:
	if movement_controller == null:
		return
	
	movement_controller.apply_grab_distance_upgrade(level)


func get_grab_distance_level() -> int:
	if movement_controller == null:
		return 0
	
	return movement_controller.get_grab_distance_level()


# One shared refresh for every path that changes booster state (purchase, refill, loadout).
func update_booster_hud() -> void:
	if is_local_player and hud_controller != null and suit_boosters != null:
		hud_controller.update_booster_ui(
			suit_boosters.get_has_suit_boosters(),
			suit_boosters.get_booster_fuel(),
			suit_boosters.get_max_booster_fuel()
		)


func purchase_suit_boosters() -> void:
	if suit_boosters == null:
		return

	suit_boosters.purchase_suit_boosters()
	update_booster_hud()


func get_has_suit_boosters() -> bool:
	if suit_boosters == null:
		return false
	
	return suit_boosters.get_has_suit_boosters()


# Shop pass-throughs. Weapon ids are WeaponInventory's SLOT_IDS ("minigun", "railgun",
# "rifle", "plasma_cannon", ...); the buy menu's weapon group names match them 1:1.
func purchase_weapon(weapon_id: StringName) -> bool:
	if weapon_inventory == null:
		return false

	return weapon_inventory.purchase_weapon(weapon_id)


func has_weapon(weapon_id: StringName) -> bool:
	if weapon_inventory == null:
		return false

	return weapon_inventory.has_weapon(weapon_id)


func get_equipped_weapon_id() -> StringName:
	if weapon_inventory == null:
		return &""
	
	return weapon_inventory.get_equipped_weapon_id()


func suppress_launch_impact() -> void:
	if impact_controller != null:
		impact_controller.ignore_impacts_briefly()


func refill_booster_fuel() -> void:
	if suit_boosters == null:
		return

	suit_boosters.refill_booster_fuel()
	update_booster_hud()
