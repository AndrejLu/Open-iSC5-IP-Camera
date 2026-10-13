#!/usr/bin/env python3
"""
Receive-only UART capture utility for the UDOO X86 Arduino 101 USB bridge.

Opens the host USB serial port (bridge), records exact camera bytes to a .bin
file, and writes a readable .log. Never transmits to the camera.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import serial
    from serial import SerialException
except ImportError as exc:  # pragma: no cover
    print("ERROR: pyserial is required (python3-serial).", file=sys.stderr)
    raise SystemExit(1) from exc


DEFAULT_PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"
DEFAULT_BAUD = 115200
DEFAULT_DURATION = 180


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def unique_paths(log_dir: Path, stamp: str) -> tuple[Path, Path, Path]:
    """Return non-colliding .bin / .log / .meta.json paths."""
    base = log_dir / f"boot_{stamp}"
    bin_path = Path(f"{base}.bin")
    log_path = Path(f"{base}.log")
    meta_path = Path(f"{base}.meta.json")
    n = 1
    while bin_path.exists() or log_path.exists() or meta_path.exists():
        bin_path = Path(f"{base}_{n}.bin")
        log_path = Path(f"{base}_{n}.log")
        meta_path = Path(f"{base}_{n}.meta.json")
        n += 1
    return bin_path, log_path, meta_path


def decode_for_display(data: bytes) -> str:
    """Best-effort text for console/.log; raw bytes stay in .bin."""
    return data.decode("utf-8", errors="replace")


def open_bridge(port: str, baud: int) -> serial.Serial:
    """
    Open the Arduino USB CDC port without triggering a 1200-baud bootloader reset.

    pyserial opens at the requested baud. We disable flow control and assert DTR
    after open (required by some CDC ACM stacks) without pulsing a reset sequence.
    """
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.bytesize = serial.EIGHTBITS
    ser.parity = serial.PARITY_NONE
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout = 0.2
    ser.write_timeout = 0
    ser.xonxoff = False
    ser.rtscts = False
    ser.dsrdtr = False
    # Avoid implicit DTR toggle on open where supported.
    ser.dtr = False
    ser.rts = False
    ser.open()
    # Assert DTR after open for CDC ACM data path; do not toggle baud or pulse reset.
    try:
        ser.dtr = True
    except Exception:
        pass
    # Never write anything — receive only.
    ser.reset_input_buffer()
    return ser


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Capture camera UART boot log via UDOO Arduino 101 RX bridge."
    )
    p.add_argument("--port", default=DEFAULT_PORT, help="Serial device path")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD, help="Host USB baud (bridge)")
    p.add_argument(
        "--duration",
        type=float,
        default=DEFAULT_DURATION,
        help="Capture duration in seconds (default 180)",
    )
    p.add_argument(
        "--log-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "logs",
        help="Directory for capture outputs",
    )
    p.add_argument(
        "--ready-file",
        type=Path,
        default=None,
        help="Write READY when port is open (for automation)",
    )
    p.add_argument(
        "--status-file",
        type=Path,
        default=None,
        help="Periodically write JSON progress status",
    )
    return p.parse_args(argv)


def write_status(path: Path | None, payload: dict) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    args.log_dir.mkdir(parents=True, exist_ok=True)

    stamp = utc_stamp()
    bin_path, log_path, meta_path = unique_paths(args.log_dir, stamp)

    stop = {"flag": False}

    def _handle_sig(_signum, _frame):
        stop["flag"] = True

    signal.signal(signal.SIGINT, _handle_sig)
    signal.signal(signal.SIGTERM, _handle_sig)

    # Host status goes to stderr / status file only — never into .log/.bin
    print(f"[host] opening port {args.port} @ {args.baud}", file=sys.stderr)
    try:
        ser = open_bridge(args.port, args.baud)
    except SerialException as exc:
        print(f"[host] ERROR opening port: {exc}", file=sys.stderr)
        write_status(
            args.status_file,
            {"state": "error", "error": str(exc), "port": args.port},
        )
        return 2

    resolved = os.path.realpath(args.port)
    print(f"[host] port open ({resolved}); capture armed", file=sys.stderr)
    print(f"[host] bin={bin_path}", file=sys.stderr)
    print(f"[host] log={log_path}", file=sys.stderr)
    print(f"[host] duration={args.duration}s — power-cycle the camera now", file=sys.stderr)

    if args.ready_file is not None:
        args.ready_file.write_text(
            f"READY\nport={args.port}\nresolved={resolved}\nstamp={stamp}\n",
            encoding="utf-8",
        )

    started = time.monotonic()
    started_wall = datetime.now(timezone.utc).isoformat()
    total_bytes = 0
    last_flush = started
    last_status = started

    meta = {
        "started_utc": started_wall,
        "port": args.port,
        "resolved_port": resolved,
        "baud": args.baud,
        "duration_requested_s": args.duration,
        "flow_control": {"rtscts": False, "xonxoff": False},
        "dtr_asserted": True,
        "transmit_to_camera": False,
        "notes": (
            "Host USB serial to Arduino 101 bridge. Camera connected to Serial1 RX only. "
            "No bytes were written to the serial port by this utility."
        ),
    }

    try:
        with bin_path.open("wb") as bin_f, log_path.open("w", encoding="utf-8", newline="") as log_f:
            write_status(
                args.status_file,
                {
                    "state": "capturing",
                    "started_utc": started_wall,
                    "bytes": 0,
                    "elapsed_s": 0,
                    "bin": str(bin_path),
                    "log": str(log_path),
                },
            )
            while not stop["flag"]:
                elapsed = time.monotonic() - started
                if elapsed >= args.duration:
                    break

                chunk = ser.read(4096)
                if chunk:
                    bin_f.write(chunk)
                    text = decode_for_display(chunk)
                    log_f.write(text)
                    # Live display of camera stream only (no host prefixes)
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    total_bytes += len(chunk)

                now = time.monotonic()
                if now - last_flush >= 1.0:
                    bin_f.flush()
                    log_f.flush()
                    os.fsync(bin_f.fileno())
                    last_flush = now

                if now - last_status >= 2.0:
                    write_status(
                        args.status_file,
                        {
                            "state": "capturing",
                            "started_utc": started_wall,
                            "bytes": total_bytes,
                            "elapsed_s": round(now - started, 3),
                            "bin": str(bin_path),
                            "log": str(log_path),
                        },
                    )
                    last_status = now

            bin_f.flush()
            log_f.flush()
            os.fsync(bin_f.fileno())
            os.fsync(log_f.fileno())
    finally:
        try:
            ser.close()
        except Exception:
            pass

    ended_wall = datetime.now(timezone.utc).isoformat()
    elapsed_total = time.monotonic() - started
    digest = sha256_file(bin_path) if bin_path.exists() else None
    log_digest = sha256_file(log_path) if log_path.exists() else None

    meta.update(
        {
            "ended_utc": ended_wall,
            "elapsed_s": round(elapsed_total, 3),
            "bytes_received": total_bytes,
            "stopped_by_signal": stop["flag"],
            "bin_path": str(bin_path),
            "log_path": str(log_path),
            "sha256_bin": digest,
            "sha256_log": log_digest,
        }
    )
    meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

    write_status(
        args.status_file,
        {
            "state": "done",
            "bytes": total_bytes,
            "elapsed_s": round(elapsed_total, 3),
            "bin": str(bin_path),
            "log": str(log_path),
            "meta": str(meta_path),
            "sha256_bin": digest,
        },
    )

    print(
        f"\n[host] capture finished: {total_bytes} bytes in {elapsed_total:.1f}s",
        file=sys.stderr,
    )
    print(f"[host] bin:  {bin_path}", file=sys.stderr)
    print(f"[host] log:  {log_path}", file=sys.stderr)
    print(f"[host] meta: {meta_path}", file=sys.stderr)
    print(f"[host] sha256(bin): {digest}", file=sys.stderr)
    return 0 if total_bytes > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
