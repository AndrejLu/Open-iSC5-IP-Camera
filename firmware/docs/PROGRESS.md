# Firmware progress checklist

## Milestone 0 — Inspect
- [x] Flash backup SHA-256 verified
- [x] Live `/proc/mtd` matches layout
- [x] Serial login; stock cramfs + jffs2 extracted
- [x] hostapd = **rtl871xdrv**; open AP proven
- [x] linuxrc erase-on-failed-/etc documented
- [x] Cloud apps identified (iSC3S, miio, TUTK)
- [x] IR GPIO from fang-ir-control (ms1 pin 2; gpio_aud day/night)
- [x] SD fanghacks **bootstrap** archive `sd-archive/fh_boot.tar`
- [x] SD fanghacks **data** archive `sd-archive/fh_data.tar` (excludes fb/test/flash dumps/recordings)
- [x] wlan0 used for AP test

## Milestone 1 — Inventory
- [x] Dependency inventory, GPIO/IR map, partition budget docs

## Milestone 2 — Build env
- [x] Script-first `firmware/src/` + allowlist assemble
- [x] `images/rootfs_localcam.cramfs` ~2.4 MiB (draft; fang bins not fully merged yet)
- [ ] Merge fang httpd/dnsd/dropbear/snx_rtsp into allowlisted image
- [ ] Button GPIO map

## Milestone 3 — Wi-Fi setup (SD-testable)
- [x] Open AP `Camera-<MAC6>`, DHCP, portal, `/cgi-bin/status` + `/cgi-bin/scan`
- [x] wifi-manager state machine (AP/STA/fallback scripts)
- [ ] Phone captive-portal + credential UX (**needs your phone** on `Camera-<MAC6>`)
- [ ] iptables isolation (no iptables on device — alternate needed)
- [ ] Timed 90s fallback / loss tests

## Milestone 4 — Local services
- [x] `snx_rtsp_server` runs @ 1920x1080, listens `:554`, URL `/unicast` (no iSC3S)
- [ ] RTSP decode on UDOO (**needs STA/phone path** — UDOO has no Wi-Fi)
- [ ] ONVIF scaffold present; client test pending
- [ ] Web admin post-setup
- [ ] SD recording

## Milestone 5 — Cloud-free image
- [x] Draft cramfs under budget + SHA-256
- [ ] Complete allowlist (IQ already included via etc_default)
- [ ] Recovery U-Boot path validated
- [ ] Install plan → **ask approval before any internal flash write**

## Blockers / need you
1. Join `Camera-<MAC6>` (open) on a phone and open `http://192.168.4.1/` — captive portal UX
2. Wi-Fi credentials (or complete portal flow) for STA + RTSP decode from UDOO/LAN
3. Optional: sudo to install extra host tools if assemble gaps appear
