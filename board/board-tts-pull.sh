#!/usr/bin/env bash
# 主动播：POST /v1/speak (Xiaoxuan 御姐) → aplay CON24. No mic.
#
#   ./board-tts-pull.sh '你好，我是大飞鱼'
#   SPEAK_INJECT=1 ./board-tts-pull.sh '…'   # also session.prompt into Desktop
#   DSH_TTS_VOICE=zh-CN-XiaoxuanNeural …     # default
#
# Body: {text, sessionId?, voice?, inject?}  Same cookie as chat.
# Loudness: TTS_SOX_GAIN default 1. See docs/dsh-voice-bridge.md.
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
DSH_VOICE_SPEAK_PATH="${DSH_VOICE_SPEAK_PATH:-/v1/speak}"
DSH_TTS_VOICE="${DSH_TTS_VOICE:-zh-CN-XiaoxuanNeural}"
SPEAK_INJECT="${SPEAK_INJECT:-0}"
TTS_WAV="${TTS_WAV:-/userdata/xiaozhi-cli/last-speak.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"
TTS_SOX_GAIN="${TTS_SOX_GAIN:-1}"
AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"

TEXT="${SPEAK_TEXT:-${*:-}}"
if [[ -z "$TEXT" && ! -t 0 ]]; then
	TEXT="$(cat)"
fi
TEXT="$(printf '%s' "$TEXT" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[[ -n "$TEXT" ]] || die "usage: $0 '要播的文本'"

RAW_COOKIE="${DSH_MOBILE_COOKIE:-}"
[[ -n "$RAW_COOKIE" ]] || die "DSH_MOBILE_COOKIE unset — pair first"
if [[ "$RAW_COOKIE" == dsh_mobile=* ]]; then
	COOKIE_HEADER="$RAW_COOKIE"
else
	COOKIE_HEADER="dsh_mobile=${RAW_COOKIE}"
fi

command -v curl >/dev/null 2>&1 || die "need curl"
command -v aplay >/dev/null 2>&1 || die "need aplay"
[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true

mkdir -p "$(dirname "$TTS_WAV")"
BODY="$(
	SPEAK_INJECT="$SPEAK_INJECT" DSH_TTS_VOICE="$DSH_TTS_VOICE" DSH_SESSION_ID="${DSH_SESSION_ID:-}" \
		python3 -c '
import json, os, sys
o = {"text": sys.argv[1], "voice": os.environ.get("DSH_TTS_VOICE") or "zh-CN-XiaoxuanNeural"}
sid = os.environ.get("DSH_SESSION_ID") or ""
if sid:
    o["sessionId"] = sid
if os.environ.get("SPEAK_INJECT") in ("1", "true", "yes"):
    o["inject"] = True
print(json.dumps(o, ensure_ascii=False))
' "$TEXT"
)"

pick_paths() {
	echo "${DSH_VOICE_SPEAK_PATH}"
	echo "/v1/speak"
	echo "/v1/tts"
}

TMP_HDR="$(mktemp)"
HTTP="000"
CT=""
USED_PATH=""
for path in $(pick_paths); do
	URL="${DSH_VOICE_BRIDGE_URL}${path}"
	HTTP=$(curl -sS -m "${VOICE_BRIDGE_TIMEOUT:-60}" -D "$TMP_HDR" -o "$TTS_WAV" -w "%{http_code}" \
		-X POST "$URL" \
		-H "Cookie: ${COOKIE_HEADER}" \
		-H "Origin: ${DSH_BASE_URL}" \
		-H "Content-Type: application/json; charset=utf-8" \
		--data-binary "$BODY") || HTTP="000"
	if [[ "$HTTP" = "404" ]]; then
		continue
	fi
	USED_PATH="$path"
	CT=$(grep -i '^Content-Type:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print tolower($0)}' || true)
	break
done
rm -f "$TMP_HDR"

