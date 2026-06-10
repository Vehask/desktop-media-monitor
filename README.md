# Desktop Media Monitor

Report Windows desktop media playback state (YouTube, Spotify, Brave, Chrome, Discord, fullscreen apps) to Home Assistant as a `binary_sensor`.

## Architecture

```
┌───────────────────────────────────────────────────────────────────────────────────────────────────┐
│  Windows Desktop                                            │
│                                                             │
│  desktop-media-monitor-launcher.vbs (auto-restart wrapper)  │
│         │                                                   │
│         ▼ (spawns & watches)                                │
│  desktop-media-monitor.ps1 (main loop, polls every 5s)      │
│         │                                                   │
│         ├── SMTC API → Brave/YouTube/Spotify playback       │
│         ├── SoundVolumeView → Chrome, Discord audio         │
│         └── Win32 API → fullscreen/borderless window check  │
│         │                                                   │
│         ▼ (POST /api/states/)                               │
│  Home Assistant ── binary_sensor.desktop_media_active       │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘

Detection sources:
1. **SMTC (System Media Transport Controls)** — detects Brave browser media playback (YouTube Music, Spotify Web, etc.) via Windows Runtime API
2. **SoundVolumeView.exe** (NirSoft) — detects audio sessions from Chrome, Discord, and other apps
3. **Fullscreen window detection** — detects borderless/fullscreen applications as "media active" (excludes Brave, Explorer, SearchHost, and monitored apps)

## Files

| File | Purpose |
|------|---------|
| `desktop-media-monitor.ps1` | **Main monitor** — polls every 5s, reports state to HA |
| `desktop-media-monitor-launcher.vbs` | **Auto-restart wrapper** — restarts the PowerShell script if it crashes |
| `windows-media-session-api.ps1` | **Lighter alternative** — only uses SMTC, simpler state (active/inactive) |
| `diag.ps1` | Diagnostic tool — dumps all active SMTC sessions |
| `SoundVolumeViewDebug.ps1` | Debug tool — shows raw SoundVolumeView CSV output |
| `stop-media-monitor.ps1` | Stops the running monitor by killing its PowerShell process |
| `stop-media-monitor-launcher.vbs` | VBS launcher for the stop script |

## Prerequisites

- **PowerShell** (built into Windows 10/11)
- **Home Assistant** instance with a Long-Lived Access Token
- **SoundVolumeView** (optional, for Chrome/Discord audio detection) — [Download from NirSoft](https://www.nirsoft.net/utils/sound_volume_view.html)

## Setup

### 1. Clone or copy scripts

Place all `.ps1` and `.vbs` files in a folder on your Windows desktop, e.g.:

```
C:\Scripts\desktop-media-monitor\
```

### 2. Download SoundVolumeView (optional)

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
Double-click `desktop-media-monitor-launcher.vbs`. It launches the PowerShell script and automatically restarts it if it crashes.

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
    details: "Brave: Song Title" | "Chrome audio active" | "Game.exe - Window Title"
    monitored_apps: "Google Chrome, Discord, Brave (SMTC)"
```

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

## Customization

- **Monitored apps** — Edit `$monitoredApps` array in `desktop-media-monitor.ps1`
- **Fullscreen monitoring** — Set `$monitorFullscreen = $false` to disable
- **Check interval** — Change `$checkInterval` (default: 5 seconds)
- **Brave detection** — Set `$monitorBrave = $false` to disable
- **Entity ID** — Change `$entityId` to use a different HA entity

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No state updates in HA | Verify `$haUrl` and `$haToken` are correct |
| "SoundVolumeView not found" | Download SVV.exe and place in `Tools\` subfolder |
| No Brave detection | Play something in Brave that shows media controls (YouTube, Spotify Web) |
| Monitor keeps crashing | Run directly (not via launcher) to see error output |
| SMTC not working | Run `diag.ps1` to verify the API is accessible |