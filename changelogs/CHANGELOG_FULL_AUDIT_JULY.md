# Changelog — full-repository audit pass
Changes made on Sunday, July 5th. Co-authored with Claude (Fable 5).

Context: complete pass over all ~18k lines (every doc + every script read, every finding
verified against the actual code before changing anything). Fixes are deliberately narrow —
nothing about how the game plays changed, except that several cheats no longer work.
**Re-export BOTH the client and the Linux server binary together after pulling this**
(`network_manager.gd` / `server_economy.gd` / `player.gd` changed → mixed builds fail with
"rpc node checksum failed").

## Security / server authority

Change 1 - ## Plasma one-round = unlimited-damage replay (CRITICAL)
A plasma blast consumes one server-side round no matter how many players it hits, merged by
blast position/time (`plasma_blast_merge_*`). The hole: NOTHING deduplicated repeat claims
for the SAME target inside that merge window — only the generic 20 ms attacker→target pair
cooldown applied — so a hacked client could submit ~25 claims/second against one victim off
a single consumed round (up to ~2500 damage/s, through the full validation pipeline).
Fixed in `server_economy.gd`: each blast now records the targets it damaged
(`blast_targets`); a repeat claim for the same target inside the merge window is rejected
(`server_validate_plasma_hit` takes the target peer id from `network_manager.gd`). Honest
clients submit exactly one claim per player per blast, so nothing legitimate changes.

Change 2 - ## Hostile lobby-settings dictionaries could abort the create handler
`server_request_create_lobby` fed the raw client dictionary straight into `int()`/`float()`
casts and an `as Array ... .duplicate()`. A malicious dict (`{"max_players": {}}`,
`{"ffa_weapons": 7}`) raised a runtime error ON THE SERVER mid-handler. Every field is now
type-checked and clamped (`_safe_int/_safe_float/_safe_bool/_safe_string/_safe_weapon_list`
in `lobby_manager.gd`): names/passwords length-capped, weapon pools filtered to known
weapon ids, and lobby capacity clamped to the ENet host's REAL slot count
(`NetworkManager.max_players`) instead of 64 — an 11th "successful" join used to just fail
silently at the transport layer.

Change 3 - ## Scaled/degenerate transform injection
`server_receive_player_state` checked finiteness but not shape: a client could send a
scaled or zeroed basis, which the headless server applied RAW to its authoritative replica
(scaled RigidBody3D = Jolt error spam = the same synchronous-stdout stall the July 4th lag
audit fixed, plus warped hit-validation geometry). `is_valid_transform` now also rejects a
basis whose determinant is far from 1, and `player.receive_network_state` orthonormalizes
whatever arrives before using it.

Change 4 - ## FFA ghost-weapon claims
The server granted each FFA life's random gun but never revoked the previous one, while the
client wipes old weapons every life (`set_exclusive_weapon`) — so a hacked client could
keep dealing damage with every weapon it ever rolled (each with its own leftover ammo
ledger). `server_grant_ffa_weapon` now revokes prior weapon ownership + ledgers (non-weapon
groups like boosters are kept), mirroring the client exactly.

Change 5 - ## Admin-key brute force
`server_receive_admin_command` answered every wrong key instantly at RPC speed. Failed
attempts are now rate-limited per peer (2 s cooldown, silent inside the window).

## Correctness

Change 6 - ## Hot-path print regression (the July 4th fix, part 2)
`player.apply_weapon_damage` printed a multi-part line on EVERY confirmed hit — and it runs
on the dedicated server per hit (50/s under a connecting minigun spray), which is exactly
the tmux-synchronous-stdout stall the lag audit removed from `network_manager.gd`. Removed,
plus the per-slam print in `apply_network_body_slam_impulse`.

Change 7 - ## Listen host was blind to remote cosmetic effects
The tracer / projectile / grapple relays only `rpc_id`'d CLIENTS; the host of a listen
server (legacy in-arena H/J path) never played them, so other players' shots were invisible
tracer-wise on the host's screen. The relays now also play locally on a server that renders
and has a spawned local player in the shooter's lobby (`_server_views_relayed_effects`).
Dedicated/headless servers skip it as before.

Change 8 - ## Non-lobby spawn-slot collision
Direct-connect servers assigned new spawn slots from `spawn_index_by_peer_id.size()` —
after any disconnect, the next joiner got a slot an existing player still occupied (same
team, same spawn marker). Now takes the lowest unused slot, same as the lobby path.

