#!/bin/sh
### BEGIN INIT INFO
# Provides:       xiaozhi-audio
# Required-Start: $local_fs
# Required-Stop:
# Default-Start:  S
# Default-Stop:
# Description:    Force ES8388 HP + mic mixer for CON24 (xiaozhi-cli)
### END INIT INFO
#
# Lives under /userdata/xiaozhi-cli/ so app/boot reflash of rootfs does not
# wipe the body. After app reflash, re-link:
#   ln -sfn /userdata/xiaozhi-cli/S43xiaozhi-audio.sh /etc/init.d/S43xiaozhi-audio
#
# Smoke without reboot:
#   /etc/init.d/S43xiaozhi-audio start

AUDIO_UP="/userdata/xiaozhi-cli/board-audio-up.sh"
LOG="/userdata/xiaozhi-cli/audio-up.log"

case "$1" in
start)
	if [ ! -x "$AUDIO_UP" ]; then
		echo "S43xiaozhi-audio: missing $AUDIO_UP" >&2
		exit 1
	fi
	# Sound card may appear slightly after local_fs; brief retry.
	i=0
	while [ "$i" -lt 15 ]; do
		if [ -d /proc/asound/card0 ] || [ -e /dev/snd/controlC0 ]; then
			break
		fi
		i=$((i + 1))
		sleep 1
	done
	AUDIO_UP_QUIET=0 "$AUDIO_UP" >"$LOG" 2>&1 || true
	echo "S43xiaozhi-audio: applied (log $LOG)"
	;;
stop)
	# Nothing to tear down — mixer state is sticky.
	;;
restart|reload)
	"$0" start
	;;
status)
	amixer -c 0 sget "hp switch" 2>/dev/null | sed -n '1,4p' || echo "no card0"
	amixer -c 0 sget "Headset Mic" 2>/dev/null | sed -n '1,4p' || true
	amixer -c 0 sget "Differential Mux" 2>/dev/null | sed -n '1,6p' || true
	;;
*)
	echo "Usage: $0 {start|stop|restart|status}" >&2
	exit 1
	;;
esac
exit 0
