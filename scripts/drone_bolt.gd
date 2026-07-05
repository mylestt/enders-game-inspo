class_name DroneBolt
extends Area3D

# Drone bullet: flies dead straight from the barrel, damages the first player it touches,
# pops on anything solid. Built entirely in code — no scene needed.

var direction := Vector3.FORWARD
var speed := 28.0
var damage := 6.0
var life := 4.0


func _init(bolt_direction: Vector3, bolt_speed: float, bolt_damage: float) -> void:
	direction = bolt_direction.normalized()
	speed = bolt_speed
	damage = bolt_damage
	collision_layer = 0

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.09
	shape.shape = sphere
	add_child(shape)

	var mesh := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.07
	ball.height = 0.14
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.4, 0.15)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.15)
	mat.emission_energy_multiplier = 2.5
	ball.material = mat
	mesh.mesh = ball
	add_child(mesh)

	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	global_position += direction * speed * delta
	life -= delta

	if life <= 0.0:
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("drones"):
		return

	if body.has_method("apply_weapon_damage"):
		body.call("apply_weapon_damage", damage, 0)

	queue_free()
