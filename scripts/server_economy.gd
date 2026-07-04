class_name ServerEconomy
extends Node

# Server-authoritative cash, item ownership, and weapon-ammo ledger.
#
# Created by NetworkManager on EVERY machine (same tree path on client and server, so the
# RPCs below resolve), but the ledgers are only populated on the server. Clients keep a
# display copy of their cash in the buy menu; every purchase goes through
# request_purchase -> server validation -> client_purchase_result, and the buy menu only
# applies the item after the server confirms.
#
# The ammo ledger backs hit validation: every server-accepted damage claim consumes one
# round (a plasma blast consumes one round total, however many players it hits), reloads
# are client-reported but rate/reserve-checked, and a claim is rejected when the shooter
# doesn't own the weapon, the mag is spent, or claims arrive faster than the weapon can
# physically fire. Counting accepted CLAIMS (not the cosmetic shot relays, which a cheater
# can simply withhold) is what makes the bound enforceable, and it undercounts real shots
# fired, so honest players can never be falsely rejected for ammo.

signal purchase_result(item_id: String, success: bool, message: String, new_cash: int)
signal cash_changed(new_cash: int)

# Accepted-claim rate limit headroom over the weapon's true fire rate, to absorb network
# jitter bunching two legitimate shots close together.
@export var fire_rate_headroom: float = 1.5
# A reload is honoured only this fraction of the weapon's reload_time after the previous
# one (tolerance for client/server clock drift).
@export var reload_time_tolerance: float = 0.8
# Plasma claims within this distance/time of the previous blast count as the SAME blast
# (one bolt hitting several players must only consume one round).
@export var plasma_blast_merge_distance: float = 1.5
@export var plasma_blast_merge_time: float = 0.5

var network_manager: Node

# --- Server-only ledgers -------------------------------------------------------------
var cash_by_peer_id: Dictionary = {}
# peer_id -> { group(String): level(int) } — single-purchase items store level 1.
var owned_by_peer_id: Dictionary = {}
# peer_id -> { weapon_id(String): {consumed, reserve, last_reload_time, tokens, last_token_time,
#              last_blast_time, last_blast_position} }
var ammo_by_peer_id: Dictionary = {}
# weapon_id(String) -> stats Dictionary, built once from the weapon scenes.
var weapon_stats_cache: Dictionary = {}

# Client-side: last cash value the server pushed, so a late-bound buy menu can catch up.
var last_synced_cash: int = -1


func setup(new_network_manager: Node) -> void:
	network_manager = new_network_manager


func now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


func is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func is_online() -> bool:
	if network_manager != null and network_manager.has_method("has_active_multiplayer_peer"):
		return bool(network_manager.call("has_active_multiplayer_peer"))

	return false


func local_peer_id() -> int:
	if network_manager != null and network_manager.has_method("get_local_peer_id"):
		return int(network_manager.call("get_local_peer_id"))

	return 1


# The shop catalog is the server's own copy of the buy menu (same build as the client's,
# so ids/prices/groups match). Null on maps without a buy menu -> purchases fail closed.
func get_catalog() -> Node:
	if network_manager != null and "buy_menu" in network_manager:
		return network_manager.buy_menu

	return null


# --- Peer lifecycle (server) ---------------------------------------------------------

func server_init_peer(peer_id: int, starting_cash: int) -> void:
	if not is_server():
		return

	cash_by_peer_id[peer_id] = maxi(starting_cash, 0)
	owned_by_peer_id[peer_id] = {}
	ammo_by_peer_id[peer_id] = {}
	push_cash_to_peer(peer_id)


func server_remove_peer(peer_id: int) -> void:
	cash_by_peer_id.erase(peer_id)
	owned_by_peer_id.erase(peer_id)
	ammo_by_peer_id.erase(peer_id)


func reset_all() -> void:
	cash_by_peer_id.clear()
	owned_by_peer_id.clear()
	ammo_by_peer_id.clear()
	last_synced_cash = -1


# --- Cash (server mutators used by admin commands) ------------------------------------

