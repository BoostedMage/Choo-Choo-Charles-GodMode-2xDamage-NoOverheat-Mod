# Shared helpers for Choo-Choo Charles God Mode v0.6.0.
# Windows PowerShell 5.1. This file never installs or replaces UE4SS.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CCCModName = 'ChooChooCharles_GodMode'

function Resolve-CCCGamePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $candidate = [IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $candidate = [IO.Path]::GetDirectoryName($candidate)
    }
    for ($depth = 0; $depth -lt 4; $depth++) {
        $exe = Join-Path $candidate 'Obscure\Binaries\Win64\Obscure-Win64-Shipping.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return $candidate }
        $parent = [IO.Directory]::GetParent($candidate)
        if ($null -eq $parent) { break }
        $candidate = $parent.FullName
    }
    return $null
}

function Get-CCCGameRoot([string]$GamePath = '') {
    if (-not [string]::IsNullOrWhiteSpace($GamePath)) {
        $resolved = Resolve-CCCGamePath $GamePath
        if ($resolved) { return $resolved }
        throw 'The supplied game path does not contain Obscure\Binaries\Win64\Obscure-Win64-Shipping.exe.'
    }
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    if (${env:ProgramFiles(x86)}) { $steamRoots.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if ($env:ProgramFiles) { $steamRoots.Add((Join-Path $env:ProgramFiles 'Steam')) }
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $reg = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($reg.PSObject.Properties.Name -contains $name) {
                    $value = [string]$reg.$name
                    if (-not [string]::IsNullOrWhiteSpace($value)) { $steamRoots.Add($value) }
                }
            }
        } catch { }
    }
    $libraries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($steam in @($steamRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $steam -PathType Container)) { continue }
        $libraries.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            try {
                foreach ($match in [regex]::Matches([IO.File]::ReadAllText($vdf), '(?im)^\s*"(?:path|\d+)"\s+"([^"]+)"\s*$')) {
                    $path = $match.Groups[1].Value.Replace('\\', '\')
                    if (Test-Path -LiteralPath $path -PathType Container) { $libraries.Add($path) }
                }
            } catch { }
        }
    }
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($library in @($libraries | Select-Object -Unique)) {
        $installName = 'Choo-Choo Charles'
        $manifest = Join-Path $library 'steamapps\appmanifest_1766740.acf'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            try {
                $match = [regex]::Match([IO.File]::ReadAllText($manifest), '"installdir"\s+"([^"]+)"')
                if ($match.Success) { $installName = $match.Groups[1].Value }
            } catch { }
        }
        $candidates.Add((Join-Path $library ('steamapps\common\' + $installName)))
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $resolved = Resolve-CCCGamePath $candidate
        if ($resolved) { return $resolved }
    }
    Write-Host 'Enter the Choo-Choo Charles game folder (Steam > Manage > Browse local files).' -ForegroundColor Yellow
    $answer = Read-Host 'Game folder path (blank cancels)'
    if ([string]::IsNullOrWhiteSpace($answer)) { throw 'Cancelled. No installation files changed.' }
    $resolved = Resolve-CCCGamePath $answer
    if (-not $resolved) { throw 'The selected path does not contain the expected game executable.' }
    return $resolved
}

function Get-LoaderRoot([string]$GameRoot, [string]$LoaderPath = '') {
    $exeDir = Join-Path $GameRoot 'Obscure\Binaries\Win64'
    $locations = @((Join-Path $exeDir 'ue4ss'), $exeDir)
    if (-not [string]::IsNullOrWhiteSpace($LoaderPath)) {
        $chosen = [IO.Path]::GetFullPath($LoaderPath.Trim().Trim('"')).TrimEnd([char[]]'\/')
        $allowed = @($locations | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd([char[]]'\/') -ieq $chosen })
        if ($allowed.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $chosen 'UE4SS.dll') -PathType Leaf)) {
            throw 'LoaderPath must be the existing Win64 or Win64\ue4ss folder containing UE4SS.dll.'
        }
        return $chosen
    }
    $found = @($locations | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'UE4SS.dll') -PathType Leaf })
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -eq 1) { return $found[0] }
    $withMod = @($found | Where-Object { Test-Path -LiteralPath (Join-Path $_ ('Mods\' + $script:CCCModName + '\Scripts\main.lua')) -PathType Leaf })
    if ($withMod.Count -eq 1) { return $withMod[0] }
    throw 'Two UE4SS.dll installations were found. Run this .ps1 with -LoaderPath pointing to the UE4SS folder used by your game (Win64 or Win64\ue4ss). No loader has been replaced.'
}

function Assert-GameClosed {
    $running = @(Get-Process -Name 'Obscure', 'Obscure-Win64-Shipping' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) { throw 'Exit Choo-Choo Charles completely, then run this installer or uninstaller again.' }
}

function Assert-CCCPlainDirectory([string]$Path, [switch]$Recurse) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $root = Get-Item -LiteralPath $Path -Force
    if (-not $root.PSIsContainer) { throw ('Expected a folder: ' + $Path) }
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('A linked folder or file needs manual handling: ' + $item.FullName)
        }
        if ($Recurse -and $item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) { $pending.Push($child) }
        }
    }
}

