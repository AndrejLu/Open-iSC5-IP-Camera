#!/bin/sh
# Lightweight ONVIF Device/Media HTTP endpoints + WS-Discovery responder.
# Not Profile S certified. Enough for many NVRs to discover + GetStreamUri.

# shellcheck disable=SC1091
. "$(dirname "$0")/paths.sh" 2>/dev/null || . "$(dirname "$0")/../wifi/paths.sh" 2>/dev/null || true
RUNDIR="${RUNDIR:-/tmp/localcam}"
PORT="${ONVIF_PORT:-8000}"
FH_HTTPD="${FH_HTTPD:-$FH_SBIN/httpd}"
[ -x "$FH_HTTPD" ] || FH_HTTPD=/media/mmcblk1p2/data/usr/sbin/httpd
[ -x "$FH_HTTPD" ] || FH_HTTPD=/media/mmcblk0p2/data/usr/sbin/httpd

IFCFG=$(command -v ifconfig 2>/dev/null || echo /sbin/ifconfig)
IP=$($IFCFG wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
[ -z "$IP" ] && IP=$($IFCFG eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
[ -z "$IP" ] && IP=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)
[ -z "$IP" ] && IP="0.0.0.0"
# Never advertise AP addressing for ONVIF
case "$IP" in 192.168.4.*) echo "onvif-lite: skip on AP IP"; exit 0 ;; esac

URI="rtsp://${IP}:554/unicast"
XADDR="http://${IP}:${PORT}/onvif/device_service"
mkdir -p "$RUNDIR/onvif/cgi-bin" "$RUNDIR/onvif/onvif"

# Single CGI that inspects SOAP Action / body keywords
cat > "$RUNDIR/onvif/cgi-bin/device_service" <<EOF
#!/bin/sh
body=\$(dd bs=1 count=\${CONTENT_LENGTH:-0} 2>/dev/null)
echo "Content-Type: application/soap+xml; charset=utf-8"
echo ""
case "\$body\$HTTP_SOAPACTION\$REQUEST_URI" in
  *GetDeviceInformation*)
    cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <tds:GetDeviceInformationResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
   <tds:Manufacturer>Localcam</tds:Manufacturer>
   <tds:Model>iSC5</tds:Model>
   <tds:FirmwareVersion>0.1.0-dev</tds:FirmwareVersion>
   <tds:SerialNumber>local</tds:SerialNumber>
   <tds:HardwareId>SN98660</tds:HardwareId>
  </tds:GetDeviceInformationResponse>
 </s:Body>
</s:Envelope>
SOAP
    ;;
  *GetCapabilities*|*GetServices*)
    cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
   <tds:Capabilities>
    <tt:Device xmlns:tt="http://www.onvif.org/ver10/schema">
     <tt:XAddr>${XADDR}</tt:XAddr>
    </tt:Device>
    <tt:Media xmlns:tt="http://www.onvif.org/ver10/schema">
     <tt:XAddr>http://${IP}:${PORT}/onvif/media_service</tt:XAddr>
     <tt:StreamingCapabilities>
      <tt:RTP_TCP>true</tt:RTP_TCP>
     </tt:StreamingCapabilities>
    </tt:Media>
   </tds:Capabilities>
  </tds:GetCapabilitiesResponse>
 </s:Body>
</s:Envelope>
SOAP
    ;;
  *GetSystemDateAndTime*)
    now=\$(date -u +"-%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2016-01-01T00:00:00Z")
    cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <tds:GetSystemDateAndTimeResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
   <tds:SystemDateAndTime>
    <tt:DateTimeType xmlns:tt="http://www.onvif.org/ver10/schema">Manual</tt:DateTimeType>
    <tt:DaylightSavings xmlns:tt="http://www.onvif.org/ver10/schema">false</tt:DaylightSavings>
   </tds:SystemDateAndTime>
  </tds:GetSystemDateAndTimeResponse>
 </s:Body>
</s:Envelope>
SOAP
    ;;
  *)
    cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <tds:GetDeviceInformationResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
   <tds:Manufacturer>Localcam</tds:Manufacturer>
   <tds:Model>iSC5</tds:Model>
   <tds:FirmwareVersion>0.1.0-dev</tds:FirmwareVersion>
   <tds:SerialNumber>local</tds:SerialNumber>
   <tds:HardwareId>SN98660</tds:HardwareId>
  </tds:GetDeviceInformationResponse>
 </s:Body>