func server_set_cash(peer_id: int, amount: int) -> bool:
	if not is_server() or not cash_by_peer_id.has(peer_id):
		return false

	cash_by_peer_id[peer_id] = maxi(amount, 0)
	push_cash_to_peer(peer_id)
	return true


func server_add_cash(peer_id: int, amount: int) -> bool:
	if not is_server() or not cash_by_peer_id.has(peer_id):
		return false

	return server_set_cash(peer_id, int(cash_by_peer_id[peer_id]) + amount)


func push_cash_to_peer(peer_id: int) -> void:
	var amount := int(cash_by_peer_id.get(peer_id, 0))

	if peer_id == multiplayer.get_unique_id():
		client_sync_cash(amount)
	else:
		rpc_id(peer_id, "client_sync_cash", amount)


@rpc("authority", "reliable")
func client_sync_cash(new_cash: int) -> void:
	last_synced_cash = new_cash
	cash_changed.emit(new_cash)


# --- Purchases -------------------------------------------------------------------------

# Client entry point. The buy menu calls this instead of applying the item directly; the
# item is applied when purchase_result comes back successful.
func request_purchase(item_id: String) -> void:
	if is_server():
		_server_handle_purchase(local_peer_id(), item_id)
	elif multiplayer.multiplayer_peer != null:
		rpc_id(1, "server_request_purchase", item_id)


@rpc("any_peer", "reliable")
func server_request_purchase(item_id: String) -> void:
	if not is_server():
		return

	_server_handle_purchase(multiplayer.get_remote_sender_id(), item_id)


func _server_handle_purchase(peer_id: int, item_id: String) -> void:
	if not cash_by_peer_id.has(peer_id):
		_send_purchase_result(peer_id, item_id, false, "Not spawned.")
		return

	var catalog := get_catalog()

	if catalog == null or not catalog.has_method("get_item_by_id"):
		_send_purchase_result(peer_id, item_id, false, "No shop catalog on server.")
		return

	var item: Dictionary = catalog.call("get_item_by_id", item_id)

	if item.is_empty():
		_send_purchase_result(peer_id, item_id, false, "Unknown item.")
		return

	var group := String(item["group"])
	var level := int(item["level"])
	var price := int(item["price"])
	var owned: Dictionary = owned_by_peer_id[peer_id]
	var current_level := int(owned.get(group, 0))

	if is_single_purchase_group(group):
		if current_level > 0:
			_send_purchase_result(peer_id, item_id, false, "Already owned.")
			return
	else:
		if current_level >= level:
			_send_purchase_result(peer_id, item_id, false, "Already owned.")
			return

		if current_level < level - 1:
			_send_purchase_result(peer_id, item_id, false, "Locked.")
			return

	if int(cash_by_peer_id[peer_id]) < price:
		_send_purchase_result(peer_id, item_id, false, "Not enough cash.")
		return

	cash_by_peer_id[peer_id] = int(cash_by_peer_id[peer_id]) - price
	owned[group] = level
	owned_by_peer_id[peer_id] = owned

	if is_weapon_group(group):
		server_grant_weapon_ammo(peer_id, group)

	_send_purchase_result(peer_id, item_id, true, "Purchased.")
	print("Purchase: peer ", peer_id, " bought ", item_id, " for ", price)


func _send_purchase_result(peer_id: int, item_id: String, success: bool, message: String) -> void:
	var new_cash := int(cash_by_peer_id.get(peer_id, 0))

	if peer_id == multiplayer.get_unique_id():
		client_purchase_result(item_id, success, message, new_cash)
	else:
		rpc_id(peer_id, "client_purchase_result", item_id, success, message, new_cash)


@rpc("authority", "reliable")
func client_purchase_result(item_id: String, success: bool, message: String, new_cash: int) -> void:
	last_synced_cash = new_cash
	purchase_result.emit(item_id, success, message, new_cash)
	cash_changed.emit(new_cash)


func is_weapon_group(group: String) -> bool:
	return StringName(group) in WeaponInventory.SLOT_IDS


