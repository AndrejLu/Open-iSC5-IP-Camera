#!/bin/sh
# Local services when STA (not relying on vendor iSC3S).
# snx_rtsp_server needs /etc/rc rate-control files and 1920x1080.

# shellcheck disable=SC1091
. "$(dirname "$0")/paths.sh" 2>/dev/null || . "$(dirname "$0")/../wifi/paths.sh" 2>/dev/null || true
FH_BIN="${FH_BIN:-/media/mmcblk0p2/data/usr/bin}"
FH_LIB="${FH_LIB:-/media/mmcblk0p2/data/usr/lib}"
FH_ROOT="${FH_ROOT:-/media/mmcblk0p2/data}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
CFGDIR="${CFGDIR:-/etc/localcam}"
DB_BIN="${DB_BIN:-$FH_ROOT/sbin/dropbear}"
[ -x "$DB_BIN" ] || DB_BIN=/media/mmcblk1p2/data/sbin/dropbear

ensure_rc() {
  if [ ! -d /etc/rc ] || [ -z "$(ls /etc/rc 2>/dev/null)" ]; then
    mkdir -p /etc/rc
    if [ -d /root/etc_default/rc ]; then
      cp -a /root/etc_default/rc/. /etc/rc/
    fi
  fi
}

# MJPEG preview helper on :8554/mjpeg (/dev/video2). Safe to call repeatedly.
start_mjpeg() {
  mkdir -p "$RUNDIR" 2>/dev/null || true
  if netstat -lnt 2>/dev/null | grep -qE '[.:]8554 '; then
    return 0
  fi
  # Stale pidfile?
  if [ -f "$RUNDIR/rtsp-mjpeg.pid" ]; then
    mpid=$(cat "$RUNDIR/rtsp-mjpeg.pid" 2>/dev/null)
    if [ -n "$mpid" ] && [ -d "/proc/$mpid" ]; then
      return 0
    fi
    rm -f "$RUNDIR/rtsp-mjpeg.pid"
  fi
  if [ ! -x "$FH_BIN/snx_rtsp_server" ]; then
    echo "services: snx_rtsp_server missing — cannot start MJPEG" >&2
    return 1
  fi
  ensure_rc
  export LD_LIBRARY_PATH="$FH_LIB:/lib:${LD_LIBRARY_PATH:-}"
  (
    cd "$FH_ROOT" || exit 1
    "$FH_BIN/snx_rtsp_server" -W 640 -H 360 -j 60 -P 8554 -u mjpeg /dev/video2 \
      >/tmp/localcam-rtsp-mjpeg.log 2>&1 &
    echo $! > "$RUNDIR/rtsp-mjpeg.pid"
  )
  # Wait briefly for listen
  n=0
  while [ "$n" -lt 15 ]; do
    if netstat -lnt 2>/dev/null | grep -qE '[.:]8554 '; then
      echo "services: MJPEG preview RTSP on :8554/mjpeg"
      return 0
    fi
    n=$((n + 1))
    sleep 0.2 2>/dev/null || sleep 1
  done
  echo "services: MJPEG preview failed — see /tmp/localcam-rtsp-mjpeg.log" >&2
  return 1
}

start_rtsp() {
  ensure_rc
  if pidof iSC3S >/dev/null 2>&1; then
    echo "services: stopping iSC3S for encoder"
    killall -9 iSC3S 2>/dev/null || true
    sleep 2
  fi
  killall -9 snx_rtsp_server 2>/dev/null || true
  sleep 1
  if [ -x "$FH_BIN/snx_rtsp_server" ]; then
    export LD_LIBRARY_PATH="$FH_LIB:/lib:${LD_LIBRARY_PATH:-}"
    (
      cd "$FH_ROOT" || exit 1
      "$FH_BIN/snx_rtsp_server" -W 1920 -H 1080 -Q 10 -b 4096 -a \
        >/tmp/localcam-rtsp.log 2>&1 &
      echo $! > "$RUNDIR/rtsp.pid"
    )
    sleep 2
    if pidof snx_rtsp_server >/dev/null; then
      echo "services: RTSP up (rtsp://<ip>:554/unicast) auth=none"
    else
      echo "services: RTSP failed — see /tmp/localcam-rtsp.log"
      cat /tmp/localcam-rtsp.log 2>/dev/null | tail -n 20
    fi
    start_mjpeg || true
  else
    echo "services: snx_rtsp_server missing at $FH_BIN"
  fi
}

