#!/bin/sh
### BEGIN INIT INFO
# Provides:       xiaozhi-ics
# Required-Start: $network
# Required-Stop:
# Default-Start:  S
# Default-Stop:
# Description:    Windows ICS static IP on USB-LAN → 192.168.137.2
### END INIT INFO
#
# Lives under /userdata/xiaozhi-cli/ so app reflash keeps the body.
# After app reflash, re-link:
#   ln -sfn /userdata/xiaozhi-cli/S42xiaozhi-ics.sh /etc/init.d/S42xiaozhi-ics
#
# IFACE auto-detect (override with IFACE=ethN): prefer iface already on
# 192.168.137.2, else eth0 with carrier, else eth2, else first eth* up.

ICS_UP="/userdata/xiaozhi-cli/board-eth0-ics-up.sh"
WAIT_SECS="${WAIT_SECS:-30}"

pick_ics_iface() {
	dev=""
	# Prefer iface already holding the ICS client address
	for n in /sys/class/net/*; do
		[ -e "$n" ] || continue
		dev="${n##*/}"
		[ "$dev" = lo ] && continue
		ip -4 -o addr show dev "$dev" 2>/dev/null | grep -q '192\.168\.137\.2' && {
			echo "$dev"
			return 0
		}
	done
	# Prefer eth0 when present and carrier is up (common USB-LAN rename)
	if [ -d /sys/class/net/eth0 ]; then
		c=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)
		[ "$c" = 1 ] && {
			echo eth0
			return 0
		}
	fi
	# Classic USB-LAN name on this board
	[ -d /sys/class/net/eth2 ] && {
		echo eth2
		return 0
	}
	# Any eth* with carrier
	for n in /sys/class/net/eth*; do
		[ -e "$n" ] || continue
		dev="${n##*/}"
		c=$(cat "$n/carrier" 2>/dev/null || echo 0)
		[ "$c" = 1 ] && {
			echo "$dev"
			return 0
		}
	done
	# Fallbacks while waiting for USB-LAN
	[ -d /sys/class/net/eth0 ] && {
		echo eth0
		return 0
	}
	echo eth2
	return 0
}

wait_iface() {
	i=0
	while [ "$i" -lt "$WAIT_SECS" ]; do
		IFACE=$(pick_ics_iface)
		if [ -d "/sys/class/net/$IFACE" ]; then
			# If carrier file exists, wait until link is up when possible
			if [ -f "/sys/class/net/$IFACE/carrier" ]; then
				c=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)
				[ "$c" = 1 ] && return 0
			else
				return 0
			fi
		fi
		i=$((i + 1))
		sleep 1
	done
	# Last chance: use whatever pick returns even without carrier
	IFACE=$(pick_ics_iface)
	if [ -d "/sys/class/net/$IFACE" ]; then
		echo "xiaozhi-ics: using $IFACE without carrier after ${WAIT_SECS}s" >&2
		return 0
	fi
	echo "xiaozhi-ics: no ICS iface after ${WAIT_SECS}s" >&2
	return 1
}

case "$1" in
	start|"")
		[ -x "$ICS_UP" ] || {
			echo "xiaozhi-ics: missing $ICS_UP" >&2
			exit 1
		}
		if [ -n "${IFACE:-}" ]; then
			# Explicit IFACE=… from caller — wait for that device only
			i=0
			while [ "$i" -lt "$WAIT_SECS" ]; do
				[ -d "/sys/class/net/$IFACE" ] && break
				i=$((i + 1))
				sleep 1
			done
			[ -d "/sys/class/net/$IFACE" ] || {
				echo "xiaozhi-ics: $IFACE not present after ${WAIT_SECS}s" >&2
				exit 1
			}
		else
			wait_iface || exit 1
		fi
		echo "Starting xiaozhi ICS on $IFACE..."
		IFACE="$IFACE" "$ICS_UP"
		;;
	stop)
		# Keep address; pair/chat may still use the link.
		;;
	restart|reload|force-reload)
		"$0" start
		;;
	*)
		echo "Usage: $0 {start|stop|restart}" >&2
		exit 3
		;;
esac

exit $?
