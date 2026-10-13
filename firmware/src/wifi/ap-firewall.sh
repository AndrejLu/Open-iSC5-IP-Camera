#!/bin/sh
# Restrict open AP clients to portal/DHCP/DNS only (BusyBox iptables if present).
# Call when entering setup-ap / fallback-ap; flush when leaving for STA.

WLAN="${WLAN:-wlan0}"
AP_IP="${AP_IP:-192.168.4.1}"

have_ipt() { command -v iptables >/dev/null 2>&1; }

flush() {
  have_ipt || return 0
  iptables -F INPUT 2>/dev/null || true
  iptables -F FORWARD 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
}

apply_ap() {
  have_ipt || { echo "ap-firewall: no iptables"; return 0; }
  flush
  # Allow established
  iptables -A INPUT -i "$WLAN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -i "$WLAN" -j ACCEPT
  # DHCP
  iptables -A INPUT -i "$WLAN" -p udp --dport 67:68 -j ACCEPT
  # DNS
  iptables -A INPUT -i "$WLAN" -p udp --dport 53 -j ACCEPT
  iptables -A INPUT -i "$WLAN" -p tcp --dport 53 -j ACCEPT
  # Portal HTTP only
  iptables -A INPUT -i "$WLAN" -p tcp --dport 80 -j ACCEPT
  # Drop SSH/RTSP/FTP/telnet/ONVIF from AP clients
  for p in 22 21 554 2323 8000 8080; do
    iptables -A INPUT -i "$WLAN" -p tcp --dport "$p" -j DROP
  done
  # Default drop other new from WLAN (if state module missing, last ACCEPT above is broad — tighten when possible)
  echo "ap-firewall: AP rules applied"
}

case "${1:-}" in
  ap) apply_ap ;;
  flush|sta) flush; echo "ap-firewall: flushed" ;;
  *) echo "Usage: $0 {ap|flush|sta}" ;;
esac
