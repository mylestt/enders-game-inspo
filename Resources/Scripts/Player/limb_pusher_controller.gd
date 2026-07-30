extends Node3D
class_name LimbPushController

const LIMB_LEFT_ARM := "left_arm"
const LIMB_RIGHT_ARM := "right_arm"
const LIMB_LEFT_FOOT := "left_foot"
const LIMB_RIGHT_FOOT := "right_foot"

@export var auto_create_limb_points: bool = true
@export var show_debug_limb_spheres: bool = true
@export var debug_sphere_radius: float = 0.085
@export var debug_sphere_near_radius: float = 0.12

@export var left_arm_marker_path: NodePath = NodePath("LeftArmPoint")
@export var right_arm_marker_path: NodePath = NodePath("RightArmPoint")
@export var left_foot_marker_path: NodePath = NodePath("LeftFootPoint")
@export var right_foot_marker_path: NodePath = NodePath("RightFootPoint")

@export var left_arm_fallback_local_offset: Vector3 = Vector3(-0.55, 0.35, -0.15)
@export var right_arm_fallback_local_offset: Vector3 = Vector3(0.55, 0.35, -0.15)
@export var left_foot_fallback_local_offset: Vector3 = Vector3(-0.28, -0.85, 0.10)
@export var right_foot_fallback_local_offset: Vector3 = Vector3(0.28, -0.85, 0.10)

@export var use_perpendicular_limb_probes: bool = true

@export var arm_force_weight: float = 0.50
@export var foot_force_weight: float = 0.70

@export var limb_push_min_force_multiplier: float = 0.25
@export var limb_push_force_weight_scale: float = 0.60
@export var limb_push_max_force_multiplier: float = 1.20

@export var use_angle_based_push_strength: bool = true
@export var min_push_angle_force_multiplier: float = 0.12
@export var push_angle_power: float = 2.0

@export var inactive_sphere_color: Color = Color(0.35, 0.55, 1.0, 0.75)
@export var near_sphere_color: Color = Color(0.35, 1.0, 0.45, 0.95)
@export var disabled_sphere_color: Color = Color(1.0, 0.2, 0.2, 0.75)

@export var debug_print_limb_checks: bool = false

var player: RigidBody3D

var limb_disabled_by_id: Dictionary = {}
var marker_by_limb_id: Dictionary = {}
var debug_sphere_by_limb_id: Dictionary = {}

var inactive_material: StandardMaterial3D
var near_material: StandardMaterial3D
var disabled_material: StandardMaterial3D

var last_limb_push_state: Dictionary = {}

# While frozen (the player is SLIDING) the limbs read as standing still: push state stays
# empty and the debug dots hold their inactive rest look. Any future limb animation should
# also key off this flag.
var limbs_frozen: bool = false

# Built once in setup() — these never change at runtime, so rebuilding the array
# and a fresh ray query every push tick was pure churn on the hot path.
var _limb_definitions: Array[Dictionary] = []
var _ray_query: PhysicsRayQueryParameters3D
var _sphere_near_by_id: Dictionary = {}


func setup(owner_player: RigidBody3D) -> void:
	player = owner_player

	limb_disabled_by_id[LIMB_LEFT_ARM] = false
	limb_disabled_by_id[LIMB_RIGHT_ARM] = false
	limb_disabled_by_id[LIMB_LEFT_FOOT] = false
	limb_disabled_by_id[LIMB_RIGHT_FOOT] = false

	_limb_definitions = build_limb_definitions()
	_setup_ray_query()
	setup_debug_materials()
	setup_limb_points()
	clear_limb_push_state(false)

	print("LimbPushController setup complete")


func _setup_ray_query() -> void:
	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = true

	if player is CollisionObject3D:
		_ray_query.exclude = [player.get_rid()]


func _process(_delta: float) -> void:
	if player == null:
		return
	
	if get_parent() != player:
		global_transform = player.global_transform


func setup_debug_materials() -> void:
	inactive_material = create_debug_material(inactive_sphere_color)
	near_material = create_debug_material(near_sphere_color)
	disabled_material = create_debug_material(disabled_sphere_color)


