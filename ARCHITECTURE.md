# EndersGameInspo — Architecture

Zero-G 1v1 arena duel (Godot 4.6, Jolt physics, Forward+). Two players float in an arena, push/grab off surfaces to move, fire a barrel-mounted laser, body-slam each other, and buy upgrades. Networked via ENet (host = server + player 1, peer = player 2).

## Scene tree

- **`scenes/main.tscn`** — main scene. Holds `NetworkManager`, `BuyMenu`, `Arena` instance, lights, `Players` container, `SpawnPointA/B`, and a `DebugTopCamera` (driven by `main.gd`).
- **`player.tscn`** — spawned per peer by NetworkManager. `RigidBody3D` root + sub-controller nodes (Movement, SuitBoosters, HUD, Impact, Health) + `Camera3D` → (`RayCast3D`, `LaserController`, `HandHolster` → `RifleTest` with a `Barrel` muzzle marker) + `UI/HUD` + collision/mesh.

## Architecture pattern

Player is one `RigidBody3D` (`player.gd`) acting as a thin coordinator. Each subsystem is its own `Node` with a `setup()` method, owned and driven by the player each physics frame. Input lives in `player.gd._input`; logic/physics live in the controllers — keeps it multiplayer-ready. NetworkManager is server-authoritative: clients request actions, server validates and broadcasts via RPC.

## Scripts

| Script | Attached to | Responsibility |
|---|---|---|
| `scripts/player.gd` | Player RigidBody3D | Coordinator. Owns sub-controllers, routes input, runs physics tick, network send/receive, body-slam detection, laser-fire requests, and a camera wall-clip guard. |
| `scripts/player_movement_controller.gd` | MovementController | Mouse aim (eases body spin toward a decaying target angular velocity — responsive with a short zero-G float), roll/stabilize, free-look camera, wall grab, charged push (normal + ctrl-push), speed clamps, grab-range upgrades. |
| `scripts/laser_controller.gd` | Camera3D/LaserController | Mouse-aimed laser. Fires from the rifle barrel; accurate down the reticle when aiming (RMB), loose hip-fire with movement-driven bloom otherwise. Screen reticle, beam VFX, fire cooldown, follow/attack-speed upgrades. |
| `scripts/weapon_controller.gd` | Camera3D/HandHolster | First-person rifle: sways with look (capped lean toward the reticle so it stays held forward), procedural recoil + player knockback per shot (driven by the laser), exposes the barrel muzzle. |
| `scripts/suit_boosters.gd` | SuitBoosters | Optional W/S thrust with limited fuel. Purchased from buy menu. |
| `scripts/impact_controller.gd` | ImpactController | Detects hard collisions, applies stun/immobilize, camera shake, and HUD impact flash. |
| `health_controller.gd` | HealthController | Hit count, combat-disabled state at max hits, debug health label. (Lives at project root.) |
| `scripts/player_hud.gd` | PlayerHUD | Builds/updates HUD: reticle, push-charge bar (white = a surface is in range, faded red = none), push-direction arrow, velocity readout, booster fuel bar, impact overlay. |
| `scenes/network_manager.gd` | NetworkManager | Host/join, spawn/despawn players, server-authoritative state replication, laser hit-reg, body-slam validation, damage broadcast. |
| `scripts/buy_menu.gd` | BuyMenu | Code-built shop UI. Cash + tiered upgrades (laser tracking, attack speed, grab distance, suit boosters); applies them to the local player. |
| `scripts/main.gd` | World Node3D | Toggles the debug top-down camera. |

## Controls

Mouse = aim/rotate · LMB = fire laser · RMB = laser aim (accurate; hip-fire when not held) · Space = charge/release push · Ctrl+Space = ctrl-push (forward) · A/D = roll · W/S = boosters · F = grab wall · Q = free-look · Shift = stabilize · B = buy menu · H = host · J = join · F1 = debug camera.

## Dead / unused (left untouched)

- `scripts/main_script.gd` — leftover "AI Assistant Plugin" placeholder, not referenced by any scene.
- `scenes/plugin_ui.tscn` — references `addons/ai_assistant_plugin/` which does not exist in the project.
</content>
