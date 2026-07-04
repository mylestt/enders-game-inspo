class_name WeaponMuzzleFlash
extends Node3D

# Per-gun muzzle flash, the same pattern as the per-gun tracer scenes: each gun gets its own
# scenes/<gun>_muzzle_flash.tscn (a scene whose root runs this script) and points its
# Weapon.muzzle_flash_scene export at it. Open that scene to tune everything about the
# gun's flash — which Binbun effect it uses, length/width/size, colors, light, speed —
# from flat inspector knobs.
#
# The Weapon instantiates ONE instance at equip, places it at the muzzle facing down the
# barrel, and calls play() once per fired round, so the flash follows the gun's exact fire
# rate and fire pattern. One persistent re-triggered effect costs the same at any fire rate
# (the minigun fires 50/s).
#
# This wrapper is also the ONE place that knows the Binbun pack's quirks:
#   - effects fire along their local +X (this node's +X is the barrel direction),
#   - they self-loop unless one_shot = true / autoplay = false,
#   - they idle with their Glow mesh + OmniLight partially LIT (snuffed here),
#   - their materials are SHARED .tres resources (duplicated here so two guns using the
#     same effect can't recolor each other).

# The Binbun effect scene to use (MuzzleFlashVFX/muzzle_flash/effects/… — any of the
# muzzle/short/wide/big variants). Applied once at _ready.
@export var effect_scene: PackedScene = preload("res://MuzzleFlashVFX/muzzle_flash/effects/muzzle_flash/muzzle_flash_01.tscn")

@export_group("Shape")
# Overall size of the flash; length/width then shape it relative to this.
@export var overall_scale: float = 0.5
# Stretch along the barrel (1 = the effect's natural proportions).
@export var flash_length: float = 1.0
# Thickness across the barrel.
@export var flash_width: float = 1.0
# Fine positional nudge, in this node's space (+X = down the barrel).
@export var muzzle_offset: Vector3 = Vector3.ZERO

@export_group("Colors")
# Off = keep the effect scene's own shipped colors.
@export var override_colors: bool = false
@export var primary_color: Color = Color(1.0, 0.69, 0.0)
@export var secondary_color: Color = Color(1.0, 0.38, 0.0)

@export_group("Light")
@export var light_enabled: bool = true
# Off = keep the effect scene's own light color/energy.
@export var override_light: bool = false
@export var light_color: Color = Color(1.0, 0.69, 0.0)
@export var light_energy: float = 2.0

@export_group("Timing")
# >1 = snappier/shorter flash, <1 = longer burn. 1 = the effect's authored 0.2 s.
@export var speed_scale: float = 1.0
# Hard-stop the flash the INSTANT the gun stops firing (trigger released, barrels below
# speed, reload) instead of letting the last burst burn out. Turn ON for sustained-fire
# guns like the minigun; leave OFF for single-shot/burst guns, or their final flash gets
# clipped the frame after the trigger releases.
@export var cut_on_fire_stop: bool = false

var effect: Node3D


func _ready() -> void:
	if effect_scene == null:
		return

	var instance := effect_scene.instantiate() as Node3D

	if instance == null:
		push_warning("WeaponMuzzleFlash effect_scene must be a Node3D-rooted effect.")
		return

	# Must be set BEFORE add_child: the pack's controller autoplays (and then LOOPS) from
	# its _ready otherwise.
	if "one_shot" in instance:
		instance.set("one_shot", true)

	if "autoplay" in instance:
		instance.set("autoplay", false)

	add_child(instance)
	effect = instance

	_make_materials_unique()
	_apply_shape()
	_apply_colors()
	_apply_light()
	_apply_timing()
	_snuff_idle()


# One flash burst. Called by the Weapon per fired round.
func play() -> void:
	if effect == null:
		return

	effect.visible = true   # undo a previous stop()

	if effect.has_method("play"):
		effect.call("play")


# Kills everything the flash renders RIGHT NOW: animation, live particles, glow, light.
# play() fully revives it.
func stop() -> void:
	if effect == null:
		return

	var anim := effect.get_node_or_null("AnimationPlayer") as AnimationPlayer

	if anim != null:
		anim.stop(true)   # keep_state: don't snap tracks back to their t=0 (lit) values

	for child in effect.get_children():
		if child is GPUParticles3D:
			(child as GPUParticles3D).emitting = false

	# Hiding the effect root also kills its OmniLight and any particles mid-lifetime.
	effect.visible = false


# Called by the Weapon whenever it stops firing (see Weapon.set_firing).
func on_fire_stopped() -> void:
	if cut_on_fire_stop:
		stop()


# The pack's materials are shared .tres resources; the controller's color setters (and our
# idle snuff) write straight into them, so without this two guns using the same effect
# variant would tint/darken each other. Duplicating per instance isolates every gun.
func _make_materials_unique() -> void:
	for child in effect.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D

			if geometry.material_override != null:
				geometry.material_override = geometry.material_override.duplicate()


func _apply_shape() -> void:
	var s := maxf(overall_scale, 0.001)
	effect.scale = Vector3(
		maxf(flash_length, 0.01),
		maxf(flash_width, 0.01),
		maxf(flash_width, 0.01)
	) * s
	effect.position = muzzle_offset


func _apply_colors() -> void:
	if not override_colors:
		return

	# The controller's export setters push these into the (now unique) shader materials.
	effect.set("primary_color", primary_color)
	effect.set("secondary_color", secondary_color)


func _apply_light() -> void:
	effect.set("light_enable", light_enabled)

	if not override_light:
		return

	effect.set("light_color", light_color)
	effect.set("light_energy", light_energy)


func _apply_timing() -> void:
	if not is_equal_approx(speed_scale, 1.0):
		effect.set("speed_scale", maxf(speed_scale, 0.05))


# The pack's effects idle with their Glow mesh and OmniLight partially lit (the animation
# only zeroes them at the END of a play). Zero both so the muzzle stays dark until fired.
func _snuff_idle() -> void:
	var glow := effect.get_node_or_null("Glow") as MeshInstance3D

	if glow != null and glow.material_override != null:
		glow.material_override.set("shader_parameter/alpha_multiplier", 0.0)

	var light := effect.get_node_or_null("Light")

	if light != null and "light_multiplier" in light:
		light.set("light_multiplier", 0.0)
