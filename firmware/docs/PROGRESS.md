# Firmware progress checklist

## Milestone 0 — Inspect
- [x] Flash backup SHA-256 verified
- [x] Live `/proc/mtd` matches layout
- [x] Serial login; stock cramfs + jffs2 extracted
- [x] hostapd = **rtl871xdrv**; open AP proven
- [x] Cloud apps identified (iSC3S, miio, TUTK)
- [x] SD fanghacks archives pulled

## Milestone 1 — Inventory
- [x] Dependency inventory, GPIO/IR map, partition budget docs

## Milestone 2 — Build env
- [x] Script-first `firmware/src/` + allowlist assemble
- [x] Draft cramfs under 7 MiB budget
- [ ] Complete fang binary merge into allowlisted image

## Milestone 3 — Wi-Fi setup (SD-testable)
- [x] Open AP + portal + scan with signal %
- [x] wifi-manager: no-conf→setup-ap; bad PSK→fallback; conf preserved
- [x] Soft isolation without iptables (stop RTSP/SSH/ONVIF on AP)
- [x] LAN-only loss detection (not Internet ping)
- [ ] Phone captive-portal UX (**needs your phone**)
- [ ] Full 90 s loss soak + setup.lock retry interaction matrix

## Milestone 4 — Local services
- [x] RTSP decode end-to-end + 10 min soak (`docs/RTSP_TEST_REPORT.md`)
- [x] Admin CGI/UI (login/logout/password/wifi + CSRF) deployed
- [x] ONVIF HTTP device/media + correct stream URI
- [x] ONVIF WS-Discovery unicast (`wsd-lite` ARMv5TE)
- [ ] ONVIF UsernameToken + multicast soak + NVR client
- [x] Host-side recording path validated; on-device ffmpeg still missing

## Milestone 5 — Cloud-free image
- [x] Draft cramfs under budget
- [ ] Complete allowlist, cloud removal audit, SHA-256 install package
- [ ] **Ask approval before any internal flash write**

## Git
- Checkpoint commit on `main` (secrets/backups/recordings untracked)
