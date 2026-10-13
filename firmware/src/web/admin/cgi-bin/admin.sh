#!/bin/sh
# Authenticated admin CGI (BusyBox httpd). Routes by SCRIPT_NAME basename.
# Do NOT source relative ../../wifi/paths.sh — CGI cwd under /tmp/.../cgi-bin breaks that.
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
    ssid=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\(.*\)".*/\1/p' | head -n 1)
    rtsp=false; pidof snx_rtsp_server >/dev/null 2>&1 && rtsp=true
    json_out "200" "{\"state\":\"$(json_escape "$st")\",\"ip\":\"$(json_escape "$ip")\",\"ssid\":\"$(json_escape "$ssid")\",\"rtsp\":$rtsp}"
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
    umask 077
    {
      printf 'ssid=%s\n' "$ssid"
      printf 'psk=%s\n' "$psk"
      printf 'key_mgmt=%s\n' "$key_mgmt"
      echo "hidden=0"
    } > "$CFGDIR/wifi.conf.tmp"
    mv "$CFGDIR/wifi.conf.tmp" "$CFGDIR/wifi.conf"
    sync
    echo "$(date) admin wifi update ssid=$ssid" >> /tmp/localcam-admin.log
    json_out "200" '{"ok":true,"message":"Wi-Fi saved"}'
    exit 0
    ;;
  *)
    json_out "404 Not Found" '{"error":"not found"}'
    exit 0
    ;;
esac
