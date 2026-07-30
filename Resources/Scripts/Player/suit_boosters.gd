class_name SuitBoosterController
extends Node

@export var booster_thrust_force: float = 7.5
@export var max_booster_fuel: float = 100.0
@export var booster_drain_rate: float = 1.0

var player: RigidBody3D

var has_suit_boosters: bool = false
var booster_fuel: float = 0.0


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player
	booster_fuel = 0.0
	
	print("SuitBoosterController setup complete")


func physics_update(delta: float, input_enabled: bool, is_grabbing: bool) -> void:
	if player == null:
		return
	
	if not input_enabled:
		return
	
	if not has_suit_boosters:
		return
	
	if booster_fuel <= 0.0:
		booster_fuel = 0.0
		return
	
	if is_grabbing:
		return
	
	var thrust_input := Input.get_axis("booster_backward", "booster_forward")
	
	if absf(thrust_input) < 0.01:
		return
	
	var thrust_direction := -player.global_transform.basis.z * thrust_input
	
	player.apply_central_force(thrust_direction * booster_thrust_force)
	
	booster_fuel -= absf(thrust_input) * booster_drain_rate * delta
	booster_fuel = clampf(booster_fuel, 0.0, max_booster_fuel)


func purchase_suit_boosters() -> void:
	has_suit_boosters = true
	booster_fuel = max_booster_fuel
	
	print("Suit boosters purchased. Fuel: ", booster_fuel)


func get_has_suit_boosters() -> bool:
	return has_suit_boosters


func get_booster_fuel() -> float:
	return booster_fuel


func get_max_booster_fuel() -> float:
	return max_booster_fuel


func refill_booster_fuel() -> void:
	if not has_suit_boosters:
		return

	booster_fuel = max_booster_fuel


# FFA loadout: enable boosters and set the match's fuel capacity, filled to full. Used when
# a player (re)spawns into a free-for-all, where boosters aren't a purchase.
func grant_with_fuel(max_fuel: float) -> void:
	has_suit_boosters = true
	max_booster_fuel = maxf(max_fuel, 0.0)
	booster_fuel = max_booster_fuel
