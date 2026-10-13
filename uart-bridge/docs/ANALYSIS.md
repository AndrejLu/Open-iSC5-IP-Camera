# iSC5 UART boot-log analysis

Capture: `logs/boot_20261012T170402Z` (180 s, 39397 bytes, 115200 8N1 via UDOO Curie RX bridge).

The file begins with ~787 bytes of already-running userspace Wi-Fi/ISP chatter, then a power-cycle and a full U-Boot → Linux boot. Analysis below uses the boot sequence starting at `U-Boot 2011.09`.

**This is not a flash backup.** It is a console transcript only.

## Observed facts

### U-Boot
- **Version:** U-Boot 2011.09 (Nov 24 2016 - 03:23:06)
- **DRAM:** 64 MiB
- **SPI FLASH:** 16 MB
- **MMC/SD at U-Boot:** “SD Card not detect”; `mmci_host_init error - -1`
- **Console:** serial in/out/err
- **Autoboot:** “Hit any key to stop autoboot: 0” (no interrupt)
- **Kernel image:** Legacy Image @ 0x00008000, name `Linux-2.6.35.12`, 3038112 bytes, load 0x00008000, entry 0x00008040

### Kernel
- **Version:** Linux 2.6.35.12
- **Build:** `(fedora@localhost.localdomain)` gcc 4.5.2 (SONiX GCC-4.5.2 Release 2011-12-06) `#27 Thu Dec 22 18:48:16 PST 2016`
- **CPU:** ARM926EJ-S `[41069265]` revision 5 (ARMv5TEJ)
- **Machine string:** `SONiX SN98600 Development Platform`
- **Memory:** 64MB total; ~36836k available / 28700k reserved at boot message
- **ISP carveout:** `0x00a00000` bytes reserved for ISP at `0x005ec000`
- **Root:** cramfs readonly on `mtdblock2` (`/dev/mtdblock2`), `init=/linuxrc`

### Boot arguments (verbatim)
```
console=ttyS0,115200 root=/dev/mtdblock2 init=/linuxrc mem=64M isp=10M vc=12M vo=0M mtdparts=snx-spi:768k(uboot),3072k(kernel),7168k(rootfs),4096k(rescue),1024k(etc),256k(userconfig)
```

### Flash / MTD layout (from cmdline + MTD create messages)
| Partition   | Size (cmdline) | Offset range (kernel)      |
|-------------|----------------|----------------------------|
| uboot       | 768k           | 0x000000–0x0c0000          |
| kernel      | 3072k          | 0x0c0000–0x3c0000          |
| rootfs      | 7168k          | 0x3c0000–0xac0000          |
| rescue      | 4096k          | 0xac0000–0xec0000          |
| etc         | 1024k          | 0xec0000–0xfc0000          |
| userconfig  | 256k           | 0xfc0000–0x1000000         |

Total 16 MiB — matches SPI FLASH and the GD25Q127 (16 MiB) on the board.

### Sensor / ISP / encoder
- **Sensor:** `scan:sc2135` then `sensor:sc2135 (id:0x2135) driver loadded` — **SC2135 is established for this unit**
- ISP: `snx_isp` probe/load; later fps/bps tweaks (e.g. 10→30 fps, bitrate 50k→400k→256k)
- Video: `snx_vc` registers `/dev/video1`, `/dev/video2`
- Capture paths observed: **1920×1080** and **640×360** (plus JPEG path)
- Audio: SNX audio / MIC unmute

### Wi-Fi
- Driver: `rtl8188eu v4.3.24_16705.20160509` (build Jan 19 2017)
- Chip: `CHIP_8188E` / `RTL8188E`, USB VID:PID `0x0BDA:0x0179`
- Interface `wlan0`, MAC **aa:bb:cc:dd:ee:ff**
- Scans for ESSID `TP-LINK_5EE504`; link often “not ready” / DHCP “No lease” during this capture window

### Watchdog
- `SNX Watchdog Timer` / `Sonix926 Watchdog Timer: timer margin 10 sec`
- Userspace: `Init WatchDog !!!!` with WDIOC_SETTIMEOUT / WDIOS_ENABLECARD / WDIOC_KEEPALIVE

### SD card / fang-hacks
- U-Boot: SD not detected
- Later: `snx_sd_initial ... SD initialisation done` (controller init; not proof of a mounted card)
- `/sys/block/mmcblk0/...` missing → no mmcblk0
- **fang-hacks path attempted but failed:**
  - `Starting boa webserver...`
  - `CGI scripts not found in /media/mmcblk0p1/bootstrap/www!`
  - `Failed to find hacks in /media/mmcblk0p2/data!`
  - `Failed to find /media/mmcblk0p2/data!`
- Conclusion: fang-hacks **hooks are present in the image**, but **no usable SD layout was mounted** during this boot (card absent, wrong partition layout, or not mounted in time).

### Vendor / app stack
- Firmware string: **`FIRM WARE VERSION : 3.0.3.56`** (also APPUP rootfs/release `3.0.3.56`)
- `Waiting for cloud apps...`, cloud domain `apicn.ismartalarm.com`
- TUTK/IOTC-related strings (`IOTC_Get_Version`, SDK path containing `P2P_TUTK`)
- `xiaomi_client_station 0`
- Boa webserver start (fang-hacks related; CGI missing without SD)
- **RTSP:** no explicit `rtsp` / `RTSP` service line in this log → **unknown** whether an RTSP daemon is running
- NVRAM: `[nvram_check:725] CRC error` then “SONIX Kernel NVRAM initialized”

### UART
- Console on **ttyS0 @ 115200** (matches capture settings)
- Second UART: `snx_uart.1` / `ttyS1` present

## Hypotheses (not proven by this log alone)
- Kernel “SN98600” vs package marking **SN98660AFG**: same SN986xx family; exact silicon marketing name vs boardfile string may differ — treat chip photo + this machine string as related, not contradictory without datasheet cross-check.
- fang-hacks was installed previously on flash (hooks run) but depends on SD content that was missing this boot.
- Cloud/P2P stack is the stock Xiaomi/Hualai path for 3.0.3.56.

## Unknowns
- Full flash contents / hashes (need dump, not UART)
- Whether RTSP/ONVIF already listen on the LAN
- SD partition scheme when a card is inserted
- Complete early DRAM/clock init before the first U-Boot banner (possible few lost bytes at power-on)

## Recommended next concrete step
1. **Insert a prepared microSD** with a known fang-hacks layout (`bootstrap` on p1, `data` on p2) so the observed hooks succeed (`/media/mmcblk0p2/data`, boa CGI).
2. Re-capture UART through the same bridge while booting with the SD present.
3. Once fang-hacks networking/SSH (or boa) is up, **dump the six MTD partitions** (`uboot`…`userconfig`) over the network to the UDOO and verify sizes/SHA-256 — that is the real working-camera backup before any custom userspace work.

Do **not** flash or factory-reset until those dumps exist.
