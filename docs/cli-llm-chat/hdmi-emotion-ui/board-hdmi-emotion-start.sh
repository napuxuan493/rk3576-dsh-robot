#!/bin/sh
# Start HDMI emotion UI on TL3576-EVM-H.
# Default BACKEND=fb → emotion_fb uses share_docs robot-eyes SDF (preview.gif look).
# Optional BACKEND=eyes (raw eyes_app --demo), BACKEND=chromium (Weston kiosk).
# No fish on idle. eth0/DSH untouched unless ETH0_STATIC=1.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# Prefer /userdata so app partition reflash keeps the UI + animation assets.
DEST="${DAFEIYU_HDMI_ROOT:-/userdata/dafeiyu-hdmi}"
PORT="${EMOTION_PORT:-8765}"
# Prefer HDMI panel preferred mode (LEN L1950wD: 1024x600); avoid 1440x900
# which leaves rockchipdrmfb visible xres/yres mismatched vs virtual buffer.
MODE="${HDMI_MODE:-1024x600}"
BACKEND="${BACKEND:-fb}"
PIDDIR=/var/run/dafeiyu-hdmi
LOGDIR=/var/log/dafeiyu-hdmi
ANIM="${ANIMATION_ASSETS:-/userdata/animation-assets}"
# v1.1.0 frame pack (share_docs rk3576-robot-eyes-deploy-v1.1.0)
ROBOT_EYES_PACK="${ROBOT_EYES_PACK:-$ANIM/rk3576-robot-eyes/fb-raw}"
ROBOT_EYES_ROOT="${ROBOT_EYES_ROOT:-$ANIM/rk3576-robot-eyes}"
EYES_GIF_RAW="${EYES_GIF_RAW:-$ANIM/eyes-ref/gif-raw}"
EYES_MODE="${EYES_MODE:-pack}"
export ROBOT_EYES_PACK ROBOT_EYES_ROOT EYES_GIF_RAW EYES_MODE
# Larger eyes; pair midline centered. IPD via EYE_SEP (not gap stretch).
# Knobs tuned at EYE_REF (1024x600); emotion_fb remaps onto active CRTC so
# 1920x1080 keeps the same apparent size (do not shrink vs the tuned look).
EYE_SCALE="${EYE_SCALE:-1.25}"
EYE_REF_W="${EYE_REF_W:-1024}"
EYE_REF_H="${EYE_REF_H:-600}"
# Slightly elliptical eyes (wider than tall).
EYE_GAP_X="${EYE_GAP_X:-1.28}"
# Mild IPD widen (~1.35–1.5); was 2.0 too wide.
EYE_SEP="${EYE_SEP:-1.4}"
# Soft glow (baked offscreen); keep light to avoid thrash/flicker.
EYE_GLOW_R="${EYE_GLOW_R:-4}"
EYE_GLOW="${EYE_GLOW:-0.55}"
# Cap ~12 Hz present + clip (was 30 → fast strobe / live-fb clear flicker).
EMOTION_FPS="${EMOTION_FPS:-12}"
EMOTION_ANIM_FPS="${EMOTION_ANIM_FPS:-12}"
EMOTION_DT_CAP="${EMOTION_DT_CAP:-0.18}"
EMOTION_POLL_EVERY="${EMOTION_POLL_EVERY:-3}"
# Livelier idle: blink + drift + breath (emotion_fb); IDLE_LIVELY=0 to disable.
IDLE_LIVELY="${IDLE_LIVELY:-1}"
# Wait after Weston stop before first present (DRM/fbdev settle).
EMOTION_DRM_SETTLE_S="${EMOTION_DRM_SETTLE_S:-0.8}"
# Idle specials rotation hold (board-dsh-chat.sh); export so chat inherits if started after UI.
EMOTION_CYCLE_S="${EMOTION_CYCLE_S:-4}"
export EYE_SCALE EYE_REF_W EYE_REF_H EYE_GAP_X EYE_SEP EYE_GLOW_R EYE_GLOW EMOTION_CYCLE_S EMOTION_FPS EMOTION_ANIM_FPS EMOTION_DT_CAP EMOTION_POLL_EVERY IDLE_LIVELY EMOTION_DRM_SETTLE_S

mkdir -p "$DEST" "$PIDDIR" "$LOGDIR"

