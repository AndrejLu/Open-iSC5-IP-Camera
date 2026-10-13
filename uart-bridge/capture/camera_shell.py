#!/usr/bin/env python3
"""
Run commands on the camera over the Curie bridge with START/END markers.
Handles noisy kernel logs by extracting between unique markers.
"""

from __future__ import annotations

import argparse
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import serial
from serial import SerialException

DEFAULT_PORT = "/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00"


def open_port(port: str) -> serial.Serial:
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = 115200
    ser.bytesize = serial.EIGHTBITS
    ser.parity = serial.PARITY_NONE
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout = 0.15
    ser.write_timeout = 5
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


def drain(ser: serial.Serial, seconds: float = 0.5) -> str:
    end = time.monotonic() + seconds
    out = []
    while time.monotonic() < end:
        d = ser.read(4096)
        if d:
            out.append(d.decode("utf-8", errors="replace"))
        else:
            time.sleep(0.02)
    return "".join(out)


def write_line(ser: serial.Serial, s: str) -> None:
    ser.write((s + "\n").encode("utf-8"))
    ser.flush()


def ensure_shell(ser: serial.Serial, user: str, password: str, log: list[str]) -> bool:
    write_line(ser, "")
    buf = drain(ser, 1.5)
    log.append(buf)
    sys.stdout.write(buf)
    sys.stdout.flush()

    marker = f"SH_{uuid.uuid4().hex[:8]}"
    write_line(ser, f"echo {marker}")
    end = time.monotonic() + 4
    got = ""
    while time.monotonic() < end:
        d = ser.read(4096)
        if d:
            t = d.decode("utf-8", errors="replace")
            got += t
            log.append(t)
            sys.stdout.write(t)
            sys.stdout.flush()
            if marker in got:
                return True
        else:
            time.sleep(0.02)

    # Need login
    write_line(ser, "")
    buf = drain(ser, 2.0)
    log.append(buf)
    sys.stdout.write(buf)

    # If login prompt
    if "login:" in buf.lower() or "login:" in got.lower():
        write_line(ser, user)
        time.sleep(0.3)
        pw_wait = drain(ser, 2.0)
        log.append(pw_wait)
        sys.stdout.write(pw_wait)
        write_line(ser, password)
        after = drain(ser, 3.0)
        log.append(after)
        sys.stdout.write(after)
        if "Login incorrect" in after:
            return False

    marker2 = f"SH_{uuid.uuid4().hex[:8]}"
    write_line(ser, f"echo {marker2}")
    end = time.monotonic() + 6
    got = ""
    while time.monotonic() < end:
        d = ser.read(4096)
        if d:
            t = d.decode("utf-8", errors="replace")
            got += t
            log.append(t)
            sys.stdout.write(t)
            if marker2 in got:
                return True
        else:
            time.sleep(0.02)
    return False


