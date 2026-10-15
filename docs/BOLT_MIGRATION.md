# Migrating LocalCam host to UDOO Bolt V8

## Checkout

```bash
mkdir -p ~/Documents/Code\ Projects
cd ~/Documents/Code\ Projects
git clone https://github.com/AndrejLu/Open-iSC5-IP-Camera.git
cd Open-iSC5-IP-Camera
```

## Host packages

```bash
sudo apt-get update
sudo apt-get install -y git curl wget build-essential python3 python3-venv python3-pip \
  ffmpeg netcat-openbsd nmap sharutils minicom screen socat ca-certificates jq
sudo usermod -aG dialout "$USER"   # re-login after
```

If `python3 -m venv` lacks ensurepip, use `pip install --user virtualenv` then `python3 -m virtualenv firmware/.venv`.

```bash
firmware/.venv/bin/pip install -r firmware/scripts/requirements.txt pyserial
mkdir -p firmware/private
cp firmware/scripts/cam_creds.env.example firmware/private/cam_creds.env
# edit LOCALCAM_HOST / LOCALCAM_PASS — never commit cam_creds.env
```

Place a static ffmpeg at `firmware/tools/ffmpeg-7.0.2-amd64-static/ffmpeg` or install system `ffmpeg` and adjust `host_recorder.py` candidates.

## Camera connectivity (this LAN)

**Current unit (2026-10-15):** replacement iSC5 (old camera UART RX failed).  
MAC `34:CE:00:D3:85:7D` · DHCP `192.168.187.215` on SSID `GC DPI` · fanghacks SD reused from previous unit · host UART **`/dev/ttyS0`** (CN25 UART0).

Update `LOCALCAM_HOST` in `firmware/private/cam_creds.env` if DHCP changes. Previous placeholder was `192.168.187.180`.

| Check | Expect |
|-------|--------|
| TCP 22 Dropbear | SSH `root@…` via `firmware/scripts/cam_ssh.py` |
| TCP 80 | Admin UI |
| TCP 554 | `rtsp://<ip>:554/unicast` (UDP preferred) |
| TCP 8554 | MJPEG RTSP `/mjpeg` |
| TCP 8000 | ONVIF |
| UDP 3702 | WS-Discovery (often unreliable from host) |
| Serial | `LOCALCAM_SERIAL=/dev/ttyS0` · 115200 8N1 |

Credentials: `firmware/private/cam_creds.env` (gitignored). Copy from the old host’s private tree — do not paste into chat.

Wi‑Fi config lives at `/media/mmcblk0p1/lc/etc/wifi.conf` (paths.sh prefers `p1/lc` over `p2/data/localcam`). Boot hook: `firmware/overlay/sd_test/fang_scripts/99-localcam` → SD `…/etc/scripts/99-localcam`.

## Serial on Bolt V8 (do not reuse Curie assumptions)

The old UDOO X86 used onboard Intel Curie as USB-UART. **That does not apply to Bolt.**

On Bolt:

- `/dev/ttyACM0` is the **Arduino Leonardo-compatible ATmega32U4** (CN24) — **5 V logic**. Do **not** wire the camera UART here.
- **CN25 Embedded Controller UART0** is the intended path: manual lists `EC_UART_RxD0` / `TxD0` at **+3.3V_DSW** ([Pinout Headers](https://www.udoo.org/docs-bolt/Hardware_References/Pinout_Headers.html), UDOO BOLT User Manual §3.3.13). Linux device: **`/dev/ttyS0`** (UART0 @ 0x3f8). UART1 is `/dev/ttyS1`.

### CN25 UART0 wiring (camera ↔ Bolt)

Header is on the **bottom** of the board (CN25). Leave RTS/CTS (pins 38/40) unconnected.

| Camera | Bolt CN25 |
|--------|-----------|
| TX | **Pin 34** `EC_UART_RxD0` (UART0 RX) |
| RX | **Pin 36** `EC_UART_TxD0` (UART0 TX) |
| GND | **Pin 29 or 31** `GND` |
| VCC | leave disconnected (power camera through its normal supply) |

Settings: **115200 8N1**. Permissions: `sudo usermod -aG dialout "$USER"` then re-login (not world-writable `chmod 666`). Only one process may open the port.

```bash
export LOCALCAM_SERIAL=/dev/ttyS0
# then e.g. firmware/.venv/bin/python uart-bridge/capture/uart_capture.py …
```

Alternate: USB-to-TTL **3.3 V** adapter if CN25 is inconvenient; set `LOCALCAM_SERIAL` to that `/dev/serial/by-id/…` path.

## Private assets (gitignored)

Copy from old checkout `/home/andrejl/Documents/Code Projects/Cursor/iSC5IPCamera/` into `~/localcam-private/` or repo `firmware/private/` / `uart-bridge/backups/`:

- Flash backups + manifests under `uart-bridge/backups/` (verify SHA-256 `5339528331f1c80c378c02e00290d68e799cb13da421a1a2a92ca29b45c979bb` for the 16 MiB image)
- `firmware/private/cam_creds.env` and any recovery notes
- `firmware/stock/`, `firmware/tools/`, SDKs, uncommitted work

Do not delete anything on the old machine.

## Host recorder handover

Recording is **host-assisted**: one Linux host runs `host_recorder.py`, pulls RTSP, uploads `.ts` to the camera SD.

1. Prepare Bolt config + venv (do not start recorder yet).
2. On the **old** host, stop the recorder (`systemctl --user stop …`, kill the python process, or disable the unit).
3. Confirm no old writer remains.
4. Start on Bolt: `firmware/.venv/bin/python firmware/scripts/host_recorder.py -u rtsp://<CAMERA_IP>:554/unicast -t 20`
5. Optional: install `firmware/scripts/systemd/localcam-host-recorder.service.example` as a user unit.

Do not format the SD or run destructive cleanup during migration.

## What agent sessions on Bolt cannot do alone

- Cannot `sudo` when the process has “no new privileges”.
- Old UDOO must expose SSH before private assets can be pulled automatically.
