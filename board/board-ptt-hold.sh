#!/usr/bin/env bash
# KEY5 PTT daemon → board-voice-once (LAN voice bridge). No flash.
#
# Hardware (TL3576-EVM / RK3576):
#   Silk KEY5 = GPIOB3 = GPIO1_B3 (DT: gpio1 RK_PB3, ACTIVE_LOW)
#   Linux gpio = bank*32 + group*8 + pin = 1*32 + 1*8 + 3 = **43**
#   gpio-keys label user-key1 → /dev/input/event7
#   DT linux,code = KEY_PROG2 (149); live caps may report EV_KEY 21 — accept any
#   on this node. Do **not** export gpio-43 (already claimed).
#
# UX (default PTT_MODE=toggle):
#   1st press  → play local 「diii」 → start arecord
#                (barge-in if TTS playing: kill aplay, discard reply)
#   2nd press  → stop record → play local 「滴嘟」 → POST bridge → aplay new reply
#   Press during TTS → kill aplay immediately; discard; never resume; start new record
#
# Optional: PTT_MODE=hold → press=start(+diii), release=end(+didu) + bridge + barge-in
#
#   ./board-ptt-hold.sh              # daemon loop
#   ./board-ptt-hold.sh --once       # one utterance cycle
#   ./board-ptt-hold.sh --self-test
#   ./board-ptt-hold.sh --mk-didu    # (re)generate diii.wav + di-du.wav via sox
#   PTT_SMOKE=1 ./board-ptt-hold.sh  # diii → 2s record → didu → bridge (no key)
#
# See docs/board-ptt-key5.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "ptt: $*" >&2; }

PTT_GPIO="${PTT_GPIO:-43}"
PTT_KEY_CODES="${PTT_KEY_CODES:-149 21}"
PTT_MODE="${PTT_MODE:-toggle}" # toggle | hold
PTT_MAX_SECS="${PTT_MAX_SECS:-30}"
PTT_MIN_SECS="${PTT_MIN_SECS:-0.35}"
PTT_DEBOUNCE_MS="${PTT_DEBOUNCE_MS:-250}"
# Ignore KEY bounce after end-press so bridge wait / early aplay is not false-barged
PTT_POST_END_GUARD_MS="${PTT_POST_END_GUARD_MS:-1000}"
PTT_LOCK="${PTT_LOCK:-/userdata/xiaozhi-cli/ptt-hold.lock}"
REC_WAV="${REC_WAV:-/userdata/xiaozhi-cli/last-utt.wav}"
REPLY_WAV="${REPLY_WAV:-/userdata/xiaozhi-cli/last-reply.wav}"
DIII_WAV="${DIII_WAV:-/userdata/xiaozhi-cli/diii.wav}"
DIDU_WAV="${DIDU_WAV:-/userdata/xiaozhi-cli/di-du.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"
AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"
VOICE_ONCE="${VOICE_ONCE:-$SCRIPT_DIR/board-voice-once.sh}"

MODE="loop"
[[ "${1:-}" == "--once" ]] && MODE="once"
[[ "${1:-}" == "--self-test" ]] && MODE="self-test"
[[ "${1:-}" == "--mk-didu" ]] && MODE="mk-didu"
[[ "${PTT_SMOKE:-0}" == "1" ]] && MODE="smoke"

ensure_cues() {
	local force=0
	[[ "${DIDU_FORCE:-0}" == "1" || "${1:-}" == "force" ]] && force=1
	command -v sox >/dev/null 2>&1 || die "need sox to generate PTT cue wavs"
	mkdir -p "$(dirname "$DIDU_WAV")" "$(dirname "$DIII_WAV")"
	# 「diii」 start cue — single sustained beep (~1400Hz), 48k stereo
	if [[ "$force" == "1" || ! -f "$DIII_WAV" ]]; then
		sox -n -r 48000 -c 2 -b 16 "$DIII_WAV" synth 0.14 sine 1400 vol 0.4
		log "wrote $DIII_WAV ($(wc -c <"$DIII_WAV" | tr -d ' ')B)"
	fi
	# 「滴嘟」 end cue — 滴(~1200Hz) + gap + 嘟(~880Hz)
	if [[ "$force" == "1" || ! -f "$DIDU_WAV" ]]; then
		sox -n -r 48000 -c 2 -b 16 "$DIDU_WAV" \
			synth 0.09 sine 1200 vol 0.4 : \
			synth 0.05 sine 0 : \
			synth 0.12 sine 880 vol 0.4
		log "wrote $DIDU_WAV ($(wc -c <"$DIDU_WAV" | tr -d ' ')B)"
	fi
}
ensure_didu() { ensure_cues "$@"; }

