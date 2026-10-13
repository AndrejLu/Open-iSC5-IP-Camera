# Hardware test log

## Environment
- Host: UDOO X86, serial `/dev/serial/by-id/usb-UDOO_UDOO_X86__<BOARD_SERIAL>-if00`
- Camera: iSC5 + fanghacks SD (`mmcblk1` while seated)
- LAN: `192.168.1.50` on **<HOME_SSID>**
- Updated: 2026-10-13

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
| WS-Discovery UDP 3702 | **BLOCKED** | no Python on camera |
| Auth (WS-UsernameToken) | **NOT IMPLEMENTED** | open HTTP ONVIF |
| Real NVR client | **PENDING** | |

## Recording / flash
| Test | Result |
|------|--------|
| SD recorder script | **DEPLOYED** (needs arm ffmpeg for on-device segments; none present) |
| Internal flash install | **BLOCKED** — approval gate; candidate not complete |

## Original backup
SHA-256 `5339528331f1c80c378c02e00290d68e799cb13da421a1a2a92ca29b45c979bb` — unchanged.
