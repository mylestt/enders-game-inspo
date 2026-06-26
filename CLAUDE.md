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
  **Multiplayer** → put **`127.0.0.1`** in the Direct IP field → **Join**. Two windows =
  2 players = round starts. Both ends are current code, so no version-mismatch errors.
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
- `server_control.ps1` (Codex) is a menu wrapper, but its "upload+restart" uploads BEFORE
  stopping → same bug; fixing it (stop-before-upload) is an open TODO.

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
  weapon-tracer relay, admin cash RPCs, scoreboard backend), `scripts/lobby_manager.gd`
  (ONE active lobby, API built to become many), `scripts/lobby_browser.gd` (in-game
  browser), `scripts/round_manager.gd` (team scoring, round ends when a whole team is
  eliminated), `scripts/round_hud.gd` (top-center team-score bar). Dedicated server doesn't
  auto-spawn connectors; they spawn on lobby join. Teams = spawn-slot parity (even=A,
  odd=B) → 1v1@2, 2v1@3, 2v2@4.
- **Maps:** `scripts/map_generator.gd` is now a **scene loader, not a generator** — the
  procedural styles (Core/Module/Asteroid/Designed) and the default-arena path were removed.
  Maps are hand-built `.tscn` scenes registered in the `MAPS` const (id + display name +
  preloaded scene); each scene supplies its own `spawn_team_a` / `spawn_team_b` marker
  groups (and optional `gate_team_*`), which NetworkManager reads to place players. Current
  maps: `diamond` (`DiamondArena.tscn`), `2v2` (`2v_2.tscn`). To add one: author the scene
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
- **Settings:** `scripts/game_settings.gd` + `settings_menu.gd` (keybinds, FOV, volume,
  fullscreen; persisted to `user://settings.cfg`).

## Open threads / TODO
- **Map authoring:** procedural generation is gone; all maps are hand-built scenes
  registered in `MapGenerator.MAPS`. Every map scene needs `Marker3D`s in groups
  **`spawn_team_a` / `spawn_team_b`** for NetworkManager to pick them up (gates in
  `gate_team_a` / `gate_team_b`). New maps just need a scene + a one-line `MAPS` entry.
  Re-export the server binary after adding a map (the scenes are preloaded into the build).
- **Three scoring systems coexist:** `team_scores` (drives match win), `score_by_peer_id`
  (admin commands poke it but it no longer decides the match), scoreboard K/D. Reconcile so
  admin `set_score` affects the match again.
- `admin_console.gd` doesn't re-capture the mouse on close (minor).
- **No death/spectate state** — a player at 0 health can still move/shoot until round reset.
- Lobby **late-joiners** see 0–0 until the next score change (no on-join state sync).
- **Economy is client-side cash** (cheatable) — should move server-side.
