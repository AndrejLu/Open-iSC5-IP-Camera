#!/bin/sh
# wifi-manager.sh — AP/STA/fallback for iSC5 (8188eu + rtl871xdrv hostapd)
# BusyBox ash compatible. No shell interpolation of credentials into eval.
#
# Modes: setup-ap | station | fallback-ap
# Config root: $CFGDIR (default /etc/localcam); runtime under /tmp/localcam

set -e

# Shared CFGDIR / fang paths (mmcblk0|1, lc|localcam)
# shellcheck disable=SC1091
. "$(dirname "$0")/paths.sh" 2>/dev/null || . /media/mmcblk1p1/lc/bin/paths.sh 2>/dev/null || true
AP_NET="${AP_NET:-192.168.4.0}"
STA_TIMEOUT="${STA_TIMEOUT:-90}"
LOSS_TIMEOUT="${LOSS_TIMEOUT:-90}"
RETRY_INTERVAL="${RETRY_INTERVAL:-300}"
LOGFILE="${LOGFILE:-/tmp/localcam-wifi.log}"

WIFI_CONF="$CFGDIR/wifi.conf"
ADMIN_CONF="$CFGDIR/admin.conf"
STATE_FILE="$RUNDIR/wifi.state"
SETUP_LOCK="$RUNDIR/setup.lock"
ERR_FILE="$RUNDIR/wifi.error"

HOSTAPD_BIN="${HOSTAPD_BIN:-/sbin/hostapd}"
WPA_BIN="${WPA_BIN:-/sbin/wpa_supplicant}"
UDHCPD_BIN="${UDHCPD_BIN:-/usr/sbin/udhcpd}"
# BusyBox may provide udhcpd as applet
command -v udhcpd >/dev/null 2>&1 && UDHCPD_BIN=$(command -v udhcpd)
command -v hostapd >/dev/null 2>&1 && HOSTAPD_BIN=$(command -v hostapd)
command -v wpa_supplicant >/dev/null 2>&1 && WPA_BIN=$(command -v wpa_supplicant)

mkdir -p "$CFGDIR" "$RUNDIR" 2>/dev/null || true

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') wifi-manager: $*" >> "$LOGFILE"
  echo "wifi-manager: $*"
}

set_state() {
  echo "$1" > "$STATE_FILE"
}

get_state() {
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "unknown"
}

device_suffix() {
  # Stable suffix from wlan MAC last 3 octets → 6 hex chars (BusyBox; no awk)
  mac=$(ifconfig "$WLAN" 2>/dev/null | sed -n 's/.*HWaddr //p' | head -n 1 | tr -d ' ')
  if [ -z "$mac" ]; then
    mac=$(cat /sys/class/net/"$WLAN"/address 2>/dev/null || echo "00:00:00:00:00:00")
  fi
  hex=$(echo "$mac" | tr -d ':' | tr 'a-f' 'A-F')
  # last 6 hex chars
  echo "$hex" | sed 's/.*\([0-9A-F]\{6\}\)$/\1/'
}

ap_ssid() {
  echo "Camera-$(device_suffix)"
}

has_wifi_conf() {
  [ -f "$WIFI_CONF" ] && grep -q '^ssid=' "$WIFI_CONF" 2>/dev/null
}

has_admin() {
  [ -f "$ADMIN_CONF" ] && grep -q '^password_hash=' "$ADMIN_CONF" 2>/dev/null
}

