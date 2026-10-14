#!/usr/bin/env python3
"""Pull RTSP (UDP) on the host and push segments onto the camera SD.

The camera SoC cannot receive its own RTSP UDP loopback, so on-device ffmpeg /
rtsp-h264 cannot record. This helper runs on the UDOO (or any LAN host).
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cam_ssh import connect, put_file, run  # noqa: E402

DEFAULT_URL = "rtsp://192.168.1.50:554/unicast"
REMOTE_DIR = "/media/mmcblk0p1/record/localcam"
RUNDIR = "/tmp/localcam"


def find_ffmpeg() -> str:
  root = Path(__file__).resolve().parents[1]
  cand = [
    root / "tools/ffmpeg-7.0.2-amd64-static/ffmpeg",
    Path("/usr/bin/ffmpeg"),
  ]
  for c in cand:
    if c.is_file() and c.stat().st_mode & 0o111:
      return str(c)
  raise SystemExit("ffmpeg not found (expected firmware/tools/ffmpeg-*-static/ffmpeg)")


def set_state(c, state: str) -> None:
  run(c, f"mkdir -p {REMOTE_DIR} {RUNDIR}; echo {state} > {RUNDIR}/recorder.state")
  run(c, f"touch {RUNDIR}/recorder.run")


def main() -> int:
  ap = argparse.ArgumentParser()
  ap.add_argument("-u", "--url", default=DEFAULT_URL)
  ap.add_argument("-t", "--seg", type=int, default=30, help="segment seconds")
  ap.add_argument("-n", "--count", type=int, default=0, help="0=forever")
  args = ap.parse_args()
  ff = find_ffmpeg()
  tmp = Path("/tmp/localcam-host-rec")
  tmp.mkdir(parents=True, exist_ok=True)

  n = 0
  while args.count == 0 or n < args.count:
    n += 1
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    local = tmp / f"seg_{ts}.ts"
    cmd = [
      ff, "-y", "-loglevel", "error",
      "-rtsp_transport", "udp",
      "-i", args.url,
      "-t", str(args.seg),
      "-c", "copy", "-an", "-f", "mpegts",
      str(local),
    ]
    print(f"record #{n} → {local.name}", flush=True)
    try:
      subprocess.run(cmd, check=True, timeout=args.seg + 45)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
      print(f"segment failed: {e}", flush=True)
      time.sleep(3)
      continue
    if not local.is_file() or local.stat().st_size < 4096:
      print("segment too small — skip", flush=True)
      local.unlink(missing_ok=True)
      time.sleep(2)
      continue
    remote = f"{REMOTE_DIR}/{local.name}"
    try:
      from cam_creds import load as load_creds
      creds = load_creds()
      # Prefer FTP (camera already runs ftpd) — much faster than uuencode-SSH
      ftp_url = f"ftp://{creds['host']}{remote}"
      up = subprocess.run(
        [
          "curl", "-sS", "--connect-timeout", "8", "--max-time", "180",
          "--ftp-pasv",
          "-u", f"{creds['user']}:{creds['password']}",
          "-T", str(local),
          ftp_url,
        ],
        capture_output=True,
        text=True,
      )
      if up.returncode != 0:
        # Fallback: slow but reliable uuencode put
        print(f"ftp push failed ({up.stderr.strip() or up.returncode}); trying SSH", flush=True)
        c = connect()
        try:
          put_file(c, str(local), remote)
        finally:
          c.close()
      c = connect()
      try:
        set_state(c, "recording")
        run(c, f"chmod 644 {remote} 2>/dev/null; echo host-rec ok {local.name} >> /tmp/localcam-recorder.log")
      finally:
        c.close()
      print(f"pushed {remote} ({local.stat().st_size} bytes)", flush=True)
    except Exception as e:
      print(f"push failed: {e}", flush=True)
      time.sleep(5)
    finally:
      local.unlink(missing_ok=True)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
