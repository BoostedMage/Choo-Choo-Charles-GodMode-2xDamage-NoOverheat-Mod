#requires -Version 5.1
[CmdletBinding()]
param([string]$GamePath = '', [string]$LoaderPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CCC.Tools.ps1')
Write-Host 'CHOO-CHOO CHARLES GOD MODE - DIAGNOSTIC PACKAGER' -ForegroundColor Cyan

# Whole mod log snapshots are preferred. Every omission or incomplete read is
# declared in MANIFEST.csv; no last-N-line trimming of mod logs is performed.
[long]$perModFileLimit = 32MB
[long]$totalModLimit = 96MB
[int]$modFileCountLimit = 512
[long]$ue4ssSourceLimit = 128MB
[long]$ue4ssOutputLimit = 8MB
$temp = $null

function Get-CCCModLogFiles([string]$ModRoot, $Notes) {
    $found = New-Object 'System.Collections.Generic.List[object]'
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    $pending.Push([pscustomobject]@{ Path = $ModRoot; Depth = 0 })
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try { $children = @(Get-ChildItem -LiteralPath $directory.Path -Force -ErrorAction Stop) }
        catch { $Notes.Add('Could not inspect a mod log directory: ' + $_.Exception.Message); continue }
        foreach ($item in $children) {
            $relative = $item.FullName.Substring($ModRoot.TrimEnd([char[]]'\/').Length + 1)
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $Notes.Add('Skipped linked path inside the mod: ' + $relative)
                continue
            }
            if ($item.PSIsContainer) {
                if ($directory.Depth -ge 8) { $Notes.Add('Skipped directory beyond depth limit: ' + $relative) }
                else { $pending.Push([pscustomobject]@{ Path = $item.FullName; Depth = $directory.Depth + 1 }) }
            } elseif ($item.Extension -ieq '.log' -or $item.Extension -ieq '.txt') {
                $priority = 2
                if ($relative -match '^(?:CCC_Mod_Status|CCC_Reflection|CCC_Events)\.log$') { $priority = 0 }
                elseif ($relative -match '^(?:CCC_Mod_Status|CCC_Reflection|CCC_Events)\.previous\.log$') { $priority = 1 }
                $found.Add([pscustomobject]@{ File = $item; Relative = $relative; Priority = $priority })
            }
        }
    }
    return $found.ToArray()
}

function Add-CCCFilteredLine($Writer, $State, [long]$Number, [string]$Line, [long]$Limit) {
    if ($Number -le $State.LastWritten) { return }
    $value = '[' + $Number + '] ' + $Line + [Environment]::NewLine
    [long]$bytes = [Text.Encoding]::UTF8.GetByteCount($value)
    if ($State.Bytes + $bytes -le $Limit) {
        $Writer.Write($value)
        $State.Bytes += $bytes
        $State.Included++
    } else { $State.Omitted++ }
    $State.LastWritten = $Number
}

function Export-CCCUE4SSLines([string]$SnapshotPath, [string]$OutputPath, [long]$Limit) {
    $reader = $null
    $writer = $null
    $state = [pscustomobject]@{ Bytes = [long]0; Included = [long]0; Omitted = [long]0; LastWritten = [long]0; Scanned = [long]0 }
    try {
        $reader = [IO.StreamReader]::new($SnapshotPath, [Text.Encoding]::UTF8, $true)
        $writer = [IO.StreamWriter]::new($OutputPath, $false, ([Text.UTF8Encoding]::new($false)))
        $previous = New-Object 'System.Collections.Generic.Queue[object]'
        $after = 0
        $pattern = '(?i)CCC[-_ ](?:GODMOD|MOD|HUD)|ChooChooCharles_GodMode|\b(?:error|exception|failed|fatal)\b|Unreal Engine|UE4SS.{0,40}(?:version|v[0-9])'
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $state.Scanned++
            $match = $line -match $pattern
            if ($match) {
                foreach ($old in $previous.ToArray()) { Add-CCCFilteredLine $writer $state $old.Number $old.Line $Limit }
                $after = 3
            }
            if ($state.Scanned -le 100 -or $match -or $after -gt 0) {
                Add-CCCFilteredLine $writer $state $state.Scanned $line $Limit
            }
            if (-not $match -and $after -gt 0) { $after-- }
            $previous.Enqueue([pscustomobject]@{ Number = $state.Scanned; Line = $line })
            while ($previous.Count -gt 2) { $null = $previous.Dequeue() }
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
    }
    return $state
}