kill_pidfile() {
  pf="$1"
  if [ -f "$pf" ]; then
    pid=$(cat "$pf" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  fi
}

stop_ap() {
  kill_pidfile "$RUNDIR/hostapd.pid"
  kill_pidfile "$RUNDIR/udhcpd.pid"
  # Also kill by name if pidfiles stale
  killall hostapd 2>/dev/null || true
  killall udhcpd 2>/dev/null || true
  rm -f "$RUNDIR/hostapd.conf" "$RUNDIR/udhcpd.conf"
}

stop_sta() {
  kill_pidfile "$RUNDIR/wpa.pid"
  killall wpa_supplicant 2>/dev/null || true
  killall udhcpc 2>/dev/null || true
  rm -f "$RUNDIR/wpa_supplicant.conf"
}

stop_all_wifi() {
  FW="$(dirname "$0")/ap-firewall.sh"
  [ -x "$FW" ] && "$FW" flush || true
  stop_ap
  stop_sta
  ifconfig "$WLAN" 0.0.0.0 down 2>/dev/null || true
  sleep 1
}

write_hostapd_open() {
  ssid="$1"
  conf="$RUNDIR/hostapd.conf"
  # Open AP — no wpa=, no passphrase. rtl871xdrv required for this hostapd build.
  cat > "$conf" <<EOF
driver=rtl871xdrv
beacon_int=100
hw_mode=g
ieee80211n=1
wme_enabled=1
ht_capab=[SHORT-GI-20]
max_num_sta=8
interface=$WLAN
ctrl_interface=/var/run/hostapd
channel=6
auth_algs=1
ignore_broadcast_ssid=0
ssid=$ssid
EOF
  echo "$conf"
}

write_udhcpd() {
  conf="$RUNDIR/udhcpd.conf"
  mkdir -p /var/lib/misc 2>/dev/null || true
  touch /var/lib/misc/udhcpd.leases 2>/dev/null || true
  cat > "$conf" <<EOF
start		192.168.4.100
end		192.168.4.200
interface	$WLAN
opt	dns	$AP_IP
option	subnet	255.255.255.0
opt	router	$AP_IP
option	domain	localcam
option	lease	86400
lease_file	/var/lib/misc/udhcpd.leases
pidfile	$RUNDIR/udhcpd.pid
EOF
  echo "$conf"
}

start_ap() {
  mode_label="$1"
  ssid=$(ap_ssid)
  log "starting $mode_label AP ssid=$ssid"
  stop_all_wifi
  ifconfig "$WLAN" up
  ifconfig "$WLAN" "$AP_IP" netmask 255.255.255.0
  hc=$(write_hostapd_open "$ssid")
  uc=$(write_udhcpd)
  mkdir -p /var/run/hostapd 2>/dev/null || true
  "$HOSTAPD_BIN" -B -P "$RUNDIR/hostapd.pid" "$hc" || {
    log "hostapd failed"
    echo "hostapd_failed" > "$ERR_FILE"
    return 1
  }
  "$UDHCPD_BIN" "$uc" || {
    # Some builds want -f foreground; try background via &
    "$UDHCPD_BIN" "$uc" &
    echo $! > "$RUNDIR/udhcpd.pid"
  }
  # Restrict AP clients to portal/DHCP/DNS when iptables exists
  FW="$(dirname "$0")/ap-firewall.sh"
  [ -x "$FW" ] && "$FW" ap || true
  # Soft isolation when no iptables: stop fang maintenance + media services on AP
  killall telnetd ftpd 2>/dev/null || true
  killall -9 snx_rtsp_server 2>/dev/null || true
  killall dropbear 2>/dev/null || true
  # Stop ONVIF httpd if we started one
  [ -f "$RUNDIR/onvif.pid" ] && kill "$(cat "$RUNDIR/onvif.pid")" 2>/dev/null || true
  set_state "$mode_label"
  rm -f "$ERR_FILE"
  log "AP up: $ssid @ $AP_IP (media/SSH stopped for isolation)"
  HTTPD_SH="$(dirname "$0")/httpd.sh"
  [ -x "$HTTPD_SH" ] && "$HTTPD_SH" ap >>/tmp/localcam-httpd.log 2>&1 || true
}

# Write wpa_supplicant.conf atomically from wifi.conf (key=value, no shell eval of values)
write_wpa_conf() {
  out="$RUNDIR/wpa_supplicant.conf"
  ssid=""
  psk=""
  key_mgmt="WPA-PSK"
  hidden="0"
  while IFS='=' read -r k v; do
    case "$k" in
      ssid) ssid=$v ;;
      psk) psk=$v ;;
      key_mgmt) key_mgmt=$v ;;
      hidden) hidden=$v ;;
    esac
  done < "$WIFI_CONF"
  # Escape for wpa_supplicant double-quoted strings: \ and "
  esc() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  }
  {
    echo "ctrl_interface=/var/run/wpa_supplicant"
    echo "update_config=0"
    echo "network={"
    printf '  ssid="%s"\n' "$(esc "$ssid")"
    if [ "$key_mgmt" = "NONE" ] || [ -z "$psk" ]; then
      echo "  key_mgmt=NONE"
    else
      printf '  psk="%s"\n' "$(esc "$psk")"
      echo "  key_mgmt=WPA-PSK"
    fi
    if [ "$hidden" = "1" ]; then
      echo "  scan_ssid=1"
    fi
    echo "}"
  } > "$out"
  echo "$out"
}

