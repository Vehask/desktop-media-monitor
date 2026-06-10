' Runs the stop script to kill the desktop-media-monitor process
' Place this .vbs in the same directory as stop-media-monitor.ps1

Dim ScriptDir, StopScriptPath
ScriptDir      = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
StopScriptPath = ScriptDir & "stop-media-monitor.ps1"

CreateObject("Wscript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & StopScriptPath & """", 0, False