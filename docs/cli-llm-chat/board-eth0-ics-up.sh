#!/usr/bin/env bash
# Static USB-LAN for Windows ICS — keep under /userdata so app reflash does not wipe it.
# Typical board USB Ethernet: IFACE=eth2 (script default eth0 for older notes).
set -euo pipefail
IFACE="${IFACE:-eth0}"
ADDR="${ADDR:-192.168.137.2/24}"
GW="${GW:-192.168.137.1}"

# Drop the same ICS address from other ifaces so default route is not stolen by a linkdown NIC.
for n in /sys/class/net/*; do
	dev="${n##*/}"
	[ "$dev" = "$IFACE" ] && continue
	[ "$dev" = lo ] && continue
	ip addr del "$ADDR" dev "$dev" 2>/dev/null || true
done

ip link set "$IFACE" up
ip addr flush dev "$IFACE"
ip addr add "$ADDR" dev "$IFACE"
ip route replace default via "$GW" dev "$IFACE"
echo "nameserver $GW" > /etc/resolv.conf
ip -br a show "$IFACE"
ip r | head -5
