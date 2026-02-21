"""WiFi management using wpa_supplicant on Debian 12."""

from __future__ import annotations

import os
import re
import tempfile
from dataclasses import dataclass
from typing import List, Optional

import subprocess

WPA_DIR = "/etc/wpa_supplicant"
WPA_CONF_TEMPLATE = "wpa_supplicant-{iface}.conf"


@dataclass
class WifiStatus:
    """Container for WiFi status details."""

    connected: bool
    ssid: str
    ip: str
    gateway: str
    mac: str
    rssi: str


def _run(args: List[str], timeout: int = 10) -> subprocess.CompletedProcess:
    """Run a subprocess command with a timeout and captured output."""
    return subprocess.run(
        args,
        check=False,
        timeout=timeout,
        capture_output=True,
        text=True,
    )


def _iface_config_path(interface: str) -> str:
    """Return the path to the interface-specific wpa_supplicant config."""
    filename = WPA_CONF_TEMPLATE.format(iface=interface)
    return os.path.join(WPA_DIR, filename)


def list_interfaces() -> List[str]:
    """Return a list of wireless interface names."""
    result = _run(["iw", "dev"], timeout=5)
    interfaces: List[str] = []
    for line in result.stdout.splitlines():
        match = re.search(r"^\s*Interface\s+(\S+)", line)
        if match:
            interfaces.append(match.group(1))
    return interfaces


def scan(interface: str) -> List[str]:
    """Scan for nearby SSIDs on the given interface."""
    result = _run(["iw", "dev", interface, "scan"], timeout=15)
    ssids: List[str] = []
    for line in result.stdout.splitlines():
        if "SSID:" in line:
            ssid = line.split("SSID:", 1)[1].strip()
            if ssid and ssid not in ssids:
                ssids.append(ssid)
    return ssids


def _generate_wpa_config(ssid: str, psk: Optional[str]) -> str:
    """Generate a minimal wpa_supplicant config for the SSID."""
    if not psk:
        network = [
            "network={",
            f'    ssid="{ssid}"',
            "    key_mgmt=NONE",
            "}",
        ]
        return "\n".join(["ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev", "update_config=1"] + network) + "\n"

    passphrase = _run(["wpa_passphrase", ssid, psk], timeout=5)
    lines = []
    for line in passphrase.stdout.splitlines():
        if line.strip().startswith("#psk="):
            continue
        lines.append(line)
    header = ["ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev",
              "update_config=1"]
    return "\n".join(header + lines) + "\n"


def _write_wpa_config_atomic(path: str, content: str) -> None:
    """Atomically write the wpa_supplicant config file."""
    os.makedirs(WPA_DIR, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="wpa.", dir=WPA_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(content)
            tmp_file.flush()
            os.fsync(tmp_file.fileno())

        with open(tmp_path, "r", encoding="utf-8") as verify_file:
            verify_file.read()

        os.replace(tmp_path, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def _set_region(region: Optional[str]) -> None:
    """Set the WiFi regulatory region if provided."""
    if not region:
        return
    _run(["iw", "reg", "set", region], timeout=5)


def _apply_mac(interface: str, mac: Optional[str]) -> None:
    """Apply MAC spoofing if a MAC address is provided."""
    if not mac:
        return
    _run(["ip", "link", "set", interface, "down"], timeout=5)
    _run(["ip", "link", "set", interface, "address", mac], timeout=5)
    _run(["ip", "link", "set", interface, "up"], timeout=5)


def _restart_wpa(interface: str, config_path: str) -> None:
    """Restart wpa_supplicant for the given interface."""
    _run(["pkill", "-f", f"wpa_supplicant.*-i {interface}"])  # best-effort
    _run(["wpa_supplicant", "-B", "-i", interface, "-c", config_path], timeout=10)


def connect(
    interface: str,
    ssid: str,
    psk: Optional[str],
    dhcp: bool = True,
    ip: Optional[str] = None,
    netmask: Optional[str] = None,
    gateway: Optional[str] = None,
    mac: Optional[str] = None,
    region: Optional[str] = None,
) -> bool:
    """Connect to the given SSID using wpa_supplicant and DHCP or static IP."""
    if not interface or not ssid:
        return False

    _set_region(region)
    _apply_mac(interface, mac)

    config_path = _iface_config_path(interface)
    config_content = _generate_wpa_config(ssid, psk)
    _write_wpa_config_atomic(config_path, config_content)

    _restart_wpa(interface, config_path)

    if dhcp:
        _run(["dhclient", "-r", interface], timeout=10)
        _run(["dhclient", interface], timeout=15)
        return True

    if not ip or not netmask or not gateway:
        return False

    _run(["ip", "addr", "flush", "dev", interface], timeout=5)
    _run(["ip", "addr", "add", f"{ip}/{netmask}", "dev", interface], timeout=5)
    _run(["ip", "route", "replace", "default", "via",
         gateway, "dev", interface], timeout=5)
    return True


def disconnect(interface: str) -> bool:
    """Disconnect the given interface by stopping wpa_supplicant and DHCP."""
    if not interface:
        return False

    _run(["dhclient", "-r", interface], timeout=10)
    _run(["pkill", "-f", f"wpa_supplicant.*-i {interface}"])
    return True


def status(interface: str) -> dict:
    """Return a status dict for the given interface."""
    if not interface:
        return {
            "connected": False,
            "ssid": "",
            "ip": "",
            "gateway": "",
            "mac": "",
            "rssi": "",
        }

    link = _run(["iw", "dev", interface, "link"], timeout=5)
    connected = "Connected to" in link.stdout
    ssid = ""
    rssi = ""
    for line in link.stdout.splitlines():
        if line.strip().startswith("SSID:"):
            ssid = line.split("SSID:", 1)[1].strip()
        if "signal:" in line:
            rssi = line.split("signal:", 1)[1].strip()

    ip_addr = ""
    ip_info = _run(["ip", "-4", "addr", "show", interface], timeout=5)
    for line in ip_info.stdout.splitlines():
        if "inet " in line:
            ip_addr = line.strip().split()[1].split("/")[0]
            break

    gateway = ""
    route_info = _run(["ip", "route", "show", "default",
                      "dev", interface], timeout=5)
    for line in route_info.stdout.splitlines():
        parts = line.split()
        if "via" in parts:
            gateway = parts[parts.index("via") + 1]
            break

    mac = ""
    try:
        with open(f"/sys/class/net/{interface}/address", "r", encoding="utf-8") as mac_file:
            mac = mac_file.read().strip()
    except OSError:
        mac = ""

    return {
        "connected": connected,
        "ssid": ssid,
        "ip": ip_addr,
        "gateway": gateway,
        "mac": mac,
        "rssi": rssi,
    }
