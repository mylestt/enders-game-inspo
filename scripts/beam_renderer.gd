class_name BeamRenderer
extends RefCounted

# Shared laser-beam VFX. Used by laser_controller.gd (local shots) and
# network_manager.gd (replicated remote shots) so the beam look stays identical.


static func make_material(color: Color, emission_energy: float, additive: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = emission_energy

	if color.a < 1.0 or additive:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	if additive:
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD

	return material


static func aligned_basis(y_axis: Vector3) -> Basis:
	y_axis = y_axis.normalized()

	var helper := Vector3.UP

	if absf(y_axis.dot(helper)) > 0.95:
		helper = Vector3.RIGHT

	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()

	return Basis(x_axis, y_axis, z_axis).orthonormalized()


# Spawns a short-lived two-layer (glow + core) cylinder beam under parent and
# auto-frees it after lifetime. Glow radius = core_radius * glow_multiplier.
static func spawn(
	parent: Node,
	origin: Vector3,
	end: Vector3,
	core_material: StandardMaterial3D,
	glow_material: StandardMaterial3D,
	core_radius: float,
	glow_multiplier: float,
	radial_segments: int,
	lifetime: float,
	name_prefix: String
) -> void:
	if (end - origin).length() < 0.05:
		return

	var beam_root := Node3D.new()
	beam_root.name = name_prefix + "Beam"
	parent.add_child(beam_root)

	var glow_radius := core_radius * glow_multiplier
	var glow := _make_part(name_prefix + "Glow", glow_material, glow_radius, radial_segments)
	var core := _make_part(name_prefix + "Core", core_material, core_radius, radial_segments)

	beam_root.add_child(glow)
	beam_root.add_child(core)

	_draw_part(glow, origin, end, glow_radius)
	_draw_part(core, origin, end, core_radius)

	var timer := parent.get_tree().create_timer(lifetime)
	timer.timeout.connect(
		func() -> void:
			if is_instance_valid(beam_root):
				beam_root.queue_free()
	)


static func _make_part(part_name: String, material: StandardMaterial3D, radius: float, radial_segments: int) -> MeshInstance3D:
	var beam := MeshInstance3D.new()
	beam.name = part_name

	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 1.0
	mesh.radial_segments = max(radial_segments, 8)
	mesh.rings = 1
	mesh.material = material

	beam.mesh = mesh
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	return beam


static func _draw_part(beam: MeshInstance3D, origin: Vector3, end: Vector3, radius: float) -> void:
	var mesh := beam.mesh as CylinderMesh
	var direction := end - origin
	var length := direction.length()

	if length < 0.05:
		beam.visible = false
		return

	mesh.height = length
	mesh.top_radius = radius
	mesh.bottom_radius = radius

	beam.global_transform = Transform3D(aligned_basis(direction.normalized()), origin + direction * 0.5)
	beam.visible = true
