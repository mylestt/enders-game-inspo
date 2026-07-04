@tool
extends Node3D
class_name SpawnPoint

# Authoring aid for spawn placement. A player-sized capsule you drop into a map scene and
# rest on a surface; at runtime it joins the same `spawn_team_a` / `spawn_team_b` groups that
# NetworkManager reads, so it's a drop-in replacement for the old bare Marker3D spawns.
#
# The capsule matches the player collision capsule (radius 0.5, height 2.0), so "resting the
# capsule on the floor, facing where you want" places the player exactly there. Players spawn
# in ground (surface-walk) mode on the nearest surface — see PlayerMovementController's spawn
# probe — so orient the capsule upright on the face you want them standing on; the small nub
# marks the facing direction (the player's forward, -Z).
#
# Team A = blue, Team B = orange. The visual only shows in the editor unless show_in_game.

enum Team { A, B }

@export var team: Team = Team.A:
	set(value):
		team = value
		_refresh()

# Leave the capsule visible during play (debugging spawn placement). Off by default.
@export var show_in_game: bool = false:
	set(value):
		show_in_game = value
		_refresh()

const PLAYER_CAPSULE_RADIUS := 0.5
const PLAYER_CAPSULE_HEIGHT := 2.0

var _capsule: MeshInstance3D
var _facing: MeshInstance3D


func _ready() -> void:
	_ensure_visual()
	_refresh()

	if not Engine.is_editor_hint():
		add_to_group(group_name())


func group_name() -> String:
	return "spawn_team_a" if team == Team.A else "spawn_team_b"


func team_color() -> Color:
	return Color(0.35, 0.6, 1.0) if team == Team.A else Color(1.0, 0.55, 0.3)


# Builds the capsule + facing nub once. Kept as runtime children (not saved into the map
# scene) so a map only stores the SpawnPoint node + its transform.
func _ensure_visual() -> void:
	if _capsule == null:
		_capsule = MeshInstance3D.new()
		_capsule.name = "SpawnCapsuleVisual"
		var mesh := CapsuleMesh.new()
		mesh.radius = PLAYER_CAPSULE_RADIUS
		mesh.height = PLAYER_CAPSULE_HEIGHT
		_capsule.mesh = mesh
		_capsule.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_capsule)

	if _facing == null:
		_facing = MeshInstance3D.new()
		_facing.name = "SpawnFacingVisual"
		var nub := BoxMesh.new()
		nub.size = Vector3(0.12, 0.12, 0.4)
		_facing.mesh = nub
		# Sits in front of the capsule (-Z = the player's forward) at chest height.
		_facing.position = Vector3(0.0, 0.2, -(PLAYER_CAPSULE_RADIUS + 0.25))
		_facing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_facing)


func _refresh() -> void:
	if _capsule == null or _facing == null:
		return

	var color := team_color()

	var body_mat := StandardMaterial3D.new()
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body_mat.albedo_color = Color(color.r, color.g, color.b, 0.28)
	body_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_capsule.material_override = body_mat

	var nub_mat := StandardMaterial3D.new()
	nub_mat.albedo_color = color
	nub_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_facing.material_override = nub_mat

	var visible_now := Engine.is_editor_hint() or show_in_game
	_capsule.visible = visible_now
	_facing.visible = visible_now