func create_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = 0.8
	return material


func setup_limb_points() -> void:
	marker_by_limb_id[LIMB_LEFT_ARM] = get_or_create_limb_point(
		"LeftArmPoint",
		left_arm_marker_path,
		left_arm_fallback_local_offset
	)
	
	marker_by_limb_id[LIMB_RIGHT_ARM] = get_or_create_limb_point(
		"RightArmPoint",
		right_arm_marker_path,
		right_arm_fallback_local_offset
	)
	
	marker_by_limb_id[LIMB_LEFT_FOOT] = get_or_create_limb_point(
		"LeftFootPoint",
		left_foot_marker_path,
		left_foot_fallback_local_offset
	)
	
	marker_by_limb_id[LIMB_RIGHT_FOOT] = get_or_create_limb_point(
		"RightFootPoint",
		right_foot_marker_path,
		right_foot_fallback_local_offset
	)
	
	for limb_id in marker_by_limb_id.keys():
		var marker := marker_by_limb_id[limb_id] as Node3D
		
		if marker != null:
			setup_debug_sphere_for_marker(limb_id, marker)


func get_or_create_limb_point(
	point_name: String,
	marker_path: NodePath,
	fallback_offset: Vector3
) -> Node3D:
	var point_node: Node3D = null
	
	if String(marker_path) != "":
		point_node = get_node_or_null(marker_path) as Node3D
	
	if point_node == null:
		point_node = get_node_or_null(point_name) as Node3D
	
	if point_node == null and auto_create_limb_points:
		var new_marker := Marker3D.new()
		new_marker.name = point_name
		add_child(new_marker)
		new_marker.position = fallback_offset
		point_node = new_marker
	
	return point_node


func setup_debug_sphere_for_marker(limb_id: String, marker: Node3D) -> void:
	if marker == null:
		return
	
	var existing_sphere := marker.get_node_or_null("DebugSphere") as MeshInstance3D
	
	if existing_sphere == null:
		existing_sphere = MeshInstance3D.new()
		existing_sphere.name = "DebugSphere"
		marker.add_child(existing_sphere)
		existing_sphere.position = Vector3.ZERO
	
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = debug_sphere_radius
	sphere_mesh.height = debug_sphere_radius * 2.0
	sphere_mesh.radial_segments = 16
	sphere_mesh.rings = 8
	
	existing_sphere.mesh = sphere_mesh
	existing_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	existing_sphere.visible = show_debug_limb_spheres
	existing_sphere.material_override = inactive_material

	debug_sphere_by_limb_id[limb_id] = existing_sphere
	_sphere_near_by_id[limb_id] = false


func set_limbs_frozen(frozen: bool) -> void:
	if limbs_frozen == frozen:
		return

	limbs_frozen = frozen

	if frozen:
		clear_limb_push_state(false)


func update_limb_push_state(
	preferred_surface_check_direction: Vector3,
	desired_push_direction: Vector3,
	max_check_distance: float,
	using_ctrl_push: bool
) -> Dictionary:
	if player == null or limbs_frozen:
		clear_limb_push_state(using_ctrl_push)
		return last_limb_push_state
	
	if preferred_surface_check_direction.length() < 0.01:
		clear_limb_push_state(using_ctrl_push)
		return last_limb_push_state
	
	preferred_surface_check_direction = preferred_surface_check_direction.normalized()
	
	if desired_push_direction.length() < 0.01:
		desired_push_direction = -preferred_surface_check_direction
	
	desired_push_direction = desired_push_direction.normalized()
	max_check_distance = maxf(max_check_distance, 0.01)
	
	var valid_limb_results: Array[Dictionary] = []

	for limb_definition in _limb_definitions:
		var limb_id: String = limb_definition.get("id", "")
		
		if is_limb_disabled(limb_id):
			continue
		
		var result := check_limb_surface(
			limb_definition,
			preferred_surface_check_direction,
			desired_push_direction,
			max_check_distance
		)
		
		if not result.is_empty():
			valid_limb_results.append(result)
	
	last_limb_push_state = build_limb_push_state(
		valid_limb_results,
		preferred_surface_check_direction,
		desired_push_direction,
		max_check_distance,
		using_ctrl_push
	)
	
	update_all_debug_spheres(last_limb_push_state)
	
	if debug_print_limb_checks and bool(last_limb_push_state.get("has_limb_contact", false)):
		print(
			"Limb push check: ",
			last_limb_push_state.get("summary_text", ""),
			" force ",
			last_limb_push_state.get("force_multiplier", 0.0),
			" angle multiplier ",
			last_limb_push_state.get("angle_force_multiplier", 0.0)
		)
	
	return last_limb_push_state


