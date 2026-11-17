$ErrorActionPreference = 'Stop'

# Resolve the user's HTTPS association each time so changing the default browser
# does not require reinstalling the GlazeWM configuration.
$choice = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice'
$command = (Get-Item "Registry::HKEY_CLASSES_ROOT\$($choice.ProgId)\shell\open\command").GetValue('')
if ($command -notmatch '^\s*"([^"]+)"|^\s*(\S+\.exe)') {
    throw 'Could not resolve the default browser executable.'
}
$browser = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
Start-Process -FilePath ([Environment]::ExpandEnvironmentVariables($browser)) -ArgumentList '--new-window'
