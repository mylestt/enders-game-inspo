class_name HitscanWeapon
extends Weapon

# Cooldown-based hitscan gun. The base Weapon already does the raycast, tracer, ammo, and
# recoil; this just decides WHEN to fire. Covers the single-shot railgun (burst_count 1) and
# burst rifles (burst_count > 1, e.g. a Halo-style battle rifle).

# Cadence between shots (or between bursts). Low = slow.
@export var rounds_per_second: float = 1.0
# Semi-auto: one shot/burst per trigger press (release and pull again). False = full-auto.
@export var semi_auto: bool = true
# Rounds per trigger pull. 1 = single shot; >1 = burst.
@export var burst_count: int = 1
# Seconds between rounds inside a burst.
@export var burst_interval: float = 0.06

var fire_cooldown: float = 0.0
var burst_left: int = 0
var burst_timer: float = 0.0
var trigger_was_held: bool = false


func _physics_process(delta: float) -> void:
	advance(delta)
	fire_cooldown = maxf(fire_cooldown - delta, 0.0)
	burst_timer = maxf(burst_timer - delta, 0.0)

	if burst_left > 0:
		if burst_timer <= 0.0 and not reloading:
			fire_round()
	else:
		var wants_fire := trigger_held and fire_cooldown <= 0.0 and not reloading

		if semi_auto and trigger_was_held:
			wants_fire = false   # already fired on this trigger hold

		if wants_fire:
			burst_left = maxi(burst_count, 1)
			fire_round()

	trigger_was_held = trigger_held
	set_firing(trigger_held or burst_left > 0)


func fire_round() -> void:
	if not can_fire():
		burst_left = 0
		if uses_ammo() and current_ammo <= 0:
			start_reload()   # click on empty -> chamber a fresh mag
		return

	fire_hitscan()
	consume_round()
	apply_fire_recoil()
	burst_left -= 1

	if burst_left > 0:
		burst_timer = burst_interval
	else:
		fire_cooldown = 1.0 / maxf(rounds_per_second, 0.001)
