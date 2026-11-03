#!/usr/bin/env bash
# DEPRECATED for board VOICE_IN — use board-voice-once.sh (LAN :43128 /v1/voice-turn).
# This script no longer defaults to api.openai.com (unreachable / curl 6 from board).
#
# Prefer: VOICE_IN=1 ./board-dsh-chat.sh   or   ./board-voice-once.sh
# Legacy cloud ASR only if you explicitly set ASR_BASE_URL + ASR_API_KEY (not openai.com).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"
REC_SECS="${REC_SECS:-5}"
REC_WAV="${REC_WAV:-/userdata/xiaozhi-cli/last-utt.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"
# No OpenAI default — empty means redirect to LAN bridge
ASR_BASE_URL="${ASR_BASE_URL:-}"
ASR_BASE_URL="${ASR_BASE_URL%/}"
ASR_MODEL="${ASR_MODEL:-whisper-1}"
API_KEY="${ASR_API_KEY:-${OPENAI_API_KEY:-}}"

if [[ -z "$ASR_BASE_URL" ]]; then
	echo "ASR: OpenAI path disabled. Use LAN bridge:" >&2
	echo "  ./board-voice-once.sh" >&2
	echo "  or: VOICE_IN=1 ./board-dsh-chat.sh   # Enter = /v1/voice-turn" >&2
	if [[ -x "$SCRIPT_DIR/board-voice-once.sh" ]]; then
		echo "ASR: handing off to board-voice-once.sh…" >&2
		exec env GREET_ON_START="${GREET_ON_START:-0}" "$SCRIPT_DIR/board-voice-once.sh"
	fi
	exit 3
fi
if [[ "$ASR_BASE_URL" == *"api.openai.com"* ]]; then
	echo "ASR BLOCKER: api.openai.com blocked on board (curl 6). Use board-voice-once / VOICE_IN=1." >&2
	exit 3
fi

[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true

mkdir -p "$(dirname "$REC_WAV")"
rm -f "$REC_WAV"

echo "ASR: recording ${REC_SECS}s on $DEV → $REC_WAV (speak now)" >&2
arecord -D "$DEV" -f S16_LE -r 16000 -c 2 -d "$REC_SECS" "$REC_WAV" >&2
sz=$(wc -c <"$REC_WAV" | tr -d ' ')
[[ "${sz:-0}" -gt 44 ]] || { echo "ASR: empty wav" >&2; exit 2; }
echo "ASR: saved ${sz} bytes" >&2

if [[ -z "$API_KEY" ]]; then
	echo "ASR BLOCKER: ASR_API_KEY unset for custom ASR_BASE_URL=$ASR_BASE_URL" >&2
	exit 3
fi

TMP_JSON="$(mktemp)"
HTTP=$(curl -sS -m "${ASR_TIMEOUT:-60}" -o "$TMP_JSON" -w "%{http_code}" \
	-X POST "${ASR_BASE_URL}/audio/transcriptions" \
	-H "Authorization: Bearer ${API_KEY}" \
	-F "model=${ASR_MODEL}" \
	-F "file=@${REC_WAV};type=audio/wav" || echo "000")

if [[ "$HTTP" != "200" ]]; then
	echo "ASR HTTP $HTTP: $(head -c 400 "$TMP_JSON" 2>/dev/null)" >&2
	rm -f "$TMP_JSON"
	exit 4
fi

TEXT="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("text") or "").strip())' "$TMP_JSON")"
rm -f "$TMP_JSON"
[[ -n "$TEXT" ]] || { echo "ASR: empty transcript" >&2; exit 4; }
printf '%s\n' "$TEXT"
