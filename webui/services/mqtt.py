"""MQTT connection management using paho-mqtt."""

from __future__ import annotations

import threading
import time
from typing import Dict, Optional

import paho.mqtt.client as mqtt
from paho.mqtt.client import CallbackAPIVersion


_lock = threading.Lock()
_stop_event = threading.Event()
_reconnect_thread: Optional[threading.Thread] = None

_client: Optional[mqtt.Client] = None
_loop_running = False

_state: Dict[str, object] = {
    "connected": False,
    "broker": "",
    "port": 0,
    "uptime_start": None,
}


def _set_connected(connected: bool) -> None:
    """Update connection state and uptime tracking."""
    with _lock:
        _state["connected"] = connected
        _state["uptime_start"] = time.monotonic() if connected else None


def _on_connect(
    client: mqtt.Client,
    userdata: object,
    flags: mqtt.ConnectFlags,
    reason_code: mqtt.ReasonCodes,
    properties: Optional[mqtt.Properties] = None,
) -> None:
    """Handle MQTT connect events."""
    _set_connected(True)


def _on_disconnect(
    client: mqtt.Client,
    userdata: object,
    reason_code: mqtt.ReasonCodes,
    properties: Optional[mqtt.Properties] = None,
) -> None:
    """Handle MQTT disconnect events."""
    _set_connected(False)


def _ensure_client() -> mqtt.Client:
    """Return the singleton MQTT client, creating it if needed."""
    global _client
    if _client is not None:
        return _client

    client = mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION2)
    client.on_connect = _on_connect
    client.on_disconnect = _on_disconnect
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    _client = client
    return client


def _ensure_reconnect_thread() -> None:
    """Start the background reconnect loop if it is not running."""
    global _reconnect_thread
    if _reconnect_thread and _reconnect_thread.is_alive():
        return

    _stop_event.clear()
    _reconnect_thread = threading.Thread(
        target=_reconnect_loop,
        name="mqtt-reconnect",
        daemon=True,
    )
    _reconnect_thread.start()


def _reconnect_loop() -> None:
    """Reconnect with exponential backoff up to 60 seconds."""
    backoff = 1.0
    while not _stop_event.is_set():
        with _lock:
            connected = bool(_state["connected"])
        if connected:
            backoff = 1.0
            time.sleep(1.0)
            continue

        try:
            client = _ensure_client()
            if not _loop_running:
                client.loop_start()
                _set_loop_running(True)
            client.reconnect()
            backoff = 1.0
            time.sleep(1.0)
        except Exception:
            time.sleep(backoff)
            backoff = min(backoff * 2.0, 60.0)


def _set_loop_running(running: bool) -> None:
    """Record whether the MQTT network loop is running."""
    global _loop_running
    _loop_running = running


def connect(
    server: str,
    port: int,
    username: Optional[str],
    password: Optional[str],
) -> bool:
    """Connect to the MQTT broker and enable auto-reconnect."""
    if not server or port <= 0:
        return False

    client = _ensure_client()
    if username:
        client.username_pw_set(username, password or None)

    with _lock:
        _state["broker"] = server
        _state["port"] = port

    try:
        client.connect_async(server, port, keepalive=60)
        if not _loop_running:
            client.loop_start()
            _set_loop_running(True)
    except Exception:
        _set_connected(False)
        return False

    _ensure_reconnect_thread()
    return True


def disconnect() -> bool:
    """Disconnect the MQTT client and stop the background loop."""
    global _client
    _stop_event.set()

    client = _client
    if not client:
        return False

    try:
        client.disconnect()
        if _loop_running:
            client.loop_stop()
            _set_loop_running(False)
    finally:
        _set_connected(False)
    return True


def status() -> dict:
    """Return the current MQTT connection status."""
    with _lock:
        connected = bool(_state["connected"])
        broker = str(_state["broker"])
        port = int(_state["port"])
        uptime_start = _state["uptime_start"]

    uptime_seconds = 0
    if connected and isinstance(uptime_start, (int, float)):
        uptime_seconds = int(time.monotonic() - uptime_start)

    return {
        "connected": connected,
        "broker": broker,
        "port": port,
        "uptime_seconds": uptime_seconds,
    }


def publish(topic: str, payload: str) -> bool:
    """Publish a message to the configured broker."""
    if not topic:
        return False

    client = _client
    if not client:
        return False

    result = client.publish(topic, payload)
    return result.rc == mqtt.MQTT_ERR_SUCCESS
