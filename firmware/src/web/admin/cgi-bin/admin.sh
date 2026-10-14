#!/bin/sh
# Authenticated admin CGI (BusyBox httpd). Routes by SCRIPT_NAME basename.
# Do NOT source relative ../../wifi/paths.sh — CGI cwd under /tmp/.../cgi-bin breaks that.
PATH="/sbin:/usr/sbin:/bin:/usr/bin:/media/mmcblk0p2/data/sbin:/media/mmcblk0p2/data/usr/sbin:$PATH"
export PATH
if [ -z "$CFGDIR" ]; then
  for d in /media/mmcblk0p1/lc/etc /media/mmcblk1p1/lc/etc \
           /media/mmcblk0p2/data/localcam/etc /media/mmcblk1p2/data/localcam/etc \
           /etc/localcam; do
    [ -d "$d" ] && CFGDIR=$d && break
  done
fi
CFGDIR="${CFGDIR:-/etc/localcam}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
ADMIN_CONF="$CFGDIR/admin.conf"
SESS="$RUNDIR/admin.session"
CSRF="$RUNDIR/csrf.token"
mkdir -p "$RUNDIR" 2>/dev/null || true
# CFGDIR may be on read-only root during early boot — don't fail CGI
mkdir -p "$CFGDIR" 2>/dev/null || true

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }
read_body() {
  n=${CONTENT_LENGTH:-0}
  if [ "$n" -gt 0 ] && [ "$n" -lt 8192 ]; then dd bs=1 count="$n" 2>/dev/null; fi
}
json_str() { echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }

cookie_get() {
  echo "${HTTP_COOKIE:-}" | tr ';' '\n' | sed -n "s/^[[:space:]]*$1=//p" | head -n 1
}

hash_pw() {
  salt=$1
  pw=$2
  # Prefer sha256sum when present; fall back to md5sum (label accordingly)
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(printf '%s' "${salt}${pw}" | sha256sum | cut -c1-64)
    echo "sha256:${salt}:${h}"
  else
    h=$(printf '%s' "${salt}${pw}" | md5sum | cut -c1-32)
    echo "md5:${salt}:${h}"
  fi
}

verify_pw() {
  pw=$1
  line=$(grep '^password_hash=' "$ADMIN_CONF" 2>/dev/null | head -n 1 | sed 's/^password_hash=//')
  [ -z "$line" ] && return 1
  algo=$(echo "$line" | cut -d: -f1)
  salt=$(echo "$line" | cut -d: -f2)
  want=$(echo "$line" | cut -d: -f3)
  case "$algo" in
    sha256)
      got=$(printf '%s' "${salt}${pw}" | sha256sum 2>/dev/null | cut -c1-64)
      ;;
    md5|sha256_legacy|*)
      # Historical portal used label sha256: but md5 body — accept both
      got=$(printf '%s' "${salt}${pw}" | md5sum | cut -c1-32)
      if [ "$got" != "$want" ] && command -v sha256sum >/dev/null 2>&1; then
        got=$(printf '%s' "${salt}${pw}" | sha256sum | cut -c1-64)
      fi
      ;;
  esac
  [ "$got" = "$want" ]
}

session_ok() {
  tok=$(cookie_get admin_sess)
  [ -z "$tok" ] && return 1
  [ -f "$SESS" ] || return 1
  exp=$(cat "$SESS")
  [ "$tok" = "$exp" ]
}

require_csrf() {
  body=$1
  csrf=$(json_str "$body" csrf)
  [ -z "$csrf" ] && csrf=$(cookie_get csrf)
  exp=$(cat "$CSRF" 2>/dev/null || true)
  [ -n "$csrf" ] && [ "$csrf" = "$exp" ]
}

json_out() {
  code=$1
  shift
  [ "$code" != "200" ] && echo "Status: $code"
  echo "Content-Type: application/json"
  echo "Cache-Control: no-store"
  echo ""
  echo "$*"
}

wifi_get() {
  key=$1
  def=${2:-}
  [ -f "$CFGDIR/wifi.conf" ] || { echo "$def"; return; }
  val=$(sed -n "s/^${key}=//p" "$CFGDIR/wifi.conf" 2>/dev/null | head -n 1)
  [ -n "$val" ] && echo "$val" || echo "$def"
}

