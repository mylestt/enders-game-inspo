# Weapon System Guide

How the first-person weapons work, and how to add a new one so it feels coherent with the
rest. Zero-G, server-authoritative, physics-interpolated. Everything is data-driven per gun
via `@export`s you tune in the Inspector — you rarely touch code to make a new weapon.

> **July 2026 pivot:** the design target is now an arena movement shooter where guns spawn
> around the map as contested pickups (`PROJECT_OVERVIEW.md`). Nothing in this guide
> changes — `weapon_registry.tres` stays the single weapon-pool source a future pickup
> system will draw from. No pickup spawner exists yet.

---

## 1. The layers

Weapons are split into three responsibilities. Keep them separate.

| Layer | File | Lives on | Job |
|---|---|---|---|
| **Combat** | `scripts/weapons/weapon.gd` (`Weapon`) + subclasses | the weapon scene root | Raycast, spread, tracer, damage, networking, recoil routing, ammo, ADS state. |
| **Coordinator** | `scripts/weapons/weapon_inventory.gd` (`WeaponInventory`) | a Node on the player | Owns the equipped weapon; reads fire/aim/reload/swap input; drives ADS FOV + viewmodel; forwards ammo to the HUD. |
| **Viewmodel** | `scripts/weapons/weapon_spring_sway.gd` (`WeaponSpringSway`) | the `WeaponMount` node | Pure procedural animation: sway, visual recoil spring, idle, ADS pose, equip/reload poses, sustained kickback. |

Subclasses of `Weapon` decide *when* to fire; the base does *everything else*:
- `hitscan_weapon.gd` (`HitscanWeapon`) — cooldown fire: single-shot or burst (battle rifle).
- `charge_hitscan_weapon.gd` (`ChargeHitscanWeapon`) — subclass of `HitscanWeapon` (the railgun):
  hold to charge, release to fire; damage + tracer width scale with charge (see §7C).
- `minigun_weapon.gd` (`MinigunWeapon`) — wind-up spin-up full-auto.
- `projectile_weapon.gd` (`ProjectileWeapon`) — subclass of `HitscanWeapon` (inherits its
  whole fire cadence) that launches a travelling bolt (plasma cannon) instead of a ray; see
  §2b. Bolt script: `plasma_projectile.gd` (`PlasmaProjectile`).

Helper: `scripts/weapons/weapon_feel.gd` (`WeaponFeel`) — framerate-independent decay/spring math.

### Node hierarchy (on the player)
```
Player (RigidBody3D, player.gd)
├─ MovementController (player_movement_controller.gd)   # owns the look; recoil climbs the aim here
├─ WeaponInventory (weapon_inventory.gd)                # the coordinator
└─ CameraRig (camera_rig.gd)
   └─ Camera3D
	  └─ WeaponMount (weapon_spring_sway.gd)            # the viewmodel animator
		 └─ <weapon scene instance>                     # spawned on equip
```
Only the **local** player runs weapon input/animation. Remote players never equip weapons
(no third-person viewmodel sync) — don't rely on a remote player's gun existing.

---

## 2. The fire pipeline

1. `WeaponInventory.update(delta, enabled)` (called each physics frame from `player.gd`) sets
   `equipped_weapon.set_trigger_held(...)` from the `weapon_fire` action, drives ADS, etc.
2. The weapon subclass's `_physics_process` decides to fire and calls `fire_hitscan()`.
3. `Weapon.fire_hitscan()` (base): raycast from the muzzle with spread → spawns the tracer →
   `owner_player.submit_weapon_hit(...)` (server-validated damage) → `owner_player.report_weapon_shot(...)`
   (relays the tracer to other clients). **This is already networked — don't reinvent it.**
4. The subclass calls `apply_fire_recoil(multiplier)` (see §3).

Damage/hits are **server-authoritative** with lag compensation in `scenes/network_manager.gd`.
A weapon just calls `fire_hitscan()`; the base + player + network manager handle validation.

### 2b. The projectile pipeline (`ProjectileWeapon`)

Same shape, but the hit claim is **deferred to impact** instead of instant:

