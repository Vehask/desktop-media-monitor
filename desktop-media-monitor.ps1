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

if (-not ([System.Management.Automation.PSTypeName]'WindowHelper').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WindowHelper {
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
    public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
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

function Get-AllWindowInfo {
    $windows = New-Object System.Collections.ArrayList
    $callback = {
        param($hwnd, $lParam)
        $title = New-Object System.Text.StringBuilder 256
        [WindowHelper]::GetWindowText($hwnd, $title, $title.Capacity) | Out-Null
        if ($title.Length -eq 0) { return $true }
        $processId = 0
        [WindowHelper]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        $rect = New-Object WindowHelper+RECT
        [WindowHelper]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        try { $processName = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName }
        catch { $processName = "" }
        $null = $windows.Add(@{
            Title = $title.ToString(); ProcessName = $processName
            ProcessId = $processId; Left = $rect.Left; Top = $rect.Top
            Right = $rect.Right; Bottom = $rect.Bottom
        })
        return $true
    }
    [WindowHelper]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $windows
}

function Test-IsFullscreenOrBorderless {
    param($windowInfo)
    Add-Type -AssemblyName System.Windows.Forms
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $screen.Bounds
        if ($windowInfo.Left -le $b.Left -and $windowInfo.Top -le $b.Top -and
            $windowInfo.Right -ge ($b.Left + $b.Width) -and $windowInfo.Bottom -ge ($b.Top + $b.Height)) {
            return $true
        }
    }
    return $false
}

function Test-AnyFullscreenWindow {
    if (-not $monitorFullscreen) { return @{ IsFullscreen = $false; Details = "" } }

    $excludeProcesses = @("explorer", "SearchHost", "brave")
    foreach ($app in $monitoredApps) {
        $excludeProcesses += ($app -replace " \.exe$", "" -replace "Google ", "" -replace "Microsoft ", "").ToLower()
    }

    foreach ($window in (Get-AllWindowInfo)) {
        if ($excludeProcesses -contains $window.ProcessName.ToLower()) { continue }
        if (Test-IsFullscreenOrBorderless $window) {
            return @{ IsFullscreen = $true; Details = "$($window.ProcessName) - $($window.Title)" }
        }
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
Write-Host "Brave detection : SMTC (SourceAppUserModelId = 'Brave')"
Write-Host "Other apps      : SoundVolumeView"
Write-Host "Fullscreen      : $(if ($monitorFullscreen) { 'Enabled' } else { 'Disabled' })"
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

        if (-not $mediaActive) {
            $fsCheck = Test-AnyFullscreenWindow
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
