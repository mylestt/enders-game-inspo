# Project Overview: Zero-G Arena Movement Shooter

**July 2026 pivot.** This document is the design vision — the game this project is heading
toward. It is NOT a description of what is implemented today: `CLAUDE.md` is the
current-state handoff and `ARCHITECTURE.md` the technical map. The previous vision (a 5v5
defusal-style tactical FPS with gate scoring and robot limb damage) is dropped — see
"Dropped From the Old Vision" below; git history has the old document.

The game is a **zero-gravity arena movement shooter** in the lineage of Quake, Unreal
Tournament, and Halo: fast momentum-driven movement through full-6DOF arenas, weapons that
spawn around the map and get fought over, and classic arena game modes (TDM, CTF, Gun
Game, and other staples).

**Status boundary that matters:** none of the arena-direction maps are designed yet and
the weapon roster isn't finished. Until they are, the currently implemented modes (team
elimination with the buy menu, FFA deathmatch) stay exactly as they are. Nothing in this
document is an instruction to change or remove existing modes or systems today — it
describes where the game goes once its pieces exist.

## High-Level Identity

An arena shooter where the movement IS the game. There is no gravity and no fixed up or
down: every wall, ceiling, and curved interior is a floor you can land on, run along, and
launch from. Players who master the movement cross the arena dramatically faster than
players who don't, and that speed is the primary skill expression — alongside the classic
arena skill of controlling the powerful weapon spawns.

The pacing target is arena-fast, not tactical-deliberate. Fights happen at speed, deaths
feed respawns, and map knowledge (routes + weapon timing) wins games.

## The Core Movement Loop

The heart of the game. A player moves through the arena by:

1. **Launching** — jumping off the surface they're standing on (jump-off carries extra
   tangential momentum), using the charged space launch, or **grappling**: the wire
   attaches to static geometry as a fixed-length tether, enabling tows, swings at speed,
   and wire-wraps around corners.
2. **Landing** — flying feet-first at a surface makes the body smoothly align and lock on
   automatically (no engage key). A good landing is continuous — speed in, speed out —
   not a dead stop.
3. **Building and keeping speed** — sprint to accelerate on the surface; momentum above
   run speed is kept **by sliding**. That rule is deliberate: land hot → slide to keep the
   excess → release and normal friction reclaims it. Slide into the next jump-off or
   grapple swing to chain speed across the arena.

Skill expression is chaining these into **routes**: practiced sequences of launches,
swings, feet-first landings, and slides that move you across the map as fast as possible.

Most of this loop already exists in code (auto-mount surface walk, slide, momentum-carrying
jump-off, grapple with wrapping — see `CLAUDE.md` for internals). What the pivot adds is
intent: tuning, maps, and modes built around this loop rather than around tactical rounds.

## Weapons: Map Pickups

Guns spawn at points around the map, on a spectrum from weak to powerful. The strong
weapons are contested: controlling their spawn timing and location is map control, exactly
the classic arena formula.

- **Spawn loadout is mode-defined.** Each mode decides what you start with (Gun Game
  brings its own weapon ladder; FFA already rolls a random gun per life). The grapple is
  standard issue for everyone — it's movement equipment, not a weapon.
- `weapon_registry.tres` stays the single source of the weapon pool; the pickup system
  will draw from it. **No pickup spawner exists yet.**
- Weapon tiering, pickup respawn timers, and telegraphing (spawn sounds / announcer) are
  TBD.

## Game Modes

Target modes: **TDM**, **CTF**, **Gun Game**, plus other common arena staples (KOTH etc. —
exact list TBD).

Implemented today: round-based team elimination (buy menu economy) and FFA deathmatch.
These stay unchanged until the arena systems (maps, weapon pickups, mode rules) are built.
Whether the buy-menu team mode survives long-term alongside the arena modes is an open
question.

## Map Design Principles

Maps are authored around the movement loop:

- **Routes first.** Every map should contain deliberate lines a skilled player can chain —
  launch → swing → feet-first landing → slide → relaunch — to cross it at maximum speed.
  Route knowledge should be learnable, practicable, and visibly faster.
