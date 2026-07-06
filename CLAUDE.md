# CLAUDE.md — Zero-G Tactical FPS (Godot 4.6.3)

Current-state + gotchas handoff for AI sessions. Design vision: `PROJECT_OVERVIEW.md`.
Player/weapon internals: `ARCHITECTURE.md` (predates the multiplayer/lobby/admin/map
systems). Weapon how-to: `WEAPONS.md`. Re-read code directly when in doubt.

## What it is
Zero-gravity 6DOF tactical FPS. Jolt physics + physics interpolation ON. Player =
`RigidBody3D` with composed child controllers. Server-authoritative multiplayer with
lobbies, deployed to a DigitalOcean VPS at **147.182.160.52:7000**.

## Run / test
- Boot scene `scenes/start_menu.tscn`; game scene `scenes/main.tscn`.
- **Local MP test:** `host_server.bat` (dedicated server of current code) → run game →
  Multiplayer → IP **`127.0.0.1`** → Join → pick lobby. Two windows = round starts.
  Blank IP = official VPS; "server not responding" usually means the VPS needs the new
  binary (see Deploy).
- Dedicated: `godot --headless -- --server --port 7000` (+ flags; `run_server.sh`,
  `GameLaunch.apply_cmdline_overrides`).

## Deploy (full runbook: `DEPLOY.md`)
1. Export Linux preset → `build/enders_server.x86_64`. **Re-export after ANY code change.**
2. **STOP the server BEFORE upload** (else "text file busy" silently keeps the old binary):
   `ssh root@147.182.160.52` → `tmux kill-session -t gameserver; pkill -f enders_server.x86_64`
   → `scp build\enders_server.x86_64 root@147.182.160.52:/root/` → ssh back →
   `chmod +x enders_server.x86_64 && ./run_server.sh 7000`. `server_control.ps1` does this order.

## Conventions / gotchas
- **Server-authoritative:** NetworkManager / RoundManager / LobbyManager own state; clients
  display. Damage, scoring, lobby actions validated server-side.
- **No autoloads** — static holders `GameLaunch` (launch config + cmdline overrides) and
  `GameSettings`. HUDs/menus are procedural GDScript, not `.tscn`.
- **No `print()` in per-shot/per-packet hot paths** — tmux's synchronous stdout stalls the
  VPS under fire. This includes `player.apply_weapon_damage` (runs server-side per
  confirmed hit). One-shot lifecycle prints fine; `debug_print_*` exports default OFF.
- Nodes animated per render frame in `_process` must set `physics_interpolation_mode = OFF`
  or they judder on >60 Hz displays.
- Client-supplied floats/vectors must pass `is_valid_vector`/`is_finite`; transforms must
  also pass `is_valid_transform` (orthonormal-basis determinant check) — replicas
  additionally orthonormalize the basis on receipt.
- **Tests:** `godot --headless --path . -s tools/tests/run_smoke_tests.gd` (75 checks:
  scene instantiation, economy claim validation, lobby sanitation, net-state hygiene,
  surface-walk wall slide, grapple multi-wrap, per-map spawn/enclosure/ground checks);
  `tools/tests/loopback_client.gd` joins a locally-running dedicated server end-to-end.
- **"rpc node checksum failed"** = client/server on different builds (usually stale VPS
  binary) — redeploy. UID warnings on load are harmless.

## Systems map
- **Multiplayer** (`scenes/network_manager.gd`): spawn, transform/hit/slam/tracer/projectile
  relay, validated plasma blast damage+impulse, scoreboard. Tracer relay is per-weapon
  (`get_tracer_scene_for_weapon`) so bystanders see the shooter's own tracer.
  `scripts/server_economy.gd`: server-authoritative cash/purchases/ownership + per-weapon
  ammo ledger + fire-rate validation of damage claims. Teams = spawn-slot parity (even=A,
  odd=B → 1v1@2, 2v2@4).
- **Lobbies** (`scripts/lobby_manager.gd`): up to 5 concurrent; a lobby closes when its last
  member leaves. Each has its own settings dict + RoundManager session (`sessions[lobby_id]`),
  replicated only to members; every relay is lobby-scoped, cross-lobby damage rejected,
  joiners get a full session sync. Client-supplied lobby settings are TYPE-CHECKED and
  clamped server-side (`_safe_*` helpers — a hostile dict must not abort the handler);
  lobby capacity clamps to the ENet host's real slots (`NetworkManager.max_players`).
  CONSTRAINT: all lobbies share the one loaded map (spawn markers are global groups; the
  host menu says so). Non-lobby servers use one implicit session.
