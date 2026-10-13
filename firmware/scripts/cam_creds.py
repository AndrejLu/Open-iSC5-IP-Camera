"""Load camera credentials from env or untracked local file (never commit secrets)."""
from __future__ import annotations
import os
from pathlib import Path

_CREDS = Path(__file__).resolve().parents[1] / "private" / "cam_creds.env"


def load() -> dict[str, str]:
    vals: dict[str, str] = {}
    if _CREDS.is_file():
        for line in _CREDS.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip().strip('"').strip("'")
    host = os.environ.get("LOCALCAM_HOST", vals.get("LOCALCAM_HOST", "192.168.1.50"))
    user = os.environ.get("LOCALCAM_USER", vals.get("LOCALCAM_USER", "root"))
    password = os.environ.get("LOCALCAM_PASS", vals.get("LOCALCAM_PASS", ""))
    return {"host": host, "user": user, "password": password}