func build_limb_definitions() -> Array[Dictionary]:
	return [
		{
			"id": LIMB_LEFT_ARM,
			"display_name": "Left Arm",
			"near_text": "Left Arm Near",
			"group": "arm",
			"fallback_offset": left_arm_fallback_local_offset,
			"force_weight": arm_force_weight
		},
		{
			"id": LIMB_RIGHT_ARM,
			"display_name": "Right Arm",
			"near_text": "Right Arm Near",
			"group": "arm",
			"fallback_offset": right_arm_fallback_local_offset,
			"force_weight": arm_force_weight
		},
		{
			"id": LIMB_LEFT_FOOT,
			"display_name": "Left Foot",
			"near_text": "Left Foot Near",
			"group": "foot",
			"fallback_offset": left_foot_fallback_local_offset,
			"force_weight": foot_force_weight
		},
		{
			"id": LIMB_RIGHT_FOOT,
			"display_name": "Right Foot",
			"near_text": "Right Foot Near",
			"group": "foot",
			"fallback_offset": right_foot_fallback_local_offset,
			"force_weight": foot_force_weight
		}
	]


func check_limb_surface(
	limb_definition: Dictionary,
	preferred_surface_check_direction: Vector3,
	desired_push_direction: Vector3,
	max_check_distance: float
) -> Dictionary:
	if player == null:
		return {}
	
	var limb_id: String = limb_definition.get("id", "")
	var origin := get_limb_world_position(limb_id, limb_definition)
	var probe_directions := get_limb_probe_directions(
		limb_id,
		limb_definition,
		preferred_surface_check_direction
	)
	
	var best_result: Dictionary = {}
	var best_score := -999999.0
	
	for probe_direction in probe_directions:
		if probe_direction.length() < 0.01:
			continue
		
		var end := origin + probe_direction.normalized() * max_check_distance
		var ray_result := raycast_limb(origin, end)
		
		if ray_result.is_empty():
			continue
		
		var hit_position: Vector3 = ray_result.get("position", origin)
		var hit_distance := origin.distance_to(hit_position)
		
		var built_result := build_limb_hit_result(
			limb_definition,
			ray_result,
			origin,
			probe_direction.normalized(),
			hit_distance,
			desired_push_direction,
			max_check_distance
		)
		
		var score := float(built_result.get("selection_score", 0.0))
		
		if score > best_score:
			best_score = score
			best_result = built_result
	
	return best_result


func get_feet_nearby_surface(
	max_check_distance: float,
	min_surface_normal_dot: float,
	required_foot_count: int
) -> Dictionary:
	if player == null:
		return {}
	
	var surface_normal := player.global_transform.basis.y.normalized()
	
	if surface_normal.length() < 0.01:
		return {}
	
	max_check_distance = maxf(max_check_distance, 0.01)
	min_surface_normal_dot = clampf(min_surface_normal_dot, -1.0, 1.0)
	required_foot_count = clampi(required_foot_count, 1, 2)
	
	var foot_results: Array[Dictionary] = []
	
	for limb_definition in _limb_definitions:
		var limb_id: String = limb_definition.get("id", "")
		
		if limb_id != LIMB_LEFT_FOOT and limb_id != LIMB_RIGHT_FOOT:
			continue
		
		if is_limb_disabled(limb_id):
			continue
		
		var result := get_foot_nearby_surface(
			limb_id,
			limb_definition,
			surface_normal,
			max_check_distance,
			min_surface_normal_dot
		)
		
		if not result.is_empty():
			foot_results.append(result)
	
	if foot_results.size() < required_foot_count:
		return {}
	
	return build_feet_nearby_surface_result(foot_results)


