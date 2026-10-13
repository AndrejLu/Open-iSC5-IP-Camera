# RTSP end-to-end test report

Date: 2026-10-13 (host local) · Camera: `192.168.1.50` · STA SSID: <HOME_SSID>

## Discovery

| Item | Result |
|------|--------|
| Process | `snx_rtsp_server -W 1920 -H 1080 -b 4096 -a` |
| Listen | `0.0.0.0:554` |
| URL | **`rtsp://192.168.1.50:554/unicast`** |
| Auth | **None** (DESCRIBE/OPTIONS 200 without credentials) |
| Video | H.264 High, **1920×1080**, ~**25 fps** |
| Audio | **G.711 A-law** (`pcm_alaw`), 8 kHz, mono (`-a` flag) |
| Stack | LIVE555 Streaming Media v2014.07.04 |

## Decode on UDOO

| Test | Result | Notes |
|------|--------|-------|
| ffprobe TCP | **PASS** | Streams detected |
| 10 s MKV clip (UDP, A/V) | **PASS** | `firmware/private/rtsp_tests/clip_10s.mkv` (~2.4 MiB) |
| 30 s null decode | **PASS** | ~731 frames ≈ 24.4 fps |
| **10 min** null decode (UDP) | **PASS** (exit 0) | ~24 fps sustained; process did not restart |
| Camera `VmRSS` over 10 min | **PASS** | ~2036→2168→1944 kB — no leak growth |
| H.264 concealment (UDP) | **Observed** | Packet-loss artifacts under UDP; stream continued |
| TCP interleaved decode | **FAIL** | ffmpeg hangs on TCP with this LIVE555 build — use UDP |

## Artifacts (private / not for git)

- Clip: `firmware/private/rtsp_tests/clip_10s.mkv`
- Logs: `firmware/progress/m4_rtsp_*`, `m4_rtsp_stable10m_*`
- Host ffmpeg: `firmware/tools/ffmpeg-7.0.2-amd64-static/` (gitignored)

## Conclusions

- Listening on :554 alone was insufficient; full DESCRIBE + decode + 10‑minute soak confirmed a working stream.
- No RTSP password on current `snx_rtsp_server` invocation — document for admin UI / ONVIF.
- Soft AP mode must stop RTSP (implemented in wifi-manager) because there is no iptables on device.
