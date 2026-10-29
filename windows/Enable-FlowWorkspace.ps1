# Update only Flow placement and GlazeWM lifecycle commands in an existing setup.
[CmdletBinding()]
param([switch]$NoRestart)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Add-FlowWorkspaceCommand {
    param([string]$Config, [string]$Field, [string]$Command)
    $pattern = '(?m)^  ' + [regex]::Escape($Field) + ':(?<value>[^\r\n]*)'
    $match = [regex]::Match($Config, $pattern)
    if (-not $match.Success) { throw "Missing general.$Field in GlazeWM config." }
    $remaining = $Config.Substring($match.Index)
    $block = [regex]::Match($remaining, '(?ms)^.*?(?=\r?\n  [a-z_]+:|\r?\n[a-z_]+:|\z)').Value
    if ($block.Contains('Watch-FlowWorkspace.ps1') -or ($Field -in @('startup_commands', 'shutdown_commands') -and $block.Contains('Start-Desktop.ps1'))) { return $Config }
    $value = $match.Groups['value'].Value.Trim()
    $quoted = "'" + $Command.Replace("'", "''") + "'"
    if ($value.StartsWith('[') -and $value.EndsWith(']')) {
        $existing = $value.Substring(1, $value.Length - 2).Trim()
        $replacement = '  ' + $Field + ': [' + $(if ($existing) { $existing + ', ' }) + $quoted + ']'
    } elseif ($value -eq '' -or $value.StartsWith('#')) {
        $replacement = $match.Value + "`r`n    - " + $quoted
    } else { throw "Unsupported general.$Field value; expected an inline or indented YAML list." }
    return $Config.Substring(0, $match.Index) + $replacement + $Config.Substring($match.Index + $match.Length)
}
if ($MyInvocation.InvocationName -eq '.') { return }

. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')
$installed = Join-Path $env:USERPROFILE '.glzr\glazewm'
$configPath = Join-Path $installed 'config.yaml'
if (-not (Test-Path -LiteralPath $configPath)) { throw 'Install the GlazeWM configuration with setup.ps1 first.' }
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$flowRoot = Join-Path $scoopRoot 'apps\flow-launcher\current'
$manifestPath = Join-Path $flowRoot 'scoop-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $flowRoot 'manifest.json' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$settingsPath = Join-Path $flowRoot ("app-$($manifest.version)\UserData\Settings\Settings.json")
if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'Configure the portable Flow Launcher installation first.' }
$cli = Join-Path $scoopRoot 'apps\glazewm\current\cli\GlazeWM.exe'
if (-not $NoRestart -and -not (Test-Path -LiteralPath $cli)) { throw "GlazeWM CLI not found: $cli" }
& (Join-Path $PSScriptRoot 'Watch-FlowWorkspace.ps1') -Check
$config = [IO.File]::ReadAllText($configPath)
$launch = 'shell-exec powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%USERPROFILE%/.glzr/glazewm/Watch-FlowWorkspace.ps1"'
$config = Add-FlowWorkspaceCommand $config 'startup_commands' $launch
$config = Add-FlowWorkspaceCommand $config 'shutdown_commands' ($launch + ' -Stop')
$config = Add-FlowWorkspaceCommand $config 'config_reload_commands' ($launch + ' -Restart')
$backup = New-SettingsBackup 'flow-workspace'
Write-Host "Flow workspace backup: $backup"
# Stop the running version before replacing either source file. A config reload
# alone used to race with an old helper that was still holding its session mutex.
& (Join-Path $PSScriptRoot 'Watch-FlowWorkspace.ps1') -Stop -WaitForStop
$running = @(Get-Process -Name Flow.Launcher -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId })
Stop-DesktopApp 'Flow.Launcher'
$settings = Read-SettingJson $settingsPath
Set-JsonProperty $settings 'SearchWindowScreen' 'Focus'
Write-SettingText $settingsPath ($settings | ConvertTo-Json -Depth 50)
foreach ($name in @('Watch-FlowWorkspace.ps1', 'FlowWorkspace.cs', 'HelperCache.ps1')) {
    Write-SettingText (Join-Path $installed $name) ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)))
}
& (Join-Path $installed 'Watch-FlowWorkspace.ps1') -Build
Write-SettingText $configPath $config
if (-not $NoRestart) {
    try {
        & $cli command wm-reload-config
        if ($LASTEXITCODE -ne 0) { throw "GlazeWM could not reload. Restore the backup if needed: $backup" }
        $expectedHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'FlowWorkspace.cs') -Algorithm SHA256).Hash
        $expectedVersion = [Dotfiles.FlowWorkspace.Bridge]::Version
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        do {
            $status = & (Join-Path $installed 'Watch-FlowWorkspace.ps1') -Status
            if ($status.Ready -and $status.Version -eq $expectedVersion -and $status.SourceSha256 -eq $expectedHash) { break }
            Start-Sleep -Milliseconds 100
        } while ([datetime]::UtcNow -lt $deadline)
        if (-not $status.Ready -or $status.Version -ne $expectedVersion -or $status.SourceSha256 -ne $expectedHash) {
            throw "The updated Flow helper did not become ready. Check $(Join-Path $installed 'flow-workspace.log'). Backup: $backup"
        }
        Write-Host "Flow placement enabled; helper $($status.Version) is ready (PID $($status.ProcessId))."
    } finally {
        if ($running.Count) { Start-Process -FilePath (Join-Path $flowRoot 'Flow.Launcher.exe') }
    }
} else { Write-Host 'Settings installed. Restart Flow and reload GlazeWM with Alt+Shift+R to activate them.' }
