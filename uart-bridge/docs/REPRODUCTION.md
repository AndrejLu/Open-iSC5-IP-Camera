# UART RX bridge — reproduction

## Host
- Machine: UDOO X86 (Braswell + onboard Arduino 101 / Intel Curie)
- OS: Ubuntu 26.04.1 LTS (`resolute`), Linux `7.0.0-38-generic` x86_64
- User needs `dialout` and/or ACL on the ACM device; run `scripts/grant_serial_access.sh` once (sudo)

## Tool versions (as used)
| Component | Version |
|-----------|---------|
| arduino-cli | 1.5.1 (`01f3d4f2b`, 2026-06-05) |
| Board core | `Intel:arc32@2.0.6` (deprecated package, still installable) |
| FQBN | `Intel:arc32:arduino_101` |
| arc-elf32 | 1.6.9+1.0.1 |
| arduino101load | 2.3.0 |
| dfu-util (Arduino package) | 0.9.0-arduino1 |
| Python | 3.14.4 |
| pyserial | 3.5 (`python3-serial`) |

Stable serial path:
```
/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00
```
USB IDs: runtime `8087:0ab6`, DFU `8087:0aba`, serial `<BOARD_SERIAL>`.

## Wiring (receive-only)
- Camera GND → Arduino header GND
- Camera TX → Arduino **D0/RX** (Serial1)
- Camera RX disconnected
- Camera VCC disconnected (camera on its own USB supply)
- Logic: 3.3 V TTL

## Compile
```bash
export PATH="$HOME/.local/bin:$PATH"
arduino-cli core install Intel:arc32
arduino-cli compile --fqbn Intel:arc32:arduino_101 \
  "uart-bridge/arduino/CameraUartRxBridge"
```

## Upload (UDOO-specific)
Stock `arduino-cli upload` races the short DFU window on this board. Use:
```bash
bash uart-bridge/scripts/upload_bridge.sh
```
This does: 1200 bps touch → wait for `8087:0aba` → `dfu-util -a 7` (sensor_core) with the compiled `.bin`.

If needed: press **MASTER_RESET** while DFU is expected.

## Capture
```bash
# default 115200, 180 s
bash uart-bridge/capture/run_capture.sh

# or directly
uart-bridge/venv/bin/python3 uart-bridge/capture/uart_capture.py \
  --port /dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00 \
  --baud 115200 --duration 180
```
Then power-cycle **only the camera**.

Outputs under `uart-bridge/logs/`:
- `boot_<UTC>.bin` — exact bytes
- `boot_<UTC>.log` — same bytes decoded for reading
- `boot_<UTC>.meta.json` — metadata + SHA-256

## Sketch behaviour
`CameraUartRxBridge.ino`: Serial1 @ 115200 → Serial (USB); never TX to camera; batch forward; no banners on the byte stream.
