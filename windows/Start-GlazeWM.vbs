Option Explicit
Dim shell, files, directory, command, result, action, cli, argument, environment
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
directory = files.GetParentFolderName(WScript.ScriptFullName)
If WScript.Arguments.Count > 1 Then WScript.Quit 1
action = "Startup"
cli = ""
If WScript.Arguments.Count = 1 Then
    argument = WScript.Arguments(0)
    Select Case argument
        Case "--companions": action = "CompanionsOnly"
        Case "--stop": action = "StopCompanions"
        Case "--title-bars-restart": action = "TitleBarsRestart"
        Case "--flow-restart": action = "FlowRestart"
        Case "--flow-start": action = "FlowStart"
        Case "--flow-stop": action = "FlowStop"
        Case Else
            If Left(argument, 2) = "--" Then WScript.Quit 1
            cli = argument
    End Select
End If
' Pass data in this process's environment, not through CMD or PowerShell source.
' In particular WScript.Run expands percent expressions in its command string.
On Error Resume Next
Set environment = shell.Environment("Process")
environment("DOTFILES_DESKTOP_ENTRY") = files.BuildPath(directory, "Start-DesktopLauncher.ps1")
environment("DOTFILES_DESKTOP_ACTION") = action
environment("DOTFILES_DESKTOP_CLI") = cli
If Err.Number <> 0 Then WScript.Quit 1
command = Quote(shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe") & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " & _
    Quote("$ErrorActionPreference = 'Stop'; try { & $env:DOTFILES_DESKTOP_ENTRY -Action $env:DOTFILES_DESKTOP_ACTION -GlazeCli $env:DOTFILES_DESKTOP_CLI; exit $LASTEXITCODE } catch { Write-Error $_ -ErrorAction Continue; exit 1 }")
' 7 requests minimized without activation. Wait for startup, preserving its result.
' Terminal hosts may interpret the window-state request differently; test at sign-in.
result = shell.Run(command, 7, True)
If Err.Number <> 0 Then WScript.Quit 1
On Error GoTo 0
WScript.Quit result

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
