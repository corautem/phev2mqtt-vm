"""Authentication and first-run security gate logic."""

from __future__ import annotations

import functools
import secrets
import threading
from typing import Any, Callable, TypeVar

import bcrypt
from flask import Flask, redirect, session, url_for

from config import get_secret, is_configured, set_secret

T = TypeVar("T", bound=Callable[..., Any])

_setup_lock = threading.Lock()


def configure_session(app: Flask) -> None:
    """Configure Flask session settings and generate a runtime secret key."""
    # Generate a per-startup secret key to avoid hardcoding secrets.
    app.secret_key = secrets.token_urlsafe(32)
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        SESSION_PERMANENT=False,
    )


def is_first_run() -> bool:
    """Return True when the web UI password has not been configured yet."""
    # First run is defined by the absence of a stored password hash.
    return not is_configured()


def complete_first_run(password: str) -> bool:
    """Attempt to complete first-run setup by storing a new password hash."""
    # Prevent multiple browsers from completing setup simultaneously.
    with _setup_lock:
        if is_configured():
            return False
        if len(password) < 8:
            return False

        hashed = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt())
        set_secret("webui_password", hashed.decode("utf-8"))
        return True


def verify_password(plain: str) -> bool:
    """Verify a plain-text password against the stored bcrypt hash."""
    # Return False if there is no stored hash or the check fails.
    stored_hash = get_secret("webui_password")
    if not stored_hash:
        return False

    return bcrypt.checkpw(plain.encode("utf-8"), stored_hash.encode("utf-8"))


def login_required(view_func: T) -> T:
    """Decorator enforcing an authenticated session for protected routes."""
    # Redirect unauthenticated users to the login page.
    @functools.wraps(view_func)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return view_func(*args, **kwargs)

    return wrapper  # type: ignore[return-value]


def change_password(old: str, new: str) -> bool:
    """Change the stored password after validating the current one."""
    # Force re-login after a successful password change.
    if not verify_password(old):
        return False
    if len(new) < 8:
        return False

    hashed = bcrypt.hashpw(new.encode("utf-8"), bcrypt.gensalt())
    set_secret("webui_password", hashed.decode("utf-8"))
    session.clear()
    return True


def terminal_allowed() -> bool:
    """Return True when terminal access is allowed server-side."""
    # Terminal access is locked until a password is configured.
    return is_configured()


def ssh_allowed() -> bool:
    """Return True when SSH access is allowed server-side."""
    # SSH access is locked until a password is configured.
    return is_configured()
