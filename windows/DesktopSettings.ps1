# Shared helpers. Dot-source from the configuration scripts.
Set-StrictMode -Version Latest

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
    foreach ($file in @('Start-Desktop.ps1', 'DesktopLauncher.cs', 'Invoke-DesktopLauncher.ps1', 'Watch-FlowWorkspace.ps1', 'FlowWorkspace.cs', 'Wallpaper.ps1', 'Start-GlazeWM.cmd', 'Start-GlazeWM.vbs', 'Measure-GlazeWMStartup.ps1', 'StartupPerformance.ps1', 'HelperCache.ps1', 'DesktopRuntime.cs')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw "Startup source missing: $file" }
    }
    $backup = New-SettingsBackup 'startup-task'
    Save-SettingFile $launcherConfig
    foreach ($name in @('GlazeWM.lnk') + $launcherShortcuts) { Save-SettingFile (Join-Path $StartupDirectory $name) }

    $installedFiles = @('Start-Desktop.ps1', 'DesktopLauncher.cs', 'Invoke-DesktopLauncher.ps1', 'DesktopLauncher.exe', 'Watch-FlowWorkspace.ps1', 'FlowWorkspace.cs', 'Wallpaper.ps1', 'Measure-GlazeWMStartup.ps1', 'StartupPerformance.ps1', 'HelperCache.ps1', 'DesktopRuntime.cs', 'Start-GlazeWM.cmd', 'Start-GlazeWM.vbs', 'config.yaml', 'diagnostics.enabled')
    foreach ($file in $installedFiles) { Save-SettingFile (Join-Path $LauncherDirectory $file) }
    if ($existingTask) { Export-ScheduledTask -TaskName $taskName -TaskPath '\' | Set-Content -LiteralPath (Join-Path $backup 'task.xml') -Encoding Unicode }
    [IO.File]::WriteAllText((Join-Path $backup 'task.json'), (@{ Existed = [bool]$existingTask; Name = $taskName } | ConvertTo-Json))
    try {
    New-Item -ItemType Directory -Path $LauncherDirectory -Force | Out-Null
    . (Join-Path $PSScriptRoot 'HelperCache.ps1')
    Initialize-DesktopRuntime -Directory $LauncherDirectory -Build
    Install-DesktopLauncher -Directory $LauncherDirectory
    foreach ($file in $installedFiles | Where-Object { $_ -notin @('DesktopLauncher.exe', 'config.yaml', 'diagnostics.enabled') }) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $LauncherDirectory -Force
    }
    & (Join-Path $LauncherDirectory 'Watch-FlowWorkspace.ps1') -Build
    $configPath = Join-Path $LauncherDirectory 'config.yaml'
    if (Test-Path -LiteralPath $configPath) {
        Write-SettingText $configPath (Convert-DesktopLifecycle ([IO.File]::ReadAllText($configPath)))
    }
    $action = New-ScheduledTaskAction -Execute (Join-Path $LauncherDirectory 'DesktopLauncher.exe') `
        -Argument ('startup "{0}"' -f $glazeCli) -WorkingDirectory $LauncherDirectory
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
    } catch {
        $failure = $_
        Restore-StartupBackup $backup
        throw $failure
    }
    Write-Host "Registered $taskName logon task for $($identity.Name) with a 10-second delay."
    Write-Host "Startup settings and shortcut backup: $backup"
    Write-Host "Startup log: $(Join-Path $LauncherDirectory 'startup.log')"
    if ($enableLaunchers) { Write-Host 'Flow and Everything will start with GlazeWM; Startup-folder delays are bypassed.' }
}

function Convert-DesktopLifecycle {
    param([string]$Config)
    $Config = [regex]::Replace($Config, 'shell-exec powershell.exe[^\r\n'']*Start-Desktop.ps1" -CompanionsOnly', 'shell-exec "%USERPROFILE%/.glzr/glazewm/DesktopLauncher.exe" companions')
    $Config = [regex]::Replace($Config, 'shell-exec powershell.exe[^\r\n'']*Start-Desktop.ps1" -StopCompanions', 'shell-exec "%USERPROFILE%/.glzr/glazewm/DesktopLauncher.exe" shutdown')
    $Config = [regex]::Replace($Config, 'shell-exec powershell.exe[^\r\n'']*Watch-FlowWorkspace.ps1" -Restart', 'shell-exec "%USERPROFILE%/.glzr/glazewm/DesktopLauncher.exe" reload')
    $Config = [regex]::Replace($Config, 'shell-exec powershell.exe[^\r\n'']*Watch-FlowWorkspace.ps1" -Stop', 'shell-exec "%USERPROFILE%/.glzr/glazewm/DesktopLauncher.exe" shutdown')
    $Config = [regex]::Replace($Config, 'shell-exec powershell.exe[^\r\n'']*Watch-FlowWorkspace.ps1"(?='')', 'shell-exec "%USERPROFILE%/.glzr/glazewm/DesktopLauncher.exe" companions')
    return $Config
}

function Restore-StartupBackup {
    param([string]$BackupPath)
    $taskManifest = Join-Path $BackupPath 'task.json'
    if (Test-Path -LiteralPath $taskManifest) {
        $state = Get-Content -LiteralPath $taskManifest -Raw | ConvertFrom-Json
        if ($state.Existed) { $null = [xml][IO.File]::ReadAllText((Join-Path $BackupPath 'task.xml')) }
    }
    $parsed = Get-Content -LiteralPath (Join-Path $BackupPath 'files.json') -Raw | ConvertFrom-Json
    foreach ($entry in @($parsed)) {
        if ($entry.Existed -and -not (Test-Path -LiteralPath (Join-Path $BackupPath $entry.Backup))) { throw "Missing backup: $($entry.Backup)" }
    }
    foreach ($entry in @($parsed)) {
        if ($entry.Existed) { New-Item -ItemType Directory -Path (Split-Path -Parent $entry.Path) -Force | Out-Null }
        if ($entry.Existed) { Copy-Item -LiteralPath (Join-Path $BackupPath $entry.Backup) -Destination $entry.Path -Force }
        elseif (Test-Path -LiteralPath $entry.Path) { Remove-Item -LiteralPath $entry.Path -Force }
    }
    $registry = Join-Path $BackupPath 'registry.json'
    if (Test-Path -LiteralPath $registry) {
        $parsed = Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json
        foreach ($entry in @($parsed)) {
            New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType $entry.Kind -Force | Out-Null
        }
    }
    $task = Join-Path $BackupPath 'task.json'
    if (Test-Path -LiteralPath $task) {
        $state = Get-Content -LiteralPath $task -Raw | ConvertFrom-Json
        if ($state.Existed) { Register-ScheduledTask -TaskName $state.Name -TaskPath '\' -Xml ([IO.File]::ReadAllText((Join-Path $BackupPath 'task.xml'))) -Force | Out-Null }
        else { Unregister-ScheduledTask -TaskName $state.Name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Disable-OptionalStartupApps {
    $backup = New-SettingsBackup 'optional-startup'
    $entries = @()
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $run) {
        $key = Get-Item -LiteralPath $run
        foreach ($name in $key.GetValueNames()) {
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if (($name -match '^Mozilla-Firefox-[A-Fa-f0-9]{16}$' -and $value -match '(?i)firefox\.exe"?\s+-os-autostart(?:\s|$)') -or
                ($name -eq 'Adobe Acrobat Synchronizer' -and $value -match '(?i)AdobeCollabSync\.exe')) {
                $entries += [pscustomobject]@{ Path = $run; Name = $name; Value = $value; Kind = $key.GetValueKind($name).ToString() }
            }
        }
    }
    ConvertTo-Json -InputObject @($entries) -Depth 8 | Set-Content -LiteralPath (Join-Path $backup 'registry.json') -Encoding UTF8
    try {
        foreach ($entry in $entries) { Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name }
        $startup = [Environment]::GetFolderPath('Startup')
        foreach ($shortcut in @(Get-ChildItem -LiteralPath $startup -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^Send to OneNote(?: Tool)?$' })) {
            $shell = New-Object -ComObject WScript.Shell
            if ($shell.CreateShortcut($shortcut.FullName).TargetPath -match '(?i)\\ONENOTEM\.EXE$') {
                Save-SettingFile $shortcut.FullName
                Remove-Item -LiteralPath $shortcut.FullName
            }
        }
    } catch { Restore-StartupBackup $backup; throw }
    Write-Host "Optional startup backup: $backup"
}
