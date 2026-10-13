#!/bin/sh
# Non-destructive GPIO read sweep for documentation (run on camera).
# Does not change outputs except temporary mode=input reads.

echo "=== gpio_led read (0-4) ==="
n=0
while [ "$n" -le 4 ]; do
  echo -n "led $n: "
  gpio_led -n "$n" -m 0 2>&1 || gpio_led -n "$n" -m 0 -v 0 2>&1
  n=$((n + 1))
done

echo "=== gpio_ms1 read (1-14 skip 8-10) ==="
n=1
while [ "$n" -le 14 ]; do
  case "$n" in 8|9|10) n=$((n + 1)); continue ;; esac
  echo -n "ms1 $n: "
  gpio_ms1 -n "$n" -m 0 2>&1
  n=$((n + 1))
done

echo "=== fang IR script ==="
ls -la /media/mmcblk0p2/data/usr/bin/fang-ir-control.sh 2>/dev/null
head -n 80 /media/mmcblk0p2/data/usr/bin/fang-ir-control.sh 2>/dev/null
