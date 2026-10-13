# Localcam firmware (iSC5 / SN98660)

Cloud-free camera userspace for Xiaomi/Hualai iSC5. Keeps stock U-Boot, kernel, modules, and SONiX ISP stack; replaces vendor cloud apps.

## Layout
- `src/wifi/` — AP/STA manager (`rtl871xdrv` hostapd), AP firewall
- `src/web/portal/` — open-hotspot captive setup UI + BusyBox httpd CGI
- `src/web/admin/` — post-setup admin UI (scaffold)
- `src/services/` — RTSP/SSH starters
- `overlay/sd_test/` — SD-deployable test package
- `build/` — allowlist + cramfs assemble
- `images/` — built artifacts + SHA-256
- `sd-archive/` — fanghacks SD backups (local; not for git secrets)
- `docs/` — architecture, budget, GPIO, tests, recovery

## SD test (current)
On camera (fanghacks SD already mounted):

```sh
cd /media/mmcblk0p2/data
# after overlay extract:
sh localcam/bin/localcam-ap-test.sh
```

Open AP: **`Camera-<MAC6>`** (this unit: `Camera-<MAC6>`), no password, portal `http://192.168.4.1/`.

## Build rootfs tree
```sh
STOCK=/tmp/isc5_rootfs ./build/assemble_rootfs.sh
```
Produces `images/rootfs_localcam.cramfs` if `mkfs.cramfs` exists. Must be ≤ 7 MiB.

## Flash policy
No internal flash writes without an explicit approval package (paths, hashes, tests, recovery). Bootloader/rescue/userconfig are not routine install targets.
