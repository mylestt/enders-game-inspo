# ARCHITECTURE.md

Zero-G arena prototype in Godot 4.6 using Jolt physics and physics interpolation. The player is a `RigidBody3D` with composed child controllers for movement, impacts, health, HUD, suit boosters, and weapons. Multiplayer currently handles player spawning, transform relay, body-slam impulse relay, and prototype weapon damage validation.

## Stack / Config
- Main scene: `scenes/main.tscn`
- No autoloads.
- Input starts spawning when you press H to host or J to join. Hosting with one peer is playable solo.
- Main input actions: Space push, Ctrl reverse push, A/D roll or surface-walk strafe, Shift stabilize/sprint fallback, F grab, B buy menu, LMB `weapon_fire`, W/S suit boosters, Alt free look, C surface-walk toggle, H/J host/join, F1 debug camera.

## Player Scene
```
Player RigidBody3D              scripts/player.gd
|-- MovementController          scripts/player_movement_controller.gd
|-- SuitBoosters                scripts/suit_boosters.gd
|-- PlayerHUD                   scripts/player_hud.gd
|-- PlayerHealth                scripts/player_health.gd
|-- ImpactController            scripts/impact_controller.gd
|-- WeaponInventory             scripts/weapons/weapon_inventory.gd
|-- LimbPusherController        scripts/limb_pusher_controller.gd
|-- CameraRig                   scripts/camera_rig.gd
|   `-- Camera3D
|       `-- WeaponMount
|-- CollisionShape3D
`-- MeshInstance3D
```

## Module Map
| File | Role | Key API |
|---|---|---|
| `scripts/player.gd` | Actor orchestration, local input routing, network transform state, body-slam contact detection, weapon hit submission, shop pass-throughs | `set_multiplayer_player`, `receive_network_state`, `submit_weapon_hit`, `apply_weapon_damage`, `purchase_minigun`, `purchase_suit_boosters` |
| `scripts/player_movement_controller.gd` | Zero-G rotation/roll/stabilize, push-off, grab, surface-walk/ground-lock | `physics_update`, `integrate_forces`, `is_surface_walk_active`, `apply_grab_distance_upgrade` |
| `scripts/player_health.gd` | Simple whole-player health component for prototype damage | `setup`, `apply_damage`, `heal`, `reset_health`, `set_health_state` |
| `scripts/weapons/weapon.gd` | Base weapon contract, shared recoil stats, hitscan firing/damage helper | `equip`, `unequip`, `set_trigger_held`, `is_firing`, `request_recoil`, `fire_hitscan` |
| `scripts/weapons/weapon_inventory.gd` | Owns unlock/equip/input routing for weapons mounted under `WeaponMount` | `purchase_weapon`, `equip_weapon`, `purchase_minigun`, `get_has_minigun` |
| `scripts/weapons/weapon_spring_sway.gd` | Deterministic spring weapon sway and recoil receiver on the mount; affects the equipped weapon transform | `set_equipped_weapon`, `reset_sway`, `apply_recoil` |
| `scripts/weapons/weapon_hitscan_tracer_effect.gd` | Short-lived world-space hitscan tracer VFX with muzzle flash, jagged streak, and impact spark | `play` |
| `scripts/weapons/minigun_weapon.gd` | Minigun-specific barrel lookup, wind-up, barrel spin, firing-state threshold, round cadence | `set_trigger_held`, `get_windup_amount` |
| `scripts/suit_boosters.gd` | Purchasable W/S propulsion with fuel | `physics_update`, `purchase_suit_boosters`, fuel getters |
| `scripts/impact_controller.gd` | Collision impact stun, camera shake, HUD flash | `integrate_forces`, `is_immobilized`, `ignore_impacts_briefly` |
| `scripts/player_hud.gd` | Procedural HUD for health/stats, movement reticle, weapon aim reticle, push arrow, impact, limb/booster/ground-lock prompts | `update_*` setters |
| `scenes/network_manager.gd` | ENet host/join, spawn, state relay, body-slam validation/relay, prototype weapon hit validation/damage broadcast | `submit_local_player_state`, `request_body_slam`, `request_weapon_hit` |
| `scripts/buy_menu.gd` | Procedural shop; applies purchases/upgrades via player methods | `set_local_player` |

## Weapon Flow
The buy menu calls `player.purchase_minigun()`. The player delegates to `WeaponInventory`, which records ownership, instantiates `scenes/minigun.tscn` under `CameraRig/Camera3D/WeaponMount`, and calls `equip(owner_player)`.

Each physics frame, `player.gd` calls `weapon_inventory.update_weapon_input(input_enabled)`. The inventory maps LMB through the generic `weapon_fire` action and sets the equipped weapon trigger state. `MinigunWeapon` owns its wind-up value, barrel rotation, firing-state threshold, and round cadence.

`WeaponSpringSway` is attached to `CameraRig/Camera3D/WeaponMount`. It uses a deterministic spring (`offset`, `velocity`, `stiffness`, `damping`) driven by camera look velocity, so it can affect future muzzle/barrel firing consistently. Weapon weight scales amplitude and lag, with caps to keep heavy weapons readable. It also receives recoil impulses from the equipped weapon, so recoil, sway, the muzzle marker, and the weapon-aim reticle all move through the same transform.

Weapons expose recoil values on the base `Weapon` class. A braced shooter sends recoil to the mount through `request_recoil()` and `WeaponInventory` forwards it to the sway/recoil receiver. A free-floating shooter can instead receive body knockback/torque through `apply_fire_recoil()`. The minigun applies this per fired round.

Competitive instant-fire weapons call `Weapon.fire_hitscan()`. The ray starts at the weapon muzzle, uses the current sway/recoil direction, applies optional `hitscan_spread_degrees`, excludes the owning player, and stops at the first hit point. Spread is a `Vector2`: X is horizontal yaw spread, Y is vertical pitch spread. The minigun uses this path and spawns `scenes/hitscan_tracer_effect.tscn` under the world `WeaponEffects` node. That effect is visual-only: it grows a jagged tracer from the muzzle for frame-zero barrel connection, fades quickly, adds a short muzzle flash, and shows a small impact spark when the ray hits.

Hitscan weapons can also submit damage through the owning player. In local/non-network testing, the hit target receives damage directly. In multiplayer, the owner asks `NetworkManager.request_weapon_hit()`, the server performs simple plausibility checks, then broadcasts `client_apply_weapon_damage()` so every peer sees the same prototype health value.

The old moving projectile/tracer prototype was removed because the active minigun path is hitscan. Add a fresh projectile path later if a slower weapon needs true travel time.

Weapons can set `Weapon.pivot_node_path` so their chosen part sits on the mount origin when equipped. The minigun uses `Box`, so sway rotations happen around the receiver/box instead of the imported scene's center.

Weapons can also set `Weapon.aim_origin_node_path` and `Weapon.aim_local_direction`. The minigun uses a `Muzzle` marker and local +X aim direction. `PlayerHUDController` shows an open-circle reticle at the current weapon aim projection, so spring sway visibly changes where the barrel is pointing. `player.gd` can optionally raycast the reticle with `weapon_aim_reticle_use_world_raycast`, but it defaults off to avoid collision-triangle jitter.

## Per-Frame Flow
Local player `_physics_process`:
impact tick -> lock flags -> movement query/HUD update -> movement physics -> weapon input -> suit booster physics -> network state send.

Local player `_integrate_forces`:
impact integration, movement integration, body-slam contact detection.

Remote player `_physics_process`:
interpolate toward the latest network transform target.

## Economy
`BuyMenu` keeps local in-memory cash. Current shop:
- WEAPONS: Minigun, one-time purchase, immediately equips.
- SUIT UPGRADES: Grab Distance I-III, tiered.
- SPECIAL SUIT SYSTEMS: Suit Boosters, one-time purchase.

Purchases are local-only for now. Weapon ownership and equipped state are not persisted or replicated yet.

## Notes
- Weapon logic is intentionally split: inventory owns ownership/equip/input, individual weapon scenes own behavior, and player only delegates.
- The minigun auto-finds child `Node3D`s whose names contain `barrel` and `box`; set exported node paths on `scenes/minigun.tscn` if the imported names do not match.
