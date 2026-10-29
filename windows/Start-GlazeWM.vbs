Option Explicit
Dim shell, files, directory, command, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
directory = files.GetParentFolderName(WScript.ScriptFullName)
If WScript.Arguments.Count <> 1 Then WScript.Quit 1
command = Quote(shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe") & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Quote(files.BuildPath(directory, "Start-Desktop.ps1")) & " -GlazeCli " & Quote(WScript.Arguments(0))
On Error Resume Next
result = shell.Run(command, 0, True)
If Err.Number <> 0 Then WScript.Quit 1
On Error GoTo 0
WScript.Quit result

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
