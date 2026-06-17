extends RigidBody3D

@export var linear_damp_value: float = 0.0
@export var angular_damp_value: float = 1.2

@export var network_send_rate: float = 30.0
@export var network_interpolation_speed: float = 18.0
@export var fallback_laser_range: float = 120.0
@export var fallback_laser_fire_cooldown: float = 0.2

@export var body_slam_min_speed: float = 3.0
@export var body_slam_impulse_multiplier: float = 1.35
@export var body_slam_max_impulse: float = 18.0
@export var body_slam_local_cooldown: float = 0.2

var buy_menu_open: bool = false

var peer_id: int = 0
var is_local_player: bool = false
var network_manager: Node

var network_send_timer: float = 0.0
var network_laser_cooldown_remaining: float = 0.0

var network_target_transform: Transform3D
var network_target_linear_velocity: Vector3 = Vector3.ZERO
var network_target_angular_velocity: Vector3 = Vector3.ZERO
var has_network_target: bool = false

var last_body_slam_time_by_target_peer_id: Dictionary = {}

@onready var camera: Camera3D = get_node_or_null("Camera3D") as Camera3D
@onready var movement_controller: PlayerMovementController = get_node_or_null("MovementController") as PlayerMovementController
@onready var suit_boosters: SuitBoosterController = get_node_or_null("SuitBoosters") as SuitBoosterController
@onready var hud_controller: PlayerHUDController = get_node_or_null("PlayerHUD") as PlayerHUDController
@onready var impact_controller: PlayerImpactController = get_node_or_null("ImpactController") as PlayerImpactController
@onready var health_controller: PlayerHealthController = get_node_or_null("HealthController") as PlayerHealthController
@onready var laser_controller: Node = get_node_or_null("Camera3D/LaserController")


func _ready() -> void:
	gravity_scale = 0.0
	linear_damp = linear_damp_value
	angular_damp = angular_damp_value
	can_sleep = false
	continuous_cd = true
	
	contact_monitor = true
	max_contacts_reported = max(max_contacts_reported, 12)
	
	network_target_transform = global_transform
	
	if camera != null:
		camera.current = false
	
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
	
	if impact_controller == null:
		push_warning("ImpactController node is missing or does not have impact_controller.gd attached.")
	else:
		impact_controller.setup(self, hud_controller)
	
	if health_controller == null:
		push_error("HealthController node is missing or does not have player_health_controller.gd attached.")
	else:
		health_controller.setup(self)


