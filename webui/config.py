"""Encrypted configuration storage for phev2mqtt web UI."""

from __future__ import annotations

import json
import logging
import os
import tempfile
from typing import Any, Dict

from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger(__name__)

CONFIG_PATH = "/etc/phev2mqtt-webui/config.json"
KEY_PATH = "/etc/phev2mqtt-webui/secret.key"

SENSITIVE_KEYS = {
    "webui_password",
    "wifi_psk",
    "mqtt_username",
    "mqtt_password",
}

DEFAULT_CONFIG: Dict[str, Any] = {
    "wifi_ssid": "",
    "wifi_interface": "",
    "wifi_region": "",
    "wifi_mac_spoof": "",
    "mqtt_server": "",
    "mqtt_port": 1883,
    "ssh_enabled": False,
    "log_level": "info",
    "journal_max_size": "200MB",
    "log_retention_days": 7,
    "logrotate_size": "20M",
    "logrotate_rotate": 5,
    "phev_vin": "",
    "emulator_enabled": False,
    "secrets": {},
}


def generate_key() -> None:
    """Create the encryption key file if it does not exist."""
    if os.path.exists(KEY_PATH):
        return

    key_dir = os.path.dirname(KEY_PATH)
    os.makedirs(key_dir, exist_ok=True)

    key = Fernet.generate_key()
    with open(KEY_PATH, "wb") as key_file:
        key_file.write(key)

    os.chmod(KEY_PATH, 0o600)


def _load_key() -> bytes:
    """Load the encryption key, generating it if it does not exist."""
    # Auto-generate key on first startup
    if not os.path.exists(KEY_PATH):
        generate_key()

    with open(KEY_PATH, "rb") as key_file:
        return key_file.read().strip()


def _get_fernet() -> Fernet:
    """Return a Fernet instance for encrypting and decrypting secrets."""
    return Fernet(_load_key())


def load_config() -> Dict[str, Any]:
    """Load config.json and return a dict with safe defaults."""
    # Guard: raises RuntimeError if key is missing.
    _load_key()

    if not os.path.exists(CONFIG_PATH):
        config = DEFAULT_CONFIG.copy()
        config["emulator_enabled"] = False
        return config

    with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
        data = json.load(config_file)

    config = DEFAULT_CONFIG.copy()
    config.update(data)
    config["secrets"] = data.get("secrets", {})
    config["emulator_enabled"] = False
    return config


def save_config(data: Dict[str, Any]) -> None:
    """Atomically write config.json after validating JSON content."""
    try:
        _load_key()

        config_dir = os.path.dirname(CONFIG_PATH)
        os.makedirs(config_dir, exist_ok=True)

        data = data.copy()
        data["emulator_enabled"] = False
        data.setdefault("secrets", {})

        fd, tmp_path = tempfile.mkstemp(prefix="config.", dir=config_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
                json.dump(data, tmp_file, indent=2, sort_keys=True)
                tmp_file.flush()
                os.fsync(tmp_file.fileno())

            with open(tmp_path, "r", encoding="utf-8") as verify_file:
                json.load(verify_file)

            os.replace(tmp_path, CONFIG_PATH)
            logger.info(f"Config saved successfully to {CONFIG_PATH}")
        finally:
            # os.replace() removes tmp_path on success,
            # so only unlink if it still exists (i.e. on error).
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
    except Exception as exc:
        logger.error(f"Failed to save config: {exc}", exc_info=True)
        raise


def get_secret(key: str) -> str:
    """Decrypt and return a sensitive field from the config."""
    if key not in SENSITIVE_KEYS:
        raise KeyError(f"Unsupported secret key: {key}")

    config = load_config()
    encrypted = config.get("secrets", {}).get(key)
    if not encrypted:
        return ""

    fernet = _get_fernet()
    try:
        return fernet.decrypt(encrypted.encode("utf-8")).decode("utf-8")
    except InvalidToken as exc:
        raise RuntimeError("Failed to decrypt config secret") from exc


def set_secret(key: str, value: str) -> None:
    """Encrypt and store a sensitive field in the config."""
    if key not in SENSITIVE_KEYS:
        raise KeyError(f"Unsupported secret key: {key}")

    config = load_config()
    fernet = _get_fernet()
    encrypted = fernet.encrypt(value.encode("utf-8")).decode("utf-8")
    config.setdefault("secrets", {})[key] = encrypted
    save_config(config)


def is_configured() -> bool:
    """Return True when a valid password hash has been stored."""
    password_hash = get_secret("webui_password")
    return bool(password_hash)
