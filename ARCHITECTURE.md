# ARCHITECTURE.md

Zero-G arena prototype in Godot 4.6 using Jolt physics and physics interpolation. The player is a `RigidBody3D` with composed child controllers for movement, impacts, health, HUD, suit boosters, and weapons. On top of that sits a **server-authoritative multiplayer stack**: a lobby system, round/team scoring, procedural + custom map generation, and an admin/server-control layer. Deployed as a headless dedicated server (DigitalOcean VPS).

> This file is the technical architecture. `PROJECT_OVERVIEW.md` is the design vision; `CLAUDE.md` is the current-state + run/deploy + gotchas handoff; `DEPLOY.md` is the VPS deploy runbook.

## Stack / Config
- **Boot scene:** `scenes/start_menu.tscn` (front-end menu). **Game scene:** `scenes/main.tscn`.
- **No autoloads** — static holders `GameLaunch` (launch intent + cmdline overrides) and `GameSettings` (saved options) instead.
- **Startup:** the menu records intent on `GameLaunch` and changes to `main.tscn`; `NetworkManager.apply_launch_mode()` acts on it. Modes: `TEST_ARENA` (local listen-server, auto-spawns you solo), `MULTIPLAYER_BROWSE` (connect + browse lobbies), `MULTIPLAYER_HOST` (connect + create a lobby), `DEDICATED_SERVER` (headless, no local player). Cmdline flags (`--server`, `--join <ip>`, `--map`, rule flags) bypass the menu — see `GameLaunch.apply_cmdline_overrides()`.
- **Run/deploy:** local test = `host_server.bat` + Multiplayer→Join `127.0.0.1`; VPS deploy = `DEPLOY.md` (re-export + **stop server before scp** + restart).
- Main input actions: Space push, Ctrl reverse push, A/D roll or surface-walk strafe, Shift stabilize/sprint, F grab, B buy menu, LMB `weapon_fire`, W/S suit boosters, Alt free look, C surface-walk toggle, F10 admin console, Tab scoreboard, F1 debug camera. (H/J host/join still work in-arena as a legacy path.)

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

## Game Scene (`scenes/main.tscn`)
```
World Node3D                     scripts/main.gd (debug-camera toggle)
|-- DebugTopCamera Camera3D
|-- BuyMenu (CanvasLayer)        scripts/buy_menu.gd
|-- GeneratedMap                 instance of scenes/test_map.tscn (MapGenerator) — the arena
|-- NetworkManager               scenes/network_manager.gd
|-- RoundManager                 scripts/round_manager.gd
|-- LobbyManager                 scripts/lobby_manager.gd
|-- LobbyBrowser (CanvasLayer)   scripts/lobby_browser.gd
|-- RoundHUD (CanvasLayer)       scripts/round_hud.gd
|-- ServerAdmin                  scripts/server_admin.gd
|-- AdminConsole (CanvasLayer)   scripts/admin_console.gd
|-- Scoreboard (CanvasLayer)     scripts/scoreboard.gd
|-- Players (Node3D)             players spawned here at runtime
|-- WeaponEffects (Node3D)       parent for tracers/effects
|-- SpawnPointA / SpawnPointB    fallback spawn markers
```
The arena's real spawns/gates come from the **map** (marker groups `spawn_team_a` / `spawn_team_b`, gate groups `gate_team_a` / `gate_team_b`). `SpawnPointA/B` are only fallbacks used when no group markers exist.

