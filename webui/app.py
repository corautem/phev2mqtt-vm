"""Flask application for the phev2mqtt web UI."""

from __future__ import annotations

import secrets
import threading
from typing import Any

from flask import (
    Flask,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from flask.typing import ResponseReturnValue

import config
import auth
from routes.api import api
from routes.terminal import init_sock

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=False,
    SESSION_PERMANENT=False,
)

# Register the API blueprint
app.register_blueprint(api)

# Initialize WebSocket support for terminal
init_sock(app)

_setup_lock = threading.Lock()


@app.before_request
def enforce_first_run_gate() -> ResponseReturnValue | None:
    """Redirect protected routes to setup while no password is configured."""
    if config.is_configured():
        return None

    allowed_endpoints = {"setup", "static"}
    if request.endpoint in allowed_endpoints:
        return None

    return redirect(url_for("setup"))


@app.get("/setup")
def setup() -> ResponseReturnValue:
    """Render the mandatory first-run setup form."""
    if config.is_configured():
        flash("Setup already completed")
        return redirect(url_for("login"))

    return render_template("first_run.html")


@app.post("/setup")
def setup_submit() -> ResponseReturnValue:
    """Handle first-run password submission."""
    with _setup_lock:
        if config.is_configured():
            flash("Setup already completed")
            return redirect(url_for("login"))

        password = request.form.get("password", "")
        if len(password) < 8:
            flash("Password must be at least 8 characters")
            return render_template("first_run.html"), 400

        if not auth.complete_first_run(password):
            flash("Setup already completed")
            return redirect(url_for("login"))

        session["authenticated"] = True
        return redirect(url_for("settings"))


@app.get("/login")
def login() -> ResponseReturnValue:
    """Render the login form."""
    if not config.is_configured():
        return redirect(url_for("setup"))

    return render_template("login.html")


@app.post("/login")
def login_submit() -> ResponseReturnValue:
    """Handle login submissions."""
    if not config.is_configured():
        return redirect(url_for("setup"))

    password = request.form.get("password", "")
    if not auth.verify_password(password):
        flash("Invalid password")
        return render_template("login.html"), 401

    session["authenticated"] = True
    return redirect(url_for("settings"))


@app.get("/logout")
def logout() -> ResponseReturnValue:
    """Clear the session and return to the login page."""
    session.clear()
    return redirect(url_for("login"))


@app.get("/")
def index() -> ResponseReturnValue:
    """Redirect the root route to the settings page."""
    return redirect(url_for("settings"))


@app.get("/settings")
@auth.login_required
def settings() -> ResponseReturnValue:
    """Render the main settings page."""
    return render_template("settings.html")


@app.get("/tools")
@auth.login_required
def tools() -> ResponseReturnValue:
    """Render the terminal and tools page."""
    return render_template("tools.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
