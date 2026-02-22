"""MQTT-based vehicle emulator for testing Home Assistant integration."""

from __future__ import annotations

import threading
import time
from typing import Optional

from services import mqtt


_lock = threading.Lock()
_stop_event = threading.Event()
_thread: Optional[threading.Thread] = None

_running = False
_vin = ""


def enable(vin: str) -> bool:
    """Enable the emulator with the provided VIN and start the cycle thread."""
    global _running, _vin, _thread
    if not vin:
        return False

    with _lock:
        if _running:
            return False
        _vin = vin
        _running = True
        _stop_event.clear()
        _thread = threading.Thread(
            target=_run_cycle, name="mqtt-emulator", daemon=True)
        _thread.start()

    return True


def disable() -> bool:
    """Disable the emulator and stop the cycle thread."""
    global _running
    with _lock:
        if not _running:
            return False
        _running = False
        _stop_event.set()

    return True


def auto_disable() -> bool:
    """Disable the emulator when car WiFi connects."""
    return disable()


def is_running() -> bool:
    """Return True when the emulator is currently running."""
    with _lock:
        return _running


def _run_cycle() -> None:
    """Publish alternating test sensor values every 5 seconds."""
    tick = 0
    while not _stop_event.is_set():
        with _lock:
            vin = _vin
            running = _running
        if not running:
            break

        if tick % 2 == 0:
            topic = "phev/lights/parking"
            payload = "on" if (tick // 2) % 2 == 0 else "off"
        else:
            topic = "phev/door/locked"
            payload = "locked" if (tick // 2) % 2 == 0 else "unlocked"

        _publish(topic, payload, vin)
        tick += 1
        _stop_event.wait(5.0)


def _publish(topic: str, payload: str, vin: str) -> None:
    """Publish a test message through the shared MQTT client."""
    if not vin:
        return
    mqtt.publish(topic, payload)
