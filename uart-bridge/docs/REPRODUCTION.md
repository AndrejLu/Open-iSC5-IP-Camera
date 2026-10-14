# UART RX bridge — reproduction

## Host

- Machine class: UDOO X86 (Braswell + onboard Arduino 101 / Intel Curie) or similar Linux host with a Curie/Arduino 101 bridge
- OS: modern Ubuntu/Debian Linux x86_64
- User needs `dialout` and/or ACL on the ACM device; run `scripts/grant_serial_access.sh` once (sudo)

## Tool versions (as used in lab)

| Component | Version |
|-----------|---------|
| arduino-cli | 1.5.x |
| Board core | `Intel:arc32@2.0.6` (deprecated package, still installable) |
| FQBN | `Intel:arc32:arduino_101` |
| Python | 3.x |
| pyserial | 3.5+ |

Stable serial path (discover on your board):

```text
/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00
```

USB IDs commonly seen: runtime `8087:0ab6`, DFU `8087:0aba`.

## Wiring (receive-only)

- Camera GND → Arduino header GND
- Camera TX → Arduino **D0/RX** (Serial1)
- Camera RX disconnected
- Camera VCC disconnected (camera on its own USB supply)
- Logic: 3.3 V TTL

## Compile / upload

```bash
export PATH="$HOME/.local/bin:$PATH"
arduino-cli core install Intel:arc32
arduino-cli compile --fqbn Intel:arc32:arduino_101 \
  uart-bridge/arduino/CameraUartRxBridge
# upload via scripts/upload_bridge.sh or arduino-cli upload (Curie DFU / MASTER_RESET)
```

## Capture

```bash
./uart-bridge/scripts/grant_serial_access.sh
./uart-bridge/capture/run_capture.sh
```

See `ANALYSIS.md` / `FINDINGS_INTERACTIVE.md` for sanitized findings. A boot log is **not** a flash backup; keep dumps under local `backups/` (gitignored).