- **Game modes** (per lobby): `"team"` elimination | `"ffa"` deathmatch. FFA: procedural
  arena-edge spawns (raycast from centre, farthest from others; falls back to markers),
  kill-ranked scoreboard, no buy menu, random gun from lobby pool + booster fuel each life,
  timed match, optional kill limit, auto-respawn. Clients mirror the mode into
  `GameLaunch.game_mode_id`.
- **Match rules** (host menu + cmdline): shared — min players, time limit, heal/ammo on
  kill. Team — starting cash, points to win. FFA — respawn time, booster fuel, kill limit,
  weapon pool. Cmdline: `--mode --respawn-time --booster-fuel --ffa-weapons --kill-limit
  --heal-on-kill --ammo-on-kill`. Kill rewards: `NetworkManager._handle_kill_rewards`.
- **Match end:** `State.MATCH_END` (team: points reached; FFA: timer, most kills; tie →
  draw) → `match_ended` → `game_over_hud.gd` winner screen + Return to Main Menu. Recovers
  to WAITING below `min_players`.
- **Spawns:** players spawn in surface-walk mode on the nearest surface
  (`request_spawn_ground_mode` → 6-axis probe, feet first, instant snap; zero-G fallback
  past 8 m). Local player only; remotes replicate. Author spawns as **`SpawnPoint` capsules**
  (`scenes/spawn_point.tscn`: blue=A, orange=B, nub = -Z forward, auto-joins
  `spawn_team_a/b`); bare `Marker3D`s still work. FFA pools all points. Spawn transforms
  are ORTHONORMALIZED before use — an editor-scaled marker/capsule must never leak scale
  into the player's basis (a scaled body errors camera/walk math everywhere).
- **Maps** (`scripts/map_generator.gd` = scene loader, generator removed): hand-built
  `.tscn` registered (preloaded) in the `MAPS` const; each needs `spawn_team_a/b` groups
  (optional `gate_team_*`). Current: `diamond` (DiamondArena.tscn) and `sphere`
  (scenes/sphere.tscn — goldberg-sphere shell, 5 spawns per pentagon pole: team A stands
  on the bottom face, team B on the interior ceiling; enclosed, so FFA edge-spawns land
  anywhere on the shell). New map = scene + one `MAPS` line + **re-export the server**.
  Selection = `GameLaunch.map_id`, synced at lobby join; `scenes/test_map.tscn` previews;
  `--map <id>`. The smoke suite runtime-checks every registered map (spawn groups,
  orthonormalizable bases, enclosure, grounded spawns where promised).
- **Admin:** `server_admin.gd` (command-file poll + admin-key RPC), `admin_console.gd`
  (F10), `scoreboard.gd` (Tab K/D), `server_control.ps1` (VPS menu).
