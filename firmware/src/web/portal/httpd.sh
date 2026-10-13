#!/bin/sh
# Captive portal HTTP using fanghacks BusyBox httpd + dnsd (AP mode only).

PORTAL_ROOT="${PORTAL_ROOT:-/media/mmcblk0p1/localcam/portal}"
RUNDIR="${RUNDIR:-/tmp/localcam}"
AP_IP="${AP_IP:-192.168.4.1}"
FH_SBIN="${FH_SBIN:-/media/mmcblk0p2/data/usr/sbin}"
[ -x "$FH_SBIN/httpd" ] || FH_SBIN=/media/mmcblk0p1/localcam/sbin
HTTPD="${HTTPD:-$FH_SBIN/httpd}"
DNSD="${DNSD:-$FH_SBIN/dnsd}"
# Keep in sync with wifi-manager / portal CGI
if [ -z "$CFGDIR" ]; then
  if [ -d /media/mmcblk0p1/localcam ]; then
    CFGDIR=/media/mmcblk0p1/localcam/etc
  elif [ -d /media/mmcblk0p2/data/localcam ]; then
    CFGDIR=/media/mmcblk0p2/data/localcam/etc
  else
    CFGDIR=/etc/localcam
  fi
fi
export CFGDIR RUNDIR PORTAL_ROOT

mkdir -p "$RUNDIR/www/cgi-bin" 2>/dev/null || true
rm -rf "$RUNDIR/www"
mkdir -p "$RUNDIR/www/cgi-bin"

cp -a "$PORTAL_ROOT/index.html" "$RUNDIR/www/"
chmod +x "$PORTAL_ROOT/cgi-bin/api.sh"
# BusyBox httpd may not execute CGI via symlink — copy scripts
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/api"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/status"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/scan"
cp -a "$PORTAL_ROOT/cgi-bin/api.sh" "$RUNDIR/www/cgi-bin/connect"
chmod +x "$RUNDIR/www/cgi-bin/"*

# Captive detection stubs → redirect via cgi
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

# BusyBox httpd.conf: A:* allow all. Do NOT add /path:user:pass (that forces Basic auth).
cat > "$RUNDIR/httpd.conf" <<EOF
A:*
EOF

killall httpd dnsd 2>/dev/null || true
sleep 1

# DNS sinkhole: all queries → AP_IP
if [ -x "$DNSD" ]; then
  # dnsd format: name IP — use wildcard if supported; else rely on DHCP dns=AP
  echo "* $AP_IP" > "$RUNDIR/dnsd.conf"
  "$DNSD" -c "$RUNDIR/dnsd.conf" -p 53 -d >/dev/null 2>&1 &
  echo $! > "$RUNDIR/dnsd.pid"
fi

# Bind httpd (listen all — firewall later restricts to AP)
if [ -x "$HTTPD" ]; then
  "$HTTPD" -h "$RUNDIR/www" -p 80 -c "$RUNDIR/httpd.conf" >/tmp/localcam-httpd.log 2>&1 &
  echo $! > "$RUNDIR/httpd.pid"
else
  echo "httpd not found at $HTTPD" >&2
  exit 1
fi
echo "portal http://$AP_IP/"
