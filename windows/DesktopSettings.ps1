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
