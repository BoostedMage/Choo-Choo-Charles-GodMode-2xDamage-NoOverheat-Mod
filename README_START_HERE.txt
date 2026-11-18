CHOO-CHOO CHARLES - GOD MODE / 2x DAMAGE / NO OVERHEAT
Version 0.6.0 ALPHA - performance update, complete package
========================================================

WHAT THIS UPDATE CHANGES

This update reduces repeated work done by the mod while you play. Your working
cave-NPC protection and No Overheat mechanism are retained. The native guard
DLL, protection/damage core, heat-field implementation and top-right HUD are
unchanged from v0.5. The changes are in scheduling, discovery and diagnostics.

The previous version repeatedly re-enabled and fully checked an already-active
player guard. This version keeps that guard continuously installed, verifies it
on a slower maintenance cadence, and still handles activation, actor changes,
failures and F6 OFF immediately when they are processed. It also reduces
repeated object searches, duplicate cooling checks and diagnostic work during
combat. Log lines are written in batches. Large reflection dumps now run only
when you press F9; routine automatic records are compact.

Your latest report contained four automatic reflection dumps and no F9 presses.
It did not contain frame times, so there is no measured FPS improvement to quote.
This release targets the identified overhead and still needs a live smoothness
check on your PC.

INSTALL / UPDATE

1. Exit Choo-Choo Charles completely.
2. Extract the ENTIRE ZIP into a normal folder. Keep the Mod folder, all seven
   Lua modules, and Scripts/native/ccc_guard.dll together.
3. Run INSTALL_God_Mode.cmd from the extracted folder.
4. Start the game normally and enter a gameplay level.

This is a full update. The installer verifies required files and staged hashes,
backs up the previous mod and existing saves locally, and replaces this mod's
folder. Your installed UE4SS and its settings are reused. The installer prints
the backup location. Both supported layouts work: UE4SS beside the shipping
EXE, or in Win64/ue4ss. The included native DLL belongs to this mod; it does not
replace UE4SS.dll or the game executable.

Fully restart after installing. Do not hot-reload this mod or delete its files
while the game is running: restoration records belong to the current session.

CONTROLS - PLAIN FUNCTION KEYS, NO CTRL

  F6   God Mode: ON/OFF          Character protection, including custom Damage
  F7   Train God Mode: ON/OFF    Locomotive protection
  F8   Double Damage: ON/OFF     2x hit-region damage multipliers against Charles
  F10  No Overheat: ON/OFF       Suppress heat accumulation and jam lockout
  F9   Snapshot                 Record a detailed diagnostic snapshot
  F11  Hide/show HUD            Changes visibility only

All four modes start ON each game launch. Press once to turn a mode OFF and
again to turn it ON. The small panel remains at the TOP RIGHT:

  F6 God Mode: ON
  F7 Train God Mode: ON
  F8 Double Damage: ON
  F10 No Overheat: ON
  [F9 Snapshot | F11 Hide HUD]

ON (NOT READY) means the requested protection did not pass its runtime checks
or an observed protection gap remains recorded. For F6, the custom Damage guard
must have passed its checks. For F10, the six exact counter/flag fields must be
found and writable. OFF (RESTORING) means an original value/function could not
yet be restored; the mod keeps its restoration record and retries.

FOCUSED PERFORMANCE CHECK

Keep F6 and F10 ON. Walk and look around, then fire continuously beyond the old
overheating point. Check whether movement and aiming remain smooth, including
in the area where the NPC shot you. There is no need to press F9 during normal
play just to make the modes work.

If choppiness remains:
  1. Stop somewhere safe, away from combat, while still in the gameplay level.
  2. Press F9 once and allow a moment for the detailed snapshot to finish.
  3. Close the game and run COLLECT_Mod_Test.cmd from this package.
  4. Upload the new UPLOAD_THIS_ChooChooCharles_ModTest_....zip beside it.

F9 can itself cause a brief hitch because it requests a detailed reflection
snapshot. It is not a recording start/stop key. Compact diagnostics run
without F9. Do not repeatedly press it while judging normal frame pacing, and
do not wait until the main menu for the only capture.

RETAINED GAMEPLAY / DIFFICULTIES

You confirmed sustained firing and survival after an NPC shot with v0.5. The
supplied v0.5 report records NightmareMode=true during player damage events;
the older Classic baseline was also user-confirmed. The same protection code
is used for both difficulties. No difficulty flag, graphics setting or frame
rate cap is changed by this update.

No Overheat still clears the Machine Gun, Range Gun and Flamethrower Jamming
floats and Jammed booleans. It keeps the existing 16 ms game-thread schedule
when supported, with a 50 ms fallback. Fire rate and firing cycles are unchanged.
F10 OFF stops cooling without restoring stale heat. No unsupported Rocket heat
property is invented.

The custom player guard still requires the observed UE4SS 4.0.0 / Unreal 4.26
ABI. It stops the observed player Damage function before its body executes.
F6 OFF restores that function; closing the game discards the in-memory patch.
This release changes performance, not the set of damage routes covered. See
TECHNICAL_NOTES.txt for the train-health warning observed in the latest report.

REMOVAL / SOURCE

Close the game and run UNINSTALL_Mod.cmd. It removes this mod and keeps UE4SS.
The collector includes mod logs and hashes, not saves, DLL bytes or game assets.
The installer keeps local backups; the collector does not upload them.

TECHNICAL_NOTES.txt explains the evidence, mechanism and scope.
VALIDATION_RESULTS.txt records local verification and its limits.
NativeSource/ contains the unchanged native companion source and build script.
Verification/ contains developer tests, which are not required to play.
