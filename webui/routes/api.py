"""JSON API endpoints for the phev2mqtt web UI frontend."""

from __future__ import annotations

import base64
import io
import json
import logging
import re
import subprocess
import tempfile
import time
from datetime import datetime
from typing import Any, Dict, Optional

from flask import Blueprint, request, session, jsonify, send_file
from flask.typing import ResponseReturnValue

from config import (
    get_secret,
    load_config,
    save_config,
    set_secret,
    is_configured,
    SENSITIVE_KEYS,
)
from auth import (
    login_required,
    change_password,
    is_configured as auth_is_configured,
    terminal_allowed,
    ssh_allowed,
)
import services.emulator as emulator
import services.mqtt as mqtt
import services.phev as phev
import services.resources as resources
import services.wifi as wifi

api = Blueprint("api", __name__, url_prefix="/api")

logger = logging.getLogger(__name__)


@api.errorhandler(Exception)
def handle_error(error: Exception) -> tuple[Dict[str, str], int]:
    """Return JSON error responses."""
    logger.error(f"API error: {error}")
    return {"error": str(error)}, 500


# ============================================================================
# WiFi Management
# ============================================================================


@api.get("/wifi/interfaces")
@login_required
def wifi_list_interfaces() -> ResponseReturnValue:
    """List available wireless interfaces."""
    interfaces = wifi.list_interfaces()
    return jsonify({"interfaces": interfaces})


@api.post("/wifi/scan")
@login_required
def wifi_scan() -> ResponseReturnValue:
    """Scan for nearby SSIDs on the specified interface."""
    data = request.get_json() or {}
    interface = data.get("interface", "")
    if not interface:
        return jsonify({"error": "interface required"}), 400

    ssids = wifi.scan(interface)
    return jsonify({"ssids": ssids})


@api.post("/wifi/connect")
@login_required
def wifi_connect() -> ResponseReturnValue:
    """Connect to a WiFi network."""
    data = request.get_json() or {}
    interface = data.get("interface", "")
    ssid = data.get("ssid", "")
    psk = data.get("psk")
    dhcp = data.get("dhcp", True)
    ip = data.get("ip")
    netmask = data.get("netmask")
    gateway = data.get("gateway")
    mac = data.get("mac")
    region = data.get("region")

    if not interface or not ssid:
        return jsonify({"error": "interface and ssid required"}), 400

    success = wifi.connect(
        interface=interface,
        ssid=ssid,
        psk=psk,
        dhcp=dhcp,
        ip=ip,
        netmask=netmask,
        gateway=gateway,
        mac=mac,
        region=region,
    )

    cfg = load_config()
    cfg["wifi_ssid"] = ssid
    cfg["wifi_interface"] = interface
    cfg["wifi_mac_spoof"] = mac or ""
    cfg["wifi_region"] = region or ""
    save_config(cfg)

    if psk:
        set_secret("wifi_psk", psk)

    return jsonify({"success": success})


@api.post("/wifi/disconnect")
@login_required
def wifi_disconnect() -> ResponseReturnValue:
    """Disconnect from WiFi."""
    data = request.get_json() or {}
    interface = data.get("interface", "")

    if not interface:
        return jsonify({"error": "interface required"}), 400

    success = wifi.disconnect(interface)
    return jsonify({"success": success})


@api.get("/wifi/status")
@login_required
def wifi_status() -> ResponseReturnValue:
    """Get WiFi connection status."""
    cfg = load_config()
    interface = cfg.get("wifi_interface", "")

    if not interface:
        return jsonify({
            "connected": False,
            "interface": "",
            "ssid": "",
            "ip": "",
            "gateway": "",
            "mac": "",
            "rssi": "",
        })

    status = wifi.status(interface)
    return jsonify({
        "connected": status.get("connected", False),
        "interface": interface,
        "ssid": status.get("ssid", ""),
        "ip": status.get("ip", ""),
        "gateway": status.get("gateway", ""),
        "mac": status.get("mac", ""),
        "rssi": status.get("rssi", ""),
    })


# ============================================================================
# MQTT Management
# ============================================================================


