#!/bin/bash
# Cross-build rtsp-jpeg for SN98660 (ARMv5TE / ARM926EJ-S).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC_ROOT="${TC_ROOT:-$HOME/tools/armv5-eabi--uclibc--stable-2024.05-1}"
GCC="$TC_ROOT/bin/arm-buildroot-linux-uclibcgnueabi-gcc"
OUT="$ROOT/build/bin"
mkdir -p "$OUT"
if [[ ! -x "$GCC" ]]; then
  echo "missing toolchain at $TC_ROOT" >&2
  exit 1
fi
"$GCC" -Wl,-s -O2 -static -march=armv5te -mtune=arm926ej-s \
  -o "$OUT/rtsp-jpeg" "$ROOT/src/services/rtsp-jpeg.c"
cp -a "$OUT/rtsp-jpeg" "$ROOT/overlay/sd_test/localcam/bin/rtsp-jpeg"
cp -a "$OUT/rtsp-jpeg" "$ROOT/src/services/rtsp-jpeg.armv5"
file "$OUT/rtsp-jpeg"
ls -la "$OUT/rtsp-jpeg"
