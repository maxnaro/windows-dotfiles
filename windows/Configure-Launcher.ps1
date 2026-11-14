[CmdletBinding()]
param([switch]$NoStart)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ThemeAssets.ps1')
$themeAssets = Get-ThemeAssets (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$flowRoot = Join-Path $scoopRoot 'apps\flow-launcher\current'
$everythingRoot = Join-Path $scoopRoot 'apps\everything\current'
$flowExe = Join-Path $flowRoot 'Flow.Launcher.exe'
$everythingExe = Join-Path $everythingRoot 'Everything.exe'
foreach ($exe in @($flowExe, $everythingExe)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Install the Scoop package first: $exe" }
}
$manifestPath = Join-Path $flowRoot 'scoop-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $flowRoot 'manifest.json' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$flowData = Join-Path $flowRoot ("app-$($manifest.version)\UserData")
if (-not (Test-Path -LiteralPath $flowData -PathType Container)) { throw "Flow portable UserData not found: $flowData" }
$everythingManifestPath = Join-Path $everythingRoot 'scoop-manifest.json'
if (-not (Test-Path -LiteralPath $everythingManifestPath)) { $everythingManifestPath = Join-Path $everythingRoot 'manifest.json' }
$everythingManifest = Get-Content -LiteralPath $everythingManifestPath -Raw | ConvertFrom-Json
if ($everythingManifest.version -notlike '1.4.*') { throw 'This configuration supports standard Everything 1.4, not Lite or 1.5 alpha.' }
$backup = New-SettingsBackup 'launcher'
Write-Host "Launcher settings backup: $backup"
Stop-DesktopApp 'Flow.Launcher'
# Ask Everything to save and exit before editing its INI; never touch its database.
$runningEverything = @(Get-Process -Name Everything -ErrorAction SilentlyContinue)
if ($runningEverything.Count) {
    $quit = Start-Process -FilePath $everythingExe -ArgumentList '-exit' -PassThru
    if (-not $quit.WaitForExit(5000)) { throw 'Everything exit request timed out.' }
    for ($i = 0; $i -lt 20 -and (Get-Process -Name Everything -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
    if (Get-Process -Name Everything -ErrorAction SilentlyContinue) { throw 'Exit Everything from its tray menu, then rerun.' }
}
$iniPath = Join-Path $everythingRoot 'Everything.ini'
$ini = if (Test-Path -LiteralPath $iniPath) { [IO.File]::ReadAllText($iniPath) } else { "[Everything]`r`n" }
# The Scoop portable package persists this file beside the executable.
if ($ini -match '(?m)^app_data=1\s*$') { throw 'Existing Everything uses AppData settings. Switch to portable settings before configuring.' }
# Preserve explicitly chosen folders on repeat runs. First run resolves redirected known folders.
if ([string]::IsNullOrWhiteSpace((Get-IniValue $ini 'folders'))) {
    $known = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $downloadsProperty = $known.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}']
    $downloads = if ($downloadsProperty) { $downloadsProperty.Value } else { Join-Path $env:USERPROFILE 'Downloads' }
    $candidates = @([Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'),
        [Environment]::ExpandEnvironmentVariables($downloads), (Split-Path -Parent $PSScriptRoot))
    $accounts = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
    if (Test-Path $accounts) {
        $candidates += @(Get-ChildItem $accounts | Where-Object { $_.PSChildName -like 'Business*' } |
            ForEach-Object { (Get-ItemProperty $_.PSPath).UserFolder })
    }
    $roots = @()
    foreach ($candidate in @($candidates | Where-Object { $_ } | Sort-Object Length)) {
        $candidate = $candidate.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        if (@($roots | Where-Object { $candidate.Equals($_, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { $roots += $candidate }
    }
    if (-not $roots.Count) { throw 'No readable index folders found.' }
    # Everything uses backslash escaping only inside quoted INI-list values.
    $encoded = @($roots | ForEach-Object { '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"' }) -join ','
    $values = [ordered]@{ folders = $encoded }
    foreach ($pair in @(@('folder_monitor_changes', 1), @('folder_rescan_if_full_list', 1),
        @('folder_update_types', 2), @('folder_update_days', 0), @('folder_update_ats', 12))) {
        $values[$pair[0]] = (@($roots | ForEach-Object { [string]$pair[1] }) -join ',')
    }
    $ini = Set-IniValues $ini $values
}
$ini = Set-IniValues $ini ([ordered]@{
    app_data = 0; run_as_admin = 0; run_in_background = 1; ipc = 1
    auto_include_fixed_volumes = 0; auto_include_removable_volumes = 0
    auto_include_fixed_refs_volumes = 0; auto_include_removable_refs_volumes = 0
    ntfs_volume_guids = ''; ntfs_volume_paths = ''; ntfs_volume_roots = ''; ntfs_volume_includes = ''; ntfs_volume_monitors = ''
    refs_volume_guids = ''; refs_volume_paths = ''; refs_volume_roots = ''; refs_volume_includes = ''; refs_volume_monitors = ''
    folder_update_rescan_asap = 0; folder_update_thread_mode_background = 1
})
Write-SettingText $iniPath $ini
$settingsPath = Join-Path $flowData 'Settings\Settings.json'
$settings = Read-SettingJson $settingsPath
# Keep custom themes in portable UserData so Flow updates retain them.
$themePath = Join-Path $flowData 'Themes\Chocolatier.xaml'
Write-SettingText $themePath ([IO.File]::ReadAllText($themeAssets.Launcher))
Set-JsonProperty $settings 'Theme' 'Chocolatier'
Set-JsonProperty $settings 'UseClock' $false
Set-JsonProperty $settings 'UseDate' $false
# WPF font family lists fall back when the first family lacks a glyph or is absent.
foreach ($property in @('QueryBoxFont', 'ResultFont', 'ResultSubFont')) {
    Set-JsonProperty $settings $property 'JetBrainsMono NF, Cascadia Mono'
}
Set-JsonProperty $settings 'QueryBoxFontSize' 18
Set-JsonProperty $settings 'ResultItemFontSize' 14
Set-JsonProperty $settings 'ResultSubItemFontSize' 12
Set-JsonProperty $settings 'Hotkey' 'Alt + Space'
Set-JsonProperty $settings 'SearchWindowScreen' 'Focus'
Set-JsonProperty $settings 'HideOnStartup' $true
Set-JsonProperty $settings 'FirstLaunch' $false
# Startup is owned by our per-user scheduled task, not Flow's own registration.
Set-JsonProperty $settings 'StartFlowLauncherOnSystemStartup' $false
if ($settings.PSObject.Properties['PluginSettings'] -and $settings.PluginSettings.PSObject.Properties['Plugins']) {
    foreach ($plugin in $settings.PluginSettings.Plugins.PSObject.Properties) {
        if ($plugin.Value.Name -in @('Explorer', 'Program')) { Set-JsonProperty $plugin.Value 'Disabled' $false }
    }
}
Update-WindowWalkerSettings $settings (Split-Path -Parent (Split-Path -Parent $settingsPath))
Write-SettingText $settingsPath ($settings | ConvertTo-Json -Depth 50)
$explorerPath = Join-Path $flowData 'Settings\Plugins\Flow.Launcher.Plugin.Explorer\Settings.json'
$explorer = Read-SettingJson $explorerPath
Set-JsonProperty $explorer 'IndexSearchEngine' 1
Set-JsonProperty $explorer 'PathEnumerationEngine' 1
Set-JsonProperty $explorer 'EverythingInstalledPath' $everythingExe
Set-JsonProperty $explorer 'EnableEverythingContentSearch' $false
Write-SettingText $explorerPath ($explorer | ConvertTo-Json -Depth 50)
Update-PowerToys -WithLauncher
# Include startup ownership in this backup so restoring launcher settings also
# restores their previous opt-in and any legacy Startup-folder shortcuts.
Save-SettingFile (Join-Path $env:USERPROFILE '.glzr\glazewm\launcher-startup.json')
foreach ($name in @('Everything (dotfiles).lnk', 'Flow Launcher (dotfiles).lnk')) {
    Save-SettingFile (Join-Path ([Environment]::GetFolderPath('Startup')) $name)
}
& (Join-Path $PSScriptRoot 'Enable-Startup.ps1') -WithLauncher
if (-not $NoStart) {
    Start-Process -FilePath $everythingExe -ArgumentList '-startup'
    Start-Process -FilePath $flowExe
}
Write-Host 'Flow: Alt+Space. Everything: folder indexing, no elevation or service installation.'
Write-Host 'The first folder scan may take several minutes. Later setup runs preserve selected folders and the database.'
