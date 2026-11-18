# Choo-Choo Charles v0.6.0 Alpha

God Mode, train protection, 2x damage against Charles, and No Overheat, with a top-right status HUD. This is the original v0.6.0 Alpha performance update; gameplay code and the installer are unchanged by publication.

## Performance changes

- Keeps the active native player guard installed and reduces repeated maintenance validation.
- Reuses validated objects and avoids duplicate cooling work during stable play.
- Moves heavy diagnostics out of damage callbacks and batches log writes.
- Runs full reflection snapshots only when F9 is pressed.
- Retains the prior protection core, no-overheat mechanism, native helper DLL and HUD.

## Install and controls

Download **ChooChooCharles_GodMode_2xDamage_NoOverheat_v0.6.0_ALPHA.zip**, close the game, extract the whole archive, and run **INSTALL_God_Mode.cmd**. Requires the existing UE4SS 4.0.0 setup used by the mod. Fully restart after updating.

F6: player God Mode; F7: train protection; F8: 2x damage; F10: No Overheat; F9: diagnostic snapshot; F11: hide/show HUD. All four gameplay modes start ON.

## Known limits

- Alpha release: choppy frame pacing is still reported with v0.6.0. The performance issue remains unresolved, and no measured FPS increase is claimed.
- Train-health loss was recorded with F7 ON; this release does not fix every train-damage route.
- F9 can briefly hitch while producing its detailed snapshot.
- Prior live success with player protection and No Overheat does not establish coverage of every damage route.

The original validation records and developer tests are included. Publication verified archive integrity, all 48 manifest checksums, Python syntax, and Lua 5.4 compilation of all seven gameplay modules. The Windows game, installer and native DLL were not executed during publication.

**Original ZIP SHA-256:** `761a2117fb8da2e3d1f2909dacc72913f4b7bb7c20d4804afcb4b4d300fdfa54`
