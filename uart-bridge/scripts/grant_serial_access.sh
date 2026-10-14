#!/usr/bin/env bash
# Host prep for Curie upload + UART capture. Needs your sudo password.
set -euo pipefail

USER_NAME="$(id -un)"
DFU_SCRIPT="${HOME}/.arduino15/packages/Intel/hardware/arc32/2.0.6/scripts/create_dfu_udev_rule"

# Prefer by-id path for UDOO / Arduino 101 CDC ACM; fall back to first match.
PORT_BY_ID=""
for cand in /dev/serial/by-id/usb-UDOO_UDOO_X86__*-if00 \
            /dev/serial/by-id/usb-Intel_Arduino_101_*-if00; do
  if [[ -e "$cand" ]]; then
    PORT_BY_ID="$cand"
    break
  fi
done

echo "==> Adding ${USER_NAME} to dialout (permanent after re-login)"
sudo usermod -aG dialout "$USER_NAME"

if [[ -x "$DFU_SCRIPT" ]]; then
  echo "==> Installing Arduino 101 DFU / ModemManager udev rules"
  sudo "$DFU_SCRIPT"
else
  echo "WARNING: DFU udev script not found at $DFU_SCRIPT"
  echo "==> Writing minimal udev rules"
  sudo tee /etc/udev/rules.d/99-arduino-101.rules >/dev/null <<'EOF'
# Arduino 101 / UDOO Curie
SUBSYSTEM=="tty", ENV{ID_REVISION}=="8087", ENV{ID_MODEL_ID}=="0ab6", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_CANDIDATE}="0"
SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0aba", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
EOF
  sudo udevadm control --reload-rules
  sudo udevadm trigger
fi

echo "==> Stopping ModemManager for this session (often grabs ttyACM)"
sudo systemctl stop ModemManager.service || true

grant_port() {
  local dev="$1"
  [[ -e "$dev" ]] || return 0
  echo "==> Granting rw on $dev"
  sudo setfacl -m "u:${USER_NAME}:rw" "$dev" 2>/dev/null || sudo chmod 666 "$dev"
}

if [[ -n "$PORT_BY_ID" ]]; then
  echo "==> Using serial port $PORT_BY_ID"
  grant_port "$(readlink -f "$PORT_BY_ID")"
else
  echo "WARNING: no UDOO/Arduino 101 by-id serial node found yet"
  for acm in /dev/ttyACM*; do
    [[ -e "$acm" ]] || continue
    grant_port "$acm"
  done
fi

echo
echo "Done."
if [[ -n "$PORT_BY_ID" ]]; then
  echo "Verify: python3 -c \"import serial; serial.Serial('$PORT_BY_ID'); print('OK')\""
fi
echo "Permanent dialout membership needs a new login; ACL/chmod is enough now."
