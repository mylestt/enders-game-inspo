# CLAUDE.md — Zero-G Tactical FPS (Godot 4.6.3)

Current-state + gotchas handoff for AI sessions. Design vision: `PROJECT_OVERVIEW.md`.
Player/weapon internals: `ARCHITECTURE.md` (predates the multiplayer/lobby/admin/map
systems). Weapon how-to: `WEAPONS.md`. In-game map editor: `MAP_CREATOR.md`. Re-read
code directly when in doubt.

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
- **Tests:** `godot --headless --path . -s tools/tests/run_smoke_tests.gd` (195 checks:
  scene instantiation, RPC-surface fingerprint, economy claim validation, lobby sanitation,
  net-state hygiene, surface-walk wall slide, grapple multi-wrap, cylindrical-force-field
  profile/gizmo, spinning-skybox spin math, map-creator document/bevel/importer/builder
  checks, per-map spawn/enclosure/ground checks);
  `tools/tests/loopback_client.gd` joins a locally-running dedicated server end-to-end.
- **Mismatched client/server builds** are rejected at connect by a version handshake
  (`NetworkManager.NET_PROTOCOL_VERSION`, SceneMultiplayer auth — server logs "failed the
  build-version handshake", client shows "version mismatch"). BUMP the constant whenever
  any `@rpc` method is added/removed/renamed on any script — Godot sends RPCs as an index
  into the alphabetically-sorted @rpc table, so differing tables silently decode calls as
  the WRONG methods (symptoms on pre-handshake builds: "rpc node checksum failed", endless
  "RPC 'x' is not allowed on node ... from <peer>" spam, frozen remotes). The smoke suite
  fingerprints the @rpc surface and fails on drift, printing the new hash to record in
  `NET_RPC_FINGERPRINT`. UID warnings on load are harmless.

## Systems map
- **Multiplayer** (`scenes/network_manager.gd`): spawn, transform/hit/slam/tracer/projectile
  relay, validated plasma blast damage+impulse, scoreboard. Tracer relay is per-weapon
  (`get_tracer_scene_for_weapon`) so bystanders see the shooter's own tracer; the shot relay
  also carries a `tracer_scale` (the charge railgun's variable beam width — hence
  `NET_PROTOCOL_VERSION` is 2).
  `scripts/server_economy.gd`: server-authoritative cash/purchases/ownership + per-weapon
  ammo ledger + fire-rate validation of damage claims. Teams = spawn-slot parity (even=A,
  odd=B → 1v1@2, 2v2@4).
- **Weapon registry** (`weapon_registry.tres`, how-to: `WEAPONS.md`): weapons are registered
  in a resource EXACTLY like maps (`WeaponRegistry`/`WeaponListing` mirror
  `MapRegistry`/`MapListing`) — drag a weapon `.tscn` into `weapon_registry.tres` in the
  inspector, no code edit; entry order = quick-swap slot order. `WeaponInventory` preloads it and
  exposes static lookups (`get_weapon_ids`/`get_weapon_scene`/`get_weapon_name`, cached like
  `MapGenerator`) read by the shop, `ServerEconomy` stats, the FFA pool, and the tracer relay.
  Re-export the server after adding a weapon (scene must bake in). The **railgun** is a
  `ChargeHitscanWeapon` (`scripts/weapons/charge_hitscan_weapon.gd`): hold to charge, release to
  fire; damage AND tracer width scale from a tap to a full charge. `hitscan_damage` is the FULL
  value (the server clamps claims to it, so the charge needs no economy change); tune
  `max_charge_time`/`charge_min_damage_fraction`/`tracer_charge_min_scale`/`_max_scale`.
- **Lobbies** (`scripts/lobby_manager.gd`): up to 5 concurrent; a lobby closes when its last
  member leaves. Each has its own settings dict + RoundManager session (`sessions[lobby_id]`),
  replicated only to members; every relay is lobby-scoped, cross-lobby damage rejected,
  joiners get a full session sync. Client-supplied lobby settings are TYPE-CHECKED and
  clamped server-side (`_safe_*` helpers — a hostile dict must not abort the handler);
  lobby capacity clamps to the ENet host's real slots (`NetworkManager.max_players`).
  CONSTRAINT: all lobbies share the one loaded map (spawn markers are global groups). The
  FIRST lobby on an empty server adopts the host's map pick — the server rebuilds its
  GeneratedMap to match (`LobbyManager._resolve_lobby_map_id` / `_server_switch_active_map`);
  once any lobby exists the shared map is fixed and later lobbies inherit it (host menu says
  so). Non-lobby servers use one implicit session.
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
  `.tscn`s registered in `map_registry.tres` (a `MapRegistry` resource preloaded by
  MapGenerator; each `MapListing` = a PackedScene + optional id/name that auto-derive from
  the filename — `scripts/map_registry.gd` / `scripts/map_listing.gd`); each needs
  `spawn_team_a/b` groups (optional `gate_team_*`). Current: `diamond` (DiamondArena.tscn)
  and `sphere` (scenes/sphere.tscn — goldberg-sphere shell, 5 spawns per pentagon pole:
  team A stands on the bottom face, team B on the interior ceiling; enclosed, so FFA
  edge-spawns land anywhere on the shell). New map = author the scene, then in the inspector
  double-click `map_registry.tres`, add a `maps` element and drag the `.tscn` into its
  `scene` slot (no code edit) + **re-export the server** (the scene must bake into the
  binary; preloading the registry keeps its scenes tracked as export dependencies).
  Static lookups (`get_map_ids`/`get_map_entry`/`has_map`/...) build a cached Dictionary
  view of the registry, so menus/lobby/tests are unchanged.
  Selection = `GameLaunch.map_id`, synced at lobby join; `scenes/test_map.tscn` previews;
  `--map <id>`. The smoke suite runtime-checks every registered map (spawn groups,
  orthonormalizable bases, enclosure, grounded spawns where promised).
- **Force fields** (`scripts/cylindrical_force_field.gd`): `CylindricalForceField`, @tool
  Area3D pushing non-frozen RigidBody3Ds laterally AWAY from its local Y axis. Radial
  profile from three rings — `start_radius` (GREEN wireframe, zero force here/inside),
  `full_radius` (YELLOW, peak `force_strength`), `end_radius` (RED, faded to zero) — with
  `blend_in/out_falloff` ramp exponents between; `height` bands the volume; sizes are
  properties, never node scale. Wireframe gizmo + collider are generated in `_ready`
  (editor via @tool and in-game; unowned so never saved) — `gizmo_visible` hides it.
  Skipping frozen bodies means each machine pushes only what it simulates (remote replicas
  are frozen) — cosmetically consistent, no @rpc, no protocol bump. Diamond ships one on
  its vertical axis (rings 3/6/10 m, height 50, 10 N vs the 7.5 N booster).
- **Spinning skybox** (`scripts/spinning_skybox.gd` + `shaders/skybox_fullbright.gdshader`):
  `SpinningSkybox`, a Node3D you parent a sky-textured sphere mesh under. Each render frame
  it pins its ORIGIN to `get_viewport().get_camera_3d()` (infinite-distance illusion) while
  keeping its OWN orientation plus a `degrees_per_second` spin about `spin_axis` (world);
  `follow_camera` toggles the pinning. `physics_interpolation_mode = OFF` (per-frame driven).
  Local/cosmetic only, no networking. The shader (`skybox_fullbright.gdshader`) is `unshaded`
  fullbright, `shadows_disabled`, `fog_disabled`, `cull_disabled`, `depth_draw_never` (z-write
  OFF, so it never occludes the arena and reads as the backdrop BEHIND everything); add
  `depth_test_disabled` to the render_mode for a true on-top foreground overlay instead. It
  samples one texture straight by UV — used as the `SpinSpaceBall` (`spin_space_ball.tscn`),
  a UV-unwrapped inverted cube-sphere with one surface per cube face, so each of the six
  `SpinningSpace_*` face images is a per-surface material and the six together read as a cube
  map. The Space Station arena (`scenes/sphere.tscn`) instances the ball spinning at 15°/s.
  Scale the MESH, not the rig (rig writes an orthonormal basis).
- **Map creator** (`scripts/map_creator/`, how-to: `MAP_CREATOR.md`): in-game editor
  (start menu → Map Creator → `scenes/map_creator.tscn`; transforms via drag GIZMO —
  move arrows/rotate rings/scale cubes on their own physics layer `GIZMO_LAYER`, toolbar
  or keys 1/2/3 — or Blender-style G/R/S modal ops, both sharing one op pipeline)
  building DATA-ONLY maps —
  `MapDocument` JSON + copied model files in `user://custom_maps/<slug>/`, id
  `custom:<slug>`, built at runtime by `CustomMapBuilder` (edit mode = pick proxies that
  never join spawn groups; runtime = real SpawnPoints). Primitives store DIMENSIONS,
  never node scale. Colliders auto-added arena-style (MeshInstance3D → StaticBody3D →
  CollisionShape3D): trimesh for imported models + beveled/ramp/cone/torus, ANALYTIC
  shapes for exact box/sphere/cylinder/capsule (surface-walk wants analytic normals on
  curves). Bevels = `BevelMesh` procedural rounded box / rim-beveled cylinder (winding
  smoke-checked against BoxMesh — Godot fronts are CLOCKWISE). Imports
  (`MapModelImporter`, runtime — the editor import pipeline doesn't exist in exports):
  glb/gltf + fbx via engine document classes, obj/stl hand-parsed, .blend by shelling to
  a detected Blender (`settings.cfg tools/blender_path`, asked once in-editor) that
  exports a .glb into the map's assets. Playtest = save → offline TEST_ARENA with the
  `custom:` id; returning to the start menu reopens the editor
  (`MapCreatorEditor.consume_return_slug`). Custom maps are LOCAL-only: `has_map()` true
  only where the file exists, servers fall back to their current map on unknown ids, and
  the host-lobby menu never offers them (Test Arena only — networked custom maps would
  need file sync). MapDocument type-checks/clamps every field on load (hostile JSON must
  degrade, not crash). No `@rpc` changes — protocol version untouched.
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
  on wall contact instead. Walking toward a DROP-OFF is handled the same way
  (`get_surface_walk_ledge_block_normal`): look-ahead down-probes (`surface_walk_ledge_look_ahead`
  /`_max_drop`, gated by the CONCAVE limit + convex sweeps so crests/spheres/steep-but-walkable
  seams don't false-block) find no ground → the into-the-void velocity is stripped so you STOP
  at the lip and stay grounded. Curved surfaces: author them with
  PRIMITIVE colliders (SphereShape3D etc. — analytic, smooth normals), not trimesh. **Surface
  walk NEVER auto-exits into zero-G** — you leave ONLY by the charged space launch (`push`
  release) or the airborne timeout, or via external force-exits
  (death/respawn/knockback/grapple-tension). Steep edges and walls
  just stop you. If ground is somehow lost anyway (shoved off / clipped past a lip) the body
  holds (`surface_walk_ground_lost`: drift arrested, snap tows you back) rather than floating
  off. Camera rolls with the body on an eased tween
  (`surface_walk_align_*`), never a snap. Camera PITCH is rigidly body-relative (helmet cam):
  `surface_walk_pitch` is the mouse (+recoil) aim written straight to the Camera3D, so the
  body's alignment nod moves the view with it. (The old gimbal stabilizer —
  `surface_walk_pitch_stabilize` cancelling the nod — was REMOVED as broken; git history has
  it if a rebuild is ever wanted.) Jump-off keeps the tangential run (×`DETACH_MOMENTUM_CARRY`, 1.35). Mounting is
  FULLY AUTOMATIC (no engage key): floating with your feet pointed at a surface within
  `AUTO_GROUND_LOCK_DISTANCE` (2 m) locks on, gated by
  `surface_walk_entry_max_angle_degrees` (15° — the normal must be near the body's up).
  Spawn grounding is exempt (snaps to the nearest surface). **C = SLIDE**, not
  mount/dismount: momentum above `move_speed * sprint_multiplier` survives ONLY while
  sliding (`slide` action; hold, or press-to-toggle via Settings > Slide Input) — release
  and normal Source friction reclaims the excess. Slide is a real mode
  (`GroundMovementController.is_sliding()`, "SLIDING" on both HUDs, flight-recorder state
  SLIDE, limb debug dots pinned to rest via `LimbPushController.set_limbs_frozen`, headbob
  suppressed) for animations to key off; stance/hitbox/orientation are untouched.
- **Grapple wire:** standard-issue for every player by default (`GrappleController.has_grapple`
  defaults ON; no shop entry — re-add one + flip the default to gate it behind a purchase
  again). `scripts/grapple_controller.gd` on the player
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
- **Settings:** `game_settings.gd` + `settings_menu.gd` (keybinds, FOV, sensitivity,
  volume, fullscreen, slide hold/toggle, zero-G roll feel [start/max/change-rate sliders =
  PER-PLAYER overrides, unset (-1) follows the export defaults on PlayerMovementController
  — tune game-wide feel in the SCRIPT exports, read live], mouse-roll modifier [opt-in
  toggle + own sens slider (shown only while on): HOLD the `mouse_roll` bind (default V)
  in zero-G and mouse X drives ROLL around the aim axis instead of yaw — direct rotation
  for fast precise banks, A/D roll ignored while held; mouse Y still pitches; inert in
  ground mode] → `user://settings.cfg`).

## State notes / TODO
- **Zero-G wall push DISABLED** (space push off geometry + limb pushes):
  `wall_push_enabled = false` on PlayerMovementController — mechanic code intact, flip to
  re-enable. Gates the push itself, the zero-G charge, and every HUD affordance (push
  prompt, ctrl-push arrow, limb readout). Ground-mode charged launch unaffected.
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
