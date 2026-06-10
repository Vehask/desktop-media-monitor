Get-Process powershell | Where-Object {
    $_.CommandLine -like "*desktop-media-monitor.ps1*"
} | Stop-Process -Force

Write-Host "Desktop Media Monitor stopped"
Start-Sleep -Seconds 2