func set_multiplayer_player(new_peer_id: int, new_is_local_player: bool, new_network_manager: Node) -> void:
	peer_id = new_peer_id
	is_local_player = new_is_local_player
	network_manager = new_network_manager
	
	set_multiplayer_authority(peer_id)
	
	freeze = not is_local_player
	
	if camera != null:
		camera.current = is_local_player
	
	var ui := get_node_or_null("UI")
	
	if ui != null:
		ui.visible = is_local_player
	
	if health_controller != null:
		health_controller.set_is_local_player(is_local_player)
	
	if laser_controller != null and laser_controller.has_method("set_input_enabled"):
		laser_controller.call("set_input_enabled", is_local_player)
	
	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	print("Player ", peer_id, " multiplayer setup. Local: ", is_local_player)


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
	
	if event.is_action_pressed("free_look"):
		set_laser_input_enabled(false)
	
	if event.is_action_released("free_look"):
		set_laser_input_enabled(not buy_menu_open and not is_input_locked())
	
	if event is InputEventMouseMotion:
		if movement_controller != null:
			if is_free_look_active():
				movement_controller.add_free_look_mouse_motion(event.relative)
			else:
				movement_controller.add_mouse_motion(event.relative)
	
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not is_local_player:
		update_remote_network_state(delta)
		return
	
	if impact_controller != null:
		impact_controller.physics_update(delta)
	
	if network_laser_cooldown_remaining > 0.0:
		network_laser_cooldown_remaining -= delta
		network_laser_cooldown_remaining = maxf(network_laser_cooldown_remaining, 0.0)
	
	var input_locked := is_input_locked()
	var free_look_active := is_free_look_active()
	
	set_laser_input_enabled(not buy_menu_open and not free_look_active and not input_locked)
	
	var laser_aiming := is_laser_aiming()
	var surface_in_range := false
	var grabbing := false
	var show_ctrl_push_arrow := false
	var ctrl_push_direction := Vector3.ZERO
	
	if movement_controller != null:
		surface_in_range = movement_controller.is_surface_in_interaction_range()
		grabbing = movement_controller.is_grabbing_wall()
		show_ctrl_push_arrow = movement_controller.should_show_ctrl_push_arrow(
			buy_menu_open,
			free_look_active,
			laser_aiming,
			input_locked
		)
		ctrl_push_direction = movement_controller.get_predicted_ctrl_push_direction()
	
	if hud_controller != null:
		hud_controller.update_velocity_indicator(linear_velocity)
		hud_controller.update_reticle(delta, surface_in_range, laser_aiming, buy_menu_open or input_locked)
		hud_controller.update_push_direction_arrow(
			delta,
			show_ctrl_push_arrow,
			ctrl_push_direction,
			camera
		)
	
	if movement_controller != null:
		movement_controller.physics_update(delta, laser_aiming, free_look_active, input_locked)
		grabbing = movement_controller.is_grabbing_wall()
	
	if suit_boosters != null:
		suit_boosters.physics_update(delta, not buy_menu_open and not input_locked, grabbing)
		
		if hud_controller != null:
			hud_controller.update_booster_ui(
				suit_boosters.get_has_suit_boosters(),
				suit_boosters.get_booster_fuel(),
				suit_boosters.get_max_booster_fuel()
			)
	
	handle_network_laser_fire()
	update_network_send(delta)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not is_local_player:
		return
	
	if impact_controller != null:
		impact_controller.integrate_forces(state)
	
	if movement_controller != null:
		movement_controller.integrate_forces(state)
	
	detect_player_body_slam_contacts(state)


func detect_player_body_slam_contacts(state: PhysicsDirectBodyState3D) -> void:
	if network_manager == null:
		return
	
	if is_combat_disabled():
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
		
		var slam_direction := linear_velocity.normalized()
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
	
	sleeping = false
	
	var local_contact_position := contact_position - global_position
	
	if local_contact_position.length() > 4.0:
		apply_central_impulse(impulse)
	else:
		apply_impulse(impulse, local_contact_position)
	
	print("Applied body slam impulse: ", impulse)


func update_remote_network_state(delta: float) -> void:
	if not has_network_target:
		return
	
	linear_velocity = network_target_linear_velocity
	angular_velocity = network_target_angular_velocity
	
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		global_transform = network_target_transform
		return
	
	var weight := 1.0 - exp(-network_interpolation_speed * delta)
	
	var new_position := global_transform.origin.lerp(network_target_transform.origin, weight)
	var new_basis := global_transform.basis.slerp(network_target_transform.basis, weight).orthonormalized()
	
	global_transform = Transform3D(new_basis, new_position)


func receive_network_state(
	new_transform: Transform3D,
	new_linear_velocity: Vector3,
	new_angular_velocity: Vector3
) -> void:
	network_target_transform = new_transform
	network_target_linear_velocity = new_linear_velocity
	network_target_angular_velocity = new_angular_velocity
	has_network_target = true


func update_network_send(delta: float) -> void:
	if network_manager == null:
		return
	
	if multiplayer.multiplayer_peer == null:
		return
	
	if network_send_rate <= 0.0:
		return
	
	network_send_timer -= delta
	
	if network_send_timer > 0.0:
		return
	
	network_send_timer = 1.0 / network_send_rate
	
	if network_manager.has_method("submit_local_player_state"):
		network_manager.call(
			"submit_local_player_state",
			peer_id,
			global_transform,
			linear_velocity,
			angular_velocity
		)


