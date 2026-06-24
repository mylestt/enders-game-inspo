extends Node
class_name PlayerHealth

signal health_changed(current_health: float, max_health: float)
signal died(attacker_peer_id: int)

@export var max_health: float = 100.0
@export var starting_health: float = 100.0

var current_health: float = 100.0
var last_attacker_peer_id: int = 0


func setup() -> void:
	max_health = maxf(max_health, 1.0)
	current_health = clampf(starting_health, 0.0, max_health)
	health_changed.emit(current_health, max_health)


func apply_damage(amount: float, attacker_peer_id: int = 0) -> bool:
	if amount <= 0.0 or current_health <= 0.0:
		return false
	
	last_attacker_peer_id = attacker_peer_id
	current_health = maxf(current_health - amount, 0.0)
	health_changed.emit(current_health, max_health)
	
	if current_health <= 0.0:
		died.emit(last_attacker_peer_id)
	
	return true


func heal(amount: float) -> bool:
	if amount <= 0.0 or current_health >= max_health:
		return false
	
	current_health = minf(current_health + amount, max_health)
	health_changed.emit(current_health, max_health)
	return true


func reset_health() -> void:
	current_health = max_health
	health_changed.emit(current_health, max_health)


func set_health_state(new_current_health: float, new_max_health: float) -> void:
	max_health = maxf(new_max_health, 1.0)
	current_health = clampf(new_current_health, 0.0, max_health)
	health_changed.emit(current_health, max_health)


func get_health_ratio() -> float:
	if max_health <= 0.0:
		return 0.0
	
	return current_health / max_health