func get_foot_nearby_surface(
	limb_id: String,
	limb_definition: Dictionary,
	surface_normal: Vector3,
	max_check_distance: float,
	min_surface_normal_dot: float
) -> Dictionary:
	var foot_origin := get_limb_world_position(limb_id, limb_definition)
	var ray_start := foot_origin + surface_normal * 0.05
	var ray_end := foot_origin - surface_normal * max_check_distance
	var ray_result := raycast_limb(ray_start, ray_end)
	
	if ray_result.is_empty():
		return {}
	
	var hit_normal: Vector3 = ray_result.get("normal", Vector3.ZERO)
	
	if hit_normal.length() < 0.01:
		return {}
	
	if hit_normal.normalized().dot(surface_normal) < min_surface_normal_dot:
		return {}
	
	var hit_position: Vector3 = ray_result.get("position", foot_origin)
	var hit_distance := foot_origin.distance_to(hit_position)
	
	if hit_distance > max_check_distance:
		return {}
	
	var built_result := ray_result.duplicate()
	built_result["limb_id"] = limb_id
	built_result["limb_origin"] = foot_origin
	built_result["hit_distance"] = hit_distance
	
	return built_result


func build_feet_nearby_surface_result(foot_results: Array[Dictionary]) -> Dictionary:
	var average_position := Vector3.ZERO
	var average_normal := Vector3.ZERO
	
	for result in foot_results:
		var hit_position: Vector3 = result.get("position", Vector3.ZERO)
		var hit_normal: Vector3 = result.get("normal", Vector3.ZERO)
		
		average_position += hit_position
		
		if hit_normal.length() >= 0.01:
			average_normal += hit_normal.normalized()
	
	average_position = average_position / float(foot_results.size())
	
	if average_normal.length() >= 0.01:
		average_normal = average_normal.normalized()
	
	var built_result: Dictionary = foot_results[0].duplicate()
	built_result["position"] = average_position
	built_result["normal"] = average_normal
	built_result["valid_foot_count"] = foot_results.size()
	built_result["valid_foot_results"] = foot_results
	
	return built_result


func build_limb_hit_result(
	limb_definition: Dictionary,
	ray_result: Dictionary,
	origin: Vector3,
	probe_direction: Vector3,
	hit_distance: float,
	desired_push_direction: Vector3,
	max_check_distance: float
) -> Dictionary:
	var limb_id: String = limb_definition.get("id", "")
	var display_name: String = limb_definition.get("display_name", limb_id)
	var near_text: String = limb_definition.get("near_text", display_name + " Near")
	var limb_group: String = limb_definition.get("group", "")
	var force_weight: float = float(limb_definition.get("force_weight", 0.0))
	var surface_normal: Vector3 = ray_result.get("normal", Vector3.ZERO)
	
	var angle_alignment := get_surface_alignment_to_push_direction(
		surface_normal,
		desired_push_direction
	)
	
	var distance_ratio := clampf(hit_distance / maxf(max_check_distance, 0.001), 0.0, 1.0)
	var distance_score := 1.0 - distance_ratio
	
	var result: Dictionary = ray_result.duplicate()
	result["limb_id"] = limb_id
	result["display_name"] = display_name
	result["near_text"] = near_text
	result["limb_group"] = limb_group
	result["force_weight"] = force_weight
	result["limb_origin"] = origin
	result["probe_direction"] = probe_direction
	result["hit_distance"] = hit_distance
	result["angle_alignment"] = angle_alignment
	result["selection_score"] = angle_alignment * 2.0 + distance_score * 0.35
	
	return result


