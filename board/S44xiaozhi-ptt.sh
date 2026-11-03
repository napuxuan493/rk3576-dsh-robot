#!/bin/sh
# SysV: KEY5 hold-to-talk daemon (userdata survives app flash).
#   ln -sfn /userdata/xiaozhi-cli/S44xiaozhi-ptt.sh /etc/init.d/S44xiaozhi-ptt
# Start after S42 ICS + S43 audio. No flash required.
#
# Default: background board-ptt-hold.sh loop. Disable: PTT_BOOT=0
# Single-instance: stop kills bash+python orphans; start uses flock in board-ptt-hold.sh

DIR=/userdata/xiaozhi-cli
PTT="$DIR/board-ptt-hold.sh"
PIDFILE=/var/run/xiaozhi-ptt.pid
LOG=$DIR/ptt-hold.log
LOCK=$DIR/ptt-hold.lock

kill_ptt_tree() {
	# pidfile bash wrapper
	if [ -f "$PIDFILE" ]; then
		pid=$(cat "$PIDFILE" 2>/dev/null)
		if [ -n "$pid" ]; then
			# kill children first (python)
			pkill -P "$pid" 2>/dev/null || true
			kill "$pid" 2>/dev/null || true
		fi
		rm -f "$PIDFILE"
	fi
	killall board-ptt-hold.sh 2>/dev/null || true
	# orphaned python that still holds /dev/input/event7 (previous restarts)
	for p in $(pgrep -f 'python3 -' 2>/dev/null); do
		if ls -l "/proc/$p/fd" 2>/dev/null | grep -q '/dev/input/event'; then
			echo "S44xiaozhi-ptt: killing orphan evdev python pid=$p"
			kill "$p" 2>/dev/null || true
		fi
	done
	rm -f "$LOCK"
	sleep 0.3
}

start() {
	if [ "${PTT_BOOT:-1}" = "0" ]; then
		echo "S44xiaozhi-ptt: PTT_BOOT=0 — skip"
		return 0
	fi
	if [ ! -x "$PTT" ]; then
		echo "S44xiaozhi-ptt: missing $PTT"
		return 1
	fi
	# Always clear orphans first — stale python caused double voice-turn
	kill_ptt_tree
	# shellcheck disable=SC1090
	[ -f "$DIR/.env" ] && set -a && . "$DIR/.env" && set +a
	export GREET_ON_START="${GREET_ON_START:-0}"
	echo "S44xiaozhi-ptt: starting hold-to-talk → voice bridge (single instance)"
	(
		cd "$DIR" || exit 1
		exec ./board-ptt-hold.sh
	) >>"$LOG" 2>&1 &
	echo $! >"$PIDFILE"
	echo "S44xiaozhi-ptt: pid $(cat "$PIDFILE") log $LOG"
}

stop() {
	kill_ptt_tree
	echo "S44xiaozhi-ptt: stopped"
}

case "$1" in
start) start ;;
stop) stop ;;
restart) stop; start ;;
*) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
