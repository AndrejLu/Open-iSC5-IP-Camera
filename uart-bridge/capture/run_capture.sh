#!/usr/bin/env bash
# Launch a managed UART capture session (receive-only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${ROOT}/venv/bin/python3"
if [[ ! -x "$PY" ]]; then
  PY="$(command -v python3)"
fi

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
BAUD="${BAUD:-115200}"
DURATION="${DURATION:-180}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
STATUS_FILE="${STATUS_FILE:-$LOG_DIR/capture_status.json}"
READY_FILE="${READY_FILE:-$LOG_DIR/capture_ready.txt}"
STDOUT_LOG="${STDOUT_LOG:-$LOG_DIR/capture_console.txt}"
PID_FILE="${PID_FILE:-$LOG_DIR/capture.pid}"

mkdir -p "$LOG_DIR"
rm -f "$READY_FILE"

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "ERROR: capture already running (pid $(cat "$PID_FILE"))" >&2
  exit 1
fi

# Prefer by-id path; fail early if missing.
if [[ ! -e "$PORT" ]]; then
  echo "ERROR: serial port not found: $PORT" >&2
  echo "Available by-id entries:" >&2
  ls -la /dev/serial/by-id/ >&2 || true
  exit 2
fi

# Resolve conflicts without killing anything.
if command -v fuser >/dev/null 2>&1; then
  if fuser "$PORT" >/dev/null 2>&1 || fuser "$(readlink -f "$PORT")" >/dev/null 2>&1; then
    echo "ERROR: another process owns $PORT — refusing to open." >&2
    fuser -v "$PORT" "$(readlink -f "$PORT")" 2>&1 || true
    exit 3
  fi
fi

nohup "$PY" "$ROOT/capture/uart_capture.py" \
  --port "$PORT" \
  --baud "$BAUD" \
  --duration "$DURATION" \
  --log-dir "$LOG_DIR" \
  --ready-file "$READY_FILE" \
  --status-file "$STATUS_FILE" \
  >"$STDOUT_LOG" 2>"$LOG_DIR/capture_host.txt" &
echo $! >"$PID_FILE"
echo "Started capture pid=$(cat "$PID_FILE")"
echo "Waiting for READY..."
for _ in $(seq 1 50); do
  if [[ -f "$READY_FILE" ]]; then
    cat "$READY_FILE"
    exit 0
  fi
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Capture process exited early:" >&2
    cat "$LOG_DIR/capture_host.txt" >&2 || true
    exit 4
  fi
  sleep 0.1
done
echo "WARNING: timed out waiting for READY; check $LOG_DIR/capture_host.txt" >&2
exit 5
