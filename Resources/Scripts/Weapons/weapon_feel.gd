class_name WeaponFeel
extends RefCounted

# Frame-rate-independent smoothing helpers for the viewmodel animator.

# Exponential decay toward a target (framerate-independent lerp).
static func decay(current: float, target: float, speed: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-speed * delta))


static func decay_vec3(current: Vector3, target: Vector3, speed: float, delta: float) -> Vector3:
	return current.lerp(target, 1.0 - exp(-speed * delta))


# One integration step of a damped spring's velocity toward `target`.
static func spring_velocity(
	offset: Vector3,
	velocity: Vector3,
	target: Vector3,
	stiffness: float,
	damping: float,
	delta: float
) -> Vector3:
	return velocity + (-(offset - target) * stiffness - velocity * damping) * delta
