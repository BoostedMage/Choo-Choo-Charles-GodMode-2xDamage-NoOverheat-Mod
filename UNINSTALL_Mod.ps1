#requires -Version 5.1
[CmdletBinding()]
param([string]$GamePath = '', [string]$LoaderPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CCC.Tools.ps1')
Write-Host 'CHOO-CHOO CHARLES GOD MODE - UNINSTALL' -ForegroundColor Cyan

$stage = $null
$backup = $null
$plan = $null
$modDest = $null
$oldMoved = $false
$listTouched = $false
$committed = $false
try {
    Assert-GameClosed
    $gameRoot = Get-CCCGameRoot $GamePath
    $loader = Get-LoaderRoot $gameRoot $LoaderPath
    if (-not $loader) { throw 'No existing UE4SS installation was found. No files were changed.' }
    $mods = Join-Path $loader 'Mods'
    $modDest = Join-Path $mods $script:CCCModName
    Assert-CCCPlainDirectory $mods
    Assert-CCCPlainDirectory $modDest -Recurse
    $plan = Get-CCCModListPlan (Join-Path $mods 'mods.txt') $false
    $hasMod = Test-Path -LiteralPath $modDest -PathType Container
    if (-not $hasMod -and -not $plan.WasPresent) {
        Write-Host 'The mod is already absent. No files were changed.' -ForegroundColor Green
        exit 0
    }
    $backup = New-LocalBackupRoot
    if ($plan.WasPresent) { [IO.File]::WriteAllBytes((Join-Path $backup 'mods.txt.before'), [byte[]]$plan.OriginalBytes) }
    if ($hasMod) {
        Copy-Item -LiteralPath $modDest -Destination (Join-Path $backup 'PreviousMod') -Recurse -ErrorAction Stop
        $stage = Join-Path $loader ('CCC_Uninstall_Staging_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
    }
    Assert-GameClosed
    if ($hasMod) {
        Move-Item -LiteralPath $modDest -Destination (Join-Path $stage 'PreviousMod') -ErrorAction Stop
        $oldMoved = $true
    }
    if ($plan.WasPresent) {
        $listTouched = $true
        Write-CCCModList $plan
    }
    $committed = $true
    Write-Host 'Removed ChooChooCharles_GodMode.' -ForegroundColor Green
    Write-Host 'Your UE4SS installation, its settings, other mods, and your saves remain available.'
    Write-Host ('Previous mod and mods.txt backup: ' + $backup)
} catch {
    $failure = $_.Exception.Message
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    if (-not $committed) {
        if ($listTouched -and $null -ne $plan) {
            try { Restore-CCCModList $plan } catch { $rollbackErrors.Add('mods.txt restore: ' + $_.Exception.Message) }
        }
        if ($oldMoved -and $stage) {
            try { Move-Item -LiteralPath (Join-Path $stage 'PreviousMod') -Destination $modDest -ErrorAction Stop } catch { $rollbackErrors.Add('Previous mod restore: ' + $_.Exception.Message) }
        }
    }
    Write-Host ('UNINSTALL ERROR: ' + $failure) -ForegroundColor Red
    if ($rollbackErrors.Count -gt 0) {
        foreach ($message in $rollbackErrors) { Write-Host ('ROLLBACK NEEDS ATTENTION: ' + $message) -ForegroundColor Red }
        Write-Host ('Recovery staging folder: ' + $stage)
        Write-Host ('Persistent backup: ' + $backup)
        $stage = $null
    } elseif ($listTouched -or $oldMoved) {
        Write-Host 'The previous mod and mods.txt state were restored.' -ForegroundColor Yellow
    }
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop } catch { Write-Warning ('Could not remove the inactive staging folder outside Mods: ' + $stage) }
    }
}
