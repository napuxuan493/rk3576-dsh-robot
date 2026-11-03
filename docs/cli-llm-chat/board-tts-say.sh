#!/usr/bin/env bash
# TTS text → wav → aplay on CON24 (after board-audio-up).
# Usage: board-tts-say.sh "你好"   or   echo hi | board-tts-say.sh
# Env:
#   TTS_API_KEY / OPENAI_API_KEY
#   TTS_BASE_URL (default https://api.openai.com/v1)
#   TTS_MODEL    (default tts-1)
#   TTS_VOICE    (default alloy)
#   TTS_WAV      (default /userdata/xiaozhi-cli/last-tts.wav)
#   TTS_STUB=1   — no cloud: print text + short 880Hz beep (proves path)
# Exit: 0=played; 3=no key (blocker); 4=HTTP fail; 2=play fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"
TTS_WAV="${TTS_WAV:-/userdata/xiaozhi-cli/last-tts.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"
TTS_BASE_URL="${TTS_BASE_URL:-https://api.openai.com/v1}"
TTS_BASE_URL="${TTS_BASE_URL%/}"
TTS_MODEL="${TTS_MODEL:-tts-1}"
TTS_VOICE="${TTS_VOICE:-alloy}"
API_KEY="${TTS_API_KEY:-${OPENAI_API_KEY:-}}"

TEXT="${*:-}"
if [[ -z "$TEXT" && ! -t 0 ]]; then
	TEXT="$(cat)"
fi
TEXT="$(printf '%s' "$TEXT" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[[ -n "$TEXT" ]] || { echo "TTS: empty text" >&2; exit 1; }

[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true
mkdir -p "$(dirname "$TTS_WAV")"

play_wav() {
	local f="$1"
	aplay -D "$DEV" "$f" >&2
}

if [[ -z "$API_KEY" ]]; then
	if [[ "${TTS_STUB:-0}" = "1" ]]; then
		echo "TTS STUB (no API key): $TEXT" >&2
		# Audible path check — not speech
		sox -n -r 48000 -c 2 -b 16 "$TTS_WAV" synth 0.35 sine 880 vol 0.5
		play_wav "$TTS_WAV"
		exit 0
	fi
	echo "TTS BLOCKER: set TTS_API_KEY or OPENAI_API_KEY in $SCRIPT_DIR/.env (OpenAI-compatible /v1/audio/speech). Or TTS_STUB=1 for beep-only. Text was: $TEXT" >&2
	exit 3
fi

# Prefer wav so aplay works without ffmpeg
BODY="$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"voice":sys.argv[2],"input":sys.argv[3],"response_format":"wav"}, ensure_ascii=False))' \
	"$TTS_MODEL" "$TTS_VOICE" "$TEXT")"

HTTP=$(curl -sS -m "${TTS_TIMEOUT:-60}" -o "$TTS_WAV" -w "%{http_code}" \
	-X POST "${TTS_BASE_URL}/audio/speech" \
	-H "Authorization: Bearer ${API_KEY}" \
	-H "Content-Type: application/json" \
	--data-binary "$BODY" || echo "000")

if [[ "$HTTP" != "200" ]]; then
	echo "TTS HTTP $HTTP: $(head -c 400 "$TTS_WAV" 2>/dev/null)" >&2
	exit 4
fi

# Sanity: RIFF/WAVE or raw pcm fallback
if ! head -c 4 "$TTS_WAV" | grep -q RIFF; then
	echo "TTS: response not WAV (got $(head -c 16 "$TTS_WAV" | od -An -tx1 | head -1)); trying aplay anyway" >&2
fi

echo "TTS: playing $(wc -c <"$TTS_WAV" | tr -d ' ') bytes on $DEV" >&2
play_wav "$TTS_WAV"
