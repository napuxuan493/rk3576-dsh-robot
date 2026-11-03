#!/usr/bin/env bash
# Sync HDMI eyes with voice TTS (parse [emotion:…] / bridge x-emotion).
# Uses /userdata/dafeiyu-hdmi + animation-assets. No flash.
#
#   board-emotion-voice.sh ensure              # start API+fb if down
#   board-emotion-voice.sh parse '…[emotion:happy]'
#   board-emotion-voice.sh play-start [name] [hold_s]
#   board-emotion-voice.sh play-end           # idle after TTS
#   board-emotion-voice.sh set <name> [hold]
#
# Env: EMOTION_ENABLE=0 to disable; EMOTION_PORT=8765;
#      EMOTION_START_SH / EMOTION_SET_SH under /userdata/dafeiyu-hdmi/
set -euo pipefail

EMOTION_ENABLE="${EMOTION_ENABLE:-1}"
EMOTION_PORT="${EMOTION_PORT:-8765}"
EMOTION_START_SH="${EMOTION_START_SH:-/userdata/dafeiyu-hdmi/board-hdmi-emotion-start.sh}"
EMOTION_SET_SH="${EMOTION_SET_SH:-/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh}"
EMOTION_IDLE="${EMOTION_IDLE:-idle}"
EMOTION_SPEAK_FALLBACK="${EMOTION_SPEAK_FALLBACK:-speaking}"

die() { echo "emotion-voice: ERROR: $*" >&2; exit 1; }
log() { echo "emotion-voice: $*" >&2; }

[[ "$EMOTION_ENABLE" == "1" ]] || { [[ "${1:-}" == "parse" ]] && echo ""; exit 0; }

api_up() {
	curl -sS -m 1 "http://127.0.0.1:${EMOTION_PORT}/api/emotion" >/dev/null 2>&1
}

cmd_ensure() {
	if api_up; then
		return 0
	fi
	[[ -x "$EMOTION_START_SH" ]] || { log "missing $EMOTION_START_SH"; return 0; }
	log "starting HDMI emotion UI (BACKEND=fb)…"
	BACKEND=fb "$EMOTION_START_SH" >/tmp/emotion-voice-start.log 2>&1 || {
		log "start failed (see /tmp/emotion-voice-start.log)"
		return 0
	}
	# wait briefly for API
	local i=0
	while [[ $i -lt 30 ]]; do
		api_up && return 0
		sleep 0.2
		i=$((i + 1))
	done
	log "API not ready after start"
	return 0
}

cmd_parse() {
	local text="${1:-}"
	REPLY_TEXT="$text" python3 - <<'PY'
import os, re
raw = os.environ.get("REPLY_TEXT") or ""
SPECIAL = {
    "happy", "excited", "love", "surprised", "confused", "thinking",
    "sad", "angry", "sleepy", "sleep", "wink", "dizzy", "blink",
    "look_around", "boot", "shutdown", "speaking", "listening", "idle",
}
tag = None
for m in re.finditer(r"\[emotion:\s*([A-Za-z0-9_]+)\s*\]", raw, re.I):
    tag = m.group(1).lower()
for m in re.finditer(r"<!--\s*emotion:\s*([A-Za-z0-9_]+)\s*-->", raw, re.I):
    tag = m.group(1).lower()
if tag in SPECIAL:
    print(tag)
else:
    print("")
PY
}

cmd_set() {
	local s="${1:-idle}"
	local hold="${2:-}"
	local force="${3:-}"
	cmd_ensure
	local body
	if [[ -n "$hold" && -n "$force" ]]; then
		body=$(printf '{"state":"%s","hold":%s,"force":true}' "$s" "$hold")
	elif [[ -n "$hold" ]]; then
		body=$(printf '{"state":"%s","hold":%s}' "$s" "$hold")
	elif [[ -n "$force" ]]; then
		body=$(printf '{"state":"%s","force":true}' "$s")
	else
		body=$(printf '{"state":"%s"}' "$s")
	fi
	if curl -sS -m 2 -X POST "http://127.0.0.1:${EMOTION_PORT}/api/emotion" \
		-H 'Content-Type: application/json' --data-binary "$body" >/dev/null 2>&1; then
		log "set $s hold=${hold:-none} force=${force:-0}"
		return 0
	fi
	if [[ -x "$EMOTION_SET_SH" ]]; then
		if [[ -n "$hold" ]]; then
			"$EMOTION_SET_SH" "$s" "$hold" >/dev/null 2>&1 || true
		else
			"$EMOTION_SET_SH" "$s" >/dev/null 2>&1 || true
		fi
		log "set via script $s"
	fi
	return 0
}

# During TTS: prefer tagged emotion; else speaking. hold ≈ clip length.
# Always force so a leftover special lock cannot ignore this turn's eyes.
cmd_play_start() {
	local emo="${1:-}"
	local hold="${2:-30}"
	[[ -n "$emo" ]] || emo="$EMOTION_SPEAK_FALLBACK"
	# clamp hold
	hold=$(python3 -c "print(max(1.0, min(120.0, float('${hold}'))))" 2>/dev/null || echo 30)
	cmd_set "$emo" "$hold" force
}

cmd_play_end() {
	# force: idle is priority 0 and cannot preempt special lock otherwise
	cmd_set "$EMOTION_IDLE" "0.5" force
}

case "${1:-}" in
ensure) shift; cmd_ensure "$@" ;;
parse) shift; cmd_parse "${1:-}" ;;
set) shift; cmd_set "$@" ;;
play-start) shift; cmd_play_start "${1:-}" "${2:-30}" ;;
play-end) shift; cmd_play_end ;;
*)
	echo "Usage: $0 ensure|parse|set|play-start|play-end" >&2
	exit 2
	;;
esac
