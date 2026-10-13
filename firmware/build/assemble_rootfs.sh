#!/bin/bash
# Assemble allowlisted rootfs tree and build cramfs if mkfs.cramfs available.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK="${STOCK:-/tmp/isc5_rootfs}"
OUT="$ROOT/build/rootfs"
IMG="$ROOT/images/rootfs_localcam.cramfs"
ALLOW="$ROOT/build/allowlist.txt"
LIMIT=$((7 * 1024 * 1024))

rm -rf "$OUT"
mkdir -p "$OUT" "$ROOT/images"

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  src="$STOCK/$line"
  dst="$OUT/$line"
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    cp -a "$src"/. "$dst"/
  elif [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  else
    echo "WARN missing: $src" >&2
  fi
done < "$ALLOW"

# Strip cloud bits if accidentally present (binaries + configs/hooks)
rm -rf "$OUT/usr/bin/iSC3S" "$OUT/usr/share/miio_client" \
  "$OUT/lib/libIOTCAPIs.so" "$OUT/lib/libAVAPIs.so" \
  "$OUT/lib/libpaho-mqtt3as.so.1" "$OUT/usr/bin/smbclient" \
  "$OUT/root/etc_default/miio" "$OUT/root/etc_default/miio_client" \
  "$OUT/etc/miio" "$OUT/etc/miio_client" \
  "$OUT/usr/bin/miio_client" "$OUT/usr/bin/miio_agent" \
  "$OUT/usr/bin/miot_"* 2>/dev/null || true
# Remove vendor cloud start hooks from default rc if present
if [[ -d "$OUT/root/etc_default/rc" ]]; then
  find "$OUT/root/etc_default/rc" -type f \( -iname '*miio*' -o -iname '*cloud*' -o -iname '*iSC3*' \) -delete 2>/dev/null || true
fi
if [[ -d "$OUT/etc/rc" ]]; then
  find "$OUT/etc/rc" -type f \( -iname '*miio*' -o -iname '*cloud*' -o -iname '*iSC3*' \) -delete 2>/dev/null || true
fi

# Overlay our scripts (cloud-free localcam)
mkdir -p "$OUT/usr/local/bin" "$OUT/usr/local/share" "$OUT/etc/localcam" "$OUT/etc/init.d"
cp -a "$ROOT/src/wifi/paths.sh" "$OUT/usr/local/bin/"
cp -a "$ROOT/src/wifi/wifi-manager.sh" "$OUT/usr/local/bin/"
cp -a "$ROOT/src/wifi/ap-firewall.sh" "$OUT/usr/local/bin/" 2>/dev/null || true
cp -a "$ROOT/src/web/portal" "$OUT/usr/local/share/localcam-portal"
cp -a "$ROOT/src/web/admin" "$OUT/usr/local/share/localcam-admin"
cp -a "$ROOT/src/web/portal/httpd.sh" "$OUT/usr/local/bin/"
cp -a "$ROOT/src/services/services.sh" "$OUT/usr/local/bin/" 2>/dev/null || true
cp -a "$ROOT/src/services/onvif-lite.sh" "$OUT/usr/local/bin/" 2>/dev/null || true
cp -a "$ROOT/src/record/recorder.sh" "$OUT/usr/local/bin/" 2>/dev/null || true
# ARMv5TE static WS-Discovery helper (Bootlin uClibc build)
if [[ -f "$ROOT/build/bin/wsd-lite.min" ]]; then
  cp -a "$ROOT/build/bin/wsd-lite.min" "$OUT/usr/local/bin/wsd-lite"
elif [[ -f "$ROOT/src/services/wsd-lite.armv5" ]]; then
  cp -a "$ROOT/src/services/wsd-lite.armv5" "$OUT/usr/local/bin/wsd-lite"
fi
cp -a "$ROOT/src/init/S10-localcam.sh" "$OUT/etc/init.d/" 2>/dev/null || true
chmod 755 "$OUT/usr/local/bin/"*.sh "$OUT/usr/local/bin/wsd-lite" "$OUT/etc/init.d/S10-localcam.sh" 2>/dev/null || true
# Stock defaults live under root/etc_default in cramfs extract
if [[ -d "$STOCK/root/etc_default" ]]; then
  mkdir -p "$OUT/etc"
  cp -a "$STOCK/root/etc_default/firmware" "$OUT/etc/" 2>/dev/null || true
  for f in fstab inittab profile mdev.conf; do
    cp -a "$STOCK/root/etc_default/$f" "$OUT/etc/$f" 2>/dev/null || true
  done
fi
# udhcpd is often BusyBox applet or usr/sbin
mkdir -p "$OUT/usr/sbin" "$OUT/usr/bin" "$OUT/sbin"
cp -a "$STOCK/usr/sbin/udhcpd" "$OUT/usr/sbin/udhcpd" 2>/dev/null || true

# Fanghacks binaries from SD archive (if present on build host)
FANG="${FANG:-$ROOT/sd-archive/data}"
if [[ -d "$FANG" ]]; then
  # Fang busybox provides httpd/dnsd applets (stock busybox lacks them)
  if [[ -f "$FANG/bin/busybox" ]]; then
    cp -a "$FANG/bin/busybox" "$OUT/bin/busybox-fh"
    ln -sf ../../bin/busybox-fh "$OUT/usr/sbin/httpd"
    ln -sf ../../bin/busybox-fh "$OUT/usr/sbin/dnsd"
  fi
  cp -a "$FANG/usr/bin/snx_rtsp_server" "$OUT/usr/bin/" 2>/dev/null || true
  cp -a "$FANG/usr/bin/fang-ir-control.sh" "$OUT/usr/bin/" 2>/dev/null || true
  cp -a "$FANG/sbin/dropbear" "$OUT/sbin/" 2>/dev/null || true
  mkdir -p "$OUT/usr/lib"
  cp -a "$FANG/usr/lib/." "$OUT/usr/lib/" 2>/dev/null || true
fi

# Size check uncompressed
UNCOMP=$(du -sb "$OUT" | awk '{print $1}')
echo "uncompressed_tree_bytes=$UNCOMP"

if command -v mkfs.cramfs >/dev/null; then
  mkfs.cramfs "$OUT" "$IMG"
  SZ=$(stat -c%s "$IMG")
  echo "cramfs_bytes=$SZ limit=$LIMIT"
  if (( SZ > LIMIT )); then
    echo "ERROR: image exceeds 7MiB rootfs partition" >&2
    exit 2
  fi
  sha256sum "$IMG" | tee "$ROOT/images/rootfs_localcam.cramfs.sha256"
else
  echo "mkfs.cramfs not installed — tree assembled at $OUT only"
fi
