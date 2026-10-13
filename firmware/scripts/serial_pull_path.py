#!/usr/bin/env python3
"""Pull an arbitrary remote file from the camera via hexdump + MD5 chunks."""
from __future__ import annotations
import argparse, hashlib, re, sys, time, uuid
from pathlib import Path
import serial

PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"
HEX_LINE = re.compile(r"(?m)^([0-9a-f]{32})\s*$")
MAX_LINE = 100


def open_port(port: str = PORT) -> serial.Serial:
    s = serial.Serial()
    s.port = port
    s.baudrate = 115200
    s.bytesize = serial.EIGHTBITS
    s.parity = serial.PARITY_NONE
    s.stopbits = serial.STOPBITS_ONE
    s.timeout = 0.2
    s.write_timeout = 10
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
        raise ValueError(f"too long ({len(line)}): {line}")
    ser.write((line + "\n").encode())
    ser.flush()


def run(ser, cmd: str, timeout: float = 60) -> str:
    tag = uuid.uuid4().hex[:8]
    b, e = f"B_{tag}", f"E_{tag}"
    line = f"echo {b};{cmd};echo {e}"
    if len(line) > MAX_LINE:
        raise ValueError(f"wrapped too long: {cmd}")
    br = re.compile(rf"(?m)^{re.escape(b)}\s*$")
    er = re.compile(rf"(?m)^{re.escape(e)}\s*$")
    wl(ser, line)
    buf, saw, t0 = "", False, time.monotonic()
    while time.monotonic() - t0 < timeout:
        d = ser.read(16384)
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


def pull(ser, remote: str, local: Path, chunk: int = 16384) -> None:
    # remote path must be short enough for dd cmds — use /tmp/r symlink
    run(ser, "rm -f /tmp/r", timeout=5)
    # ln -s may exceed length; cp to /tmp/r if path long
    if len(remote) < 40:
        run(ser, f"ln -sf {remote} /tmp/r", timeout=10)
    else:
        run(ser, f"cp {remote} /tmp/r", timeout=120)
    out = run(ser, "wc -c /tmp/r", timeout=15)
    m = re.search(r"(\d+)", out)
    if not m:
        raise SystemExit(f"cannot size remote: {out!r}")
    size = int(m.group(1))
    expect = run(ser, "md5sum /tmp/r", timeout=60)
    em = re.search(r"([0-9a-f]{32})", expect)
    if not em:
        raise SystemExit(f"no md5: {expect!r}")
    expect_md5 = em.group(1)
    print(f"[pull] {remote} size={size} md5={expect_md5}", flush=True)

    assembled = bytearray()
    n_chunks = (size + chunk - 1) // chunk
    for i in range(n_chunks):
        offset = i * chunk
        length = min(chunk, size - offset)
        bs = 1024
        skip = offset // bs
        count = length // bs
        if length % bs:
            bs, skip, count = 1, offset, length
        ok = False
        for attempt in range(5):
            run(ser, f"dd if=/tmp/r of=/tmp/c.bin bs={bs} skip={skip} count={count}", timeout=90)
            body = run(ser, "hexdump -v -e '16/1 \"%02x\" \"\\n\"' /tmp/c.bin", timeout=180)
            # quiet: don't print body
            parts = HEX_LINE.findall(body.replace("\r", ""))
            data = b"".join(bytes.fromhex(p) for p in parts)
            if len(data) != length:
                print(f"[pull] chunk {i+1} len {len(data)}!={length} try {attempt+1}", flush=True)
                continue
            assembled.extend(data)
            ok = True
            print(f"[pull] chunk {i+1}/{n_chunks} OK", flush=True)
            break
        run(ser, "rm -f /tmp/c.bin", timeout=5)
        if not ok:
            raise SystemExit(f"failed chunk {i}")
    md5 = hashlib.md5(assembled).hexdigest()
    if md5 != expect_md5:
        raise SystemExit(f"md5 mismatch {md5}!={expect_md5}")
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_bytes(bytes(assembled))
    print(f"[pull] OK {local} sha256={hashlib.sha256(bytes(assembled)).hexdigest()}", flush=True)
    run(ser, "rm -f /tmp/r", timeout=5)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("remote")
    ap.add_argument("local", type=Path)
    ap.add_argument("--chunk", type=int, default=16384)
    args = ap.parse_args()
    ser = open_port()
    if not ensure_shell(ser):
        print("LOGIN_FAIL", file=sys.stderr)
        return 2
    run(ser, "dmesg -n 1", timeout=5)
    pull(ser, args.remote, args.local, chunk=args.chunk)
    ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