- **Player:** `player.gd` + child controllers (movement, impact, boosters, camera_rig,
  limb_pusher, weapons/*, health). **Surface-walk** traverses seams/curves: the ground
  probes (down ray + front/back FOOT rays + crest sweeps) are gated at
  `surface_walk_max_edge_angle_degrees` (70°, measured vs the LAST-STOOD surface so beveled
  crests work at speed), but the orientation target is the distance-weighted BLEND of every
  probe hit (`target_normal`) — continuous across seams and curved colliders, so no
  face-to-face stutter; the NEAREST hit stays the physical anchor (snap plane / movement
  tangent / gating). Standing ON an edge is stabilised by anchor HYSTERESIS (a different
  face must persist `surface_walk_anchor_switch_time` as dominant support before it takes
  the anchor — per-frame ray alternation never persists) + STICKY blending (foreign-face
  weight scales with walk speed via `surface_walk_foreign_face_weight`, so idling hugs the
  anchored face) + a low-passed target (`surface_walk_target_smoothing`). Foot probes cast
  in a cross pattern even when idle, so a seam under the player is always straddled.
  Concave = forward takeover feeler with its OWN larger limit
  (`surface_walk_max_concave_angle_degrees`, 80° — steep-but-walkable seams like the
  Diamond arena's ~70.5° interior seams still climb on a deliberate walk-in, but a ~90°
  face is a WALL: it blocks you, never rotates you onto it; raise back toward 120 for
  walk-up-any-wall traversal). Walking INTO a too-steep face strips the into-wall velocity
  so you stop against it and stay grounded (`get_surface_walk_wall_block_normal` /
  `strip_into_wall_component`) — deterministic instead of physics-depenetration randomly
  lifting you off some walls; flip `surface_walk_wall_forces_zero_g` to detach into zero-G
  on wall contact instead. Curved surfaces: author them with
  PRIMITIVE colliders (SphereShape3D etc. — analytic, smooth normals), not trimesh. Exit =
  jump or all probes missing past grace. Camera rolls with the body on an eased tween
  (`surface_walk_align_*`), never a snap. Jump-off keeps the tangential run
  (×`surface_walk_jump_momentum_carry`, 1.35). Ground-lock (C): feet ray first, then
  nearest surface around the body — but ONLY surfaces whose normal matches the body's up
  within `surface_walk_entry_max_angle_degrees` (15°): you must actually orient your feet
  at a surface to lock it. Spawn grounding is exempt (snaps to the nearest surface).
- **Grapple wire:** purchasable (shop → SPECIAL SUIT SYSTEMS, `grapple_wire` group;
  server-validated like boosters). `scripts/grapple_controller.gd` on the player
  (`GrappleController` node): `grapple_fire` (E) casts along camera aim up to `max_range`;
  on STATIC geometry (players/RigidBody props rejected) it attaches and the wire length
  LOCKS to the attach distance — a fixed-length tether (`shoot_out_full_length` pays out
  the whole max_range instead, leaving slack). Taut = outward radial velocity absorbed
  over `taut_give` seconds (0 = rigid one-frame snap; higher = stretchier catch), tangent
  kept → swings at speed; slack = free float. `grapple_reel` (MMB) spools
  in (tows when floating, tightens/accelerates a swing); `grapple_release` (Q) detaches
  keeping all velocity. The wire WRAPS: contact mid-swing chains a new pivot (bend points
  STICK where they touch — deliberate no-slip) shrinking the active radius; it unwraps when
  the rope geometrically straightens back past a bend with clear LOS to the previous pivot.
  Tension yanks a surface-walking player off into zero-G. Local player simulates; other
  lobby members mirror the pivot chain via NetworkManager's grapple-event relay
  (attach/bend/unwrap/release, lobby-scoped, cosmetic-only) for the rope ribbon visual.
  Released automatically on death and round reset. New input actions are auto-listed in the
  settings keybinds.
- **Muzzle flashes:** per-gun wrapper scenes (`scenes/<gun>_muzzle_flash.tscn`,
  `WeaponMuzzleFlash` root) set via the gun's `muzzle_flash_scene`. Inspector: Binbun
  `effect_scene` variant, scale/length/width/offset, color/light overrides, `speed_scale`,
  `cut_on_fire_stop` (ON only for sustained-fire guns like the minigun). One instance
  auto-placed at the muzzle on equip, re-triggered per round; first-person only; plasma has
  none. The wrapper owns the VFX pack's quirks (one_shot, idle glow, per-instance material
  duplication). New gun = duplicate a flash scene + assign.
- **Drones (Test Arena only):** map-setup "Drones" dropdown (No default / Peaceful /
  Aggressive) → `GameLaunch.drone_mode`; `DroneSpawner` in main.tscn spawns
  `testingdrone.tscn` above random spawn markers (cap 4). Drone (`scripts/drone.gd`,
  RigidBody3D, 50 HP): force-flown, seeks the player at range, always wanders, one whisker
  ray for walls; fires a code-built bolt (`scripts/drone_bolt.gd`) straight out of
  BarrelOpening (+X) only when on target — peaceful never shoots. Hitscan damages it via
  `apply_weapon_damage` + shove ∝ damage (local branch of `player.submit_weapon_hit`);
  plasma pushes it for free. Non-test launches reset the mode. Groups: `players`, `drones`.
- **Settings:** `game_settings.gd` + `settings_menu.gd` (keybinds, FOV, volume, fullscreen
  → `user://settings.cfg`).

## State notes / TODO
- **Scoring reconciled:** `team_scores` IS the match score (admin `set_score`/`add_score`
  take a team letter); scoreboard K/D is display-only.
- **Economy/ammo server-authoritative**; the HUD ammo counter is client-side display.
  Plasma blasts merge by position/time into ONE consumed round, but each blast damages
  each target at most once (`blast_targets` dedup — a repeat claim is a replay). FFA
  loadout grants are exclusive server-side too: rolling a new gun revokes last life's
  weapon ownership/ledgers.
- **No spectate:** a dead player is an input-locked shoveable corpse until round reset
  (dead-attacker damage claims rejected after a grace window).
- **Overhead health bars** on remotes: green ally / red enemy (always red in FFA),
  depth-tested, hidden while dead. One shared `shaders/health_bar.gdshader` material with
  per-instance params, colored by `refresh_player_health_bars`, synced via the lobby-scoped
  damage/heal RPCs.
