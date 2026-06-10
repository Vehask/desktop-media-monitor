' Desktop Media Monitor Launcher v2 - Auto-Restart on Crash
' Wraps PowerShell in a loop so it restarts if it dies
' Place this .vbs in the same directory as desktop-media-monitor.ps1

Dim RetryDelay, ScriptDir, PSScriptPath
RetryDelay = 10  ' seconds to wait between restarts

' Derive script path from the launcher's own location
ScriptDir    = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
PSScriptPath = ScriptDir & "desktop-media-monitor.ps1"

Do While True
    CreateObject("Wscript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & PSScriptPath & """", 0, True
    WScript.Sleep RetryDelay * 1000
Loop