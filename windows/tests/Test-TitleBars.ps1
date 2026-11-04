[CmdletBinding()]
param([switch]$Live)
$ErrorActionPreference='Stop'
$windows=Split-Path -Parent $PSScriptRoot
& (Join-Path $windows 'Watch-TitleBars.ps1') -Check
. (Join-Path $windows 'HelperCache.ps1')
$assembly=Get-DesktopHelperAssembly -Source (Join-Path $windows 'TitleBars.cs') -References @('System.dll','System.Core.dll','System.Web.Extensions.dll')
[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly)) | Out-Null
Add-Type -AssemblyName System.Windows.Forms
$flags=[Reflection.BindingFlags]'NonPublic,Static'
$type=[Dotfiles.TitleBars]
function Native($name,$arguments){$type.GetMethod($name,$flags).Invoke($null,$arguments)}
function Assert($condition,$message){if(-not $condition){throw $message}}
$form=New-Object Windows.Forms.Form
$journal=Join-Path $env:TEMP ('title-bars-test-'+[guid]::NewGuid()+'.json')
try {
 $handle=$form.Handle
 $style=(Native 'GetWindowLongPtrW' @($handle,-16)).ToInt64()
 $bounds=$form.Bounds
 $record=New-Object Dotfiles.TitleBars+Record
 $record.Handle=$handle.ToInt64();$record.Pid=$PID;$record.Start=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;$record.Token=12345;$record.Bits=0x400000
 $null=Native 'SetPropW' @($handle,'Dotfiles.TitleBars.Owner',[IntPtr]12345)
 [IO.File]::WriteAllText($journal, ('[' + ($record | ConvertTo-Json -Compress) + ']'))
 $null=Native 'Frame' @($handle,[int]($style -band (-bnot 0x400000)))
 Assert (((Native 'GetWindowLongPtrW' @($handle,-16)).ToInt64() -band 0x400000) -eq 0) 'Frame was not hidden'
 [Dotfiles.TitleBars]::Recover($journal)
 Assert ((Native 'GetWindowLongPtrW' @($handle,-16)).ToInt64() -eq $style) 'Original style was not restored'
 Assert ($form.Bounds -eq $bounds) 'Frame update moved the window'
 Assert ((Get-Content $journal -Raw | ConvertFrom-Json).Count -eq 0) 'Recovery journal was not cleared'
 # A missing marker simulates destruction and handle reuse.
 [IO.File]::WriteAllText($journal, ('[' + ($record | ConvertTo-Json -Compress) + ']'))
 $null=Native 'Frame' @($handle,[int]($style -band (-bnot 0x400000)))
 [Dotfiles.TitleBars]::Recover($journal)
 Assert (((Native 'GetWindowLongPtrW' @($handle,-16)).ToInt64() -band 0x400000) -eq 0) 'Unowned window was modified'
 Write-Output 'PASS: native title-bar removal, restoration, geometry, journal cleanup, and ownership protection.'
} finally {$form.Dispose();Remove-Item $journal -Force -ErrorAction SilentlyContinue}

Add-Type -Path (Join-Path $PSScriptRoot 'TitleBarSocketFixture.cs') -ReferencedAssemblies @($assembly,'System.dll','System.Core.dll','System.Windows.Forms.dll')
$lifecycleJournal = Join-Path $env:TEMP ('title-bars-lifecycle-' + [guid]::NewGuid() + '.json')
try {
    [TitleBarLifecycleFixture]::Run($lifecycleJournal)
    Write-Output 'PASS: managed/unmanaged events, pause/resume, graceful exit, IPC disconnect, reconnect, and owner crash.'
} finally {
    Remove-Item $lifecycleJournal,($lifecycleJournal + '.log') -Force -ErrorAction SilentlyContinue
}

if ($Live) {
    $installed = Join-Path $env:USERPROFILE '.glzr\glazewm'
    $cli = Join-Path $env:USERPROFILE 'scoop\apps\glazewm\current\cli\GlazeWM.exe'
    $journal = Join-Path $installed ('title-bars-' + (Get-Process -Id $PID).SessionId + '.json')
    $initial = (& $cli query paused | ConvertFrom-Json).data
    Assert (-not $initial) 'Live test requires GlazeWM to be unpaused.'
    $records = Get-Content $journal -Raw | ConvertFrom-Json
    function Has-Frame($row) {
        $h = [IntPtr]([long]$row.Handle)
        ((Native 'GetWindowLongPtrW' @($h,-16)).ToInt64() -band 0x400000) -ne 0
    }
    try {
        $null = & $cli command wm-toggle-pause
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        do { Start-Sleep -Milliseconds 100; $remaining = Get-Content $journal -Raw | ConvertFrom-Json }
        while ($remaining.Count -and [datetime]::UtcNow -lt $deadline)
        foreach ($row in $records) { Assert (Has-Frame $row) 'Pause did not restore a tracked frame.' }
    } finally {
        if ((& $cli query paused | ConvertFrom-Json).data) { $null = & $cli command wm-toggle-pause }
    }
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    do { Start-Sleep -Milliseconds 100; $current = Get-Content $journal -Raw | ConvertFrom-Json }
    while (-not $current.Count -and [datetime]::UtcNow -lt $deadline)
    Assert ($current.Count -gt 0) 'Resume did not hide any frames.'
    foreach ($row in $current) { Assert (-not (Has-Frame $row)) 'Resume left a tracked frame visible.' }
    Write-Output 'PASS: live pause restores frames and resume hides them again.'
}
