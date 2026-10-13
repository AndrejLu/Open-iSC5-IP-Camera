#!/usr/bin/env python3
"""Push a local file to the camera via uuencode + uudecode (MD5 verify)."""
from __future__ import annotations
import argparse, hashlib, re, sys, time, uuid
from pathlib import Path
import serial

PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"
MAX_LINE = 100


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
    if len(line) > MAX_LINE:
        raise ValueError(f"cmd too long ({len(line)}): {line}")
    ser.write((line + "\n").encode())
    ser.flush()


def run(ser, cmd: str, timeout: float = 30) -> str:
    tag = uuid.uuid4().hex[:8]
    b, e = f"B_{tag}", f"E_{tag}"
    line = f"echo {b};{cmd};echo {e}"
    if len(line) > MAX_LINE:
        raise ValueError(f"wrapped cmd too long ({len(line)}): {cmd}")
    br = re.compile(rf"(?m)^{re.escape(b)}\s*$")
    er = re.compile(rf"(?m)^{re.escape(e)}\s*$")
    wl(ser, line)
    buf, saw, t0 = "", False, time.monotonic()
    while time.monotonic() - t0 < timeout:
        d = ser.read(8192)
        if d:
            buf += d.decode("utf-8", errors="replace")
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


def ensure_shell(ser) -> bool:
    m = f"SH_{uuid.uuid4().hex[:6]}"
    wl(ser, f"echo {m}")
    t0, buf = time.monotonic(), ""
    while time.monotonic() - t0 < 4:
        d = ser.read(4096)
        if d:
            buf += d.decode("utf-8", errors="replace")
            if m in buf:
                return True
        else:
            time.sleep(0.02)
    wl(ser, "")
    time.sleep(0.5)
    ser.read(8192)
    try:
        from cam_creds import load as _load_creds
        _c = _load_creds()
        _user, _pw = _c["user"], _c["password"]
    except Exception:
        _user, _pw = "root", ""
    if not _pw:
        raise RuntimeError("Set LOCALCAM_PASS or firmware/private/cam_creds.env")
    wl(ser, _user)
    time.sleep(0.4)
    ser.read(4096)
    wl(ser, _pw)
    time.sleep(1.2)
    ser.read(8192)
    m2 = f"SH_{uuid.uuid4().hex[:6]}"
    wl(ser, f"echo {m2}")
    t0, buf = time.monotonic(), ""
    while time.monotonic() - t0 < 5:
        d = ser.read(4096)
        if d:
            buf += d.decode("utf-8", errors="replace")
            if m2 in buf:
                return True
        else:
            time.sleep(0.02)
    return False


def uuencode(data: bytes, name: str = "x") -> list[str]:
    lines = [f"begin 644 {name}"]
    for i in range(0, len(data), 45):
        chunk = data[i : i + 45]
        n = len(chunk)
        raw = chunk + b"\0" * ((3 - (len(chunk) % 3)) % 3)
        enc = [32 + (n & 63)]
        for j in range(0, len(raw), 3):
            a, b, c = raw[j], raw[j + 1], raw[j + 2]
            enc += [
                32 + ((a >> 2) & 63),
                32 + (((a & 3) << 4) | (b >> 4)),
                32 + (((b & 15) << 2) | (c >> 6)),
                32 + (c & 63),
            ]
        s = bytes(enc).decode("ascii").replace(" ", "`")
        lines.append(s)
    lines += ["`", "end"]
    return lines


def push(ser, local: Path, remote: str) -> None:
    data = local.read_bytes()
    md5 = hashlib.md5(data).hexdigest()
    parent = str(Path(remote).parent)
    run(ser, f"mkdir -p {parent}", timeout=10)
    run(ser, "rm -f /tmp/u /tmp/x", timeout=10)
    run(ser, f"rm -f {remote}", timeout=10)

    lines = uuencode(data, "x")
    total = len(lines)
    for i, ln in enumerate(lines, 1):
        # Shell-safe single-quoted string (escape embedded ')
        q = "'" + ln.replace("'", "'\\''") + "'"
        cmd = f"echo {q}>>/tmp/u"
        if len(cmd) > MAX_LINE:
            # Rare: many quotes — append via printf %s and \xNN is awkward; use two echos
            # Write length-prefixed hex of the line instead into sidecar, then convert
            raise SystemExit(f"uu append too long ({len(cmd)}): len={len(ln)}")
        wl(ser, cmd)
        time.sleep(0.05)
        ser.read(8192)
        if i % 25 == 0 or i == total:
            print(f"[push] uu {i}/{total}", flush=True)

    # decode to /tmp/x then copy (keeps serial cmds short; avoids long mv paths)
    out = run(ser, "cd /tmp;uudecode /tmp/u", timeout=60)
    print(f"[push] uudecode:{out!r}", flush=True)
    parent = str(Path(remote).parent)
    run(ser, f"mkdir -p {parent}", timeout=15)
    # Two-step copy if remote path is long
    run(ser, "cp /tmp/x /tmp/recv", timeout=15)
    run(ser, f"cp /tmp/recv {remote}", timeout=30)
    run(ser, "rm -f /tmp/u /tmp/x /tmp/recv", timeout=10)
    got = run(ser, f"md5sum {remote}", timeout=30)
    if md5 not in got.replace("\n", " "):
        sz = run(ser, f"wc -c {remote}", timeout=10)
        raise SystemExit(f"MD5 mismatch got={got!r} expected={md5} size={sz!r}")
    print(f"[push] OK {remote} md5={md5} size={len(data)}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("local", type=Path)
    ap.add_argument("remote")
    args = ap.parse_args()
    ser = open_port()
    if not ensure_shell(ser):
        print("LOGIN_FAIL", file=sys.stderr)
        return 2
    push(ser, args.local, args.remote)
    ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
