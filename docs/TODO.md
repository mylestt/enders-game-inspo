# TODO

Full-repository punch list from the technical audit + design-gap review. Ordered roughly
by priority within each section. Check items off as they land; keep this file current —
delete/rewrite items that turn out stale rather than leaving them checked-but-wrong.

## 0. Immediate housekeeping

- [ ] Commit and push the July 2026 audit-pass changes (plasma replay fix, lobby settings
	  sanitation, hot-path print removal, listen-host effect playback, `tools/tests/`)
	  plus any pending uncommitted work.
- [ ] Re-export and redeploy BOTH the client and dedicated server binaries together after
	  pulling — `network_manager.gd` changed again; mismatched versions fail with
	  "rpc node checksum failed".
- [ ] Start the VPS with `--admin-key <key>` — the shipped default admin key is blank
	  (previously it was a real key baked into every client build).

## 1. Core gameplay systems (design gap vs. docs/design/PROJECT_OVERVIEW.md — July 2026 arena pivot)

The July 2026 pivot retargets the game as a zero-G ARENA MOVEMENT SHOOTER (Quake/UT/Halo
lineage): weapons spawn around the map and get fought over, classic arena modes, maps
built around movement routes. Existing gamemodes stay unchanged until those systems
exist. Dropped with the pivot (do NOT build): gate objective, 2/3-point elimination
scoring, robot limb damage, body posture hotkeys — git history has the old items.

- [ ] **Weapon pickup system.** Nothing implements it yet: pickup spawn points on maps,
	  respawn timers, weak→powerful tiering, pickup networking + server validation.
	  `ServerEconomy`'s ownership/ammo-ledger plumbing is the obvious base to repurpose,
      and `Resources/Registries/weapon_registry.tres` already provides the pool.
- [ ] **Arena game modes.** TDM, CTF, Gun Game, then other common staples (exact list
	  TBD). Spawn loadouts are mode-defined. FFA's kill-ranked scoreboard / auto-respawn /
	  random-loadout loop and the per-lobby RoundManager sessions are the closest
	  starting points.
- [ ] **Route-first arena maps.** None are designed yet. Maps built around movement
	  routes — deliberate lines to chain launch → feet-first landing → slide → grapple
	  swing at speed — with weapon-pickup placement as the map-control layer.
- [ ] **Movement flow pass for arena speed.** The core loop already exists (auto-mount
	  landings, slide momentum keep, 1.35× jump-off carry, grapple wraps); tune it for
	  route play — e.g. landing-alignment forgiveness (the 15° auto-mount entry gate),
	  chaining feel. The momentum rule itself is deliberate and stays: above-cap speed
	  survives only while sliding.
- [ ] **Death/spectate state.** Dead players currently see a ~98%-black screen until round
	  reset. Minimum viable: spectate a teammate's camera or a free/orbit cam.
- [x] **Match-over experience.** ~~No victory screen.~~ Done: `RoundManager.State.MATCH_END`
      → `match_ended` → `game_over_hud.gd` winner/draw screen (team + FFA variants) with
      Return to Main Menu; recovers to WAITING when the lobby empties below `min_players`.
- [ ] **Round-state input gating.** Players can currently shoot and take damage during
	  COUNTDOWN and ROUND_END (deaths outside ACTIVE don't end rounds/count stats — see
	  `server_on_player_died`). Decide if that's intended; if not, gate firing/damage on
      `RoundManager.State.ACTIVE`. (Deliberately left as a design decision in the July 2026
      audit — a single server-side gate in `server_attacker_may_deal_damage` would do it.)

## 2. Multiplayer robustness

- [x] **Late-join state sync.** ~~A late joiner sees 0–0 team scores.~~ Done:
      `RoundManager.server_sync_session_to_peer()` pushes mode + scores + round state to a
      peer on lobby join, and `server_spawn_in_lobby` follows with a scoreboard broadcast.
- [x] **Lobby capacity mismatch.** ~~Lobby settings clamp `max_players` to 64.~~ Fixed:
	  lobby capacity clamps to the ENet host's real slot count
	  (`LobbyManager._server_player_capacity()` reads `NetworkManager.max_players`).
- [ ] **Full-lobby spawn capacity check.** Verify DiamondArena actually has 5 spawn
	  markers per side and that a full 10-player match behaves (spawn overlap, team-dot
	  readability, minigun tracer/audio volume at scale).
- [ ] **Mid-round disconnect/reconnect policy.** Today a disconnect wipes cash/ownership and
	  a rejoin is a fresh spawn mid-round on whatever team parity assigns. Decide the rule
	  (same team on rejoin? sit out until next round? keep wallet for N minutes?).
- [x] **Multiple lobbies.** Done: up to `LobbyManager.MAX_LOBBIES` (5) concurrent lobbies,
	  each with its own RoundManager session and lobby-scoped relays. REMAINING CONSTRAINT:
	  all lobbies share the server's one loaded map (spawn markers are global scene-tree
      groups) — per-lobby maps need per-instance marker lookup, and the host menu says so.
- [ ] **Anti-cheat tier 2 (optional, do when it matters).** Current model is client-claim +
      server plausibility envelope (plus, since the July 2026 audit: per-blast per-target
      plasma dedup, fire-rate token buckets, basis/NaN validation, FFA exclusive-weapon
      grants). Next tier: server-side re-raycast of hitscan claims and blast-occlusion
	  checks so plasma can't damage through walls. Also decide explicitly whether
	  through-wall splash is a wanted feature or a bug.

