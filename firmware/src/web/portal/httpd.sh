#!/bin/sh
# Captive portal HTTP using fanghacks BusyBox httpd + dnsd (AP mode only).
# Also stages admin CGI for authenticated Wi-Fi changes in fallback mode.

# shellcheck disable=SC1091
for _p in \
  "$(dirname "$0")/../../wifi/paths.sh" \
  /media/mmcblk1p1/lc/bin/paths.sh \
  /media/mmcblk0p1/localcam/bin/paths.sh
do
  [ -f "$_p" ] && . "$_p" && break
done

PORTAL_ROOT="${PORTAL_ROOT:-}"
if [ -z "$PORTAL_ROOT" ]; then
  for d in /media/mmcblk1p1/lc/portal /media/mmcblk0p1/localcam/portal \
           /media/mmcblk1p2/data/localcam/portal /media/mmcblk0p2/data/localcam/portal; do
    [ -d "$d" ] && PORTAL_ROOT=$d && break
  done
fi
ADMIN_ROOT="${ADMIN_ROOT:-}"
if [ -z "$ADMIN_ROOT" ]; then
  for d in /media/mmcblk1p1/lc/admin /media/mmcblk0p1/localcam/admin \
           /media/mmcblk1p2/data/localcam/admin /media/mmcblk0p2/data/localcam/admin \
           "$(dirname "$0")/../admin"; do
    [ -d "$d" ] && ADMIN_ROOT=$d && break
  done
fi

RUNDIR="${RUNDIR:-/tmp/localcam}"
AP_IP="${AP_IP:-192.168.4.1}"
FH_SBIN="${FH_SBIN:-}"
if [ -z "$FH_SBIN" ] || [ ! -x "$FH_SBIN/httpd" ]; then
  for d in /media/mmcblk1p2/data/usr/sbin /media/mmcblk0p2/data/usr/sbin \
           /media/mmcblk1p1/lc/sbin /media/mmcblk0p1/localcam/sbin; do
    [ -x "$d/httpd" ] && FH_SBIN=$d && break
  done
fi
HTTPD="${HTTPD:-$FH_SBIN/httpd}"
DNSD="${DNSD:-$FH_SBIN/dnsd}"
export CFGDIR RUNDIR PORTAL_ROOT

mkdir -p "$RUNDIR/www/cgi-bin" 2>/dev/null || true
rm -rf "$RUNDIR/www"
mkdir -p "$RUNDIR/www/cgi-bin"

cp -a "$PORTAL_ROOT/index.html" "$RUNDIR/www/"
chmod +x "$PORTAL_ROOT/cgi-bin/api.sh"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/api"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/status"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/scan"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/connect"

# Admin UI + CGI (auth required for settings)
if [ -f "$ADMIN_ROOT/index.html" ]; then
  mkdir -p "$RUNDIR/www/admin"
  cp -a "$ADMIN_ROOT/index.html" "$RUNDIR/www/admin/"
fi
if [ -f "$ADMIN_ROOT/cgi-bin/admin.sh" ]; then
  chmod +x "$ADMIN_ROOT/cgi-bin/admin.sh"
  for ep in admin_login admin_logout admin_status admin_password admin_wifi; do
    cp -a "$ADMIN_ROOT/cgi-bin/admin.sh" "$RUNDIR/www/cgi-bin/$ep"
  done
fi
chmod +x "$RUNDIR/www/cgi-bin/"*

# Captive detection stubs → redirect to portal
cat > "$RUNDIR/www/cgi-bin/generate_204" <<'EOF'
#!/bin/sh
echo "Status: 302 Found"
echo "Location: http://192.168.4.1/"
echo ""
EOF
chmod +x "$RUNDIR/www/cgi-bin/generate_204"
cp "$RUNDIR/www/cgi-bin/generate_204" "$RUNDIR/www/cgi-bin/hotspot-detect.html"
cp "$RUNDIR/www/cgi-bin/generate_204" "$RUNDIR/www/cgi-bin/ncsi.txt"
cp "$RUNDIR/www/cgi-bin/generate_204" "$RUNDIR/www/cgi-bin/connecttest.txt"

cat > "$RUNDIR/httpd.conf" <<EOF
A:*
EOF

killall httpd dnsd 2>/dev/null || true
sleep 1

if [ -x "$DNSD" ]; then
  echo "* $AP_IP" > "$RUNDIR/dnsd.conf"
  "$DNSD" -c "$RUNDIR/dnsd.conf" -p 53 -d >/dev/null 2>&1 &
  echo $! > "$RUNDIR/dnsd.pid"
fi

if [ -x "$HTTPD" ]; then
  "$HTTPD" -h "$RUNDIR/www" -p 80 -c "$RUNDIR/httpd.conf" >/tmp/localcam-httpd.log 2>&1 &
  echo $! > "$RUNDIR/httpd.pid"
else
  echo "httpd not found at $HTTPD" >&2
  exit 1
fi
echo "portal http://$AP_IP/ (admin http://$AP_IP/admin/)"
