def default_serial_port() -> str:
    """First UDOO / Arduino 101 by-id ACM node, or empty string."""
    import glob
    patterns = [
        "/dev/serial/by-id/usb-UDOO_UDOO_X86__*-if00",
        "/dev/serial/by-id/usb-Intel_Arduino_101_*-if00",
    ]
    for pat in patterns:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0]
    return ""