func raycast_limb(origin: Vector3, end: Vector3) -> Dictionary:
	_ray_query.from = origin
	_ray_query.to = end

	return player.get_world_3d().direct_space_state.intersect_ray(_ray_query)


func get_limb_probe_directions(
	limb_id: String,
	limb_definition: Dictionary,
	preferred_surface_check_direction: Vector3
) -> Array[Vector3]:
	var directions: Array[Vector3] = []
	var player_basis := player.global_transform.basis
	
	append_limb_probe_direction(directions, preferred_surface_check_direction)
	
	if use_perpendicular_limb_probes:
		var limb_group: String = limb_definition.get("group", "")
		var side_sign := get_limb_side_sign(limb_id)
		
		if limb_group == "arm":
			append_limb_probe_direction(directions, player_basis.y)
			append_limb_probe_direction(directions, player_basis.x * side_sign)
			append_limb_probe_direction(directions, get_limb_outward_direction(limb_id))
		
		if limb_group == "foot":
			append_limb_probe_direction(directions, -player_basis.y)
			append_limb_probe_direction(directions, player_basis.x * side_sign)
			append_limb_probe_direction(directions, get_limb_outward_direction(limb_id))
	
	return directions


func append_limb_probe_direction(
	directions: Array[Vector3],
	direction: Vector3
) -> void:
	if direction.length() < 0.01:
		return
	
	direction = direction.normalized()
	
	for existing_direction in directions:
		if existing_direction.normalized().dot(direction) > 0.98:
			return
	
	directions.append(direction)


func get_limb_side_sign(limb_id: String) -> float:
	if limb_id == LIMB_LEFT_ARM or limb_id == LIMB_LEFT_FOOT:
		return -1.0
	
	return 1.0


func get_limb_outward_direction(limb_id: String) -> Vector3:
	var marker := marker_by_limb_id.get(limb_id, null) as Node3D
	
	if marker != null and marker.position.length() >= 0.01:
		return (player.global_transform.basis * marker.position).normalized()
	
	var world_position := get_limb_world_position(limb_id, {})
	var direction := world_position - player.global_position
	
	if direction.length() >= 0.01:
		return direction.normalized()
	
	return -player.global_transform.basis.z


func get_limb_world_position(limb_id: String, limb_definition: Dictionary) -> Vector3:
	var marker := marker_by_limb_id.get(limb_id, null) as Node3D
	
	if marker != null:
		return marker.global_position
	
	var fallback_offset: Vector3 = limb_definition.get("fallback_offset", Vector3.ZERO)
	return player.global_position + player.global_transform.basis * fallback_offset


func build_limb_push_state(
	valid_limb_results: Array[Dictionary],
	preferred_surface_check_direction: Vector3,
	desired_push_direction: Vector3,
	max_check_distance: float,
	using_ctrl_push: bool
) -> Dictionary:
	var total_force_weight := 0.0
	var limb_ids: Array[String] = []
	var limb_display_names: Array[String] = []
	
	for result in valid_limb_results:
		var limb_id: String = result.get("limb_id", "")
		var display_name: String = result.get("display_name", limb_id)
		
		limb_ids.append(limb_id)
		limb_display_names.append(display_name)
		
		total_force_weight += float(result.get("force_weight", 0.0))
	
	var has_limb_contact := valid_limb_results.size() > 0
	var base_limb_force_multiplier := 0.0
	var angle_alignment := 0.0
	var angle_force_multiplier := 0.0
	var final_force_multiplier := 0.0
	
	if has_limb_contact:
		base_limb_force_multiplier = clampf(
			limb_push_min_force_multiplier + total_force_weight * limb_push_force_weight_scale,
			limb_push_min_force_multiplier,
			limb_push_max_force_multiplier
		)
		
		angle_alignment = get_weighted_angle_alignment(valid_limb_results, desired_push_direction)
		angle_force_multiplier = get_angle_force_multiplier(angle_alignment)
		final_force_multiplier = base_limb_force_multiplier * angle_force_multiplier
	
	var primary_surface_result := get_primary_surface_result(valid_limb_results)
	var summary_names := build_summary_names(valid_limb_results)
	var summary_text := join_strings(summary_names, ", ")
	var mode_text := "Back Push" if using_ctrl_push else "Front Push"
	
	if summary_text == "":
		summary_text = "No Limbs Near"
	
	return {
		"has_limb_contact": has_limb_contact,
		"valid_limb_count": valid_limb_results.size(),
		"valid_limb_ids": limb_ids,
		"valid_limb_names": limb_display_names,
		"summary_names": summary_names,
		"summary_text": summary_text,
		"force_multiplier": final_force_multiplier,
		"base_limb_force_multiplier": base_limb_force_multiplier,
		"angle_alignment": angle_alignment,
		"angle_force_multiplier": angle_force_multiplier,
		"total_force_weight": total_force_weight,
		"primary_surface_result": primary_surface_result,
		"valid_limb_results": valid_limb_results,
		"push_direction": desired_push_direction,
		"preferred_surface_check_direction": preferred_surface_check_direction,
		"max_check_distance": max_check_distance,
		"using_ctrl_push": using_ctrl_push,
		"mode_text": mode_text
	}


