# Upload Test Map

The start menu's **Upload Test Map** button loads a Blender blockout directly into an
offline single-player session. Select either:

- `.glb` — recommended, because mesh data and textures are packed into one file.
- `.gltf` — supported; keep its `.bin` and image files beside the `.gltf`.

No Godot editor setup is required.

## Blender naming conventions

Names are case-insensitive, and Blender suffixes such as `.001` are accepted.

| Blender object name | Runtime result |
| --- | --- |
| `spawn` or `spawn_*` | Team A player spawn. The object's local `-Z` is player forward. |
| `spawn_b` or `spawn_team_b` | Optional Team B spawn. |
| `light` or `light_*` | Becomes an `OmniLight3D` with energy 16 and range 4096. |
| Any Blender light | Also normalized to the same `OmniLight3D` settings. |
| `no_collision` or `nocollide_*` | This object and its children remain visual-only. |
| Any other mesh | Gets a static body and trimesh collision automatically. |

Put `spawn` at the center of the player's standing capsule: normally 1 metre above a
floor. Apply object transforms before export when practical.

## Materials and lighting

Authored glTF albedo textures are kept automatically. Untextured meshes get the existing
`Resources/Textures/Blockout/GreyGrid.png` asset sampled with a world-space triplanar shader, so they need no
UVs or copied texture asset. The grid reads in 1-metre cells with 10-metre major lines.

The importer always adds ambient environment lighting. Every imported/generated gameplay
light is an `OmniLight3D` with energy `16` and maximum range `4096`. If the file has no
lights, a default omni light with those same settings is added.

This workflow is intentionally single-player and is not available to multiplayer hosts or
dedicated servers.
