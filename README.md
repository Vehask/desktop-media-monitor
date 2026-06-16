# Desktop Media Monitor

Report Windows desktop media playback state (YouTube, Spotify, Brave, Chrome, Discord, fullscreen apps) to Home Assistant as a `binary_sensor`.

## Architecture

```
Scheduled Task (AtStartup, SYSTEM)
         |
         v
VBS Launcher (auto-restart every 10s on crash)
         |
         v
desktop-media-monitor.ps1 (main loop, polls every 5s)
         |
         +-- SMTC API -> Brave/YouTube/Spotify playback
         +-- SoundVolumeView -> Chrome, Discord audio
         +-- Win32 GetForegroundWindow -> fullscreen/borderless apps
         |
         v (POST /api/states/)
    Home Assistant -> binary_sensor.desktop_media_active
```

Detection sources:
1. **SMTC (System Media Transport Controls)** — Brave browser media (YouTube Music, Spotify Web)
2. **SoundVolumeView.exe** (NirSoft) — Chrome, Discord audio sessions
3. **Foreground fullscreen detection** — borderless/fullscreen apps (excludes Brave, Explorer, SearchHost, monitored apps)

## Files

| File | Purpose |
|------|---------|
| `desktop-media-monitor.ps1` | **Main monitor** — polls every 5s, reports state to HA |
| `desktop-media-monitor-launcher.vbs` | **Auto-restart wrapper** — restarts PS1 if it crashes |

## What's New in v3

- **Single-instance lock** — PID file in `%TEMP%` prevents duplicate processes
- **SMTC lazy reinit** — SMTC manager auto-reinitializes on failure (no stuck sessions)
- **5-minute heartbeat** — periodic state push prevents stale HA state
- **Organized folder** — scripts live in their own subdirectory
- **Debug scripts removed** — `diag.ps1`, `SoundVolumeViewDebug.ps1`, `windows-media-session-api.ps1`, `stop-media-monitor.ps1` and `.vbs` are no longer needed

## Prerequisites

- **PowerShell** (built into Windows 10/11)
- **Home Assistant** instance with a Long-Lived Access Token
- **SoundVolumeView** (optional, for Chrome/Discord audio) — [Download from NirSoft](https://www.nirsoft.net/utils/sound_volume_view.html)

## Setup

### 1. Clone or copy scripts

Place in a folder on your Windows desktop:

```
C:\Scripts\desktop-media-monitor\
  desktop-media-monitor.ps1
  desktop-media-monitor-launcher.vbs
```

### 2. Download SoundVolumeView (optional)

```
C:\Scripts\Tools\SoundVolumeView.exe
```

### 3. Configure

Edit `desktop-media-monitor.ps1` and set:

```powershell
$haUrl   = "http://YOUR_HA_IP:8123"
$haToken = "YOUR_HA_LONG_LIVED_TOKEN"
```

### 4. Install as scheduled task

```powershell
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '//B "C:\Scripts\desktop-media-monitor\desktop-media-monitor-launcher.vbs"'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 72)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'DesktopMediaMonitor_Start' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
```

### 5. Run it

```powershell
schtasks /run /tn DesktopMediaMonitor_Start
```

Or reboot the machine.

## Home Assistant entity

```yaml
binary_sensor.desktop_media_active:
  state: "on" | "off"
  attributes:
    friendly_name: "Desktop Media Active"
    device_class: "running"
    details: "Brave: Song Title" | "Chrome audio active" | "Game.exe - Window Title"
    monitored_apps: "Google Chrome, Discord, Brave (SMTC)"
```

## Auto-restart mechanics

The VBS launcher uses a `Do While True` loop:
1. Spawns `powershell.exe -WindowStyle Hidden ... desktop-media-monitor.ps1`
2. Waits for exit (third arg `True` = synchronous)
3. On exit (crash or normal), waits 10 seconds
4. Restarts

## Single-instance lock

On startup, the PS1 script writes its PID to `%TEMP%\desktop-media-monitor.lock`. If the file exists and points to a live process, the new instance exits immediately. This prevents duplicate processes that can cause duplicate HA state updates.

## Stability improvements in v3

| Issue | Fix |
|-------|-----|
| Two PS1 instances running | PID lock file prevents duplicates |
| SMTC crashes after hours | Lazy reinit — resets the manager on failure |
| HA shows stale state | 5-minute heartbeat pushes current state |
| Script crashes silently | VBS launcher restarts in 10s |
| Token truncated in file | Full token verified at 183 chars on deploy |

## Customization

- **Monitored apps** — Edit `$monitoredApps` array
- **Fullscreen monitoring** — Set `$monitorFullscreen = $false`
- **Check interval** — Change `$checkInterval` (default: 5s)
- **Brave detection** — Set `$monitorBrave = $false`
- **Entity ID** — Change `$entityId`

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No state updates in HA | Verify `$haUrl` and `$haToken` are correct (token should be ~183 chars) |
| "SoundVolumeView not found" | Download SVV.exe and place in `Tools\` folder |
| No Brave detection | Play something in Brave with media controls (YouTube, Spotify Web) |
| Monitor keeps crashing | Run directly (not via launcher) to see error output |
| Duplicate PIDs found | Lock file at `%TEMP%\desktop-media-monitor.lock` prevents this |
| HA shows stale "on" state | Script heartbeat pushes state every 5 minutes |
| SMTC errors when SYSTEM runs the script | This is expected — SMTC needs a user session. Brave detection degrades gracefully |