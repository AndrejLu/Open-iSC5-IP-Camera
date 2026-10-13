#!/usr/bin/env python3
"""Short-command camera shell helper (BusyBox-safe, line-marker based)."""
from __future__ import annotations
import argparse, re, sys, time, uuid
from pathlib import Path
import serial

PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"


def open_port(port: str = PORT) -> serial.Serial:
    s = serial.Serial()
    s.port = port
    s.baudrate = 115200
    s.bytesize = serial.EIGHTBITS
    s.parity = serial.PARITY_NONE
    s.stopbits = serial.STOPBITS_ONE
    s.timeout = 0.2
    s.write_timeout = 5
    s.xonxoff = s.rtscts = s.dsrdtr = False
    s.dtr = False
    s.open()
    try:
        s.dtr = True
    except Exception:
        pass
    time.sleep(0.2)
    s.reset_input_buffer()
    return s


def wl(ser, line: str) -> None:
    if len(line) > 100:
        raise ValueError(f"cmd too long: {len(line)}")
    ser.write((line + "\n").encode())
    ser.flush()


def run(ser, cmd: str, timeout: float = 30) -> str:
    tag = uuid.uuid4().hex[:8]
    b, e = f"B_{tag}", f"E_{tag}"
    br = re.compile(rf"(?m)^{re.escape(b)}\s*$")
    er = re.compile(rf"(?m)^{re.escape(e)}\s*$")
    # BusyBox ash rejects `cmd &; echo` — drop the semicolon after &
    if cmd.rstrip().endswith("&"):
        wl(ser, f"echo {b};{cmd} echo {e}")
    else:
        wl(ser, f"echo {b};{cmd};echo {e}")
    buf, saw, t0 = "", False, time.monotonic()
    while time.monotonic() - t0 < timeout:
        d = ser.read(8192)
        if d:
            t = d.decode("utf-8", errors="replace")
            buf += t
            sys.stdout.write(t)
            sys.stdout.flush()
            if not saw and br.search(buf):
                saw = True
            if saw and er.search(buf):
                break
        else:
            time.sleep(0.02)
    mb, me = br.search(buf), er.search(buf)
    if not mb or not me:
        return ""
    return buf[mb.end() : me.start()]


def ensure_shell(ser, user=None, password=None) -> bool:
    try:
        from cam_creds import load as _load_creds
        _c = _load_creds()
        user = user or _c["user"]
        password = password or _c["password"]
    except Exception:
        user = user or "root"
        password = password or ""
    if not password:
        raise RuntimeError("Set LOCALCAM_PASS or firmware/private/cam_creds.env")
    m = f"SH_{uuid.uuid4().hex[:6]}"
    wl(ser, f"echo {m}")
    t0 = time.monotonic()
    buf = ""
    while time.monotonic() - t0 < 3:
        d = ser.read(4096)
        if d:
            buf += d.decode("utf-8", errors="replace")
            if m in buf:
                return True
        else:
            time.sleep(0.02)
    # Reach a clean login prompt (do not send shell cmds as username)
    for _ in range(4):
        wl("")
        time.sleep(0.35)
        chunk = ser.read(8192).decode("utf-8", errors="replace")
        buf += chunk
        if "login:" in chunk.lower():
            break
        if "Password:" in chunk:
            wl("")  # abort half-login
            time.sleep(0.4)
            ser.read(4096)
    wl(user)
    time.sleep(0.7)
    ser.read(4096)
    wl(password)
    time.sleep(1.5)
    ser.read(8192)
    m2 = f"SH_{uuid.uuid4().hex[:6]}"
    wl(f"echo {m2}")
    t0 = time.monotonic()
    buf = ""
    while time.monotonic() - t0 < 5:
        d = ser.read(4096)
        if d:
            buf += d.decode("utf-8", errors="replace")
            if m2 in buf:
                return True
        else:
            time.sleep(0.02)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--cmd", action="append", default=[])
    ap.add_argument("-f", "--file", type=Path)
    ap.add_argument("-t", "--timeout", type=float, default=30)
    ap.add_argument("-o", "--out", type=Path)
    args = ap.parse_args()
    cmds = list(args.cmd)
    if args.file:
        cmds.extend(
            [
                ln.strip()
                for ln in args.file.read_text().splitlines()
                if ln.strip() and not ln.strip().startswith("#")
            ]
        )
    ser = open_port()
    if not ensure_shell(ser):
        print("LOGIN_FAIL", file=sys.stderr)
        return 2
    outs = []
    for c in cmds:
        print(f"\n### {c}\n", file=sys.stderr)
        outs.append(f"### CMD: {c}\n" + run(ser, c, args.timeout))
    ser.close()
    text = "\n".join(outs)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
