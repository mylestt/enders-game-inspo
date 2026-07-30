# Project Structure

This project uses a **Resources-centered, type-then-feature** layout:

1. Files Godot imports or loads at runtime live under `Resources/`.
2. The first folder describes the resource type (`Scripts`, `Objects`, `Models`,
   `Materials`, and so on).
3. The next folder describes the gameplay feature (`Player`, `Weapons`,
   `Pickups`, `Maps`, `Networking`, and so on).
4. Developer-only utilities live under `tools/`, documentation under `docs/`,
   and generated output under the ignored `build/` folder.

This hybrid keeps Godot's FileSystem dock predictable without returning to large,
unrelated `scripts/` and `scenes/` folders.

## Canonical tree

```text
Resources/
├── Branding/                 Project icon and branding assets
├── Maps/                     Complete playable map scenes
├── Materials/
│   ├── Level/                Level material resources and texture sets
│   └── Shaders/              Shader source grouped by purpose
├── Models/
│   ├── Characters/
│   ├── Enemies/
│   ├── Maps/
│   ├── Pickups/              Create when a pickup needs an imported model
│   ├── Weapons/
│   └── World/
├── Objects/
│   ├── Gamemodes/
│   ├── Pickups/
│   ├── Weapons/
│   │   └── Effects/
│   └── World/
├── Registries/               Data-driven map and weapon lists
├── Scenes/
│   ├── Core/                 Start menu and main application scenes
│   └── Tests/                Standalone test/preview scenes
├── Scripts/
│   ├── Core/
│   ├── Enemies/
│   ├── Gamemodes/
│   ├── Maps/
│   ├── Networking/
│   ├── Pickups/
│   ├── Player/
│   ├── UI/
│   ├── Weapons/
│   └── World/
├── Source/                   Editable authoring files, not runtime exports
├── Sprites/
├── Textures/
├── VFX/                      Self-contained effects or third-party bundles
└── Widgets/                  C# UI scenes and controls
```

Some older assets already inside `Resources/` predate this convention. They are
kept in place to avoid needless churn. New files should follow the structure
above, and old files should move only as part of a focused change that updates
and validates every reference.

## Placement rules

| Content | Location | Notes |
| --- | --- | --- |
| Player controller code | `Resources/Scripts/Player/` | Movement, camera, health, grapple, boosters |
| Menu or HUD code | `Resources/Scripts/UI/` | Scene can live in `Resources/Scenes/Core/` or beside its reusable object |
| Network/session code | `Resources/Scripts/Networking/` | Lobby, round, server authority, replication |
| Complete map scene | `Resources/Maps/` | Register playable maps in `Resources/Registries/map_registry.tres` |
| Map import/build code | `Resources/Scripts/Maps/` | Includes uploaded test-map preparation |
| Weapon scene | `Resources/Objects/Weapons/` | Register it in `weapon_registry.tres` |
| Weapon tracer/muzzle effect | `Resources/Objects/Weapons/Effects/` | Give independently tuned weapons their own effect scene |
| Pickup or temporary boost scene | `Resources/Objects/Pickups/` | Health, damage, invisibility, speed boosts, jump boosts |
| Pickup behavior | `Resources/Scripts/Pickups/` | Shared pickup bases and feature-specific effects |
| Imported model | `Resources/Models/<Feature>/` | Keep relative textures beside the model in the same bundle |
| Standalone shader | `Resources/Materials/Shaders/<Purpose>/` | Material-local shaders may stay with their material bundle |
| Editable source art | `Resources/Source/<Tool>/` | Blender, Aseprite, and similar source files |
| Smoke/integration test | `tools/tests/` | Runtime source must never depend on test code |
| Exported game/server | `build/` | Ignored; safe to regenerate |

## Pickups and future boosts

Speed boosts belong to the pickup feature because they are world items that grant
a temporary player effect. Use:

```text
Resources/Objects/Pickups/speed_boost.tscn
Resources/Scripts/Pickups/speed_boost.gd
Resources/Models/Pickups/speed_boost.glb       # only if it needs a model
```

Keep three responsibilities separate:

- The pickup scene owns collision, visuals, audio, and respawn presentation.
- The pickup script requests or applies the effect.
- The player/status system owns effect duration, stacking rules, replication,
  cleanup on death, and the actual movement multiplier.

Permanent movement volumes that affect everyone while they are inside them are
world hazards, not pickups; put those scenes/scripts under `Objects/World` and
`Scripts/World`.

The existing `Resources/Scripts/PowerUp.cs` is the legacy shared pickup base and
remains in place. New pickup-specific scripts go in `Scripts/Pickups`; move the
shared base only during a dedicated migration with reference validation.

## Naming conventions

- Use `snake_case` for project-owned files and folders below the established
  top-level `Resources` directories.
- Match a primary scene and script name: `speed_boost.tscn` and `speed_boost.gd`.
- Use descriptive suffixes: `_controller`, `_manager`, `_hud`, `_projectile`,
  `_tracer_effect`, and `_muzzle_flash`.
- Imported vendor/source filenames may retain capitalization or spaces when
  renaming would break external dependencies.
- Do not create new gameplay files at the repository root.
- Do not use folders named `new`, `misc`, `temp`, or `final`; file by ownership.

## Dependency rules

- Reference project assets with `res://Resources/...`.
- Prefer registries for extensible pools rather than hard-coded scene lists.
- Keep imported files with relative dependencies together. The
  `Models/World/SpinSpaceBall/` bundle is the reference example.
- Preserve `.uid` files when moving GDScript or shaders.
- Move assets and rewrite their references in the same change.
- After a structural change, let Godot reimport and run the smoke suite before
  committing.

## Root-directory policy

The repository root is intentionally small:

- Required engine/build files: `project.godot`, `export_presets.cfg`, the C#
  solution/project.
- Project entry docs: `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `LICENSE`.
- Canonical folders: `Resources`, `docs`, `tools`, and ignored `build`.

IDE caches, Godot import state, server-manager compiler output, and exported
binaries are ignored. Historical build products do not belong in source control.