</s:Envelope>
SOAP
    ;;
esac
EOF
chmod +x "$RUNDIR/onvif/cgi-bin/device_service"

cat > "$RUNDIR/onvif/cgi-bin/media_service" <<EOF
#!/bin/sh
body=\$(dd bs=1 count=\${CONTENT_LENGTH:-0} 2>/dev/null)
echo "Content-Type: application/soap+xml; charset=utf-8"
echo ""
case "\$body\$HTTP_SOAPACTION" in
  *GetProfiles*|*GetVideoSources*)
    cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <trt:GetProfilesResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
   <trt:Profiles token="profile1" fixed="true">
    <tt:Name xmlns:tt="http://www.onvif.org/ver10/schema">MainStream</tt:Name>
    <tt:VideoEncoderConfiguration xmlns:tt="http://www.onvif.org/ver10/schema" token="venc1">
     <tt:Name>H264-1080p</tt:Name>
     <tt:Encoding>H264</tt:Encoding>
     <tt:Resolution><tt:Width>1920</tt:Width><tt:Height>1080</tt:Height></tt:Resolution>
     <tt:RateControl><tt:FrameRateLimit>25</tt:FrameRateLimit><tt:BitrateLimit>4096</tt:BitrateLimit></tt:RateControl>
    </tt:VideoEncoderConfiguration>
   </trt:Profiles>
  </trt:GetProfilesResponse>
 </s:Body>
</s:Envelope>
SOAP
    ;;
  *GetStreamUri*|*)
    cat <<SOAP
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <trt:GetStreamUriResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
   <trt:MediaUri>
    <tt:Uri xmlns:tt="http://www.onvif.org/ver10/schema">${URI}</tt:Uri>
    <tt:InvalidAfterConnect xmlns:tt="http://www.onvif.org/ver10/schema">false</tt:InvalidAfterConnect>
    <tt:InvalidAfterReboot xmlns:tt="http://www.onvif.org/ver10/schema">false</tt:InvalidAfterReboot>
    <tt:Timeout xmlns:tt="http://www.onvif.org/ver10/schema">PT60S</tt:Timeout>
   </trt:MediaUri>
  </trt:GetStreamUriResponse>
 </s:Body>
</s:Envelope>
SOAP
    ;;
esac
EOF
chmod +x "$RUNDIR/onvif/cgi-bin/media_service"

# Alias paths some clients use
cp "$RUNDIR/onvif/cgi-bin/device_service" "$RUNDIR/onvif/onvif/device_service"
cp "$RUNDIR/onvif/cgi-bin/media_service" "$RUNDIR/onvif/onvif/media_service"
chmod +x "$RUNDIR/onvif/onvif/"*

echo "A:*" > "$RUNDIR/onvif-httpd.conf"
[ -f "$RUNDIR/onvif.pid" ] && kill "$(cat "$RUNDIR/onvif.pid")" 2>/dev/null || true
if [ -x "$FH_HTTPD" ]; then
  "$FH_HTTPD" -h "$RUNDIR/onvif" -p "$PORT" -c "$RUNDIR/onvif-httpd.conf" \
    >/tmp/localcam-onvif.log 2>&1 &
  echo $! > "$RUNDIR/onvif.pid"
  echo "onvif-lite: $XADDR media→$URI"
fi

# WS-Discovery via static ARMv5 wsd-lite (preferred), else skip
WSD_BIN=""
for c in \
  "$(dirname "$0")/wsd-lite" \
  "$LC_ROOT/bin/wsd-lite" \
  /media/mmcblk0p1/lc/bin/wsd-lite \
  /media/mmcblk1p1/lc/bin/wsd-lite \
  /media/mmcblk0p2/data/localcam/bin/wsd-lite \
  /media/mmcblk1p2/data/localcam/bin/wsd-lite \
  /usr/local/bin/wsd-lite
do
  [ -x "$c" ] && WSD_BIN=$c && break
done
[ -f "$RUNDIR/wsd.pid" ] && kill "$(cat "$RUNDIR/wsd.pid")" 2>/dev/null || true
if [ -n "$WSD_BIN" ]; then
  "$WSD_BIN" "$XADDR" >/tmp/localcam-wsd.log 2>&1 &
  echo $! > "$RUNDIR/wsd.pid"
  echo "onvif-lite: WS-Discovery UDP 3702 via $WSD_BIN"
else
  echo "onvif-lite: wsd-lite missing — WS-Discovery skipped (HTTP only)"
fi