func is_single_purchase_group(group: String) -> bool:
	return group == "suit_boosters" or is_weapon_group(group)


# --- Weapon stats (from the same scenes the clients equip) -----------------------------

func get_weapon_stats(weapon_id: String) -> Dictionary:
	if weapon_stats_cache.has(weapon_id):
		return weapon_stats_cache[weapon_id]

	var stats: Dictionary = {}
	var scene := WeaponInventory.get_weapon_scene(StringName(weapon_id))

	if scene != null:
		var weapon := scene.instantiate() as Weapon

		if weapon != null:
			var damage := float(weapon.hitscan_damage)

			# Projectile weapons deal their bolt's blast damage, not hitscan_damage.
			if weapon is ProjectileWeapon:
				var bolt_scene: PackedScene = (weapon as ProjectileWeapon).projectile_scene

				if bolt_scene != null:
					var bolt := bolt_scene.instantiate()

					if bolt is PlasmaProjectile:
						damage = float((bolt as PlasmaProjectile).maximum_damage)

					bolt.free()

			var rps := 10.0
			var rps_value = weapon.get("rounds_per_second")

			if rps_value != null:
				rps = maxf(float(rps_value), 0.1)

			var burst := 1
			var burst_value = weapon.get("burst_count")

			if burst_value != null:
				burst = maxi(int(burst_value), 1)

			stats = {
				"mag_size": weapon.mag_size,
				"reserve": weapon.starting_reserve,
				"reload_time": weapon.reload_time,
				"damage": damage,
				# Token bucket: capacity covers one full burst plus jitter slack; refill is
				# the weapon's sustained rounds/sec with headroom.
				"token_capacity": float(burst) + 2.0,
				"token_rate": rps * float(burst) * maxf(fire_rate_headroom, 1.0),
			}
			weapon.free()

	weapon_stats_cache[weapon_id] = stats
	return stats


func server_grant_weapon_ammo(peer_id: int, weapon_id: String) -> void:
	var stats := get_weapon_stats(weapon_id)

	if stats.is_empty():
		return

	var ammo: Dictionary = ammo_by_peer_id.get(peer_id, {})
	ammo[weapon_id] = _fresh_ammo_entry(stats)
	ammo_by_peer_id[peer_id] = ammo


# FFA loadout grant: records ownership and refills the ammo ledger for a gun the server
# handed the player for free (no purchase / cash deduction). Mirrors what the client does
# when it equips the random weapon, so hit-claim validation passes.
func server_grant_ffa_weapon(peer_id: int, weapon_id: String) -> void:
	if not is_server() or not owned_by_peer_id.has(peer_id):
		return

	var owned: Dictionary = owned_by_peer_id[peer_id]
	owned[weapon_id] = 1
	owned_by_peer_id[peer_id] = owned

	server_grant_weapon_ammo(peer_id, weapon_id)


func _fresh_ammo_entry(stats: Dictionary) -> Dictionary:
	return {
		"consumed": 0,
		"reserve": int(stats["reserve"]),
		"last_reload_time": now_seconds(),
		"tokens": float(stats["token_capacity"]),
		"last_token_time": now_seconds(),
		"last_blast_time": -1000.0,
		"last_blast_position": Vector3.ZERO,
	}


# Refills one peer's whole ammo ledger (round start, or the "ammo on kill" rule).
func server_refill_peer_ammo(peer_id: int) -> void:
	if not is_server():
		return

	var ammo: Dictionary = ammo_by_peer_id.get(peer_id, {})

	for weapon_id in ammo.keys():
		var stats := get_weapon_stats(String(weapon_id))

		if not stats.is_empty():
			ammo[weapon_id] = _fresh_ammo_entry(stats)


# Round start: every client refills all its weapons (WeaponInventory.reset_state), so the
# server ledger does the same.
func server_refill_all_ammo() -> void:
	if not is_server():
		return

	for peer_id in ammo_by_peer_id.keys():
		server_refill_peer_ammo(peer_id)


# --- Reload mirroring -------------------------------------------------------------------