Change 9 - ## Stale death-signal bookkeeping
`RoundManager.death_handler_by_peer_id` never forgot disconnected peers: unbounded growth
on a long-running server, and a reused peer id would silently never get its death signal
re-hooked (round would never end on their death). Entries are pruned as players disappear.
Same class of fix: per-peer network-diagnostic timing dictionaries are now erased on
disconnect (`clear_net_diag_for_peer`).

Change 10 - ## Grapple wrap could spam pivots (and reliable RPCs) without bound
With `wrap_min_pivot_separation` tuned to 0 (current player.tscn tuning), sliding along
curved geometry could add a bend pivot nearly every physics frame — each one a RELIABLE
bend-event RPC to the whole lobby, growing every member's pivot array forever. Added a
hard epsilon floor (5 mm, keeps the tight-wrap tuning intent) and a 64-pivot chain cap,
enforced on the remote mirror too (a forged bend flood can't balloon replicas). Also:
grapple raycasts reuse one cached query object, and the rope's `_process` is disabled on
headless servers.

## Performance / hygiene

Change 11 - ## Movement-controller ray queries reused
Surface-walk + push probes allocated a fresh `PhysicsRayQueryParameters3D` up to ~20×/tick;
now one cached query object (the same optimization `limb_pusher_controller.gd` already
had). SpawnPoint capsules skip building their editor visuals on headless servers.

Change 12 - ## Host menu tells the truth about maps
All lobbies share the server's single loaded map, but the host flow showed a map picker
whose choice was silently overridden at join. The picker now carries a note ("Online
lobbies currently play the server's active map") until per-lobby maps exist.

## Tests (new)

`tools/tests/run_smoke_tests.gd` — 58 headless checks: every registered
map/weapon/tracer/muzzle-flash/core scene instantiates; economy hit validation (fire-rate
token bucket, damage clamping, plasma per-target dedup, FFA exclusive grants); hostile
lobby-settings dictionaries; transform validation, spawn-slot reuse, replica
orthonormalization, stale-seq rejection.
`tools/tests/loopback_client.gd` — headless client that joins a locally running dedicated
server end-to-end (connect → create lobby → session → spawn). Both verified passing, plus
a dedicated-server boot check and `--check-only` parses on every modified script.

## Addendum — Sphere Arena (same day)

Registered the new `sphere` map (`scenes/sphere.tscn`, built on Props/Sphere.glb with its
authored GreyGrid material + per-mesh trimesh collision, verified enclosing from the
inside by raycast): added 5 SpawnPoint capsules per team seated by raycast on the top and
bottom pentagon-face corners (team A stands on the bottom, team B on the interior
ceiling — the spawn ground-probe locks everyone into surface-walk on spawn), plus a
7-light OmniLight ring (2 pole + 5 equatorial on the pentagon azimuths). Registered in
`MapGenerator.MAPS` as `sphere`; works in team and FFA (FFA edge-spawns raycast onto the
shell). The smoke suite now runtime-verifies every registered map: spawn groups populate
5/5, bases orthonormalize, arena encloses its centroid, and (for sphere) all 10 spawns
are within the 8 m ground probe. Found while testing: 6 of Diamond's 10 spawns are >8 m
from any surface, so those players deliberately(?) spawn free-floating. New map = another
"re-export both binaries" change.

## Addendum 2 — surface-walk feel changes (same day, by request)

Two gameplay-tuning changes in `player_movement_controller.gd` (both Inspector-exposed on
the player's MovementController node):

- **Ground-lock entry now requires alignment.** C only locks onto a surface whose normal
  is within `surface_walk_entry_max_angle_degrees` (NEW export, default 15°) of the
  body's own up — you must genuinely point your feet at the floor you want. Previously
  the 6-axis fallback grabbed the nearest surface in ANY direction, so you could lock
  onto a wall beside your shoulder. Spawn grounding (round start / respawn / FFA lives)
  is exempt and still snaps to the nearest surface regardless of orientation.
- **~90° faces are walls now.** `surface_walk_max_concave_angle_degrees` (the walk-INTO
  takeover feeler's limit) default dropped 120° → 80°: seams up to 80° off your current
  floor still climb on a deliberate walk-in (Diamond's ~70.5° interior seams keep
  working), but a face ~90° off blocks you like a wall instead of auto-rotating you onto
  it. Set it back toward 120 to restore walk-up-any-wall, or lower it toward
  `surface_walk_max_edge_angle_degrees` (70°, the passive seam/crest gate) for stricter
  walls.

Follow-up: the 80° change fixed the *align* half but exposed the *other* half — walking
into a rejected steep face left the outcome to physics depenetration, which lifts you off
inward-leaning/curved walls (every wall on a convex shell as you near an edge) but not
vertical ones, so you'd "leave ground mode against some walls and not others" at random.
Now deterministic: `handle_surface_walk_movement` casts a forward feeler
(`get_surface_walk_wall_block_normal`) and, for a face steeper than the concave limit,
strips the into-wall velocity component (`strip_into_wall_component`) so you stop against
it and stay grounded — a wall acts like a wall. New export `surface_walk_wall_forces_zero_g`
(default OFF) switches that to "detach into zero-G on wall contact" for anyone who wants
the drop-off feel instead. Walkable seams (≤ concave limit) are untouched — the ground
feeler still hands those over. Unit-tested in the smoke suite (wall-slide velocity strip).

## Addendum 3 — grapple swing feel (same day, by request)

Design goal the user chose: most realistic + most skill expression, jerk is fine when it's
earned by a bad approach. The tether model already delivers that (keeps all tangential
velocity = free swing + release slingshot; hard-catches only the outward-radial velocity,
whose magnitude ∝ how badly you entered = the skill signal; free slack inside the radius;
reel-to-pump). Two knobs were muddying the FEEDBACK, not the physics:

- `taut_give` 0.01 → 0.03 (player.tscn override; the audit had preserved 0.01, now
  deliberately retuned): the catch removes the same velocity either way, but 0.01 does it in
  ~1 tick so a deserved hard catch renders as a teleport-stutter; 0.03 spreads it over ~3-4
  frames so it reads as weight the player can learn from. Skill signal preserved (jerk still
  ∝ bad angle), glitch-look removed.
- `taut_max_snap_speed` 30 → 12 (grapple_controller.gd default): the positional leash is a
  stabiliser, not the catch. Gentler so a wrap planting a new pivot (radius steps down) eases
  you back onto the radius instead of micro-yanking — that yank was punishing CLEAN wraps
  around curves (the sphere map), the opposite of a skill signal.

Deliberately NOT changed: the rigid-ish outward absorption philosophy, free-slack-inside (no
inward damping — managing slack is skill), and no-slip bends. Explanation of the tangential-
vs-radial decomposition and why wrapping distributes the turn was given inline with a diagram.

## Addendum 4 — grapple couldn't wrap more than ~once (regression fix)

Symptom: doing a full loop around a body, the rope started cutting straight through it —
"can't wrap more than once around something." Reproduced headlessly (orbit a fake player
around a solid sphere, step _update_wrap/_update_unwrap): with player.tscn's surface-hugging
tuning (`wrap_surface_offset = 0.005`) bends plant ~twice as densely as the code default, so
the pivot chain hit `MAX_PIVOTS` at roughly the 2nd lap — and once capped, `_update_wrap`
returns early, stops planting bends, and the live player→pivot segment chords straight
through the body from that frame on.

Root cause was MINE: `MAX_PIVOTS = 64`, added during the audit to bound the pivot array +
relayed bend-event RPCs, is far too low for real multi-wrap play. Raised to 512 (still a hard
bound — a few KB, and a backstop against a forged-event flood — but generous enough for many
full loops even with tight tuning). Verified: seven full laps now reach ~252 pivots and never
chord through; the old cap failed at ~64 pivots / ~2 laps. Regression-tested in the smoke
suite (grapple multi-wrap: chain grows past 64, stays ≤ MAX_PIVOTS, never cuts through over
four laps). If you loop huge objects and still hit the cap, raise `wrap_surface_offset` for
fewer, wider-spaced bends rather than lowering it.

## Verified-fine during the audit (don't chase these)
- Tracer revamp is correct: geometry builds once per shot, one shared ShaderMaterial with
  per-instance uniforms, interpolation opt-outs in place (`weapon_spring_sway`, tracer).
- Muzzle-flash wrapper duplicates the Binbun pack's shared materials per instance; guns
  can't recolor each other; headless servers never build flashes (weapons only exist on
  the local shooter).
- Health bars: one shared shader material + per-instance params, billboarded in the
  shader, depth-tested (no wallhack), never built headless.
- Late-join sync, match-over screen, and 5-lobby concurrency all exist and work (TODO.md
  said otherwise — it's been reconciled).
- Grapple remote events need no sequence numbers: the relay is reliable+ordered per
  sender, and `apply_remote_event` ignores bends/unwraps while unattached.
- ENet reliable damage claims at minigun rates remain the known head-of-line-blocking
  risk under packet loss (unchanged by design — batching is the future option).
