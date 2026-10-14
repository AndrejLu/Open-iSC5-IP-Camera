#!/bin/bash
# Cross-build rtsp-h264 for SN98660 (ARMv5TE).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC_ROOT="${TC_ROOT:-$HOME/tools/armv5-eabi--uclibc--stable-2024.05-1}"
GCC="$TC_ROOT/bin/arm-buildroot-linux-uclibcgnueabi-gcc"
OUT="$ROOT/build/bin"
mkdir -p "$OUT"
[[ -x "$GCC" ]] || { echo "missing toolchain at $TC_ROOT" >&2; exit 1; }
"$GCC" -Wl,-s -O2 -static -march=armv5te -mtune=arm926ej-s \
  -o "$OUT/rtsp-h264" "$ROOT/src/services/rtsp-h264.c"
cp -a "$OUT/rtsp-h264" "$ROOT/overlay/sd_test/localcam/bin/rtsp-h264"
cp -a "$OUT/rtsp-h264" "$ROOT/src/services/rtsp-h264.armv5"
file "$OUT/rtsp-h264"
ls -la "$OUT/rtsp-h264"
