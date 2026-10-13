#!/bin/sh
# Captive-portal CGI. CFGDIR must match wifi-manager (SD overlay during test).
if [ -z "$CFGDIR" ]; then
  if [ -d /media/mmcblk0p1/localcam ]; then
    CFGDIR=/media/mmcblk0p1/localcam/etc
  elif [ -d /media/mmcblk0p2/data/localcam ]; then
    CFGDIR=/media/mmcblk0p2/data/localcam/etc
  else
    CFGDIR=/etc/localcam
  fi
fi
RUNDIR="${RUNDIR:-/tmp/localcam}"
WM="${WM:-/media/mmcblk0p1/localcam/bin/wifi-manager.sh}"
[ -x "$WM" ] || WM=/media/mmcblk0p2/data/localcam/bin/wifi-manager.sh
WLAN="${WLAN:-wlan0}"
mkdir -p "$CFGDIR" "$RUNDIR" 2>/dev/null || true
export CFGDIR RUNDIR WLAN WM

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }

read_body() {
  n=${CONTENT_LENGTH:-0}
  if [ "$n" -gt 0 ] && [ "$n" -lt 8192 ]; then dd bs=1 count="$n" 2>/dev/null; fi
}
json_str() { echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }
json_bool() { echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -n 1; }

route=$(basename "${SCRIPT_NAME:-api}")
case "$REQUEST_URI" in
  *generate_204*|*hotspot-detect*|*ncsi.txt*|*connecttest*) route=captive ;;
esac

