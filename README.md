# Desktop Media Monitor

Report Windows desktop media playback state (browser audio, Discord voice, and fullscreen apps) to Home Assistant as a `binary_sensor`.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Windows Desktop                                    │
│                                                     │
│  desktop-media-monitor-launcher.vbs (auto-restart)  │
│         │                                           │
│         ▼ (spawns & watches)                        │
│  desktop-media-monitor.ps1 (main loop, polls 5s)    │
│         │                                           │
│         ├── SMTC API → Brave (YouTube, Spotify)     │
│         ├── SoundVolumeView → Chrome, Discord       │
│         └── GetForegroundWindow → games, fullscreen │
│         │                                           │
│         ▼ (POST /api/states/)                       │
│  Home Assistant ── binary_sensor.desktop_media_active│
└─────────────────────────────────────────────────────┘
```

Detection sources (checked in order):
1. **SMTC (System Media Transport Controls)** — detects Brave browser media playback (YouTube Music, Spotify Web, etc.) via Windows Runtime API
2. **SoundVolumeView.exe** (NirSoft) — detects active audio sessions from Chrome and Discord voice calls
3. **Foreground fullscreen detection** — detects fullscreen/borderless apps (games, tools) using only the **active foreground window** (`GetForegroundWindow`), not `EnumWindows` (background windows are ignored)

> **Why foreground-only?** The original version used `EnumWindows` which checks ALL open windows. A maximized window sitting in the background could trigger a false "on" state for days. By checking only `GetForegroundWindow`, the sensor only fires when the user is actively looking at a fullscreen app. When you alt-tab or close the game, the foreground changes and the sensor goes "off" automatically.

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

> SoundVolumeView is **required** if you want to detect Chrome audio or Discord voice sessions. Brave detection works via SMTC (built-in Windows API) without additional tools. Fullscreen detection works natively without any extra software.

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
    details: "Brave: Song Title" | "Discord audio active" | "Google Chrome audio active" | "game.exe - Window Title"
    monitored_apps: "Google Chrome, Discord, Brave (SMTC)"
```

**What triggers "on":**
- Brave playing audio (YouTube, Spotify Web) via SMTC
- Chrome playing audio (any tab) via SoundVolumeView
- Discord in a voice call via SoundVolumeView
- Any app/game running fullscreen or borderless in the **foreground** (active window)

**What stays "off:
- Background maximized windows (no EnumWindows — only foreground checked)
- Idle system with monitors sleeping
- Browser tabs with no audio playing
- Desktop / lock screen / system panels

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
| `$monitorFullscreen` | `$true` | Enable/disable foreground fullscreen detection |

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No state updates in HA | Verify `$haUrl` and `$haToken` are correct |
| "SoundVolumeView not found" | Download SVV.exe and place in `Tools\` subfolder |
| No Brave detection | Play something in Brave that shows media controls (YouTube, Spotify Web) |
| Game not detected as fullscreen | Some games run in windowed mode — check game display settings |
| False "on" from fullscreen | Only checked on the foreground window. If still false, add exclusions in `$monitoredApps` |
| Monitor keeps crashing | Run directly (not via launcher) to see error output |
| SMTC not working | Run `diag.ps1` to verify the API is accessible |
