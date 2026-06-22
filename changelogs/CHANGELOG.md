# Changelog
Changes made by Sam on Friday, June 19th. Co-authored with Opus 4.8.

Change 1 - ## Camera smoothing
The camera was messed up and choppy because it was stuck to a physics object that runs at 60hz, however we want the camera be as many frames as possible, so I decoupled them. To do this, Opus: 
- Enabled physics interpolation so the camera no longer judders on displays faster than the 60 Hz physics tick.
- Added interpolation resets on spawn and surface-walk exit to avoid one-frame teleport smears.

Change 2 - ## Roll ramp-up (A/D)
The A & D keys rolled way too fast, and that would not feel good in gameplay. the player should always feel in control. obviously this may be a setting the user can change, but I still felt it made sense to improve now.
- Zero-G roll now eases from slow to fast while held instead of snapping to full spin.
- Tunable on MovementController: Roll Start Torque, Roll Torque (max), Roll Ramp Time.

Change 3 - ## Procedural camera animation
Added headbob animation when walking and a sprint feature that has increased headbob and 1.25x the movement speed. could delete.
this lives on its own new camera rig node. dont want to pack too many features into one node or script cuz then its hard to debug and esp AI is bad with huge scripts, better to have many smaller ones.
- Headbob, landing dip and strafe-lean apply only during surface-walk; look-sway applies in all modes.
- New CameraRig node (between the body and Camera3D) composites the offsets; all values tunable in the inspector.

Change 4 - ## Look & roll control
Looking around in 0-g was rolling the view, which is a bug i caused earlier but still i did this (spin the mouse in a circle and the horizon tilts) — roll should only be A/D. Tightened both, plus impacts now hit the camera everywhere.
- Mouse look no longer rolls the view (first attempt was a no-op — same accumulation). Roll/tumble still come from A/D and impacts; up/down look is limited, roll with A/D to look further.
- A/D now settles fast after small turns but still drifts after a hard spin (Roll Settle Rate, tunable).
- Hard surface hits (e.g. crashing into a wall) now give a force-scaled camera dip, not just walk-landings.
- Surface sprint set to 1.25× walk; headbob increased 50% (Bob Intensity).

Change 5 - ## turning body upside down
idk how it worked before or what but i ran into an issue so had to do this:
	"Yaw now rotates around the body's own up axis, so moving the mouse left always turns left — even upside-down. (Previously it yawed around a fixed world-anchored "head-up," which inverted left/right once you flipped over.)
Pitch is a two-stage motion: mouse up/down first articulates a neck (camera-only pitch) up to look_neck_limit_degrees (70°, tunable). Past that limit the overflow tumbles the whole body around its right axis — a free, unbounded flip. Your body stays tumbled where you leave it; the neck articulates within its range.
Surface-walk is unchanged — it keeps its own pitch clamp (surface_walk_pitch_limit_degrees) while you're attached to a surface, since you don't want to flip the camera over while walking.
Tunable on MovementController: Look Neck Limit Degrees."

NOTE - had opus on super ultra mode run through all scripts, find ones that had redundant or unopimized code, i manually reviewed, and then it rewrote those scripts. it functions the same, but should work better and be a stronger foundation for the future.
OPTIMIZATIONS - game should run better as some things were redundant (not that it ran bad b4)
laser_controller.gd — added class_name LaserController; beam/material building delegated to BeamRenderer; removed 4 local duplicate funcs.
network_manager.gd — remote beam/material via BeamRenderer; removed 4 local duplicate funcs.
limb_pusher_controller.gd — perf: limb definitions built once instead of every push tick; ray query reused instead of re-allocated per cast (was up to 16/tick); debug sphere mesh rebuilt only on actual near↔far change.
player.gd — perf: typed the laser ref and dropped per-frame has_method/call reflection on the hot paths (laser + surface-walk queries) for direct typed calls.
player_hud.gd — perf + cleanup: 5 stat labels via one add_stat_label helper; FPS text written only when it changes; static-panel relayout only on viewport resize (was every frame).
buy_menu.gd — triple match group dispatch collapsed into one data-driven get_group_handler table.


future reference - things like the players money MUST be held server side, not locally, otherwise players can easily change their own $ amount using like cheat engine. or just verified server side.
