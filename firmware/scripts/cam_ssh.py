#!/usr/bin/env python3
"""SSH helper for the camera on LAN (exec + uuencode file put; no SFTP required)."""
from __future__ import annotations
import argparse
import binascii
import glob
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".venv/lib"))
for p in glob.glob(str(Path(__file__).resolve().parents[1] / ".venv/lib/python*/site-packages")):
    sys.path.insert(0, p)

import paramiko
from cam_creds import load as load_creds

_creds = load_creds()
DEFAULT_HOST = _creds["host"]
DEFAULT_USER = _creds["user"]
DEFAULT_PASS = _creds["password"]


def connect(host: str = DEFAULT_HOST, password: str = DEFAULT_PASS) -> paramiko.SSHClient:
    if not password:
        raise RuntimeError("Set LOCALCAM_PASS or firmware/private/cam_creds.env")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        host,
        username=DEFAULT_USER,
        password=password,
        timeout=12,
        allow_agent=False,
        look_for_keys=False,
        banner_timeout=12,
    )
    return c


def run(c: paramiko.SSHClient, cmd: str, timeout: float = 60) -> tuple[int, str, str]:
    stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def put_file(c: paramiko.SSHClient, local: str, remote: str) -> None:
    """Stream a file via uuencode/uudecode (dropbear often has no SFTP)."""
    raw = Path(local).read_bytes()
    tmp_name = f"_put_{Path(remote).name}"
    payload = b"begin 644 " + tmp_name.encode() + b"\n"
    for i in range(0, len(raw), 45):
        payload += binascii.b2a_uu(raw[i : i + 45])
    payload += b"end\n"
    stdin, stdout, stderr = c.exec_command("cd /tmp && uudecode")
    stdin.write(payload)
    stdin.channel.shutdown_write()
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"uudecode failed: {err or code}")
    code, out, err = run(c, f"mv -f /tmp/{tmp_name} {remote} && chmod 644 {remote}")
    if code != 0:
        raise RuntimeError(f"mv failed: {err or out or code}")
    print(f"PUT {local} -> {remote} ({len(raw)} bytes)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-H", "--host", default=DEFAULT_HOST)
    ap.add_argument("-c", "--cmd", action="append", default=[])
    ap.add_argument("--put", nargs=2, action="append", default=[], metavar=("LOCAL", "REMOTE"))
    args = ap.parse_args()
    c = connect(args.host)
    try:
        for local, remote in args.put:
            put_file(c, local, remote)
        for cmd in args.cmd:
            code, out, err = run(c, cmd)
            sys.stdout.write(out)
            if err:
                sys.stderr.write(err)
            if code != 0:
                return code
    finally:
        c.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
