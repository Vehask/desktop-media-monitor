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

$monitorBrave      = $true
$monitorFullscreen = $true

# ============================================================================

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]

# P/Invoke for foreground window checks (no EnumWindows — only the active window)
if (-not ([System.Management.Automation.PSTypeName]'ForegroundWindowHelper').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class ForegroundWindowHelper {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@
}

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

function Test-ForegroundFullscreen {
    if (-not $monitorFullscreen) { return @{ IsFullscreen = $false; Details = "" } }

    try {
        $hwnd = [ForegroundWindowHelper]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return @{ IsFullscreen = $false; Details = "" } }

        # Skip if the window isn't visible (hidden/ghost window)
        if (-not [ForegroundWindowHelper]::IsWindowVisible($hwnd)) {
            return @{ IsFullscreen = $false; Details = "" }
        }

        # Get window title
        $title = New-Object System.Text.StringBuilder 256
        [ForegroundWindowHelper]::GetWindowText($hwnd, $title, $title.Capacity) | Out-Null
        $windowTitle = $title.ToString()

        # Skip windows with no title (desktop, system panels, etc.)
        if ($windowTitle.Length -eq 0) { return @{ IsFullscreen = $false; Details = "" } }

        # Get process name for exclusion check
        $processId = 0
        [ForegroundWindowHelper]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        $processName = ""
        try { $processName = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName.ToLower() } catch {}

        # Exclude known non-game processes
        $excluded = @("explorer", "SearchHost", "ApplicationFrameHost", "LockApp")
        foreach ($app in $monitoredApps) {
            $excluded += ($app -replace " \.exe$", "" -replace "Google ", "" -replace "Microsoft ", "").ToLower()
        }
        # Also exclude brave via SMTC (already detected via Test-BravePlayingViaSMTC)
        $excluded += @("brave")

        if ($excluded -contains $processName) { return @{ IsFullscreen = $false; Details = "" } }

        # Get window bounds and check against screen resolution
        $rect = New-Object ForegroundWindowHelper+RECT
        [ForegroundWindowHelper]::GetWindowRect($hwnd, [ref]$rect) | Out-Null

        Add-Type -AssemblyName System.Windows.Forms
        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $b = $screen.Bounds
            if ($rect.Left -le $b.Left -and $rect.Top -le $b.Top -and
                $rect.Right -ge ($b.Left + $b.Width) -and $rect.Bottom -ge ($b.Top + $b.Height)) {
                return @{ IsFullscreen = $true; Details = "$processName - $windowTitle" }
            }
        }
    } catch {
        Write-Host "Foreground fullscreen check failed: $_"
    }

    return @{ IsFullscreen = $false; Details = "" }
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
Write-Host "Brave detection    : SMTC (SourceAppUserModelId = 'Brave')"
Write-Host "Other apps         : SoundVolumeView ($($monitoredApps -join ', '))"
Write-Host "Fullscreen         : $(if ($monitorFullscreen) { 'Enabled (foreground only)' } else { 'Disabled' })'"
Write-Host "Check interval     : $checkInterval seconds"
Write-Host "SVV                : $(if (Test-Path $soundVolumeViewPath) { 'Found' } else { 'NOT FOUND' })"
Write-Host ""

$lastState   = ""
$lastDetails = ""

try {
    while ($true) {
        $mediaActive = $false
        $details     = ""

        # Check 1: Brave audio via SMTC
        $braveCheck = Test-BravePlayingViaSMTC
        if ($braveCheck.IsPlaying) {
            $mediaActive = $true
            $details     = $braveCheck.Details
        }

        # Check 2: Chrome / Discord audio via SoundVolumeView
        if (-not $mediaActive) {
            $audioCheck = Test-MonitoredAppsPlayingAudio
            if ($audioCheck.IsPlaying) {
                $mediaActive = $true
                $details     = $audioCheck.Details
            }
        }

        # Check 3: Foreground window is fullscreen (games, apps)
        # Only checks the active foreground window — NOT all open windows.
        # This prevents false "on" states from background/maximized windows
        # sitting around when the machine is idle.
        if (-not $mediaActive) {
            $fsCheck = Test-ForegroundFullscreen
            if ($fsCheck.IsFullscreen) {
                $mediaActive = $true
                $details     = $fsCheck.Details
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