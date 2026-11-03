#!/usr/bin/env bash
# Idle proactive nudge: POST /v1/proactive-tick → play if not cooldown-skipped.
#   PROACTIVE_IDLE_S=180  → callers sleep this many seconds between ticks
#   ./board-proactive-tick.sh
#   PROACTIVE_FORCE=1 ./board-proactive-tick.sh
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
TICK_PATH="${DSH_VOICE_PROACTIVE_PATH:-/v1/proactive-tick}"
PROACTIVE_FORCE="${PROACTIVE_FORCE:-0}"
TICK_WAV="${TICK_WAV:-/userdata/xiaozhi-cli/last-proactive.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"
TTS_SOX_GAIN="${TTS_SOX_GAIN:-1}"
AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"

SESSION_ID="${DSH_SESSION_ID:-}"
[[ -n "$SESSION_ID" ]] || die "DSH_SESSION_ID unset"
RAW_COOKIE="${DSH_MOBILE_COOKIE:-}"
[[ -n "$RAW_COOKIE" ]] || die "DSH_MOBILE_COOKIE unset"
if [[ "$RAW_COOKIE" == dsh_mobile=* ]]; then COOKIE_HEADER="$RAW_COOKIE"
else COOKIE_HEADER="dsh_mobile=${RAW_COOKIE}"; fi

command -v curl >/dev/null 2>&1 || die "need curl"
command -v python3 >/dev/null 2>&1 || die "need python3"
[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true

BODY="$(
	PROACTIVE_FORCE="$PROACTIVE_FORCE" DSH_SESSION_ID="$SESSION_ID" python3 -c '
import json, os
o = {"sessionId": os.environ["DSH_SESSION_ID"], "inject": True}
if os.environ.get("PROACTIVE_FORCE") in ("1", "true", "yes"):
    o["force"] = True
print(json.dumps(o, ensure_ascii=False))
'
)"

URL="${DSH_VOICE_BRIDGE_URL}${TICK_PATH}"
TMP_JSON="$(mktemp)"
HTTP=$(curl -sS -m "${VOICE_BRIDGE_TIMEOUT:-90}" -o "$TMP_JSON" -w "%{http_code}" \
	-X POST "$URL" \
	-H "Cookie: ${COOKIE_HEADER}" \
	-H "Origin: ${DSH_BASE_URL}" \
	-H "Content-Type: application/json; charset=utf-8" \
	-H "Accept: application/json" \
	--data-binary "$BODY") || HTTP="000"

if [[ "$HTTP" != "200" && "$HTTP" != "207" ]]; then
	echo "proactive: HTTP ${HTTP}" >&2
	head -c 200 "$TMP_JSON" >&2 || true
	rm -f "$TMP_JSON"
	exit 6
fi

SKIP="$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1],encoding="utf-8")); print("1" if j.get("skipped") else "0")' "$TMP_JSON")"
if [[ "$SKIP" = "1" ]]; then
	echo "proactive: skipped ($(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("reason",""))' "$TMP_JSON"))" >&2
	rm -f "$TMP_JSON"
	exit 0
fi

mkdir -p "$(dirname "$TICK_WAV")"
python3 -c 'import base64,json,sys; j=json.load(open(sys.argv[1],encoding="utf-8")); open(sys.argv[2],"wb").write(base64.b64decode(j["audio_b64"]))' \
	"$TMP_JSON" "$TICK_WAV"
echo "proactive: $(python3 -c 'import json,sys; print((json.load(open(sys.argv[1],encoding="utf-8")).get("text") or "")[:60])' "$TMP_JSON")" >&2
rm -f "$TMP_JSON"

RAW_WAV="${TICK_WAV%.wav}.raw.wav"
WAV_OUT="${TICK_WAV%.wav}.pcm.wav"
if head -c 4 "$TICK_WAV" | grep -q RIFF; then
	sox "$TICK_WAV" -r 48000 -c 2 -b 16 "$WAV_OUT" gain -n -3 gain "${TTS_SOX_GAIN}" 2>/dev/null || cp "$TICK_WAV" "$WAV_OUT"
	PLAY="$WAV_OUT"
else
	command -v mpg123 >/dev/null 2>&1 || die "need mpg123"
	mpg123 -q -w "$RAW_WAV" "$TICK_WAV"
	sox "$RAW_WAV" -r 48000 -c 2 -b 16 "$WAV_OUT" gain -n -3 gain "${TTS_SOX_GAIN}" 2>/dev/null
	PLAY="$WAV_OUT"
fi
aplay -D "$DEV" "$PLAY" >&2 || aplay -D "plughw:${CARD},0" "$PLAY" >&2
echo "proactive: done" >&2
