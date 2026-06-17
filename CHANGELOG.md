# Changelog

Changes in this branch, newest first. All are currently live.

## Movement / camera feel
- better cam imo, "Mouse look no longer injects persistent spin. The body now eases toward a decaying *target* angular velocity, so the view tracks closely and settles to rest with a short float instead of tumbling. (`player_movement_controller.gd`, `angular_damp` 1.2 → 0.5.)

## Weapon (first-person rifle)
- - rifle renders and is under camera tree
- - laser fires from the rifle's `Barrel` marker, with recoil + a small player knockback per shot — synced to the laser's fire rate.
- - hip fire 

## HUD
- push bar color updating White while charging when a surface is actually in push range; faded light red when there's nothing to push off. (`player_hud.gd`, `player_movement_controller.gd`)

## Docs
- Added `ARCHITECTURE.md` (project map) and this changelog.
</content>
