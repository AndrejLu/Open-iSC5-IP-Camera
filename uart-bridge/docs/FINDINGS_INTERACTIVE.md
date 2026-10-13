# Interactive UART session & flash backup — findings

Stamp: 2026-10-12 (session after full-duplex Curie bridge upload)

## Bridge & login
- Sketch: `arduino/CameraUartBridge` (USB Serial ↔ Serial1 @ 115200 8N1), uploaded via DFU alt7.
- Port: `/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00` (8087:0ab6, S/N <BOARD_SERIAL>).
- Login: **root / ismart12** succeeded.
- Confirmed: `uid=0(root) gid=0(root) groups=0(root),10(wheel)`
- `Linux iSmartAlarm 2.6.35.12 #27 Thu Dec 22 18:48:16 PST 2016 armv5tejl GNU/Linux`

## Hardware / OS (from live shell)
- CPU: ARM926EJ-S rev 5 (v5l); Hardware string: SONiX SN98600 Development Platform
- RAM: MemTotal **36956 kB** (~36 MiB usable of 64 MiB after ISP/VC carveouts)
- Root: cramfs readonly; `/etc` on jffs2 (`mtdblock4`)
- Firmware apps report **3.0.3.56**

## MTD mapping (confirmed before dump)
| Device | Name | Size |
|--------|------|------|
| mtdblock0 | uboot | 768 KiB |
| mtdblock1 | kernel | 3072 KiB |
| mtdblock2 | rootfs | 7168 KiB |
| mtdblock3 | rescue | 4096 KiB |
| mtdblock4 | etc | 1024 KiB |
| mtdblock5 | userconfig | 256 KiB |
| **Total** | | **16 MiB** |

## Network (at diagnostic time)
- `wlan0` UP, MAC AA:BB:CC:DD:EE:FF, **no IPv4 address**, empty routing table
- `wpa_supplicant` + `udhcpc -i wlan0` running but no lease
- Listening (fanghacks): **dropbear :22**, **boa :80**, **snx_rtsp_server :554**, telnetd :2323, ftp :21
- No usable host network path for backup → serial transfer used

## Fanghacks / services
- SD: mmcblk0p1 vfat (~98 MiB), mmcblk0p2 ext2 (~145 MiB, ~85 MiB free) — writable
- Scripts under `/media/mmcblk0p2/data/etc/scripts/` (00-stop-cloud, 01-network, 11-dropbear, 20-rtsp-server, …)
- RTSP: `snx_rtsp_server -W 1920 -H 1080 -Q 10 -b 4096 -a`
- Modules: `sc2135`, `snx_isp`, `snx_vc`, `8188eu`, watchdog present

## Backup status
- Camera-side dump dir: `/media/mmcblk0p2/data/fb/{0..5}.bin`
- All six sizes exact; **etc** and **userconfig** double-read MD5 matched
- Host assembly path: `uart-bridge/backups/flash_20261012T184535Z/`
- Transfer: paced hexdump lines over serial (no raw binary); in progress / see MANIFEST.json

## Camera-side MD5 (authoritative pre-transfer)
| Part | MD5 |
|------|-----|
| uboot | da8e146b122a2f2b55ab4d0cf51ec20c |
| kernel | 1a7a8a614f53ca075d42d1afd5520825 |
| rootfs | f4c5198480ae5059ef5b3cd19a778adb |
| rescue | fec6577cc1c2049ec0ce22dfd170c8f6 |
| etc | eeb70e970745fe739337bb43f78d1220 |
| userconfig | 4b5c1bcf9ada33085edb2464467698e7 |

## Next concrete step (after host verify)
1. Fix Wi-Fi association (credentials / fanghacks `01-network`) so SSH is reachable on LAN.
2. Prefer network `scp`/`nc` for future dumps; keep this 16 MiB image as golden restore reference.
3. Unpack rootfs (cramfs) offline and map fanghacks hooks before designing cloud-free userspace on SD.

**Flash was not written.** Camera config was not persistently changed (temporary `wlan0 down` / printk quiet during transfer only).

## Backup complete (host-verified)
- Directory: `./uart-bridge/backups/flash_20261012T184535Z`
- Full image: `flash_full_16MiB.bin` (**16777216** bytes)
- Full MD5: `ed89a8bc2900a45bc12388e6762482c2`
- Full SHA-256: `5339528331f1c80c378c02e00290d68e799cb13da421a1a2a92ca29b45c979bb`
- All six partition host MD5s match camera-side MD5s; `etc`/`userconfig` double-reads matched on camera.
- Concatenation of partitions equals full image.