sta_associated() {
  iwconfig "$WLAN" 2>/dev/null | grep -q "Access Point: ..:..:..:..:..:.." && \
    ! iwconfig "$WLAN" 2>/dev/null | grep -q "Not-Associated"
}

sta_has_ip() {
  ifconfig "$WLAN" 2>/dev/null | grep -q "inet addr:"
}

# LAN usable: associated, has non-AP IP. Does NOT require Internet/DNS.
sta_lan_ok() {
  sta_associated || return 1
  ip=$(ifconfig "$WLAN" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
  [ -z "$ip" ] && return 1
  case "$ip" in
    192.168.4.*) return 1 ;;
    *) return 0 ;;
  esac
}

default_gw() {
  route -n 2>/dev/null | sed -n 's/^0\.0\.0\.0[[:space:]]\{1,\}\([0-9.]\{1,\}\).*/\1/p' | head -n 1
}

# Optional: ping default GW (LAN). Never use public Internet as health signal.
sta_gw_reachable() {
  gw=$(default_gw)
  [ -z "$gw" ] && return 1
  ping -c 1 -W 2 "$gw" >/dev/null 2>&1
}

start_sta() {
  log "starting STA mode CFGDIR=$CFGDIR conf=$WIFI_CONF"
  if ! has_wifi_conf; then
    log "no wifi.conf at $WIFI_CONF"
    return 1
  fi
  stop_all_wifi
  # 8188eu needs a pause when leaving AP/Master before Managed
  sleep 2
  ifconfig "$WLAN" down
  sleep 1
  ifconfig "$WLAN" up
  sleep 1
  wc=$(write_wpa_conf)
  log "wpa conf written; ssid=$(sed -n 's/^ssid=//p' "$WIFI_CONF" | head -n 1)"
  mkdir -p /var/run/wpa_supplicant 2>/dev/null || true
  "$WPA_BIN" -B -i "$WLAN" -c "$wc" -P "$RUNDIR/wpa.pid" || {
    log "wpa_supplicant failed"
    echo "wpa_failed" > "$ERR_FILE"
    return 1
  }
  set_state "station-connecting"
  # DHCP once associated; -b background, -t retries
  udhcpc -i "$WLAN" -b -t 10 -T 3 -p "$RUNDIR/udhcpc.pid" >/tmp/localcam-udhcpc.log 2>&1 &
  return 0
}