sync_payload() {
	if [ "$ROOT" = "$DEST" ]; then
		return 0
	fi
	cp -a "$ROOT/index.html" "$ROOT/emotion_api.py" "$ROOT/emotion_fb.py" "$DEST/"
	cp -a "$ROOT/board-hdmi-emotion-start.sh" "$ROOT/board-hdmi-emotion-stop.sh" \
		"$ROOT/board-hdmi-emotion-set.sh" "$DEST/"
	chmod +x "$DEST"/*.sh "$DEST/emotion_api.py" "$DEST/emotion_fb.py"
}

kill_extras() {
	pkill -f 'weston-terminal' 2>/dev/null || true
	pkill -f 'weston-flower' 2>/dev/null || true
	pkill -f 'weston-simple-egl' 2>/dev/null || true
	pkill -f 'hdmi-chat-overlay' 2>/dev/null || true
	pkill -f 'weston-editor' 2>/dev/null || true
	pkill -f 'weston-image' 2>/dev/null || true
}

ensure_eth0() {
	# Prefer leaving ICS alone; only re-assert static if asked or address missing.
	if [ "${ETH0_STATIC:-0}" != "1" ]; then
		if ip -4 addr show eth0 2>/dev/null | grep -q '192.168.137.2'; then
			return 0
		fi
	fi
	ip link set eth0 up 2>/dev/null || true
	ip addr replace 192.168.137.2/24 dev eth0 2>/dev/null || true
	ip route replace default via 192.168.137.1 dev eth0 2>/dev/null || true
}

apply_fullbleed_weston() {
	# Letterbox root cause: WESTON_DRM_KEEP_RATIO=1 (mirror keep-aspect).
	if [ -f /etc/profile.d/weston.sh ]; then
		if grep -q 'WESTON_DRM_KEEP_RATIO=1' /etc/profile.d/weston.sh; then
			cp -a /etc/profile.d/weston.sh /etc/profile.d/weston.sh.dafeiyu-bak 2>/dev/null || true
			sed -i 's/export WESTON_DRM_KEEP_RATIO=1/export WESTON_DRM_KEEP_RATIO=0/' /etc/profile.d/weston.sh
		fi
		sed -i 's/^# export WESTON_FULLSCREEN_BLACK_BACKGROUND=1/export WESTON_FULLSCREEN_BLACK_BACKGROUND=1/' /etc/profile.d/weston.sh 2>/dev/null || true
		sed -i 's/^# export WESTON_NO_BACKGROUND=1/export WESTON_NO_BACKGROUND=1/' /etc/profile.d/weston.sh 2>/dev/null || true
		if ! grep -q 'WESTON_DRM_CONFIG=' /etc/profile.d/weston.sh; then
			echo 'export WESTON_DRM_CONFIG=/tmp/.weston_drm.conf' >> /etc/profile.d/weston.sh
		fi
	fi

	mkdir -p /etc/xdg/weston/weston.ini.d
	for f in 01-launcher.ini 02-desktop.ini 03-desktop-launcher.ini 04-desktop-launcher-group.ini; do
		if [ -f "/etc/xdg/weston/weston.ini.d/$f" ] && [ ! -f "/etc/xdg/weston/weston.ini.d/$f.dafeiyu-bak" ]; then
			mv "/etc/xdg/weston/weston.ini.d/$f" "/etc/xdg/weston/weston.ini.d/$f.dafeiyu-bak"
		elif [ -f "/etc/xdg/weston/weston.ini.d/$f" ]; then
			rm -f "/etc/xdg/weston/weston.ini.d/$f"
		fi
	done

	cat > /etc/xdg/weston/weston.ini.d/99-dafeiyu-emotion.ini <<EOF
[shell]
panel-position=none
background-image=
background-color=0xFF000000
locking=false
startup-animation=none

[output]
name=HDMI-A-1
mode=${MODE}
EOF

	cat > /tmp/.weston_drm.conf <<EOF
output:HDMI-A-1:mode=${MODE}
output:HDMI-A-1:primary
compositor:cursor:hide
EOF
}

restart_weston() {
	export WESTON_DRM_KEEP_RATIO=0
	export WESTON_DRM_PRIMARY=HDMI-A-1
	export WESTON_DRM_MIRROR=1
	export WESTON_DISABLE_ATOMIC=1
	export WESTON_DRM_MIN_BUFFERS=2
	export WESTON_FULLSCREEN_BLACK_BACKGROUND=1
	export WESTON_NO_BACKGROUND=1
	export WESTON_DRM_CONFIG=/tmp/.weston_drm.conf
	export WESTON_FREEZE_DISPLAY=/tmp/.freeze_weston
	export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
	export WL_OUTPUT_VERSION=3

	killall weston 2>/dev/null || true
	i=0
	while pgrep -x weston >/dev/null 2>&1 && [ "$i" -lt 40 ]; do
		i=$((i + 1))
		sleep 0.1
	done
	sleep 0.3
	/usr/bin/weston >>/var/log/weston.log 2>&1 &

	i=0
	while [ "$i" -lt 50 ]; do
		if [ -S "${XDG_RUNTIME_DIR}/wayland-0" ] || [ -S /var/run/wayland-0 ]; then
			break
		fi
		i=$((i + 1))
		sleep 0.2
	done
	sleep 1
}

clear_fb_black() {
	# Wipe post-Weston garbage so HDMI is not snow while emotion_fb warms.
	python3 - <<'PY' 2>/dev/null || true
import os, array, fcntl, struct, mmap
dev = os.environ.get("FRAMEBUFFER", "/dev/fb0")
fd = os.open(dev, os.O_RDWR)
buf = array.array("B", [0] * 256)
fcntl.ioctl(fd, 0x4600, buf, True)
xres, yres, xv, yv, xoff, yoff = struct.unpack_from("<6I", buf, 0)
if xv <= 0 or yv <= 0:
    vs = open("/sys/class/graphics/fb0/virtual_size").read().strip().split(",")
    xv, yv = int(vs[0]), int(vs[1])
# Cover virtual buffer top rows (HDMI plane src is often 1920x1080 of 1920x1280).
nbytes = max(1, xv) * max(1, min(yv, 1280)) * 4
try:
    mm = mmap.mmap(fd, xv * yv * 4, mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ)
    # XR24/ARGB black with opaque alpha
    mm[:nbytes] = (b"\x00\x00\x00\xff") * (nbytes // 4)
    mm.close()
except OSError:
    os.lseek(fd, 0, os.SEEK_SET)
    os.write(fd, (b"\x00\x00\x00\xff") * (nbytes // 4))
os.close(fd)
print(f"fb cleared black virtual={xv}x{yv} bytes={nbytes}")
PY
}

stop_weston_for_fb() {
	killall weston 2>/dev/null || true
	i=0
	while pgrep -x weston >/dev/null 2>&1 && [ "$i" -lt 40 ]; do
		i=$((i + 1))
		sleep 0.1
	done
	# Prefer HDMI preferred mode via modetest when weston is gone.
	# Note: modetest mode often does *not* stick after exit (fbcon/CRTC may stay
	# at 1920x1080); emotion_fb centers on *active* CRTC/plane, not modes[0].
	if command -v modetest >/dev/null 2>&1; then
		# connector 181 = HDMI-A-1 on this image (see board-hdmi-test-result)
		modetest -M rockchip -s 181:"${MODE}" >/dev/null 2>&1 || \
			modetest -M rockchip -s 181:1024x600 >/dev/null 2>&1 || true
	fi
	# Align fbdev visible geometry when possible (keep virtual size; CRTC may stay).
	if command -v fbset >/dev/null 2>&1; then
		_mw="${MODE%x*}"
		_mh="${MODE#*x}"
		_vs="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 1920,1280)"
		_vx="${_vs%,*}"
		_vy="${_vs#*,}"
		fbset -g "$_mw" "$_mh" "$_vx" "$_vy" 32 >/dev/null 2>&1 || true
	fi
	# Let DRM/fbdev settle, then paint black before launching the renderer.
	sleep "${EMOTION_DRM_SETTLE_S:-0.8}"
	clear_fb_black
}

start_api() {
	if [ -f "$PIDDIR/api.pid" ] && kill -0 "$(cat "$PIDDIR/api.pid")" 2>/dev/null; then
		return 0
	fi
	# nohup: survive SSH logout when start is invoked remotely
	EMOTION_HOST=127.0.0.1 EMOTION_PORT="$PORT" \
		nohup python3 "$DEST/emotion_api.py" >>"$LOGDIR/api.log" 2>&1 &
	echo $! >"$PIDDIR/api.pid"
}

wait_api() {
	i=0
	while [ "$i" -lt 30 ]; do
		if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/api/emotion', timeout=1)" 2>/dev/null; then
			return 0
		fi
		i=$((i + 1))
		sleep 0.2
	done
	return 1
}

start_fb() {
	# Avoid pkill -f matching this shell's argv when invoked over SSH.
	if [ -f "$PIDDIR/fb.pid" ]; then
		kill "$(cat "$PIDDIR/fb.pid")" 2>/dev/null || true
	fi
	if [ -f "$PIDDIR/eyes.pid" ]; then
		kill "$(cat "$PIDDIR/eyes.pid")" 2>/dev/null || true
	fi
	EMOTION_STOP_WESTON=0 \
		EMOTION_API="http://127.0.0.1:${PORT}/api/emotion" \
		ROBOT_EYES_PACK="$ROBOT_EYES_PACK" \
		ROBOT_EYES_ROOT="$ROBOT_EYES_ROOT" \
		EYES_GIF_RAW="$EYES_GIF_RAW" \
		EYES_MODE="$EYES_MODE" \
		EYE_SCALE="$EYE_SCALE" \
		EYE_REF_W="$EYE_REF_W" \
		EYE_REF_H="$EYE_REF_H" \
		EYE_GAP_X="$EYE_GAP_X" \
		EYE_SEP="$EYE_SEP" \
		EYE_GLOW_R="$EYE_GLOW_R" \
		EYE_GLOW="$EYE_GLOW" \
		EMOTION_FPS="$EMOTION_FPS" \
		EMOTION_ANIM_FPS="$EMOTION_ANIM_FPS" \
		EMOTION_DT_CAP="$EMOTION_DT_CAP" \
		EMOTION_POLL_EVERY="$EMOTION_POLL_EVERY" \
		IDLE_LIVELY="$IDLE_LIVELY" \
		EMOTION_DRM_SETTLE_S="$EMOTION_DRM_SETTLE_S" \
		nohup python3 "$DEST/emotion_fb.py" >>"$LOGDIR/fb.log" 2>&1 &
	echo $! >"$PIDDIR/fb.pid"
}

start_robot_eyes() {
	# Full-screen SDF eyes from share_docs robot-eyes.zip (takes over fb0).
	if [ -f "$PIDDIR/fb.pid" ]; then
		kill "$(cat "$PIDDIR/fb.pid")" 2>/dev/null || true
	fi
	if [ -f "$PIDDIR/eyes.pid" ]; then
		kill "$(cat "$PIDDIR/eyes.pid")" 2>/dev/null || true
	fi
	APP="$ROBOT_EYES_ROOT/app/eyes_app.py"
	if [ ! -f "$APP" ]; then
		echo "robot-eyes missing at $APP" >&2
		return 1
	fi
	nohup python3 "$APP" --demo --socket /run/robot-eyes.sock >>"$LOGDIR/robot-eyes.log" 2>&1 &
	echo $! >"$PIDDIR/eyes.pid"
}

start_chromium() {
	export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
	export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
	export LD_LIBRARY_PATH="/usr/lib/chromium:/usr/lib/chromium/lib:${LD_LIBRARY_PATH:-}"

	pkill -f 'chromium-bin.*(8765|dafeiyu|emotion)' 2>/dev/null || true
	sleep 0.3

	URL="http://127.0.0.1:${PORT}/"
	BIN=/usr/lib/chromium/chromium-bin
	[ -x "$BIN" ] || { echo "chromium-bin missing" >&2; return 1; }

	"$BIN" \
		--ozone-platform=wayland \
		--use-gl=angle --use-angle=gles-egl \
		--use-cmd-decoder=passthrough \
		--no-sandbox \
		--disable-gpu-sandbox \
		--ignore-gpu-blocklist \
		--kiosk --start-fullscreen \
		--no-first-run --disable-infobars \
		--disable-session-crashed-bubble \
		--disable-features=TranslateUI \
		--check-for-update-interval=31536000 \
		--autoplay-policy=no-user-gesture-required \
		--window-position=0,0 \
		"$URL" >>"$LOGDIR/chromium.log" 2>&1 &
	echo $! >"$PIDDIR/chromium.pid"
}

# --- main ---
sync_payload
ensure_eth0
kill_extras

# Always persist full-bleed weston knobs (KEEP_RATIO=0 + mode) even for fb path,
# so a later weston bring-up stays filled.
apply_fullbleed_weston

start_api
wait_api || echo "warn: emotion api not ready" >&2

case "$BACKEND" in
	fb|framebuffer)
		stop_weston_for_fb
		ensure_eth0
		start_fb
		;;
	eyes|robot-eyes)
		stop_weston_for_fb
		ensure_eth0
		start_robot_eyes
		;;
	chromium|kiosk)
		restart_weston
		kill_extras
		ensure_eth0
		start_chromium
		;;
	*)
		echo "unknown BACKEND=$BACKEND (fb|eyes|chromium)" >&2
		exit 1
		;;
esac

# Steady reference idle (vertical white capsules); no fish.
python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${PORT}/api/emotion', data=b'{\"state\":\"idle\",\"variant\":\"\"}', headers={'Content-Type':'application/json'}))" 2>/dev/null || true
ensure_eth0

echo "dafeiyu-hdmi up  backend=${BACKEND} mode=${MODE} api=:${PORT} pack=${ROBOT_EYES_PACK}"
echo "set emotion: $DEST/board-hdmi-emotion-set.sh happy|listening|thinking|speaking|idle"