@api.post("/mqtt/connect")
@login_required
def mqtt_connect_endpoint() -> ResponseReturnValue:
    """Connect to MQTT broker with stored credentials."""
    data = request.get_json() or {}
    server = data.get("server", "")
    port = data.get("port", 1883)
    username = data.get("username", "")
    password = data.get("password", "")

    if not server or port <= 0:
        return jsonify({"error": "server and valid port required"}), 400

    cfg = load_config()
    cfg["mqtt_server"] = server
    cfg["mqtt_port"] = port
    save_config(cfg)

    if username:
        set_secret("mqtt_username", username)
    if password:
        set_secret("mqtt_password", password)

    success = mqtt.connect(server, port, username or None, password or None)
    return jsonify({"success": success})


@api.post("/mqtt/disconnect")
@login_required
def mqtt_disconnect_endpoint() -> ResponseReturnValue:
    """Disconnect from MQTT broker."""
    success = mqtt.disconnect()
    return jsonify({"success": success})


@api.get("/mqtt/status")
@login_required
def mqtt_status_endpoint() -> ResponseReturnValue:
    """Get MQTT connection status."""
    state = mqtt.status()
    return jsonify(state)


# ============================================================================
# phev2mqtt Service Control
# ============================================================================


@api.post("/phev/start")
@login_required
def phev_start() -> ResponseReturnValue:
    """Start the phev2mqtt systemd service."""
    success = phev.start()
    return jsonify({"success": success})


@api.post("/phev/stop")
@login_required
def phev_stop() -> ResponseReturnValue:
    """Stop the phev2mqtt systemd service."""
    success = phev.stop()
    return jsonify({"success": success})


@api.post("/phev/restart")
@login_required
def phev_restart() -> ResponseReturnValue:
    """Restart the phev2mqtt systemd service."""
    success = phev.restart()
    return jsonify({"success": success})


@api.get("/phev/status")
@login_required
def phev_status_endpoint() -> ResponseReturnValue:
    """Get phev2mqtt service status."""
    state = phev.status()
    return jsonify(state)


@api.post("/phev/set-log-level")
@login_required
def phev_set_log_level() -> ResponseReturnValue:
    """Change the phev2mqtt service log level and restart."""
    data = request.get_json() or {}
    level = data.get("level", "")

    if level not in phev.VALID_LOG_LEVELS:
        return jsonify({"error": "invalid log level"}), 400

    success = phev.set_log_level(level)
    cfg = load_config()
    cfg["log_level"] = level
    save_config(cfg)

    return jsonify({"success": success})


# ============================================================================
# Configuration Management
# ============================================================================


@api.get("/config/get")
@login_required
def config_get() -> ResponseReturnValue:
    """Retrieve non-secret config values."""
    cfg = load_config()
    safe_cfg = {
        k: v for k, v in cfg.items()
        if k not in SENSITIVE_KEYS and k != "secrets"
    }
    return jsonify(safe_cfg)


@api.post("/config/set")
@login_required
def config_set() -> ResponseReturnValue:
    """Update config values (non-secret)."""
    data = request.get_json() or {}
    cfg = load_config()

    for key, value in data.items():
        if key not in SENSITIVE_KEYS and key != "secrets":
            cfg[key] = value

    save_config(cfg)
    return jsonify({"success": True})


@api.post("/auth/change-password")
@login_required
def change_password_endpoint() -> ResponseReturnValue:
    """Change the web UI password."""
    data = request.get_json() or {}
    old_password = data.get("old_password", "")
    new_password = data.get("new_password", "")

    if not old_password or not new_password:
        return jsonify({"error": "both passwords required"}), 400

    success = change_password(old_password, new_password)
    if not success:
        return jsonify({"error": "invalid old password or too short"}), 401

    return jsonify({"success": True})


@api.post("/ssh/toggle")
@login_required
def ssh_toggle() -> ResponseReturnValue:
    """Toggle SSH access (requires password set)."""
    if not ssh_allowed():
        return jsonify({"error": "SSH locked until password is set"}), 403

    data = request.get_json() or {}
    enabled = data.get("enabled", False)

    cfg = load_config()
    cfg["ssh_enabled"] = enabled
    save_config(cfg)

    return jsonify({"success": True, "ssh_enabled": enabled})


