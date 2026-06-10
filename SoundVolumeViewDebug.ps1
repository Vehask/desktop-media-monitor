# Debug version - let's see what SoundVolumeView is outputting
# Download SoundVolumeView.exe from https://www.nirsoft.net/utils/sound_volume_view.html
# Place it in a Tools\ subdirectory alongside this script

$soundVolumeViewPath = Join-Path $PSScriptRoot "Tools\SoundVolumeView.exe"

Write-Host "Testing SoundVolumeView output..."

$tempFile = [System.IO.Path]::GetTempFileName()
& $soundVolumeViewPath /scomma $tempFile | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`nRaw CSV content:"
Get-Content $tempFile | Write-Host

Write-Host "`n`nParsed data:"
$audioData = Import-Csv $tempFile -ErrorAction SilentlyContinue
$audioData | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "`n`nChrome sessions only:"
$audioData | Where-Object { $_.Name -like "*chrome*" } | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "`n`nColumn names:"
$audioData[0].PSObject.Properties.Name | Write-Host

Remove-Item $tempFile -ErrorAction SilentlyContinue