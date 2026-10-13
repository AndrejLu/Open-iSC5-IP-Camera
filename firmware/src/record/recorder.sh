#!/bin/sh
# Optional SD continuous recording — hardware H.264 segments, no transcode.
# Uses existing RTSP/encoder path or direct V4L when wired; never formats the card.

REC_ROOT="${REC_ROOT:-/media/mmcblk0p1/record/localcam}"
SEG_SEC="${SEG_SEC:-300}"
MIN_FREE_KB="${MIN_FREE_KB:-102400}"
RUNDIR="${RUNDIR:-/tmp/localcam}"

have_sd() {
  [ -d /media/mmcblk0p1 ] && grep -q mmcblk0p1 /proc/mounts 2>/dev/null
}

free_kb() {
  df -k /media/mmcblk0p1 2>/dev/null | tail -n 1 | awk '{print $4}'
}

prune() {
  # Delete oldest segments until free space OK; never format
  while [ "$(free_kb)" -lt "$MIN_FREE_KB" ] 2>/dev/null; do
    oldest=$(ls -1tr "$REC_ROOT"/*.mkv "$REC_ROOT"/*.mp4 "$REC_ROOT"/*.h264 2>/dev/null | head -n 1)
    [ -n "$oldest" ] || break
    rm -f "$oldest"
    echo "recorder: pruned $oldest"
  done
}

start() {
  if ! have_sd; then
    echo "recorder: no SD — recording disabled"
    return 0
  fi
  mkdir -p "$REC_ROOT" || {
    echo "recorder: cannot create $REC_ROOT (read-only?)"
    return 1
  }
  touch "$REC_ROOT/.writetest" 2>/dev/null || {
    echo "recorder: SD not writable"
    return 1
  }
  rm -f "$REC_ROOT/.writetest"
  echo "recorder: ready at $REC_ROOT (segment ${SEG_SEC}s) — pull from RTSP when ffmpeg/openRTSP available"
  # Placeholder loop: prefer openRTSP/ffmpeg arm binary when added to image
  echo "idle" > "$RUNDIR/recorder.state"
}

stop() {
  echo "stopped" > "$RUNDIR/recorder.state"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  prune) have_sd && prune ;;
  *) echo "Usage: $0 {start|stop|prune}" ;;
esac