# ============================================================================
# Emulator Control
# ============================================================================


@api.post("/emulator/enable")
@login_required
def emulator_enable() -> ResponseReturnValue:
    """Enable the MQTT vehicle emulator."""
    if not auth_is_configured():
        return jsonify({"error": "password not set"}), 403

    data = request.get_json() or {}
    vin = data.get("vin", "").strip().upper()

    if not vin or len(vin) != 17:
        return jsonify({"error": "valid 17-char VIN required"}), 400

    success = emulator.enable(vin)
    if success:
        cfg = load_config()
        cfg["phev_vin"] = vin
        cfg["emulator_enabled"] = True
        save_config(cfg)

    return jsonify({"success": success})


@api.post("/emulator/disable")
@login_required
def emulator_disable() -> ResponseReturnValue:
    """Disable the MQTT vehicle emulator."""
    success = emulator.disable()
    return jsonify({"success": success})


@api.get("/emulator/status")
@login_required
def emulator_status_endpoint() -> ResponseReturnValue:
    """Get emulator running status."""
    running = emulator.is_running()
    cfg = load_config()
    vin = cfg.get("phev_vin", "")
    return jsonify({"running": running, "vin": vin})


# ============================================================================
# Resource Monitoring
# ============================================================================


@api.get("/resources/snapshot")
@login_required
def resources_snapshot() -> ResponseReturnValue:
    """Get current disk, RAM, and CPU usage."""
    snapshot = resources.snapshot()
    snapshot["timestamp"] = datetime.now().isoformat()
    return jsonify(snapshot)


@api.get("/resources/thresholds")
@login_required
def resources_thresholds() -> ResponseReturnValue:
    """Get resource warning and critical thresholds."""
    thresholds = {
        "disk": {
            "warning_free_percent": 20,
            "critical_free_percent": 10,
        },
        "ram": {
            "warning_used_percent": 80,
            "critical_used_percent": 90,
        },
        "cpu": {
            "warning_percent": 80,
        },
    }
    return jsonify(thresholds)


# ============================================================================
# Log Management
# ============================================================================


