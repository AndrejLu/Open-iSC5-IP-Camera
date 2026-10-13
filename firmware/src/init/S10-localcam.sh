#!/bin/sh
# Localcam boot hook (SD-test or future rootfs /etc/init.d)
# Starts Wi-Fi manager then local services when STA is up.

export PATH="/media/mmcblk0p2/data/localcam/bin:/media/mmcblk0p2/data/usr/sbin:/media/mmcblk0p2/data/usr/bin:/media/mmcblk0p2/data/bin:$PATH"
export CFGDIR="${CFGDIR:-/etc/localcam}"
# SD-test fallback store
[ -d /media/mmcblk0p2/data/localcam/etc ] && CFGDIR=/media/mmcblk0p2/data/localcam/etc
export RUNDIR=/tmp/localcam
export PORTAL_ROOT=/media/mmcblk0p2/data/localcam/portal
export WM=/media/mmcblk0p2/data/localcam/bin/wifi-manager.sh

mkdir -p "$CFGDIR" "$RUNDIR"

# Unload watchdog if present (fanghacks pattern) when not using vendor apps
modprobe -rf snx_wdt 2>/dev/null || true

"$WM" start
"$WM" monitor &
echo $! > "$RUNDIR/wifi-monitor.pid"

# Portal only in AP modes
st=$(cat "$RUNDIR/wifi.state" 2>/dev/null)
case "$st" in
  setup-ap|fallback-ap)
    /media/mmcblk0p2/data/localcam/bin/httpd.sh
    ;;
esac

# Local services when station
if [ "$st" = "station" ]; then
  [ -x /media/mmcblk0p2/data/localcam/bin/services.sh ] && /media/mmcblk0p2/data/localcam/bin/services.sh start
fi
