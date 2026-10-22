[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Distribution = 'UbuntuNC',
    [string]$Repository = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL must already be installed. See the WSL prerequisites in README.md.'
}
$listed = & wsl.exe --list --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list WSL distributions. WSL must already be enabled on this PC.'
}
# Older WSL versions can emit NUL characters in redirected output.
$distributions = @(($listed -join "`n" -replace "`0", '') -split '\r?\n' |
    ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Distribution -notin $distributions) {
    throw "WSL distribution '$Distribution' is not installed. Installed: $($distributions -join ', ')."
}

# Encode the repository URL as data before putting it into the stdin script.
$repositoryData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Repository))
$bootstrap = @'
set -euo pipefail
repo_url="$(printf '%s' '__REPOSITORY_BASE64__' | base64 --decode)"
linux_dotfiles="$HOME/dotfiles"
if [[ ! -e "$linux_dotfiles" ]]; then
    if [[ -z "$repo_url" ]]; then
        printf '%s\n' 'Missing ~/dotfiles in this distribution. Rerun setup-wsl.ps1 with -Repository <your-Linux-dotfiles-Git-URL>.' >&2
        exit 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        printf '%s\n' 'Git must already be installed inside WSL before cloning the Linux dotfiles.' >&2
        exit 1
    fi
    git clone --recurse-submodules -- "$repo_url" "$linux_dotfiles"
fi
if [[ ! -f "$linux_dotfiles/setup.sh" ]]; then
    printf '%s\n' 'Expected ~/dotfiles/setup.sh. Existing files have been left in place.' >&2
    exit 1
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd -- "$linux_dotfiles"
exec bash ./setup.sh
'@

Write-Host "Running the Linux dotfiles setup inside $Distribution."
# Windows PowerShell emits CRLF; remove CR characters before Bash reads stdin.
# The doubled backslash reaches tr as a single backslash, so tr removes CR.
$bootstrap = $bootstrap.Replace('__REPOSITORY_BASE64__', $repositoryData)
$bootstrap | & wsl.exe --distribution $Distribution --cd '~' -- bash -c 'tr -d \\r | bash -s'
if ($LASTEXITCODE -ne 0) {
    throw "The Linux setup exited with code $LASTEXITCODE. Check its prerequisite messages above."
}
