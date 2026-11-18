"""Run actual PS scripts against isolated fake game trees on Linux/PowerShell 7."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import zipfile

WORK = Path(__file__).resolve().parent
PWSH = os.environ.get("CCC_PWSH") or shutil.which("pwsh") or str(WORK / "tooling/pwsh-7.4.7/pwsh")
SOURCE = WORK.parent if WORK.name == "Verification" else WORK / "installer"
checks = []
passed = 0


def check(condition, message):
    global passed
    if not condition:
        raise AssertionError(message)
    passed += 1


with tempfile.TemporaryDirectory(prefix="ccc_smoke_") as temporary:
    fixture_root = Path(temporary)
    for layout in ("adjacent", "subfolder"):
        base = fixture_root / layout
        package = base / "package"
        shutil.copytree(SOURCE, package)
        with (package / "CCC.Tools.ps1").open("a") as stream:
            stream.write(r'''
# Test-only overrides: all backups/process checks stay inside the fake fixture.
function Assert-GameClosed { }
function New-LocalBackupRoot {
    $path = Join-Path $env:CCC_SMOKE_ROOT ('backups/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function Write-CCCModList($Plan) {
    if ($env:CCC_SMOKE_FAIL_WRITE -eq '1') { throw 'TEST injected mods.txt write failure' }
    [IO.File]::WriteAllBytes($Plan.Path, [byte[]]$Plan.Bytes)
}
''')
        game = base / "game"
        win64 = game / "Obscure/Binaries/Win64"
        loader = win64 if layout == "adjacent" else win64 / "ue4ss"
        loader.mkdir(parents=True)
        (win64 / "Obscure-Win64-Shipping.exe").write_bytes(b"FAKE executable; never execute")
        (loader / "UE4SS.dll").write_bytes(b"existing loader sentinel")
        (loader / "UE4SS-settings.ini").write_bytes(b"existing settings sentinel")
        mods = loader / "Mods"
        mod = mods / "ChooChooCharles_GodMode"
        (mod / "Scripts").mkdir(parents=True)
        (mod / "Scripts/main.lua").write_text("-- old main\n")
        (mod / "old_only.txt").write_text("previous version\n")
        (mods / "OtherMod").mkdir()
        (mods / "OtherMod/other.log").write_text("OTHER_MOD_PRIVATE_SENTINEL")
        original_config = b"OtherMod : 1\nChooChooCharles_GodMode : 0\n"
        (mods / "mods.txt").write_bytes(original_config)
        payload = package / "Mod/ChooChooCharles_GodMode"
        (payload / "Scripts").mkdir(parents=True, exist_ok=True)
        (payload / "Scripts/main.lua").write_text("-- new main\n")
        (payload / "Scripts/hud.lua").write_text("-- new HUD\n")
        save_root = base / "local/Obscure/Saved/SaveGames"
        save_root.mkdir(parents=True)
        (save_root / "progress.sav").write_text("SAVE_PRIVATE_SENTINEL")
        environment = os.environ.copy()
        environment.update(CCC_SMOKE_ROOT=str(base), LOCALAPPDATA=str(base / "local"), USERPROFILE=str(base / "profile"))

        def run(script, expect=0, fail_write=False):
            current_env = environment.copy()
            current_env["CCC_SMOKE_FAIL_WRITE"] = "1" if fail_write else "0"
            result = subprocess.run(
                [str(PWSH), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(package / script), "-GamePath", str(game)],
                cwd=package, env=current_env, text=True, capture_output=True, timeout=30,
            )
            if result.returncode != expect:
                raise AssertionError(f"{layout}/{script}: exit {result.returncode}, expected {expect}\n{result.stdout}\n{result.stderr}")
            return result

        def unchanged_shared():
            check((loader / "UE4SS.dll").read_bytes() == b"existing loader sentinel", "loader preserved")
            check((loader / "UE4SS-settings.ini").read_bytes() == b"existing settings sentinel", "settings preserved")
            check((mods / "OtherMod/other.log").read_text() == "OTHER_MOD_PRIVATE_SENTINEL", "other mod preserved")
            check((save_root / "progress.sav").read_text() == "SAVE_PRIVATE_SENTINEL", "save preserved")

        failed = run("INSTALL_God_Mode.ps1", expect=1, fail_write=True)
        check("TEST injected" in failed.stdout, "injected install failure observed")
        check((mod / "Scripts/main.lua").read_text() == "-- old main\n", "install rollback restores old main")
        check((mod / "old_only.txt").exists(), "install rollback restores old files")
        check((mods / "mods.txt").read_bytes() == original_config, "install rollback restores exact config")
        unchanged_shared()
        run("INSTALL_God_Mode.ps1")
        check((mod / "Scripts/main.lua").read_text() == "-- new main\n", "new payload installed")
        check((mod / "Scripts/hud.lua").exists(), "new module installed")
        check((mod / "Scripts/logger.lua").read_bytes() == (payload / "Scripts/logger.lua").read_bytes(), "new buffered logger installed exactly")
        check(not (mod / "old_only.txt").exists(), "whole folder replaced")
        check((mod / "enabled.txt").exists(), "enabled marker created")
        check((mods / "mods.txt").read_bytes() == b"OtherMod : 1\nChooChooCharles_GodMode : 1\n", "other mod entry preserved")
        check(len(list((base / "backups").glob("*/PreviousMod/old_only.txt"))) == 2, "old mod backups outside Mods")
        check(len(list((base / "backups").glob("*/SaveGames/progress.sav"))) == 2, "local save backups created")
        unchanged_shared()
        checks.append(f"PASS {layout}: actual install, prior folder replacement, local backups, exact config preservation and injected install rollback")

        log_text = "SESSION_FAKE_CURRENT\nEARLY_MARKER\n" + "reflection field\n" * 4000 + "LATE_MARKER\n"
        (mod / "CCC_Reflection.log").write_text(log_text)
        (mod / "CCC_Mod_Status.log").write_text("SESSION_FAKE_CURRENT\nstatus\n")
        (mod / "CCC_Events.log").write_text("SESSION_FAKE_CURRENT\ndamage\n")
        (mod / "CCC_Mod_Status.previous.log").write_text("SESSION_FAKE_PREVIOUS\nprevious\n")
        (mod / "hidden.sav").write_text("MOD_SAVE_PRIVATE_SENTINEL")
        nested = mod / "Logs/session_older"
        nested.mkdir(parents=True)
        (nested / "events.txt").write_text("old session\n")
        oversized = mod / "oversized.log"
        with oversized.open("wb") as stream:
            stream.truncate(32 * 1024 * 1024 + 1)
        outside = base / "not_mod.log"
        outside.write_text("EXTERNAL_PRIVATE_SENTINEL")
        (mod / "linked.log").symlink_to(outside)
        ue_lines = [f"ordinary line {i}" for i in range(4000)]
        ue_lines[200] = "CCC-GODMOD EARLY_UE4SS_MATCH"
        ue_lines[3800] = "CCC-GODMOD LATE_UE4SS_MATCH"
        (loader / "UE4SS.log").write_text("\n".join(ue_lines) + "\n")
        run("COLLECT_Mod_Test.ps1")
        archive = list(package.glob("UPLOAD_THIS_*.zip"))
        check(len(archive) == 1, "one diagnostic archive created")
        with zipfile.ZipFile(archive[0]) as zipped:
            names = zipped.namelist()
            check(zipped.read("mod_logs/CCC_Reflection.log").decode() == log_text, "whole reflection log retained")
            check("mod_logs/CCC_Mod_Status.previous.log" in names, "previous session retained")
            check("mod_logs/Logs/session_older/events.txt" in names, "nested log retained")
            check("mod_logs/oversized.log" not in names, "oversized log omitted")
            check("OMITTED_PER_FILE_LIMIT" in zipped.read("MANIFEST.csv").decode("utf-8-sig"), "size omission declared")
            check("mod_logs/linked.log" not in names, "linked external log skipped")
            filtered = zipped.read("UE4SS_Filtered.log").decode()
            check("EARLY_UE4SS_MATCH" in filtered and "LATE_UE4SS_MATCH" in filtered, "UE4SS scans early and late matches")
            all_content = b"".join(zipped.read(name) for name in names if not name.endswith("/"))
            check(b"SAVE_PRIVATE_SENTINEL" not in all_content, "saves excluded")
            check(b"OTHER_MOD_PRIVATE_SENTINEL" not in all_content, "other mod log excluded")
            check(b"EXTERNAL_PRIVATE_SENTINEL" not in all_content, "external symlink content excluded")
            check(all(name.startswith("mod_logs/") or name in {"REPORT.txt", "MANIFEST.csv", "UE4SS_Filtered.log"} for name in names), "archive restricted to diagnostic payload")
        (mod / "linked.log").unlink()
        oversized.unlink()
        checks.append(f"PASS {layout}: actual collection, complete 4,000-line log, previous/nested sessions, cap manifest, early/late UE4SS matches, save/other-mod/link exclusion")

        before_remove = (mods / "mods.txt").read_bytes()
        failed = run("UNINSTALL_Mod.ps1", expect=1, fail_write=True)
        check("TEST injected" in failed.stdout, "injected uninstall failure observed")
        check((mod / "Scripts/main.lua").read_text() == "-- new main\n", "uninstall rollback restores mod")
        check((mods / "mods.txt").read_bytes() == before_remove, "uninstall rollback restores exact config")
        run("UNINSTALL_Mod.ps1")
        check(not mod.exists(), "own mod removed")
        check((mods / "mods.txt").read_bytes() == b"OtherMod : 1\n", "uninstall preserves only other entry")
        check(not list(loader.glob("CCC_*_Staging_*")), "no staging folder left")
        unchanged_shared()
        checks.append(f"PASS {layout}: actual uninstall and injected uninstall rollback; UE4SS/settings/other mod/saves unchanged")

checks.append(f"PASS total smoke assertions: {passed}")
checks.append("SCOPE: PowerShell 7.4.7 on Linux; fake executable/DLL/payload, temporary game trees only. Test-only overrides stub process detection, force backups into the fixture, and inject optional mods.txt write failures. No Windows or game execution was tested.")
output = "\n".join(checks) + "\n"
(WORK / "installer_smoke_validation.txt").write_text(output)
print(output)