## 3. Content

- [ ] **More maps.** `diamond` and `sphere` exist (sphere: pentagon-pole spawns, omni
	  lighting, interior-verified collision). Pipeline is trivial (scene + spawn groups +
	  one `Resources/Registries/map_registry.tres` entry) — more is authoring work. Post-pivot, new maps should
	  be ROUTE-FIRST with weapon-pickup placement in mind (see docs/design/PROJECT_OVERVIEW.md map
	  design principles). Note: 6 of Diamond's 10 authored spawns sit >8 m from any
	  surface, so those players spawn free-floating (zero-G fallback) — check that's
	  intended.
- [ ] **Audio — essentially absent.** No weapon fire sounds, reloads, impacts, footsteps /
	  surface-walk audio, ambience, or UI sounds. `PlasmaProjectile` already exposes
	  `explosion_sound` (currently unassigned). Biggest single gap in game *feel* — even
	  placeholder sounds would transform playtests.
- [ ] **Player character model + animations.** Players are glowing capsules right now.
	  `y_bot.tscn` sits unused in the repo. Needed for remote players to read at arena
	  speed. Big job: model, rig for 6DOF orientation, remote-player animation.
- [ ] **Weapon balance pass with real players.** docs/guides/WEAPONS.md's tuning table is reference
      values, not tested balance. Post-pivot this doubles as the weak→powerful pickup
      tiering pass. Plasma-cannon self-knockback as mobility (rocket-jumping) is an
      emergent mechanic worth deliberately tuning rather than accidentally allowing.
- [ ] **Movable props.** Pushing off objects is core to the movement identity — audit how
      many arenas actually have grabbable/pushable RigidBody3D props. Note: prop physics is
      intentionally client-local today, so props desync across clients (fine for
      cosmetics, not for gameplay-relevant cover); syncing them would be its own project.

## 4. UX / polish

- [ ] **Kill feed + damage-direction indicator.** Currently no way to tell who killed whom,
      or where damage came from, beyond the hurt-flash overlay.
- [ ] **Buy-phase rules.** The buy menu currently opens anytime, including mid-firefight.
      Decide if purchases should be countdown-only (CS-style) and gate `open_menu()` on
      round state if so. (July 2026 pivot: map pickups may retire the buy menu entirely —
      decide that first before investing here.)
- [ ] **Controller support.** Rumble already exists (plasma explosions), but keybinds/menus
      are keyboard-and-mouse only; the rebind system only serializes key + mouse-button
      events.
- [ ] **HUD debug cleanup for real builds.** Jump-force/limb-push/FPS debug labels and the
      default-on `debug_print_*` flags are dev UI. Worth one `debug_hud` toggle so playtests
      look like a finished game.
- [ ] **Menu polish.** Resolution/vsync settings, a confirm dialog on "Leave Game," and the
      lobby browser handling "server unreachable" with a real message instead of an eternal
      "Connecting…".

## 5. Tech debt / infrastructure

- [x] **Test suite (local).** `tools/tests/run_smoke_tests.gd` (195 checks as of July 2026:
      scene instantiation for every map/weapon/tracer/flash scene, RPC-surface fingerprint,
      economy claim validation incl. the plasma per-target dedup, lobby-settings sanitation,
      network transform hygiene, surface-walk wall slide, grapple multi-wrap, map-creator
      checks, per-map spawn/enclosure/ground)
      and `tools/tests/loopback_client.gd` (connect → create lobby → spawn against a local
      dedicated server). Run headless:
      `godot --headless --path . -s tools/tests/run_smoke_tests.gd`.
- [ ] **CI.** Wire the suite above into a GitHub Action on push so parse errors and broken
      scenes are caught before they reach the VPS. Cheap, high value.
- [ ] **`network_manager.gd` split.** ~2,000 lines. Deliberately not split during the audit
      (RPC-checksum / scene-path churn risk vs. clarity gain). If it keeps growing, extract
      the telemetry/diagnostics block first — most separable, though it does own two RPCs,
      so move carefully and rebuild both binaries when it happens.
- [x] **Tracer mesh rebuild cost.** ~~Re-committed three SurfaceTool meshes every frame.~~
      Revamped: geometry builds once per shot; the travel window, fades, and spark growth
      animate via per-instance uniforms on one shared ShaderMaterial
      (`Resources/Materials/Shaders/Gameplay/tracer_streak.gdshader`). Zero per-frame allocations.
- [ ] **Server process management.** The VPS runs in tmux with no auto-restart on crash. A
      small systemd unit (or a restart loop in `tools/launch/run_server.sh`) would keep the server up
      unattended.
- [ ] **Doc consolidation.** docs/architecture/ARCHITECTURE.md is partially updated but still predates the
      lobby/economy era in places; CLAUDE.md is current. One pass to make docs/architecture/ARCHITECTURE.md
      fully match reality (or fold it into CLAUDE.md) would prevent future drift.

## Suggested order of attack

For the playable arena loop:
**0 (commit/deploy) → weapon pickup system (§1) → first arena mode, TDM (§1) →
a route-first map (§3) → spectate (§1) → placeholder audio (§3)**
gets to a genuinely testable arena match (match-over, late-join sync, and the lobby cap
all landed already). CTF and Gun Game layer onto the same pickup + mode plumbing — treat
each as its own effort once TDM proves the loop. Existing team-elim/FFA modes stay
untouched throughout, per the pivot's ground rule.
