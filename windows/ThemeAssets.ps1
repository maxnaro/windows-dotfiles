# Check the complete shared asset set before any installation writes.
function Get-ThemeAssets {
    param([string]$RepositoryRoot)
    $root = Join-Path $RepositoryRoot 'modules\theme'
    $assets = @{
        Css = Join-Path $root 'generated\desktop.css'
        Wallpaper = Join-Path $root 'assets\coniston.jpg'
        Launcher = Join-Path $root 'assets\Chocolatier.xaml'
    }
    foreach ($path in $assets.Values) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Shared theme asset missing: $path. Run git submodule update --init --recursive from the repository root."
        }
    }
    return $assets
}
