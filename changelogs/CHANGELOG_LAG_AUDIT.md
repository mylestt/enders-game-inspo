# Changelog — online lag audit
Changes made by Sam on Saturday, July 4th. Co-authored with Claude (Fable 5).

Context: weird lag reported in online matches, worse on high-end hardware and sometimes absent on low-end machines. Ran a full-codebase audit (three parallel reviewers over all ~18k lines, every finding re-verified against the actual code before touching anything). Fixes below are deliberately tiny and change nothing about how the game plays.

Change 1 - ## Viewmodel & tracer judder on >60 Hz displays (the "high-end only" lag)
Physics interpolation is on project-wide (see Change 1 in the June 19 changelog — it decouples rendering from the 60 Hz physics tick). The catch: interpolated nodes render from their physics-tick snapshots, so anything animating its transform per RENDER frame in `_process` gets overridden/aliased by the interpolator — invisible at 60 Hz (frames ≈ ticks), visible judder at 120–240 Hz. Two nodes did exactly that:
- WeaponMount viewmodel animator (`weapon_spring_sway.gd` — sway/recoil/idle/ADS writes position+rotation every frame).
- Tracer impact spark (`weapon_hitscan_tracer_effect.gd` — scale animates every frame; the streak itself is shader-driven and was fine).
Fix: both now set `physics_interpolation_mode = OFF` on themselves in `_ready()` (one line each, cascades to children). They render their live per-frame animation as intended. Rule going forward: any node animated in `_process` must opt out of physics interpolation the same way.

Change 2 - ## Server console spam in the hit path (the online-only random rubber-banding)
The dedicated server printed a line on EVERY confirmed weapon hit — a connecting minigun spray is 50 prints/sec — plus one per body slam. On the VPS, stdout goes through a tmux pipe (synchronous I/O), so heavy fire could stall the network poll and everyone saw burst lag, regardless of their hardware. Removed both prints (`network_manager.gd`); all remaining server prints are one-shot lifecycle messages (connect, spawn, lobby events) and stay.

Change 3 - ## Client debug prints defaulted ON
`debug_print_limb_pushes` (multi-line print per push-off) and `debug_print_impacts` (4 lines per impact) shipped defaulted to true. Flipped both defaults to false — the exports are still there for dev use. No scene overrides existed, so the code default is what runs.

NOTE - things audited and confirmed FINE (don't chase these):
- Remote player replication is correct: replicas are frozen bodies, all smoothing runs at the fixed 60 Hz tick with delta-scaled math, network send is timer-throttled to 30 Hz (not FPS-bound).
- HUD ammo/health labels are event-driven, not per-frame; reticle/hurt-flash fades use framerate-independent decay; tracer geometry builds once per shot; round telemetry buffers to disk on round end only; peer disconnect cleanup erases everything it should.

FUTURE OPTIONS (identified, deliberately not changed to avoid altering gameplay/netcode shape):
- Damage claims + broadcasts are reliable RPCs at up to 50/s per spraying minigun; fine on a clean link, but under packet loss the reliable channel can head-of-line block. Batching damage per tick would help if it ever shows up in practice.
- Mouse look samples at the 60 Hz physics tick; high-refresh players may perceive aim latency vs. shooters that sample per frame. Changing it changes feel — decide deliberately.

IMPORTANT - re-export BOTH the client and the Linux server binary together after pulling this (network_manager.gd changed → old binary vs new client = "rpc node checksum failed").
