class_name ChargeHitscanWeapon
extends HitscanWeapon

# A charge-up hitscan gun (the railgun). HOLDING the fire button winds up a charge; RELEASING
# fires a single shot whose damage AND tracer width scale from a floor value (a quick tap) up
# to full power (a complete charge). Everything else — the raycast, ammo, recoil routing,
# networking, the per-gun tracer/muzzle-flash — is the base Weapon / HitscanWeapon pipeline;
# this only changes WHEN it fires and feeds two scale hooks the base already calls.
#
# hitscan_damage is the FULL-charge damage (and the value the server clamps hit claims to, so
# a charged shot needs no economy change — it can only ever claim <= full). A tap deals
# hitscan_damage * charge_min_damage_fraction.

@export_group("Charge")
# Seconds of holding to reach a full-power shot. Holding beyond this does nothing more.
@export var max_charge_time: float = 1.2
# Damage of an UNCHARGED shot (a quick tap) as a fraction of hitscan_damage. 1.0 = no scaling.
@export var charge_min_damage_fraction: float = 0.3
# Tracer WIDTH multiplier at zero charge -> at full charge (length is always muzzle-to-impact).
# This makes the beam thin on a tap and thick on a full charge — for the shooter and, relayed
# with the shot, every bystander too.
@export var tracer_charge_min_scale: float = 0.4
@export var tracer_charge_max_scale: float = 1.8
# Recoil/knockback multiplier at zero charge -> at full charge, so a full shot kicks harder.
@export var charge_min_recoil_mult: float = 0.5

var charge_time: float = 0.0
var is_charging: bool = false
# The charge ratio captured at the instant of firing. The base fire_hitscan() reads it back
# through the two scale hooks below during the shot, then it is reset with the charge.
var _fire_charge_ratio: float = 0.0


func _physics_process(delta: float) -> void:
	advance(delta)
	fire_cooldown = maxf(fire_cooldown - delta, 0.0)

	var ready := not reloading and fire_cooldown <= 0.0 and can_fire()

	if trigger_held and ready:
		is_charging = true
		charge_time = minf(charge_time + delta, max_charge_time)

	# Trigger released fires whatever we charged (a tap is a valid, weak shot). Releasing while
	# NOT charging — e.g. the button was held down through a reload/cooldown — just clears state.
	if not trigger_held:
		if is_charging:
			_fire_charged_shot()

		is_charging = false
		charge_time = 0.0

	set_firing(is_charging)


# 0.0 (no charge) .. 1.0 (full charge).
func charge_ratio() -> float:
	return clampf(charge_time / maxf(max_charge_time, 0.0001), 0.0, 1.0)


func _fire_charged_shot() -> void:
	if not can_fire():
		if uses_ammo() and current_ammo <= 0:
			start_reload()   # released on empty -> chamber a fresh mag
		return

	_fire_charge_ratio = charge_ratio()
	perform_shot()   # base fire_hitscan(): reads the two scale hooks below for damage + tracer
	consume_round()
	apply_fire_recoil(lerpf(charge_min_recoil_mult, 1.0, _fire_charge_ratio))
	fire_cooldown = 1.0 / maxf(rounds_per_second, 0.001)


# --- Scale hooks the base fire pipeline calls (see Weapon.fire_hitscan) ------------------

func get_effective_hitscan_damage() -> float:
	return lerpf(hitscan_damage * charge_min_damage_fraction, hitscan_damage, _fire_charge_ratio)


func get_tracer_size_scale() -> float:
	return lerpf(tracer_charge_min_scale, tracer_charge_max_scale, _fire_charge_ratio)
