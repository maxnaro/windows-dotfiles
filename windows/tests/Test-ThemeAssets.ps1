# Tests preflight without touching installed settings or applications.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'ThemeAssets.ps1')
$root = Join-Path $env:TEMP ('dotfiles-theme-assets-' + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $failed = $false
    try { $null = Get-ThemeAssets $root } catch {
        $failed = $_.Exception.Message -match 'git submodule update --init --recursive'
    }
    if (-not $failed) { throw 'Missing module did not produce initialization instructions.' }
    # Exercise every installer entry point in a checkout without the module.
    # Their first work must be preflight, before profile or application writes.
    $repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $fixtureWindows = Join-Path $root 'windows'
    New-Item -ItemType Directory -Path $fixtureWindows | Out-Null
    foreach ($name in @('ThemeAssets.ps1', 'Apply.ps1', 'Configure-Launcher.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repository "windows/$name") -Destination $fixtureWindows
    }
    Copy-Item -LiteralPath (Join-Path $repository 'setup.ps1') -Destination $root
    $oldProfile = $env:USERPROFILE
    $env:USERPROFILE = Join-Path $root 'profile'
    try {
        foreach ($entry in @('setup.ps1', 'windows/Apply.ps1', 'windows/Configure-Launcher.ps1')) {
            $failure = ''
            try { & (Join-Path $root $entry) } catch { $failure = $_.Exception.Message }
            if ($failure -notmatch 'git submodule update --init --recursive') { throw "Missing module was not reported by $entry : $failure" }
            if (Test-Path -LiteralPath $env:USERPROFILE) { throw "$entry created a profile destination before preflight." }
        }
    } finally { $env:USERPROFILE = $oldProfile }
    foreach ($relative in @('modules\theme\generated\desktop.css', 'modules\theme\assets\coniston.jpg', 'modules\theme\assets\Chocolatier.xaml')) {
        $path = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'fixture')
    }
    $assets = Get-ThemeAssets $root
    foreach ($path in $assets.Values) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Resolved asset is missing.' } }
    Remove-Item -LiteralPath $assets.Css
    $failed = $false
    try { $null = Get-ThemeAssets $root } catch { $failed = $true }
    if (-not $failed) { throw 'Partially populated module was accepted.' }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host 'Theme asset preflight passed.'
