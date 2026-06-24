class_name MinigunWeapon
extends Weapon

signal windup_changed(amount: float)

@export var barrel_node_path: NodePath
@export var box_node_path: NodePath
@export var barrel_name_hint: String = "barrel"
@export var box_name_hint: String = "box"

@export var wind_up_time: float = 0.45
@export var wind_down_time: float = 0.75
@export var fire_spin_threshold: float = 0.78
@export var max_spin_radians_per_second: float = 54.0
@export var barrel_local_spin_axis: Vector3 = Vector3.FORWARD
@export var rounds_per_second: float = 18.0
@export var max_rounds_per_frame: int = 4

var barrel: Node3D
var box: Node3D
var windup_amount: float = 0.0
var fire_cooldown: float = 0.0


func _ready() -> void:
	barrel = resolve_part(barrel_node_path, barrel_name_hint)
	box = resolve_part(box_node_path, box_name_hint)
	
	if barrel == null:
		push_warning("MinigunWeapon could not find a barrel mesh. Set Barrel Node Path on the minigun scene.")


func _process(delta: float) -> void:
	spin_barrel(delta)


func _physics_process(delta: float) -> void:
	update_windup(delta)
	update_firing_state()
	update_fire_cycle(delta)


func update_windup(delta: float) -> void:
	var target := 1.0 if trigger_held else 0.0
	var duration := wind_up_time if trigger_held else wind_down_time
	var speed := 1.0 / maxf(duration, 0.001)
	var previous := windup_amount
	
	windup_amount = move_toward(windup_amount, target, speed * delta)
	
	if not is_equal_approx(previous, windup_amount):
		windup_changed.emit(windup_amount)


func spin_barrel(delta: float) -> void:
	if barrel == null:
		return
	
	if windup_amount <= 0.001:
		return
	
	var axis := barrel_local_spin_axis
	
	if axis.length() < 0.001:
		axis = Vector3.FORWARD
	
	barrel.rotate_object_local(axis.normalized(), max_spin_radians_per_second * windup_amount * delta)


func update_firing_state() -> void:
	set_firing(trigger_held and windup_amount >= fire_spin_threshold)


func update_fire_cycle(delta: float) -> void:
	if not is_firing():
		fire_cooldown = 0.0
		return
	
	if rounds_per_second <= 0.0:
		return
	
	fire_cooldown -= delta
	var fire_interval := 1.0 / rounds_per_second
	var rounds_this_frame := 0
	
	while fire_cooldown <= 0.0 and rounds_this_frame < max_rounds_per_frame:
		fire_round()
		fire_cooldown += fire_interval
		rounds_this_frame += 1
	
	if fire_cooldown <= 0.0:
		fire_cooldown = fire_interval


func fire_round() -> void:
	fire_hitscan()
	apply_fire_recoil(windup_amount)


func set_trigger_held(value: bool) -> void:
	super.set_trigger_held(value)
	
	if not trigger_held:
		set_firing(false)
		fire_cooldown = 0.0


func resolve_part(path: NodePath, name_hint: String) -> Node3D:
	if String(path) != "":
		var explicit_node := get_node_or_null(path) as Node3D
		
		if explicit_node != null:
			return explicit_node
	
	return find_descendant_by_name_hint(self, name_hint)


func find_descendant_by_name_hint(root: Node, name_hint: String) -> Node3D:
	var normalized_hint := name_hint.to_lower()
	
	for child in root.get_children():
		var child_name := String(child.name).to_lower()
		
		if child is Node3D and child_name.contains(normalized_hint):
			return child as Node3D
		
		var nested := find_descendant_by_name_hint(child, name_hint)
		
		if nested != null:
			return nested
	
	return null


func get_windup_amount() -> float:
	return windup_amount
