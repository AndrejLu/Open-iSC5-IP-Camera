# LocalCam for iSC5

Local camera firmware and tooling for the Xiaomi / Hualai **iSC5** (SONiX SN98660), aimed at **web administration, RTSP, ONVIF, SSH, Wi‑Fi provisioning, and optional SD recording** without manufacturer cloud apps in normal operation.

This repository is a **development prototype**. The working path today is an **SD-card overlay** (fanghacks-style) plus host-side helpers on a Linux PC (verified on an UDOO x86). **Internal-flash installation is unfinished.** Do not treat this as a finished cloud-free production firmware.

## Verified hardware

| Item | Value |
|------|--------|
| Camera | Xiaomi / Hualai **iSC5** |
| SoC | SONiX **SN98660** (ARMv5TE / ARM926EJ-S) |
| RAM / flash | 64 MiB RAM · 16 MiB SPI NOR |
| Sensor | SC2135 |
| Wi‑Fi | RTL8188ETV (`8188eu.ko`) |
| Kernel (stock) | 2.6.35.12 |
| Rootfs / config | cramfs (mtd2 ≤ 7 MiB) · JFFS2 `/etc` (mtd4) |

**Compatibility:** only the iSC5 unit described in `firmware/docs/` has been exercised. Other Hualai/Xiaomi SONiX cameras may share pieces of the stack; they are **unverified**. Stock U-Boot, kernel, modules, and SONiX ISP/VC binaries are retained from the device — this project does **not** redistribute manufacturer firmware images.

## Current status (honest)

| Area | Status |
|------|--------|
| Open setup hotspot + captive portal | **Implemented** (SD-tested) |
| Save network / STA + DHCP or static IP | **Implemented** |
| Fallback AP after failed STA | **Implemented** (short timeouts tested; full 90 s soak / phone captive UX **not fully validated**) |
| Admin web UI (login, Wi‑Fi, network, services, MJPEG preview) | **Implemented** (SD-tested) |
| RTSP H.264 via stock `snx_rtsp_server` | **Verified** (UDP preferred; TCP interleaved unreliable on this LIVE555 build) |
| Lightweight ONVIF HTTP + unicast WS-Discovery | **Implemented**; **no** UsernameToken auth; multicast discovery unreliable from host probes |
| SSH (Dropbear on fanghacks SD) | **Used for development** |
| Optional SD recording | **Host-assisted only** (see below) |
| Autonomous on-camera recording | **Not implemented** (camera cannot usefully ingest its own RTSP UDP loopback; avoid wedging the SoC with on-device ffmpeg experiments) |
| Internal flash install / full cloud removal image | **Unfinished** (draft cramfs assemble exists; **no approved flash**) |
| Stock rescue / U-Boot alt-boot recovery | **Unvalidated** |

Cloud apps (`iSC3S`, miio, TUTK) are **not started** by the LocalCam SD overlay in normal STA operation, but a complete audited flash image that permanently removes them is **not** claimed.

## What runs where

### On the camera (SD overlay under `firmware/overlay/sd_test/localcam/`)

- `wifi-manager.sh` — setup AP / STA / fallback
- BusyBox `httpd` portal (AP) and admin UI (STA)
- `services.sh` — RTSP, ONVIF CGI httpd, WS-Discovery helper, recorder watch mode
- Stock / fang binaries obtained **from the device or fanghacks SD** (not shipped here as blobs): `snx_rtsp_server`, `hostapd` (`driver=rtl871xdrv`), `wpa_supplicant`, Dropbear, BusyBox httpd, etc.

### On the development host (UDOO / Linux PC)

- Serial UART bridge (`uart-bridge/`) for boot logs and recovery shell (USB-TTL 3.3 V on UDOO Bolt; Curie bridge was UDOO X86-only)
- Python helpers (`firmware/scripts/`) for SSH deploy, serial file push/pull, **host recorder**
- Optional cross toolchain (Bootlin ARMv5 EABI uClibc) to build `wsd-lite` and experimental RTSP helpers
- Host `ffmpeg` (system or a local static build under `firmware/tools/`, gitignored)