- **Pickups are the strategy layer.** Weapon spawn placement creates the fights and gives
  routes a purpose (get to the power weapon first, rotate between pickups efficiently).
- **Zero-G means every surface counts.** Routes can run along walls, ceilings, and curved
  interiors; curved surfaces should use analytic primitive colliders so landings and
  surface-running stay smooth (see `CLAUDE.md`).
- Authoring mechanics (spawn groups, the map registry, the in-game map creator) are
  documented in `CLAUDE.md` and `MAP_CREATOR.md`.

None of the arena-direction maps are designed yet; the current `diamond` and `sphere`
arenas predate the pivot.

## What Exists vs. What the Pivot Needs

Already built (details in `CLAUDE.md`):

- Surface walk with fully automatic feet-first mounting, seam/curve traversal, slide
  (the momentum keeper), and momentum-carrying jump-off.
- Grapple wire for every player: tether, swings, reel, wire-wrapping around geometry,
  networked rope visuals.
- Zero-G 6DOF flight with boosters, roll controls, and the charged space launch.
- A weapon roster (hitscan, burst, charge railgun, minigun, plasma projectile) behind a
  drag-and-drop weapon registry, with server-authoritative damage validation.
- Server-authoritative multiplayer: lobbies (up to 5), per-lobby sessions, team
  elimination + FFA modes, scoreboards, match end, VPS deployment.
- Map registry + in-game map creator for custom maps.

Needed for the pivot (also tracked in `TODO.md` §1):

- **Weapon pickup system** — spawn points, respawn timers, tiered placement, pickup
  networking/validation.
- **The arena modes** — TDM, CTF (flags/carriers), Gun Game (ladder), then other staples;
  mode-defined spawn loadouts.
- **Route-first maps** designed for the movement loop and pickup control.
- **A movement flow/tuning pass** for arena speed (e.g. landing-alignment forgiveness,
  route chaining feel) — the slide momentum rule itself stays as designed.

## Dropped From the Old Vision (July 2026)

These were the previous design direction and are no longer targets. Do not build them:

- 5v5 defusal-style structure and single-elimination round pressure.
- The gate objective and its 2-point-elimination / 3-point-gate scoring.
- Robot limb damage/destruction as the combat model — the game uses the standard
  health-bar model that is actually implemented.
- Body posture hotkeys (fetal/upright/tucked poses).
- The "tactical and deliberate" pacing goal — replaced by arena speed.

## Unresolved Design Questions

Intentionally open. Don't invent answers; ask the owner or mark assumptions clearly:

- Weapon tier list, pickup respawn timers, and pickup telegraphing rules.
- The exact mode list beyond TDM/CTF/Gun Game (KOTH? Oddball-style? a race/time-trial
  mode that leans on routes?).
- Per-mode spawn loadouts (what the starter weapon is per mode, if any).
- Team sizes / player counts per mode (the old fixed 5v5 no longer applies).
- Long-term fate of the buy-menu team-elimination mode once arena modes exist.
- Movement tuning specifics: how forgiving feet-first landing alignment should be
  (current auto-mount entry gate is deliberately narrow), and whether the currently
  disabled zero-G wall push returns as a movement tool.

## Guidance For Future AI Agents

- This document is the TARGET. `CLAUDE.md` describes what actually exists — trust it for
  current behavior. Don't build pivot features unprompted, and don't remove or alter the
  existing modes/economy: the owner has said current gamemodes stay until the arena maps
  and weapons are ready.
- The movement feel is the product. When touching movement code, protect momentum, flow,
  and the land-slide-launch chain. Don't add friction, snap, or speed caps that break
  route play. The slide rule (excess speed survives only while sliding) is deliberate.
- This is a true zero-G 6DOF game, not a grounded shooter with a space theme. Every
  surface is a floor; routes and fights use all of them.
- Don't finalize unresolved rules without the owner's direction. If implementation needs a
  temporary assumption, keep it narrow and document it as provisional.