1. `fire_projectile()` spawns a `PlasmaProjectile` into the world `WeaponEffects` node
   (reusing the base's muzzle origin, spread model, ammo, and all three recoil channels).
2. The bolt is **client-simulated on the shooter's machine**: it flies in a straight line
   (zero-G — no gravity/arc) sweeping a segment raycast each physics frame (no tunnelling).
3. On impact `plasma_projectile.tscn` queries a sphere, evaluates its editable damage and
   airburst falloff curves, and submits one combined damage + radial-impulse claim per player.
   The server validates blast radius, projectile path, damage, and impulse before applying
   them. Non-player `RigidBody3D`s receive radial `apply_central_impulse` locally.
4. Other clients see the bolt via `NetworkManager.broadcast_projectile_shot` →
   `client_play_projectile_shot` (unreliable, like tracers): they spawn a **cosmetic** copy
   that flies and pops but never deals damage. The shooter's client owns the claim.

**Constraint:** the server checks the claimed fire origin against
`plasma_explosion_origin_validation_distance` at impact time. Long flight plus a fast-moving
shooter can exceed it; widen that server export if legitimate blasts are rejected.

---

## 3. The recoil model (three independent channels)

Every gun runs the same system. `Weapon.apply_fire_recoil(multiplier)` fires three channels;
tune each per weapon in the Inspector:

1. **Viewmodel spring kick** (cosmetic — the gun model punches back and springs home).
   Driven by `recoil_rotation_degrees` + `recoil_position_offset` (+ their `_random_` variants),
   sent via the `recoil_requested` signal to the animator's recoil spring.
   *`+Z` in `recoil_position_offset` = toward the player (a backward kick).*

2. **Camera climb with recovery** (CS-style: the climb is mostly yours to pull down).
   `recoil_kick_up` (degrees of climb per shot, ±15% per-shot variance) + `recoil_kick_side`
   (± horizontal — a smooth sine walk across consecutive shots plus per-shot jitter, so sprays
   never trace a learnable pattern).
   Routed `weapon → player.apply_camera_recoil → MovementController.apply_look_recoil` into a
   **camera-space offset separate from the mouse look**: kicks ease in over a few frames (no
   one-frame snap), the offset is clamped at the pitch limit (shooting never tumbles the body),
   and the player's counter-pull consumes the offset 1:1 first — pulling down mid-spray is the
   skill, and recovery never yanks the view below where they were aiming. Auto-recovery is
   **small and continuous**: only `recoil_recovery_fraction` (default 0.15) of each kick's
   climb recenters, and it runs *during* fire (`recoil_fire_settle_fraction`, default 1.0 —
   no waiting for the trigger release); the rest folds into the base look as permanent climb
   the player must pull down themselves (side wander always fully recenters). Tune feel via
   the MovementController exports `recoil_apply_speed` / `recoil_recovery_delay` /
   `recoil_recovery_speed`. While **free-floating** the climb is scaled by
   `recoil_kick_free_float_mult` (default 0.5) — braced (surface-walk/grab) shooters take the
   full kick, floaters take the body shove instead. `recoil_kick_up` is *per shot*, so a 50 rps
   minigun needs a tiny value.

3. **Free-float body push** (0-G reaction). Only while free-floating (not braced on a
   surface/grip). `fire_knockback_force` = a central impulse straight back **opposite the
   barrel** (`get_aim_direction()`), so where you aim is where you're shoved. `fire_torque_strength`
   adds an off-centre tumble — but that spin is a **fixed body-space direction** (always the
   same way), which feels bad, so **leave it at 0** and rely on the linear push.

Plus **`sustained_kickback`** (`Vector3`): a viewmodel offset the animator eases toward *while
the gun is firing* and eases out of when it stops — e.g. the minigun kicks back and *stays*
back during sustained fire.

`apply_fire_recoil(multiplier)` scales all channels; the minigun passes its `windup_amount` so
recoil ramps with spin-up.

---

## 4. Export reference

Select a weapon scene's **root node** in the Inspector to see all of these.

### `Weapon` (base — every gun has these)
**(top)** `weapon_weight`, `aim_origin_node_path` (NodePath to the muzzle marker),
`aim_local_direction` (the barrel's forward axis in the weapon's local frame, e.g. `(1,0,0)`).

**Recoil** — `recoil_enabled`, `recoil_rotation_degrees`, `recoil_position_offset`,
`recoil_random_rotation_degrees`, `recoil_random_position_offset`, **`recoil_kick_up`**,
**`recoil_kick_side`**, `recoil_kick_free_float_mult` (camera-climb scale while unbraced),
**`sustained_kickback`**.

**Hitscan** — `hitscan_range`, `hitscan_damage`, `hitscan_collision_mask`,
`hitscan_collide_with_bodies`, `hitscan_collide_with_areas`, `hitscan_spread_degrees`
(Vector2 yaw/pitch), `hitscan_tracer_scene`, `hitscan_effect_parent_path`.

**Body Recoil** — `fire_knockback_enabled`, `fire_knockback_force`, `fire_torque_strength`
(keep 0), `max_recoil_angular_speed`.

**Ammo** — `mag_size` (**0 = infinite, no reload**), `starting_reserve`, `reload_time`.

**ADS** — `ads_fov` (**0 = no zoom**), `ads_in_speed_mult` (scope-in speed multiplier, default
1.75× — scope-out always runs at 1×; the minigun sets 1.0 so the heavy gun shoulders slowly),
`ads_spread_mult`, `ads_recoil_mult`, `ads_position_offset` (additive fine-tune on top of sight
auto-centring).

### `HitscanWeapon` (railgun, battle rifle, most guns)
`rounds_per_second` (cadence between shots/bursts), `semi_auto` (one shot/burst per trigger
pull), `burst_count` (**1 = single shot; >1 = burst**), `burst_interval` (seconds between
rounds inside a burst).

### `MinigunWeapon` (wind-up full-auto)
`barrel_node_path`, `box_node_path` (spinning parts), `wind_up_time`, `wind_down_time`,
`fire_spin_threshold` (windup fraction before it fires), `max_spin_radians_per_second`,
`barrel_local_spin_axis`, `rounds_per_second`, `max_rounds_per_frame`, plus heat:
`heat_ramp_time` / `heat_recoil_max_mult` (all recoil channels ramp up over sustained fire,
cool on release).

### `ProjectileWeapon` (plasma cannon)
`projectile_scene`, `projectile_speed` (m/s), plus everything `HitscanWeapon` has
(`rounds_per_second`, `semi_auto`, `burst_count`; the plasma cannon scene sets 1.4 rps).
Open `scenes/plasma_projectile.tscn` for flight lifetime, projectile/explosion visuals,
100→5 damage and its editable `Curve`, airburst impulse/curve, and ion-particle controls.
Impact feedback is layered: white-hot core, pressure shell, slow ions, fast velocity-aligned
streaks, distance-falloff camera punch/shake, a brief view flash, and optional 3D audio.
Spread reuses `hitscan_spread_degrees`; `hitscan_damage`/`hitscan_range`/tracer are unused.

### Signals emitted by `Weapon`
`firing_state_changed(is_firing)`, `recoil_requested(rot_deg, pos)`, `ammo_changed(current, reserve)`,
`reload_started()`, `reload_finished()`, `ads_changed(aiming)`. Hook these for HUD/audio/VFX.

---

## 5. ADS (aim down sights)

Hold `aim` (RMB). The coordinator lerps `camera.fov` between `GameSettings.fov` and the gun's
`ads_fov`, blends the viewmodel to align its sight to screen centre, and applies
`ads_spread_mult` / `ads_recoil_mult`. Scope-in runs faster than scope-out by the gun's
`ads_in_speed_mult` (default 1.75×); scope-out always uses the base `ads_blend_speed`. The animator finds the sight by searching the weapon's
children for a `Marker3D` named **`Sight`** first, then **`ADSmarker`**. If alignment is
slightly off, nudge `ads_position_offset` on the weapon; with no sight marker it falls back to
that offset alone.

---

## 6. Input actions (`project.godot`)
`weapon_fire` (LMB), `aim` (RMB), `reload` (R), `weapon_slot_1/2/3` (1/2/3). All are rebindable
in the settings menu automatically. Add `weapon_slot_4` (etc.) if you add more quick-swap slots.

---

## 7. Adding a new weapon — step by step

**Example: the battle rifle (`scenes/rifle.tscn`) is the reference — copy its pattern.**

### A. The weapon scene
Make a `.tscn` whose **root has a weapon script** (`HitscanWeapon` for single/burst, or
`MinigunWeapon`). Two valid shapes:
- **Direct** (like `minigun.tscn`): the root is the model instance with the script on it.
- **Wrapper** (like `rifle.tscn`, best for a big/embedded art scene): a bare `Node3D` root with
  the script, instancing your art scene as a child, so you never edit the heavy art file.

The scene needs, somewhere in its tree:
- a **muzzle** `Marker3D` (shots originate here) — set `aim_origin_node_path` to it.
- an **`ADSmarker`** (or `Sight`) `Marker3D` for aim-down-sights.
- `aim_local_direction` = the barrel's forward axis in the root frame (the minigun/rifle point
  `+X`, so `(1,0,0)`; orient the root so that axis faces the camera's forward, e.g. copy the
  minigun root's basis `Transform3D(0,0,1, 0,1,0, -1,0,0, ...)`).

**Give the weapon its own tracer scene — don't point it at another gun's.** Duplicate
`scenes/hitscan_tracer_effect.tscn` to `scenes/<weapon>_tracer_effect.tscn` and set
`hitscan_tracer_scene` to your copy. Every export on `WeaponHitscanTracerEffect`
(`scripts/weapons/weapon_hitscan_tracer_effect.gd`) — color, width, speed, glow, impact
sparks — is then that weapon's alone to tune. `NetworkManager` looks up each
weapon's own tracer scene by `weapon_id` when relaying the shot to other clients
(`get_tracer_scene_for_weapon`), so a bystander sees the exact same tracer the shooter
does — sharing one tracer scene across guns means every gun using it looks and sounds
identical, including to everyone else in the match.

**Give the weapon its own muzzle-flash scene — same pattern as the tracer.** Duplicate one
of `scenes/<gun>_muzzle_flash.tscn` to `scenes/<weapon>_muzzle_flash.tscn` and set the gun's
`muzzle_flash_scene` export (right under Hitscan in the inspector) to it. The flash scene's
root is a `WeaponMuzzleFlash` (`scripts/weapons/weapon_muzzle_flash.gd`) with everything
tunable in the inspector: `effect_scene` (pick any Binbun variant from
`MuzzleFlashVFX/muzzle_flash/effects/…` — muzzle/short/wide/big × 6 looks each),
`overall_scale`, `flash_length` (stretch down the barrel), `flash_width`, `muzzle_offset`,
optional color/light overrides, `speed_scale` (snappier vs longer burn), and
`cut_on_fire_stop` (sustained-fire guns only: kills the flash the instant the gun stops
firing — the minigun uses it so the flash can't outlive the trigger into spin-down; leave
it off on single-shot/burst guns or their final flash gets clipped). The weapon
places it at the muzzle marker automatically (facing `aim_local_direction`) and re-triggers
it once per fired round, so it follows the gun's fire rate and pattern (bursts, full-auto,
singles) with zero extra wiring. Blank export = no flash (the plasma cannon has none).
There is **no pivot auto-snap** — position the gun directly via the root node's transform
(fine-tune in-editor like a viewmodel).

