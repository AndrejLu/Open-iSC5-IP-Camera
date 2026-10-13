#!/bin/sh
export CFGDIR=/media/mmcblk0p1/localcam/etc
export RUNDIR=/tmp/localcam
export PORTAL_ROOT=/media/mmcblk0p1/localcam/portal
export WM=/media/mmcblk0p1/localcam/bin/wifi-manager.sh
mkdir -p "$CFGDIR" "$RUNDIR"
killall wpa_supplicant hostapd udhcpd 2>/dev/null || true
"$WM" setup
/media/mmcblk0p1/localcam/bin/httpd.sh
"$WM" status
echo "AP_TEST_READY ssid=$($WM ssid) CFGDIR=$CFGDIR"
