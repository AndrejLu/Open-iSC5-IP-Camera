#!/bin/bash
# Cross-build wsd-lite for SN98660 (ARMv5TE / ARM926EJ-S).
# Requires Bootlin armv5-eabi uclibc toolchain (see docs).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC_ROOT="${TC_ROOT:-$HOME/tools/armv5-eabi--uclibc--stable-2024.05-1}"
GCC="$TC_ROOT/bin/arm-buildroot-linux-uclibcgnueabi-gcc"
OUT="$ROOT/build/bin"
mkdir -p "$OUT"
if [[ ! -x "$GCC" ]]; then
  echo "missing toolchain at $TC_ROOT" >&2
  echo "Download: https://toolchains.bootlin.com/downloads/releases/toolchains/armv5-eabi/tarballs/armv5-eabi--uclibc--stable-2024.05-1.tar.xz" >&2
  exit 1
fi
"$GCC" -O2 -static -march=armv5te -mtune=arm926ej-s \
  -o "$OUT/wsd-lite" "$ROOT/src/services/wsd-lite.c"
"$GCC" -Wl,-s -O2 -static -march=armv5te -mtune=arm926ej-s \
  -o "$OUT/wsd-lite.min" "$ROOT/src/services/wsd-lite.c"
cp -a "$OUT/wsd-lite.min" "$ROOT/overlay/sd_test/localcam/bin/wsd-lite"
cp -a "$OUT/wsd-lite.min" "$ROOT/src/services/wsd-lite.armv5"
file "$OUT/wsd-lite.min"
readelf -A "$OUT/wsd-lite.min" | head -n 8
ls -la "$OUT/wsd-lite.min"
