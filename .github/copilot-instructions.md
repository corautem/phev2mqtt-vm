# phev2mqtt Web UI — Copilot Instructions

This file provides project-wide context and rules for GitHub Copilot. These instructions apply to every file generated or modified in this project. Always check this file before writing any code.

---

## Project Overview

This is a Proxmox VM installer and web UI management tool for [phev2mqtt](https://github.com/buxtronix/phev2mqtt) — a Mitsubishi Outlander PHEV to MQTT gateway. The project consists of:

1. A **host-side bash installer script** (runs on the Proxmox host shell using whiptail dialogs)
2. A **VM setup script** (runs inside a Debian 12 minimal KVM VM via cloud-init on first boot)
3. A **Python web UI application** (Flask or FastAPI backend, vanilla JS or Alpine.js frontend)

This is a **setup and management tool**, not a monitoring dashboard. Home Assistant handles monitoring. The web UI helps users configure WiFi, MQTT, and manage the phev2mqtt service.

---

## Build Progress

✅ adapters.txt — approved
✅ systemd/phev2mqtt.service — approved
✅ systemd/phev2mqtt-webui.service — approved
✅ config/journald.conf — approved
✅ config/logrotate.phev2mqtt-webui — approved
✅ webui/requirements.txt — approved
✅ webui/config.py — approved
✅ webui/auth.py — approved
✅ webui/app.py — approved
✅ webui/templates/first_run.html — approved
✅ webui/templates/login.html — approved
✅ webui/templates/settings.html — approved
✅ webui/templates/tools.html — approved
✅ webui/services/wifi.py — approved
✅ webui/services/mqtt.py — approved
✅ webui/services/phev.py — approved
✅ webui/services/emulator.py — approved
✅ webui/services/resources.py — approved
✅ webui/routes/**init**.py — approved
✅ webui/routes/api.py — approved
✅ webui/routes/terminal.py — approved
✅ webui/static/js/settings.js — approved
✅ webui/static/js/tools.js — approved
✅ install.sh — approved
✅ vm-setup.sh — approved
✅ README.md — approved

Next file to build: — none, build complete —

## Approval Gate — Critical Workflow Rule

NEVER modify copilot-instructions.md on your own initiative.
Only update it when explicitly instructed per the workflow below.

### States

⬜ not started | ⏳ in progress | ✅ approved

### Workflow

STEP 1 — When told to build a file:

- Update copilot-instructions.md: mark file as ⏳ in both
  Build Progress and Full Build Plan
- Using filesystem, write the file to its full absolute path under
  C:\Users\cosmi\Desktop\VS Code\phev2mqtt-proxmox\
- Ask for review, approval and next instructions
- Do not change anything else. WAIT.

STEP 2a — When told "APPROVED" with no new file instructions:

- Update copilot-instructions.md: mark file ✅
- STOP. Ask for next instructions.

STEP 2b — When told "APPROVED" with next file instructions:

- Update copilot-instructions.md:
  - Mark approved file ✅
  - Mark next file ⏳
  - Update "Next file to build" line
- Using filesystem, write the file to its full absolute path under
  C:\Users\cosmi\Desktop\VS Code\phev2mqtt-proxmox\
- Ask for review, approval and next instructions
- Do not change anything else. WAIT.

STEP 3 — When told "REJECTED — fix it":

- File stays ⏳. Do not update copilot-instructions.md.
- Using filesystem, write the corrected file to its full absolute path under
  C:\Users\cosmi\Desktop\VS Code\phev2mqtt-proxmox\
- Ask for review, approval and next instructions. WAIT.

EDGE CASE — If next file instructions arrive but no explicit
approval for the current ⏳ file:

- Stop and ask: "Current file [filename] is still pending
  approval. Approve it before I proceed?"
- Do not generate or write anything until confirmed.

---

## Full Build Plan

✅ adapters.txt — USB ID lookup table
✅ systemd/phev2mqtt.service — phev2mqtt systemd unit
✅ systemd/phev2mqtt-webui.service — web UI systemd unit
✅ config/journald.conf — journald disk limits
✅ config/logrotate.phev2mqtt-webui — web UI log rotation
✅ webui/requirements.txt — Python dependencies
✅ webui/config.py — encrypted config read/write
✅ webui/auth.py — bcrypt password, login_required decorator
✅ webui/app.py — Flask routes, first-run gate, session management
✅ webui/templates/first_run.html — mandatory password setup screen
✅ webui/templates/login.html — login form
✅ webui/templates/settings.html — settings page structure
✅ webui/templates/tools.html — terminal and tools page structure
✅ webui/services/wifi.py — wpa_supplicant connect/disconnect/status
✅ webui/services/mqtt.py — paho-mqtt connect/disconnect/status with auto-reconnect
✅ webui/services/phev.py — systemd service start/stop/restart/status via subprocess
✅ webui/services/emulator.py — MQTT emulator cycling 2 sensors every 5s, VIN required, off by default
✅ webui/services/resources.py — disk/RAM/CPU live metrics for resource monitor
✅ webui/routes/**init**.py — package marker
✅ webui/routes/api.py — all Flask JSON API endpoints consumed by the JS above
✅ webui/static/js/settings.js — all JS for settings page (WiFi, MQTT, resource polling, sliders, password change, SSH toggle, log download)
✅ webui/static/js/tools.js — emulator toggle+VIN validation, pre-built command send, xterm.js WebSocket connection
✅ webui/routes/terminal.py — WebSocket handler for xterm.js shell session
✅ install.sh — Proxmox host script (whiptail dialogs, VM creation, USB passthrough)
✅ vm-setup.sh — cloud-init VM setup script (driver install, phev2mqtt build, service registration)
✅ README.md — full project README per spec

Next to build: — none, build complete —

## Stack Rules — Never Deviate From These

**Backend:** Python with Flask or FastAPI. Never Django, never Node.js backend.

**Frontend:** Vanilla JavaScript or Alpine.js only. Never React, Vue, Angular, or any other framework.

**Terminal:** xterm.js with WebSocket backend (ttyd or custom). Never a simple textarea.

**Styling:** Minimal, clean light theme. No dark mode. No CSS frameworks like Bootstrap or Tailwind — keep it lean.

**Database/Config:** Encrypted config file or SQLite only. Never PostgreSQL, MySQL, or any remote database.

**Service management:** systemd only. Never Docker, never supervisord.

**OS:** Debian 12 (Bookworm) minimal only. Never Ubuntu, never Alpine, never containers.

---

## MCP Servers Available

Use these in Agent mode. Always use them proactively.

- **filesystem** — read/write project files. Path: `C:\Users\cosmi\Desktop\VS Code`
  Use to read existing files before modifying anything.
- **context7** — fetch live docs. Use before building any file involving
  Flask-Sock, pty, paho-mqtt, xterm.js, or any external library.
- **github** — search buxtronix/phev2mqtt source when building features
  that must match upstream behaviour (emulator, MQTT topics, commands).
- **memory** — persist facts across sessions.
- **awesome-copilot** — find community instructions for Flask, security, REST APIs.
- **playwright** — test the web UI at localhost when running.

### Rules for MCP usage in this project:

- Always read existing files via filesystem before editing them
- Always fetch library docs via context7 before using any external library
- Always check upstream source via github when behaviour must match phev2mqtt

---

## Absolute Security Rules

These are non-negotiable. Every generated file must comply:

1. **All passwords stored with bcrypt** — never plain text, never MD5, never SHA1 alone
2. **All sensitive config values encrypted at rest** — WiFi PSK, MQTT credentials, web UI password
3. **The web UI password must NEVER appear in any log file** — enforce at application level, not just redaction
4. **No default password exists** — the app is inaccessible until the user sets one via the first-run gate
5. **SSH and terminal access are server-side locked** when no password is set — not just hidden in UI
6. **Config files written atomically** — write to temp file, verify, then rename. Never write directly to the live config file
7. **Session tokens** must be cryptographically random and expire on browser close unless explicitly extended
8. **No sensitive data in URLs** — credentials never in query strings or URL parameters

---

## phev2mqtt Binary Path — Critical

The phev2mqtt binary **must always** be at `/usr/local/bin/phev2mqtt`. This is the canonical path set by the installer.

- All pre-built commands in the terminal panel use this path
- All systemd service files reference this path
- Never use relative paths like `./phev2mqtt` or paths like `/opt/phev2mqtt/phev2mqtt`
- The installer must create a symlink to this path if the binary ends up elsewhere

---

## File & Directory Structure

```
/opt/phev2mqtt-webui/          # Web UI application root
├── app.py                     # Main Flask/FastAPI application
├── config.py                  # Config management (encrypted)
├── requirements.txt
├── static/
│   ├── js/
│   └── css/
├── templates/
│   ├── first_run.html         # First-run security gate
│   ├── settings.html          # Page 1 — Settings & Status
│   └── tools.html             # Page 2 — Terminal & Tools
└── services/
    ├── wifi.py                # WiFi management (wpa_supplicant/NetworkManager)
    ├── mqtt.py                # MQTT connection management
    ├── phev.py                # phev2mqtt service management
    └── emulator.py            # Vehicle emulator

/etc/phev2mqtt-webui/          # Config directory
└── config.enc                 # Encrypted config file

/usr/local/bin/phev2mqtt       # phev2mqtt binary (canonical path)

/etc/systemd/system/
├── phev2mqtt.service          # phev2mqtt service
└── phev2mqtt-webui.service    # Web UI service

/etc/systemd/journald.conf.d/
└── phev2mqtt.conf             # journald limits

/etc/logrotate.d/
└── phev2mqtt-webui            # logrotate config for web UI logs
```

---

## systemd Service Patterns

All systemd services must follow the upstream phev2mqtt pattern:

```ini
[Unit]
Description=phev2mqtt service
After=network.target

[Service]
Type=exec
ExecStart=/usr/local/bin/phev2mqtt client mqtt --mqtt_server tcp://[server]:1883
Restart=always
RestartSec=30s
SyslogIdentifier=phev2mqtt
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
```

The web UI service must have `Restart=always` and `RestartSec=10s`.

---

## Log Management Rules

1. **journald cap:** `SystemMaxUse=200MB`, `SystemMaxFileSize=50MB`, `MaxRetentionSec=7day`, `SystemKeepFree=500MB`
2. **logrotate:** size-based rotation (not time-based), default 20MB per file, keep 5 rotated files, gzip compression
3. **Default log level:** `-v=info` for phev2mqtt — never `-v=debug` as default
4. **Four log levels exposed in UI:** `error`, `warn`, `info` (default), `debug`
5. **Logs can never be fully disabled** — they are the only diagnostic tool without SSH
6. **Log download obfuscation at download time only** — never modify stored logs

---

## Log Download Obfuscation

When generating a downloadable log file, always redact these values before writing the output:

| Data               | Replace with               |
| ------------------ | -------------------------- |
| WiFi SSID          | `[SSID REDACTED]`          |
| WiFi PSK           | `[WIFI PASSWORD REDACTED]` |
| MQTT username      | `[MQTT USER REDACTED]`     |
| MQTT password      | `[MQTT PASSWORD REDACTED]` |
| MAC addresses      | `[MAC REDACTED]`           |
| Local IP addresses | `[IP REDACTED]`            |
| VIN number         | `[VIN REDACTED]`           |

Use both exact-value matching (from config) and regex patterns for MACs, IPs, and VIN format. Include a context header in the downloaded file with version, OS, kernel, uptime, adapter, and log level.

---

## WiFi Management

- Use `wpa_supplicant` + `dhclient` or NetworkManager — whichever is simpler to script on Debian 12
- Auto-reconnect scan interval: configurable, default 30 seconds
- Car SSID format is typically `REMOTExxxxxx` — document this for users
- MAC address spoofing must persist across reboots via config
- WiFi region must be set and persist

---

## MQTT Topics Reference

These are the topics phev2mqtt publishes and subscribes to. Use this list for the vehicle emulator and any MQTT-related features:

**Published by phev2mqtt:**

- `phev/battery/level` — battery % (integer)
- `phev/charge/charging` — `on` / `off`
- `phev/charge/plug` — `unplugged` / `connected`
- `phev/charge/remaining` — minutes remaining (integer)
- `phev/door/locked` — `on` / `off`
- `phev/door/driver` — `open` / `closed`
- `phev/door/front_passenger` — `open` / `closed`
- `phev/door/bonnet` — `open` / `closed`
- `phev/door/boot` — `open` / `closed`
- `phev/lights/parking` — `on` / `off`
- `phev/lights/head` — `on` / `off`
- `phev/lights/hazard` — `on` / `off`
- `phev/lights/interior` — `on` / `off`
- `phev/climate/status` — `on` / `off`
- `phev/climate/mode` — `cool` / `heat` / `windscreen`
- `phev/available` — `online` / `offline`
- `phev/vin` — VIN string (store this when received)

**Subscribed by phev2mqtt (commands):**

- `phev/set/parkinglights` — `on` / `off`
- `phev/set/headlights` — `on` / `off`
- `phev/set/cancelchargetimer` — any payload
- `phev/set/climate/[cool|heat|windscreen]` — `on` / `off`
- `phev/connection` — `on` / `off` / `restart`

---

## Vehicle Emulator Rules

1. **Default state: OFF after every reboot/restart** — enforced, never persists enabled state across reboots
2. **Auto-disables immediately** if WiFi connects to the car — cannot run simultaneously with real car
3. **Requires VIN input** before enabling — no placeholder VINs
4. **VIN auto-populated** from stored `phev/vin` topic value if available, but field remains editable
5. **Two sensors only**, cycling one at a time every 5 seconds:
   - `phev/lights/parking` → `on` / `off` → entity: `light.phev_[VIN]_phev_park_lights`
   - `phev/door/locked` → `locked` / `unlocked` → entity: `binary_sensor.phev_[VIN]_phev_locked`
6. Entity ID format must match exactly what phev2mqtt HA discovery registers — check upstream source

---

## Installer Script Rules (Bash)

**Script 1 (host script):**

- Uses `whiptail` for all UI dialogs — never raw `echo` prompts for interactive choices
- Simple / Advanced mode choice at start
- Must query `qm list` for existing VMIDs before suggesting one
- Must validate VMID before proceeding — never proceed with a conflicting ID
- Must query `pvesm status` for storage pool selection
- Must detect USB adapters with `lsusb` and present a numbered selection list
- VM spec: 1 vCPU, 1GB RAM, 12GB disk, Debian 12 minimal cloud image
- Must clean up with `qm destroy` on any failure after VM creation starts
- Never prompts for MQTT, WiFi, or any application config — that's the web UI's job

**Script 2 (VM setup via cloud-init):**

- Runs headlessly on first boot
- Binary installed to `/usr/local/bin/phev2mqtt` — no exceptions
- Must configure journald limits as part of setup
- Must set phev2mqtt systemd service to `-v=info` — never `-v=debug`
- Must be idempotent — safe to re-run

**USB adapter lookup table format:**

```
# USB_ID      CHIPSET    DRIVER     NOTES
2357:0138     88x2bu     88x2bu     TP-Link Archer T3U Plus AC1300
```

---

## First-Run Security Gate Rules

1. No default password exists — app is inaccessible until password is set
2. Setup screen cannot be skipped or dismissed
3. Minimum password length: 8 characters with confirmation field
4. Mandatory warning with checkbox acknowledgement: _"There is no password recovery. If you lose your password, re-run the installer."_
5. SSH and terminal are locked server-side until password is set
6. Config written atomically on password save — temp file → verify → rename
7. Setup lock flag prevents race condition if two browsers hit setup simultaneously
8. If VM crashes mid-save and no valid password file exists on reboot → return to setup gate

---

## Update Manager Rules

**phev2mqtt updates:**

- Use GitHub API (`api.github.com/repos/buxtronix/phev2mqtt/commits`) — no auth token needed for public repos
- Store installed commit hash at install time for comparison
- Show commit messages since installed version
- Mandatory Proxmox snapshot warning + confirmation checkbox before updating
- Update process: `git pull` → `go build` → replace `/usr/local/bin/phev2mqtt` → `systemctl restart phev2mqtt`
- Stream progress to terminal window

**OS updates:**

- Check DKMS health and kernel headers before applying
- Detect if kernel update is included → warn reboot required → show reboot button
- After reboot, verify WiFi adapter and DKMS module are healthy
- Mandatory Proxmox snapshot warning + confirmation checkbox before updating
- Major Debian version upgrades explicitly out of scope — display permanent notice

---

## Resource Monitoring

Display live in Settings page, updating without page refresh:

| Resource    | Warning                 | Critical   |
| ----------- | ----------------------- | ---------- |
| Disk (root) | < 20% free              | < 10% free |
| RAM         | > 80% used              | > 90% used |
| CPU         | > 80% sustained for 60s | —          |

Brief CPU spikes (e.g. during Go compilation or DKMS builds) must not trigger warnings — only sustained high CPU should alert.

Summary alert shown at top of Settings page whenever any resource hits warning or critical state.

---

## Pre-built Terminal Commands

All commands use `/usr/local/bin/phev2mqtt` (canonical path). Never use relative paths.

| Label                 | Command                                   |
| --------------------- | ----------------------------------------- |
| Watch car data        | `phev2mqtt client watch`                  |
| Register with car     | `phev2mqtt client register`               |
| phev2mqtt logs (live) | `journalctl -u phev2mqtt -f -o cat`       |
| Web UI logs (live)    | `journalctl -u phev2mqtt-webui -f -o cat` |
| WiFi status           | `iw dev`                                  |
| System resource usage | `top`                                     |

---

## README Requirements

The README must include: one-line install command at top, supported USB adapter table, installation steps (5 steps), first-time setup walkthrough, updating instructions, troubleshooting section, contributing guide, GPL-3.0 licence, acknowledgements crediting buxtronix and community-scripts/ProxmoxVE.