function New-LocalBackupRoot {
    $base = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Could not locate a folder for the local backup.' }
    $parent = Join-Path $base 'ChooChooCharles_ModBackups'
    $leaf = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $parent $leaf
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Save-GameBackup([string]$BackupRoot) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable; the local save backup could not be made.' }
    $savePath = Join-Path $env:LOCALAPPDATA 'Obscure\Saved\SaveGames'
    if (Test-Path -LiteralPath $savePath -PathType Container) {
        Assert-CCCPlainDirectory $savePath -Recurse
        Copy-Item -LiteralPath $savePath -Destination (Join-Path $BackupRoot 'SaveGames') -Recurse -ErrorAction Stop
        Write-Host 'A local copy of your saves has been backed up. Saves are never added to the diagnostic ZIP.' -ForegroundColor Green
    } else {
        Write-Host 'No existing SaveGames folder was found.'
    }
}

# Decode and re-encode only mods.txt; preserve its BOM, newline style, comments,
# blank lines, and every unrelated mod entry. No pipeline scalar concatenation.
function Get-CCCModListPlan([string]$Path, [bool]$Enable) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('mods.txt must be a regular file, not a directory or link: ' + $Path)
        }
    }
    [byte[]]$original = @()
    if ($exists) { $original = [IO.File]::ReadAllBytes($Path) }
    $offset = 0
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    if ($original.Length -ge 4 -and $original[0] -eq 255 -and $original[1] -eq 254 -and $original[2] -eq 0 -and $original[3] -eq 0) {
        $encoding = [Text.UTF32Encoding]::new($false, $true, $true); $offset = 4
    } elseif ($original.Length -ge 4 -and $original[0] -eq 0 -and $original[1] -eq 0 -and $original[2] -eq 254 -and $original[3] -eq 255) {
        $encoding = [Text.UTF32Encoding]::new($true, $true, $true); $offset = 4
    } elseif ($original.Length -ge 3 -and $original[0] -eq 239 -and $original[1] -eq 187 -and $original[2] -eq 191) {
        $encoding = [Text.UTF8Encoding]::new($true, $true); $offset = 3
    } elseif ($original.Length -ge 2 -and $original[0] -eq 255 -and $original[1] -eq 254) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $offset = 2
    } elseif ($original.Length -ge 2 -and $original[0] -eq 254 -and $original[1] -eq 255) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $offset = 2
    }
    $text = $encoding.GetString($original, $offset, $original.Length - $offset)
    $newline = "`r`n"
    $firstBreak = [regex]::Match($text, '\r\n|\n|\r')
    if ($firstBreak.Success) { $newline = $firstBreak.Value }
    $pattern = '(?<![^\r\n])[ \t]*ChooChooCharles_GodMode[ \t]*:[^\r\n]*(?:\r\n|\n|\r|$)'
    $clean = [regex]::Replace($text, $pattern, '', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($Enable) {
        if ($clean.Length -gt 0 -and -not ($clean.EndsWith("`n") -or $clean.EndsWith("`r"))) { $clean += $newline }
        $clean += $script:CCCModName + ' : 1' + $newline
    }
    [byte[]]$preamble = $encoding.GetPreamble()
    [byte[]]$body = $encoding.GetBytes($clean)
    [byte[]]$next = New-Object byte[] ($preamble.Length + $body.Length)
    [Buffer]::BlockCopy($preamble, 0, $next, 0, $preamble.Length)
    [Buffer]::BlockCopy($body, 0, $next, $preamble.Length, $body.Length)
    return [pscustomobject]@{ Path = $Path; WasPresent = $exists; OriginalBytes = $original; Bytes = $next; Text = $clean }
}

function Write-CCCModList($Plan) {
    [IO.File]::WriteAllBytes($Plan.Path, [byte[]]$Plan.Bytes)
}

function Restore-CCCModList($Plan) {
    if ($Plan.WasPresent) {
        [IO.File]::WriteAllBytes($Plan.Path, [byte[]]$Plan.OriginalBytes)
    } elseif (Test-Path -LiteralPath $Plan.Path -PathType Leaf) {
        Remove-Item -LiteralPath $Plan.Path -Force
    }
}

# Copies exactly the length seen when a log is opened. FileShare.ReadWrite allows
# collection during gameplay. An append after opening goes into the next report.
function Copy-CCCLogSnapshot([string]$Source, [string]$Destination, [long]$MaximumBytes) {
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.FileStream]::new($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        [long]$length = $inputStream.Length
        if ($length -gt $MaximumBytes) {
            return [pscustomobject]@{ Status = 'OMITTED_SIZE_LIMIT'; OriginalBytes = $length; CopiedBytes = 0 }
        }
        $parent = [IO.Path]::GetDirectoryName($Destination)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $outputStream = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        [byte[]]$buffer = New-Object byte[] 65536
        [long]$copied = 0
        while ($copied -lt $length) {
            $count = [int][Math]::Min([long]$buffer.Length, $length - $copied)
            $read = $inputStream.Read($buffer, 0, $count)
            if ($read -eq 0) { break }
            $outputStream.Write($buffer, 0, $read)
            $copied += $read
        }
        $state = 'COMPLETE'
        if ($copied -ne $length) { $state = 'INCOMPLETE_FILE_CHANGED_DURING_READ' }
        return [pscustomobject]@{ Status = $state; OriginalBytes = $length; CopiedBytes = $copied }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
    }
}

function Write-CCCText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, ([Text.UTF8Encoding]::new($false)))
}
