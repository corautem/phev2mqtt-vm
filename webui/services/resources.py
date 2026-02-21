"""Resource monitoring utilities using psutil."""

from __future__ import annotations

from typing import Dict

import psutil


def disk() -> Dict[str, int | float]:
    """Return disk usage for the root filesystem."""
    usage = psutil.disk_usage("/")
    total = int(usage.total)
    free = int(usage.free)
    used = total - free
    percent_free = (free / total) * 100 if total else 0.0
    return {
        "total_bytes": total,
        "used_bytes": used,
        "free_bytes": free,
        "percent_free": percent_free,
    }


def ram() -> Dict[str, int | float]:
    """Return RAM usage metrics."""
    mem = psutil.virtual_memory()
    total = int(mem.total)
    free = int(mem.available)
    used = total - free
    percent_used = (used / total) * 100 if total else 0.0
    return {
        "total_bytes": total,
        "used_bytes": used,
        "free_bytes": free,
        "percent_used": percent_used,
    }


def cpu_percent() -> float:
    """Return current CPU usage percentage."""
    return float(psutil.cpu_percent(interval=0.5))


def snapshot() -> Dict[str, object]:
    """Return a combined snapshot of disk, RAM, and CPU usage."""
    return {
        "disk": disk(),
        "ram": ram(),
        "cpu_percent": cpu_percent(),
    }