func handle_network_laser_fire() -> void:
	if network_manager == null:
		return
	
	if is_input_locked():
		return
	
	if network_laser_cooldown_remaining > 0.0:
		return
	
	if not Input.is_action_pressed("laser_fire"):
		return
	
	if not is_laser_aiming():
		return
	
	var origin := get_network_laser_origin()
	var direction := get_network_laser_direction()
	var laser_range := get_network_laser_range()
	var fire_cooldown := get_network_laser_fire_cooldown()
	
	if direction.length() < 0.01:
		return
	
	if network_manager.has_method("request_laser_fire"):
		network_manager.call("request_laser_fire", peer_id, origin, direction, laser_range, fire_cooldown)
	
	network_laser_cooldown_remaining = fire_cooldown


func get_network_laser_origin() -> Vector3:
	if laser_controller != null and laser_controller.has_method("get_laser_muzzle_world_position"):
		return laser_controller.call("get_laser_muzzle_world_position")
	
	if camera != null:
		return camera.global_position
	
	return global_position


func get_network_laser_direction() -> Vector3:
	if laser_controller != null and laser_controller.has_method("get_actual_laser_direction"):
		return laser_controller.call("get_actual_laser_direction")
	
	if camera != null:
		return (-camera.global_transform.basis.z).normalized()
	
	return (-global_transform.basis.z).normalized()


func get_network_laser_range() -> float:
	if laser_controller != null and laser_controller.has_method("get_laser_range"):
		return laser_controller.call("get_laser_range")
	
	return fallback_laser_range


func get_network_laser_fire_cooldown() -> float:
	if laser_controller != null and laser_controller.has_method("get_laser_fire_cooldown"):
		return laser_controller.call("get_laser_fire_cooldown")
	
	return fallback_laser_fire_cooldown


func is_free_look_active() -> bool:
	if is_input_locked():
		return false
	
	return Input.is_action_pressed("free_look")


func is_input_locked() -> bool:
	return is_immobilized() or is_combat_disabled()


func is_immobilized() -> bool:
	if impact_controller == null:
		return false
	
	return impact_controller.is_immobilized()


func is_combat_disabled() -> bool:
	if health_controller == null:
		return false
	
	return health_controller.is_combat_disabled()


func is_laser_aiming() -> bool:
	if is_free_look_active() or is_input_locked():
		return false
	
	if laser_controller != null and laser_controller.has_method("is_laser_aiming"):
		return laser_controller.call("is_laser_aiming") == true
	
	return Input.is_action_pressed("laser_aim")


func set_laser_input_enabled(value: bool) -> void:
	if laser_controller != null and laser_controller.has_method("set_input_enabled"):
		laser_controller.call("set_input_enabled", value)


func set_buy_menu_open(value: bool) -> void:
	if not is_local_player:
		return
	
	buy_menu_open = value
	
	if movement_controller != null:
		movement_controller.clear_mouse_motion()
		movement_controller.clear_free_look_mouse_motion()
	
	set_laser_input_enabled(not value and not is_input_locked())
	
	if value:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func server_add_hit(amount: int) -> void:
	if health_controller == null:
		return
	
	health_controller.add_hit(amount)


func server_reset_health() -> void:
	if health_controller == null:
		return
	
	health_controller.reset_health()


func apply_network_damage_state(hits: int, disabled: bool) -> void:
	if health_controller != null:
		health_controller.set_network_state(hits, disabled)
	
	if disabled:
		set_laser_input_enabled(false)
		
		if movement_controller != null:
			movement_controller.clear_mouse_motion()
			movement_controller.clear_free_look_mouse_motion()


func get_hit_count() -> int:
	if health_controller == null:
		return 0
	
	return health_controller.get_hit_count()


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
