# Architecture — cloud-free iSC5 firmware

## Principles
- Keep stock **U-Boot**, **kernel 2.6.35.12**, **modules**, **uClibc**, **SONiX ISP/VC/audio**, **SC2135 IQ**.
- Replace vendor userspace (`iSC3S`, miio, TUTK) with our init + services.
- Development/test via **SD overlay** (fanghacks-style) before any internal flash write.
- Flash budget: rootfs ≤ **7168 KiB** cramfs; settings on **JFFS2 /etc** (1024 KiB).

## Runtime modes
1. **Setup AP** — open Wi-Fi `Camera-<suffix>`, captive portal only (192.168.4.1).
2. **Station** — `wpa_supplicant` + `udhcpc`/`static`; local services enabled.
3. **Fallback AP** — after 90s failed STA (or sustained loss); portal requires admin auth after first setup.

## Wi-Fi stack (observed)
- Driver: `8188eu.ko`
- AP: stock `/sbin/hostapd` with **`driver=rtl871xdrv`** (not nl80211)
- STA: `/sbin/wpa_supplicant` + `/sbin/iwconfig` / `iwlist`
- Single-radio: exclusive AP *or* STA; explicit mode transitions

## Service map (target)
| Service | Role | Bind |
|---------|------|------|
| `wifi-manager` | AP/STA/fallback state machine | scripts |
| `dnsmasq` or BusyBox dnsd+udhcpd | DHCP/DNS for AP | AP only |
| `portal` | Captive setup HTTP | :80 AP-only |
| `webadmin` | Authenticated admin UI | :80 STA / after auth |
| `snx_rtsp_server` (retained) | HW H.264 RTSP | :554 (+auth wrapper) |
| `onvif-lite` | Discovery + media profiles | :8000 |
| `dropbear` | SSH | :22 |
| `recorder` | Optional SD segments | filesystem |

## Security notes
- Open AP exposes **portal only** (iptables/owner checks).
- No default production password; first-boot sets admin password in portal.
- Never ship device tokens / Wi-Fi PSK in distributable images.

## Recovery (pre-flash requirement)
- Serial shell + verified dumps under `uart-bridge/backups/`
- Stock rescue partition retained but **not sanitized** yet
- Exact U-Boot alt-boot procedure: **TBD / unvalidated**
