[CmdletBinding()]
param([switch]$Build,[switch]$Check,[switch]$Stop,[switch]$WaitForStop,[switch]$Restart,[switch]$Status,[string]$StartupGeneration)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HelperCache.ps1')
$assembly=Get-DesktopHelperAssembly -Source (Join-Path $PSScriptRoot 'TitleBars.cs') -References @('System.dll','System.Core.dll','System.Web.Extensions.dll') -Build:($Build -or $Check)
if ($Build -or $Check) { Write-Output 'PASS: title-bar helper compiled.'; return }
[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly)) | Out-Null
$session=(Get-Process -Id $PID).SessionId
$eventName="Local\DotfilesTitleBarsStop-$session"
if ($Status) { try { $event=[Threading.EventWaitHandle]::OpenExisting($eventName); $event.Dispose(); return $true } catch { return $false } }
if ($Stop -or $Restart) { try { $event=[Threading.EventWaitHandle]::OpenExisting($eventName); $null=$event.Set(); $event.Dispose() } catch [Threading.WaitHandleCannotBeOpenedException] {} }
$mutex=New-Object Threading.Mutex($false,"Local\DotfilesTitleBars-$session")
$locked=$false
try {
 try { $locked=$mutex.WaitOne($(if($Stop -or $Restart){15000}else{0})) } catch [Threading.AbandonedMutexException] { $locked=$true }
 if(-not $locked){ if($Stop -or $Restart){throw 'Title-bar helper did not stop.'}; return }
 $journal=Join-Path $PSScriptRoot "title-bars-$session.json"
 [Dotfiles.TitleBars]::Recover($journal)
 if($Stop){return}
 if(-not (Test-DesktopSession $PSScriptRoot $StartupGeneration)){return}
 $config=Get-Content (Join-Path $PSScriptRoot 'desktop-startup.json') -Raw | ConvertFrom-Json
 if(-not $config.PSObject.Properties['TitleBarsEnabled'] -or -not $config.TitleBarsEnabled){return}
 $event=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,$eventName)
 try { [Dotfiles.TitleBars]::Run($event,$journal) } finally {$event.Dispose()}
} finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
