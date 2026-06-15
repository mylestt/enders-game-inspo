extends RigidBody3D

@export var linear_damp_value: float = 0.0
@export var angular_damp_value: float = 1.2

var buy_menu_open: bool = false

@onready var movement_controller: PlayerMovementController = get_node_or_null("MovementController") as PlayerMovementController
@onready var suit_boosters: SuitBoosterController = get_node_or_null("SuitBoosters") as SuitBoosterController
@onready var hud_controller: PlayerHUDController = get_node_or_null("PlayerHUD") as PlayerHUDController
@onready var laser_controller: Node = get_node_or_null("Camera3D/LaserController")


func _ready() -> void:
	gravity_scale = 0.0
	linear_damp = linear_damp_value
	angular_damp = angular_damp_value
	can_sleep = false
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	if hud_controller == null:
		push_error("PlayerHUD node is missing or does not have player_hud_controller.gd attached.")
	else:
		hud_controller.setup(self)
	
	if movement_controller == null:
		push_error("MovementController node is missing or does not have player_movement_controller.gd attached.")
	else:
		movement_controller.setup(self, hud_controller)
	
	if suit_boosters == null:
		push_error("SuitBoosters node is missing or does not have suit_booster_controller.gd attached.")
	else:
		suit_boosters.setup(self)


func _input(event: InputEvent) -> void:
	if buy_menu_open:
		if movement_controller != null:
			movement_controller.clear_mouse_motion()
		return
	
	if event is InputEventMouseMotion:
		if movement_controller != null:
			movement_controller.add_mouse_motion(event.relative)
	
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	var laser_aiming := is_laser_aiming()
	var surface_in_range := false
	var grabbing := false
	
	if movement_controller != null:
		surface_in_range = movement_controller.is_surface_in_interaction_range()
		grabbing = movement_controller.is_grabbing_wall()
	
	if hud_controller != null:
		hud_controller.update_velocity_indicator(linear_velocity)
		hud_controller.update_reticle(delta, surface_in_range, laser_aiming, buy_menu_open)
	
	if buy_menu_open:
		if movement_controller != null:
			movement_controller.clear_mouse_motion()
		return
	
	if movement_controller != null:
		movement_controller.physics_update(delta, laser_aiming)
		grabbing = movement_controller.is_grabbing_wall()
	
	if suit_boosters != null:
		suit_boosters.physics_update(delta, not buy_menu_open, grabbing)
		
		if hud_controller != null:
			hud_controller.update_booster_ui(
				suit_boosters.get_has_suit_boosters(),
				suit_boosters.get_booster_fuel(),
				suit_boosters.get_max_booster_fuel()
			)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if movement_controller != null:
		movement_controller.integrate_forces(state)


func is_laser_aiming() -> bool:
	if laser_controller != null and laser_controller.has_method("is_laser_aiming"):
		return laser_controller.call("is_laser_aiming") == true
	
	return Input.is_action_pressed("laser_aim")


func set_buy_menu_open(value: bool) -> void:
	buy_menu_open = value
	
	if movement_controller != null:
		movement_controller.clear_mouse_motion()
	
	if laser_controller != null and laser_controller.has_method("set_input_enabled"):
		laser_controller.call("set_input_enabled", not value)
	
	if value:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func apply_grab_distance_upgrade(level: int) -> void:
	if movement_controller == null:
		return
	
	movement_controller.apply_grab_distance_upgrade(level)


func get_grab_distance_level() -> int:
	if movement_controller == null:
		return 0
	
	return movement_controller.get_grab_distance_level()


func purchase_suit_boosters() -> void:
	if suit_boosters == null:
		return
	
	suit_boosters.purchase_suit_boosters()
	
	if hud_controller != null:
		hud_controller.update_booster_ui(
			suit_boosters.get_has_suit_boosters(),
			suit_boosters.get_booster_fuel(),
			suit_boosters.get_max_booster_fuel()
		)


func get_has_suit_boosters() -> bool:
	if suit_boosters == null:
		return false
	
	return suit_boosters.get_has_suit_boosters()


func refill_booster_fuel() -> void:
	if suit_boosters == null:
		return
	
	suit_boosters.refill_booster_fuel()
	
	if hud_controller != null:
		hud_controller.update_booster_ui(
			suit_boosters.get_has_suit_boosters(),
			suit_boosters.get_booster_fuel(),
			suit_boosters.get_max_booster_fuel()
		)
