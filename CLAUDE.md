# CLAUDE.md — Zero-G Tactical FPS (Godot 4.6.3)

Working handoff for AI sessions. The **design vision** is in `PROJECT_OVERVIEW.md`; the
**player/weapon core** is in `ARCHITECTURE.md` (note: that doc predates the multiplayer /
lobby / admin / map-generator systems below — treat it as the player-internals reference
only). This file is the current-state + gotchas layer. You can re-read any code directly.

## What it is
Godot 4.6.3 zero-gravity, 6DOF tactical FPS. Jolt physics + physics interpolation. The
player is a `RigidBody3D` with composed child controllers. Server-authoritative
multiplayer with a lobby system, deployed to a DigitalOcean VPS at **147.182.160.52:7000**.

## Run / test
- Main scene: `scenes/start_menu.tscn` → menu (Test Arena / Multiplayer / Settings).
- Game scene: `scenes/main.tscn`.
- **Local multiplayer test (use this while developing):** double-click `host_server.bat`
  (runs the *current* project as a dedicated server on your PC), then run the game →
  **Multiplayer** → put **`127.0.0.1`** in the Server IP field → **Join** → pick the lobby
  in the browser (Host also works locally). Two windows = 2 players = round starts. Both
  ends are current code, so no version-mismatch errors. Leaving the IP blank targets the
  official VPS — the lobby browser shows connect progress and failures with a Retry
  (Refresh) button; if it says the server isn't responding, the VPS needs the new binary
  started (see Deploy below).
- Dedicated server is `godot --headless -- --server --port 7000` (+ rule/map flags; see
  `run_server.sh` and `GameLaunch.apply_cmdline_overrides`).

## Deploy to the VPS (full version in `DEPLOY.md`)
1. `Project → Export → Linux preset → Export Project` (writes `build/enders_server.x86_64`).
   **Re-export after ANY code change — `scp` only copies what's in `build/`.**
2. **STOP the server FIRST, then upload** (uploading over a running executable fails with
   "text file busy" and silently leaves the old binary — this bit us repeatedly):
   - `ssh root@147.182.160.52` → `tmux kill-session -t gameserver; pkill -f enders_server.x86_64; exit`
   - `scp build\enders_server.x86_64 root@147.182.160.52:/root/`
   - `ssh` back in → `chmod +x enders_server.x86_64 && ./run_server.sh 7000`
- `server_control.ps1` (Codex) is a menu wrapper; its "upload+restart" now stops the
  server BEFORE uploading (kill tmux session + pkill, then scp, then chmod).

## Conventions
- **Server-authoritative.** NetworkManager / RoundManager / LobbyManager own state; clients
  only display. Damage, scoring, and lobby actions are validated server-side.
- **`GameLaunch`** (`scripts/game_launch.gd`): static (no autoload) config carried across
  scene changes, plus cmdline overrides (`--map`, `--min-players`, `--admin-key`, …).
- **HUDs are procedural** (built in GDScript, not `.tscn`): `player_hud`, `lobby_browser`,
  `round_hud`, `scoreboard`, `admin_console`, `settings_menu`, `map_setup_menu`.
- **No autoloads** — static holders (`GameLaunch`, `GameSettings`) instead.
- **"rpc node checksum failed"** in multiplayer = client and server are running DIFFERENT
  code versions (almost always: VPS has an old binary). Redeploy. UID warnings on load are
  harmless (it falls back to the text path).

## Systems map (current)
- **Multiplayer/lobby:** `scenes/network_manager.gd` (spawn, transform/hit/slam relay,
  weapon-tracer + plasma-projectile relay, validated plasma blast damage/impulse, team
  indicator refresh, scoreboard backend). Weapon-tracer relay is per-weapon:
  `get_tracer_scene_for_weapon(weapon_id)` resolves and caches each gun's OWN
  `hitscan_tracer_scene` (read once from `WeaponInventory.get_weapon_scene`), so a
  bystander sees the same tracer the shooter does, not a generic fallback — falls back to
  `weapon_tracer_scene` only for an unrecognized/blank id. `scripts/server_economy.gd` (server-authoritative
  cash/purchases/ownership + per-weapon ammo ledger and fire-rate validation of damage
  claims), `scripts/lobby_manager.gd` (up to `MAX_LOBBIES` = 5 CONCURRENT lobbies; see
  below), `scripts/lobby_browser.gd` (in-game browser; failed create/join shows the reason
  and re-pulls the list), `scripts/round_manager.gd` (per-lobby SESSION state machines; see
  below), `scripts/round_hud.gd` (top-center team-score bar). Dedicated server doesn't
  auto-spawn connectors; they spawn on lobby join. Teams = per-lobby spawn-slot parity
  (lowest free slot; even=A, odd=B) → 1v1@2, 2v1@3, 2v2@4.
