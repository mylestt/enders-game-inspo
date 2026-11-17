# Drydock — Blender build brief

Use Blender to build **Drydock**, a playable greybox for a 5v5 capture-the-flag shooter in zero gravity. Deliver an editable `drydock_ctf.blend`, a meter-scale `drydock_ctf.glb` for Godot, and two labeled overview images: an end-on cross-section and a lengthwise cutaway. Build and export the assets in this session.

## The play this map should produce

A carrier grabs the enemy flag while sliding around a bank, launches across the inside of the bend, rolls, and catches the far wall feet-first. A pursuer can follow. A defender who reads the exit early can cut through a side passage and meet the carrier at the landing. An escort in a third lane can challenge that defender. **Build this encounter first**, then mirror it and complete the arena.

## Layout and scale

- Use 1 Blender unit = 1 metre, with X along the length of the dock and Z up in the editor. Players can treat any face as a floor. Use a 2 m tall, 1 m diameter capsule as a scale reference.
- Start with a sealed dock about **150 × 54 × 40 m**. Put Blue’s flag bay near X = −62 m and Red’s near X = +62 m. Mirror gameplay geometry across X = 0. These are first-pass dimensions. Adjust them to preserve clearances, curves, and sightlines.
- Suspend a solid unfinished ship through midfield, roughly X = −45 to +45 m. Looking from Blue toward Red, **Hull** passes over its curved back, **Gantry** runs along one flank, and **Cargo** runs along the other. Use lengthwise dividers that meet both ship and dock shell. Keep the exterior sealed so a player cannot fly around the map. Cut a service passage between lanes in each half, roughly X = ±25 m.
- Give each flag bay two offset mouths. Hull and Gantry split beyond one mouth. Cargo reaches the other. Place five spawns per team in a protected side room with two exits and solid cover from midfield. Give each flag a broad sweep-through approach, enough room for a carrier and escort, and an escape in either direction.

## Shape the three lanes

**Hull — the fast run.** Build a continuous riding strip at least 6 m wide. Start with 25–30 m of run-up into a broad concave bank with roughly a 10–14 m bend radius. A beginner can ride the entire turn. A skilled player can cut a chord through open air and meet a wide receiving wall at a shallow angle. Check that the chord clears the ship. Give the runner a visible static grapple face before the bank. Sprint targets about 10.5 m/s, the grapple reaches 60 m, and sliding preserves speed the player already earned. Build both the launch and the catch into the geometry.

**Gantry — the rifle fight.** Make a 30–45 m clear midfield firing line with a solid bend before each flag bay. Give each half one firing slit angled toward the Hull landing. A defender at the slit should see the runner arrive, then lose sight as the runner exits. Keep the slit too narrow for the player capsule. Put cover beside the main slide surface so a stationary player and a passing teammate can share the lane.

**Cargo — the close fight.** Use two offset, solid bulkheads to form a broad S-turn with typical sightlines of 8–15 m. Carry a smooth, continuous sliding face around both bends. Put sheltered fighting pockets on the inside of the turns. Extend the bulkheads far enough around the cross-section that rolling onto the ceiling still gives a close-range fight.

## Surface and export requirements

- Build the banks with actual curved collision geometry. Give walls thickness and orient their playable faces toward the air. Weld seams along riding surfaces, apply mesh scale, and keep door lips, trim, railings, and protruding bolts clear of slide paths.
- Use shape as well as color for navigation. Give Hull a smooth skin, Gantry a repeating frame, and Cargo deep divider walls. Assign blue and red Base Colors to the team materials so the game tints its grey checker on those surfaces.
- Export ten separate Empties named `spawn_a_01` through `spawn_a_05` and `spawn_b_01` through `spawn_b_05`. A is Blue and B is Red. Place each at capsule center, about 1 m off its starting face. After glTF conversion, Godot local −Z should face a protected exit and local +Y should point away from the surface.
- Export `flag_a_anchor` and `flag_b_anchor` as Empties marking the capture-point placements and orientations. The Godot integrator will align the existing paired flag scene to them. Omit preview cameras, route arrows, labels, and the scale capsule from the gameplay GLB. The game’s offline importer gives ordinary meshes collision.

## Check the result before delivery

1. Trace a capsule-sized path down every lane, in both directions. Check each bank seam, doorway, shortcut, and landing. Trace the easy continuous Hull line as well as the expert airborne chord.
2. Test sightlines at player-eye height from several surfaces. Flag-to-flag and midfield-to-spawn rays should hit solid cover. The Gantry slit should see the intended Hull landing. Check the same angles from the opposing team’s side.
3. Reimport the GLB and verify scale, bounds, ten uniquely named spawns, two flag anchors, and the team colors. In the overview images, label the three lanes, both flags, the expert chord, and the defender’s cut.
4. Report which geometry and export checks passed and identify any unresolved issues. The first Godot playtest is a carrier and a defender swapping roles on the Hull exit. Slide retention, interception timing, and scoring are in-engine checks.
