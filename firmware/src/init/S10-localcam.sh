#!/bin/sh
# Localcam boot hook (SD-test or future rootfs /etc/init.d)
# Starts Wi-Fi manager then local services when STA is up.

# shellcheck disable=SC1091
for _p in \
  /media/mmcblk0p1/lc/bin/paths.sh \
  /media/mmcblk1p1/lc/bin/paths.sh \
  /media/mmcblk0p2/data/localcam/bin/paths.sh
do
  [ -f "$_p" ] && . "$_p" && break
done

export PATH="${LC_ROOT:-/media/mmcblk0p1/lc}/bin:${FH_ROOT:-/media/mmcblk0p2/data}/usr/sbin:${FH_ROOT:-/media/mmcblk0p2/data}/usr/bin:${FH_ROOT:-/media/mmcblk0p2/data}/bin:/sbin:/bin:/usr/bin:$PATH"
export CFGDIR="${CFGDIR:-}"
export RUNDIR="${RUNDIR:-/tmp/localcam}"
export PORTAL_ROOT="${LC_ROOT:-}/portal"
export WM="${LC_ROOT:-}/bin/wifi-manager.sh"
[ -x "$WM" ] || WM=/media/mmcblk0p2/data/localcam/bin/wifi-manager.sh

mkdir -p "$CFGDIR" "$RUNDIR"

# Unload watchdog if present (fanghacks pattern) when not using vendor apps
modprobe -rf snx_wdt 2>/dev/null || true

"$WM" start
"$WM" monitor &
echo $! > "$RUNDIR/wifi-monitor.pid"

st=$(cat "$RUNDIR/wifi.state" 2>/dev/null)
HTTPD_SH="${LC_ROOT:-}/bin/httpd.sh"
[ -x "$HTTPD_SH" ] || HTTPD_SH=/media/mmcblk0p2/data/localcam/bin/httpd.sh

case "$st" in
  setup-ap|fallback-ap)
    [ -x "$HTTPD_SH" ] && "$HTTPD_SH" ap
    ;;
  station)
    [ -x "$HTTPD_SH" ] && "$HTTPD_SH" sta
    [ -x "${LC_ROOT:-}/bin/services.sh" ] && "${LC_ROOT:-}/bin/services.sh" start
    [ -x "${LC_ROOT:-}/bin/onvif-lite.sh" ] && "${LC_ROOT:-}/bin/onvif-lite.sh" || true
    ;;
esac
