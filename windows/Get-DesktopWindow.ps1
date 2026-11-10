# Point at the unexpected window, then run this script; no focus/layout changes.
[CmdletBinding()]
param([long]$Handle = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HelperCache.ps1')
$installed = Join-Path $env:USERPROFILE '.glzr\glazewm'
Initialize-DesktopRuntime -Directory $installed
$snapshot = [Dotfiles.Desktop.StartupWindows]::DescribeWindow($Handle)
$result = [ordered]@{ Time = (Get-Date).ToString('o'); Window = $snapshot; Managed = $null; ManagementError = $null }
$scoop = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$probe = New-Object Diagnostics.Process
$probe.StartInfo.FileName = Join-Path $scoop 'apps\glazewm\current\cli\GlazeWM.exe'
$probe.StartInfo.Arguments = 'query windows'
$probe.StartInfo.UseShellExecute = $false
$probe.StartInfo.CreateNoWindow = $true
$probe.StartInfo.RedirectStandardOutput = $true
$probe.StartInfo.RedirectStandardError = $true
try {
    $null = $probe.Start()
    $stdout = $probe.StandardOutput.ReadToEndAsync()
    $stderr = $probe.StandardError.ReadToEndAsync()
    if (-not $probe.WaitForExit(1000)) { $probe.Kill(); throw 'GlazeWM window query timed out.' }
    if ($probe.ExitCode -ne 0 -or -not $stdout.Wait(200)) { throw 'GlazeWM window query failed.' }
    $response = $stdout.Result | ConvertFrom-Json
    if (-not $response.success) { throw 'GlazeWM rejected the window query.' }
    $result.Managed = @($response.data.windows | Where-Object { [long]$_.handle -eq $snapshot.RootHandle }).Count -gt 0
} catch { $result.ManagementError = $_.Exception.Message }
finally { $probe.Dispose() }
# No titles, executable paths, or command lines are persisted.
[pscustomobject]$result | ConvertTo-Json -Depth 4
