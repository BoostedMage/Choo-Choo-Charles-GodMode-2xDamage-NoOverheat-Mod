DEVELOPER VERIFICATION - NOT REQUIRED TO INSTALL

Lua/native core checks: python3 Verification/run_lua_tests.py
Requires Python3, Lua5.4 shared library and cc on Linux. Diagnostics reproduces
UE4SS iterator C-stack behavior; guard tests compile the actual portable patch
core and an actual Lua C return-count fixture. Other engine boundaries are
simulated. No game or Windows runtime is executed by this harness.

Optional Windows companion rebuild:
  Set CCC_ZIG to a Zig0.13.0 compiler path, then run:
  python3 NativeSource/build_guard.py
The built DLL is already included. Only the DLL is needed during gameplay.

PowerShell helper checks:
  pwsh -NoProfile -File Verification/test_installer_helpers.ps1 -SourceRoot .
Filesystem smoke:
  Set CCC_PWSH to an available pwsh executable, then run:
  python3 Verification/smoke_installer.py
Native/logger payload completeness/corruption checks:
  python3 Verification/test_install_completeness.py
Static script checks:
  python3 Verification/validate_installer.py

Filesystem tests use temporary fake game trees and test-only process/backup
stubs. They exercise real scripts but do not run the game. Output filenames
record the current release; BASELINE_v0.3.0_ files are explicitly historical.

The unchanged v0.5 companion and heat feature have user-reported live success.
Local passes do not establish v0.6 frame-time improvement or cover every game
damage route. See
VALIDATION_RESULTS.txt and TECHNICAL_NOTES.txt for the exact verification scope.
