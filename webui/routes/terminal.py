"""WebSocket handler for xterm.js shell session."""

from __future__ import annotations

import fcntl
import logging
import os
import pty
import select
import struct
import termios
from typing import Any

from flask_sock import Sock

from auth import terminal_allowed

logger = logging.getLogger(__name__)

sock = Sock()


def init_sock(app: Any) -> None:
    """Initialize Flask-Sock with the Flask app."""
    sock.init_app(app)


@sock.route("/ws/terminal")
def terminal_websocket(ws: Any) -> None:
    """
    WebSocket endpoint for xterm.js terminal session.

    Spawns a shell in a pseudo-terminal and bridges bidirectional
    communication between the WebSocket client and the shell process.
    """
    if not terminal_allowed():
        ws.send("Terminal access locked until password is set.\r\n")
        ws.send("Please complete first-run setup.\r\n")
        ws.close(reason="Terminal access locked")
        return

    master_fd = None
    pid = None

    try:
        # Fork a new process with a pseudo-terminal
        pid, master_fd = pty.fork()

        if pid == 0:
            # Child process: execute the shell
            shell = os.environ.get("SHELL", "/bin/bash")
            os.execvp(shell, [shell])
        else:
            # Parent process: bridge WebSocket and pty
            _bridge_pty_to_websocket(ws, master_fd, pid)

    except Exception as e:
        logger.error(f"Terminal session error: {e}")
        try:
            ws.send(f"\r\nTerminal error: {e}\r\n")
        except Exception:
            pass
    finally:
        # Clean up
        if master_fd is not None:
            try:
                os.close(master_fd)
            except Exception:
                pass

        if pid is not None and pid > 0:
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass


def _bridge_pty_to_websocket(ws: Any, master_fd: int, pid: int) -> None:
    """
    Bridge data between WebSocket and pty master file descriptor.

    Runs a select loop that:
    - Reads from WebSocket and writes to pty (user input)
    - Reads from pty and writes to WebSocket (shell output)
    - Handles terminal resize events
    - Exits when shell process terminates or WebSocket closes
    """
    # Set master_fd to non-blocking
    flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
    fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    while True:
        try:
            # Check if child process has exited
            wpid, status = os.waitpid(pid, os.WNOHANG)
            if wpid != 0:
                logger.info(f"Shell process {pid} exited with status {status}")
                break

            # Wait for data from either WebSocket or pty
            rlist, _, _ = select.select([master_fd], [], [], 0.1)

            # Read from pty and send to WebSocket
            if master_fd in rlist:
                try:
                    data = os.read(master_fd, 4096)
                    if data:
                        ws.send(data.decode("utf-8", errors="replace"))
                    else:
                        # EOF from pty
                        break
                except OSError:
                    # Read error, likely EOF
                    break

            # Read from WebSocket and write to pty
            # Flask-Sock WebSocket receive is non-blocking with timeout
            try:
                msg = ws.receive(timeout=0.05)
                if msg is None:
                    # WebSocket closed
                    logger.info("WebSocket closed by client")
                    break

                # Handle JSON messages (terminal resize events)
                if isinstance(msg, str):
                    if msg.startswith("{"):
                        import json
                        try:
                            data = json.loads(msg)
                            if data.get("type") == "resize":
                                _resize_pty(master_fd, data.get(
                                    "rows", 24), data.get("cols", 80))
                        except json.JSONDecodeError:
                            # Not JSON, treat as regular input
                            os.write(master_fd, msg.encode("utf-8"))
                    else:
                        # Regular text input
                        os.write(master_fd, msg.encode("utf-8"))
                elif isinstance(msg, bytes):
                    os.write(master_fd, msg)

            except Exception:
                # No data available from WebSocket, continue
                pass

        except Exception as e:
            logger.error(f"Bridge loop error: {e}")
            break


def _resize_pty(fd: int, rows: int, cols: int) -> None:
    """
    Resize the pseudo-terminal window size.

    Sends TIOCSWINSZ ioctl to update the terminal dimensions,
    which is required for programs like top, vim, etc. to display correctly.
    """
    try:
        size = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, size)
    except Exception as e:
        logger.error(f"Failed to resize pty: {e}")
