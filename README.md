# Desktop Media Monitor

Report Windows desktop media playback state (browser audio and Discord voice sessions) to Home Assistant as a `binary_sensor`.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Windows Desktop                                    │
│                                                     │
│  desktop-media-monitor-launcher.vbs (auto-restart)  │
│         │                                           │
│         ▼ (spawns & watches)                        │
│  desktop-media-monitor.ps1 (main loop, polls 5s)      │
│         │                                           │
│         ├── SMTC API → Brave (YouTube, Spotify)     │
│         └── SoundVolumeView → Chrome, Discord       │
│         │                                           │
│         ▼ (POST /api/states/)                       │
│  Home Assistant ── binary_sensor.desktop_media_active│
└─────────────────────────────────────────────────────┘
```

Detection sources:
1. **SMTC (System Media Transport Controls)** — detects Brave browser media playback (YouTube Music, Spotify Web, etc.) via Windows Runtime API
2. **SoundVolumeView.exe** (NirSoft) — detects active audio sessions from Chrome and Discord voice calls

> **Note:** Fullscreen/borderless window detection was intentionally removed. The sensor only triggers on actual audio playback — not on which windows are open or maximized. This prevents false "on" states when the machine is idle but has open windows.

## Files

| File | Purpose |
|------|---------|
| `desktop-media-monitor.ps1` | **Main monitor** — polls every 5s, reports state to HA |
| `desktop-media-monitor-launcher.vbs` | **Auto-restart wrapper** — restarts the script if it crashes |
| `windows-media-session-api.ps1` | **Lighter alternative** — only uses SMTC, simpler active/inactive state |
| `diag.ps1` | Diagnostic tool — dumps all active SMTC sessions |
| `stop-media-monitor.ps1` | Stops the running monitor by killing its PowerShell process |
| `stop-media-monitor-launcher.vbs` | VBS launcher for the stop script |

## Prerequisites

- **PowerShell** (built into Windows 10/11)
- **Home Assistant** instance with a **Long-Lived Access Token**
- **SoundVolumeView** (required for Chrome/Discord detection) — [Download from NirSoft](https://www.nirsoft.net/utils/sound_volume_view.html)

> SoundVolumeView is **required** if you want to detect Chrome audio or Discord voice sessions. Brave detection works via SMTC (built-in Windows API) without additional tools.

## Setup

### 1. Clone or copy scripts

Place all `.ps1` and `.vbs` files in a folder on your Windows desktop, e.g.:

```
C:\Scripts\desktop-media-monitor\
```

### 2. Download SoundVolumeView

Download `SoundVolumeView.exe` from NirSoft and place it in a `Tools\` subfolder:

```
C:\Scripts\desktop-media-monitor\Tools\SoundVolumeView.exe
```

### 3. Configure the monitor

Edit `desktop-media-monitor.ps1` and set:

```powershell
$haUrl   = "http://YOUR_HA_IP:8123"              # Your Home Assistant URL
$haToken = "YOUR_HA_LONG_LIVED_TOKEN"             # HA Long-Lived Access Token
```

Generate the token in Home Assistant: **Profile → Security → Long-Lived Access Tokens**.

### 4. Test it

Run `diag.ps1` first to verify SMTC is working — play something in Brave/YouTube and confirm sessions appear.

### 5. Run the monitor (two options)

**Option A — Persistent with auto-restart** (recommended):
Double-click `desktop-media-monitor-launcher.vbs`. It runs the PowerShell script and automatically restarts it if it crashes.

**Option B — Direct PowerShell**:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\desktop-media-monitor.ps1"
```

### 6. Home Assistant entity

The monitor creates/updates:

```yaml
binary_sensor.desktop_media_active:
  state: "on" | "off"
  attributes:
    friendly_name: "Desktop Media Active"
    device_class: "running"
    details: "Brave: Song Title" | "Discord audio active" | "Google Chrome audio active: window title"
    monitored_apps: "Google Chrome, Discord, Brave (SMTC)"
```

**What triggers "on":** Brave browser playing audio (YouTube, Spotify Web), Chrome playing audio (any tab), Discord in a voice call.

**What stays "off":** Maximized/borderless windows, games running, idle system, monitors sleeping.

### 7. Stop the monitor

Double-click `stop-media-monitor-launcher.vbs` or run:

```powershell
.\stop-media-monitor.ps1
```

## How the auto-restart launcher works

`desktop-media-monitor-launcher.vbs` uses a `Do While True` loop:

1. Spawns `powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "desktop-media-monitor.ps1"`
2. Waits for the process to exit (third argument `True` means synchronous)
3. On exit (crash or normal), waits 10 seconds
4. Restarts the PowerShell script

This means even if the PowerShell script crashes due to transient errors, it comes back automatically.

## Auto-start on boot (recommended)

Create a scheduled task so the monitor starts at boot:

```cmd
schtasks /create /tn "DesktopMediaMonitor_Start" /tr "wscript.exe //B C:\path\to\desktop-media-monitor-launcher.vbs" /sc onstart /ru SYSTEM /it /rl highest /delay 0000:15
```

This starts the monitor 15 seconds after Windows boots, even before you log in.

Optionally add a shortcut to the launcher in your Startup folder (`shell:startup`) if you prefer a per-user start.

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `$haUrl` | `"http://YOUR_HA_IP:8123"` | Home Assistant instance URL |
| `$haToken` | `"YOUR_HA_LONG_LIVED_TOKEN"` | HA Long-Lived Access Token |
| `$entityId` | `"binary_sensor.desktop_media_active"` | Entity ID to report state to |
| `$checkInterval` | `5` | Polling interval in seconds |
| `$soundVolumeViewPath` | `Join-Path $PSScriptRoot "Tools\SoundVolumeView.exe"` | Path to SoundVolumeView.exe |
| `$monitoredApps` | `@("Google Chrome", "Discord")` | Apps checked via SoundVolumeView |
| `$monitorBrave` | `$true` | Enable/disable Brave SMTC detection |

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No state updates in HA | Verify `$haUrl` and `$haToken` are correct |
| "SoundVolumeView not found" | Download SVV.exe and place in `Tools\` subfolder |
| No Brave detection | Play something in Brave that shows media controls (YouTube, Spotify Web) |
| Monitor keeps crashing | Run directly (not via launcher) to see error output |
| SMTC not working | Run `diag.ps1` to verify the API is accessible |
| Sensor stuck "on" for no reason | This was a known issue with the old fullscreen detection — removed in v2. If still happening, check SoundVolumeView for stale audio sessions |
