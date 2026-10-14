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
# Small fang SD (~100MiB) — keep a modest reserve, not 100MiB
MIN_FREE_KB="${MIN_FREE_KB:-8192}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:554/unicast}"
RECORDER_BIN="${RECORDER_BIN:-}"
# Prefer lightweight rtsp-h264 (does not wedge the SoC). SONiX ffmpeg is fallback only.
for c in \
  /media/mmcblk0p1/lc/bin/rtsp-h264 /media/mmcblk1p1/lc/bin/rtsp-h264 \
  "$LC_ROOT/bin/rtsp-h264" /usr/local/bin/rtsp-h264 \
  /media/mmcblk0p2/data/test/ffmpeg/ffmpeg \
  /media/mmcblk1p2/data/test/ffmpeg/ffmpeg \
  "$FH_BIN/ffmpeg" /usr/bin/ffmpeg
do
  [ -x "$c" ] && RECORDER_BIN=$c && break
done
FFMPEG_BIN=

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
    oldest=$(ls -1tr "$REC_ROOT"/seg_*.mkv "$REC_ROOT"/seg_*.ts "$REC_ROOT"/seg_*.mp4 "$REC_ROOT"/seg_*.h264 2>/dev/null | head -n 1)
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
    case "$RECORDER_BIN" in
      *rtsp-h264)
        out="$REC_ROOT/seg_${ts}.h264"
        if ! pidof snx_rtsp_server >/dev/null 2>&1; then
          echo "recorder: waiting for RTSP"
          sleep 5
          continue
        fi
        # Ensure H.264 :554 is listening (MJPEG-only leaves connect refused)
        if ! netstat -lnt 2>/dev/null | grep -qE '[.:]554 '; then
          echo "recorder: RTSP :554 not listening — retry"
          sleep 5
          continue
        fi
        nice -n 10 "$RECORDER_BIN" -t "$SEG_SEC" "$RTSP_URL" > "$out" \
          2>>/tmp/localcam-recorder.log || {
          echo "recorder: rtsp-h264 segment failed"
          rm -f "$out"
          sleep 3
          continue
        }
        ;;
      *ffmpeg*)
        out="$REC_ROOT/seg_${ts}.ts"
        hard=$((SEG_SEC + 30))
        # Watchdog — SONiX ffmpeg has wedged this SoC when RTSP stalls
        nice -n 15 "$RECORDER_BIN" -y -loglevel error \
          -rtsp_transport udp -i "$RTSP_URL" -t "$SEG_SEC" \
          -c copy -an -f mpegts "$out" >>/tmp/localcam-recorder.log 2>&1 &
        fpid=$!
        w=0
        while [ "$w" -lt "$hard" ]; do
          kill -0 "$fpid" 2>/dev/null || break
          w=$((w + 1))
          sleep 1
        done
        if kill -0 "$fpid" 2>/dev/null; then
          echo "recorder: watchdog killing ffmpeg pid=$fpid"
          kill -9 "$fpid" 2>/dev/null || true
          killall -9 ffmpeg 2>/dev/null || true
          rm -f "$out"
        fi
        wait "$fpid" 2>/dev/null || true
        ;;
      *)
        echo "recorder: no recorder binary — idle (stream at $RTSP_URL)"
        echo "idle-no-tool" > "$RUNDIR/recorder.state"
        sleep 60
        continue
        ;;
    esac
    sz=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
    [ -n "$sz" ] && [ "$sz" -gt 4096 ] || rm -f "$out"
  done
  echo "stopped" > "$RUNDIR/recorder.state"
}

# Watch for host-pushed segments (UDP loopback to self does not work on this SoC).
watch_loop() {
  echo "recording" > "$RUNDIR/recorder.state"
  echo "recorder: host-assisted watch mode → $REC_ROOT"
  while [ -f "$RUNDIR/recorder.run" ]; do
    prune
    # Fresh segment within last ~2 minutes ⇒ stay "recording"
    fresh=$(find "$REC_ROOT" -name 'seg_*' -mmin -2 2>/dev/null | head -n 1)
    if [ -n "$fresh" ]; then
      echo "recording" > "$RUNDIR/recorder.state"
    fi
    sleep 10
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
  # Prefer host-assisted watch: on-camera RTSP UDP to 127.0.0.1 delivers no packets.
  # Optional: RECORDER_LOCAL=1 to attempt on-device rtsp-h264/ffmpeg anyway.
  if [ "${RECORDER_LOCAL:-0}" = "1" ]; then
    record_loop &
  else
    watch_loop &
  fi
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
