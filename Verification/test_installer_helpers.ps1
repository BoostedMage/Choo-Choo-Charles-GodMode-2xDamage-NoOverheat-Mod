[CmdletBinding()]
param([string]$SourceRoot = (Join-Path $PSScriptRoot 'installer'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw ($Label + ': expected [' + $Expected + '], got [' + $Actual + ']') }
    $script:passed++
}

function Assert-Bytes([byte[]]$Actual, [byte[]]$Expected, [string]$Label) {
    Assert-Equal ([Convert]::ToBase64String($Actual)) ([Convert]::ToBase64String($Expected)) $Label
}

$scripts = @(Get-ChildItem -LiteralPath $SourceRoot -Filter '*.ps1' -File)
foreach ($file in $scripts) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        foreach ($error in $errors) { Write-Output ($file.Name + ': ' + $error.ToString()) }
        throw ('PowerShell parser errors in ' + $file.Name)
    }
    Write-Output ('PASS PowerShell parser: ' + $file.Name)
}

. (Join-Path $SourceRoot 'CCC.Tools.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('CCC_PwshValidation_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $fixturePath = Join-Path $temp 'mods.txt'
    $fixtures = @(
        @{ Original = ''; Retained = ''; Newline = "`r`n" },
        @{ Original = 'OtherMod : 1'; Retained = 'OtherMod : 1'; Newline = "`r`n" },
        @{ Original = "OtherMod : 1`r`n"; Retained = "OtherMod : 1`r`n"; Newline = "`r`n" },
        @{ Original = "OtherMod : 1`n"; Retained = "OtherMod : 1`n"; Newline = "`n" },
        @{ Original = "OtherMod : 1`r"; Retained = "OtherMod : 1`r"; Newline = "`r" },
        @{ Original = 'ChooChooCharles_GodMode : 0'; Retained = ''; Newline = "`r`n" },
        @{ Original = "ChooChooCharles_GodMode : 0`nOtherMod : 1`n"; Retained = "OtherMod : 1`n"; Newline = "`n" },
        @{ Original = "OtherMod : 1`rChooChooCharles_GodMode : 0`r"; Retained = "OtherMod : 1`r"; Newline = "`r" },
        @{ Original = "OtherMod : 1`r`nChooChooCharles_GodMode : 0`r`n`r`n"; Retained = "OtherMod : 1`r`n`r`n"; Newline = "`r`n" },
        @{ Original = "  choochoocharles_godmode`t: 1 ; old`nOtherMod : 1`nChooChooCharles_GodMode:0"; Retained = "OtherMod : 1`n"; Newline = "`n" },
        @{ Original = "; ChooChooCharles_GodMode : 0`nOtherMod : 1`n"; Retained = "; ChooChooCharles_GodMode : 0`nOtherMod : 1`n"; Newline = "`n" },
        @{ Original = "ChooChooCharles_GodMode_Extra : 1`n# keep comment`n"; Retained = "ChooChooCharles_GodMode_Extra : 1`n# keep comment`n"; Newline = "`n" }
    )
    $case = 0
    foreach ($fixture in $fixtures) {
        $case++
        Write-CCCText $fixturePath $fixture.Original
        [byte[]]$before = [IO.File]::ReadAllBytes($fixturePath)
        $installPlan = Get-CCCModListPlan $fixturePath $true
        $prefix = $fixture.Retained
        if ($prefix.Length -gt 0 -and -not ($prefix.EndsWith("`n") -or $prefix.EndsWith("`r"))) { $prefix += $fixture.Newline }
        $expected = $prefix + 'ChooChooCharles_GodMode : 1' + $fixture.Newline
        Assert-Equal $installPlan.Text $expected ('install text fixture ' + $case)
        Assert-Equal $installPlan.WasPresent $true ('existing file fixture ' + $case)
        Assert-Bytes $installPlan.OriginalBytes $before ('original bytes fixture ' + $case)
        Write-CCCModList $installPlan
        Assert-Equal ([IO.File]::ReadAllText($fixturePath)) $expected ('write fixture ' + $case)
        $secondPlan = Get-CCCModListPlan $fixturePath $true
        Assert-Bytes $secondPlan.Bytes $installPlan.Bytes ('idempotent install fixture ' + $case)
        Restore-CCCModList $installPlan
        Assert-Bytes ([IO.File]::ReadAllBytes($fixturePath)) $before ('rollback fixture ' + $case)
        $uninstallPlan = Get-CCCModListPlan $fixturePath $false
        Assert-Equal $uninstallPlan.Text $fixture.Retained ('uninstall fixture ' + $case)
    }
    Write-Output ('PASS actual helper: ' + $fixtures.Count + ' install/write/idempotence/rollback/uninstall text fixtures')

    $encodings = @(
        [Text.UTF8Encoding]::new($false, $true),
        [Text.UTF8Encoding]::new($true, $true),
        [Text.UnicodeEncoding]::new($false, $true, $true),
        [Text.UnicodeEncoding]::new($true, $true, $true),
        [Text.UTF32Encoding]::new($false, $true, $true),
        [Text.UTF32Encoding]::new($true, $true, $true)
    )
    $special = '; keep ' + [char]0x65E5 + [char]0x672C + [char]0x8A9E + "`r`nOtherMod : 1`r`n"
    foreach ($encoding in $encodings) {
        $original = $special + "ChooChooCharles_GodMode : 0`r`n"
        [IO.File]::WriteAllText($fixturePath, $original, $encoding)
        [byte[]]$before = [IO.File]::ReadAllBytes($fixturePath)
        $plan = Get-CCCModListPlan $fixturePath $false
        Assert-Equal $plan.Text $special ('decoded ' + $encoding.EncodingName)
        Write-CCCModList $plan
        $expectedPath = Join-Path $temp 'encoding_expected.txt'
        [IO.File]::WriteAllText($expectedPath, $special, $encoding)
        Assert-Bytes ([IO.File]::ReadAllBytes($fixturePath)) ([IO.File]::ReadAllBytes($expectedPath)) ('preserved encoding ' + $encoding.EncodingName)
        Restore-CCCModList $plan
        Assert-Bytes ([IO.File]::ReadAllBytes($fixturePath)) $before ('encoding rollback ' + $encoding.EncodingName)
    }
    Write-Output 'PASS actual helper: six BOM/encoding variants with Unicode comments and exact-byte rollback'

    Remove-Item -LiteralPath $fixturePath -Force
    $missing = Get-CCCModListPlan $fixturePath $true
    Assert-Equal $missing.WasPresent $false 'missing config'
    Write-CCCModList $missing
    Assert-Equal (Test-Path -LiteralPath $fixturePath -PathType Leaf) $true 'created config'
    Restore-CCCModList $missing
    Assert-Equal (Test-Path -LiteralPath $fixturePath) $false 'removed config on rollback'
    [IO.File]::WriteAllBytes($fixturePath, [byte[]]@(255, 254, 255))
    $rejected = $false
    try { $null = Get-CCCModListPlan $fixturePath $true } catch { $rejected = $true }
    Assert-Equal $rejected $true 'invalid encoding rejected'
    Write-Output 'PASS actual helper: missing file creation/rollback and invalid encoding refusal'

    $source = Join-Path $temp 'runtime.log'
    $destination = Join-Path $temp 'snapshot.log'
    $contents = 'runtime log bytes' * 1000
    Write-CCCText $source $contents
    $copied = Copy-CCCLogSnapshot $source $destination 65536
    Assert-Equal $copied.Status 'COMPLETE' 'shared snapshot status'
    Assert-Equal $copied.CopiedBytes ([IO.FileInfo]::new($source).Length) 'shared snapshot length'
    Assert-Bytes ([IO.File]::ReadAllBytes($destination)) ([IO.File]::ReadAllBytes($source)) 'shared snapshot bytes'
    $omittedPath = Join-Path $temp 'omitted.log'
    $omitted = Copy-CCCLogSnapshot $source $omittedPath 1
    Assert-Equal $omitted.Status 'OMITTED_SIZE_LIMIT' 'snapshot cap status'
    Assert-Equal (Test-Path -LiteralPath $omittedPath) $false 'omitted file not created'
    Write-Output 'PASS actual helper: shared-read whole-file snapshot and explicit size-cap omission'
    Write-Output ('PASS total actual PowerShell assertions: ' + $script:passed)
    Write-Output ('Runtime: PowerShell ' + $PSVersionTable.PSVersion + '; ' + [Runtime.InteropServices.RuntimeInformation]::OSDescription)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
