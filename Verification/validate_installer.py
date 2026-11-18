"""Static and text-transformation checks; this is not a PowerShell runtime test."""
from pathlib import Path
import codecs
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent if HERE.name == "Verification" else HERE / "installer"
checks = []


def balanced_powershell(path: Path):
    text = path.read_text(encoding="ascii")
    stack = []
    i = 0
    quote = None
    while i < len(text):
        c = text[i]
        if quote:
            if quote == '"' and c == "`":
                i += 2
                continue
            if c == quote:
                if quote == "'" and i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
        elif c == "#":
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        elif c in "([{":
            stack.append((c, i))
        elif c in ")]}":
            assert stack, f"{path.name}: stray {c}"
            previous, _ = stack.pop()
            assert previous == dict(zip(")]}", "([{"))[c], f"{path.name}: unbalanced {c}"
        i += 1
    assert not quote, f"{path.name}: unterminated string"
    assert not stack, f"{path.name}: unclosed delimiters"
    checks.append(f"PASS balanced strings/delimiters and ASCII source: {path.name}")


for path in sorted(ROOT.glob("*.ps1")):
    balanced_powershell(path)

helpers = (ROOT / "CCC.Tools.ps1").read_text()
installer = (ROOT / "INSTALL_God_Mode.ps1").read_text()
uninstaller = (ROOT / "UNINSTALL_Mod.ps1").read_text()
collector = (ROOT / "COLLECT_Mod_Test.ps1").read_text()
all_scripts = helpers + installer + uninstaller + collector

# Exercise the exact removal regex found in the PowerShell helper. Text assembly
# is the same scalar string operation; this specifically covers the old single-
# preserved-line bug, accidental comment removal, and newline/BOM preservation.
pattern = re.search(r"\$pattern = '([^']+)'", helpers).group(1)
remove_entry = re.compile(pattern, re.IGNORECASE)
MOD_LINE = "ChooChooCharles_GodMode : 1"


def plan_text(text, enable):
    first = re.search(r"\r\n|\n|\r", text)
    newline = first.group() if first else "\r\n"
    cleaned = remove_entry.sub("", text)
    if enable:
        if cleaned and not cleaned.endswith(("\r", "\n")):
            cleaned += newline
        cleaned += MOD_LINE + newline
    return cleaned


fixtures = [
    ("", "", "\r\n"),
    ("OtherMod : 1", "OtherMod : 1", "\r\n"),
    ("OtherMod : 1\r\n", "OtherMod : 1\r\n", "\r\n"),
    ("OtherMod : 1\n", "OtherMod : 1\n", "\n"),
    ("OtherMod : 1\r", "OtherMod : 1\r", "\r"),
    ("ChooChooCharles_GodMode : 0", "", "\r\n"),
    ("ChooChooCharles_GodMode : 0\nOtherMod : 1\n", "OtherMod : 1\n", "\n"),
    ("OtherMod : 1\rChooChooCharles_GodMode : 0\r", "OtherMod : 1\r", "\r"),
    ("OtherMod : 1\r\nChooChooCharles_GodMode : 0\r\n\r\n", "OtherMod : 1\r\n\r\n", "\r\n"),
    ("  choochoocharles_godmode\t: 1 ; old\nOtherMod : 1\nChooChooCharles_GodMode:0", "OtherMod : 1\n", "\n"),
    ("; ChooChooCharles_GodMode : 0\nOtherMod : 1\n", "; ChooChooCharles_GodMode : 0\nOtherMod : 1\n", "\n"),
    ("ChooChooCharles_GodMode_Extra : 1\n# keep comment\n", "ChooChooCharles_GodMode_Extra : 1\n# keep comment\n", "\n"),
    ("OtherMod : 1 # Straße 日本語\n\nChooChooCharles_GodMode:1\n", "OtherMod : 1 # Straße 日本語\n\n", "\n"),
]
for original, retained, newline in fixtures:
    assert plan_text(original, False) == retained
    prefix = retained if not retained or retained.endswith(("\r", "\n")) else retained + newline
    assert plan_text(original, True) == prefix + MOD_LINE + newline
    assert plan_text(plan_text(original, True), True) == plan_text(original, True)
checks.append(f"PASS exact mods.txt entry regex and text assembly: {len(fixtures)} fixtures, install/uninstall/idempotence")

