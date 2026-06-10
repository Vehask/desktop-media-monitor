# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Customize these before running
# ═══════════════════════════════════════════════════════════════════════════

# Your Home Assistant instance URL
$haUrl    = "http://YOUR_HA_IP:8123"

# Create a Long-Lived Access Token in HA: Profile > Security > Long-Lived Access Tokens
$haToken  = "YOUR_HA_LONG_LIVED_TOKEN"

# The entity ID to report state to (customize this if needed)
# Options: binary_sensor.desktop_media_session_api_active, sensor.desktop_media_state, etc.
$entityId = "binary_sensor.desktop_media_session_api_active"

$pollMs   = 500
# ═══════════════════════════════════════════════════════════════════════════

[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,
 Windows.Media.Control, ContentType=WindowsRuntime] | Out-Null

function Await($asyncOp) {
    $awaiter = $asyncOp.GetAwaiter()
    while (-not $awaiter.IsCompleted) { Start-Sleep -Milliseconds 50 }
    return $awaiter.GetResult()
}

function Send-HaState($state) {
    $uri     = "$haUrl/api/states/$entityId"
    $headers = @{ Authorization = "Bearer $haToken"; "Content-Type" = "application/json" }
    $body    = @{ state = $state } | ConvertTo-Json
    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body | Out-Null
}

$manager    = Await([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync())
$wasPlaying = $null

Write-Host "Watching Windows Media Sessions..."

while ($true) {
    $sessions  = $manager.GetSessions()
    $isPlaying = $false

    foreach ($session in $sessions) {
        $status = $session.GetPlaybackInfo().PlaybackStatus
        if ($status -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing) {
            $isPlaying = $true
            break
        }
    }

    if ($isPlaying -ne $wasPlaying) {
        $wasPlaying = $isPlaying
        $state      = if ($isPlaying) { "active" } else { "inactive" }

        Write-Host "$(Get-Date -Format 'HH:mm:ss')  →  $state"
        Send-HaState $state
    }

    Start-Sleep -Milliseconds $pollMs
}