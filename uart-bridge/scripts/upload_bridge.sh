#!/usr/bin/env bash
# Upload CameraUartBridge to UDOO X86 Curie via tight 1200bps→DFU path.
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FQBN="Intel:arc32:arduino_101"
SKETCH="${SKETCH:-$ROOT/arduino/CameraUartBridge}"
PORT="${PORT:-}"
if [[ -z "$PORT" ]]; then
  for cand in /dev/serial/by-id/usb-UDOO_UDOO_X86__*-if00 \
              /dev/serial/by-id/usb-Intel_Arduino_101_*-if00; do
    [[ -e "$cand" ]] || continue
    PORT="$cand"
    break
  done
fi
PORT="${PORT:-/dev/ttyACM0}"
LOG="$ROOT/docs/upload_log.txt"
NAME="$(basename "$SKETCH")"

arduino-cli compile --fqbn "$FQBN" "$SKETCH"
BIN="$(find /home/<user>/.cache/arduino/sketches -name "${NAME}.ino.bin" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
if [[ -z "${BIN}" || ! -f "${BIN}" ]]; then
  echo "ERROR: compiled .bin not found for $NAME" >&2
  exit 1
fi
echo "Using BIN=$BIN"

python3 - "$PORT" "$BIN" <<'PY' | tee "$LOG"
import serial, subprocess, time, os, sys, tempfile, glob

port, binpath = sys.argv[1], sys.argv[2]
if not os.path.exists(port):
    cands = sorted(glob.glob("/dev/ttyACM*"))
    if not cands:
        raise SystemExit("ERROR: no serial port for 1200bps touch")
    port = cands[0]
dfu = os.path.expanduser(
    "~/.arduino15/packages/arduino/tools/dfu-util/0.9.0-arduino1/dfu-util"
)

def usb():
    return subprocess.check_output(["lsusb"]).decode()

def in_dfu():
    return "8087:0aba" in usb()

print("1200bps touch on", port)
serial.Serial(port, 1200).close()
t0 = time.time()
while not in_dfu():
    if time.time() - t0 > 5:
        raise SystemExit("ERROR: DFU not entered")
    time.sleep(0.02)
print(f"DFU in {time.time()-t0:.3f}s")

trap = tempfile.NamedTemporaryFile(prefix="curie_trap_", suffix=".bin", delete=False)
trap.close()
try:
    subprocess.run(
        [dfu, "-d", "8087:0aba", "-a", "4", "-U", trap.name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
    )
finally:
    try:
        os.unlink(trap.name)
    except OSError:
        pass

print("Flashing sensor_core alt7...")
r = subprocess.run(
    [dfu, "-d", "8087:0aba", "-a", "7", "-D", binpath, "-R"],
    text=True,
    capture_output=True,
)
print(r.stdout)
print(r.stderr)
if r.returncode != 0:
    raise SystemExit(f"dfu-util failed: {r.returncode}")
for _ in range(50):
    if os.path.exists("/dev/ttyACM0"):
        break
    time.sleep(0.1)
print("SUCCESS")
PY