Host move notes (Bolt V8): see `docs/BOLT_MIGRATION.md`.

## Service ports (placeholders)

Replace `<CAMERA_IP>` with the camera’s LAN address after STA join.

| Service | URL / bind |
|---------|------------|
| Admin web | `http://<CAMERA_IP>/` |
| Setup portal (AP mode) | `http://192.168.4.1/` |
| RTSP H.264 | `rtsp://<CAMERA_IP>:554/unicast` |
| MJPEG preview RTSP | `rtsp://<CAMERA_IP>:8554/mjpeg` |
| ONVIF device service | `http://<CAMERA_IP>:8000/cgi-bin/device_service` |
| WS-Discovery | UDP `<CAMERA_IP>:3702` |
| SSH (fanghacks) | `ssh root@<CAMERA_IP>` |

Setup AP SSID form: `Camera-<last6-of-MAC>` (open / no PSK). Portal and AP addressing use `192.168.4.0/24`.

## Repository layout

```
README.md                 ← this file
.gitignore
firmware/
  src/                    ← LocalCam shell/CGI/C sources
  overlay/sd_test/        ← SD-deployable tree (scripts + web)
  build/                  ← allowlist, assemble + cross-build scripts
  scripts/                ← host Python/shell helpers
  docs/                   ← architecture, recovery, inventories, test notes
  images/                 ← manifests / hashes only (no firmware blobs)
uart-bridge/
  arduino/                ← Curie RX UART sketches
  capture/                ← Python serial capture / MTD transfer helpers
  scripts/                ← host udev / upload helpers
  docs/                   ← serial findings, reproduction, hash notes
```

## Dependencies (obtain separately)

See `firmware/docs/DEPENDENCY_INVENTORY.md` and `firmware/docs/LICENSE_INVENTORY.md`.

**Must come from your device / fanghacks SD / upstream projects — not redistributed here without verified rights:**

- Stock rootfs, kernel, modules, SONiX ISP/VC/audio libs, `snx_rtsp_server`, IQ binaries
- Realtek `8188eu.ko`, stock `hostapd` / `wpa_supplicant`
- Fanghacks BusyBox httpd, Dropbear, and related userspace (if you use that SD layout)

**Host tools:**

- Python 3 + `paramiko` (`firmware/scripts/requirements.txt`)
- `ffmpeg` for RTSP soak / host recorder
- Optional: Bootlin `armv5-eabi--uclibc--stable-2024.05-1` toolchain for ARMv5 helpers
- Optional: `arduino-cli` + Intel `arc32` core for the UDOO Curie bridge

Third-party licenses stay with their upstream projects. **This repository does not assign a license to manufacturer binaries** (they are not included). Project-authored code license: see root `LICENSE` once you choose one (currently unset — do not assume MIT/GPL).

## Host setup (development)

```bash
cd firmware
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements.txt
cp scripts/cam_creds.env.example private/cam_creds.env   # then edit; private/ is gitignored
# or: export LOCALCAM_HOST=… LOCALCAM_USER=root LOCALCAM_PASS=…
```

Serial (UDOO Curie receive-only bridge):

```bash
# Wire: camera GND→GND, camera TX→Arduino D0/RX; camera RX left disconnected
./uart-bridge/scripts/grant_serial_access.sh
# Build/flash sketch per uart-bridge/docs/REPRODUCTION.md
# Capture: uart-bridge/capture/run_capture.sh
```

Cross-build WS-Discovery helper (optional):

```bash
# Install Bootlin ARMv5 EABI uClibc toolchain (see firmware/build/build_wsd.sh)
./firmware/build/build_wsd.sh
# Copies into overlay/sd_test/localcam/bin/wsd-lite
```

Draft rootfs assemble (needs a **local** stock rootfs extract; does not flash):

```bash
STOCK=/path/to/isc5_rootfs_extract ./firmware/build/assemble_rootfs.sh
```

## Camera deployment (SD overlay — verified path)

Assumes fanghacks-style SD already mounts and provides BusyBox httpd / Dropbear / `snx_rtsp_server`.

