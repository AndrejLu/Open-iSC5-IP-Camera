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

stop_media() {
  killall -9 snx_rtsp_server 2>/dev/null || true
  [ -f "$RUNDIR/onvif.pid" ] && kill "$(cat "$RUNDIR/onvif.pid")" 2>/dev/null || true
}

stop_all() {
  stop_media
  [ -f "$RUNDIR/dropbear.pid" ] && kill "$(cat "$RUNDIR/dropbear.pid")" 2>/dev/null || true
}

case "${1:-start}" in
  start) mkdir -p "$RUNDIR"; start_rtsp; start_ssh ;;
  stop) stop_all ;;
  stop-media) stop_media ;;
  start-rtsp) start_rtsp ;;
  start-ssh) start_ssh ;;
  *) echo "Usage: $0 {start|stop|stop-media|start-rtsp|start-ssh}" ;;
esac
