# Shared helpers. Dot-source from the configuration scripts.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HelperCache.ps1')

function New-SettingsBackup {
    param([string]$Name)
    $script:settingsBackup = Join-Path $env:USERPROFILE ('.glzr\backups\' + $Name + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $script:settingsBackup -Force | Out-Null
    $script:backupEntries = @()
    [IO.File]::WriteAllText((Join-Path $script:settingsBackup 'files.json'), '[]')
    return $script:settingsBackup
}

function Save-SettingFile {
    param([string]$Path)
    if (@($script:backupEntries | Where-Object { $_.Path -eq $Path }).Count) { return }
    $existed = Test-Path -LiteralPath $Path -PathType Leaf
    $name = '{0:D3}.bak' -f $script:backupEntries.Count
    if ($existed) { Copy-Item -LiteralPath $Path -Destination (Join-Path $script:settingsBackup $name) }
    $script:backupEntries += [pscustomobject]@{ Path = $Path; Existed = $existed; Backup = $name }
    ConvertTo-Json -InputObject @($script:backupEntries) -Depth 8 |
        Set-Content -LiteralPath (Join-Path $script:settingsBackup 'files.json') -Encoding UTF8
}

function Write-SettingText {
    param([string]$Path, [string]$Text)
    Save-SettingFile $Path
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Read-SettingJson {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{}
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Set-IniValues {
    param([string]$Text, [System.Collections.IDictionary]$Values)
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = "[Everything]`r`n" }
    if ($Text -notmatch '(?im)^\[Everything\]\s*$') { throw 'Missing [Everything] INI section.' }
    foreach ($key in $Values.Keys) {
        $line = $key + '=' + [string]$Values[$key]
        $pattern = '(?m)^' + [regex]::Escape($key) + '=[^\r\n]*'
        if ([regex]::IsMatch($Text, $pattern)) {
            $replacement = $line
            $Text = [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
        } else { $Text = $Text.TrimEnd() + "`r`n" + $line + "`r`n" }
    }
    return $Text
}

function Get-IniValue {
    param([string]$Text, [string]$Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=([^\r\n]*)')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Stop-DesktopApp {
    param([string]$Name)
    $session = (Get-Process -Id $PID).SessionId
    Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session } | Stop-Process -Force
}

function Update-PowerToys {
    param([switch]$WithLauncher)
    $root = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'
    $path = Join-Path $root 'settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $settings = Read-SettingJson $path
    Save-SettingFile $path
    $running = @(Get-Process -Name PowerToys -ErrorAction SilentlyContinue)
    $exe = if ($running.Count) { $running[0].Path } else { Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe' }
    # Stop the manager before its modules so it cannot respawn them or rewrite settings.
    Stop-DesktopApp 'PowerToys'
    Stop-DesktopApp 'PowerToys.FancyZones'
    if ($WithLauncher) {
        Stop-DesktopApp 'PowerToys.PowerLauncher'
        Stop-DesktopApp 'Microsoft.CmdPal*'
    }
    Set-JsonProperty $settings.enabled 'FancyZones' $false
    if ($WithLauncher) {
        Set-JsonProperty $settings.enabled 'PowerToys Run' $false
        Set-JsonProperty $settings.enabled 'CmdPal' $false
    }
    Write-SettingText $path ($settings | ConvertTo-Json -Depth 50)
    if ($running.Count -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe }
}

function Set-StartupShortcut {
    param([string]$Name, [string]$Target, [string]$Arguments = '')
    $path = Join-Path ([Environment]::GetFolderPath('Startup')) ($Name + '.lnk')
    Save-SettingFile $path
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = Split-Path -Parent $Target
    $shortcut.Save()
}

function Register-DesktopStartup {
    [CmdletBinding()]
    param(
        [string]$ScoopRoot = $(if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }),
        [string]$LauncherDirectory = (Join-Path $env:USERPROFILE '.glzr\glazewm'),
        [string]$StartupDirectory = ([Environment]::GetFolderPath('Startup')),
        [switch]$WithLauncher, [switch]$Diagnostics, [switch]$DisableDiagnostics
    )
    if ($Diagnostics -and $DisableDiagnostics) { throw 'Choose either Diagnostics or DisableDiagnostics.' }
    $glazeCli = Join-Path $ScoopRoot 'apps\glazewm\current\cli\GlazeWM.exe'
    if (-not (Test-Path -LiteralPath $glazeCli -PathType Leaf)) { throw "GlazeWM CLI not found: $glazeCli" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User.Value
    $taskName = 'GlazeWM'
    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $accountNames = @($userSid, $identity.Name, ($identity.Name -split '\\')[-1])
    if ($existingTask -and $existingTask.Principal.UserId -notin $accountNames) {
        throw 'An existing GlazeWM scheduled task belongs to another account.'
    }

    $launcherConfig = Join-Path $LauncherDirectory 'launcher-startup.json'
    $launcherShortcuts = @('Everything (dotfiles).lnk', 'Flow Launcher (dotfiles).lnk')
    $legacyLaunchers = @($launcherShortcuts | Where-Object { Test-Path -LiteralPath (Join-Path $StartupDirectory $_) })
    $enableLaunchers = $WithLauncher -or (Test-Path -LiteralPath $launcherConfig) -or $legacyLaunchers.Count -gt 0
    $launcherScoopRoot = $ScoopRoot
    if (-not $WithLauncher -and (Test-Path -LiteralPath $launcherConfig)) {
        $previous = Read-SettingJson $launcherConfig
        if (-not $previous -or -not $previous.PSObject.Properties['ScoopRoot'] -or
            $previous.ScoopRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($previous.ScoopRoot) -or
            -not [IO.Path]::IsPathRooted($previous.ScoopRoot)) {
            throw 'Invalid launcher-startup.json. Rerun Enable-Startup.ps1 -WithLauncher to repair it.'
        }
        $launcherScoopRoot = $previous.ScoopRoot
    }
    if ($enableLaunchers) {
        foreach ($relative in @('apps\flow-launcher\current\Flow.Launcher.exe', 'apps\everything\current\Everything.exe')) {
            $exe = Join-Path $launcherScoopRoot $relative
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Launcher executable not found: $exe" }
        }
    }
    foreach ($file in @('Start-Desktop.ps1', 'Start-GlazeWM.cmd', 'Start-GlazeWM.vbs', 'Measure-GlazeWMStartup.ps1', 'StartupPerformance.ps1', 'HelperCache.ps1', 'DesktopRuntime.cs', 'Start-DesktopLauncher.ps1', 'Get-DesktopWindow.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw "Startup source missing: $file" }
    }
    $backup = New-SettingsBackup 'startup-task'
    Save-SettingFile $launcherConfig
    foreach ($name in @('GlazeWM.lnk') + $launcherShortcuts) { Save-SettingFile (Join-Path $StartupDirectory $name) }

    New-Item -ItemType Directory -Path $LauncherDirectory -Force | Out-Null
    # Install the implementation before switching the compatible CMD entry point.
    foreach ($file in @('Start-Desktop.ps1', 'Measure-GlazeWMStartup.ps1', 'StartupPerformance.ps1', 'HelperCache.ps1', 'DesktopRuntime.cs', 'Start-DesktopLauncher.ps1', 'Get-DesktopWindow.ps1', 'Start-GlazeWM.cmd', 'Start-GlazeWM.vbs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $LauncherDirectory -Force
    }
    Initialize-DesktopRuntime -Directory $LauncherDirectory -Build
    $launcherPath = Join-Path $LauncherDirectory 'Start-GlazeWM.vbs'
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') `
        -Argument ('//B //Nologo "{0}" "{1}"' -f $launcherPath, $glazeCli) -WorkingDirectory $LauncherDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userSid
    $trigger.Delay = 'PT10S'
    $principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -Priority 6 -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Start GlazeWM and configured app launchers at sign-in (Windows dotfiles).' -Force | Out-Null

    # Retain the previous opt-in and shortcuts if registration fails.
    if ($enableLaunchers) {
        Write-SettingText $launcherConfig ([pscustomobject]@{ ScoopRoot = $launcherScoopRoot } | ConvertTo-Json)
    }
    $diagnosticFlag = Join-Path $LauncherDirectory 'diagnostics.enabled'
    if ($Diagnostics) { Set-Content -LiteralPath $diagnosticFlag -Value 'startup' -Encoding ASCII }
    if ($DisableDiagnostics -and (Test-Path -LiteralPath $diagnosticFlag)) { Remove-Item -LiteralPath $diagnosticFlag }
    $retiredShortcuts = @('GlazeWM.lnk')
    if ($enableLaunchers) { $retiredShortcuts += $launcherShortcuts }
    foreach ($name in $retiredShortcuts) {
        $path = Join-Path $StartupDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Write-Host "Registered $taskName logon task for $($identity.Name) with a 10-second delay."
    Write-Host "Startup settings and shortcut backup: $backup"
    Write-Host "Startup log: $(Join-Path $LauncherDirectory 'startup.log')"
    if ($enableLaunchers) { Write-Host 'Flow and Everything will start with GlazeWM; Startup-folder delays are bypassed.' }
}

function Update-WindowWalkerSettings {
    param($Settings, [string]$FlowData)
    if (-not $Settings.PSObject.Properties['PluginSettings'] -or
        -not $Settings.PluginSettings.PSObject.Properties['Plugins']) { return }
    foreach ($entry in $Settings.PluginSettings.Plugins.PSObject.Properties) {
        if ($entry.Name -ne 'F737A9223560B3C6833B5FFB8CDF78E5') { continue }
        if (-not $entry.Value.PSObject.Properties['Priority'] -or $entry.Value.Priority -lt 2) {
            Set-JsonProperty $entry.Value 'Priority' 2
        }
        $path = Join-Path $FlowData 'Settings\Plugins\Flow.Plugin.WindowWalker\Settings.json'
        $pluginSettings = Read-SettingJson $path
        Set-JsonProperty $pluginSettings 'SearchCloakedWindows' $true
        Write-SettingText $path ($pluginSettings | ConvertTo-Json -Depth 50)
    }
}
