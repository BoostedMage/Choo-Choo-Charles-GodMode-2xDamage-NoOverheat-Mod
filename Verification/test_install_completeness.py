"""Check native-package preflight and staged SHA256 verification in fake game trees.

Runs the actual install script under PowerShell. Only fixture copies are changed.
The executable and UE4SS.dll are inert sentinel files and are never executed.
Set CCC_PWSH to a PowerShell executable if pwsh is not available on PATH.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


VERIFICATION = Path(__file__).resolve().parent
SOURCE = VERIFICATION.parent
PWSH = os.environ.get("CCC_PWSH") or shutil.which("pwsh")
if not PWSH:
    raise SystemExit("Set CCC_PWSH to PowerShell 7 or add pwsh to PATH for this developer test.")

messages = []
assertions = 0


def check(condition, message):
    global assertions
    if not condition:
        raise AssertionError(message)
    assertions += 1


with tempfile.TemporaryDirectory(prefix="CCC_install_completeness_") as temporary:
    base = Path(temporary)
    package = base / "package"
    package.mkdir()
    for name in ("INSTALL_God_Mode.ps1", "CCC.Tools.ps1"):
        shutil.copy2(SOURCE / name, package / name)
    shutil.copytree(SOURCE / "Mod", package / "Mod")
    with (package / "CCC.Tools.ps1").open("a", encoding="utf-8") as stream:
        stream.write(r'''
# Test-only overrides: no real process check or user backup destination is used.
function Assert-GameClosed { }
function New-LocalBackupRoot {
    $path = Join-Path $env:CCC_COMPLETENESS_ROOT ('backups/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
''')

    game = base / "game"
    loader = game / "Obscure/Binaries/Win64"
    loader.mkdir(parents=True)
    (loader / "Obscure-Win64-Shipping.exe").write_bytes(b"FAKE executable; never execute")
    loader_bytes = b"existing UE4SS loader sentinel"
    (loader / "UE4SS.dll").write_bytes(loader_bytes)
    installed = loader / "Mods/ChooChooCharles_GodMode"
    installed.mkdir(parents=True)
    old_bytes = b"previous installed mod sentinel"
    (installed / "old.txt").write_bytes(old_bytes)
    config = loader / "Mods/mods.txt"
    config_bytes = b"OtherMod : 1\nChooChooCharles_GodMode : 0\n"
    config.write_bytes(config_bytes)
    environment = os.environ.copy()
    environment.update(
        LOCALAPPDATA=str(base / "local"),
        USERPROFILE=str(base / "profile"),
        CCC_COMPLETENESS_ROOT=str(base),
    )

    def run_install():
        result = subprocess.run(
            [str(PWSH), "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
             str(package / "INSTALL_God_Mode.ps1"), "-GamePath", str(game)],
            cwd=package, env=environment, text=True, capture_output=True, timeout=30,
        )
        check(result.returncode == 1,
              f"Expected installer refusal, got {result.returncode}:\n{result.stdout}\n{result.stderr}")
        return result

    def check_original_install():
        check((installed / "old.txt").read_bytes() == old_bytes, "Previous mod bytes changed")
        check(sorted(path.name for path in installed.iterdir()) == ["old.txt"],
              "Installed mod received new or unexpected files")
        check(config.read_bytes() == config_bytes, "Original mods.txt bytes changed")
        check((loader / "UE4SS.dll").read_bytes() == loader_bytes, "Existing UE4SS was changed")
        check(not list(loader.glob("CCC_Install_Staging_*")), "Inactive staging was left behind")

    for relative in ("Scripts/native/ccc_guard.dll", "Scripts/playerguard.lua", "Scripts/logger.lua"):
        missing = package / "Mod/ChooChooCharles_GodMode" / relative
        original = missing.read_bytes()
        missing.unlink()
        try:
            result = run_install()
            check("The update is incomplete:" in result.stdout,
                  "Missing dependency did not reach package preflight")
            check(relative.replace("/", "\\") in result.stdout,
                  "Installer did not identify the missing dependency")
            check_original_install()
            check(not list(base.glob("backups/*")),
                  "Incomplete package was not rejected before creating backups")
        finally:
            missing.write_bytes(original)
        messages.append(
            f"PASS missing {relative}: rejected before backup/install; "
            "old mod, exact mods.txt and existing UE4SS preserved"
        )

    # Mutate the actual copied DLL, then let the unmodified installer calculate
    # both SHA256 hashes. Get-FileHash and the verification condition are real.
    with (package / "CCC.Tools.ps1").open("a", encoding="utf-8") as stream:
        stream.write(r'''
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Recurse)
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    if ((Split-Path -Leaf $Destination) -eq 'NewMod') {
        [IO.File]::WriteAllText((Join-Path $Destination 'Scripts/native/ccc_guard.dll'),
            'TEST injected corruption of the staged native companion')
    }
}
''')
    result = run_install()
    check("Staging verification failed: Scripts\\native\\ccc_guard.dll" in result.stdout,
          "Actual staged DLL corruption was not rejected by its SHA256 check")
    check_original_install()
    check(len(list(base.glob("backups/*/PreviousMod/old.txt"))) == 1,
          "Staging failure did not retain the expected local previous-mod backup")
    messages.append(
        "PASS corrupted staged DLL: actual SHA256 comparison rejected installation "
        "before installed mutation; staging cleaned; old mod, exact mods.txt and UE4SS preserved"
    )

messages.append(f"PASS total completeness assertions: {assertions}")
messages.append(
    "SCOPE: actual install script with temporary fake game trees and inert executable/DLL files. "
    "Test-only overrides stub process detection, keep backups inside the fixture, and corrupt "
    "the copied native DLL. No real game installation or game execution is tested."
)
output = "\n".join(messages) + "\n"
(VERIFICATION / "installer_completeness_validation.txt").write_text(output, encoding="utf-8")
print(output, end="")
