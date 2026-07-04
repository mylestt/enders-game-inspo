# TODO

Full-repository punch list from the technical audit + design-gap review. Ordered roughly
by priority within each section. Check items off as they land; keep this file current —
delete/rewrite items that turn out stale rather than leaving them checked-but-wrong.

## 0. Immediate housekeeping

- [ ] Commit and push the audit-pass changes (security fixes, headless hygiene, deleted
      broken scenes) plus any pending uncommitted work.
- [ ] Re-export and redeploy BOTH the client and dedicated server binaries together — the
      state-sync RPC signature changed (`state_seq` added); mismatched versions fail with
      "rpc node checksum failed".
- [ ] Start the VPS with `--admin-key <key>` — the shipped default admin key is now blank
      (previously it was a real key baked into every client build).

## 1. Core gameplay systems (design gap vs. PROJECT_OVERVIEW.md)

- [ ] **Gate objective.** Nothing implements it yet: no trigger volumes, no "one player
      through while a teammate holds it," no scoring hook. Maps already support
      `gate_team_a/b` groups and `MapGenerator.get_gate()` exists as a lookup.
- [ ] **Design-correct scoring values.** Design calls for elimination = 2 points, gate = 3,
      both scorable in the same round. Current code awards 1 point for a team wipe only.
      Do this together with the gate work.
- [ ] **Robot limb damage system.** The core combat identity from the design doc. Partial
      plumbing exists (`LimbPushController.set_limb_disabled()` already removes disabled
      limbs from push mechanics) but nothing calls it from combat — `PlayerHealth` is a
      single health bar, the player is one capsule hitbox. Needs per-part hitboxes
      (head/chest/arms/legs), server-validated per-part damage routing, and the
      critical-zone rules (head hit = eliminated, chest hit = legs disabled).
- [ ] **Death/spectate state.** Dead players currently see a ~98%-black screen until round
      reset. Minimum viable: spectate a teammate's camera or a free/orbit cam.
- [ ] **Match-over experience.** `server_restart_match()` silently resets to WAITING when a
      team hits `points_to_win` — no victory screen, no "Team A wins," no scoreboard
      freeze-frame.
- [ ] **Round-state input gating.** Players can currently shoot and take damage during
      COUNTDOWN and ROUND_END. Decide if that's intended; if not, gate firing/damage on
      `RoundManager.State.ACTIVE`.
- [ ] **Body posture hotkeys** (fetal/upright/arms-tucked/etc.). Not started. Deliberately
      low priority until limb damage exists, since postures mainly matter for
      hitbox/exposure control.

## 2. Multiplayer robustness

- [ ] **Late-join state sync.** A late joiner sees 0–0 team scores and stale round state
      until the next change. Fix: push a one-shot snapshot (team scores, round state +
      timer, scoreboard) to a peer on `server_spawn_in_lobby`.
- [ ] **Lobby capacity mismatch.** Lobby settings clamp `max_players` to 64, but the ENet
      server only allocates 10 slots (`NetworkManager.max_players`) — an 11th join silently
      fails at the transport layer. Clamp lobby capacity to the server's real capacity.
- [ ] **5v5 spawn capacity check.** Verify DiamondArena actually has 5 spawn markers per
      side and that a full 10-player round behaves (spawn overlap, team-dot readability,
      minigun tracer/audio volume at scale).
- [ ] **Mid-round disconnect/reconnect policy.** Today a disconnect wipes cash/ownership and
      a rejoin is a fresh spawn mid-round on whatever team parity assigns. Decide the rule
      (same team on rejoin? sit out until next round? keep wallet for N minutes?).
- [ ] **Multiple lobbies.** `LobbyManager` is already shaped for it (`SINGLE_LOBBY_ID`
      everywhere) — becomes relevant once more than ~10 people play at once.
- [ ] **Anti-cheat tier 2 (optional, do when it matters).** Current model is client-claim +
      server plausibility envelope. Next tier: server-side re-raycast of hitscan claims and
      blast-occlusion checks so plasma can't damage through walls. Also decide explicitly
      whether through-wall splash is a wanted feature or a bug.

## 3. Content

- [ ] **More maps.** Only `diamond` exists. Pipeline is now trivial (scene + spawn groups +
      one `MAPS` line) — this is authoring work. Each new map needs gate positions once
      gates exist.
- [ ] **Audio — essentially absent.** No weapon fire sounds, reloads, impacts, footsteps /
      surface-walk audio, ambience, or UI sounds. `PlasmaProjectile` already exposes
      `explosion_sound` (currently unassigned). Biggest single gap in game *feel* — even
      placeholder sounds would transform playtests.
- [ ] **Player character model + animations.** Players are glowing capsules right now.
      `y_bot.tscn` sits unused in the repo. Needed for limb damage to read visually. Big
      job: model, rig for 6DOF orientation, remote-player animation.
- [ ] **Weapon balance pass with real players.** WEAPONS.md's tuning table is reference
      values, not tested balance. Plasma-cannon self-knockback as mobility
      (rocket-jumping) is an emergent mechanic worth deliberately tuning rather than
      accidentally allowing.
- [ ] **Movable props.** Pushing off objects is core to the movement identity — audit how
      many arenas actually have grabbable/pushable RigidBody3D props. Note: prop physics is
      intentionally client-local today, so props desync across clients (fine for
      cosmetics, not for gameplay-relevant cover); syncing them would be its own project.

## 4. UX / polish

- [ ] **Kill feed + damage-direction indicator.** Currently no way to tell who killed whom,
      or where damage came from, beyond the hurt-flash overlay.
- [ ] **Buy-phase rules.** The buy menu currently opens anytime, including mid-firefight.
      Decide if purchases should be countdown-only (CS-style) and gate `open_menu()` on
      round state if so.
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

- [ ] **CI.** This audit produced proven headless validation recipes (script parse-check,
      scene-load check, plasma/weapon smoke test, loopback join test). Turning them into a
      `tests/` folder + a GitHub Action on push would catch parse errors and broken scenes
      before they reach the VPS. Cheap, high value.
- [ ] **`network_manager.gd` split.** ~2,000 lines. Deliberately not split during the audit
      (RPC-checksum / scene-path churn risk vs. clarity gain). If it keeps growing, extract
      the telemetry/diagnostics block first — most separable, though it does own two RPCs,
      so move carefully and rebuild both binaries when it happens.
- [x] **Tracer mesh rebuild cost.** ~~Re-committed three SurfaceTool meshes every frame.~~
      Revamped: geometry builds once per shot; the travel window, fades, and spark growth
      animate via per-instance uniforms on one shared ShaderMaterial
      (`shaders/tracer_streak.gdshader`). Zero per-frame allocations.
- [ ] **Server process management.** The VPS runs in tmux with no auto-restart on crash. A
      small systemd unit (or a restart loop in `run_server.sh`) would keep the server up
      unattended.
- [ ] **Doc consolidation.** ARCHITECTURE.md is partially updated but still predates the
      lobby/economy era in places; CLAUDE.md is current. One pass to make ARCHITECTURE.md
      fully match reality (or fold it into CLAUDE.md) would prevent future drift.

## Suggested order of attack

For the playable prototype loop:
**0 (commit/deploy) → gate objective + scoring (§1) → spectate + match-over (§1) →
late-join sync + lobby cap (§2) → placeholder audio (§3) → a second map (§3)**
gets to a genuinely testable 5v5 mode. Limb damage is the biggest identity feature but
also the biggest lift — treat it as its own effort after the core loop works, since it
touches hitboxes, health, networking validation, and eventually character models.
