# ============================================================================
# CONFIGURATION — Customize these before running
# ============================================================================

# Your Home Assistant instance URL
$haUrl         = "http://YOUR_HA_IP:8123"

# Create a Long-Lived Access Token in HA: Profile > Security > Long-Lived Access Tokens
$haToken       = "YOUR_HA_LONG_LIVED_TOKEN"

# The entity ID to report state to (customize this if needed)
$entityId      = "binary_sensor.desktop_media_active"

$checkInterval = 5

# Path to NirSoft SoundVolumeView.exe (download from https://www.nirsoft.net/utils/sound_volume_view.html)
$soundVolumeViewPath = Join-Path $PSScriptRoot "Tools\SoundVolumeView.exe"

# Apps monitored via SoundVolumeView (Brave is handled separately via SMTC)
$monitoredApps = @(
    "Google Chrome"
    "Discord"
)

$monitorBrave = $true

# ============================================================================

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]

function Invoke-Async($op, $type) {
    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $task = $asTaskMethod.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait()
    return $task.Result
}

$smtcManager = Invoke-Async `
    ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
    ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

function Test-BravePlayingViaSMTC {
    if (-not $monitorBrave) { return @{ IsPlaying = $false; Details = "" } }

    try {
        $sessions = $smtcManager.GetSessions()
        foreach ($session in $sessions) {
            if ($session.SourceAppUserModelId -eq "Brave") {
                $status = $session.GetPlaybackInfo().PlaybackStatus
                if ($status -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing) {
                    $title = ""
                    try {
                        $props = Invoke-Async($session.TryGetMediaPropertiesAsync(), [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                        $title = $props.Title
                    } catch {}
                    return @{ IsPlaying = $true; Details = "Brave: $title" }
                }
            }
        }
    } catch {
        Write-Host "SMTC check failed: $_"
    }

    return @{ IsPlaying = $false; Details = "" }
}

function Test-MonitoredAppsPlayingAudio {
    if (-not (Test-Path $soundVolumeViewPath)) {
        Write-Host "WARNING: SoundVolumeView not found at $soundVolumeViewPath"
        return @{ IsPlaying = $false; Details = "" }
    }

    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        & $soundVolumeViewPath /scomma $tempFile | Out-Null
        Start-Sleep -Milliseconds 500
        $audioData = Import-Csv $tempFile -ErrorAction SilentlyContinue
        Remove-Item $tempFile -ErrorAction SilentlyContinue

        foreach ($session in $audioData) {
            if ($monitoredApps -contains $session.Name -and $session.'Device State' -eq "Active") {
                $windowTitle = $session.'Window Title'
                return @{
                    IsPlaying = $true
                    Details   = "$($session.Name) audio active$(if ($windowTitle) { ": $windowTitle" })"
                }
            }
        }
    } catch {
        Write-Host "SoundVolumeView check failed: $_"
    }

    return @{ IsPlaying = $false; Details = "" }
}

function Update-HomeAssistantState {
    param($state, $details)
    $headers = @{ "Authorization" = "Bearer $haToken"; "Content-Type" = "application/json" }
    $body = @{
        state      = $state
        attributes = @{
            friendly_name  = "Desktop Media Active"
            device_class   = "running"
            details        = $details
            monitored_apps = (($monitoredApps + @("Brave (SMTC)")) -join ", ")
        }
    } | ConvertTo-Json

    $maxRetries = 3
    $retryDelay = 2
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Invoke-RestMethod -Uri "$haUrl/api/states/$entityId" -Method Post -Headers $headers -Body $body | Out-Null
            return $true
        } catch {
            if ($attempt -lt $maxRetries) {
                Write-Host "HA update attempt $attempt/$maxRetries failed, retrying in ${retryDelay}s: $_"
                Start-Sleep -Seconds $retryDelay
            } else {
                Write-Host "Failed to update Home Assistant after $maxRetries attempts: $_"
            }
        }
    }
    return $false
}

Write-Host "========================================"
Write-Host "Desktop Media Monitor"
Write-Host "========================================"
Write-Host "Brave detection : SMTC (SourceAppUserModelId = 'Brave')"
Write-Host "Other apps      : SoundVolumeView ($($monitoredApps -join ', '))"
Write-Host "Check interval  : $checkInterval seconds"
Write-Host "SVV             : $(if (Test-Path $soundVolumeViewPath) { 'Found' } else { 'NOT FOUND' })"
Write-Host ""

$lastState   = ""
$lastDetails = ""

try {
    while ($true) {
        $mediaActive = $false
        $details     = ""

        $braveCheck = Test-BravePlayingViaSMTC
        if ($braveCheck.IsPlaying) {
            $mediaActive = $true
            $details     = $braveCheck.Details
        }

        if (-not $mediaActive) {
            $audioCheck = Test-MonitoredAppsPlayingAudio
            if ($audioCheck.IsPlaying) {
                $mediaActive = $true
                $details     = $audioCheck.Details
            }
        }

        $currentState = if ($mediaActive) { "on" } else { "off" }
        if ($currentState -ne $lastState -or $details -ne $lastDetails) {
            if (Update-HomeAssistantState $currentState $details) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $currentState $(if ($details) { "- $details" })"
                $lastState   = $currentState
                $lastDetails = $details
            }
        }

        Start-Sleep -Seconds $checkInterval
    }
} catch {
    Write-Host "[FATAL] Unhandled exception in main loop, exiting: $_"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    Start-Sleep -Seconds 5
} finally {
    Write-Host "Monitor stopped (will restart via launcher)"
}