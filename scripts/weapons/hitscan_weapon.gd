class_name HitscanWeapon
extends Weapon

# Minimal single-shot / steady-cadence hitscan weapon. The base Weapon already does the
# raycast, tracer, and recoil; this just decides WHEN to fire. Used for the railgun, and
# reusable for any straightforward gun that isn't the wind-up minigun.

# Shots per second. Low = slow fire rate (railgun).
@export var rounds_per_second: float = 1.0
# Semi-auto: one shot per trigger press (must release and pull again). False = full-auto
# at rounds_per_second.
@export var semi_auto: bool = true

var fire_cooldown: float = 0.0
var trigger_was_held: bool = false


func _physics_process(delta: float) -> void:
	fire_cooldown = maxf(fire_cooldown - delta, 0.0)

	var wants_fire := trigger_held and fire_cooldown <= 0.0

	if semi_auto and trigger_was_held:
		wants_fire = false   # already fired on this trigger hold

	if wants_fire:
		fire_round()

	trigger_was_held = trigger_held
	set_firing(trigger_held)


func fire_round() -> void:
	fire_hitscan()
	apply_fire_recoil()
	fire_cooldown = 1.0 / maxf(rounds_per_second, 0.001)