### B. Tune it in the Inspector
Damage, `rounds_per_second`/`burst_count`, `hitscan_spread_degrees`, the three recoil channels
(§3), `mag_size`/`reload_time`, `ads_fov`. Use the existing guns as reference (§8).

### C. Register it (`weapon_registry.tres`) — same flow as the map registry
Weapons live in a **resource registry** exactly like maps (`map_registry.tres`). No code edit:
1. Double-click `weapon_registry.tres` in the FileSystem dock, add an element to `weapons`, and
   drag your weapon `.tscn` into its `scene` slot. `id`/`display_name` auto-derive from the
   filename (`WeaponListing.resolve_id/resolve_name`), so set them explicitly only when the id
   must differ from the filename. **Entry ORDER is the quick-swap slot order** (first = key 1).
2. That's it — `WeaponInventory` preloads the registry and every consumer reads it through the
   static lookups (`get_weapon_ids()` / `get_weapon_scene()` / `get_weapon_name()`): the shop
   (via matching group id), the server's ammo/damage validation (`ServerEconomy.get_weapon_stats`),
   the FFA pool, and `NetworkManager.get_tracer_scene_for_weapon`. Preloading the `.tres` also makes
   the exporter bake the weapon scene into the server binary.
3. (Quick-swap) the id auto-maps to `weapon_slot_<n>` by its registry index. Only if you exceed
   the existing slot keys, add `elif event.is_action_pressed("weapon_slot_<n>"): ...try_quick_swap(<n-1>)`
   in `player.gd _input` and add the `weapon_slot_<n>` action to `project.godot`.

