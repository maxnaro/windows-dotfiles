[CmdletBinding()]
param([ValidateSet('startup','companions','shutdown','reload')][string]$Mode, [string]$GlazeCli)
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot ("launcher-$Mode-$PID.log")
try {
    $parameters = @{}
    $scriptName = 'Start-Desktop.ps1'
    switch ($Mode) {
        startup { if ($GlazeCli) { $parameters.GlazeCli = $GlazeCli } }
        companions { $parameters.CompanionsOnly = $true }
        shutdown { $parameters.StopCompanions = $true }
        reload { $scriptName = 'Watch-FlowWorkspace.ps1'; $parameters.Restart = $true }
    }
    & (Join-Path $PSScriptRoot $scriptName) @parameters *> $log
} catch { $_ | Out-String | Add-Content -LiteralPath $log; exit 1 }