# Client entry point, called by the local player when a reload finishes.
func notify_weapon_reload(weapon_id: String) -> void:
	if is_server():
		_server_handle_reload(local_peer_id(), weapon_id)
	elif multiplayer.multiplayer_peer != null:
		rpc_id(1, "server_notify_weapon_reload", weapon_id)


@rpc("any_peer", "reliable")
func server_notify_weapon_reload(weapon_id: String) -> void:
	if not is_server():
		return

	_server_handle_reload(multiplayer.get_remote_sender_id(), weapon_id)


func _server_handle_reload(peer_id: int, weapon_id: String) -> void:
	var entry := _get_ammo_entry(peer_id, weapon_id)
	var stats := get_weapon_stats(weapon_id)

	if entry.is_empty() or stats.is_empty() or int(stats["mag_size"]) <= 0:
		return

	# Reloads can't come faster than the weapon's real reload time (with drift tolerance).
	if now_seconds() - float(entry["last_reload_time"]) < float(stats["reload_time"]) * reload_time_tolerance:
		return

	var transfer := mini(int(entry["consumed"]), int(entry["reserve"]))
	entry["reserve"] = int(entry["reserve"]) - transfer
	entry["consumed"] = int(entry["consumed"]) - transfer
	entry["last_reload_time"] = now_seconds()


func _get_ammo_entry(peer_id: int, weapon_id: String) -> Dictionary:
	var ammo: Dictionary = ammo_by_peer_id.get(peer_id, {})
	return ammo.get(weapon_id, {})


# --- Hit-claim validation (server) ------------------------------------------------------
# Both return the approved damage (claimed damage clamped to the weapon's real damage), or
# -1.0 when the claim must be rejected outright.

func server_validate_hitscan_hit(attacker_peer_id: int, weapon_id: String, claimed_damage: float) -> float:
	var stats := get_weapon_stats(weapon_id)
	var entry := _get_ammo_entry(attacker_peer_id, weapon_id)

	if stats.is_empty() or entry.is_empty():
		return -1.0   # unknown weapon or not owned

	if not _consume_round(entry, stats):
		return -1.0

	return minf(claimed_damage, float(stats["damage"]))


# Plasma blasts submit one claim per player hit; only the first claim of a blast consumes a
# round and a fire token, identified by explosion position/time proximity.
func server_validate_plasma_hit(
	attacker_peer_id: int,
	weapon_id: String,
	claimed_damage: float,
	blast_position: Vector3
) -> float:
	var stats := get_weapon_stats(weapon_id)
	var entry := _get_ammo_entry(attacker_peer_id, weapon_id)

	if stats.is_empty() or entry.is_empty():
		return -1.0

	var same_blast := (
		now_seconds() - float(entry["last_blast_time"]) <= plasma_blast_merge_time
		and blast_position.distance_to(entry["last_blast_position"]) <= plasma_blast_merge_distance
	)

	if not same_blast:
		if not _consume_round(entry, stats):
			return -1.0

		entry["last_blast_time"] = now_seconds()
		entry["last_blast_position"] = blast_position

	return minf(claimed_damage, float(stats["damage"]))


# One fired round: takes a fire-rate token and a round from the mag ledger.
func _consume_round(entry: Dictionary, stats: Dictionary) -> bool:
	var now := now_seconds()
	var tokens := float(entry["tokens"])
	tokens = minf(
		tokens + (now - float(entry["last_token_time"])) * float(stats["token_rate"]),
		float(stats["token_capacity"])
	)
	entry["last_token_time"] = now

	if tokens < 1.0:
		entry["tokens"] = tokens
		return false   # claims arriving faster than the weapon can fire

	if int(stats["mag_size"]) > 0 and int(entry["consumed"]) >= int(stats["mag_size"]):
		entry["tokens"] = tokens
		return false   # mag spent without a (valid) reload

	entry["tokens"] = tokens - 1.0

	if int(stats["mag_size"]) > 0:
		entry["consumed"] = int(entry["consumed"]) + 1

	return true