wait_sta() {
  timeout="$1"
  n=0
  while [ "$n" -lt "$timeout" ]; do
    if [ -f "$SETUP_LOCK" ]; then
      log "setup session active — abort wait"
      return 2
    fi
    if sta_lan_ok; then
      ip=$(ifconfig "$WLAN" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
      set_state "station"
      rm -f "$ERR_FILE"
      log "STA connected with IP $ip"
      # LAN admin UI on :80 (replaces empty stock Boa page)
      HTTPD_SH="$(dirname "$0")/httpd.sh"
      [ -x "$HTTPD_SH" ] && "$HTTPD_SH" sta >>/tmp/localcam-httpd.log 2>&1 || true
      return 0
    fi
    if [ $((n % 15)) -eq 0 ]; then
      log "wait_sta ${n}s lan=$(sta_lan_ok && echo y || echo n) $(iwconfig "$WLAN" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-120)"
    fi
    n=$((n + 1))
    sleep 1
  done
  echo "sta_timeout" > "$ERR_FILE"
  log "STA timeout after ${timeout}s"
  return 1
}

# Persist wifi.conf atomically (caller writes to tmp then calls this)
persist_wifi_tmp() {
  tmp="$1"
  mkdir -p "$CFGDIR"
  mv "$tmp" "$WIFI_CONF.tmp"
  sync
  mv "$WIFI_CONF.tmp" "$WIFI_CONF"
  sync
}

cmd_start() {
  if ! has_wifi_conf; then
    start_ap "setup-ap"
    return $?
  fi
  start_sta || true
  if wait_sta "$STA_TIMEOUT"; then
    return 0
  fi
  # Failed — fallback open AP, preserve credentials
  start_ap "fallback-ap"
}

cmd_fallback() {
  start_ap "fallback-ap"
}

cmd_setup() {
  touch "$SETUP_LOCK"
  start_ap "setup-ap"
}

cmd_release_setup() {
  rm -f "$SETUP_LOCK"
}

cmd_stop() {
  stop_all_wifi
  set_state "stopped"
}

cmd_status() {
  echo "state=$(get_state)"
  echo "ssid=$(ap_ssid)"
  echo "has_wifi_conf=$(has_wifi_conf && echo yes || echo no)"
  echo "has_admin=$(has_admin && echo yes || echo no)"
  iwconfig "$WLAN" 2>/dev/null || true
  ifconfig "$WLAN" 2>/dev/null || true
  [ -f "$ERR_FILE" ] && echo "error=$(cat "$ERR_FILE")"
}

cmd_monitor() {
  # Long-running: watch for loss / retry
  log "monitor loop"
  while true; do
    st=$(get_state)
    if [ -f "$SETUP_LOCK" ]; then
      sleep 5
      continue
    fi
    case "$st" in
      station)
        # Only Wi-Fi/LAN loss triggers fallback — Internet-only outage must not.
        if ! sta_lan_ok; then
          log "LAN lost (assoc/IP) — waiting ${LOSS_TIMEOUT}s before fallback"
          set_state "station-lost"
          n=0
          recovered=0
          while [ "$n" -lt "$LOSS_TIMEOUT" ]; do
            [ -f "$SETUP_LOCK" ] && break
            if sta_lan_ok; then
              recovered=1
              set_state "station"
              log "LAN recovered"
              break
            fi
            n=$((n + 1))
            sleep 1
          done
          if [ "$recovered" -eq 0 ] && [ ! -f "$SETUP_LOCK" ]; then
            log "sustained LAN loss — fallback AP (wifi.conf preserved)"
            start_ap "fallback-ap"
          fi
        fi
        ;;
      fallback-ap|setup-ap)
        # Periodically retry saved Wi-Fi without interrupting setup
        if [ "$st" = "fallback-ap" ] && has_wifi_conf && [ ! -f "$SETUP_LOCK" ]; then
          sleep "$RETRY_INTERVAL"
          [ -f "$SETUP_LOCK" ] && continue
          log "retrying saved Wi-Fi"
          # Signal portal that AP will drop briefly
          echo "retry_pending" > "$RUNDIR/wifi.notice"
          sleep 3
          start_sta || true
          if wait_sta 45; then
            rm -f "$RUNDIR/wifi.notice"
            continue
          fi
          start_ap "fallback-ap"
          rm -f "$RUNDIR/wifi.notice"
        else
          sleep 10
        fi
        ;;
      *)
        sleep 5
        ;;
    esac
    sleep 3
  done
}

usage() {
  echo "Usage: $0 {start|stop|status|setup|release-setup|fallback|monitor|ssid}"
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  setup) cmd_setup ;;
  release-setup) cmd_release_setup ;;
  fallback) cmd_fallback ;;
  monitor) cmd_monitor ;;
  ssid) ap_ssid ;;
  *) usage; exit 1 ;;
esac
