# Hardware test log

## Environment
- Host: UDOO X86, serial bridge `/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00`
- Camera: iSC5 FW 3.0.3.56 + fanghacks SD
- Date: 2026-10-12

## Wi-Fi AP / portal (SD overlay `localcam`)
| Test | Result | Evidence |
|------|--------|----------|
| Open AP starts | **PASS** | `ESSID:"Camera-<MAC6>"`, `Encryption key:off`, Mode:Master |
| AP IP 192.168.4.1 | **PASS** | `ifconfig wlan0` |
| hostapd rtl871xdrv | **PASS** | hostapd.conf `driver=rtl871xdrv` |
| udhcpd running | **PASS** | pidof includes udhcpd |
| Portal index.html | **PASS** | `wget http://192.168.4.1/` returns local HTML |
| `/cgi-bin/status` JSON | **PASS** | after fixing httpd.conf auth |
| `/cgi-bin/scan` networks | **PASS** | saw FRITZ!Box, T-2, ZZ1, HP DIRECT |
| Phone captive portal | **NEED USER** | UDOO has no Wi-Fi NIC |
| Bad/good PSK connect | **PENDING** | needs phone or STA credentials |
| 90s fallback | **PENDING** | logic in wifi-manager; not timed yet |

## RTSP (without iSC3S)
| Test | Result | Evidence |
|------|--------|----------|
| Stop iSC3S + start `snx_rtsp_server` | **PASS** | pid listening `:554` |
| URL advertised | **PASS** | `rtsp://0.0.0.0/unicast` @ 1920x1080 |
| Needs `/etc/rc` | **PASS** | copy from `/root/etc_default/rc` |
| 720p crop path | **FAIL** | segfault — use 1080p for now |
| Decode on UDOO | **BLOCKED** | UDOO has no Wi-Fi; need STA or phone |

## Other
| Test | Result |
|------|--------|
| Live `/proc/mtd` matches expected | **PASS** |
| Flash backup SHA-256 | **PASS** `5339528331f1c80c378c02e00290d68e799cb13da421a1a2a92ca29b45c979bb` |
| SD fang archives pulled | **PASS** `fh_boot.tar` + `fh_data.tar` |
| Draft cramfs ≤ 7 MiB | **PASS** ~2.4 MiB (incomplete fang merge) |
| ONVIF | scaffold only |
| Internal flash install | **BLOCKED** — approval gate |

## Listening ports (AP + RTSP test, after soft isolation)
80 (portal), 554 (snx_rtsp), 22 (stock dropbear still). Telnet/FTP stopped. No iptables — full AP isolation deferred.
