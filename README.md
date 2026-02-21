# phev2mqtt-vm

Automated Proxmox VM installer and web-based management interface for [phev2mqtt](https://github.com/buxtronix/phev2mqtt) — a Mitsubishi Outlander PHEV to MQTT gateway.

## What This Is

This project provides a **one-command Proxmox installer** that creates a fully configured Debian 12 KVM virtual machine running the [phev2mqtt](https://github.com/buxtronix/phev2mqtt) WiFi gateway with a web-based management interface.

**This is a setup and management tool, not a monitoring dashboard.** Home Assistant handles vehicle monitoring. The web UI helps you:

- Configure WiFi connection to your PHEV vehicle
- Set up MQTT broker credentials
- Manage the phev2mqtt service
- View live resource usage (CPU, RAM, disk)
- Access a terminal for troubleshooting
- Run pre-built phev2mqtt commands
- Enable a vehicle emulator for testing Home Assistant automations
- Change passwords and manage SSH access
- Download diagnostic logs

All credit for the phev2mqtt gateway goes to [buxtronix](https://github.com/buxtronix/phev2mqtt).

## Requirements

- **Proxmox VE 8.0+** (host system)
- **USB WiFi adapter** with supported chipset (see table below)
- **Mitsubishi Outlander PHEV** (2014+ model year)
- **MQTT broker** (e.g., Mosquitto running in Home Assistant)
- **Proxmox storage** configured to support snippets (for cloud-init)
- **200MB+ free disk space** on Proxmox host for VM disk image
- **Internet connection** on Proxmox host for downloading Debian cloud image and dependencies

## Supported USB WiFi Adapters

The installer detects your USB WiFi adapter and automatically installs the appropriate driver. Currently supported adapters:

| USB ID      | Chipset | Driver | Model / Notes                  |
| ----------- | ------- | ------ | ------------------------------ |
| `2357:0138` | 88x2bu  | 88x2bu | TP-Link Archer T3U Plus AC1300 |

**Choosing an adapter?** Not all USB WiFi adapters work well on Linux. Before purchasing, check that your adapter's chipset has a working Linux driver. The best-supported chipsets are **MT7612U** and **MT7921AU** (Mediatek) — both use plug-and-play in-kernel drivers with no compilation required. The **88x2bu** chipset (Realtek) also works but requires an out-of-kernel driver that the installer compiles automatically.

For a comprehensive, maintained chipset compatibility reference, see [morrownr/USB-WiFi](https://github.com/morrownr/USB-WiFi) on GitHub — the most authoritative Linux USB WiFi adapter resource available.

If you have tested an adapter and want to add it to the supported list, open a Pull Request with the USB ID, chipset, driver name, and adapter model in [`adapters.txt`](adapters.txt) format.

## Installation

**One-line install from your Proxmox VE host shell:**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/corautem/phev2mqtt-vm/main/install.sh)"
```

The installer will:

1. Detect all connected USB devices and show a numbered list
2. Validate your USB WiFi adapter chipset against the supported list
3. Prompt you to select a VMID (suggests lowest available)
4. Prompt you to select a Proxmox storage pool
5. Download the Debian 12 minimal cloud image (with SHA512 verification)
6. Create a KVM VM with 1 vCPU, 1GB RAM, 12GB disk
7. Pass through your selected USB WiFi adapter
8. Configure cloud-init to run the VM setup script
9. Start the VM

The VM will automatically install all dependencies, compile phev2mqtt from source, install the WiFi driver, and start the web UI service. **This takes 5-10 minutes.** Once complete, the web UI will be accessible at `http://<VM_IP>:8080`.

To find your VM's IP address:

```bash
qm guest cmd <VMID> network-get-interfaces
```

Or check the Proxmox web UI under VM → Summary → IPs.

## First-Time Setup

### 1. Set Your Password

On first access, you'll be forced to set a password. **There is no password recovery.** If you lose your password, you must re-run the installer.

### 2. Configure WiFi

Navigate to **Settings** and enter your PHEV's WiFi credentials:

- **SSID:** Typically `REMOTExxxxxx` (check your vehicle's WiFi settings)
- **Password:** WiFi password set in your PHEV's infotainment system
- **Region:** Your country code (e.g., `AU`, `US`, `GB`)
- **DHCP:** Leave enabled unless you need a static IP

Optional but recommended:

- **MAC Address Spoofing:** Some PHEVs only accept connections from trusted MAC addresses. If you've previously connected with a phone or laptop, copy that device's MAC address here.

Click **Connect** and wait 15-30 seconds. The status indicator will show "Connected" when successful.

### 3. Configure MQTT

Enter your MQTT broker details:

- **Server:** IP address or hostname of your MQTT broker (e.g., `192.168.1.100` or `homeassistant.local`)
- **Port:** Default is `1883` (use `8883` for TLS, but TLS support is manual — see Troubleshooting)
- **Username:** MQTT username (if required by your broker)
- **Password:** MQTT password (if required by your broker)

Click **Connect** and wait a few seconds. The status indicator will show "Connected" when successful.

### 4. Start phev2mqtt

Once both WiFi and MQTT are connected, click **Start** in the phev2mqtt Service section. The service will connect to your vehicle and begin publishing sensor data to your MQTT broker.

### 5. Register with Your Vehicle

To receive data from and send commands to your vehicle, you must register the phev2mqtt gateway with your car. Connecting to the car's WiFi network is not enough on its own — registration must complete successfully before any MQTT data flows.

Navigate to **Tools** and click the **Register with car** button (or run `phev2mqtt client register` in the terminal).

If registration succeeds, phev2mqtt will begin publishing vehicle data to your MQTT broker. If it fails, check that:

- You are connected to the car's WiFi network (Settings → WiFi)
- The phev2mqtt service is running
- No other registration attempt is in progress
- Your WiFi signal strength is adequate — registration can fail if the signal is too weak even when the connection appears active. Try moving closer to the vehicle if registration repeatedly fails.

Once registered successfully, you'll be able to receive vehicle data and send commands via MQTT.

## Updating

### phev2mqtt Updates

The web UI includes an **Update Manager** (Settings → Updates) that checks for new commits in the upstream [buxtronix/phev2mqtt](https://github.com/buxtronix/phev2mqtt) repository.

**Before updating:**

1. **Take a Proxmox snapshot** of your VM (Proxmox UI → VM → Snapshots → Take Snapshot)
2. Review the commit messages shown in the update panel
3. Check the mandatory confirmation box acknowledging the snapshot warning
4. Click **Update**

The update process will:

1. Pull the latest code from GitHub
2. Rebuild the phev2mqtt binary
3. Replace `/usr/local/bin/phev2mqtt`
4. Restart the phev2mqtt service

Progress is streamed to the terminal window. If the update fails, restore your snapshot.

### OS Updates

The Update Manager also checks for Debian security updates.

**Before updating:**

1. **Take a Proxmox snapshot** of your VM
2. Check if a kernel update is included (indicated in the update panel)
3. Check the mandatory confirmation box acknowledging the snapshot warning
4. Click **Update OS**

If a kernel update is included, you'll be prompted to reboot after the update completes. The system will verify WiFi driver health after reboot.

**Major Debian version upgrades (e.g., Debian 12 → 13) are out of scope and not supported.** A permanent notice is displayed in the Update Manager.

## Troubleshooting

### 1. WiFi won't connect

- **Check SSID and password:** PHEV SSIDs are typically `REMOTExxxxxx` (case-sensitive).
- **Check WiFi region:** Must match your country code (`iw reg get` in the terminal).
- **Check MAC address:** Some PHEVs require MAC address spoofing to match a previously trusted device.
- **Check USB passthrough:** Run `lsusb` in the VM terminal to verify your WiFi adapter is visible.
- **Check driver installation:** Run `lsmod | grep 88x2bu` (or your driver name) to verify the driver is loaded.
- **Check logs:** Download logs from Settings → Log Management or run `journalctl -u phev2mqtt -f` in the terminal.

### 2. MQTT won't connect

- **Check broker reachability:** Run `ping <mqtt_server>` in the terminal to verify network connectivity.
- **Check broker port:** Default is `1883`. Verify with your MQTT broker configuration.
- **Check credentials:** Verify username/password with your MQTT broker admin interface.
- **Check TLS:** If using port `8883`, you must manually configure TLS certificates (not supported by web UI).
- **Check logs:** Download logs from Settings → Log Management or run `journalctl -u phev2mqtt-webui -f` in the terminal.

### 3. phev2mqtt service won't start

- **Check WiFi and MQTT:** Both must be connected before starting the service.
- **Check configuration:** Settings → Tools → Pre-built Commands → "Watch car data" to verify the config file is valid.
- **Check binary:** Run `/usr/local/bin/phev2mqtt client watch` in the terminal to test the binary directly.
- **Check logs:** Download logs from Settings → Log Management or run `journalctl -u phev2mqtt -f` in the terminal.

### 4. Can't register with vehicle

- **Check phev2mqtt service:** Must be running before registration.
- **Check WiFi connection:** Must be connected to the car's WiFi network, not just in range.
- **Check signal strength:** Registration can fail if the WiFi signal is too weak even when the connection appears active. Try moving the Proxmox host or USB adapter closer to the vehicle.
- **Check logs:** Run `journalctl -u phev2mqtt -f` in the terminal during a registration attempt to see exactly where it fails.

### 5. Resource monitor shows critical warnings

- **Disk space:** If root partition < 10% free, check logs for excessive journald usage (`journalctl --disk-usage`) or clear old logs (`journalctl --vacuum-time=2d`).
- **RAM:** 1GB is sufficient for normal operation. High RAM usage may indicate a memory leak (restart phev2mqtt service).
- **CPU:** Sustained high CPU (>80% for 60s+) is abnormal. Check for runaway processes with `top` in the terminal.

### 6. Forgot web UI password

**There is no password recovery.** You must re-run the installer. This will destroy and recreate the VM — take a Proxmox snapshot first if you want any chance of recovery.

Re-running the installer will reset all settings. Your Home Assistant entities will need to be reconfigured after reinstall.

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

**Areas where contributions are especially welcome:**

- Additional USB WiFi adapter support (add to `adapters.txt` with tested driver)
- TLS/SSL support for MQTT connections
- Multi-language support for web UI
- Additional pre-built terminal commands
- Home Assistant blueprint examples
- Documentation improvements

## License

This project is licensed under the **GNU General Public License v3.0** (GPL-3.0).

You are free to use, modify, and distribute this software under the terms of the GPL-3.0 license. See the [LICENSE](LICENSE) file for full details.

**Note:** The upstream [phev2mqtt](https://github.com/buxtronix/phev2mqtt) project is also licensed under GPL-3.0.

## Acknowledgements

This project would not be possible without the following:

- **[buxtronix](https://github.com/buxtronix)** — Creator of the original [phev2mqtt](https://github.com/buxtronix/phev2mqtt) gateway. All phev2mqtt functionality and protocol implementation is their work.
- **[tteck](https://github.com/tteck)** and the **[Proxmox VE Helper Scripts](https://github.com/tteck/Proxmox)** project — Inspiration for the whiptail-based installer UI pattern and cloud-init VM creation approach.
- **[Claude](https://www.anthropic.com/claude)** — AI assistant by Anthropic, used for code generation and architectural design.
- **[GitHub Copilot](https://github.com/features/copilot)** — AI pair programmer by GitHub, used extensively throughout development.

---

**Disclaimer:** This is an unofficial third-party tool. It is not affiliated with, endorsed by, or supported by Mitsubishi Motors Corporation. Use at your own risk.