**Charge-up weapons** (like the railgun): root the scene with `ChargeHitscanWeapon`
(`scripts/weapons/charge_hitscan_weapon.gd`) instead of `HitscanWeapon`. Holding the trigger
charges; releasing fires one shot whose **damage and tracer width** scale from a tap to a full
charge. `hitscan_damage` is the FULL-charge value (and what the server clamps claims to — a
charged shot needs no economy change). Tune `max_charge_time`, `charge_min_damage_fraction`,
`tracer_charge_min_scale`/`_max_scale`, `charge_min_recoil_mult`. The tracer width is relayed
with the shot (a trailing `tracer_scale` arg on the weapon-shot RPCs — this is why
`NET_PROTOCOL_VERSION` is 2) so bystanders see the same-sized beam.

Purchase/ownership need no new code: `player.purchase_weapon(id)` / `player.has_weapon(id)`
are generic pass-throughs to the inventory, and online purchases are validated by the
server (`ServerEconomy`) before the item is applied.

### D. Sell it (`scripts/buy_menu.gd`)
1. Add an entry to `shop_items` (`id`, `section:"WEAPONS"`, `group`, `title`, `description`,
   `price`) with **`group` equal to the weapon id** from step C.
2. Add the group to the `WEAPON_GROUPS` const. That's it — the generic handler routes it
   through `player.purchase_weapon(...)` / `player.has_weapon(...)`.

