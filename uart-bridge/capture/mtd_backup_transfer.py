#!/usr/bin/env python3
"""
Dump camera MTD partitions to SD, then pull them to the host via uuencode chunks.
Uses short commands to avoid ~80-col serial line wrap corruption.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import serial
from serial import SerialException

DEFAULT_PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"

EXPECTED = [
    ("0", "uboot", 768 * 1024),
    ("1", "kernel", 3072 * 1024),
    ("2", "rootfs", 7168 * 1024),
    ("3", "rescue", 4096 * 1024),
    ("4", "etc", 1024 * 1024),
    ("5", "userconfig", 256 * 1024),
]
FULL_SIZE = 16 * 1024 * 1024


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
    # Camera getty historically wraps near 80; keep under that with margin.
    if len(s) > 100:
        raise ValueError(f"command too long ({len(s)}): {s[:60]}...")
    ser.write((s + "\n").encode("utf-8"))
    ser.flush()


def run_cmd(ser: serial.Serial, cmd: str, timeout: float) -> str:
    """Run cmd; markers matched only as whole lines to avoid echo false-positives."""
    tag = uuid.uuid4().hex[:8]
    begin, endm = f"B_{tag}", f"E_{tag}"
    begin_re = re.compile(rf"(?m)^{re.escape(begin)}\s*$")
    end_re = re.compile(rf"(?m)^{re.escape(endm)}\s*$")
    write_line(ser, f"echo {begin};{cmd};echo {endm}")
    deadline = time.monotonic() + timeout
    buf = ""
    saw_begin = False
    while time.monotonic() < deadline:
        d = ser.read(8192)
        if d:
            t = d.decode("utf-8", errors="replace")
            buf += t
            sys.stdout.write(t)
            sys.stdout.flush()
            if not saw_begin and begin_re.search(buf):
                saw_begin = True
            if saw_begin and end_re.search(buf):
                time.sleep(0.15)
                extra = ser.read(8192)
                if extra:
                    te = extra.decode("utf-8", errors="replace")
                    buf += te
                    sys.stdout.write(te)
                break
        else:
            time.sleep(0.02)
    mb = begin_re.search(buf)
    me = end_re.search(buf)
    if not mb or not me or me.start() <= mb.end():
        return ""
    return buf[mb.end() : me.start()]


def ensure_shell(ser: serial.Serial, user: str, password: str) -> bool:
    marker = f"SH_{uuid.uuid4().hex[:6]}"
    write_line(ser, f"echo {marker}")
    end = time.monotonic() + 5
    buf = ""
    while time.monotonic() < end:
        d = ser.read(4096)
        if d:
            t = d.decode("utf-8", errors="replace")
            buf += t
            sys.stdout.write(t)
            sys.stdout.flush()
            if marker in buf:
                return True
        else:
            time.sleep(0.02)
    write_line(ser, "")
    time.sleep(1)
    ser.read(8192)
    write_line(ser, user)
    time.sleep(0.5)
    ser.read(8192)
    write_line(ser, password)
    time.sleep(2)
    ser.read(8192)
    marker2 = f"SH_{uuid.uuid4().hex[:6]}"
    write_line(ser, f"echo {marker2}")
    end = time.monotonic() + 6
    buf = ""
    while time.monotonic() < end:
        d = ser.read(4096)
        if d:
            t = d.decode("utf-8", errors="replace")
            buf += t
            sys.stdout.write(t)
            sys.stdout.flush()
            if marker2 in buf:
                return True
        else:
            time.sleep(0.02)
    return False


def quiet_console(ser: serial.Serial) -> None:
    run_cmd(ser, "dmesg -n 1", 5)
    run_cmd(ser, "stty cols 200 2>/dev/null||true", 5)


def parse_md5(text: str) -> str | None:
    for line in text.splitlines():
        m = re.match(r"^([0-9a-f]{32})\s+", line.strip())
        if m:
            return m.group(1)
    return None


def parse_sha1(text: str) -> str | None:
    for line in text.splitlines():
        m = re.match(r"^([0-9a-f]{40})\s+", line.strip())
        if m:
            return m.group(1)
    return None


def parse_int_line(text: str) -> int | None:
    for line in text.splitlines():
        s = line.strip()
        if re.fullmatch(r"\d+", s):
            return int(s)
    return None


def dump_partitions(ser: serial.Serial, bdir: str) -> dict:
    """bdir is short path; use shell var D to keep lines short."""
    info = {"backup_dir": bdir, "parts": []}
    run_cmd(ser, f"D={bdir}", 5)
    run_cmd(ser, "mkdir -p $D", 10)
    run_cmd(ser, "df -h /media/mmcblk0p2", 10)
    out = run_cmd(ser, "touch $D/w&&rm $D/w&&echo PREP_OK", 10)
    if "PREP_OK" not in out:
        raise RuntimeError(f"Cannot write backup dir: {out!r}")

    for n, name, size in EXPECTED:
        path = f"{bdir}/{n}.bin"
        print(f"\n[host] dump mtdblock{n} ({name}) size={size}", file=sys.stderr)
        run_cmd(ser, f"D={bdir}", 5)
        run_cmd(ser, f"dd if=/dev/mtdblock{n} of=$D/{n}.bin bs=4096", 180)
        sz_out = run_cmd(ser, f"wc -c < $D/{n}.bin", 15)
        md_out = run_cmd(ser, f"md5sum $D/{n}.bin", 90)
        sh_out = run_cmd(ser, f"sha1sum $D/{n}.bin", 90)
        actual = parse_int_line(sz_out)
        md5 = parse_md5(md_out)
        sha1 = parse_sha1(sh_out)

        md5_b = None
        if name in ("etc", "userconfig"):
            run_cmd(ser, f"dd if=/dev/mtdblock{n} of=$D/{n}b.bin bs=4096", 180)
            md2 = run_cmd(ser, f"md5sum $D/{n}b.bin", 90)
            md5_b = parse_md5(md2)
            run_cmd(ser, f"rm -f $D/{n}b.bin", 10)

        rec = {
            "dev": f"mtdblock{n}",
            "name": name,
            "expected_size": size,
            "actual_size": actual,
            "path": path,
            "md5": md5,
            "sha1": sha1,
            "size_ok": actual == size,
            "pass2_md5": md5_b,
            "pass2_matches": (md5_b == md5) if md5_b else None,
        }
        info["parts"].append(rec)
        print(f"[host] {name}: size={actual} md5={md5} p2={rec['pass2_matches']}", file=sys.stderr)
        if actual != size or not md5:
            raise RuntimeError(f"Bad dump for {name}: {rec}")
    return info


def uudecode_text(text: str) -> bytes:
    """Minimal uu decoder (stdlib uu removed in newer Python)."""
    lines = text.replace("\r", "").split("\n")
    start = next((i for i, l in enumerate(lines) if l.startswith("begin ")), None)
    if start is None:
        raise ValueError("no begin")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip() == "end"), None)
    if end is None:
        raise ValueError("no end")
    out = bytearray()
    for line in lines[start + 1 : end]:
        if not line:
            continue
        # Ignore kernel log lines that snuck in
        if not (33 <= ord(line[0]) <= 96):
            continue
        nbytes = (ord(line[0]) - 32) & 0x3F
        if nbytes == 0:
            continue
        data = line[1:]
        # Pad
        while len(data) % 4:
            data += "`"
        i = 0
        produced = 0
        while produced < nbytes and i + 4 <= len(data):
            c1 = (ord(data[i]) - 32) & 0x3F
            c2 = (ord(data[i + 1]) - 32) & 0x3F
            c3 = (ord(data[i + 2]) - 32) & 0x3F
            c4 = (ord(data[i + 3]) - 32) & 0x3F
            i += 4
            chunk = bytes(
                [
                    (c1 << 2 | c2 >> 4) & 0xFF,
                    (c2 << 4 | c3 >> 2) & 0xFF,
                    (c3 << 6 | c4) & 0xFF,
                ]
            )
            take = min(3, nbytes - produced)
            out.extend(chunk[:take])
            produced += take
    return bytes(out)


def pull_file(
    ser: serial.Serial,
    remote_path: str,
    local_path: Path,
    expected_size: int,
    expected_md5: str,
    chunk_size: int = 32768,
) -> str:
    local_path.parent.mkdir(parents=True, exist_ok=True)
    n_chunks = (expected_size + chunk_size - 1) // chunk_size
    assembled = bytearray()

    for i in range(n_chunks):
        offset = i * chunk_size
        length = min(chunk_size, expected_size - offset)
        # Use bs=1024 when aligned
        assert offset % 1024 == 0
        assert length % 1024 == 0 or i == n_chunks - 1
        # For last chunk of userconfig 256K with 32K chunks, all align.
        bs = 1024
        skip = offset // bs
        count = (length + bs - 1) // bs
        # exact: length must be count*bs for non-last; pad handled by count
        if length % bs != 0:
            bs = 1
            skip = offset
            count = length

        cpath = f"/tmp/c{i}.bin"
        tag = uuid.uuid4().hex[:6]
        begin, endm = f"U{tag}", f"V{tag}"

        print(f"[host] chunk {i+1}/{n_chunks} off={offset} len={length}", file=sys.stderr)
        ok = False
        for attempt in range(5):
            run_cmd(ser, f"dd if={remote_path} of={cpath} bs={bs} skip={skip} count={count} 2>/dev/null", 60)
            # truncate if we over-read with bs=1024 rounding (shouldn't)
            md_out = run_cmd(ser, f"md5sum {cpath}", 20)
            cmd_md5 = parse_md5(md_out)
            # uuencode between markers — two short cmds
            write_line(ser, f"echo {begin}")
            time.sleep(0.05)
            # uuencode may be long output - don't wrap the command itself
            write_line(ser, f"uuencode {cpath} c")
            # collect until we see end line of uuencode then send end marker
            deadline = time.monotonic() + 90
            buf = begin + "\n"  # we'll search for begin already sent
            # Actually begin was echoed; read uuencode stream
            buf = ""
            saw_begin_line = False
            saw_uu_end = False
            while time.monotonic() < deadline:
                d = ser.read(8192)
                if d:
                    t = d.decode("utf-8", errors="replace")
                    buf += t
                    sys.stdout.write(t)
                    sys.stdout.flush()
                    if "begin " in buf:
                        saw_begin_line = True
                    if saw_begin_line and re.search(r"(?m)^end\s*$", buf):
                        saw_uu_end = True
                        break
                else:
                    time.sleep(0.02)
            write_line(ser, f"echo {endm}")
            # wait for endm
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and endm not in buf:
                d = ser.read(4096)
                if d:
                    t = d.decode("utf-8", errors="replace")
                    buf += t
                    sys.stdout.write(t)
                else:
                    time.sleep(0.02)

            run_cmd(ser, f"rm -f {cpath}", 5)

            if not saw_uu_end:
                print(f"[host] uu incomplete attempt {attempt+1}", file=sys.stderr)
                continue
            try:
                data = uudecode_text(buf)
            except Exception as e:
                print(f"[host] uudecode fail {attempt+1}: {e}", file=sys.stderr)
                continue
            # If dd used bs=1024 and count rounded up, trim
            if len(data) > length:
                data = data[:length]
            if len(data) != length:
                print(f"[host] len {len(data)}!={length} try {attempt+1}", file=sys.stderr)
                continue
            got = hashlib.md5(data).hexdigest()
            if cmd_md5 and got != cmd_md5:
                # if dd oversize then md5 of file != trimmed — compare file size
                print(f"[host] md5 cam={cmd_md5} host={got} try {attempt+1}", file=sys.stderr)
                # still accept host md5 of exact length if cam md5 was of padded file
                sz = run_cmd(ser, f"echo done", 3)  # no-op; already deleted
                # Prefer exact length match without cam md5 if trim happened
                if len(data) == length:
                    # re-get by using bs=1 for this chunk on retry
                    pass
                if got != cmd_md5:
                    # force bs=1 retry
                    if bs != 1:
                        bs = 1
                        skip = offset
                        count = length
                        continue
                    continue
            assembled.extend(data)
            ok = True
            break
        if not ok:
            raise RuntimeError(f"chunk {i} failed for {remote_path}")

    if len(assembled) != expected_size:
        raise RuntimeError(f"size {len(assembled)} != {expected_size}")
    md5 = hashlib.md5(assembled).hexdigest()
    if md5 != expected_md5:
        raise RuntimeError(f"md5 {md5} != {expected_md5}")
    local_path.write_bytes(bytes(assembled))
    print(f"[host] OK {local_path} md5={md5}", file=sys.stderr)
    return md5


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=DEFAULT_PORT)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="ismart12")
    ap.add_argument("--host-dir", type=Path, required=True)
    ap.add_argument("--stamp", default=None)
    ap.add_argument("--chunk-size", type=int, default=32768)
    ap.add_argument("--dump-only", action="store_true")
    ap.add_argument("--transfer-only", action="store_true")
    ap.add_argument("--manifest", type=Path, default=None)
    args = ap.parse_args()

    stamp = args.stamp or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    # Short path on camera
    bdir = f"/media/mmcblk0p2/data/fb"
    args.host_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = args.manifest or (args.host_dir / "MANIFEST.json")

    ser = open_port(args.port)
    if not ensure_shell(ser, args.user, args.password):
        print("ERROR: no shell", file=sys.stderr)
        ser.close()
        return 3
    quiet_console(ser)

    if not args.transfer_only:
        mtd = run_cmd(ser, "cat /proc/mtd", 10)
        print(mtd, file=sys.stderr)
        # clean previous
        run_cmd(ser, f"rm -rf {bdir}", 15)
        info = dump_partitions(ser, bdir)
        info["stamp"] = stamp
        info["camera_dir"] = bdir
        info["proc_mtd"] = mtd
        manifest_path.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
        if args.dump_only:
            ser.close()
            print(f"DUMP_OK {manifest_path}")
            return 0
    else:
        info = json.loads(manifest_path.read_text(encoding="utf-8"))
        bdir = info["camera_dir"]

    local_parts = []
    for rec in info["parts"]:
        local = args.host_dir / f"{rec['dev']}_{rec['name']}.bin"
        print(f"\n[host] transfer {rec['name']}...", file=sys.stderr)
        md5 = pull_file(
            ser,
            rec["path"],
            local,
            rec["expected_size"],
            rec["md5"],
            chunk_size=args.chunk_size,
        )
        data = local.read_bytes()
        rec["host_path"] = str(local)
        rec["host_md5"] = md5
        rec["host_sha256"] = hashlib.sha256(data).hexdigest()
        rec["transfer_ok"] = True
        local_parts.append(local)

    full_path = args.host_dir / "flash_full_16MiB.bin"
    with full_path.open("wb") as out:
        for p in local_parts:
            out.write(p.read_bytes())
    full = full_path.read_bytes()
    if len(full) != FULL_SIZE:
        print(f"ERROR full size {len(full)}", file=sys.stderr)
        ser.close()
        return 4
    info["full_image"] = {
        "path": str(full_path),
        "size": len(full),
        "md5": hashlib.md5(full).hexdigest(),
        "sha256": hashlib.sha256(full).hexdigest(),
    }
    manifest_path.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    run_cmd(ser, "dmesg -n 7", 5)
    ser.close()
    print(f"BACKUP_OK {full_path}", file=sys.stderr)
    print(json.dumps(info["full_image"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