encodings = [
    ("utf-8", b""), ("utf-8", codecs.BOM_UTF8),
    ("utf-16-le", codecs.BOM_UTF16_LE), ("utf-16-be", codecs.BOM_UTF16_BE),
    ("utf-32-le", codecs.BOM_UTF32_LE), ("utf-32-be", codecs.BOM_UTF32_BE),
]
for encoding, preamble in encodings:
    text = "; keep 日本語\r\nOtherMod : 1\r\nChooChooCharles_GodMode : 0\r\n"
    source = preamble + text.encode(encoding)
    decoded = source[len(preamble):].decode(encoding, errors="strict")
    output = preamble + plan_text(decoded, False).encode(encoding)
    assert output == preamble + "; keep 日本語\r\nOtherMod : 1\r\n".encode(encoding)
checks.append("PASS encoding fixtures: UTF-8 with/without BOM, UTF-16 LE/BE, UTF-32 LE/BE")

assert not re.search(r"\b(?:Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|Expand-Archive)\b", all_scripts, re.I)
assert "CCC_Install_Staging_" in installer and "CCC_Uninstall_Staging_" in uninstaller
assert "Join-Path $loader ('CCC_Install_Staging_" in installer
assert "Join-Path $loader ('CCC_Uninstall_Staging_" in uninstaller
assert "Restore-CCCModList $plan" in installer and "Restore-CCCModList $plan" in uninstaller
assert "Get-CCCModListPlan $listPath $true" in installer
assert "Get-CCCModListPlan (Join-Path $mods 'mods.txt') $false" in uninstaller
assert "Copy-Item -LiteralPath $source -Destination $newMod" in installer
assert "Move-Item -LiteralPath $newMod -Destination $modDest" in installer
assert not re.search(r"Remove-Item\s+-LiteralPath\s+\$(?:loader|mods|gameRoot)\b", installer + uninstaller)
assert not re.search(r"\$lines\s*\|.*\+\s*@", helpers + installer + uninstaller)
checks.append("PASS installer scope/rollback static checks: no downloader, stage outside Mods, no broad root removal, no pipeline-array concatenation")

assert "[long]$perModFileLimit = 32MB" in collector
assert "[long]$totalModLimit = 96MB" in collector
assert "[int]$modFileCountLimit = 512" in collector
assert "[long]$ue4ssSourceLimit = 128MB" in collector
assert "[long]$ue4ssOutputLimit = 8MB" in collector
assert "-Tail" not in collector and "-Last" not in collector
assert "Save-GameBackup" not in collector
assert "$item.Extension -ieq '.log' -or $item.Extension -ieq '.txt'" in collector
assert "[IO.FileAttributes]::ReparsePoint" in collector
assert "[IO.Compression.ZipFile]::CreateFromDirectory($payload, $output" in collector
assert "$snapshot = Join-Path $temp 'UE4SS_SourceSnapshot.tmp'" in collector
assert "$payload = Join-Path $temp 'Report'" in collector
assert "MANIFEST.csv" in collector and "OMITTED_PER_FILE_LIMIT" in collector
assert "INCOMPLETE_FILE_CHANGED_DURING_READ" in helpers
assert "[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete" in helpers
assert "CCC_Mod_Status|CCC_Reflection|CCC_Events" in collector
checks.append("PASS collector static bounds/isolation checks: complete bounded snapshots, explicit omissions, mod-only log/text traversal, raw UE4SS source outside archive")

for path in sorted(ROOT.glob("*.cmd")):
    data = path.read_bytes()
    assert b"\r\n" in data and data.replace(b"\r\n", b"").find(b"\n") == -1
    text = data.decode("ascii")
    assert f'-File "%~dp0{path.stem}.ps1" %*' in text
    assert 'set "rc=%errorlevel%"' in text and "exit /b %rc%" in text
    assert (ROOT / (path.stem + ".ps1")).read_text().startswith("#requires -Version 5.1\n")
checks.append("PASS CMD launchers: CRLF, matching scripts, argument forwarding, exit-code propagation")

print("\n".join(checks))
print("SCOPE: Static validation and regex/encoding fixtures only. Separate PowerShell runtime and smoke results are in the accompanying validation files; no Windows/game execution was tested.")
