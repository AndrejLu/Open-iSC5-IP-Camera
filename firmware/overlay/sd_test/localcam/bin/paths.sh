# Shared path detection for SD-test (mmcblk0/1, localcam/lc) and flash (/etc/localcam).
# Source this file; do not execute.

_localcam_pick() {
  # Prefer explicit override
  if [ -n "${LOCALCAM_ROOT:-}" ] && [ -d "$LOCALCAM_ROOT" ]; then
    echo "$LOCALCAM_ROOT"
    return
  fi
  for d in \
    /media/mmcblk1p1/lc \
    /media/mmcblk1p1/localcam \
    /media/mmcblk0p1/lc \
    /media/mmcblk0p1/localcam \
    /media/mmcblk1p2/data/localcam \
    /media/mmcblk0p2/data/localcam
  do
    if [ -d "$d" ]; then
      echo "$d"
      return
    fi
  done
  echo ""
}

if [ -z "${CFGDIR:-}" ]; then
  _root=$(_localcam_pick)
  if [ -n "$_root" ] && [ -d "$_root/etc" ]; then
    CFGDIR="$_root/etc"
  elif [ -n "$_root" ]; then
    CFGDIR="$_root/etc"
    mkdir -p "$CFGDIR" 2>/dev/null || true
  else
    CFGDIR=/etc/localcam
  fi
fi

if [ -z "${LC_ROOT:-}" ]; then
  LC_ROOT=$(_localcam_pick)
  [ -z "$LC_ROOT" ] && LC_ROOT=/etc/localcam
fi

RUNDIR="${RUNDIR:-/tmp/localcam}"
WLAN="${WLAN:-wlan0}"
AP_IP="${AP_IP:-192.168.4.1}"

# Fang binaries: try mmcblk1 then mmcblk0
if [ -z "${FH_ROOT:-}" ]; then
  for d in /media/mmcblk1p2/data /media/mmcblk0p2/data; do
    if [ -d "$d/usr/bin" ] || [ -d "$d/bin" ]; then
      FH_ROOT=$d
      break
    fi
  done
  FH_ROOT="${FH_ROOT:-/media/mmcblk0p2/data}"
fi
FH_BIN="${FH_BIN:-$FH_ROOT/usr/bin}"
FH_LIB="${FH_LIB:-$FH_ROOT/usr/lib}"
FH_SBIN="${FH_SBIN:-$FH_ROOT/usr/sbin}"
[ -x "$FH_SBIN/httpd" ] || FH_SBIN="$FH_ROOT/sbin"
[ -d "$FH_BIN" ] || FH_BIN="$FH_ROOT/bin"

# Dropbear/SSH sessions often lack /sbin — ensure BusyBox ifconfig/route/iwconfig work
PATH="/sbin:/usr/sbin:/bin:/usr/bin:${FH_ROOT}/sbin:${FH_ROOT}/usr/sbin:${FH_BIN}:${PATH}"
export PATH CFGDIR RUNDIR WLAN AP_IP LC_ROOT FH_ROOT FH_BIN FH_LIB FH_SBIN
