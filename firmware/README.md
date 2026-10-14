# LocalCam firmware sources (iSC5 / SN98660)

Cloud-oriented userspace replacement for Xiaomi/Hualai iSC5. Keeps stock U-Boot, kernel, modules, and SONiX ISP stack; replaces vendor cloud apps in **normal LocalCam operation** (SD overlay). See the repository root [README.md](../README.md) for status, ports, and host vs camera roles.

## Layout

- `src/wifi/` — AP/STA manager (`rtl871xdrv` hostapd), AP firewall
- `src/web/portal/` — open-hotspot captive setup UI + BusyBox httpd CGI
- `src/web/admin/` — post-setup admin UI
- `src/services/` — ONVIF lite, service orchestrator, WS-Discovery / experimental RTSP C sources
- `src/record/` — SD recorder (watch / host-assisted mode)
- `overlay/sd_test/` — SD-deployable test package
- `build/` — allowlist + cramfs assemble + cross-build scripts
- `scripts/` — host deploy / serial / host_recorder helpers
- `images/` — manifests and hashes (no firmware blobs in git)
- `docs/` — architecture, budget, GPIO, tests, recovery

## SD test (current)

On camera (fanghacks SD already mounted), after syncing the overlay:

```sh
sh /media/mmcblk0p2/data/localcam/bin/wifi-manager.sh start
sh /media/mmcblk0p2/data/localcam/bin/services.sh start
```

Open AP: **`Camera-<MAC6>`**, no password, portal `http://192.168.4.1/`.

## Build rootfs tree (draft — does not flash)

```sh
STOCK=/path/to/isc5_rootfs_extract ./build/assemble_rootfs.sh
```

Produces `images/rootfs_localcam.cramfs` if `mkfs.cramfs` exists. Must be ≤ 7 MiB. Stock extract must be supplied locally and is gitignored.

## Flash policy

No internal flash writes without an explicit approval package (paths, hashes, tests, recovery). Bootloader/rescue/userconfig are not routine install targets.