case "$route" in
  captive)
    echo "Status: 302 Found"
    echo "Location: http://192.168.4.1/"
    echo "Content-Type: text/html"
    echo ""
    echo "<a href=\"http://192.168.4.1/\">setup</a>"
    exit 0
    ;;
  status|api)
    tok=$(cat "$RUNDIR/csrf.token" 2>/dev/null || true)
    if [ -z "$tok" ]; then
      tok=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | md5sum | cut -c1-16)
      echo "$tok" > "$RUNDIR/csrf.token"
    fi
    ap=$(CFGDIR="$CFGDIR" "$WM" ssid 2>/dev/null || echo Camera)
    has_admin=false
    [ -f "$CFGDIR/admin.conf" ] && grep -q password_hash "$CFGDIR/admin.conf" && has_admin=true
    err=""; [ -f "$RUNDIR/wifi.error" ] && err=$(cat "$RUNDIR/wifi.error")
    notice=""; [ -f "$RUNDIR/wifi.notice" ] && notice=$(cat "$RUNDIR/wifi.notice")
    st=$(cat "$RUNDIR/wifi.state" 2>/dev/null || echo unknown)
    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo "Set-Cookie: csrf=$tok; Path=/"
    echo ""
    printf '{"ap_ssid":"%s","has_admin":%s,"state":"%s","error":"%s","notice":"%s"}\n' \
      "$(json_escape "$ap")" "$has_admin" "$(json_escape "$st")" "$(json_escape "$err")" "$(json_escape "$notice")"
    exit 0
    ;;
  scan)
    tmp="$RUNDIR/scan.txt"
    out="$RUNDIR/scan.rows"
    iwlist wlan0 scan >"$tmp" 2>/dev/null || true
    # One row per AP: "<pct>|<ssid>" then sort strongest first (BusyBox sort -n -r)
    : > "$out"
    qual=""
    while IFS= read -r line; do
      case "$line" in
        *Quality=*)
          # Quality=70/100  or  Quality:70/100  Signal level=…
          qual=$(echo "$line" | sed -n 's/.*Quality[:=]\([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1/p')
          [ -z "$qual" ] && qual=$(echo "$line" | sed -n 's/.*Signal level[:=]\(-\?[0-9][0-9]*\).*/\1/p')
          ;;
        *ESSID:*)
          ssid=$(echo "$line" | sed 's/.*ESSID:"\(.*\)".*/\1/')
          if [ -n "$ssid" ]; then
            [ -z "$qual" ] && qual=0
            # pad for numeric sort
            printf '%03d|%s\n' "$qual" "$ssid" >> "$out"
          fi
          qual=""
          ;;
      esac
    done < "$tmp"
    sort -r "$out" > "$out.s" 2>/dev/null || cp "$out" "$out.s"
    # Dedupe SSID keeping strongest (first after sort)
    : > "$out.u"
    seen="$RUNDIR/scan.seen"
    : > "$seen"
    while IFS='|' read -r pct ssid; do
      [ -z "$ssid" ] && continue
      grep -F -x -q -- "$ssid" "$seen" 2>/dev/null && continue
      echo "$ssid" >> "$seen"
      echo "$pct|$ssid" >> "$out.u"
    done < "$out.s"
    echo "Content-Type: application/json"
    echo ""
    printf '{"networks":['
    first=1
    while IFS='|' read -r pct ssid; do
      [ -z "$ssid" ] && continue
      # strip leading zeros for display percent
      pctn=$(echo "$pct" | sed 's/^0*\([0-9]\)/\1/;s/^$/0/')
      if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
      printf '{"ssid":"%s","signal":"%s%%","signal_pct":%s}' \
        "$(json_escape "$ssid")" "$pctn" "$pctn"
    done < "$out.u"
    echo ']}'
    exit 0
    ;;
  connect)
    body=$(read_body)
    echo "$(date) connect body_len=${#body}" >> /tmp/localcam-portal.log
    csrf=$(json_str "$body" csrf)
    exp=$(cat "$RUNDIR/csrf.token" 2>/dev/null || true)
    if [ -z "$csrf" ] || [ "$csrf" != "$exp" ]; then
      echo "Status: 403 Forbidden"; echo "Content-Type: application/json"; echo ""; echo '{"error":"CSRF check failed"}'; exit 0
    fi
    ssid=$(json_str "$body" ssid)
    psk=$(json_str "$body" psk)
    admin=$(json_str "$body" admin_password)
    hidden=$(json_bool "$body" hidden)
    open=$(json_bool "$body" open)
    if [ -z "$ssid" ]; then
      echo "Status: 400 Bad Request"; echo "Content-Type: application/json"; echo ""; echo '{"error":"SSID required"}'; exit 0
    fi
    if [ ! -f "$CFGDIR/admin.conf" ] || ! grep -q '^password_hash=' "$CFGDIR/admin.conf"; then
      alen=$(printf '%s' "$admin" | wc -c)
      if [ "$alen" -lt 8 ]; then
        echo "Status: 400 Bad Request"; echo "Content-Type: application/json"; echo ""; echo '{"error":"Admin password required (min 8)"}'; exit 0
      fi
      salt=$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | md5sum | cut -c1-8)
      # No awk on stock PATH — use cut
      ph=$(printf '%s' "${salt}${admin}" | md5sum | cut -c1-32)
      hash="sha256:${salt}:${ph}"
      umask 077
      echo "password_hash=$hash" > "$CFGDIR/admin.conf.tmp"
      mv "$CFGDIR/admin.conf.tmp" "$CFGDIR/admin.conf"
      sync
      echo "$(date) admin.conf written CFGDIR=$CFGDIR" >> /tmp/localcam-portal.log
    fi
    key_mgmt=WPA-PSK
    [ "$open" = "true" ] && key_mgmt=NONE && psk=
    umask 077
    {
      printf 'ssid=%s\n' "$ssid"
      printf 'psk=%s\n' "$psk"
      printf 'key_mgmt=%s\n' "$key_mgmt"
      [ "$hidden" = "true" ] && echo "hidden=1" || echo "hidden=0"
    } > "$CFGDIR/wifi.conf.tmp"
    mv "$CFGDIR/wifi.conf.tmp" "$CFGDIR/wifi.conf"
    sync
    echo "$(date) wifi.conf written ssid=$ssid CFGDIR=$CFGDIR" >> /tmp/localcam-portal.log
    echo "connecting" > "$RUNDIR/wifi.error"
    echo "Trying saved Wi-Fi — hotspot will drop briefly." > "$RUNDIR/wifi.notice"
    # Background connect with SAME CFGDIR exported
    (
      sleep 2
      rm -f "$RUNDIR/setup.lock"
      export CFGDIR RUNDIR WLAN
      "$WM" start >> /tmp/localcam-wifi.log 2>&1
      st=$(cat "$RUNDIR/wifi.state" 2>/dev/null)
      echo "$(date) post-start state=$st" >> /tmp/localcam-portal.log
      if [ "$st" != "station" ]; then
        echo "Could not join network. Check password/SSID and try again." > "$RUNDIR/wifi.error"
        touch "$RUNDIR/setup.lock"
        # Ensure portal is up again
        /media/mmcblk0p1/localcam/bin/httpd.sh >> /tmp/localcam-portal.log 2>&1 || true
      else
        rm -f "$RUNDIR/wifi.error" "$RUNDIR/wifi.notice"
      fi
    ) &
    echo "Content-Type: application/json"
    echo ""
    echo '{"message":"Saved. Hotspot will drop while connecting. Rejoin Camera-… if it returns with an error."}'
    exit 0
    ;;
  *)
    echo "Status: 404 Not Found"; echo "Content-Type: application/json"; echo ""; echo '{"error":"not found"}'
    exit 0
    ;;
esac
