# Dependency inventory (iSC5 / SN98660)

## Confirmed hardware
| Item | Value |
|------|-------|
| SoC | SONiX SN98660AFG ARMv5TEJ |
| RAM | 64 MiB (~36 MiB Linux) |
| Flash | 16 MiB SPI NOR |
| Sensor | SC2135 (`/etc/firmware/sc2135/IQ.bin`) |
| Wi-Fi | RTL8188ETV / `8188eu.ko` |
| Kernel | 2.6.35.12 |
| Rootfs | cramfs (mtd2 7 MiB) |
| /etc | JFFS2 (mtd4 1 MiB) |
| MAC (example unit) | last 6 hex digits form AP SSID `Camera-<MAC6>` |

## MTD (live `/proc/mtd` verified)
| Dev | Size | Name |
|-----|------|------|
| mtd0 | 0x0C0000 | uboot |
| mtd1 | 0x300000 | kernel |
| mtd2 | 0x700000 | rootfs |
| mtd3 | 0x400000 | rescue |
| mtd4 | 0x100000 | etc |
| mtd5 | 0x040000 | userconfig |

## Wi-Fi userspace (stock + fanghacks)
| Binary | Path | Notes |
|--------|------|-------|
| hostapd | `/sbin/hostapd` | **requires `driver=rtl871xdrv`** |
| wpa_supplicant | `/sbin/wpa_supplicant` | + `wpa_cli` |
| udhcpd | `/usr/sbin/udhcpd` | BusyBox |
| udhcpc | BusyBox | client DHCP |
| httpd | fang `/media/.../usr/sbin/httpd` | BusyBox httpd (not in stock busybox) |
| dnsd | fang `usr/sbin/dnsd` | captive DNS candidate |

## Video / audio (retain)
| Item | Path / note |
|------|-------------|
| Modules | `snx_isp`, `snx_vc`, `snx_vb2`, `snx_gpio`, `snx_i2s_gpio`, `snx_sd`, audio codecs |
| Libs | `libsnx_isp.so`, `libsnx_vc.so`, `libsnx_rc.so`, `libsnx_audio*.so`, `libgpio.so`, `libnvram.so` |
| RTSP | fanghacks `snx_rtsp_server` — `snx_rtsp_server -W 1920 -H 1080 -Q 10 -b 4096 -a` |
| IQ | `/etc/firmware/sc2135/IQ.bin`, `sensor.list` |
| Sensor power | `gpio_ms1 -n 6 -m 1 -v 1` (from stock `rcS`) |

## GPIO tools (wiring TBD by live probe)
| Tool | Pins |
|------|------|
| `gpio_led` | 0:pwm2 1:pwm1 2:GPIO[2] 3:GPIO[3] 4:pwm3 |
| `gpio_ms1` | 1–14 except 8,9,10; sensor uses **6** |
| IR | fang `fang-ir-control.sh` + script `21-ir-control` |

## Remove from normal rootfs (cloud / bulk)
| Item | Approx size | Reason |
|------|-------------|--------|
| `usr/bin/iSC3S/` | ~636 KiB | vendor camera/cloud |
| `miio_client` + helpers | ~104 KiB+ | pairing/cloud |
| `libIOTCAPIs.so` / `libAVAPIs.so` | ~192 KiB | TUTK |
| `libpaho-mqtt3as.so.1` | ~100 KiB | MQTT telemetry |
| `smbclient` | ~487 KiB | unused bulk |
| curl/ssl/crypto | large | only if nothing retained needs them |

## Flash budget (mtd2 ≤ 7168 KiB cramfs)
Uncompressed stock extract ≈ 15 MiB (includes modules ~1.8 MiB, 8188eu alone ~1.2 MiB).
Cramfs typically compresses well; target allowlist must still leave margin.
Writable config stays on **mtd4 /etc** (localcam under `/etc/localcam`).

## libc / ABI
- Interpreter: `/lib/ld-uClibc.so.0`
- Soft-float EABI5 ARMv5 — do not drop glibc/modern armhf binaries onto the device.
