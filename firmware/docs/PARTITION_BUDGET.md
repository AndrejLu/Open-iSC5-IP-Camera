# Partition & RAM budget

## Flash (16 MiB SPI NOR) — layout frozen for v1
| Partition | Offset | Size | Policy |
|-----------|--------|------|--------|
| uboot | 0x000000 | 768 KiB | **never write** in routine install |
| kernel | 0x0C0000 | 3072 KiB | retain stock 2.6.35.12 |
| rootfs | 0x3C0000 | **7168 KiB** | our cramfs only |
| rescue | 0xAC0000 | 4096 KiB | retain stock; **not sanitized** |
| etc | 0xEC0000 | 1024 KiB | JFFS2 settings (`/etc/localcam`) |
| userconfig | 0xFC0000 | 256 KiB | retain hardware identity/calibration |

## Rootfs (mtd2) targets
| Category | Keep? | Notes |
|----------|-------|-------|
| `/lib/ld-uClibc*`, `libc`, pthread, dl, m, gcc_s | yes | ABI |
| `libsnx_*`, `libgpio`, `libnvram`, alsa | yes | encode/ISP |
| `8188eu.ko` + snx_* modules used at boot | yes | ~1.8 MiB modules dir |
| `hostapd`, `wpa_supplicant`, busybox, udhcpd | yes | Wi-Fi |
| fang `httpd`, `dnsd`, `dropbear`, `snx_rtsp_server` | yes | copy into image |
| iSC3S, miio, TUTK, smbclient, gdbserver | **no** | reclaim space |
| openssl/curl | only if dropbear/RTSP need | audit before keep |

Hard limit: **cramfs image ≤ 7340032 bytes**. Build must fail if larger.

## /etc JFFS2 (1 MiB)
- `localcam/wifi.conf`, `admin.conf`, hostname, SSH keys, video prefs
- Do **not** copy stock `linuxrc` erase-on-failed-mount behavior

## RAM (~36 MiB Linux)
| Runtime | Budget sketch |
|---------|---------------|
| kernel + drivers | shared |
| hostapd or wpa | ~1–2 MiB |
| httpd + ash CGI | small |
| snx_rtsp_server | dominant with encoder |
| dropbear | small |
| recorder (optional) | write HW stream to SD; avoid transcode |

Leave headroom; measure with `free` under stream+record before flash.
