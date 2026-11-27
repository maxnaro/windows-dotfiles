[CmdletBinding()]
param(
    [string]$GlazeCli = (Join-Path $(if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }) 'apps\glazewm\current\cli\GlazeWM.exe')
)
$ErrorActionPreference = 'Stop'

$destinations = @{}
@('ms-teams', 'Teams', 'olk', 'OUTLOOK') | ForEach-Object { $destinations[$_] = '1' }
@('firefox', 'msedge', 'chrome', 'brave', 'opera', 'opera_gx', 'vivaldi', 'chromium', 'zen') | ForEach-Object { $destinations[$_] = '2' }
@('WindowsTerminal', 'cmd', 'powershell', 'pwsh', 'conhost', 'OpenConsole') | ForEach-Object { $destinations[$_] = '5' }

function Invoke-GlazeRequest {
    param([string[]]$Arguments)
    $output = & $GlazeCli @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GlazeWM command failed: $($Arguments -join ' ')" }
    $response = ($output -join "`n") | ConvertFrom-Json
    if (-not $response.success) { throw "GlazeWM rejected the request: $($response.error)" }
    return $response.data
}

function Get-ManagedWindows {
    param($Children)
    foreach ($child in $Children) {
        if ($child.type -eq 'window') { $child }
        elseif ($child.children) { Get-ManagedWindows $child.children }
    }
}

$mutex = New-Object Threading.Mutex($false, 'Local\DotfilesOrganizeGlazeWorkspaces')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { return }

    $snapshot = Invoke-GlazeRequest @('query', 'workspaces')
    foreach ($workspace in $snapshot.workspaces) {
        foreach ($window in (Get-ManagedWindows $workspace.children)) {
            if (-not $window.processName) { continue }
            $target = $destinations[$window.processName]
            if (-not $target -or $workspace.name -eq $target) { continue }
            try {
                $null = Invoke-GlazeRequest @('command', '--id', $window.id, 'move', '--workspace', $target)
            } catch { Write-Warning $_.Exception.Message }
        }
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
