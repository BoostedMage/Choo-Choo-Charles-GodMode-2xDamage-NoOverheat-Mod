#requires -Version 5.1
[CmdletBinding()]
param([string]$GamePath = '', [string]$LoaderPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CCC.Tools.ps1')
Write-Host 'CHOO-CHOO CHARLES GOD MODE v0.6.0 - INSTALL / UPDATE' -ForegroundColor Cyan

$stage = $null
$backup = $null
$plan = $null
$modDest = $null
$oldMoved = $false
$newInstalled = $false
$listTouched = $false
$committed = $false
try {
    Assert-GameClosed
    $gameRoot = Get-CCCGameRoot $GamePath
    $loader = Get-LoaderRoot $gameRoot $LoaderPath
    if (-not $loader) {
        throw 'UE4SS.dll was not found beside the shipping executable or in its ue4ss subfolder. Install UE4SS first, verify that the game launches, then run this installer again. This package does not download or replace UE4SS.'
    }
    $source = Join-Path $PSScriptRoot ('Mod\' + $script:CCCModName)
    $required = @('Scripts\main.lua', 'Scripts\core.lua', 'Scripts\hud.lua', 'Scripts\diagnostics.lua',
        'Scripts\noheat.lua', 'Scripts\playerguard.lua', 'Scripts\logger.lua', 'Scripts\native\ccc_guard.dll')
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) {
            throw ('The update is incomplete: ' + $relative + '. Extract the entire ZIP, including the native subfolder, then run INSTALL_God_Mode.cmd.')
        }
    }
    Assert-CCCPlainDirectory $source -Recurse
    $mods = Join-Path $loader 'Mods'
    $modDest = Join-Path $mods $script:CCCModName
    Assert-CCCPlainDirectory $mods
    Assert-CCCPlainDirectory $modDest -Recurse
    $listPath = Join-Path $mods 'mods.txt'
    $plan = Get-CCCModListPlan $listPath $true

    # Both the persistent backup and transient staging directory are outside Mods.
    # A second copy inside Mods could be auto-loaded by UE4SS.
    $backup = New-LocalBackupRoot
    Save-GameBackup $backup
    if ($plan.WasPresent) { [IO.File]::WriteAllBytes((Join-Path $backup 'mods.txt.before'), [byte[]]$plan.OriginalBytes) }
    if (Test-Path -LiteralPath $modDest -PathType Container) {
        Copy-Item -LiteralPath $modDest -Destination (Join-Path $backup 'PreviousMod') -Recurse -ErrorAction Stop
    }
    $stage = Join-Path $loader ('CCC_Install_Staging_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $newMod = Join-Path $stage 'NewMod'
    Copy-Item -LiteralPath $source -Destination $newMod -Recurse -ErrorAction Stop
    Write-CCCText (Join-Path $newMod 'enabled.txt') ''
    foreach ($relative in $required) {
        $stagedFile = Join-Path $newMod $relative
        if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf)) {
            throw ('The staged mod is incomplete: ' + $relative + '. No installed mod has been changed.')
        }
        if ((Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath (Join-Path $source $relative) -Algorithm SHA256).Hash) {
            throw ('Staging verification failed: ' + $relative + '. No installed mod has been changed.')
        }
    }
    Assert-GameClosed
    if (-not (Test-Path -LiteralPath $mods -PathType Container)) { New-Item -ItemType Directory -Path $mods | Out-Null }
    if (Test-Path -LiteralPath $modDest -PathType Container) {
        Move-Item -LiteralPath $modDest -Destination (Join-Path $stage 'PreviousMod') -ErrorAction Stop
        $oldMoved = $true
    }
    Move-Item -LiteralPath $newMod -Destination $modDest -ErrorAction Stop
    $newInstalled = $true
    $listTouched = $true
    Write-CCCModList $plan
    $committed = $true

    $receipt = New-Object 'System.Collections.Generic.List[string]'
    $receipt.Add('Choo-Choo Charles God Mode v0.6.0 installed.')
    $receipt.Add('Installed UTC: ' + [DateTime]::UtcNow.ToString('o'))
    $receipt.Add('Mod folder: ' + $modDest)
    $receipt.Add('Existing UE4SS reused: ' + $loader)
    $receipt.Add('Local backup: ' + $backup)
    $receipt.Add('UE4SS DLLs/settings and other mod folders were not changed.')
    $receipt.Add('F6 God Mode | F7 Train God Mode | F8 Double Damage | F9 Snapshot | F10 No Overheat | F11 Hide/Show HUD')
    try { Write-CCCText (Join-Path $PSScriptRoot 'INSTALL_RESULT.txt') ($receipt -join [Environment]::NewLine) } catch { Write-Warning ('The installation succeeded, but its receipt could not be written: ' + $_.Exception.Message) }
    Write-Host ''
    Write-Host 'Installed. Your existing UE4SS was reused.' -ForegroundColor Green
    Write-Host ('Mod:    ' + $modDest)
    Write-Host ('Backup: ' + $backup)
    Write-Host 'F6 God Mode | F7 Train God Mode | F8 Double Damage | F10 No Overheat'
    Write-Host 'F9 Snapshot | F11 Hide/Show HUD. Use the plain function keys; no Ctrl modifier.'
    Write-Host 'ON (NOT READY) means required patches are missing or a damage gap was detected.' -ForegroundColor Yellow
    Write-Host 'If stutter remains, press F9 once while safely away from combat. Compact diagnostics run automatically.'
} catch {
    $failure = $_.Exception.Message
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    if (-not $committed) {
        if ($listTouched -and $null -ne $plan) {
            try { Restore-CCCModList $plan } catch { $rollbackErrors.Add('mods.txt restore: ' + $_.Exception.Message) }
        }
        if ($newInstalled -and $modDest) {
            try { Remove-Item -LiteralPath $modDest -Recurse -Force -ErrorAction Stop } catch { $rollbackErrors.Add('New mod removal: ' + $_.Exception.Message) }
        }
        if ($oldMoved -and $stage) {
            try { Move-Item -LiteralPath (Join-Path $stage 'PreviousMod') -Destination $modDest -ErrorAction Stop } catch { $rollbackErrors.Add('Previous mod restore: ' + $_.Exception.Message) }
        }
    }
    Write-Host ('INSTALL ERROR: ' + $failure) -ForegroundColor Red
    if ($rollbackErrors.Count -gt 0) {
        foreach ($message in $rollbackErrors) { Write-Host ('ROLLBACK NEEDS ATTENTION: ' + $message) -ForegroundColor Red }
        Write-Host ('Keep this staging folder: ' + $stage)
        Write-Host ('Your persistent backup is: ' + $backup)
        $stage = $null # Preserve recovery files if automatic rollback was incomplete.
    } elseif ($listTouched -or $oldMoved -or $newInstalled) {
        Write-Host 'The previous mod and mods.txt state were restored.' -ForegroundColor Yellow
    }
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop } catch { Write-Warning ('Could not remove the inactive staging folder outside Mods: ' + $stage) }
    }
}