find_event() {
	if [[ -n "${PTT_EVENT:-}" && -e "$PTT_EVENT" ]]; then
		echo "$PTT_EVENT"
		return 0
	fi
	local e name
	for e in /dev/input/event*; do
		[[ -e "$e" ]] || continue
		name="$(cat "/sys/class/input/$(basename "$e")/device/name" 2>/dev/null || true)"
		if [[ "$name" == "gpio-keys" ]]; then
			echo "$e"
			return 0
		fi
	done
	[[ -e /dev/input/event7 ]] && echo /dev/input/event7 && return 0
	return 1
}

self_test() {
	local ev ok=0
	log "KEY5: silk GPIOB3 → GPIO1_B3 → gpio-${PTT_GPIO} (bank*32+group*8+pin)"
	if grep -E "gpio-${PTT_GPIO}[[:space:]]" /sys/kernel/debug/gpio 2>/dev/null | grep -q user-key1; then
		grep -E "gpio-${PTT_GPIO}[[:space:]]" /sys/kernel/debug/gpio
		ok=1
	else
		log "gpio-${PTT_GPIO}: NOT found as user-key1"
	fi
	ev="$(find_event || true)"
	if [[ -n "$ev" ]]; then
		log "evdev: $ev ($(cat /sys/class/input/$(basename "$ev")/device/name 2>/dev/null))"
		log "key caps: $(cat /sys/class/input/$(basename "$ev")/device/capabilities/key 2>/dev/null | tr '\n' ' ')"
		ok=1
	else
		log "evdev: missing"
	fi
	log "mode=${PTT_MODE} voice-once=$VOICE_ONCE"
	[[ "$ok" == "1" ]] || die "self-test failed"
	log "self-test OK"
}

kill_playback() {
	# Barge-in: stop TTS/cue immediately; never resume discarded reply
	killall -q aplay 2>/dev/null || true
	# also paplay if somehow used
	killall -q paplay 2>/dev/null || true
}

play_file() {
	local f="$1"
	[[ -f "$f" ]] || return 1
	AUDIO_UP_QUIET=1 "$AUDIO_UP" 2>/dev/null || true
	aplay -D "$DEV" "$f" >/dev/null 2>&1 || aplay -D "plughw:${CARD},0" "$f" >/dev/null 2>&1 || return 1
}

# --- modes that exit early ---
case "$MODE" in
mk-didu)
	DIDU_FORCE=1 ensure_cues force
	exit 0
	;;
self-test)
	self_test
	ensure_cues
	exit 0
	;;
