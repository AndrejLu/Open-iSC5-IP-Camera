#!/bin/sh
# Optional SD continuous recording from hardware RTSP (H.264 copy).
# Never formats the card. Never deletes non-localcam user recordings.
# Network outages do not stop recording (local RTSP loopback).

# shellcheck disable=SC1091
. "$(dirname "$0")/paths.sh" 2>/dev/null || . "$(dirname "$0")/../wifi/paths.sh" 2>/dev/null || true

REC_ROOT="${REC_ROOT:-}"
if [ -z "$REC_ROOT" ]; then
  for d in /media/mmcblk1p1/record/localcam /media/mmcblk0p1/record/localcam; do
    parent=$(dirname "$d")
    base=$(dirname "$parent")
    if [ -d "$base" ]; then REC_ROOT=$d; break; fi
  done
fi
REC_ROOT="${REC_ROOT:-/media/mmcblk0p1/record/localcam}"
SEG_SEC="${SEG_SEC:-300}"
MIN_FREE_KB="${MIN_FREE_KB:-102400}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:554/unicast}"
FFMPEG_BIN="${FFMPEG_BIN:-}"
# Prefer any available arm ffmpeg/openRTSP on fang SD
for c in \
  "$FH_BIN/ffmpeg" /media/mmcblk1p2/data/bin/ffmpeg /media/mmcblk0p2/data/bin/ffmpeg \
  "$FH_BIN/openRTSP" /usr/bin/ffmpeg
do
  [ -x "$c" ] && FFMPEG_BIN=$c && break
done

have_sd() {
  mountpoint=$(echo "$REC_ROOT" | cut -d/ -f1-3)
  [ -d "$mountpoint" ] && grep -q "$(basename "$mountpoint")" /proc/mounts 2>/dev/null
}

free_kb() {
  mountpoint=$(echo "$REC_ROOT" | cut -d/ -f1-3)
  df -k "$mountpoint" 2>/dev/null | tail -n 1 | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)[[:space:]]\+[0-9][0-9]*%.*/\1/p'
}

# Only prune files we created under REC_ROOT (localcam segments)
prune() {
  have_sd || return 0
  while true; do
    free=$(free_kb)
    [ -n "$free" ] || break
    [ "$free" -ge "$MIN_FREE_KB" ] && break
    oldest=$(ls -1tr "$REC_ROOT"/seg_*.mkv "$REC_ROOT"/seg_*.ts 2>/dev/null | head -n 1)
    [ -n "$oldest" ] || break
    rm -f "$oldest"
    echo "recorder: pruned $oldest"
  done
}

writable() {
  mkdir -p "$REC_ROOT" 2>/dev/null || return 1
  touch "$REC_ROOT/.writetest" 2>/dev/null || return 1
  rm -f "$REC_ROOT/.writetest"
  return 0
}

record_loop() {
  echo "recording" > "$RUNDIR/recorder.state"
  while [ -f "$RUNDIR/recorder.run" ]; do
    prune
    if ! pidof snx_rtsp_server >/dev/null 2>&1; then
      echo "recorder: waiting for RTSP"
      sleep 5
      continue
    fi
    ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo out)
    out="$REC_ROOT/seg_${ts}.mkv"
    if [ -n "$FFMPEG_BIN" ]; then
      "$FFMPEG_BIN" -y -rtsp_transport tcp -i "$RTSP_URL" -t "$SEG_SEC" \
        -c copy -an "$out" >>/tmp/localcam-recorder.log 2>&1 || {
        echo "recorder: segment failed"
        sleep 3
      }
    else
      # No ffmpeg on camera: mark ready but idle (host-side pull can use same URL)
      echo "recorder: no ffmpeg on device — idle (stream still available at $RTSP_URL)"
      echo "idle-no-ffmpeg" > "$RUNDIR/recorder.state"
      sleep 60
    fi
  done
  echo "stopped" > "$RUNDIR/recorder.state"
}

start() {
  if ! have_sd; then
    echo "recorder: no SD — recording disabled"
    echo "no-sd" > "$RUNDIR/recorder.state"
    return 0
  fi
  if ! writable; then
    echo "recorder: SD absent/full/read-only"
    echo "not-writable" > "$RUNDIR/recorder.state"
    return 1
  fi
  touch "$RUNDIR/recorder.run"
  record_loop &
  echo $! > "$RUNDIR/recorder.pid"
  echo "recorder: started → $REC_ROOT (seg ${SEG_SEC}s)"
}

stop() {
  rm -f "$RUNDIR/recorder.run"
  [ -f "$RUNDIR/recorder.pid" ] && kill "$(cat "$RUNDIR/recorder.pid")" 2>/dev/null || true
  echo "stopped" > "$RUNDIR/recorder.state"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  prune) prune ;;
  *) echo "Usage: $0 {start|stop|prune}" ;;
esac
