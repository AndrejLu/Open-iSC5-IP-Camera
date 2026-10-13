#!/usr/bin/env python3
"""Pull pre-dumped MTD files from camera SD via filtered hexdump lines over serial."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import uuid
from pathlib import Path

import serial

DEFAULT_PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"
FULL_SIZE = 16 * 1024 * 1024
HEX_LINE = re.compile(r"(?m)^([0-9a-f]{32})\s*$")


def open_port(port: str) -> serial.Serial:
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = 115200
    ser.bytesize = serial.EIGHTBITS
    ser.parity = serial.PARITY_NONE
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout = 0.2
    ser.write_timeout = 10
    ser.xonxoff = False
    ser.rtscts = False
    ser.dsrdtr = False
    ser.dtr = False
    ser.open()
    try:
        ser.dtr = True
    except Exception:
        pass
    time.sleep(0.2)
    ser.reset_input_buffer()
    return ser


def write_line(ser: serial.Serial, s: str) -> None:
    if len(s) > 100:
        raise ValueError(f"too long ({len(s)}): {s}")
    ser.write((s + "\n").encode())
    ser.flush()


def run_cmd(ser: serial.Serial, cmd: str, timeout: float) -> str:
    tag = uuid.uuid4().hex[:8]
    begin, endm = f"B_{tag}", f"E_{tag}"
    begin_re = re.compile(rf"(?m)^{re.escape(begin)}\s*$")
    end_re = re.compile(rf"(?m)^{re.escape(endm)}\s*$")
    write_line(ser, f"echo {begin};{cmd};echo {endm}")
    deadline = time.monotonic() + timeout
    buf = ""
    saw = False
    while time.monotonic() < deadline:
        d = ser.read(16384)
        if d:
            t = d.decode("utf-8", errors="replace")
            buf += t
            # don't flood stdout with megabytes of hex — optional quiet
            if "hexdump" not in cmd:
                sys.stdout.write(t)
                sys.stdout.flush()
            if not saw and begin_re.search(buf):
                saw = True
            if saw and end_re.search(buf):
                time.sleep(0.1)
                extra = ser.read(8192)
                if extra:
                    buf += extra.decode("utf-8", errors="replace")
                break
        else:
            time.sleep(0.02)
    mb, me = begin_re.search(buf), end_re.search(buf)
    if not mb or not me or me.start() <= mb.end():
        return ""
    return buf[mb.end() : me.start()]


def ensure_shell(ser: serial.Serial) -> bool:
    m = f"SH_{uuid.uuid4().hex[:6]}"
    write_line(ser, f"echo {m}")
    end = time.monotonic() + 5
    buf = ""
    while time.monotonic() < end:
        d = ser.read(4096)
        if d:
            buf += d.decode("utf-8", errors="replace")
            if m in buf:
                return True
        else:
            time.sleep(0.02)
    return False


def parse_md5(text: str) -> str | None:
    for line in text.splitlines():
        m = re.match(r"^([0-9a-f]{32})\s+", line.strip())
        if m:
            return m.group(1)
    return None


def hex_body_to_bytes(text: str) -> bytes:
    parts = HEX_LINE.findall(text.replace("\r", ""))
    return b"".join(bytes.fromhex(p) for p in parts)


def pull_one(
    ser: serial.Serial,
    remote: str,
    local: Path,
    size: int,
    expect_md5: str,
    chunk_size: int,
) -> str:
    n_chunks = (size + chunk_size - 1) // chunk_size
    assembled = bytearray()

    for i in range(n_chunks):
        offset = i * chunk_size
        length = min(chunk_size, size - offset)
        bs = 1024
        assert offset % bs == 0
        skip = offset // bs
        count = length // bs
        if length % bs:
            bs, skip, count = 1, offset, length

        print(
            f"[host] {local.name} chunk {i+1}/{n_chunks} off={offset} len={length}",
            file=sys.stderr,
            flush=True,
        )
        ok = False
        for attempt in range(6):
            run_cmd(
                ser,
                f"dd if={remote} of=/tmp/c.bin bs={bs} skip={skip} count={count} 2>/dev/null",
                90,
            )
            md = parse_md5(run_cmd(ser, "md5sum /tmp/c.bin", 30))
            # hexdump between markers — filter lines on host
            # Keep command short: use fixed format
            body = run_cmd(
                ser,
                "hexdump -v -e '16/1 \"%02x\" \"\\n\"' /tmp/c.bin",
                180,
            )
            data = hex_body_to_bytes(body)
            if len(data) != length:
                print(
                    f"[host] len {len(data)}!={length} lines~={len(HEX_LINE.findall(body))} try {attempt+1}",
                    file=sys.stderr,
                    flush=True,
                )
                continue
            got = hashlib.md5(data).hexdigest()
            if md and got != md:
                print(f"[host] md5 {got}!={md} try {attempt+1}", file=sys.stderr, flush=True)
                continue
            assembled.extend(data)
            ok = True
            print(f"[host] chunk {i+1} OK md5={got}", file=sys.stderr, flush=True)
            break
        run_cmd(ser, "rm -f /tmp/c.bin", 5)
        if not ok:
            raise RuntimeError(f"failed chunk {i} of {remote}")

    if len(assembled) != size:
        raise RuntimeError(f"size {len(assembled)}!={size}")
    md5 = hashlib.md5(assembled).hexdigest()
    if md5 != expect_md5:
        raise RuntimeError(f"file md5 {md5}!={expect_md5}")
    local.write_bytes(bytes(assembled))
    print(
        f"[host] wrote {local} sha256={hashlib.sha256(bytes(assembled)).hexdigest()}",
        file=sys.stderr,
        flush=True,
    )
    return md5


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=DEFAULT_PORT)
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--host-dir", type=Path, required=True)
    ap.add_argument("--chunk-size", type=int, default=32768)
    args = ap.parse_args()

    info = json.loads(args.manifest.read_text(encoding="utf-8"))
    args.host_dir.mkdir(parents=True, exist_ok=True)
    ser = open_port(args.port)
    if not ensure_shell(ser):
        write_line(ser, "root")
        time.sleep(0.5)
        ser.read(4096)
        write_line(ser, "ismart12")
        time.sleep(1.5)
        ser.read(8192)
        if not ensure_shell(ser):
            print("no shell", file=sys.stderr)
            return 3

    run_cmd(ser, "dmesg -n 1", 5)
    run_cmd(ser, "stty cols 200 2>/dev/null||true", 5)
    run_cmd(ser, "ifconfig wlan0 down 2>/dev/null;true", 5)
    run_cmd(ser, "killall -q wpa_supplicant udhcpc 2>/dev/null;true", 5)
    run_cmd(ser, f"D={info['camera_dir']}", 5)

    local_parts = []
    for rec in info["parts"]:
        n = rec["dev"].replace("mtdblock", "")
        local = args.host_dir / f"{rec['dev']}_{rec['name']}.bin"
        if local.exists() and local.stat().st_size == rec["expected_size"]:
            if hashlib.md5(local.read_bytes()).hexdigest() == rec["md5"]:
                print(f"[host] skip existing {local.name}", file=sys.stderr, flush=True)
                rec["host_path"] = str(local)
                rec["host_md5"] = rec["md5"]
                rec["host_sha256"] = hashlib.sha256(local.read_bytes()).hexdigest()
                rec["transfer_ok"] = True
                local_parts.append(local)
                continue

        print(f"[host] transferring {rec['name']}...", file=sys.stderr, flush=True)
        md5 = pull_one(
            ser,
            f"$D/{n}.bin",
            local,
            rec["expected_size"],
            rec["md5"],
            args.chunk_size,
        )
        data = local.read_bytes()
        rec["host_path"] = str(local)
        rec["host_md5"] = md5
        rec["host_sha256"] = hashlib.sha256(data).hexdigest()
        rec["transfer_ok"] = True
        local_parts.append(local)
        args.manifest.write_text(json.dumps(info, indent=2) + "\n")

    full_path = args.host_dir / "flash_full_16MiB.bin"
    with full_path.open("wb") as out:
        for p in local_parts:
            out.write(p.read_bytes())
    full = full_path.read_bytes()
    if len(full) != FULL_SIZE:
        print(f"ERROR full size {len(full)}", file=sys.stderr)
        return 4
    info["full_image"] = {
        "path": str(full_path),
        "size": len(full),
        "md5": hashlib.md5(full).hexdigest(),
        "sha256": hashlib.sha256(full).hexdigest(),
    }
    args.manifest.write_text(json.dumps(info, indent=2) + "\n")
    run_cmd(ser, "dmesg -n 7", 5)
    ser.close()
    print(json.dumps(info["full_image"], indent=2))
    print("BACKUP_OK", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