1. Sync `firmware/overlay/sd_test/localcam/` onto the SD data partition (e.g. under `/media/mmcblk0p2/data/localcam` — exact path depends on your card layout).
2. Build or copy `wsd-lite` into `localcam/bin/` if WS-Discovery is required.
3. Start (examples; adjust paths):

```sh
# on camera shell
sh /media/mmcblk0p2/data/localcam/bin/wifi-manager.sh start
sh /media/mmcblk0p2/data/localcam/bin/services.sh start
```

4. First-time Wi‑Fi: join open AP `Camera-<MAC6>`, open `http://192.168.4.1/`, select network.
5. After STA: admin at `http://<CAMERA_IP>/`, RTSP/ONVIF as in the port table.

**Host-assisted SD recording** (required today):

```bash
# Camera recorder in watch mode (services.sh / recorder.sh); then on the host:
firmware/.venv/bin/python firmware/scripts/host_recorder.py \
  -u "rtsp://<CAMERA_IP>:554/unicast" -t 20
```

The host pulls RTSP (UDP) and uploads `.ts` segments to the camera SD (FTP preferred, SSH uuencode fallback). Leaving this process running is what makes admin show “recording”.

## Wi‑Fi behaviour (implemented vs open)

| Behaviour | Notes |
|-----------|--------|
| No `wifi.conf` → open setup AP + portal | Implemented |
| Portal scan with signal % · save PSK · STA | Implemented |
| Bad PSK → timeout → fallback AP (conf preserved) | Implemented (lab timeouts) |
| Soft isolation on AP (stop RTSP/SSH/ONVIF; no iptables on device) | Implemented |
| LAN-loss detection (assoc + LAN IP; not Internet ping) | Implemented |
| Phone OS captive-portal UX | **Needs more real-phone testing** |
| Full 90 s soak + setup.lock matrix | **Not fully signed off** |

## Serial recovery (validated vs not)

**Validated:** interactive `root` shell over UART @ **115200 8N1** via the receive/TX bridge; read-only full-flash backup taken once (keep hashes private/local — see `firmware/docs/RECOVERY.md`). Fanghacks SD remains the primary recovery/development path.

**Not validated:** booting stock rescue (mtd3), U-Boot alternate RAM/SD boot, or any flash write procedure. **Do not write internal flash** without an explicit approval package (image paths, SHA-256, partitions, tests, recovery).

## Known limitations

- Prototype is **SD-tested**; flash install incomplete.
- Recorder is **not autonomous** on-camera.
- ONVIF is **unauthenticated**; NVR interoperability incomplete.
- RTSP has **no password** in the current `snx_rtsp_server` invocation.
- Manufacturer cloud removal is **operational** under LocalCam services, not a finished audited image.
- Generated ARMv5 binaries and stock extracts are **not** in git — build or copy locally.

## Roadmap (practical)

1. Harden boot so `wifi-manager` wins over stock WPA after power-cycle.
2. Phone captive-portal + 90 s fallback soak sign-off.
3. ONVIF UsernameToken + multicast discovery + one real NVR.
4. Durable host-recorder service (or true on-camera record if a safe path is found).
5. Complete allowlisted cramfs, cloud-removal audit, then **operator-approved** flash package only.

## Documentation map

- `firmware/docs/ARCHITECTURE.md` — design principles and service map  
- `firmware/docs/RECOVERY.md` — recovery status (what is / isn’t proven)  
- `firmware/docs/PROGRESS.md` / `TEST_LOG.md` / `RTSP_TEST_REPORT.md` — lab status  
- `firmware/docs/LICENSE_INVENTORY.md` / `DEPENDENCY_INVENTORY.md` — third-party / hardware notes  
- `uart-bridge/docs/REPRODUCTION.md` — serial bridge build & capture  

## License

Project-authored LocalCam / uart-bridge code is released under the **MIT License** (see root `LICENSE`).

Third-party and manufacturer components retain their original licenses; see `firmware/docs/LICENSE_INVENTORY.md`. Do not redistribute proprietary SONiX/Hualai/Xiaomi binaries from this tree (they are intentionally excluded).
