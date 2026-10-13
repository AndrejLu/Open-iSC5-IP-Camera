#!/bin/sh
# Minimal ONVIF-ish HTTP responder scaffold (device/media Get* only).
# Not Profile S certified. Uses BusyBox httpd CGI on port 8000 when STA mode.

RUNDIR="${RUNDIR:-/tmp/localcam}"
PORT="${ONVIF_PORT:-8000}"
FH_HTTPD="${FH_HTTPD:-/media/mmcblk0p2/data/usr/sbin/httpd}"
RTSP_HOST="${RTSP_HOST:-}"

mkdir -p "$RUNDIR/onvif/cgi-bin"

# Very small SOAP-ish responses — enough for some NVRs to list a profile URI.
cat > "$RUNDIR/onvif/cgi-bin/device_service" <<'EOF'
#!/bin/sh
echo "Content-Type: application/soap+xml; charset=utf-8"
echo ""
cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope">
  <SOAP-ENV:Body>
    <tds:GetDeviceInformationResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
      <tds:Manufacturer>Localcam</tds:Manufacturer>
      <tds:Model>iSC5</tds:Model>
      <tds:FirmwareVersion>0.1.0-dev</tds:FirmwareVersion>
      <tds:SerialNumber>local</tds:SerialNumber>
      <tds:HardwareId>SN98660</tds:HardwareId>
    </tds:GetDeviceInformationResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
SOAP
EOF
chmod +x "$RUNDIR/onvif/cgi-bin/device_service"

IP=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
[ -z "$IP" ] && IP="0.0.0.0"
URI="rtsp://${IP}:554/unicast"

cat > "$RUNDIR/onvif/cgi-bin/media_service" <<EOF
#!/bin/sh
echo "Content-Type: application/soap+xml; charset=utf-8"
echo ""
cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope">
  <SOAP-ENV:Body>
    <trt:GetStreamUriResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
      <trt:MediaUri>
        <tt:Uri xmlns:tt="http://www.onvif.org/ver10/schema">${URI}</tt:Uri>
      </trt:MediaUri>
    </trt:GetStreamUriResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
SOAP
EOF
chmod +x "$RUNDIR/onvif/cgi-bin/media_service"

echo "A:*" > "$RUNDIR/onvif-httpd.conf"
killall -q onvif-httpd 2>/dev/null || true
# Bind alternate port; name collision avoided by -p
if [ -x "$FH_HTTPD" ]; then
  "$FH_HTTPD" -h "$RUNDIR/onvif" -p "$PORT" -c "$RUNDIR/onvif-httpd.conf" \
    >/tmp/localcam-onvif.log 2>&1 &
  echo $! > "$RUNDIR/onvif.pid"
  echo "onvif-lite: http://$IP:$PORT/cgi-bin/device_service (scaffold)"
fi
