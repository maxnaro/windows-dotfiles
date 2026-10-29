# Run with Windows PowerShell 5.1. All test files live in a disposable TEMP folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'DesktopSettings.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
$testRoot = Join-Path $env:TEMP ('dotfiles-settings-test-' + [guid]::NewGuid())
$originalProfile = $env:USERPROFILE
$originalScoop = $env:SCOOP
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $text = "[Everything]`r`nrun_as_admin=1`r`nunknown=keep`r`nfolders=C:\old`r`n"
    $values = [ordered]@{ run_as_admin = 0; folders = '"C:\\Docs, projects","C:\\Dollar$path"'; ipc = 1 }
    $updated = Set-IniValues $text $values
    Assert-True ($updated.Contains('unknown=keep')) 'Unrelated INI settings were lost.'
    Assert-True ($updated.Contains($values.folders)) 'INI replacement interpreted literal dollars or escapes.'
    Assert-True ((Set-IniValues $updated $values) -eq $updated) 'INI updates are not idempotent.'
    Assert-True ([regex]::Matches($updated, '(?m)^run_as_admin=').Count -eq 1) 'Duplicate INI keys.'
    Assert-True ((Get-IniValue "[Everything]`r`nfolders=`r`nipc=1`r`n" 'folders') -eq '') 'Empty CRLF folder list was mistaken for a configured index.'
    Assert-True ((Get-IniValue $updated 'folders') -eq $values.folders) 'Folder list was not read literally.'
    $object = [pscustomobject]@{ Keep = 42 }
    Set-JsonProperty $object 'Hotkey' 'Alt + Space'
    Set-JsonProperty $object 'Hotkey' 'Alt + Space'
    Assert-True ($object.Keep -eq 42 -and $object.Hotkey -eq 'Alt + Space') 'JSON merge lost settings.'

    # Backups must retain the pre-edit value even when a file is written twice.
    $env:USERPROFILE = $testRoot
    $backup = New-SettingsBackup 'test'
    $file = Join-Path $testRoot 'existing.json'
    [IO.File]::WriteAllText($file, 'original')
    Write-SettingText $file 'first'
    Write-SettingText $file 'second'
    $newFile = Join-Path $testRoot 'new.json'
    Write-SettingText $newFile '{}'
    $parsedEntries = Get-Content -LiteralPath (Join-Path $backup 'files.json') -Raw | ConvertFrom-Json
    $entries = @($parsedEntries)
    Assert-True ($entries.Count -eq 2) 'Backup entries were duplicated.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $backup $entries[0].Backup)) -eq 'original') 'Original backup was overwritten.'
    Assert-True (-not $entries[1].Existed) 'Absent-file backup state was lost.'

    # A fake CLI exercises readiness, errors, and a hung query without touching GlazeWM.
    $env:SCOOP = Join-Path $testRoot 'scoop'
    $cliDirectory = Join-Path $env:SCOOP 'apps\glazewm\current\cli'
    New-Item -ItemType Directory -Path $cliDirectory -Force | Out-Null
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
public class DotfilesFakeCli {
    public static int Main() {
        Thread.Sleep(Int32.Parse(Environment.GetEnvironmentVariable("DOTFILES_TEST_DELAY")));
        return Int32.Parse(Environment.GetEnvironmentVariable("DOTFILES_TEST_EXIT"));
    }
}
'@ -OutputAssembly (Join-Path $cliDirectory 'GlazeWM.exe') -OutputType ConsoleApplication
    $measure = Join-Path (Split-Path -Parent $PSScriptRoot) 'Measure-GlazeWMStartup.ps1'
    foreach ($case in @(@('ok', '0', '0'), @('failed', '0', '2'), @('timeout', '5000', '0'))) {
        $env:DOTFILES_TEST_DELAY = $case[1]
        $env:DOTFILES_TEST_EXIT = $case[2]
        $output = Join-Path $testRoot $case[0]
        & $measure -DurationSeconds 1 -IntervalSeconds 1 -OutputDirectory $output -Label test -ProbeTransport Cli -SkipPerformanceCounters
        $records = @(Get-Content -LiteralPath (Get-ChildItem -LiteralPath $output -Filter '*.jsonl')[0].FullName | ForEach-Object { $_ | ConvertFrom-Json })
        $sample = @($records | Where-Object { $_.Event -eq 'sample' })[0]
        Assert-True ($sample.QueryStatus -eq $case[0]) "Probe did not report $($case[0])."
        Assert-True ($records[-1].Event -eq 'capture-end') 'Collector did not terminate cleanly.'
        Assert-True ($records[-1].ReadyObserved -eq ($case[0] -eq 'ok')) 'Readiness result is wrong.'
    }
    Write-Host 'PASS: INI merge, JSON merge, backup preservation, and successful/failed/timed-out diagnostic probes.'
} finally {
    $env:USERPROFILE = $originalProfile
    $env:SCOOP = $originalScoop
    Remove-Item Env:DOTFILES_TEST_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:DOTFILES_TEST_EXIT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