## Module Map
| File | Role | Key API |
|---|---|---|
| `scripts/player.gd` | Actor orchestration, local input routing, network transform state, body-slam contact detection, weapon hit submission, shop pass-throughs | `set_multiplayer_player`, `receive_network_state`, `submit_weapon_hit`, `apply_weapon_damage`, `purchase_weapon`, `purchase_suit_boosters` |
| `scripts/player_movement_controller.gd` | Zero-G rotation/roll/stabilize, push-off, grab, surface-walk/ground-lock | `physics_update`, `integrate_forces`, `is_surface_walk_active`, `apply_grab_distance_upgrade` |
| `scripts/player_health.gd` | Simple whole-player health component for prototype damage | `setup`, `apply_damage`, `heal`, `reset_health`, `set_health_state` |
| `scripts/weapons/weapon.gd` | Base weapon contract, shared recoil stats, hitscan firing/damage helper | `equip`, `unequip`, `set_trigger_held`, `is_firing`, `request_recoil`, `fire_hitscan` |
| `scripts/weapons/weapon_inventory.gd` | Owns unlock/equip/input routing for weapons mounted under `WeaponMount` | `purchase_weapon`, `has_weapon`, `equip_weapon` |
| `scripts/weapons/weapon_spring_sway.gd` | Deterministic spring weapon sway and recoil receiver on the mount; affects the equipped weapon transform | `set_equipped_weapon`, `reset_sway`, `apply_recoil` |
| `scripts/weapons/weapon_hitscan_tracer_effect.gd` | Short-lived world-space hitscan tracer VFX with muzzle flash, jagged streak, and impact spark | `play` |
| `scripts/weapons/minigun_weapon.gd` | Minigun-specific barrel lookup, wind-up, barrel spin, firing-state threshold, round cadence | `set_trigger_held`, `get_windup_amount` |
| `scripts/suit_boosters.gd` | Purchasable W/S propulsion with fuel | `physics_update`, `purchase_suit_boosters`, fuel getters |
| `scripts/impact_controller.gd` | Collision impact stun, camera shake, HUD flash | `integrate_forces`, `is_immobilized`, `ignore_impacts_briefly` |
| `scripts/player_hud.gd` | Procedural HUD for health/stats, movement reticle, weapon aim reticle, push arrow, impact, limb/booster/ground-lock prompts | `update_*` setters |
| `scenes/network_manager.gd` | ENet host/join, spawn, state relay, body-slam validation/relay, prototype weapon hit validation/damage broadcast | `submit_local_player_state`, `request_body_slam`, `request_weapon_hit` |
| `scripts/buy_menu.gd` | Procedural shop; applies purchases/upgrades via player methods | `set_local_player` |

## Multiplayer & Lobby
Server-authoritative over ENet. `NetworkManager` owns the peer and relays player transforms, body-slams, weapon hits, weapon tracers, and admin cash. On a **lobby-mode** server (dedicated), connecting does NOT auto-spawn — clients connect only to browse, and spawn when they JOIN a lobby (`server_spawn_in_lobby`). Test Arena / listen-server keep the old auto-spawn.

All client-supplied RPC vectors/floats are rejected server-side if non-finite (NaN/Inf would survive `clampf` and poison replicated physics/health). Player-state packets carry a per-sender sequence number so out-of-order unreliable packets can't rewind a replica, and the server does not echo a player's state back to its own sender. Dedicated-server (headless) builds skip all HUD/menu UI construction; only gameplay nodes run.

`LobbyManager` is the server-authoritative lobby boss. For now there is **one active lobby**, but the data model and RPCs (`server_request_lobby_list` / `_create_lobby` / `_join_lobby`) are shaped to become many. Creating or joining a lobby applies its rule config to `RoundManager` and its map config to the `MapGenerator`, and syncs the map to the joining client (`client_apply_map_config` → `MapGenerator.rebuild_from_launch`). `LobbyBrowser` is the in-game browser (list, refresh, password, join).

Teams are assigned by **spawn-slot parity** (`NetworkManager.get_team_for_peer`): even = A, odd = B, filled in join order → 1v1 at 2 players, 2v1 at 3, 2v2 at 4. Spawn transforms come from the map's `spawn_team_a/b` marker groups.

## Rounds & Scoring (`scripts/round_manager.gd`)
Server-authoritative state machine: `WAITING_FOR_PLAYERS → COUNTDOWN → ACTIVE → ROUND_END`. A round ends when an entire team is eliminated (all its players at 0 health); the surviving team scores. `team_scores {a, b}` is the ONE match score: it drives match-over (`points_to_win`) and the `RoundHUD`, and admin `set_score <a|b>` / `add_score <a|b>` / `end_round [a|b]` operate on it directly. The scoreboard's per-player K/D (NetworkManager stats) is display-only. State, team scores, and player resets replicate to clients.