- **Multiple lobbies:** up to 5 lobbies run at once on one server; Host creates a new one
  (6th attempt → "Max lobbies reached" result), and a lobby closes when its last member
  leaves. Each lobby carries its OWN settings dict (mode/rules/cash/FFA config) and gets its
  own RoundManager session: `sessions[lobby_id]` = state machine + scores + timers + rules,
  driven per-lobby in `_process` (`advance_session`), replicated only to that lobby's members
  (`session_rpc`; clients keep the same flat `state`/`team_scores`/`game_mode` mirror as
  before). EVERY relay in NetworkManager is lobby-scoped via `_lobby_client_peers_for` /
  `_same_lobby` (position state, tracers, projectiles, damage, slams, scoreboard, removals),
  and cross-lobby damage claims are rejected server-side. Joiners get a full session sync
  (`server_sync_session_to_peer`: mode + scores + state — no more 0–0 late-join gap).
  CONSTRAINT: all lobbies share the server's single loaded map (spawn markers live in global
  scene groups), so a created lobby's map is forced to the server's map; per-lobby maps need
  per-instance marker lookup. Non-lobby/direct servers fall back to one implicit session
  (`DEFAULT_SESSION_ID`) spanning all players.
- **Game modes:** each LOBBY has its own mode (`"team"` | `"ffa"`, in its settings dict);
  clients mirror their lobby's mode into `GameLaunch.game_mode_id` via
  `client_sync_game_mode`, and client display code reads that (server logic uses
  `NetworkManager._is_ffa_for_peer`). `"team"` = the original elimination mode. `"ffa"` =
  free-for-all deathmatch: **procedural arena-edge spawns** — the server raycasts from the
  arena centre in random directions and stands the player just inside whatever wall it hits,
  sampling several candidates and picking the farthest from other players
  (`get_ffa_spawn_transform(avoid_positions)`; falls back to authored markers if rays miss),
  per-player K/D scoreboard (single kill-ranked list), everyone shows as an enemy, **no buy
  menu** — players spawn with a server-picked random gun from the lobby's weapon pool + that
  lobby's booster fuel each life (`server_apply_ffa_loadout` → `client_apply_ffa_loadout` →
  `player.apply_ffa_loadout`; ownership/ammo mirrored via `ServerEconomy.server_grant_ffa_weapon`),
  timed match (kill limit optional), auto-respawn after the lobby's `respawn_time`.