def run_cmd(ser: serial.Serial, cmd: str, timeout: float, log: list[str]) -> str:
    """Run cmd; return stdout between BEGIN/END markers (best-effort strip of echo/noise)."""
    tag = uuid.uuid4().hex[:10]
    begin = f"BEGIN_{tag}"
    endm = f"END_{tag}"
    # Use a compound command; redirect stderr into the capture where possible
    wrapped = f"echo {begin}; ( {cmd} ) 2>&1; echo {endm}"
    write_line(ser, wrapped)

    deadline = time.monotonic() + timeout
    buf = ""
    while time.monotonic() < deadline:
        d = ser.read(8192)
        if d:
            t = d.decode("utf-8", errors="replace")
            buf += t
            log.append(t)
            sys.stdout.write(t)
            sys.stdout.flush()
            if endm in buf and begin in buf:
                # allow a little more for trailing prompt
                time.sleep(0.15)
                extra = ser.read(4096)
                if extra:
                    te = extra.decode("utf-8", errors="replace")
                    buf += te
                    log.append(te)
                    sys.stdout.write(te)
                break
        else:
            time.sleep(0.02)

    # Extract between markers
    m = re.search(
        re.escape(begin) + r"[^\n]*\n(.*)\n" + re.escape(endm),
        buf,
        re.S,
    )
    if m:
        return m.group(1)
    # Fallback: looser
    i0 = buf.find(begin)
    i1 = buf.find(endm)
    if i0 >= 0 and i1 > i0:
        chunk = buf[i0 + len(begin) :]
        # drop rest of first line
        nl = chunk.find("\n")
        if nl >= 0:
            chunk = chunk[nl + 1 :]
        chunk = chunk[: chunk.find(endm)]
        return chunk
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=DEFAULT_PORT)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="ismart12")
    ap.add_argument("--transcript", type=Path, required=True)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--mode", choices=["diag", "backup", "shell-check"], default="diag")
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    log: list[str] = []
    log.append(f"\n===== {datetime.now(timezone.utc).isoformat()} mode={args.mode} =====\n")

    try:
        ser = open_port(args.port)
    except SerialException as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if not ensure_shell(ser, args.user, args.password, log):
        args.transcript.write_text("".join(log), encoding="utf-8")
        print("ERROR: could not obtain shell", file=sys.stderr)
        ser.close()
        return 3

    print("\n[host] shell ready", file=sys.stderr)

    if args.mode == "shell-check":
        out = run_cmd(ser, "id; uname -a", 10, log)
        (args.out_dir / "shell_check.txt").write_text(out, encoding="utf-8")
        args.transcript.write_text("".join(log), encoding="utf-8")
        ok = "uid=" in out and "Linux" in out
        ser.close()
        return 0 if ok else 5

    if args.mode == "diag":
        commands = [
            ("id.txt", "id", 8),
            ("uname.txt", "uname -a", 8),
            ("cpuinfo.txt", "cat /proc/cpuinfo", 15),
            ("meminfo.txt", "cat /proc/meminfo", 15),
            ("mtd.txt", "cat /proc/mtd", 10),
            ("mounts.txt", "cat /proc/mounts", 15),
            ("df.txt", "df -h", 15),
            ("ifconfig.txt", "ifconfig -a 2>/dev/null || ifconfig", 15),
            ("route.txt", "route -n 2>/dev/null; ip route 2>/dev/null", 10),
            ("ps.txt", "ps 2>/dev/null || ps aux 2>/dev/null || ps w", 25),
            ("lsmod.txt", "lsmod 2>/dev/null; cat /proc/modules 2>/dev/null", 15),
            ("netstat.txt", "netstat -lntp 2>/dev/null; netstat -an 2>/dev/null | head -200", 25),
            ("cmdline.txt", "cat /proc/cmdline", 8),
            ("version.txt", "cat /etc/version 2>/dev/null; cat /etc/os-release 2>/dev/null; ls /etc/app 2>/dev/null | head", 15),
            ("fang_find.txt", "ls -la /media/mmcblk0p1/bootstrap 2>/dev/null; ls -la /media/mmcblk0p2/data 2>/dev/null; ls -la /media/mmcblk0p2/data/etc/scripts 2>/dev/null; cat /media/mmcblk0p2/data/etc/fang.conf 2>/dev/null; cat /media/mmcblk0p2/data/etc/*.conf 2>/dev/null | head -200", 30),
            ("startup.txt", "ls -la /etc/init.d 2>/dev/null; ls -la /etc/rc 2>/dev/null; ls -la /etc/app 2>/dev/null; head -100 /etc/init.d/rcS 2>/dev/null", 25),
            ("video_libs.txt", "ls -la /lib/modules 2>/dev/null; ls /lib/modules/*/ 2>/dev/null; find /lib /usr/lib -name '*snx*' -o -name '*isp*' -o -name '*vc*' 2>/dev/null | head -80", 40),
            ("tools.txt", "which md5sum sha256sum sha1sum dd cat base64 uuencode hexdump openssl nc scp tftp curl wget busybox 2>/dev/null; busybox 2>&1 | head -5; ls /bin /sbin /usr/bin 2>/dev/null | tr ' ' '\\n' | sort -u | head -200", 30),
            ("mtd_detail.txt", "cat /proc/mtd; ls -la /dev/mtd* 2>/dev/null; for i in 0 1 2 3 4 5; do echo === mtd$i ===; cat /sys/class/mtd/mtd$i/name 2>/dev/null; cat /sys/class/mtd/mtd$i/size 2>/dev/null; cat /sys/class/mtd/mtd$i/type 2>/dev/null; done", 20),
            ("sd_space.txt", "df -h /media/mmcblk0p1 /media/mmcblk0p2 2>/dev/null; mount | grep mmc; touch /media/mmcblk0p2/data/.write_test_$$ && echo WRITE_OK && rm -f /media/mmcblk0p2/data/.write_test_$$", 20),
        ]
        for fname, cmd, to in commands:
            print(f"\n[host] >>> {fname}: {cmd[:60]}...", file=sys.stderr)
            out = run_cmd(ser, cmd, to, log)
            (args.out_dir / fname).write_text(out, encoding="utf-8")
        args.transcript.write_text("".join(log), encoding="utf-8")
        ser.close()
        print("[host] diagnostics complete", file=sys.stderr)
        return 0

    ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
