' Desktop Media Monitor Launcher v3 - Auto-Restart on Crash
' Wraps PowerShell in a loop so it restarts if it dies

Dim RetryDelay
RetryDelay = 10  ' seconds to wait between restarts

Dim ScriptPath
ScriptPath = "C:\Scripts\desktop-media-monitor\desktop-media-monitor.ps1"

Do While True
    CreateObject("Wscript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ScriptPath & """", 0, True
    WScript.Sleep RetryDelay * 1000
Loop