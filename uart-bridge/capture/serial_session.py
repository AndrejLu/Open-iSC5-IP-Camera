#!/usr/bin/env python3
"""
Interactive / scripted serial session over the Curie USB↔UART bridge.
Avoids 1200-baud bootloader reset. Never claims success without markers.
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import serial
from serial import SerialException

DEFAULT_PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"
PROMPT_RE = re.compile(r"(login:\s*$|Password:\s*$|[$#]\s*$)", re.M)


def open_port(port: str, baud: int = 115200) -> serial.Serial:
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.bytesize = serial.EIGHTBITS
    ser.parity = serial.PARITY_NONE
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout = 0.2
    ser.write_timeout = 2
    ser.xonxoff = False
    ser.rtscts = False
    ser.dsrdtr = False
    ser.dtr = False
    ser.open()
    try:
        ser.dtr = True
    except Exception:
        pass
    # Drain noise without 1200bps
    time.sleep(0.3)
    ser.reset_input_buffer()
    return ser


def read_for(ser: serial.Serial, seconds: float, transcript: list[str] | None = None) -> str:
    end = time.monotonic() + seconds
    chunks: list[bytes] = []
    while time.monotonic() < end:
        data = ser.read(4096)
        if data:
            chunks.append(data)
            text = data.decode("utf-8", errors="replace")
            if transcript is not None:
                transcript.append(text)
            sys.stdout.write(text)
            sys.stdout.flush()
        else:
            time.sleep(0.05)
    return b"".join(chunks).decode("utf-8", errors="replace")


def wait_for(
    ser: serial.Serial,
    patterns: list[str],
    timeout: float,
    transcript: list[str] | None = None,
) -> tuple[str, str | None]:
    """Return (buffer, matched_pattern_or_None)."""
    end = time.monotonic() + timeout
    buf = ""
    compiled = [re.compile(p, re.M | re.I) for p in patterns]
    while time.monotonic() < end:
        data = ser.read(4096)
        if data:
            text = data.decode("utf-8", errors="replace")
            buf += text
            if transcript is not None:
                transcript.append(text)
            sys.stdout.write(text)
            sys.stdout.flush()
            for pat, cre in zip(patterns, compiled):
                if cre.search(buf):
                    return buf, pat
        else:
            time.sleep(0.05)
    return buf, None


def send_line(ser: serial.Serial, line: str) -> None:
    ser.write((line + "\n").encode("utf-8"))
    ser.flush()


def looks_like_shell(buf: str) -> bool:
    # BusyBox ash/getty style: ends with # or $ prompt, not just login:
    if re.search(r"login:\s*$", buf, re.M):
        return False
    if re.search(r"Password:\s*$", buf, re.M):
        return False
    # Prefer root# or / # style
    if re.search(r"(?:^|\n)\s*(?:root@\S+\s*)?[/#]\s*$", buf):
        return True
    if re.search(r"(?:^|\n)[^\n]*[$#]\s*$", buf) and "Login incorrect" not in buf:
        # weak: many logs end oddly; require recent # after uid= or similar later
        return "#" in buf[-80:] or "$" in buf[-80:]
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=DEFAULT_PORT)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="ismart12")
    ap.add_argument("--transcript", type=Path, required=True)
    ap.add_argument("--login-only", action="store_true")
    args = ap.parse_args()

    transcript: list[str] = []
    stamp = datetime.now(timezone.utc).isoformat()
    transcript.append(f"\n===== SESSION START {stamp} port={args.port} =====\n")

    try:
        ser = open_port(args.port)
    except SerialException as e:
        print(f"ERROR opening port: {e}", file=sys.stderr)
        return 2

    print("\n[host] sending CR to wake console...", file=sys.stderr)
    ser.write(b"\r")
    ser.flush()
    buf, matched = wait_for(
        ser,
        [r"login:\s*$", r"[$#]\s*$", r"Password:\s*$"],
        timeout=8,
        transcript=transcript,
    )

    if matched and "Password" in matched:
        # unexpected
        pass

    if not matched or "login:" not in (matched or ""):
        # maybe already logged in or need another enter
        if looks_like_shell(buf):
            print("\n[host] already at shell prompt", file=sys.stderr)
        else:
            print("\n[host] no login yet; sending another CR...", file=sys.stderr)
            ser.write(b"\r\n")
            ser.flush()
            buf2, matched = wait_for(
                ser,
                [r"login:\s*$", r"[$#]\s*$"],
                timeout=10,
                transcript=transcript,
            )
            buf += buf2

    if looks_like_shell(buf) and "login:" not in buf[-200:]:
        print("\n[host] shell appears present", file=sys.stderr)
    else:
        # ensure login prompt
        if "login:" not in buf[-400:]:
            ser.write(b"\r\n")
            ser.flush()
            more, matched = wait_for(ser, [r"login:\s*$"], timeout=12, transcript=transcript)
            buf += more
            if not matched:
                args.transcript.write_text("".join(transcript), encoding="utf-8")
                print("\n[host] ERROR: no login prompt", file=sys.stderr)
                ser.close()
                return 3

        print(f"\n[host] logging in as {args.user}...", file=sys.stderr)
        send_line(ser, args.user)
        pw_buf, matched = wait_for(ser, [r"Password:\s*$", r"[$#]\s*$"], timeout=8, transcript=transcript)
        if matched and "Password" in matched:
            # slight delay then password
            time.sleep(0.2)
            send_line(ser, args.password)
            after, matched = wait_for(
                ser,
                [r"Login incorrect", r"login:\s*$", r"[$#]\s*$"],
                timeout=10,
                transcript=transcript,
            )
            if "Login incorrect" in after or (matched and "login:" in matched):
                args.transcript.write_text("".join(transcript), encoding="utf-8")
                print("\n[host] LOGIN REJECTED", file=sys.stderr)
                ser.close()
                return 4

    # Prove shell: run unique marker commands
    marker = f"SERIAL_OK_{int(time.time())}"
    send_line(ser, f"echo {marker}; id; uname -a")
    proof, _ = wait_for(ser, [re.escape(marker)], timeout=8, transcript=transcript)
    # collect a bit more for id/uname
    extra = read_for(ser, 2.0, transcript)

    full = proof + extra
    has_marker = marker in full
    has_uid = "uid=" in full
    has_uname = "Linux" in full and "arm" in full.lower()

    args.transcript.parent.mkdir(parents=True, exist_ok=True)
    args.transcript.write_text("".join(transcript), encoding="utf-8")

    if has_marker and has_uid and has_uname:
        print("\n[host] LOGIN CONFIRMED (marker + id + uname)", file=sys.stderr)
        # leave port closed; caller reopens for more work, OR keep open?
        # For login-only we close; session scripts reopen.
        ser.close()
        return 0

    print(
        f"\n[host] LOGIN NOT CONFIRMED marker={has_marker} uid={has_uid} uname={has_uname}",
        file=sys.stderr,
    )
    ser.close()
    return 5


if __name__ == "__main__":
    raise SystemExit(main())
