# License inventory (draft)

| Component | Origin | License (claimed upstream) | Ship in image? |
|-----------|--------|---------------------------|----------------|
| Linux 2.6.35.12 | SONiX/vendor tree | GPLv2 | kernel partition (unchanged) |
| U-Boot | vendor | GPLv2 | uboot (unchanged) |
| busybox | fanghacks / stock | GPLv2 | yes |
| hostapd (rtl871xdrv build) | stock | BSD/GPL mix | yes |
| wpa_supplicant | stock | BSD | yes |
| dropbear | fanghacks | MIT | yes |
| snx_rtsp_server + libsnx_* | SONiX proprietary | proprietary — retain binary | yes |
| 8188eu.ko | Realtek/vendor | likely GPL | yes |
| iSC3S / miio / TUTK | Hualai/Xiaomi | proprietary | **no** |
| localcam scripts (this project) | project | TBD (document before release) | yes |

Pin exact upstream URLs/versions when cross-compiling anything new. Prefer reuse of on-device binaries to avoid ABI issues.