smoke)
	self_test >/dev/null || self_test
	ensure_cues
	[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true
	log "SMOKE: diii → 2s record → didu → bridge (SKIP_PLAY then local aplay)"
	kill_playback
	play_file "$DIII_WAV" || log "diii play failed"
	rm -f "$REC_WAV"
	arecord -D "$DEV" -f S16_LE -r 16000 -c 2 -d 2 "$REC_WAV" >&2
	kill_playback
	play_file "$DIDU_WAV" || log "didu play failed"
	export USE_EXISTING_REC=1 SKIP_PLAY=1 GREET_ON_START=0 REC_WAV REPLY_WAV
	"$VOICE_ONCE" || die "voice-once failed"
	PLAY="${REPLY_WAV}.play.wav"
	[[ -f "$PLAY" ]] || PLAY="$REPLY_WAV"
	play_file "$PLAY" || die "reply aplay failed"
	log "smoke done"
	exit 0
	;;
esac

ensure_cues
self_test >/dev/null || self_test
EVENT="$(find_event || true)"
[[ -n "$EVENT" ]] || die "no gpio-keys event node"
[[ -x "$VOICE_ONCE" ]] || die "missing $VOICE_ONCE"
[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true

# Single instance: two pythons on event7 = duplicate diii/record/bridge (same chat text ×2)
exec 9>"$PTT_LOCK"
if ! flock -n 9; then
	die "another board-ptt-hold holds $PTT_LOCK — stop S44 / kill orphan python first"
fi
log "flock OK ($PTT_LOCK)"

if [[ "${GREET_ON_START:-0}" == "1" && -x "$SCRIPT_DIR/board-greet.sh" ]]; then
	"$SCRIPT_DIR/board-greet.sh" || log "greet failed"
fi

# Core loop in Python: toggle/hold + barge-in + diii/didu + bridge
export PTT_EVENT_PATH="$EVENT"
export PTT_KEY_CODES PTT_MODE PTT_MAX_SECS PTT_MIN_SECS PTT_DEBOUNCE_MS PTT_POST_END_GUARD_MS
export REC_WAV REPLY_WAV DIII_WAV DIDU_WAV ALSA_DEV="$DEV" ALSA_CARD="$CARD"
export VOICE_ONCE AUDIO_UP SCRIPT_DIR
export EMOTION_HELPER="${EMOTION_HELPER:-$SCRIPT_DIR/board-emotion-voice.sh}"
export PTT_RUN_MODE="$MODE" # loop | once

python3 - <<'PY'
import os, struct, select, subprocess, signal, time, sys

ev_path = os.environ["PTT_EVENT_PATH"]
codes = {int(x) for x in os.environ.get("PTT_KEY_CODES", "").split() if x.strip()}
mode = os.environ.get("PTT_MODE", "toggle")  # toggle | hold
max_secs = float(os.environ.get("PTT_MAX_SECS", "30"))
min_secs = float(os.environ.get("PTT_MIN_SECS", "0.35"))
debounce = float(os.environ.get("PTT_DEBOUNCE_MS", "80")) / 1000.0
post_end_guard = float(os.environ.get("PTT_POST_END_GUARD_MS", "700")) / 1000.0
rec_wav = os.environ["REC_WAV"]
reply_wav = os.environ["REPLY_WAV"]
diii_wav = os.environ.get("DIII_WAV", "/userdata/xiaozhi-cli/diii.wav")
didu_wav = os.environ["DIDU_WAV"]
dev = os.environ.get("ALSA_DEV", "hw:0,0")
card = os.environ.get("ALSA_CARD", "0")
voice_once = os.environ["VOICE_ONCE"]
audio_up = os.environ.get("AUDIO_UP", "")
emotion_helper = os.environ.get("EMOTION_HELPER", "")
run_mode = os.environ.get("PTT_RUN_MODE", "loop")
ignore_keys_until = 0.0
busy = False  # True during bridge/TTS — ignore KEY (one turn per press-pair)

EV_KEY = 1
fmt64, fmt32 = "QQHHi", "IIHHi"
size64, size32 = struct.calcsize(fmt64), struct.calcsize(fmt32)

fd = os.open(ev_path, os.O_RDONLY | os.O_NONBLOCK)
# Exclusive grab so a second process cannot also see KEY5 (if supported)
try:
    import fcntl
    EVIOCGRAB = 0x40044590
    fcntl.ioctl(fd, EVIOCGRAB, 1)
    print("ptt: EVIOCGRAB on", ev_path, file=sys.stderr, flush=True)
except Exception as e:
    print(f"ptt: EVIOCGRAB skip ({e})", file=sys.stderr, flush=True)

def log(msg):
    print(f"ptt: {msg}", file=sys.stderr, flush=True)

def read_events(buf):
    use = fmt64 if len(buf) % size64 == 0 else fmt32
    sz = size64 if use == fmt64 else size32
    out = []
    off = 0
    while off + sz <= len(buf):
        rec = struct.unpack_from(use, buf, off)
        off += sz
        out.append((rec[2], rec[3], rec[4]))  # type, code, value
    return out

def drain_keys(timeout=0.0):
    """Return list of (code, value) for EV_KEY; value 1=down 0=up 2=repeat."""
    keys = []
    end = time.time() + timeout
    while True:
        remaining = end - time.time()
        if remaining < 0 and timeout > 0:
            break
        wait = max(0.0, remaining) if timeout > 0 else 0.0
        r, _, _ = select.select([fd], [], [], wait if timeout > 0 else 0.0)
        if not r:
            if timeout == 0:
                # non-blocking drain
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    break
                if not data:
                    break
                for typ, code, val in read_events(data):
                    if typ == EV_KEY:
                        keys.append((code, val))
                continue
            break
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            break
        if not data:
            break
        for typ, code, val in read_events(data):
            if typ == EV_KEY:
                keys.append((code, val))
        if timeout == 0:
            # keep draining until empty
            continue
        break
    return keys

def kill_playback():
    subprocess.call(["killall", "-q", "aplay"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(["killall", "-q", "paplay"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def stop_proc(proc, sig=signal.SIGINT, wait=2.0):
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.send_signal(sig)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
            proc.wait(timeout=1)
        except Exception:
            pass

def audio_up_quiet():
    if audio_up and os.access(audio_up, os.X_OK):
        env = os.environ.copy()
        env["AUDIO_UP_QUIET"] = "1"
        subprocess.call([audio_up], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def drain_keys():
    """Drop pending EV_KEY (bounce/autorepeat) without acting."""
    while True:
        r, _, _ = select.select([fd], [], [], 0)
        if not r:
            return
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            return
        if not data:
            return

def arm_post_end_guard():
    global ignore_keys_until
    ignore_keys_until = time.time() + post_end_guard
    drain_keys()

def emotion_play_start(wav_path):
    if not emotion_helper or not os.access(emotion_helper, os.X_OK):
        return
    emo = ""
    # side file written by board-voice-once (SKIP_PLAY)
    for p in (reply_wav + ".emotion", os.path.splitext(wav_path)[0] + ".emotion"):
        if os.path.isfile(p):
            try:
                emo = open(p, encoding="utf-8").read().strip()
            except OSError:
                pass
            break
    try:
        sz = os.path.getsize(wav_path)
        hold = max(2.0, sz / (48000 * 2 * 2) + 0.5)
    except OSError:
        hold = 20.0
    subprocess.call([emotion_helper, "ensure"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(
        [emotion_helper, "play-start", emo or "", str(hold)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if emo:
        log(f"emotion play-start {emo} hold={hold:.1f}s")

def emotion_play_end():
    if not emotion_helper or not os.access(emotion_helper, os.X_OK):
        return
    subprocess.call([emotion_helper, "play-end"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def play_blocking(path, allow_barge=False):
    """Play wav; if allow_barge and KEY down (after guard), kill aplay and return 'barge'."""
    if not os.path.isfile(path):
        return "missing"
    audio_up_quiet()
    kill_playback()
    if allow_barge:
        emotion_play_start(path)
    proc = subprocess.Popen(
        ["aplay", "-D", dev, path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    while proc.poll() is None:
        keys = []
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 4096)
                if data:
                    for typ, code, val in read_events(data):
                        if typ == EV_KEY:
                            keys.append((code, val))
            except BlockingIOError:
                pass
        if allow_barge and any(v == 1 for _, v in keys):
            if time.time() < ignore_keys_until:
                continue  # swallow bounce from end-press
            log("BARGE-IN during playback — kill aplay, discard reply")
            stop_proc(proc, signal.SIGKILL, 0.5)
            kill_playback()
            emotion_play_end()
            # discard reply artifacts
            for p in (reply_wav, reply_wav + ".play.wav", reply_wav.replace(".wav", ".pcm.wav")):
                try:
                    os.remove(p)
                except FileNotFoundError:
                    pass
            return "barge"
    rc = proc.returncode
    if rc != 0:
        # fallback plughw
        proc = subprocess.Popen(
            ["aplay", "-D", f"plughw:{card},0", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        while proc.poll() is None:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(fd, 4096)
                    if data and allow_barge:
                        for typ, code, val in read_events(data):
                            if typ == EV_KEY and val == 1:
                                log("BARGE-IN during playback — kill aplay, discard reply")
                                stop_proc(proc, signal.SIGKILL, 0.5)
                                kill_playback()
                                emotion_play_end()
                                return "barge"
                except BlockingIOError:
                    pass
        rc = proc.returncode
    if allow_barge:
        emotion_play_end()
    return "ok" if rc == 0 else "fail"

def start_record():
    os.makedirs(os.path.dirname(rec_wav) or ".", exist_ok=True)
    try:
        os.remove(rec_wav)
    except FileNotFoundError:
        pass
    audio_up_quiet()
    # 「diii」 start cue before mic opens (short; no barge)
    kill_playback()
    log("cue 「diii」")
    play_blocking(diii_wav, allow_barge=False)
    proc = subprocess.Popen(
        ["arecord", "-D", dev, "-f", "S16_LE", "-r", "16000", "-c", "2", rec_wav],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    log(f"RECORD start (max {max_secs}s) — press KEY5 again to end" if mode == "toggle"
        else f"RECORD start — release KEY5 to end")
    return proc, time.time()

def stop_record(proc, t0):
    stop_proc(proc, signal.SIGINT, 2.0)
    sz = os.path.getsize(rec_wav) if os.path.isfile(rec_wav) else 0
    held = time.time() - t0
    log(f"RECORD stop hold={held:.2f}s size={sz}B")
    return sz, held

def run_bridge_turn():
    """didu → voice-once SKIP_PLAY → play reply with barge-in. Returns 'ok'|'barge'|'fail'."""
    global busy
    busy = True
    try:
        arm_post_end_guard()
        log("cue 「滴嘟」")
        kill_playback()
        play_blocking(didu_wav, allow_barge=False)
        drain_keys()

        env = os.environ.copy()
        env["USE_EXISTING_REC"] = "1"
        env["SKIP_PLAY"] = "1"
        env["GREET_ON_START"] = "0"
        env["REC_WAV"] = rec_wav
        env["REPLY_WAV"] = reply_wav
        log("bridge turn… (single)")
        proc = subprocess.Popen([voice_once], env=env)
        while proc.poll() is None:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                data = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not data:
                continue
            for typ, code, val in read_events(data):
                if typ == EV_KEY and val == 1:
                    if time.time() < ignore_keys_until:
                        log("ignore KEY bounce during post-end guard")
                        continue
                    log("BARGE-IN during bridge wait — abort turn, discard")
                    stop_proc(proc, signal.SIGTERM, 1.0)
                    kill_playback()
                    return "barge"
        if proc.returncode != 0:
            log(f"voice-once rc={proc.returncode}")
            return "fail"
        play = reply_wav + ".play.wav"
        if not os.path.isfile(play):
            play = reply_wav
        try:
            psz = os.path.getsize(play)
        except OSError:
            psz = 0
        log(f"play reply {play} ({psz}B)")
        return play_blocking(play, allow_barge=True)
    finally:
        busy = False
        drain_keys()
        arm_post_end_guard()

# --- main state machine ---
log(f"daemon mode={mode} event={ev_path} (KEY down edges)")
last_down_t = 0.0
rec_proc = None
rec_t0 = 0.0
state = "idle"  # idle | recording
utterances = 0

try:
    while True:
        # wait for next meaningful key edge
        timeout = None
        if state == "recording":
            # also enforce max record
            left = max_secs - (time.time() - rec_t0)
            if left <= 0:
                log("max record reached → end input")
                sz, held = stop_record(rec_proc, rec_t0)
                rec_proc = None
                state = "idle"
                if sz > 44 and held >= min_secs:
                    result = run_bridge_turn()
                    utterances += 1
                    if result == "barge":
                        # immediate new record
                        rec_proc, rec_t0 = start_record()
                        state = "recording"
                        continue
                    if run_mode == "once":
                        break
                else:
                    log("utt too short/empty — discard")
                continue
            wait = min(0.2, max(0.05, left))
        else:
            wait = 1.0

        r, _, _ = select.select([fd], [], [], wait)
        if not r:
            continue
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if not data:
            continue

        for typ, code, val in read_events(data):
            if typ != EV_KEY:
                continue
            # accept any key on this single-button node
            now = time.time()

            if mode == "hold":
                if val == 1 and state == "idle":
                    if now - last_down_t < debounce:
                        continue
                    last_down_t = now
                    rec_proc, rec_t0 = start_record()
                    state = "recording"
                elif val == 0 and state == "recording":
                    if now - rec_t0 < min_secs:
                        log("release too soon — keep recording")
                        continue
                    sz, held = stop_record(rec_proc, rec_t0)
                    rec_proc = None
                    state = "idle"
                    if sz <= 44:
                        log("empty — discard")
                        continue
                    result = run_bridge_turn()
                    utterances += 1
                    if result == "barge":
                        rec_proc, rec_t0 = start_record()
                        state = "recording"
                        continue
                    if run_mode == "once":
                        raise SystemExit(0)
                continue

            # --- toggle: only KEY down ---
            if val != 1:
                continue
            if now - last_down_t < debounce:
                continue
            if now < ignore_keys_until:
                continue
            if busy:
                log("ignore KEY — turn in flight")
                continue
            last_down_t = now

            if state == "idle":
                kill_playback()
                rec_proc, rec_t0 = start_record()
                state = "recording"
            elif state == "recording":
                if now - rec_t0 < min_secs:
                    log("2nd press too soon — ignore")
                    continue
                sz, held = stop_record(rec_proc, rec_t0)
                rec_proc = None
                state = "idle"
                if sz <= 44:
                    log("empty — discard")
                    continue
                result = run_bridge_turn()
                utterances += 1
                if result == "barge":
                    rec_proc, rec_t0 = start_record()
                    state = "recording"
                    continue
                if run_mode == "once":
                    raise SystemExit(0)

except KeyboardInterrupt:
    log("interrupted")
finally:
    stop_proc(rec_proc, signal.SIGINT, 1.0)
    kill_playback()
    os.close(fd)
    log(f"exit utterances={utterances}")
PY

log "daemon exited"