# Persist Dropbear host keys under CFGDIR (jffs2/SD); never rely on dropbear -R alone.
ensure_dropbear_keys() {
  keydir="$CFGDIR/dropbear"
  mkdir -p "$keydir"
  chmod 700 "$keydir" 2>/dev/null || true
  # Migrate ephemeral /etc/dropbear keys if present and CFGDIR empty
  if [ ! -f "$keydir/dropbear_rsa_host_key" ] && [ -f /etc/dropbear/dropbear_rsa_host_key ]; then
    cp -a /etc/dropbear/dropbear_rsa_host_key "$keydir/" 2>/dev/null || true
  fi
  if [ ! -f "$keydir/dropbear_rsa_host_key" ]; then
    # Generate once into CFGDIR (dropbear -R writes to /etc/dropbear — move afterward)
    mkdir -p /etc/dropbear
    if [ -x "$DB_BIN" ]; then
      "$DB_BIN" -R -p 0 2>/tmp/localcam-dbkey.log || true
      # -R with invalid port may still create keys then exit; or start briefly
      if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
        # Start once to generate, then kill
        "$DB_BIN" -R -p 22223 >/tmp/localcam-dbkey.log 2>&1 &
        dbpid=$!
        sleep 2
        kill "$dbpid" 2>/dev/null || true
        killall dropbear 2>/dev/null || true
      fi
      if [ -f /etc/dropbear/dropbear_rsa_host_key ]; then
        cp -a /etc/dropbear/*.key "$keydir/" 2>/dev/null || true
        cp -a /etc/dropbear/dropbear_*_host_key "$keydir/" 2>/dev/null || true
        chmod 600 "$keydir/"* 2>/dev/null || true
        sync
        echo "services: dropbear host keys stored in $keydir"
      fi
    fi
  fi
}

start_ssh() {
  [ -x "$DB_BIN" ] || { echo "services: dropbear missing"; return 0; }
  ensure_dropbear_keys
  keydir="$CFGDIR/dropbear"
  # Prefer port 22 when stock dropbear not running; else 2222
  port=22
  netstat -lnt 2>/dev/null | grep -q ':22 ' && port=2222
  killall dropbear 2>/dev/null || true
  sleep 1
  # Explicit -r keys from CFGDIR (persistent)
  rsa="$keydir/dropbear_rsa_host_key"
  args="-p $port -E"
  [ -f "$rsa" ] && args="$args -r $rsa"
  for k in "$keydir"/dropbear_*_host_key; do
    [ -f "$k" ] || continue
    [ "$k" = "$rsa" ] && continue
    args="$args -r $k"
  done
  # shellcheck disable=SC2086
  "$DB_BIN" $args >/tmp/localcam-ssh.log 2>&1 &
  echo $! > "$RUNDIR/dropbear.pid"
  echo "services: dropbear on :$port keys=$keydir"
}

find_onvif() {
  for b in "$(dirname "$0")/onvif-lite.sh" \
           "$LC_ROOT/bin/onvif-lite.sh" \
           /media/mmcblk0p1/lc/bin/onvif-lite.sh \
           /media/mmcblk1p1/lc/bin/onvif-lite.sh; do
    [ -x "$b" ] && echo "$b" && return 0
  done
  return 1
}

find_recorder() {
  for b in "$(dirname "$0")/recorder.sh" \
           "$LC_ROOT/bin/recorder.sh" \
           /media/mmcblk0p1/lc/bin/recorder.sh \
           /media/mmcblk1p1/lc/bin/recorder.sh; do
    [ -x "$b" ] && echo "$b" && return 0
  done
  return 1
}

start_onvif() {
  ONV=$(find_onvif) || { echo "services: onvif-lite.sh missing"; return 1; }
  export CFGDIR RUNDIR WLAN FH_BIN FH_LIB FH_ROOT FH_SBIN LC_ROOT
  "$ONV" >>/tmp/localcam-onvif.log 2>&1
  if netstat -lnt 2>/dev/null | grep -qE '[.:]8000 '; then
    echo "services: ONVIF up on :8000"
    return 0
  fi
  echo "services: ONVIF failed — see /tmp/localcam-onvif.log" >&2
  return 1
}

start_recorder() {
  REC=$(find_recorder) || { echo "services: recorder.sh missing"; return 1; }
  # Stop previous loop cleanly
  "$REC" stop >/dev/null 2>&1 || true
  export CFGDIR RUNDIR FH_BIN FH_ROOT LC_ROOT
  "$REC" start >>/tmp/localcam-recorder.log 2>&1
  st=$(cat "$RUNDIR/recorder.state" 2>/dev/null || echo unknown)
  echo "services: recorder state=$st"
  [ "$st" = "recording" ] || [ "$st" = "idle-no-ffmpeg" ]
}

stop_recorder() {
  REC=$(find_recorder) || return 0
  "$REC" stop >/dev/null 2>&1 || true
}

stop_media() {
  stop_recorder
  killall -9 snx_rtsp_server 2>/dev/null || true
  if [ -f "$RUNDIR/onvif.pid" ]; then
    kill "$(cat "$RUNDIR/onvif.pid")" 2>/dev/null || true
    rm -f "$RUNDIR/onvif.pid"
  fi
  [ -f "$RUNDIR/wsd.pid" ] && kill "$(cat "$RUNDIR/wsd.pid")" 2>/dev/null || true
}

stop_all() {
  stop_media
  [ -f "$RUNDIR/dropbear.pid" ] && kill "$(cat "$RUNDIR/dropbear.pid")" 2>/dev/null || true
}

case "${1:-start}" in
  start) mkdir -p "$RUNDIR"; start_rtsp; start_onvif || true; start_recorder || true; start_ssh ;;
  stop) stop_all ;;
  stop-media) stop_media ;;
  start-rtsp) start_rtsp ;;
  start-mjpeg) start_mjpeg ;;
  start-onvif) start_onvif ;;
  start-recorder) start_recorder ;;
  start-ssh) start_ssh ;;
  *) echo "Usage: $0 {start|stop|stop-media|start-rtsp|start-mjpeg|start-onvif|start-recorder|start-ssh}" ;;
esac
