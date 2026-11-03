#!/bin/sh
# Stop emotion UI clients. RESTORE=1 puts Weston desktop launchers back.
set -eu
PIDDIR=/var/run/dafeiyu-hdmi

pkill -f 'chromium-bin.*(8765|dafeiyu|emotion|127.0.0.1)' 2>/dev/null || true
pkill -f 'emotion_fb.py' 2>/dev/null || true
pkill -f 'emotion_api.py' 2>/dev/null || true
pkill -f 'eyes_app.py' 2>/dev/null || true

for name in chromium.pid fb.pid api.pid eyes.pid; do
	if [ -f "$PIDDIR/$name" ]; then
		kill "$(cat "$PIDDIR/$name")" 2>/dev/null || true
		rm -f "$PIDDIR/$name"
	fi
done
rm -f /run/robot-eyes.sock 2>/dev/null || true

if [ "${RESTORE:-0}" = "1" ]; then
	for f in /etc/xdg/weston/weston.ini.d/*.dafeiyu-bak; do
		[ -f "$f" ] || continue
		mv "$f" "${f%.dafeiyu-bak}"
	done
	rm -f /etc/xdg/weston/weston.ini.d/99-dafeiyu-emotion.ini
	if [ -f /etc/profile.d/weston.sh.dafeiyu-bak ]; then
		mv /etc/profile.d/weston.sh.dafeiyu-bak /etc/profile.d/weston.sh
	fi
	killall weston 2>/dev/null || true
	sleep 0.5
	export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
	/usr/bin/weston >>/var/log/weston.log 2>&1 &
fi

echo "dafeiyu-hdmi stopped"