### E. Ship it
Re-export the Linux **server** binary (scene changes alter the packed data; a stale server
triggers "rpc node checksum failed"). See `DEPLOY.md`.

---

## 8. Current guns (reference tuning)

| | Minigun | Railgun | Battle Rifle | Plasma Cannon |
|---|---|---|---|---|
| Script | `MinigunWeapon` | `ChargeHitscanWeapon` | `HitscanWeapon` | `ProjectileWeapon` |
| Fire | wind-up 0.92s, 50 rps | hold-to-charge (1.1s), release to fire | 3-round burst, semi-auto | 1.4 rps, semi-auto, 55 m/s bolt |
| Damage | 15 | 35 (tap) → 100 (full charge) | 12 (36/burst) | 100→5 radial falloff |
| Spread | (0.58, 1.75)° | 0 | (0.35, 0.35)° | 0 |
| Mag / reserve / reload | 200 / 600 / 3.0s | 5 / 20 / 1.8s | 36 / 108 / 2.2s | 5 / 20 / 2.6s |
| `ads_fov` | 62 | 42 (scope) | 55 | 55 |
| `recoil_kick_up` | 0.48 (×50/s) | 32.0 | 4.0 | 10.0 |
| `recoil_kick_side` | 0.2 | 0.7 | 1.0 | 0.8 |
| `fire_knockback_force` | 0.12 | 13.33 | 0.6 | 9.0 |
| `fire_torque_strength` | 0 | 0 | 0 | 0 |
| Extra | `sustained_kickback (0,0.004,0.03)`, heat ramp ×2.5 over 3s | big backward `recoil_position_offset` | — | editable blast + airburst curves |

---

## 9. Conventions & gotchas

- **`recoil_kick_up` is per shot.** 50 rps guns need tiny values; single-shot guns want big ones.
- **Leave `fire_torque_strength` at 0.** It's a fixed-direction body spin (always tumbles the
  same way regardless of aim) — it feels wrong. Use `fire_knockback_force` for the aim-following push.
- **Keep `recoil_rotation_degrees.y` at 0.** Rays fire along the recoiled mount, so a constant
  yaw kick deflects actual shots sideways (this was the minigun's shoots-left bug). Side feel
  belongs in the symmetric `recoil_random_rotation_degrees.y`.
- **`+Z` in viewmodel-space `recoil_position_offset`/`sustained_kickback` = toward the player.**
- **No pivot snap.** Guns sit at their scene transform. `aim_origin_node_path` is the muzzle marker.
- **Ammo display is client-side; enforcement is server-side.** The HUD mag/reserve is local,
  but the server mirrors a per-peer ammo ledger (`scripts/server_economy.gd`): every accepted
  damage claim consumes a round, reloads are rate/reserve-checked, claims are rejected if the
  shooter doesn't own the weapon or the ledger is dry, and damage is clamped to the claimed
  weapon's real damage.
- **Only the local player** runs weapon input/animation; guard anything player-facing behind that.
- **Re-export the server** after any weapon/scene change (checksum).
- If a `.tscn` is **open in the editor** while you edit it on disk, use *External Changes →
  Reload* or the editor's in-memory copy will overwrite your changes on save.
