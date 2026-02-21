"""Systemd service management for phev2mqtt."""

from __future__ import annotations

import os
import re
import tempfile
import time
from typing import Dict

import subprocess

SERVICE_NAME = "phev2mqtt"
SERVICE_PATH = "/etc/systemd/system/phev2mqtt.service"
VALID_LOG_LEVELS = {"error", "warn", "info", "debug"}


def _run(args: list[str], timeout: int = 10) -> subprocess.CompletedProcess:
    """Run a subprocess command with a timeout and captured output."""
    return subprocess.run(
        args,
        check=False,
        timeout=timeout,
        capture_output=True,
        text=True,
    )


def start() -> bool:
    """Start the phev2mqtt systemd service."""
    result = _run(["systemctl", "start", SERVICE_NAME], timeout=10)
    return result.returncode == 0


def stop() -> bool:
    """Stop the phev2mqtt systemd service."""
    result = _run(["systemctl", "stop", SERVICE_NAME], timeout=10)
    return result.returncode == 0


def restart() -> bool:
    """Restart the phev2mqtt systemd service."""
    result = _run(["systemctl", "restart", SERVICE_NAME], timeout=15)
    return result.returncode == 0


def status() -> Dict[str, int | bool]:
    """Return service status including running state, uptime, and PID."""
    show = _run(
        [
            "systemctl",
            "show",
            SERVICE_NAME,
            "-p",
            "ActiveState",
            "-p",
            "MainPID",
            "-p",
            "ExecMainStartTimestampMonotonic",
        ],
        timeout=5,
    )

    active_state = ""
    pid = 0
    start_mono = 0
    for line in show.stdout.splitlines():
        if line.startswith("ActiveState="):
            active_state = line.split("=", 1)[1].strip()
        elif line.startswith("MainPID="):
            try:
                pid = int(line.split("=", 1)[1])
            except ValueError:
                pid = 0
        elif line.startswith("ExecMainStartTimestampMonotonic="):
            try:
                start_mono = int(line.split("=", 1)[1])
            except ValueError:
                start_mono = 0

    running = active_state == "active" and pid > 0
    uptime_seconds = 0
    if running and start_mono > 0:
        try:
            with open("/proc/uptime", "r", encoding="utf-8") as uptime_file:
                uptime_total = float(uptime_file.read().split()[0])
            start_seconds = start_mono / 1_000_000
            uptime_seconds = max(0, int(uptime_total - start_seconds))
        except (OSError, ValueError):
            uptime_seconds = 0

    return {
        "running": running,
        "uptime_seconds": uptime_seconds,
        "pid": pid,
    }


def _read_service_file() -> str:
    """Read the systemd service file content."""
    with open(SERVICE_PATH, "r", encoding="utf-8") as service_file:
        return service_file.read()


def _write_service_file_atomic(content: str) -> None:
    """Atomically write the systemd service file."""
    service_dir = os.path.dirname(SERVICE_PATH)
    os.makedirs(service_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="phev2mqtt.", dir=service_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(content)
            tmp_file.flush()
            os.fsync(tmp_file.fileno())

        with open(tmp_path, "r", encoding="utf-8") as verify_file:
            verify_file.read()

        os.replace(tmp_path, SERVICE_PATH)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def set_log_level(level: str) -> bool:
    """Update the phev2mqtt log level and restart the service."""
    if level not in VALID_LOG_LEVELS:
        return False

    try:
        content = _read_service_file()
    except OSError:
        return False

    updated, count = re.subn(
        r"-v=(error|warn|info|debug)", f"-v={level}", content)
    if count == 0:
        return False

    try:
        _write_service_file_atomic(updated)
    except OSError:
        return False

    _run(["systemctl", "daemon-reload"], timeout=10)
    result = _run(["systemctl", "restart", SERVICE_NAME], timeout=15)
    return result.returncode == 0
