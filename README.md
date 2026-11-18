# Choo-Choo Charles — God Mode, 2x Damage and No Overheat

**Current release: v0.6.0 Alpha.** Unofficial Windows mod for Choo-Choo Charles using an existing UE4SS 4.0.0 installation and the observed Unreal Engine 4.26 runtime.

## Install

Download `ChooChooCharles_GodMode_2xDamage_NoOverheat_v0.6.0_ALPHA.zip` from this repository's Releases page. Close the game, extract the entire ZIP, and run `INSTALL_God_Mode.cmd`. Keep all seven Lua modules and `Scripts/native/ccc_guard.dll` together. Fully restart the game after an update; hot reload is unsupported.

The installer reuses UE4SS, verifies the payload, and makes local backups of the previous mod and saves. UE4SS and game assets are not included. To remove this mod, close the game and run `UNINSTALL_Mod.cmd`.

## Controls

| Key | Action |
| --- | --- |
| F6 | Toggle player God Mode |
| F7 | Toggle train protection |
| F8 | Toggle 2x damage against Charles |
| F10 | Toggle No Overheat |
| F9 | Detailed diagnostic snapshot |
| F11 | Hide/show the top-right HUD |

The four gameplay modes start ON. `ON (NOT READY)` reports an unverified mode or a recorded protection gap; `OFF (RESTORING)` reports pending restoration.

## v0.6.0 performance update

This version reduces repeated guard validation, object searches, duplicate cooling checks, and diagnostic work during combat. Log writes are batched; full reflection snapshots run only on F9. The previously supplied protection core, no-overheat implementation, native helper and HUD remain unchanged.

**Known limits:** Choppy frame pacing is still reported with v0.6.0, so the performance issue remains unresolved; no measured FPS increase is claimed. The supplied report records train-health loss with F7 ON, and this update does not fix every train-damage route. F9 may briefly hitch while gathering its detailed snapshot. Earlier user testing confirmed the retained no-overheat and player-protection mechanisms, not a successful v0.6.0 performance fix.

## Source and verification

The original release's 49 files are preserved, including the native helper DLL, its C source, build script, developer tests and validation records. GitHub preparation adds only this README, release notes and `.gitignore`.

See [installation notes](README_START_HERE.txt), [technical notes](TECHNICAL_NOTES.txt), [recorded validation](VALIDATION_RESULTS.txt), and [developer verification instructions](Verification/README_VERIFICATION.txt). The recorded tests use simulated engine boundaries and temporary fake installations; they are not a Windows game benchmark.

Publication checks verified archive integrity, all 48 manifest checksums, Python syntax and compilation of all seven gameplay Lua modules with Lua 5.4. No game, installer or native DLL was executed during publication.

Personal diagnostic archives, saves, backups, logs and generated test files are excluded from future commits. No open-source license has been added; third-party components retain their own terms.