valid_ipv4() {
  ip=$1
  echo "$ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
  o1=$(echo "$ip" | cut -d. -f1)
  o2=$(echo "$ip" | cut -d. -f2)
  o3=$(echo "$ip" | cut -d. -f3)
  o4=$(echo "$ip" | cut -d. -f4)
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

find_wifi_manager() {
  for b in /media/mmcblk0p1/lc/bin/wifi-manager.sh /media/mmcblk1p1/lc/bin/wifi-manager.sh \
           /media/mmcblk0p1/localcam/bin/wifi-manager.sh "$CFGDIR/../bin/wifi-manager.sh"; do
    [ -x "$b" ] && echo "$b" && return 0
  done
  return 1
}

ensure_csrf() {
  tok=$(cat "$CSRF" 2>/dev/null || true)
  if [ -z "$tok" ]; then
    tok=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | md5sum | cut -c1-16)
    echo "$tok" > "$CSRF"
  fi
  echo "$tok"
}

route=$(basename "${SCRIPT_NAME:-admin}")
case "$route" in
  admin_csrf)
    # Unauthenticated: seed CSRF cookie for the login form
    csrf=$(ensure_csrf)
    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo "Set-Cookie: csrf=$csrf; Path=/"
    echo ""
    printf '{"csrf":"%s"}\n' "$csrf"
    exit 0
    ;;
  admin_login)
    body=$(read_body)
    require_csrf "$body" || { json_out "403 Forbidden" '{"error":"CSRF check failed"}'; exit 0; }
    pw=$(json_str "$body" password)
    if ! verify_pw "$pw"; then
      echo "$(date) admin_login fail" >> /tmp/localcam-admin.log
      json_out "401 Unauthorized" '{"error":"Invalid password"}'
      exit 0
    fi
    sess=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-32)
    umask 077
    echo "$sess" > "$SESS"
    csrf=$(ensure_csrf)
    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo "Set-Cookie: admin_sess=$sess; Path=/; HttpOnly"
    echo "Set-Cookie: csrf=$csrf; Path=/"
    echo ""
    echo '{"ok":true}'
    exit 0
    ;;
  admin_logout)
    body=$(read_body)
    require_csrf "$body" || true
    rm -f "$SESS"
    echo "Content-Type: application/json"
    echo "Set-Cookie: admin_sess=; Path=/; Max-Age=0"
    echo ""
    echo '{"ok":true}'
    exit 0
    ;;
  admin_status)
    csrf=$(ensure_csrf)
    if ! session_ok; then
      echo "Status: 401 Unauthorized"
      echo "Content-Type: application/json"
      echo "Cache-Control: no-store"
      echo "Set-Cookie: csrf=$csrf; Path=/"
      echo ""
      echo '{"error":"auth required"}'
      exit 0
    fi
    st=$(cat "$RUNDIR/wifi.state" 2>/dev/null || echo unknown)
    ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
    netmask=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*Mask:\([0-9.]*\).*/\1/p' | head -n 1)
    gateway=$(route -n 2>/dev/null | sed -n 's/^0\.0\.0\.0[[:space:]]\{1,\}\([0-9.]\{1,\}\).*/\1/p' | head -n 1)
    ssid=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p' | head -n 1)
    ip_mode=$(wifi_get ip_mode dhcp)
    case "$ip_mode" in static|STATIC) ip_mode=static ;; *) ip_mode=dhcp ;; esac
    cfg_ip=$(wifi_get ip_addr)
    cfg_nm=$(wifi_get ip_netmask)
    cfg_gw=$(wifi_get ip_gateway)

    # Listening ports (BusyBox netstat); fall back to empty
    ports=$(netstat -lntu 2>/dev/null || true)
    port_up() { echo "$ports" | grep -qE "[.:]$1 " || echo "$ports" | grep -qE ":$1 "; }

    # RTSP: distinguish H.264 (:554) vs MJPEG preview (:8554)
    rtsp_h264=false; rtsp_mjpeg=false
    for pid in $(pidof snx_rtsp_server 2>/dev/null); do
      cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      case "$cmd" in
        *-P\ 8554*|*-P\ 8554|*/dev/video2*) rtsp_mjpeg=true ;;
        *) rtsp_h264=true ;;
      esac
    done
    port_up 554 && rtsp_h264=true
    port_up 8554 && rtsp_mjpeg=true

    httpd_admin=false
    pidof httpd >/dev/null 2>&1 && port_up 80 && httpd_admin=true
    # ONVIF helper httpd on :8000 (may share binary name)
    onvif=false
    if port_up 8000; then
      onvif=true
    elif [ -f "$RUNDIR/onvif.pid" ]; then
      opid=$(cat "$RUNDIR/onvif.pid" 2>/dev/null)
      [ -n "$opid" ] && [ -d "/proc/$opid" ] && onvif=true
    fi

    wsd=false; pidof wsd-lite >/dev/null 2>&1 && wsd=true
    sshd=false; pidof dropbear >/dev/null 2>&1 && sshd=true
    wifi_sup=false; pidof wpa_supplicant >/dev/null 2>&1 && wifi_sup=true
    dhcp=false; pidof udhcpc >/dev/null 2>&1 && dhcp=true
    telnet=false; pidof telnetd >/dev/null 2>&1 && telnet=true
    ftp=false; pidof tcpsvd >/dev/null 2>&1 && ftp=true
    irctl=false
    ps 2>/dev/null | grep -q '[f]ang-ir-control' && irctl=true
    rec=false
    rec_detail="recorder.sh"
    rst=$(cat "$RUNDIR/recorder.state" 2>/dev/null || true)
    if [ -f "$RUNDIR/recorder.run" ]; then
      rpid=$(cat "$RUNDIR/recorder.pid" 2>/dev/null || true)
      if [ -n "$rpid" ] && [ -d "/proc/$rpid" ]; then
        rec=true
      elif ps 2>/dev/null | grep -q '[r]ecorder'; then
        rec=true
      fi
    fi
    # Host-assisted recorder: recent segments on SD also count as up
    if [ "$rec" = false ]; then
      for d in /media/mmcblk0p1/record/localcam /media/mmcblk1p1/record/localcam; do
        if [ -d "$d" ] && find "$d" -name 'seg_*' -mmin -3 2>/dev/null | grep -q .; then
          rec=true
          rst=${rst:-host-assisted}
          break
        fi
      done
    fi
    [ -n "$rst" ] && rec_detail="state=$rst"

    # Build services JSON array
    svc() {
      # svc id label running detail
      printf '{"id":"%s","name":"%s","running":%s,"detail":"%s"}' \
        "$1" "$2" "$3" "$(json_escape "$4")"
    }
    services=$(
      printf '['
      first=1
      add() {
        [ "$first" = 1 ] || printf ','
        first=0
        svc "$1" "$2" "$3" "$4"
      }
      host=${ip:-0.0.0.0}
      add wifi "Wi-Fi (STA)" "$wifi_sup" "state=$st ssid=${ssid:-—}"
      if [ "$ip_mode" = static ]; then
        add dhcp "IP addressing" true "static ${ip:-—}/${netmask:-—} gw ${gateway:-—}"
      else
        add dhcp "IP addressing" "$dhcp" "dhcp ${ip:-—}/${netmask:-—} gw ${gateway:-—}"
      fi
      add httpd "Admin web" "$httpd_admin" "http://${host}/"
      add rtsp "RTSP H.264" "$rtsp_h264" "rtsp://${host}:554/unicast"
      add mjpeg "MJPEG preview" "$rtsp_mjpeg" "rtsp://${host}:8554/mjpeg"
      add onvif "ONVIF" "$onvif" "http://${host}:8000/cgi-bin/device_service"
      add wsd "WS-Discovery" "$wsd" "udp://${host}:3702"
      add ssh "SSH (dropbear)" "$sshd" "ssh://root@${host}:22"
      add telnet "Telnet" "$telnet" "telnet://${host}:2323"
      add ftp "FTP" "$ftp" "ftp://${host}:21"
      add ir "IR / night control" "$irctl" "fang-ir-control"
      add record "SD recorder" "$rec" "$rec_detail"
      printf ']'
    )

    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo ""
    printf '{"state":"%s","ip":"%s","netmask":"%s","gateway":"%s","ssid":"%s","rtsp":%s,"ip_mode":"%s","cfg_ip":"%s","cfg_netmask":"%s","cfg_gateway":"%s","services":%s}\n' \
      "$(json_escape "$st")" "$(json_escape "$ip")" "$(json_escape "$netmask")" \
      "$(json_escape "$gateway")" "$(json_escape "$ssid")" \
      "$rtsp_h264" "$ip_mode" \
      "$(json_escape "$cfg_ip")" "$(json_escape "$cfg_nm")" "$(json_escape "$cfg_gw")" \
      "$services"
    exit 0
    ;;
  admin_password)
    body=$(read_body)
    session_ok || { json_out "401 Unauthorized" '{"error":"auth required"}'; exit 0; }
    require_csrf "$body" || { json_out "403 Forbidden" '{"error":"CSRF check failed"}'; exit 0; }
    old=$(json_str "$body" old_password)
    new=$(json_str "$body" new_password)
    verify_pw "$old" || { json_out "401 Unauthorized" '{"error":"current password wrong"}'; exit 0; }
    nlen=$(printf '%s' "$new" | wc -c)
    [ "$nlen" -lt 8 ] && { json_out "400 Bad Request" '{"error":"new password min 8 chars"}'; exit 0; }
    salt=$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | md5sum | cut -c1-8)
    umask 077
    echo "password_hash=$(hash_pw "$salt" "$new")" > "$ADMIN_CONF.tmp"
    mv "$ADMIN_CONF.tmp" "$ADMIN_CONF"
    sync
    # rotate session
    sess=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-32)
    echo "$sess" > "$SESS"
    echo "Content-Type: application/json"
    echo "Set-Cookie: admin_sess=$sess; Path=/; HttpOnly"
    echo ""
    echo '{"ok":true}'
    exit 0
    ;;
  admin_wifi)
    # Change saved Wi-Fi from fallback/setup — requires admin auth
    body=$(read_body)
    session_ok || { json_out "401 Unauthorized" '{"error":"auth required"}'; exit 0; }
    require_csrf "$body" || { json_out "403 Forbidden" '{"error":"CSRF check failed"}'; exit 0; }
    ssid=$(json_str "$body" ssid)
    psk=$(json_str "$body" psk)
    open=$(json_str "$body" open)
    [ -z "$ssid" ] && { json_out "400 Bad Request" '{"error":"SSID required"}'; exit 0; }
    key_mgmt=WPA-PSK
    [ "$open" = "true" ] && key_mgmt=NONE && psk=
    # Preserve IP settings when rewriting Wi-Fi credentials
    keep_mode=$(wifi_get ip_mode dhcp)
    keep_ip=$(wifi_get ip_addr)
    keep_nm=$(wifi_get ip_netmask)
    keep_gw=$(wifi_get ip_gateway)
    umask 077
    {
      printf 'ssid=%s\n' "$ssid"
      printf 'psk=%s\n' "$psk"
      printf 'key_mgmt=%s\n' "$key_mgmt"
      echo "hidden=0"
      printf 'ip_mode=%s\n' "$keep_mode"
      [ -n "$keep_ip" ] && printf 'ip_addr=%s\n' "$keep_ip"
      [ -n "$keep_nm" ] && printf 'ip_netmask=%s\n' "$keep_nm"
      [ -n "$keep_gw" ] && printf 'ip_gateway=%s\n' "$keep_gw"
    } > "$CFGDIR/wifi.conf.tmp"
    mv "$CFGDIR/wifi.conf.tmp" "$CFGDIR/wifi.conf"
    sync
    echo "$(date) admin wifi update ssid=$ssid" >> /tmp/localcam-admin.log
    json_out "200" '{"ok":true,"message":"Wi-Fi saved"}'
    exit 0
    ;;
  admin_net)
    # DHCP or static IP — requires admin auth; applied live if associated
    body=$(read_body)
    session_ok || { json_out "401 Unauthorized" '{"error":"auth required"}'; exit 0; }
    require_csrf "$body" || { json_out "403 Forbidden" '{"error":"CSRF check failed"}'; exit 0; }
    mode=$(json_str "$body" mode)
    nip=$(json_str "$body" ip)
    nnm=$(json_str "$body" netmask)
    ngw=$(json_str "$body" gateway)
    case "$mode" in
      dhcp|DHCP) mode=dhcp ;;
      static|STATIC) mode=static ;;
      *) json_out "400 Bad Request" '{"error":"mode must be dhcp or static"}'; exit 0 ;;
    esac
    if [ "$mode" = static ]; then
      valid_ipv4 "$nip" || { json_out "400 Bad Request" '{"error":"invalid IP address"}'; exit 0; }
      [ -z "$nnm" ] && nnm=255.255.255.0
      valid_ipv4 "$nnm" || { json_out "400 Bad Request" '{"error":"invalid netmask"}'; exit 0; }
      if [ -n "$ngw" ]; then
        valid_ipv4 "$ngw" || { json_out "400 Bad Request" '{"error":"invalid gateway"}'; exit 0; }
      fi
    else
      nip=; nnm=; ngw=
    fi
    # Rewrite wifi.conf preserving Wi-Fi credentials
    keep_ssid=$(wifi_get ssid)
    keep_psk=$(wifi_get psk)
    keep_km=$(wifi_get key_mgmt WPA-PSK)
    keep_hid=$(wifi_get hidden 0)
    [ -z "$keep_ssid" ] && { json_out "400 Bad Request" '{"error":"save Wi-Fi first"}'; exit 0; }
    umask 077
    {
      printf 'ssid=%s\n' "$keep_ssid"
      printf 'psk=%s\n' "$keep_psk"
      printf 'key_mgmt=%s\n' "$keep_km"
      printf 'hidden=%s\n' "$keep_hid"
      printf 'ip_mode=%s\n' "$mode"
      if [ "$mode" = static ]; then
        printf 'ip_addr=%s\n' "$nip"
        printf 'ip_netmask=%s\n' "$nnm"
        [ -n "$ngw" ] && printf 'ip_gateway=%s\n' "$ngw"
      fi
    } > "$CFGDIR/wifi.conf.tmp"
    mv "$CFGDIR/wifi.conf.tmp" "$CFGDIR/wifi.conf"
    sync
    echo "$(date) admin net mode=$mode ip=$nip" >> /tmp/localcam-admin.log
    applied=false
    msg="Network settings saved"
    WM=$(find_wifi_manager) || WM=
    if [ -n "$WM" ]; then
      if "$WM" apply-ip >>/tmp/localcam-wifi.log 2>&1; then
        applied=true
        if [ "$mode" = static ]; then
          msg="Static IP applied ($nip). If the address changed, reconnect to the new IP."
        else
          msg="DHCP enabled; requesting a lease."
        fi
      else
        msg="Saved; will apply on next Wi-Fi connect (not associated yet)."
      fi
    else
      msg="Saved; will apply on next Wi-Fi connect."
    fi
    json_out "200" "{\"ok\":true,\"applied\":$applied,\"message\":\"$(json_escape "$msg")\",\"ip_mode\":\"$mode\",\"ip\":\"$(json_escape "$nip")\"}"
    exit 0
    ;;
  admin_preview)
    # Single JPEG snapshot for admin UI (session cookie required).
    if ! session_ok; then
      echo "Status: 401 Unauthorized"
      echo "Content-Type: application/json"
      echo "Cache-Control: no-store"
      echo ""
      echo '{"error":"auth required"}'
      exit 0
    fi
    SNAP=
    for b in /media/mmcblk0p1/lc/bin/rtsp-jpeg /media/mmcblk1p1/lc/bin/rtsp-jpeg \
             /media/mmcblk0p1/localcam/bin/rtsp-jpeg /usr/local/bin/rtsp-jpeg \
             "$RUNDIR/bin/rtsp-jpeg"; do
      [ -x "$b" ] && SNAP=$b && break
    done
    if [ -z "$SNAP" ]; then
      echo "Status: 503 Service Unavailable"
      echo "Content-Type: application/json"
      echo ""
      echo '{"error":"snapshot tool missing"}'
      exit 0
    fi
    # Restart MJPEG helper if it died (does not touch H.264 :554)
    if ! netstat -lnt 2>/dev/null | grep -qE '[.:]8554 '; then
      for svc in /media/mmcblk0p1/lc/bin/services.sh /media/mmcblk1p1/lc/bin/services.sh; do
        if [ -x "$svc" ]; then
          "$svc" start-mjpeg >>/tmp/localcam-preview.err 2>&1 || true
          break
        fi
      done
    fi
    # Serialize grabs (BusyBox has no flock); recover stale locks
    lockdir=/tmp/localcam-preview.lock
    if [ -d "$lockdir" ]; then
      opid=$(cat "$lockdir/pid" 2>/dev/null || true)
      if [ -z "$opid" ] || ! kill -0 "$opid" 2>/dev/null; then
        rm -rf "$lockdir"
      fi
    fi
    i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 40 ]; then
        # Force-clear likely-stale lock after ~8s wait
        rm -rf "$lockdir"
        mkdir "$lockdir" 2>/dev/null || {
          echo "Status: 503 Service Unavailable"
          echo "Content-Type: application/json"
          echo ""
          echo '{"error":"preview busy"}'
          exit 0
        }
        break
      fi
      sleep 0.2 2>/dev/null || sleep 1
    done
    echo $$ > "$lockdir/pid" 2>/dev/null || true
    tmp=$RUNDIR/preview.jpg.$$
    ok=0
    if "$SNAP" "rtsp://127.0.0.1:8554/mjpeg" > "$tmp" 2>/tmp/localcam-preview.err; then
      sz=$(wc -c < "$tmp" | tr -d ' ')
      if [ -n "$sz" ] && [ "$sz" -gt 100 ]; then
        echo "Content-Type: image/jpeg"
        echo "Cache-Control: no-store"
        echo ""
        cat "$tmp"
        ok=1
      fi
    fi
    rm -f "$tmp"
    rm -rf "$lockdir"
    [ "$ok" = "1" ] && exit 0
    echo "Status: 503 Service Unavailable"
    echo "Content-Type: application/json"
    echo ""
    echo '{"error":"capture failed"}'
    exit 0
    ;;
  *)
    json_out "404 Not Found" '{"error":"not found"}'
    exit 0
    ;;
esac