func get_surface_alignment_to_push_direction(
	surface_normal: Vector3,
	desired_push_direction: Vector3
) -> float:
	if surface_normal.length() < 0.01:
		return 0.0
	
	if desired_push_direction.length() < 0.01:
		return 0.0
	
	return clampf(
		surface_normal.normalized().dot(desired_push_direction.normalized()),
		0.0,
		1.0
	)


func get_weighted_angle_alignment(
	valid_limb_results: Array[Dictionary],
	desired_push_direction: Vector3
) -> float:
	var weighted_alignment := 0.0
	var total_weight := 0.0
	
	for result in valid_limb_results:
		var surface_normal: Vector3 = result.get("normal", Vector3.ZERO)
		var force_weight := maxf(float(result.get("force_weight", 1.0)), 0.01)
		var alignment := get_surface_alignment_to_push_direction(
			surface_normal,
			desired_push_direction
		)
		
		weighted_alignment += alignment * force_weight
		total_weight += force_weight
	
	if total_weight <= 0.0:
		return 0.0
	
	return clampf(weighted_alignment / total_weight, 0.0, 1.0)


func get_angle_force_multiplier(angle_alignment: float) -> float:
	if not use_angle_based_push_strength:
		return 1.0
	
	angle_alignment = clampf(angle_alignment, 0.0, 1.0)
	
	return lerpf(
		min_push_angle_force_multiplier,
		1.0,
		pow(angle_alignment, push_angle_power)
	)


func get_primary_surface_result(valid_limb_results: Array[Dictionary]) -> Dictionary:
	if valid_limb_results.is_empty():
		return {}
	
	var best_result: Dictionary = valid_limb_results[0]
	var best_score := float(best_result.get("selection_score", 0.0))
	
	for result in valid_limb_results:
		var score := float(result.get("selection_score", 0.0))
		
		if score > best_score:
			best_score = score
			best_result = result
	
	return best_result


func build_summary_names(valid_limb_results: Array[Dictionary]) -> Array[String]:
	var valid_by_id: Dictionary = {}
	
	for result in valid_limb_results:
		var limb_id: String = result.get("limb_id", "")
		valid_by_id[limb_id] = true
	
	var names: Array[String] = []
	
	var left_arm_near := bool(valid_by_id.get(LIMB_LEFT_ARM, false))
	var right_arm_near := bool(valid_by_id.get(LIMB_RIGHT_ARM, false))
	var left_foot_near := bool(valid_by_id.get(LIMB_LEFT_FOOT, false))
	var right_foot_near := bool(valid_by_id.get(LIMB_RIGHT_FOOT, false))
	
	if left_arm_near and right_arm_near:
		names.append("Arms Near")
	else:
		if left_arm_near:
			names.append("Left Arm Near")
		
		if right_arm_near:
			names.append("Right Arm Near")
	
	if left_foot_near and right_foot_near:
		names.append("Feet Near")
	else:
		if left_foot_near:
			names.append("Left Foot Near")
		
		if right_foot_near:
			names.append("Right Foot Near")
	
	return names