try {
    $gameRoot = Get-CCCGameRoot $GamePath
    $loader = Get-LoaderRoot $gameRoot $LoaderPath
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('CCC_ModDiag_' + [guid]::NewGuid().ToString('N'))
    $payload = Join-Path $temp 'Report'
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    $report = New-Object 'System.Collections.Generic.List[string]'
    $manifest = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[string]'
    $report.Add('Choo-Choo Charles God Mode v0.6.0 - Diagnostic Report')
    $report.Add('Collected UTC: ' + [DateTime]::UtcNow.ToString('o'))
    $report.Add('Report format: complete mod log snapshots with explicit limits and omissions.')
    $report.Add('Limits: 32 MiB per mod file, 96 MiB total mod files, 512 files; 128 MiB UE4SS source, 8 MiB selected UE4SS output.')
    $report.Add('Only .log and .txt files inside ChooChooCharles_GodMode are copied, plus selected UE4SS log lines and generated metadata.')
    $report.Add('SaveGames, DLLs, game assets, other mod folders, and UE4SS configuration files are not included.')
    $report.Add('Current session log headers and rotated .previous.log files are retained when present.')
    $report.Add('A log appended after its copy began may have newer lines in the next report. An incomplete read is flagged in MANIFEST.csv.')
    $report.Add('UE4SS found: ' + [string](-not [string]::IsNullOrWhiteSpace($loader)))
    $exe = Join-Path $gameRoot 'Obscure\Binaries\Win64\Obscure-Win64-Shipping.exe'
    try { $report.Add('Game binary SHA256: ' + (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash) }
    catch { $notes.Add('Could not hash the game executable: ' + $_.Exception.Message) }

    if ($loader) {
        $modRoot = Join-Path $loader ('Mods\' + $script:CCCModName)
        $main = Join-Path $modRoot 'Scripts\main.lua'
        $hasMod = Test-Path -LiteralPath $main -PathType Leaf
        $report.Add('Mod main.lua present: ' + $hasMod)
        if ($hasMod) {
            try { $report.Add('Installed main.lua SHA256: ' + (Get-FileHash -LiteralPath $main -Algorithm SHA256).Hash) }
            catch { $notes.Add('Could not hash installed main.lua: ' + $_.Exception.Message) }
        }
        $native = Join-Path $modRoot 'Scripts\native\ccc_guard.dll'
        $report.Add('Native player guard present: ' + [string](Test-Path -LiteralPath $native -PathType Leaf))
        if (Test-Path -LiteralPath $native -PathType Leaf) {
            try { $report.Add('Native player guard SHA256: ' + (Get-FileHash -LiteralPath $native -Algorithm SHA256).Hash) }
            catch { $notes.Add('Could not hash native player guard: ' + $_.Exception.Message) }
        }
        $report.Add('Mod enabled.txt present: ' + [string](Test-Path -LiteralPath (Join-Path $modRoot 'enabled.txt') -PathType Leaf))
        $modList = Join-Path $loader 'Mods\mods.txt'
        if (Test-Path -LiteralPath $modList -PathType Leaf) {
            try {
                $enabled = [regex]::IsMatch([IO.File]::ReadAllText($modList), '(?im)^[ \t]*ChooChooCharles_GodMode[ \t]*:[ \t]*1(?:[ \t]*(?:;|#|//)[^\r\n]*)?[ \t]*\r?$')
                $report.Add('Mod enabled in mods.txt: ' + $enabled)
            } catch { $notes.Add('Could not inspect this mod entry in mods.txt: ' + $_.Exception.Message) }
        } else { $report.Add('mods.txt present: False') }

        [long]$totalCopied = 0
        [int]$copiedCount = 0
        if (Test-Path -LiteralPath $modRoot -PathType Container) {
            $plainModRoot = $true
            try { Assert-CCCPlainDirectory $modRoot }
            catch { $plainModRoot = $false; $notes.Add('Skipped mod log collection: ' + $_.Exception.Message) }
            $candidates = @()
            if ($plainModRoot) { $candidates = @(Get-CCCModLogFiles $modRoot $notes | Sort-Object -Property Priority, @{ Expression = { $_.File.LastWriteTimeUtc }; Descending = $true }, Relative) }
            foreach ($candidate in $candidates) {
                $file = $candidate.File
                $relative = $candidate.Relative
                $record = [pscustomobject]@{ File = ('mod_logs/' + $relative.Replace('\', '/')); Status = ''; SourceBytes = [long]$file.Length; CollectedBytes = [long]0; LastWriteUtc = $file.LastWriteTimeUtc.ToString('o'); Details = '' }
                if ($copiedCount -ge $modFileCountLimit) {
                    $record.Status = 'OMITTED_FILE_COUNT_LIMIT'
                } elseif ($file.Length -gt $perModFileLimit) {
                    $record.Status = 'OMITTED_PER_FILE_LIMIT'
                } elseif ($file.Length -gt $totalModLimit - $totalCopied) {
                    $record.Status = 'OMITTED_TOTAL_SIZE_LIMIT'
                } else {
                    $destination = Join-Path (Join-Path $payload 'mod_logs') $relative
                    try {
                        # Recheck size after opening: the game may still be writing.
                        $allowance = [Math]::Min($perModFileLimit, $totalModLimit - $totalCopied)
                        $copied = Copy-CCCLogSnapshot $file.FullName $destination $allowance
                        $record.Status = $copied.Status
                        $record.SourceBytes = $copied.OriginalBytes
                        $record.CollectedBytes = $copied.CopiedBytes
                        $totalCopied += $copied.CopiedBytes
                        if ($copied.Status -ne 'OMITTED_SIZE_LIMIT') { $copiedCount++ }
                    } catch {
                        $record.Status = 'ERROR_READING_FILE'
                        $record.Details = $_.Exception.Message
                        if (Test-Path -LiteralPath $destination -PathType Leaf) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
                    }
                }
                $manifest.Add($record)
            }
            $report.Add('Mod log/text files found: ' + $candidates.Count)
        } else { $report.Add('Mod folder present: False') }
        $report.Add('Mod log/text files collected: ' + $copiedCount)
        $report.Add('Mod bytes collected: ' + $totalCopied)

        $ue4ssLog = Join-Path $loader 'UE4SS.log'
        if (Test-Path -LiteralPath $ue4ssLog -PathType Leaf) {
            $ue4ssItem = Get-Item -LiteralPath $ue4ssLog -Force
            if (($ue4ssItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $notes.Add('Skipped linked UE4SS.log.')
            } else {
                # The unfiltered source snapshot is OUTSIDE the archived Report
                # directory and is deleted in finally even if filtering fails.
                $snapshot = Join-Path $temp 'UE4SS_SourceSnapshot.tmp'
                $record = [pscustomobject]@{ File = 'UE4SS_Filtered.log'; Status = ''; SourceBytes = [long]0; CollectedBytes = [long]0; LastWriteUtc = $ue4ssItem.LastWriteTimeUtc.ToString('o'); Details = '' }
                try {
                    $copy = Copy-CCCLogSnapshot $ue4ssLog $snapshot $ue4ssSourceLimit
                    $record.Status = $copy.Status
                    $record.SourceBytes = $copy.OriginalBytes
                    if ($copy.Status -ne 'OMITTED_SIZE_LIMIT') {
                        $selected = Export-CCCUE4SSLines $snapshot (Join-Path $payload 'UE4SS_Filtered.log') $ue4ssOutputLimit
                        $record.CollectedBytes = $selected.Bytes
                        $record.Details = 'Scanned ' + $selected.Scanned + ' lines; kept ' + $selected.Included + ' selected/context lines; omitted ' + $selected.Omitted + ' selected lines at the output size limit.'
                        if ($selected.Omitted -gt 0) { $record.Status = 'FILTERED_OUTPUT_SIZE_LIMIT' }
                        elseif ($copy.Status -eq 'COMPLETE') { $record.Status = 'FILTERED_COMPLETE_SOURCE' }
                        $report.Add('UE4SS filter includes the first 100 lines, all mod/error matches in the bounded source, two preceding and three following lines. Line numbers refer to UE4SS.log.')
                    }
                } catch {
                    $record.Status = 'ERROR_READING_OR_FILTERING_UE4SS'
                    $record.Details = $_.Exception.Message
                }
                $manifest.Add($record)
            }
        } else { $report.Add('UE4SS.log present: False') }
    }
    if ($manifest.Count -gt 0) {
        $manifest.ToArray() | Export-Csv -LiteralPath (Join-Path $payload 'MANIFEST.csv') -NoTypeInformation -Encoding UTF8
    } else {
        Write-CCCText (Join-Path $payload 'MANIFEST.csv') '"File","Status","SourceBytes","CollectedBytes","LastWriteUtc","Details"'
    }
    if ($notes.Count -gt 0) {
        $report.Add('')
        $report.Add('Collection notes:')
        foreach ($note in $notes) { $report.Add('- ' + $note) }
    }
    $report.Add('')
    $report.Add('Compact diagnostics run automatically. If stutter remains, stop somewhere safe away from combat and press F9 once while still in the gameplay level, then wait a moment before closing the game. F9 requests a detailed snapshot and can briefly hitch; it is not a recording start/stop key.')
    $report.Add('To avoid cross-file changes while packaging, you may close the game after reproducing the problem, then run this collector.')
    Write-CCCText (Join-Path $payload 'REPORT.txt') ($report -join [Environment]::NewLine)
    $fileName = 'UPLOAD_THIS_ChooChooCharles_ModTest_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip'
    $output = Join-Path $PSScriptRoot $fileName
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $output, [IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Host ''
    Write-Host ('Created upload ZIP: ' + $output) -ForegroundColor Green
    Write-Host 'This ZIP contains diagnostic logs and a manifest of everything included or omitted.'
    Write-Host 'The local save backup is not included.'
} catch {
    Write-Host ('DIAGNOSTICS ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($temp -and (Test-Path -LiteralPath $temp -PathType Container)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