if [[ -z "$USED_PATH" || "$HTTP" = "000" || "$HTTP" = "404" ]]; then
	die "no speak/tts endpoint on ${DSH_VOICE_BRIDGE_URL} (tried speak/say/tts)"
fi
# inject=true returns JSON (200/207) with audio_b64 — still playable
if [[ "$HTTP" != "200" && "$HTTP" != "207" ]]; then
	echo "tts-pull: HTTP ${HTTP} via ${USED_PATH}" >&2
	head -c 300 "$TTS_WAV" 2>/dev/null | tr -d '\000' >&2 || true
	echo >&2
	exit 6
fi

echo "tts-pull: got HTTP ${HTTP} from ${USED_PATH} ($(wc -c <"$TTS_WAV" | tr -d ' ')B)" >&2

# Unwrap JSON envelope (inject / format=json)
if echo "$CT" | grep -q 'application/json' || head -c 1 "$TTS_WAV" | grep -q '{'; then
	echo "tts-pull: JSON reply — extracting audio_b64…" >&2
	python3 - "$TTS_WAV" "${TTS_WAV}.bin" <<'PY' || die "JSON audio extract failed"
import json, base64, sys
src, dst = sys.argv[1], sys.argv[2]
j = json.load(open(src, encoding="utf-8"))
if j.get("inject_error"):
    print("tts-pull: inject_error:", j.get("inject_error"), file=sys.stderr)
if j.get("injected"):
    print("tts-pull: injected into Desktop session", file=sys.stderr)
b64 = j.get("audio_b64") or j.get("reply_wav_b64") or j.get("wav_b64")
if not b64:
    raise SystemExit("no audio_b64 in JSON: " + ",".join(j.keys()))
open(dst, "wb").write(base64.b64decode(b64))
PY
	mv -f "${TTS_WAV}.bin" "$TTS_WAV"
	CT="audio/mpeg"
fi

loud_48k() {
	local inn="$1" outn="$2"
	sox "$inn" -r 48000 -c 2 -b 16 "$outn" gain -n -3 gain "${TTS_SOX_GAIN}" 2>/dev/null \
		|| sox "$inn" -r 48000 -c 2 -b 16 "$outn" vol 1.4 2>/dev/null
}

PLAY_WAV="$TTS_WAV"
WAV_OUT="${TTS_WAV%.wav}.pcm.wav"
RAW_WAV="${TTS_WAV%.wav}.raw.wav"
magic=$(head -c 4 "$TTS_WAV" 2>/dev/null | tr -d '\0' || true)
is_mp3=0
echo "$CT" | grep -qE 'audio/mpeg|audio/mp3' && is_mp3=1
head -c 3 "$TTS_WAV" 2>/dev/null | grep -q 'ID3' && is_mp3=1
b0=$(od -An -tx1 -N1 "$TTS_WAV" 2>/dev/null | tr -d ' \n')
[[ "$b0" = "ff" ]] && is_mp3=1
[[ "$magic" = "RIFF" ]] && is_mp3=0

if [[ "$is_mp3" = "1" ]]; then
	command -v mpg123 >/dev/null 2>&1 || die "need mpg123 for Edge mp3"
	mpg123 -q -w "$RAW_WAV" "$TTS_WAV" || die "mpg123 decode failed"
	loud_48k "$RAW_WAV" "$WAV_OUT" || die "sox resample failed"
	PLAY_WAV="$WAV_OUT"
elif [[ "$magic" = "RIFF" ]]; then
	loud_48k "$TTS_WAV" "$WAV_OUT" && PLAY_WAV="$WAV_OUT"
fi

echo "tts-pull: playing ${PLAY_WAV}" >&2
AUDIO_UP_QUIET=1 "$AUDIO_UP" 2>/dev/null || true
if ! aplay -D "$DEV" "$PLAY_WAV" >&2; then
	aplay -D "plughw:${CARD},0" "$PLAY_WAV" >&2 || die "aplay failed"
fi
echo "tts-pull: done" >&2