## Map Loading (`scripts/map_generator.gd`)
`MapGenerator` is a **scene loader** (the old procedural generator was removed). Maps are hand-authored `.tscn` scenes registered in the `MAPS` const — each entry is `{id, name, scene}` with the scene **preloaded** (so the exporter packs it). At runtime `build_map()` reads `map_id` (from `GameLaunch`), looks it up in `MAPS`, and instantiates that scene under a `GeneratedMap` child. Each map scene must contain its own spawn markers in groups `spawn_team_a` / `spawn_team_b` (optional gates in `gate_team_*`); NetworkManager reads those groups directly. Current maps: `diamond` (`DiamondArena.tscn`) only. `rebuild_from_launch()` rebuilds at runtime from `GameLaunch.map_id` (used for lobby map sync). `scenes/test_map.tscn` is the standalone preview/edit scene (set `map_id` in the inspector). Static helpers `get_map_ids()` / `get_map_name()` / `has_map()` / `normalize_map_id()` drive the menu picker and cmdline `--map <id>`.

## Admin & Server Control
`ServerAdmin` (server-authoritative) accepts commands two ways: a polled **command file** (the VPS appends to `enders_admin_commands.txt`) and **in-game RPCs** gated by `--admin-key`. It dispatches to `RoundManager.server_command()` and NetworkManager cash methods (`set_starting_cash`, `give_money`, …). `AdminConsole` is the **F10** in-game console. `scoreboard.gd` is the **Tab**-held team K/D scoreboard (backed by NetworkManager kill/death tracking + `scoreboard_changed`). `server_control.ps1` is a PowerShell menu for managing the VPS (logs, commands, upload, restart).

## In-Game UI (all procedural, built in GDScript)
`player_hud` (per-local-player; hidden on remote copies via `set_hud_active`), `round_hud` (team-score bar), `lobby_browser`, `scoreboard` (Tab), `admin_console` (F10), plus the front-end `settings_menu` and `map_setup_menu`.

## Settings (`scripts/game_settings.gd`)
Static holder + `settings_menu.gd`: rebindable keybinds (any action), FOV (70–110), mouse sensitivity, master volume, fullscreen. Persisted to `user://settings.cfg` and applied on boot (`load_and_apply`).

## Weapon Flow
The buy menu calls `player.purchase_weapon(&"minigun")`. The player delegates to `WeaponInventory`, which records ownership, instantiates `scenes/minigun.tscn` under `CameraRig/Camera3D/WeaponMount`, and calls `equip(owner_player)`.

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
`BuyMenu` shows a display copy of the player's cash. Current shop:
- WEAPONS: Minigun / Railgun / Battle Rifle / Plasma Cannon, one-time purchases, immediately equip.
- SUIT UPGRADES: Grab Distance I-III, tiered.
- SPECIAL SUIT SYSTEMS: Suit Boosters, one-time purchase.

Online, the economy is **server-authoritative** (`scripts/server_economy.gd`, a child of NetworkManager): the server owns each peer's cash and item ownership, purchases go through `request_purchase` → server validation → `client_purchase_result` (the buy menu applies the item only on confirmation), and admin `give_money`/`set_money` mutate the server ledger which syncs back down. The same node keeps a per-weapon **ammo ledger** (rounds consumed per accepted damage claim, reload timing, reserve, fire-rate token bucket) used to validate weapon-hit claims. Offline Test Arena keeps the old local wallet. Starting cash is seeded from the lobby or `--starting-cash`.

## Notes
- Weapon logic is intentionally split: inventory owns ownership/equip/input, individual weapon scenes own behavior, and player only delegates.
- The minigun auto-finds child `Node3D`s whose names contain `barrel` and `box`; set exported node paths on `scenes/minigun.tscn` if the imported names do not match.
- Surface-walk auto-aligns the body to the surface beneath you within `surface_walk_slope_align_max_degrees`; steeper drops you to zero-G. Tunable via the `surface_walk_slope_align_*` exports.
- A multiplayer **"rpc node checksum failed"** error means the client and server are running different code versions (usually the VPS has an old binary) — redeploy.
- Open threads / TODOs (no death/spectate state, late-join state sync) are tracked in `CLAUDE.md`.
