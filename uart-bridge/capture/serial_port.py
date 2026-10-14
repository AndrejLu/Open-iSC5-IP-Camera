def default_serial_port() -> str:
    """Resolve the host serial device for the camera UART.

    Order:
      1. Explicit LOCALCAM_SERIAL env
      2. Common 3.3 V USB-UART chips (FTDI / CP210x / CH340 / etc.)
      3. UDOO Bolt CN25 UART0 (/dev/ttyS0) when present
      4. Legacy UDOO X86 Curie / Arduino 101 by-id (old host only)
    Skips Arduino Leonardo (5 V) which appears as ttyACM on UDOO Bolt.
    """
    import glob
    import os
    from pathlib import Path

    env = os.environ.get("LOCALCAM_SERIAL", "").strip()
    if env:
        return env

    ttl_patterns = [
        "/dev/serial/by-id/usb-FTDI_*-if00-port0",
        "/dev/serial/by-id/usb-Silicon_Labs_CP210*-if00-port0",
        "/dev/serial/by-id/usb-*CP210*-if00-port0",
        "/dev/serial/by-id/usb-*CH340*-if00-port0",
        "/dev/serial/by-id/usb-*CH341*-if00-port0",
        "/dev/serial/by-id/usb-*UART*-if00-port0",
        "/dev/serial/by-id/usb-*USB*_Serial*-if00-port0",
    ]
    for pat in ttl_patterns:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0]

    if Path("/dev/ttyS0").exists() and Path("/sys/class/dmi/id/board_name").is_file():
        try:
            board = Path("/sys/class/dmi/id/board_name").read_text(errors="replace").strip().lower()
        except OSError:
            board = ""
        if "bolt" in board or "udoo" in board:
            return "/dev/ttyS0"

    curie_patterns = [
        "/dev/serial/by-id/usb-UDOO_UDOO_X86__*-if00",
        "/dev/serial/by-id/usb-Intel_Arduino_101_*-if00",
    ]
    for pat in curie_patterns:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0]

    if Path("/dev/ttyS0").exists():
        return "/dev/ttyS0"

    return ""
