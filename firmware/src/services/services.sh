#!/bin/sh
# Local services when not relying on vendor iSC3S.
# snx_rtsp_server needs /etc/rc rate-control files and 1920x1080 (720p path segfaulted here).

FH_BIN="${FH_BIN:-/media/mmcblk0p2/data/usr/bin}"
FH_LIB="${FH_LIB:-/media/mmcblk0p2/data/usr/lib}"
FH_ROOT="${FH_ROOT:-/media/mmcblk0p2/data}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
CFGDIR="${CFGDIR:-/media/mmcblk0p2/data/localcam/etc}"

ensure_rc() {
  if [ ! -d /etc/rc ] || [ -z "$(ls /etc/rc 2>/dev/null)" ]; then
    mkdir -p /etc/rc
    if [ -d /root/etc_default/rc ]; then
      cp -a /root/etc_default/rc/. /etc/rc/
    fi
  fi
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
    # 1080p works; 720p crop path segfaulted on this build without full init
    (
      cd "$FH_ROOT" || exit 1
      "$FH_BIN/snx_rtsp_server" -W 1920 -H 1080 -Q 10 -b 4096 -a \
        >/tmp/localcam-rtsp.log 2>&1 &
      echo $! > "$RUNDIR/rtsp.pid"
    )
    sleep 2
    if pidof snx_rtsp_server >/dev/null; then
      echo "services: RTSP up (rtsp://<ip>/unicast)"
    else
      echo "services: RTSP failed — see /tmp/localcam-rtsp.log"
      cat /tmp/localcam-rtsp.log 2>/dev/null | tail -n 20
    fi
  else
    echo "services: snx_rtsp_server missing"
  fi
}

start_ssh() {
  DB=/media/mmcblk0p2/data/sbin/dropbear
  [ -x "$DB" ] || return 0
  mkdir -p "$CFGDIR/dropbear"
  # Prefer existing fang/dropbear keys; do not force stock root password
  "$DB" -p 2222 >/tmp/localcam-ssh.log 2>&1 &
  echo $! > "$RUNDIR/dropbear.pid"
  echo "services: dropbear on :2222 (avoid conflict with stock :22)"
}

stop_all() {
  killall -9 snx_rtsp_server 2>/dev/null || true
  [ -f "$RUNDIR/dropbear.pid" ] && kill "$(cat "$RUNDIR/dropbear.pid")" 2>/dev/null || true
}

case "${1:-start}" in
  start) mkdir -p "$RUNDIR"; start_rtsp; start_ssh ;;
  stop) stop_all ;;
  *) echo "Usage: $0 {start|stop}" ;;
esac