func clear_limb_push_state(using_ctrl_push: bool) -> void:
	last_limb_push_state = create_empty_state(using_ctrl_push)
	update_all_debug_spheres(last_limb_push_state)


func create_empty_state(using_ctrl_push: bool) -> Dictionary:
	var mode_text := "Back Push" if using_ctrl_push else "Front Push"
	
	return {
		"has_limb_contact": false,
		"valid_limb_count": 0,
		"valid_limb_ids": [],
		"valid_limb_names": [],
		"summary_names": [],
		"summary_text": "No Limbs Near",
		"force_multiplier": 0.0,
		"base_limb_force_multiplier": 0.0,
		"angle_alignment": 0.0,
		"angle_force_multiplier": 0.0,
		"total_force_weight": 0.0,
		"primary_surface_result": {},
		"valid_limb_results": [],
		"push_direction": Vector3.ZERO,
		"preferred_surface_check_direction": Vector3.ZERO,
		"max_check_distance": 0.0,
		"using_ctrl_push": using_ctrl_push,
		"mode_text": mode_text
	}


func update_all_debug_spheres(limb_state: Dictionary) -> void:
	var near_by_id: Dictionary = {}
	
	if not limb_state.is_empty():
		var valid_results: Array = limb_state.get("valid_limb_results", [])
		
		for result in valid_results:
			var limb_id: String = result.get("limb_id", "")
			near_by_id[limb_id] = true
	
	for limb_id in debug_sphere_by_limb_id.keys():
		update_debug_sphere_state(limb_id, bool(near_by_id.get(limb_id, false)))


func update_debug_sphere_state(limb_id: String, is_near: bool) -> void:
	var sphere := debug_sphere_by_limb_id.get(limb_id, null) as MeshInstance3D
	
	if sphere == null:
		return
	
	sphere.visible = show_debug_limb_spheres

	if sphere.mesh is SphereMesh and bool(_sphere_near_by_id.get(limb_id, false)) != is_near:
		var sphere_mesh := sphere.mesh as SphereMesh
		var radius := debug_sphere_near_radius if is_near else debug_sphere_radius
		sphere_mesh.radius = radius
		sphere_mesh.height = radius * 2.0

	_sphere_near_by_id[limb_id] = is_near

	if is_limb_disabled(limb_id):
		sphere.material_override = disabled_material
	elif is_near:
		sphere.material_override = near_material
	else:
		sphere.material_override = inactive_material


func set_limb_disabled(limb_id: String, disabled: bool) -> void:
	limb_disabled_by_id[limb_id] = disabled
	update_debug_sphere_state(limb_id, false)


func is_limb_disabled(limb_id: String) -> bool:
	return bool(limb_disabled_by_id.get(limb_id, false))


func set_arm_disabled(left_side: bool, disabled: bool) -> void:
	if left_side:
		set_limb_disabled(LIMB_LEFT_ARM, disabled)
	else:
		set_limb_disabled(LIMB_RIGHT_ARM, disabled)


func set_foot_disabled(left_side: bool, disabled: bool) -> void:
	if left_side:
		set_limb_disabled(LIMB_LEFT_FOOT, disabled)
	else:
		set_limb_disabled(LIMB_RIGHT_FOOT, disabled)


func reset_disabled_limbs() -> void:
	limb_disabled_by_id[LIMB_LEFT_ARM] = false
	limb_disabled_by_id[LIMB_RIGHT_ARM] = false
	limb_disabled_by_id[LIMB_LEFT_FOOT] = false
	limb_disabled_by_id[LIMB_RIGHT_FOOT] = false
	
	update_all_debug_spheres(last_limb_push_state)


func join_strings(items: Array[String], separator: String) -> String:
	var text := ""
	
	for i in range(items.size()):
		if i > 0:
			text += separator
		
		text += items[i]
	
	return text
