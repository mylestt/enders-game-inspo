class_name SpinningSkybox
extends Node3D

# Rig for a spinning-skybox illusion. Parent a sphere MeshInstance3D under this node
# (textured with a ShaderMaterial using Resources/Materials/Shaders/Gameplay/skybox_fullbright.gdshader) and at runtime
# this node:
#   - LOCKS its position to the active camera every render frame, so the sphere is always
#     centred on the viewer — its surface reads as infinitely far away (you can never reach
#     the edge). It does NOT inherit the camera's ROTATION.
#   - MAINTAINS ITS OWN ORIENTATION: it keeps whatever orientation you gave it in the editor
#     and adds its own slow spin, independent of where the camera looks — so glancing around
#     reveals different parts of the sky instead of a screen-locked painting.
#   - spins at `degrees_per_second` about `spin_axis` (world space).
#
# Purely cosmetic and LOCAL — it tracks get_viewport().get_camera_3d() (the local player's
# camera), so it never touches networked state and needs no @rpc / protocol bump.
#
# Scale the SPHERE MESH child, not this rig — the rig writes an orthonormal (unscaled) basis
# each frame, so any scale on the rig itself is overwritten. Author sky size on the mesh.

## Spin rate about spin_axis, in degrees per second (0 = a static, non-spinning sky).
@export var degrees_per_second: float = 3.0

## World-space axis the sky spins around (normalized at use; zero disables the spin).
@export var spin_axis: Vector3 = Vector3.UP

## When on, the rig's origin snaps to the active camera each frame (the skybox illusion).
## Turn off to leave it anchored in the world (e.g. to preview the spin in isolation).
@export var follow_camera: bool = true

# The rig's own accumulated orientation — seeded from the editor transform, advanced by the
# spin each frame, and kept independent of the camera's look direction.
var _spin: Basis = Basis.IDENTITY


func _ready() -> void:
	# Driven per render frame in _process — physics interpolation would fight it and judder
	# on >60 Hz displays (project convention). Children inherit this OFF.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_spin = global_transform.basis.orthonormalized()


func _process(delta: float) -> void:
	_spin = advance_spin(_spin, spin_axis, degrees_per_second, delta)

	var origin := global_transform.origin

	if follow_camera:
		var camera := get_viewport().get_camera_3d()

		if camera != null:
			origin = camera.global_transform.origin

	global_transform = Transform3D(_spin, origin)


# Advances an orientation by (deg_per_sec * delta) degrees about a world-space axis, kept
# orthonormal so repeated per-frame multiplication never accumulates skew/scale drift.
# Pure and static so it can be unit-tested headless.
static func advance_spin(basis: Basis, axis: Vector3, deg_per_sec: float, delta: float) -> Basis:
	if axis.length_squared() < 0.000001 or is_zero_approx(deg_per_sec):
		return basis.orthonormalized()

	return (Basis(axis.normalized(), deg_to_rad(deg_per_sec) * delta) * basis).orthonormalized()
