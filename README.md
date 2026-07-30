# Zero-G Arena Movement Shooter

A Godot 4.6 Mono prototype built around six-degree-of-freedom movement, automatic
surface walking, momentum-preserving slides, grappling, arena weapons, and
server-authoritative multiplayer.

The project is proprietary. See [LICENSE](LICENSE) and
[CONTRIBUTING.md](CONTRIBUTING.md) before contributing.

## Getting started

1. Install the Godot 4.6 Mono editor.
2. Clone this repository.
3. Open [project.godot](project.godot) in Godot.
4. Run the project with F6/F5. The configured entry scene is
   `Resources/Scenes/Core/start_menu.tscn`.

For a quick map blockout test, choose **Upload Test Map** on the start menu and
select a `.glb` or `.gltf`. Blender nodes named `spawn` and `light` are converted
automatically, and gameplay meshes receive trimesh collision. See the
[test-map import guide](docs/guides/TEST_MAP_IMPORT.md).

## Repository layout

```text
Resources/                 Game content imported or loaded by Godot
  Maps/                    Playable map scenes
  Materials/               Materials and shaders
  Models/                  Imported models, grouped by feature
  Objects/                 Reusable gameplay scenes
  Registries/              Map and weapon registries
  Scenes/                  Application-level and test scenes
  Scripts/                 Runtime code, grouped by feature
  Source/                  Editable source art such as Blender/Aseprite files
  Textures/                 Standalone textures
  VFX/                     Self-contained visual-effects packages
docs/                      Architecture, design, guides, changelogs, and TODOs
tools/                     Tests, launchers, deployment utilities, and dev apps
build/                     Ignored local exports and generated packages
project.godot              Godot project configuration
export_presets.cfg         Export configuration
```

The full placement rules and naming conventions are in
[docs/PROJECT_STRUCTURE.md](docs/PROJECT_STRUCTURE.md).

## Adding content

- Maps: add the scene under `Resources/Maps/`, then register it in
  `Resources/Registries/map_registry.tres`.
- Weapons: place scenes under `Resources/Objects/Weapons/`, scripts under
  `Resources/Scripts/Weapons/`, and register them in
  `Resources/Registries/weapon_registry.tres`.
- Pickups and boosts: place scenes such as `speed_boost.tscn` under
  `Resources/Objects/Pickups/` and behavior such as `speed_boost.gd` under
  `Resources/Scripts/Pickups/`.
- Imported assets: keep a model and any relative texture dependencies together
  in a feature folder under `Resources/Models/`.
- Generated builds: always export under `build/`; never commit exported binaries.

## Development commands

Run the headless smoke suite from the repository root:

```powershell
<godot-console> --headless --path . -s tools/tests/run_smoke_tests.gd
```

Local multiplayer helpers are in `tools/launch/`. If Godot is installed
somewhere else, update the executable path in the two Windows batch files.

## Documentation

- [Current-state handoff](CLAUDE.md)
- [Technical architecture](docs/architecture/ARCHITECTURE.md)
- [Design overview](docs/design/PROJECT_OVERVIEW.md)
- [Project structure](docs/PROJECT_STRUCTURE.md)
- [Weapon authoring](docs/guides/WEAPONS.md)
- [Test-map import](docs/guides/TEST_MAP_IMPORT.md)
- [Server deployment](docs/guides/DEPLOY.md)
- [Project TODOs](docs/TODO.md)
