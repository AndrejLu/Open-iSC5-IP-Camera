# uart-bridge — UDOO Curie receive-only camera UART

Receive-only Serial1→USB bridge on the UDOO X86 Arduino 101, plus a Python capture tool for Xiaomi/Hualai iSC5 boot logs.

- Sketch: `arduino/CameraUartRxBridge/`
- Capture: `capture/uart_capture.py`, `capture/run_capture.sh`
- Scripts: `scripts/grant_serial_access.sh`, `scripts/upload_bridge.sh`
- Docs: `docs/REPRODUCTION.md`, `docs/ANALYSIS.md`, `docs/HASHES.txt`
- Logs: `logs/boot_*.{bin,log,meta.json}`

See `docs/ANALYSIS.md` for findings from the first successful capture. A boot log is **not** a flash backup.
