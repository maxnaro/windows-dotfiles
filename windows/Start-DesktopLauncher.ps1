# Invoked by Start-GlazeWM.vbs in a minimized terminal. No generated EXE required.
[CmdletBinding()]
param(
    [ValidateSet('Startup', 'CompanionsOnly', 'StopCompanions', 'TitleBarsRestart', 'FlowRestart', 'FlowStart', 'FlowStop')]
    [string]$Action = 'Startup',
    [string]$GlazeCli
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$launcherLog = Join-Path $PSScriptRoot 'desktop-launcher.log'
function Write-LauncherLog([string]$Message) {
    if ((Test-Path -LiteralPath $launcherLog) -and (Get-Item -LiteralPath $launcherLog).Length -gt 262144) {
        Clear-Content -LiteralPath $launcherLog
    }
    Add-Content -LiteralPath $launcherLog -Value ((Get-Date -Format o) + ' ' + $Message) -Encoding UTF8
}
try {
    if ($Action -in @('Startup', 'CompanionsOnly')) {
        try { $Host.UI.RawUI.WindowTitle = 'Dotfiles desktop startup' } catch { }
        $options = @{}
        if ($GlazeCli) { $options.GlazeCli = $GlazeCli }
        if ($Action -eq 'CompanionsOnly') { $options.CompanionsOnly = $true }
        # Do not detach the orchestrator: this terminal closes only when its
        # readiness checks finish (or its bounded failure path returns).
        & (Join-Path $PSScriptRoot 'Start-Desktop.ps1') @options
        exit $LASTEXITCODE
    }
    . (Join-Path $PSScriptRoot 'HelperCache.ps1')
    $scriptName = 'Watch-FlowWorkspace.ps1'
    $arguments = switch ($Action) {
        'StopCompanions' { $scriptName = 'Start-Desktop.ps1'; ' -StopCompanions' }
        'TitleBarsRestart' { $scriptName = 'Watch-TitleBars.ps1'; ' -Restart' }
        'FlowRestart' { ' -Restart' }
        'FlowStart' { '' }
        'FlowStop' { ' -Stop -WaitForStop' }
    }
    $entry = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw "Lifecycle script missing: $entry" }
    # A resident keeps its redirection file open. A later -Restart must be able
    # to open its own log before it invokes the script that stops that resident.
    $log = Join-Path $PSScriptRoot ($Action + '-' + [guid]::NewGuid().ToString('N') + '-launcher.log')
    # Logs are opened in the child so they survive dispatcher exit. Only fixed,
    # allowlisted switches are composed into source; paths are quoted as literals.
    $command = "& { try { `$global:LASTEXITCODE = 0; & '" + $entry.Replace("'", "''") + "'" + $arguments +
        "; exit `$LASTEXITCODE } catch { Write-Error `$_ -ErrorAction Continue; exit 1 } } *> '" + $log.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $child = Start-DesktopPowerShell $encoded
    try { Write-LauncherLog "$Action dispatched (PID $($child.Id)); child status/errors: $log" }
    finally { $child.Dispose() }
    # Resident watchers must not keep a minimized console alive. Dispatch success
    # is not readiness; the orchestrator/helper status and child log report that.
    exit 0
} catch {
    $message = "$Action failed: $($_.Exception.Message)"
    try { Write-LauncherLog $message } catch { }
    Write-Error $message -ErrorAction Continue
    exit 1
}
