#!/bin/sh
# Local services when associated to home Wi-Fi (not on open setup AP).
# RTSP uses fanghacks snx_rtsp_server; SSH uses dropbear; ONVIF TBD.

FH_BIN="${FH_BIN:-/media/mmcblk0p2/data/usr/bin}"
FH_SBIN="${FH_SBIN:-/media/mmcblk0p2/data/usr/sbin}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
CFGDIR="${CFGDIR:-/media/mmcblk0p2/data/localcam/etc}"

start_rtsp() {
  # Avoid encoder conflict with iSC3S if still running
  if pidof iSC3S >/dev/null 2>&1; then
    echo "services: stop iSC3S before RTSP"
    killall -9 iSC3S 2>/dev/null || true
    sleep 2
  fi
  if [ -x "$FH_BIN/snx_rtsp_server" ]; then
    # Auth note: stock snx_rtsp_server may lack built-in auth — wrap later
    "$FH_BIN/snx_rtsp_server" -W 1920 -H 1080 -Q 10 -b 4096 -a \
      >/tmp/localcam-rtsp.log 2>&1 &
    echo $! > "$RUNDIR/rtsp.pid"
    echo "services: RTSP started pid=$!"
  else
    echo "services: snx_rtsp_server missing"
  fi
}

start_ssh() {
  if [ -x "$FH_SBIN/../sbin/dropbear" ] || [ -x /media/mmcblk0p2/data/sbin/dropbear ]; then
    DB=$(command -v dropbear 2>/dev/null || echo /media/mmcblk0p2/data/sbin/dropbear)
    # Keys in CFGDIR; do not use stock root/ismart12 as production
    mkdir -p "$CFGDIR/dropbear"
    [ -f "$CFGDIR/dropbear/dropbear_rsa_host_key" ] || \
      dropbearkey -t rsa -f "$CFGDIR/dropbear/dropbear_rsa_host_key" 2>/dev/null || true
    "$DB" -r "$CFGDIR/dropbear/dropbear_rsa_host_key" -p 22 >/tmp/localcam-ssh.log 2>&1 &
    echo $! > "$RUNDIR/dropbear.pid"
  fi
}

stop_all() {
  for p in rtsp dropbear; do
    [ -f "$RUNDIR/$p.pid" ] && kill "$(cat "$RUNDIR/$p.pid")" 2>/dev/null || true
  done
  killall snx_rtsp_server 2>/dev/null || true
}

case "${1:-start}" in
  start) start_rtsp; start_ssh ;;
  stop) stop_all ;;
  *) echo "Usage: $0 {start|stop}" ;;
esac
