# ARCHITECTURE.md

Zero-G 1v1 arena fighter (Ender's Game Battle Room). Godot 4.6, Forward+, **Jolt** physics, physics interpolation ON. Player is a `RigidBody3D` floating in zero gravity: push off surfaces with limbs, grab walls, surface-walk, suit-boost, fire lag-follow lasers, body-slam. CS-style buy menu for upgrades. ENet multiplayer, server-authoritative hit-reg.

## Stack / config (`project.godot`)
- Main scene: `scenes/main.tscn`. No autoloads.
- `gravity_scale=0`, Jolt, `physics_interpolation=true`, HDR 2D, d3d12 (Win). 1920×1080, `canvas_items` stretch.
- Run loop: nothing spawns until you press **H (host)** or **J (join)** — `NetworkManager` owns all player spawning. Host with 1 peer = playable solo.

## Pattern: Actor + composed controllers
`player.gd` (the RigidBody "Actor") owns the body and routes input; all behavior lives in child-node controllers it calls each frame. Cross-node calls are largely duck-typed (`has_method`/`call`) to stay swappable & multiplayer-tolerant.

### Player scene (`player.tscn`)
```
Player RigidBody3D            player.gd          (gravity 0, damp set in _ready)
├ MovementController          player_movement_controller.gd
├ SuitBoosters                suit_boosters.gd
├ PlayerHUD                   player_hud.gd      (builds HUD procedurally)
├ ImpactController            impact_controller.gd
├ HealthController            health_controller.gd   (res://health_controller.gd — root!)
├ LimbPusherController(Node3D) limb_pusher_controller.gd  + 4 Marker3D (see gotcha)
├ CameraRig (Node3D)          camera_rig.gd      (procedural bob/sway/dip/tilt)
│ └ Camera3D (fov 100)
│   ├ RayCast3D
│   └ LaserController (Node3D) laser_controller.gd
├ UI (CanvasLayer)/HUD/PushChargeBar (legacy, hidden)
├ CollisionShape3D (Capsule)
└ MeshInstance3D (Capsule)
```

### Main scene (`scenes/main.tscn`)
`World Node3D` [main.gd] → DebugTopCamera, BuyMenu [buy_menu.gd, cash 200000], Arena (`arena3.tscn`), Lights (6 OmniLight3D), NetworkManager [wired: player_scene, Players, SpawnPointA/B, BuyMenu], Players (spawn parent), SpawnPointA/B.

## Module map
| File | Role | Key API used by others |
|---|---|---|
| `scripts/player.gd` | Actor: input routing, per-frame orchestration, networking state, body-slam detect | `set_multiplayer_player`, `get_peer_id`, `receive_network_state`, `apply_network_*`, `server_add_hit`, `is_combat_disabled`, upgrade pass-throughs |
| `scripts/player_movement_controller.gd` | Zero-G rotate/roll/stabilize, push-off (jump), grab, feet-gated **surface-walk / ground-lock** mode | `physics_update`, `integrate_forces`, `is_surface_walk_active`, `can_ground_lock`, `apply_grab_distance_upgrade` |
| `scripts/limb_pusher_controller.gd` | 4 limb raycasts (arms/feet) → push dir + angle-scaled force mult; feet raycasts for ground-lock entry | `update_limb_push_state` → state Dict; `get_feet_nearby_surface` |
| `scripts/laser_controller.gd` (on Camera3D) | Screen-space aim reticle w/ follow-lag; local beam VFX; upgrade levels | `get_actual_laser_direction`, `get_laser_*`, `set_input_enabled`, `set_force_aiming`, `apply_laser_*_upgrade` |
| `scripts/suit_boosters.gd` | W/S thrust w/ fuel (purchasable) | `physics_update`, `purchase_suit_boosters`, fuel getters |
| `scripts/impact_controller.gd` | Collision impact → stun/immobilize + cam shake + HUD flash | `integrate_forces`, `is_immobilized`, `ignore_impacts_briefly` |
| `health_controller.gd` | Hit count, combat-disabled at `max_hits`(5) | `add_hit`, `set_network_state`, `is_combat_disabled` |
| `scripts/player_hud.gd` | Builds all HUD UI in code (CanvasLayer 60): stats, reticle, health, push arrow, impact, limb/booster, ground-lock prompt | `update_*` setters |
| `scripts/camera_rig.gd` | Procedural cam offsets between body & Camera3D (bob/dip/sway/tilt) | `kick_landing`; reads `is_surface_walk_mode_active` |
| `scenes/network_manager.gd` | ENet host/join, server-auth spawn + state relay + laser/slam validation + damage sync | RPCs + `submit_local_player_state`, `request_laser_fire`, `request_body_slam` |
| `scripts/buy_menu.gd` | Procedural shop (CanvasLayer 100); applies upgrades via duck-typed calls | `set_local_player` |
| `scripts/main.gd` | World root; F1 debug top-down camera toggle | — |

## Per-frame flow (`player.gd`, local player only)
`_physics_process`: impact tick → laser-cooldown tick → compute lock flags (`is_input_locked`, `buy_menu_open`, surface-walk, free-look) → enable/force laser → query movement (surface-in-range, grabbing, ctrl-push prediction) → HUD updates → `movement.physics_update` (caches limb push + ground-lock readiness, updates limb/ground-lock HUD) → `boosters.physics_update`+UI → `handle_network_laser_fire` → `update_network_send`.
`_integrate_forces`: impact (skip in surface-walk) → movement integrate → `detect_player_body_slam_contacts`.
Remote player: `_physics_process` only runs `update_remote_network_state` (lerp toward target; server snaps).
Input: `_input` routes mouse-motion to movement (body vs free-look), toggles laser on free-look, captures/releases mouse. Movement `_input` handles scroll = jump-force tune.

## Movement (two modes, `MovementMode` enum)
- **ZERO_G**: mouse rotates body; A/D roll (eased ramp `roll_start→roll_torque` over `roll_ramp_time`); Shift stabilize; F grab (cancels velocity, only under `max_grab_speed`); **Space push** off surface in front (Ctrl = push backward). Push prefers `LimbPushController` result (per-limb raycast, force scaled by surface-normal alignment), else legacy center-raycast fallback. Reaction impulse applied to hit RigidBodies.
- **SURFACE_WALK / ground-lock** (toggle **C**): C toggles on/off. Entry no longer depends on where the camera is looking; it requires both feet to be within `surface_walk_foot_check_distance` of a nearby surface found by `LimbPushController.get_feet_nearby_surface`. The entry surface uses the averaged foot hit position/normal, then snaps body to that surface (smooth transition + entry shake). FPS-style mouse-look (yaw around normal, clamped pitch on camera), WASD tangent move w/ snap-to-surface, sprint = Shift; **Space launches off**. Edge/normal checks auto-exit. While active: lasers force-centered, zero-G push/boost/free-look disabled. HUD shows `Ground Lock: READY (C)` when feet can lock and `Ground Lock: ON (C)` while active.

## Combat
- **Laser**: not hitscan-instant-aim — `screen_aim_position` moves with mouse while RMB held; `actual_aim_direction` lerps toward it at `laser_follow_speed` (upgradable). Two reticles: desired circle + actual dot. LMB fires; shooter sees instant local beam (`create_shot_beam`), cooldown `laser_fire_cooldown` (upgradable). Real hit-reg is server-side.
- **Body slam**: `_integrate_forces` contact-monitor; if speed ≥ `body_slam_min_speed`, finds other player via collider walk, sends `request_body_slam` (impulse ∝ velocity, clamped).
- **Health**: server owns hit count; 1 dmg/laser hit; `combat_disabled` at 5 → locks input, disables laser.

## Networking (`network_manager.gd`)
Each peer is `multiplayer_authority` over its own Player. Local = `freeze=false` (simulates); remotes = `freeze=true` (interpolated).
- **Spawn**: server-auth, RPC `client_spawn_player`; late joiners replay existing spawns. `_ready` binds local player → BuyMenu.
- **Transform** (30 Hz, unreliable): local → `submit_local_player_state`. Server applies+broadcasts `client_receive_player_state`; client → `server_receive_player_state` (validates sender==peer) → relay.
- **Laser**: `request_laser_fire` → server `server_process_laser_fire` (clamp cooldown/range/origin-dist, raycast) → broadcast `client_show_remote_laser` VFX + `server_damage_player` on hit → `client_set_player_damage_state`.
- **Body slam**: `request_body_slam` → server validate (distance, pair cooldown, impulse clamp) → `client_apply_body_slam_impulse` (target applies locally, it owns authority).
- `reset_all_players()` exists (server) — unused by UI.

## Economy (`buy_menu.gd`, **B** to toggle)
In-memory `cash` (start 200000 in scene). `shop_items` array: WEAPON (laser_follow 1-3, laser_attack_speed 1-3), SUIT (grab_distance 1-3), SPECIAL (suit_boosters). Tiered: must own prev level. Applies via duck-typed calls to player/laser. No networking/persistence — purely local.

## Input map
`push`=Space · `ctrl_push`=Ctrl · `roll_left`/`walk_left`=A · `roll_right`/`walk_right`=D · `stabilize_rotation`=Shift · `grab`=F · `laser_aim`=RMB · `laser_fire`=LMB · `toggle_buy_menu`=B · `booster_forward`=W · `booster_backward`=S · `free_look`=Alt · `toggle_surface_walk`=C (ground-lock toggle; feet-gated entry) · `host_game`=H · `join_game`=J · `debug_camera`=F1. (No `sprint` action despite code probing it — surface sprint falls back to Shift.)

## Cruft & gotchas
- **Limb-controller name mismatch**: scene node is `LimbPusherController`; movement code searches for `LimbPushController` (no path export set) → fails to find scene node, **auto-creates a second** controller with fallback-offset markers. Scene's 4 Marker3D (all at origin) are orphaned. Functional (fallbacks are the real offsets) but the scene node is dead weight.
- **Ground-lock uses active limb controller**: feet-gated entry uses `LimbPushController.get_feet_nearby_surface`, so with the current name mismatch it uses the auto-created controller and fallback foot offsets, not the `LimbPusherController` scene markers.
- **Scene vs script defaults**: `player.tscn` sets RigidBody `angular_damp=0.5`, but `player.gd _ready` overwrites with `angular_damp_value=1.2`. Export/`_ready` wins over scene inspector value.
- **Dead files**: `scripts/main_script.gd` (AI-assistant plugin stub, unreferenced), `scenes/plugin_ui.tscn` (points to nonexistent `addons/ai_assistant_plugin/...`), `_parse_check.gd.uid` (orphan, no `.gd`). `characters/Y Bot.fbx` + `scenes/y_bot.tscn` unused by main. `scenes/arena.tscn` & `arena_2.tscn` are alternates (main uses `arena3.tscn`). `*.tscn*.tmp` = Godot temp saves. `UI/HUD/PushChargeBar` + HUD `update_push_charge*` = legacy no-ops.
- `sprint` action absent from InputMap (surface-walk sprint uses Shift via `stabilize_rotation` fallback).
- `health_controller.gd` lives at repo root, not `scripts/` (its own debug Label is separate from `PlayerHUDController`'s health panel — two health displays exist).
- Heavy: `LaserController.shot_laser_radial_segments=600` in scene (cylinder beam tessellation).
