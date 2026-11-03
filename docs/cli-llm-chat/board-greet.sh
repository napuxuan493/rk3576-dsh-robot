#!/usr/bin/env bash
# After pair / chat start: one proactive greet via PC bridge /v1/greet → aplay CON24.
# Uses same DSH_MOBILE_COOKIE + DSH_SESSION_ID. inject=true on bridge (session history).
#
#   ./board-greet.sh
#   GREET_FORCE=1 ./board-greet.sh          # ignore once-per-session skip
#   GREET_ON_START=0 …                      # callers skip invoking this
#
# See docs/dsh-voice-bridge.md §greet / proactive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

_PRE_BRIDGE="${DSH_VOICE_BRIDGE_URL-}"
_PRE_COOKIE="${DSH_MOBILE_COOKIE-}"
_PRE_BASE="${DSH_BASE_URL-}"
_PRE_SESSION="${DSH_SESSION_ID-}"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a
[[ -n "${_PRE_BRIDGE}" ]] && DSH_VOICE_BRIDGE_URL="$_PRE_BRIDGE"
[[ -n "${_PRE_COOKIE}" ]] && DSH_MOBILE_COOKIE="$_PRE_COOKIE"
[[ -n "${_PRE_BASE}" ]] && DSH_BASE_URL="$_PRE_BASE"
[[ -n "${_PRE_SESSION}" ]] && DSH_SESSION_ID="$_PRE_SESSION"
unset _PRE_BRIDGE _PRE_COOKIE _PRE_BASE _PRE_SESSION

DSH_BASE_URL="${DSH_BASE_URL:-http://192.168.137.1:43127}"
DSH_BASE_URL="${DSH_BASE_URL%/}"
DSH_VOICE_BRIDGE_URL="${DSH_VOICE_BRIDGE_URL:-http://192.168.137.1:43128}"
DSH_VOICE_BRIDGE_URL="${DSH_VOICE_BRIDGE_URL%/}"
GREET_PATH="${DSH_VOICE_GREET_PATH:-/v1/greet}"
GREET_FORCE="${GREET_FORCE:-0}"
GREET_WAV="${GREET_WAV:-/userdata/xiaozhi-cli/last-greet.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"
TTS_SOX_GAIN="${TTS_SOX_GAIN:-1}"
AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"

SESSION_ID="${DSH_SESSION_ID:-}"
[[ -n "$SESSION_ID" ]] || die "DSH_SESSION_ID unset"

RAW_COOKIE="${DSH_MOBILE_COOKIE:-}"
[[ -n "$RAW_COOKIE" ]] || die "DSH_MOBILE_COOKIE unset — pair first"
if [[ "$RAW_COOKIE" == dsh_mobile=* ]]; then
	COOKIE_HEADER="$RAW_COOKIE"
else
	COOKIE_HEADER="dsh_mobile=${RAW_COOKIE}"
fi

command -v curl >/dev/null 2>&1 || die "need curl"
command -v python3 >/dev/null 2>&1 || die "need python3"
command -v aplay >/dev/null 2>&1 || die "need aplay"
[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true

BODY="$(
	GREET_FORCE="$GREET_FORCE" DSH_SESSION_ID="$SESSION_ID" python3 -c '
import json, os
o = {"sessionId": os.environ["DSH_SESSION_ID"], "inject": True}
if os.environ.get("GREET_FORCE") in ("1", "true", "yes"):
    o["force"] = True
print(json.dumps(o, ensure_ascii=False))
'
)"

URL="${DSH_VOICE_BRIDGE_URL}${GREET_PATH}"
echo "greet: POST ${URL} session=${SESSION_ID}" >&2
TMP_JSON="$(mktemp)"
HTTP=$(curl -sS -m "${VOICE_BRIDGE_TIMEOUT:-90}" -o "$TMP_JSON" -w "%{http_code}" \
	-X POST "$URL" \
	-H "Cookie: ${COOKIE_HEADER}" \
	-H "Origin: ${DSH_BASE_URL}" \
	-H "Content-Type: application/json; charset=utf-8" \
	-H "Accept: application/json" \
	--data-binary "$BODY") || HTTP="000"

if [[ "$HTTP" != "200" && "$HTTP" != "207" ]]; then
	echo "greet: HTTP ${HTTP}" >&2
	head -c 300 "$TMP_JSON" 2>/dev/null | tr -d '\000' >&2 || true
	echo >&2
	rm -f "$TMP_JSON"
	exit 6
fi

SKIP="$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1],encoding="utf-8")); print("1" if j.get("skipped") else "0")' "$TMP_JSON")"
if [[ "$SKIP" = "1" ]]; then
	REASON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("reason",""))' "$TMP_JSON")"
	echo "greet: skipped (${REASON})" >&2
	rm -f "$TMP_JSON"
	exit 0
fi

mkdir -p "$(dirname "$GREET_WAV")"
python3 - "$TMP_JSON" "$GREET_WAV" <<'PY'
import base64, json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
b64 = j.get("audio_b64") or j.get("reply_wav_b64")
if not b64:
    raise SystemExit("no audio_b64 in greet response")
open(sys.argv[2], "wb").write(base64.b64decode(b64))
print("greet text:", (j.get("text") or "")[:80], file=sys.stderr)
print("greet injected:", j.get("injected"), "voice:", j.get("voice"), file=sys.stderr)
PY
rm -f "$TMP_JSON"

loud_48k() {
	local inn="$1" outn="$2"
	sox "$inn" -r 48000 -c 2 -b 16 "$outn" gain -n -3 gain "${TTS_SOX_GAIN}" 2>/dev/null \
		|| sox "$inn" -r 48000 -c 2 -b 16 "$outn" vol 1.4 2>/dev/null
}

PLAY_WAV="$GREET_WAV"
WAV_OUT="${GREET_WAV%.wav}.pcm.wav"
RAW_WAV="${GREET_WAV%.wav}.raw.wav"
magic=$(head -c 4 "$GREET_WAV" 2>/dev/null | tr -d '\0' || true)
if [[ "$magic" = "RIFF" ]]; then
	loud_48k "$GREET_WAV" "$WAV_OUT" && PLAY_WAV="$WAV_OUT"
else
	command -v mpg123 >/dev/null 2>&1 || die "need mpg123 for Edge mp3"
	mpg123 -q -w "$RAW_WAV" "$GREET_WAV" || die "mpg123 decode failed"
	loud_48k "$RAW_WAV" "$WAV_OUT" || die "sox resample failed"
	PLAY_WAV="$WAV_OUT"
fi

echo "greet: playing ${PLAY_WAV}" >&2
AUDIO_UP_QUIET=1 "$AUDIO_UP" 2>/dev/null || true
aplay -D "$DEV" "$PLAY_WAV" >&2 || aplay -D "plughw:${CARD},0" "$PLAY_WAV" >&2 || die "aplay failed"
echo "greet: done" >&2