@api.get("/logs/download")
@login_required
def logs_download() -> ResponseReturnValue:
    """Download logs with sensitive data redacted."""
    cfg = load_config()
    level = cfg.get("log_level", "info")

    # Retrieve logs from both services
    phev_logs = ""
    webui_logs = ""

    try:
        result = subprocess.run(
            ["journalctl", "-u", "phev2mqtt", "-o", "cat", "-n", "500"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        phev_logs = result.stdout
    except Exception as e:
        phev_logs = f"Error retrieving phev2mqtt logs: {e}"

    try:
        result = subprocess.run(
            ["journalctl", "-u", "phev2mqtt-webui", "-o", "cat", "-n", "500"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        webui_logs = result.stdout
    except Exception as e:
        webui_logs = f"Error retrieving phev2mqtt-webui logs: {e}"

    # Build log sections
    logs_content = (
        "=== phev2mqtt Service Logs ===\n"
        + phev_logs
        + "\n\n=== phev2mqtt-webui Service Logs ===\n"
        + webui_logs
    )

    redacted = _redact_sensitive_data(logs_content, cfg)
    header = _build_log_header(cfg)

    output = f"{header}\n\n{redacted}"

    buffer = io.BytesIO(output.encode("utf-8"))
    return send_file(
        buffer,
        mimetype="text/plain",
        as_attachment=True,
        download_name=f"phev2mqtt-webui-logs-{int(time.time())}.txt",
    )


def _redact_sensitive_data(logs: str, cfg: Dict[str, Any]) -> str:
    """Redact sensitive data from log content."""
    redacted = logs

    ssid = cfg.get("wifi_ssid", "")
    if ssid:
        redacted = redacted.replace(ssid, "[SSID REDACTED]")

    try:
        wifi_psk = get_secret("wifi_psk")
        if wifi_psk:
            redacted = redacted.replace(wifi_psk, "[WIFI PASSWORD REDACTED]")
    except Exception:
        pass

    try:
        mqtt_user = get_secret("mqtt_username")
        if mqtt_user:
            redacted = redacted.replace(mqtt_user, "[MQTT USER REDACTED]")
    except Exception:
        pass

    try:
        mqtt_pass = get_secret("mqtt_password")
        if mqtt_pass:
            redacted = redacted.replace(mqtt_pass, "[MQTT PASSWORD REDACTED]")
    except Exception:
        pass

    vin = cfg.get("phev_vin", "")
    if vin:
        redacted = redacted.replace(vin, "[VIN REDACTED]")

    redacted = re.sub(
        r"([0-9a-f]{2}:){5}[0-9a-f]{2}",
        "[MAC REDACTED]",
        redacted,
        flags=re.IGNORECASE
    )
    redacted = re.sub(
        r"\b(?:\d{1,3}\.){3}\d{1,3}\b",
        "[IP REDACTED]",
        redacted
    )

    return redacted


def _build_log_header(cfg: Dict[str, Any]) -> str:
    """Build a log file header with system context."""
    try:
        with open("/etc/os-release", "r") as f:
            os_info = dict(line.split("=", 1) for line in f if "=" in line)
        os_name = os_info.get("PRETTY_NAME", "Unknown").strip('"')
    except Exception:
        os_name = "Unknown"

    try:
        with open("/proc/version", "r") as f:
            kernel = f.read().split("#")[0].strip()
    except Exception:
        kernel = "Unknown"

    try:
        with open("/proc/uptime", "r") as f:
            uptime = int(float(f.read().split()[0]))
            uptime_str = f"{uptime // 3600}h {(uptime % 3600) // 60}m"
    except Exception:
        uptime_str = "Unknown"

    log_level = cfg.get("log_level", "info")

    header_lines = [
        "=== phev2mqtt-webui Log Download ===",
        f"Downloaded: {datetime.now().isoformat()}",
        f"OS: {os_name}",
        f"Kernel: {kernel}",
        f"Uptime: {uptime_str}",
        f"Log Level: {log_level}",
        "===================================",
    ]
    return "\n".join(header_lines)


@api.post("/logs/clear")
@login_required
def logs_clear() -> ResponseReturnValue:
    """Clear phev2mqtt journal and rotate web UI logs."""
    try:
        subprocess.run(
            ["journalctl", "--vacuum-time=1s", "--unit=phev2mqtt"],
            capture_output=True,
            timeout=10,
        )
        subprocess.run(
            ["logrotate", "-f", "/etc/logrotate.d/phev2mqtt-webui"],
            capture_output=True,
            timeout=10,
        )
        return jsonify({"success": True})
    except Exception as e:
        logger.error(f"Failed to clear logs: {e}")
        return jsonify({"error": str(e)}), 500


# ============================================================================
# Terminal Pre-built Commands
# ============================================================================


@api.get("/terminal/commands")
@login_required
def terminal_commands() -> ResponseReturnValue:
    """Get list of pre-built terminal commands."""
    commands = [
        {
            "label": "Watch car data",
            "command": "/usr/local/bin/phev2mqtt client watch",
        },
        {
            "label": "Register with car",
            "command": "/usr/local/bin/phev2mqtt client register",
        },
        {
            "label": "phev2mqtt logs (live)",
            "command": "journalctl -u phev2mqtt -f -o cat",
        },
        {
            "label": "Web UI logs (live)",
            "command": "journalctl -u phev2mqtt-webui -f -o cat",
        },
        {
            "label": "WiFi status",
            "command": "iw dev",
        },
        {
            "label": "System resource usage",
            "command": "top",
        },
    ]
    return jsonify({"commands": commands})


@api.post("/terminal/send-command")
@login_required
def terminal_send_command() -> ResponseReturnValue:
    """Send a pre-built command to the terminal (requires active WebSocket)."""
    data = request.get_json() or {}
    command = data.get("command", "")

    if not command:
        return jsonify({"error": "command required"}), 400

    if not terminal_allowed():
        return jsonify({"error": "Terminal access locked"}), 403

    return jsonify({
        "success": True,
        "message": f"Command queued: {command}",
    })
