# Hardware test log

## Environment
- Host: **UDOO Bolt V8** (`udoo-bolt`), serial **`/dev/ttyS0`** (CN25 UART0, 3.3 V) — see `docs/BOLT_MIGRATION.md`
- Camera: replacement iSC5 (prior unit UART RX failed) + same fanghacks SD (`mmcblk0`)
- MAC `34:CE:00:D3:85:7D` · LAN `192.168.187.215` on **GC DPI** (DHCP)
- Updated: 2026-10-15 (Bolt bring-up)

### Prior lab (UDOO X86)
- Host: UDOO X86, serial `/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00`
- Camera: original iSC5 + fanghacks SD
- LAN: `192.168.1.50` on **<HOME_SSID>**
- Dated: 2026-10-13

## Wi-Fi AP / portal / fallback
| Test | Result | Evidence |
|------|--------|----------|
| Open AP starts | **PASS** | `Camera-<MAC6>`, Encryption key:off |
| AP IP 192.168.4.1 | **PASS** | hostapd + ifconfig |
| Portal + scan w/ signal % | **PASS** | `/cgi-bin/scan` JSON `signal` / `signal_pct` |
| No saved wifi.conf → setup-ap immediately | **PASS** | `m4_wifi_noconf.txt` state=`setup-ap` |
| Bad PSK → timeout → fallback-ap | **PASS** | `STA_TIMEOUT=25`, state=`fallback-ap`; conf preserved |
| Restore good conf → station | **PASS** | IP `192.168.1.50` |
| Internet-only outage → no fallback | **PASS (design)** | monitor uses `sta_lan_ok` only (assoc+LAN IP), not public ping |
| Soft AP isolation (no iptables) | **PASS** | AP mode kills RTSP/SSH/ONVIF; open AP |
| Phone captive portal UX | **NEED USER** | Connect phone to `Camera-<MAC6>`, open portal |
| iptables AP firewall | **N/A** | no iptables on device |

## RTSP
| Test | Result | Evidence |
|------|--------|----------|
| URL | **PASS** | `rtsp://192.168.1.50:554/unicast` auth=none |
| Codec / size / fps | **PASS** | H.264 1920×1080 ~25 fps; G.711A 8 kHz mono |
| Decode + 10 s clip | **PASS** | `private/rtsp_tests/clip_10s.mkv` |
| 10 min soak decode | **PASS** | 14337 frames / 600 s; exit 0; VmRSS stable |
| TCP interleaved RTSP | **FAIL/hang** | prefer UDP on this LIVE555 build |
| Report | | `docs/RTSP_TEST_REPORT.md` |

## Admin / persistence
| Test | Result | Notes |
|------|--------|-------|
| Admin CGI + UI | **DEPLOYED** | login/logout/password/wifi CSRF |
| Admin hash label | **FIXED** | md5/sha256 labeled honestly |
| Dropbear keys in CFGDIR | **PARTIAL** | ecdsa key copied to p2 `localcam/etc/dropbear` + p1; verify across reboot still TODO |
| Flash /etc persistence | **NOT YET** | SD-tested only |

## ONVIF
| Test | Result | Notes |
|------|--------|-------|
| GetDeviceInformation | **PASS** | HTTP :8000 `/cgi-bin/device_service` |
| GetStreamUri | **PASS** | advertises `rtsp://192.168.1.50:554/unicast` |
| GetProfiles | **DEPLOYED** | SOAP keyword match |
| WS-Discovery UDP 3702 | **PASS (unicast)** | `wsd-lite` ARMv5TE static; zig musl v7 = Illegal instruction |
| WS-Discovery multicast | **FAIL/timeout** from UDOO probe (IGMP/path TBD) |
| Auth (WS-UsernameToken) | **NOT IMPLEMENTED** | open HTTP ONVIF |
| Real NVR client | **PENDING** | |

## Recording / flash
| Test | Result |
|------|--------|
| Host 30s H.264 copy clip | **PASS** | `private/recordings/seg_host_30s.mkv` |
| SD writable for recordings | **PASS** | `/media/mmcblk0p1/record/localcam` |
| On-device ffmpeg segments | **BLOCKED** | no arm ffmpeg on camera |
| Internal flash install | **BLOCKED** — approval gate; draft cramfs only |

## Ops notes
- SD may appear as `mmcblk0` or `mmcblk1` after reseat — `paths.sh` covers both.
- After AP tests, restart `services.sh` + `onvif-lite.sh` (SSH/RTSP stopped on AP).

## Original backup
SHA-256 `5339528331f1c80c378c02e00290d68e799cb13da421a1a2a92ca29b45c979bb` — unchanged.