- **Match rules (per lobby, host-menu + cmdline):** shared — min players, round time/time
  limit, `heal_on_kill` (killer fully heals; replicated to all copies), `ammo_on_kill`
  (killer's ammo refills, ledger + client). Team-only — starting cash, points to win.
  FFA-only — respawn time, booster fuel, kill limit (`ffa_kill_limit`, 0 = none; first to N
  kills ends the match), weapon pool. The host menu shows ONLY the selected mode's section.
  Cmdline: `--mode`, `--respawn-time`, `--booster-fuel`, `--ffa-weapons`, `--kill-limit`,
  `--heal-on-kill`, `--ammo-on-kill`. Kill rewards run in `NetworkManager._handle_kill_rewards`
  off the server-confirmed killing blow (`apply_confirmed_damage` returns `killed`).
- **Match end (both modes):** RoundManager has a terminal `State.MATCH_END`. Team mode enters
  it when a team reaches `points_to_win` (was: auto-restart); FFA enters it when the timer
  expires (most kills wins, ties → draw). It broadcasts `match_ended(result)`, which
  `scripts/game_over_hud.gd` (a CanvasLayer in `main.tscn`) shows as a winner screen with a
  **Return to Main Menu** button (same teardown as the pause menu's Leave). MATCH_END recovers
  to WAITING once the lobby drops below `min_players`.
- **Spawns are ground-mode + capsule-authored:** players spawn (all modes, initial + round
  start + FFA respawn) directly into **surface-walk ("ground") mode** on the NEAREST surface
  around the spawn point — `PlayerMovementController.request_spawn_ground_mode()` sets a
  pending flag; the next physics tick probes the body's 6 axes (feet first) for the closest
  collider and calls `enter_surface_walk_mode(..., instant := true)` (a snap, no slide/shake/
  daze). It retries a few frames, then falls back to free-floating zero-G if no surface is
  within `surface_walk_spawn_probe_distance` (8 m). Only the LOCAL player does this; remote
  copies replicate the walked transform. Spawn points are authored as **`SpawnPoint` capsules**
  (`scenes/spawn_point.tscn` / `scripts/spawn_point.gd`): a player-sized translucent capsule
  (blue=Team A, orange=Team B, facing nub = -Z) that auto-joins `spawn_team_a`/`spawn_team_b`
  at runtime and hides its visual — a drop-in replacement for the old bare `Marker3D` spawns
  (which still work). Rest one on a surface facing where you want; the player lands there
  standing. FFA pools all spawn points (`get_all_spawn_markers`) and picks at random.
- **Maps:** `scripts/map_generator.gd` is now a **scene loader, not a generator** — the
  procedural styles (Core/Module/Asteroid/Designed) and the default-arena path were removed.
  Maps are hand-built `.tscn` scenes registered in the `MAPS` const (id + display name +
  preloaded scene); each scene supplies its own `spawn_team_a` / `spawn_team_b` marker
  groups (and optional `gate_team_*`), which NetworkManager reads to place players. Current
  maps: `diamond` (`DiamondArena.tscn`) only. To add one: author the scene
  with the spawn groups, add a line to `MAPS`. Selection is a single `GameLaunch.map_id`
  string that syncs to clients at lobby join (`rebuild_from_launch`); the map-setup menu's
  dropdown is populated from the registry. `scenes/test_map.tscn` previews it (set `map_id`
  in the inspector). Cmdline: `--map <id>`.
- **Admin (Codex):** `scripts/server_admin.gd` (command-file poll + RPC, admin-key gated),
  `scripts/admin_console.gd` (F10 console), `scripts/scoreboard.gd` (TAB-held K/D),
  `server_control.ps1` (PowerShell VPS menu).
- **Player:** `scripts/player.gd` + child controllers (`player_movement_controller`,
  `impact_controller`, `suit_boosters`, `camera_rig`, `limb_pusher_controller`,
  `weapons/*`, `player_health`). Surface-walk has slope auto-alignment (the
  `surface_walk_slope_align_*` exports; aligns to the surface directly under you).
- **Muzzle flashes are per-gun wrapper scenes (tracer-style):** each hitscan gun's
  `muzzle_flash_scene` export (next to `hitscan_tracer_scene` in the inspector) points at its
  own `scenes/<gun>_muzzle_flash.tscn` — a `WeaponMuzzleFlash` root
  (`scripts/weapons/weapon_muzzle_flash.gd`) whose inspector exposes the Binbun effect choice
  (`effect_scene`, any `MuzzleFlashVFX/muzzle_flash/effects/…` variant), `overall_scale` /
  `flash_length` / `flash_width` / `muzzle_offset`, optional color/light overrides,
  `speed_scale`, and `cut_on_fire_stop` (ON for the minigun: Weapon.set_firing(false) —
  trigger release / spun down / reload — hard-stops the flash via `on_fire_stopped`; leave
  OFF for single/burst guns or their last flash clips). Tune a gun's flash by opening ITS
  flash scene; new gun = duplicate one +
  assign. `Weapon._setup_muzzle_flash` (at equip) creates ONE instance, auto-places it at the
  muzzle (`aim_origin_node_path`, +X = `aim_local_direction`, right-handed so it's not
  mirrored), and `fire_hitscan()` re-triggers it per round — so cadence/pattern follow the
  gun (cheap even at the minigun's 50/s). First-person only; remote players see only the
  tracer streak; plasma cannon never flashes. The wrapper owns ALL the pack's quirks: sets
  `one_shot`/`autoplay` (they self-loop otherwise), snuffs the idle glow/light (they idle
  LIT), and DUPLICATES the pack's shared .tres materials per instance so two guns using the
  same variant can't recolor each other. Pack scenes reference stale `res://assets/BinbunVFX`
  paths that resolve by UID.
- **Settings:** `scripts/game_settings.gd` + `settings_menu.gd` (keybinds, FOV, volume,
  fullscreen; persisted to `user://settings.cfg`).

## Open threads / TODO
- **Map authoring:** procedural generation is gone; all maps are hand-built scenes
  registered in `MapGenerator.MAPS`. Every map scene needs `Marker3D`s in groups
  **`spawn_team_a` / `spawn_team_b`** for NetworkManager to pick them up (gates in
  `gate_team_a` / `gate_team_b`). New maps just need a scene + a one-line `MAPS` entry.
  Re-export the server binary after adding a map (the scenes are preloaded into the build).
- **Scoring is reconciled:** `team_scores` is THE match score (admin `set_score`/`add_score`
  now take a team letter and directly affect the match); scoreboard K/D is display-only
  stats. The legacy per-peer `score_by_peer_id` is gone.
- **Economy/ammo are server-authoritative** (`scripts/server_economy.gd`): cash ledger +
  purchase validation + per-weapon ownership; damage claims carry a weapon id and are
  checked against ownership, an ammo/reload ledger, a fire-rate token bucket, and the
  weapon's real damage. The HUD ammo counter is still client-side display.
- **No spectate state** — a dead player is input-locked and free-floats as a shoveable
  corpse until round reset, but has no spectate camera. (Server-side, a dead peer's damage
  claims are rejected after `weapon_hit_dead_attacker_grace` seconds.)
- **Overhead health bars:** remote players show a billboard health bar overhead — green
  teammate, red enemy (always red in FFA), depth-tested (no wallhack), hidden while dead.
  `player.gd set_health_bar_friendly` + `shaders/health_bar.gdshader` (ONE shared
  ShaderMaterial; fill/color are per-instance shader params), colored by
  `NetworkManager.refresh_player_health_bars` after spawns. The bar mirrors the local copy's
  PlayerHealth, which the lobby-scoped damage/heal RPCs keep in sync. (Replaced the old
  team-indicator dot.)
