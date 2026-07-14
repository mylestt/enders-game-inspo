# Map Creator

In-game arena editor, reached from the start menu (**Map Creator**). Build maps from
primitive shapes, import 3D model files, place spawns and lights, then playtest solo —
no Godot editor involved. Everything lives under `scripts/map_creator/`.

## Where maps live

```
user://custom_maps/<slug>/map.json    the map (data-only JSON — see MapDocument)
user://custom_maps/<slug>/assets/     imported model files, copied in at import time
```

On Windows: `%APPDATA%\Godot\app_userdata\EndersGameInspo\custom_maps\`. Maps are
self-contained — the folder can be zipped and dropped onto another PC. Nothing in a map
file can execute code: MapDocument type-checks and clamps every field on load.

## Editor controls

| Input | Action |
| --- | --- |
| RMB (hold) | Fly camera — WASD + Q/E down/up, Shift = fast, wheel = speed |
| LMB | Select object / drag a gizmo handle / confirm keyboard transform |
| 1 / 2 / 3 (or toolbar) | Gizmo tool: Move / Rotate / Scale — press again to hide the gizmo |
| Gizmo drag | Arrows = move along axis · rings = rotate around axis · cubes = scale along axis. Centre handle: white sphere = screen-plane move / view-axis rotate; white cube = uniform scale. Release confirms, Esc/RMB cancels |
| G / R / S | Keyboard-modal move / rotate / scale (Blender-style) |
| X / Y / Z | Constrain active transform to a world axis (press again to clear) |
| LMB / Enter | Confirm keyboard transform · Esc / RMB cancels |
| F | Focus camera on selection |
| Ctrl+D | Duplicate · Del/Backspace: delete |
| Ctrl+Z / Ctrl+Y | Undo / redo (snapshot-based, 64 steps) |
| Ctrl+S | Save |

The gizmo (red X / green Y / blue Z, world-aligned, constant screen size, drawn through
walls) and the G/R/S keys drive the same transform machinery — identical axis math, grid
snap, and undo. Handles live on their own physics layer, so clicking a handle can never
select the object behind it and vice versa.

Grid snap (toggle + step size) and sun/ambient/background settings are in the right-hand
panel when nothing is selected, along with a live "map check" report (spawn counts,
missing-light warnings).

## Shapes and the bevel tool

Primitives: box, sphere, cylinder, capsule, ramp, cone, torus. Dimensions are stored as
explicit fields and baked into the mesh — object nodes never carry scale, so nothing can
leak a scaled basis into player math (the repo-wide rule).

Godot has no runtime bevel/modeling tool, so `BevelMesh` generates beveled geometry
directly: **box** and **cylinder** have `Bevel Radius` + `Bevel Segments` in the
inspector. 1 segment = flat chamfer; more segments = smooth round-over; radius up to half
the smallest dimension turns a box into a capsule-ish pill. Normals are analytic (exact
arcs), and the smoke suite cross-checks triangle winding against a built-in BoxMesh so
the generator can never silently go inside-out.

## Colliders (automatic)

Every solid object gets the same structure the hand-built arenas use:
`MeshInstance3D → StaticBody3D → CollisionShape3D`.

- **Imported models**: every MeshInstance3D found in the file gets a **trimesh**
  (`ConcavePolygonShape3D`) body — instantly solid.
- **Beveled/curved-tessellated primitives** (beveled box/cylinder, ramp, cone, torus):
  trimesh.
- **Exact primitives** (plain box, sphere, cylinder, capsule): their **analytic** shape
  (BoxShape3D, SphereShape3D, …). This is deliberate: surface-walk needs smooth analytic
  normals on curved surfaces (see CLAUDE.md) — a trimesh sphere would stutter underfoot.

## Importing models

`Import Model…` accepts **.glb / .gltf / .obj / .stl / .fbx / .blend**. Files are copied
into the map's `assets/` folder (with `_2` suffixes on name collisions, and companion
files — `.bin`/textures for `.gltf`, `.mtl`+textures for `.obj` — collected too). After
import the model is a normal editor object: move/rotate/scale it, duplicate it, delete it.

Per-format notes:

- **.glb/.gltf** — engine-native runtime loader (GLTFDocument). The most reliable format;
  prefer it.
- **.fbx** — engine-native (FBXDocument/ufbx). Embed media in the file; external FBX
  textures are not collected.
- **.obj** — hand-written parser (`v/vt/vn/f`, negative indices, fan triangulation) with
  basic `.mtl` support (`Kd` color, `d` alpha, `map_Kd` texture).
- **.stl** — hand-written parser, binary + ascii, flat-shaded.
- **.blend** — converted through Blender itself, run headless in the background
  (`blender -b file.blend --python-expr "export_scene.gltf(...)"`), keeping the resulting
  `.glb` in assets. Blender is auto-detected (settings.cfg `tools/blender_path`, PATH,
  then standard install dirs); if not found, the editor shows a dialog where the path can
  be pasted once (persisted). No Blender → export `.glb` from Blender manually instead.

## Spawns, lights, environment

- **Spawn A / Spawn B** place player-capsule stand-ins (blue/orange, nub = facing). At
  runtime they become real `SpawnPoint`s and join `spawn_team_a`/`spawn_team_b` — exactly
  what NetworkManager/FFA spawning reads. In the editor they are inert proxies (never
  join groups). Placing on a wall/ceiling orients the spawn to the surface — players
  spawn surface-walking there.
- **Omni / Spot lights** with color, energy, range, angle, shadows; editable sun
  (direction/color/energy) plus ambient + background color per map.

## Playtest and playing custom maps

- **Playtest** (top bar) saves, then launches the offline Test Arena on the map
  (`GameLaunch.map_id = "custom:<slug>"`). Leaving via the pause menu returns to the
  start menu, which reopens the editor on the same map automatically.
- Custom maps also appear in the **Test Arena** map dropdown as "Custom: <name>".
- **Online lobbies cannot use custom maps yet** — the id is machine-local, and the VPS
  has no copy of the file. `MapGenerator.has_map()` is only true where the file exists,
  so a server receiving a custom id falls back to its current map safely. Networked
  custom maps would need a map-file sync channel (deliberately not built yet).

## Runtime id plumbing (for code)

`MapGenerator.CUSTOM_MAP_PREFIX` (`"custom:"`) marks custom ids. `build_map()` routes
them to `CustomMapBuilder.build_map_node(doc, edit_mode=false)`; a missing/corrupt file
falls back to the default arena rather than booting into a void. `--map custom:<slug>`
works from the command line where the file exists. No `@rpc` surface was touched —
NET_PROTOCOL_VERSION is unchanged.
