#!/bin/bash
# Cross-build v4l2-jpeg for SN98660 (ARMv5TE / ARM926EJ-S).
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
  -o "$OUT/v4l2-jpeg" "$ROOT/src/services/v4l2-jpeg.c"
cp -a "$OUT/v4l2-jpeg" "$ROOT/overlay/sd_test/localcam/bin/v4l2-jpeg"
cp -a "$OUT/v4l2-jpeg" "$ROOT/src/services/v4l2-jpeg.armv5"
file "$OUT/v4l2-jpeg"
ls -la "$OUT/v4l2-jpeg"
