#!/usr/bin/env bash
# CON24 one voice turn via Windows LAN voice bridge (NOT DeepSeek speech APIs).
#
# Flow: board-audio-up → arecord → POST wav to bridge → receive reply wav → aplay
# Auth/session: same DSH_MOBILE_COOKIE + DSH_SESSION_ID as board-dsh-chat.sh
#
# Env (see docs/dsh-voice-bridge.md):
#   DSH_VOICE_BRIDGE_URL   default http://192.168.137.1:43128
#   DSH_VOICE_TURN_PATH    default /v1/voice-turn
#   DSH_VOICE_HEALTH_PATH  default /health
#   REC_SECS               default 5
#   REC_WAV / REPLY_WAV    under /userdata/xiaozhi-cli/
#
#   ./board-voice-once.sh           # full turn (mic → reply)
#   VOICE_BRIDGE_DRY=1 …            # record only + print curl that would run
# 主动播 (no mic): use ./board-tts-pull.sh '文本'  (POST /v1/tts; /v1/speak when ready)
#   or: SPEAK_TEXT='你好' ./board-voice-once.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

# Delegate 主动播 to board-tts-pull.sh
if [[ -n "${SPEAK_TEXT:-}" ]]; then
	exec "$SCRIPT_DIR/board-tts-pull.sh" "$SPEAK_TEXT"
fi
if [[ "${1:-}" == "--speak" ]]; then
	shift
	exec "$SCRIPT_DIR/board-tts-pull.sh" "$@"
fi


_PRE_BASE="${DSH_BASE_URL-}"
_PRE_COOKIE="${DSH_MOBILE_COOKIE-}"
_PRE_SESSION="${DSH_SESSION_ID-}"
_PRE_BRIDGE="${DSH_VOICE_BRIDGE_URL-}"

# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a

[[ -n "${_PRE_BASE}" ]] && DSH_BASE_URL="$_PRE_BASE"
[[ -n "${_PRE_COOKIE}" ]] && DSH_MOBILE_COOKIE="$_PRE_COOKIE"
[[ -n "${_PRE_SESSION}" ]] && DSH_SESSION_ID="$_PRE_SESSION"
[[ -n "${_PRE_BRIDGE}" ]] && DSH_VOICE_BRIDGE_URL="$_PRE_BRIDGE"
unset _PRE_BASE _PRE_COOKIE _PRE_SESSION _PRE_BRIDGE

DSH_BASE_URL="${DSH_BASE_URL:-http://192.168.137.1:43127}"
DSH_BASE_URL="${DSH_BASE_URL%/}"
DSH_VOICE_BRIDGE_URL="${DSH_VOICE_BRIDGE_URL:-http://192.168.137.1:43128}"
DSH_VOICE_BRIDGE_URL="${DSH_VOICE_BRIDGE_URL%/}"
DSH_VOICE_TURN_PATH="${DSH_VOICE_TURN_PATH:-/v1/voice-turn}"
DSH_VOICE_HEALTH_PATH="${DSH_VOICE_HEALTH_PATH:-/health}"
REC_SECS="${REC_SECS:-5}"
REC_WAV="${REC_WAV:-/userdata/xiaozhi-cli/last-utt.wav}"
REPLY_WAV="${REPLY_WAV:-/userdata/xiaozhi-cli/last-reply.wav}"
CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"

AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"
RAW_COOKIE="${DSH_MOBILE_COOKIE:-}"
[[ -n "$RAW_COOKIE" ]] || die "DSH_MOBILE_COOKIE unset — pair first (./board-dsh-pair-url.sh)"
if [[ "$RAW_COOKIE" == dsh_mobile=* ]]; then
	COOKIE_HEADER="$RAW_COOKIE"
else
	COOKIE_HEADER="dsh_mobile=${RAW_COOKIE}"
fi
SESSION_ID="${DSH_SESSION_ID:-}"
[[ -n "$SESSION_ID" ]] || die "DSH_SESSION_ID unset — pin same session as board-dsh-chat.sh"

command -v curl >/dev/null 2>&1 || die "need curl"
command -v arecord >/dev/null 2>&1 || die "need arecord"
command -v aplay >/dev/null 2>&1 || die "need aplay"

[[ -x "$AUDIO_UP" ]] && AUDIO_UP_QUIET=1 "$AUDIO_UP" || true

TURN_URL="${DSH_VOICE_BRIDGE_URL}${DSH_VOICE_TURN_PATH}"
HEALTH_URL="${DSH_VOICE_BRIDGE_URL}${DSH_VOICE_HEALTH_PATH}"

echo "voice-once: bridge=${DSH_VOICE_BRIDGE_URL} session=${SESSION_ID}" >&2

# --- health (soft) ---
HC=$(curl -sS -m 3 -o /tmp/voice-bridge-health.txt -w "%{http_code}" "$HEALTH_URL" 2>/dev/null) || HC="000"
if [[ "$HC" != "200" ]]; then
	# try bare root as alternate
	HC2=$(curl -sS -m 3 -o /tmp/voice-bridge-health.txt -w "%{http_code}" "${DSH_VOICE_BRIDGE_URL}/" 2>/dev/null) || HC2="000"
	if [[ "$HC2" != "200" ]]; then
		echo "voice-once: bridge not reachable (health HTTP ${HC}, / HTTP ${HC2})." >&2
		echo "  Expect Windows LAN voice bridge on ${DSH_VOICE_BRIDGE_URL}" >&2
		echo "  (wraps dsh-voice-mode + session.prompt). See docs/dsh-voice-bridge.md" >&2
		echo "  Text chat still works via ${DSH_BASE_URL}/api/rpc when Desktop is up." >&2
		[[ "${VOICE_BRIDGE_DRY:-0}" = "1" ]] || exit 5
	fi
fi

# One greet before first mic turn (GREET_ON_START=0 to skip; once/session on bridge)
GREET_ON_START="${GREET_ON_START:-1}"
if [[ "$GREET_ON_START" == "1" && -x "$SCRIPT_DIR/board-greet.sh" && "${VOICE_BRIDGE_DRY:-0}" != "1" ]]; then
	export DSH_SESSION_ID="$SESSION_ID" DSH_VOICE_BRIDGE_URL DSH_BASE_URL DSH_MOBILE_COOKIE
	"$SCRIPT_DIR/board-greet.sh" || echo "voice-once: greet failed (continuing)" >&2
fi

# --- record (or reuse PTT / external wav) ---
mkdir -p "$(dirname "$REC_WAV")" "$(dirname "$REPLY_WAV")"
if [[ "${USE_EXISTING_REC:-0}" == "1" ]]; then
	[[ -f "$REC_WAV" ]] || die "USE_EXISTING_REC=1 but missing $REC_WAV"
	sz=$(wc -c <"$REC_WAV" | tr -d ' ')
	[[ "${sz:-0}" -gt 44 ]] || die "empty existing recording ($REC_WAV)"
	echo "voice-once: using existing rec ${sz}B ($REC_WAV)" >&2
	rm -f "$REPLY_WAV"
else
	rm -f "$REC_WAV" "$REPLY_WAV"
	echo "voice-once: recording ${REC_SECS}s on ${DEV} — speak now" >&2
	arecord -D "$DEV" -f S16_LE -r 16000 -c 2 -d "$REC_SECS" "$REC_WAV" >&2
	sz=$(wc -c <"$REC_WAV" | tr -d ' ')
	[[ "${sz:-0}" -gt 44 ]] || die "empty recording ($REC_WAV)"
fi

if [[ "${VOICE_BRIDGE_DRY:-0}" = "1" ]]; then
	echo "voice-once DRY: would POST ${sz}B wav → ${TURN_URL}" >&2
	echo "curl -sS -m 120 -X POST '${TURN_URL}' -H 'Cookie: dsh_mobile=***' -F 'sessionId=${SESSION_ID}' -F 'file=@${REC_WAV};type=audio/wav' -o '${REPLY_WAV}'" >&2
	exit 0
fi

# --- POST wav; expect reply audio/wav (or JSON — see bridge doc) ---
# Placeholder contract (adjust when Windows publishes finals):
#   multipart: file=<wav>, sessionId=<id>
#   Cookie: dsh_mobile=…  (same as chat)
#   200 + Content-Type audio/wav|audio/mpeg → save & play
#   200 + application/json → { "audio_url"|"reply_wav_b64"|"reply_path" … }
TMP_HDR="$(mktemp)"
# --http1.1 + fail on incomplete Content-Length bodies; wait for full mp3/wav
HTTP=$(curl -sS --http1.1 -m "${VOICE_BRIDGE_TIMEOUT:-180}" -D "$TMP_HDR" -o "$REPLY_WAV" -w "%{http_code}" \
	-X POST "$TURN_URL" \
	-H "Cookie: ${COOKIE_HEADER}" \
	-H "Origin: ${DSH_BASE_URL}" \
	-H "Accept: audio/mpeg, audio/wav, */*;q=0.1" \
	-F "sessionId=${SESSION_ID}" \
	-F "file=@${REC_WAV};type=audio/wav;filename=utt.wav") || HTTP="000"

CT=$(grep -i '^Content-Type:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print tolower($0)}' || true)
CL=$(grep -i '^Content-Length:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
XENG=$(grep -i '^x-tts-engine:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
XBYTES=$(grep -i '^x-tts-bytes:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
XCHARS=$(grep -i '^x-reply-chars:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
XEMO=$(grep -i '^x-emotion:' "$TMP_HDR" | tail -1 | tr -d '\r' | awk '{print tolower($2)}' || true)
# keep headers for optional reply-text decode; remove after JSON branch
REPLY_HDR="$TMP_HDR"

if [[ "$HTTP" != "200" ]]; then
	echo "voice-once: bridge turn HTTP ${HTTP}" >&2
	# show small body if looks like text error (no secrets)
	if head -c 4 "$REPLY_WAV" 2>/dev/null | grep -qv RIFF; then
		head -c 400 "$REPLY_WAV" 2>/dev/null | tr -d '\000' >&2 || true
		echo >&2
	fi
	rm -f "$REPLY_HDR"
	exit 6
fi

got=$(wc -c <"$REPLY_WAV" | tr -d ' ')
if [[ -n "${CL:-}" && "$CL" =~ ^[0-9]+$ && "$got" -ne "$CL" ]]; then
	die "incomplete download: got ${got}B Content-Length=${CL} (early close?)"
fi
if [[ -n "${XBYTES:-}" && "$XBYTES" =~ ^[0-9]+$ && "$got" -ne "$XBYTES" ]]; then
	die "incomplete download: got ${got}B x-tts-bytes=${XBYTES}"
fi
echo "voice-once: got ${got}B engine=${XENG:-?} reply_chars=${XCHARS:-?} emotion=${XEMO:-?} cl=${CL:-chunked}" >&2

EMOTION_HELPER="${EMOTION_HELPER:-$SCRIPT_DIR/board-emotion-voice.sh}"
VOICE_EMOTION="${XEMO:-}"

# JSON envelope fallback
if echo "$CT" | grep -q 'application/json' || head -c 1 "$REPLY_WAV" | grep -q '{'; then
	echo "voice-once: JSON reply — resolving audio…" >&2
	python3 - "$REPLY_WAV" "$REPLY_WAV.out" "${REPLY_WAV}.emotion.txt" <<'PY' || die "JSON audio extract failed"
import json, base64, sys, urllib.request, os, re
src, dst, emo_path = sys.argv[1], sys.argv[2], sys.argv[3]
j = json.load(open(src, encoding="utf-8"))
# emotion from JSON reply_text / emotion field
rt = j.get("reply_text") or j.get("text") or ""
emo = (j.get("emotion") or "").strip().lower()
if not emo and rt:
    tag = None
    for m in re.finditer(r"\[emotion:\s*([A-Za-z0-9_]+)\s*\]", rt, re.I):
        tag = m.group(1).lower()
    for m in re.finditer(r"<!--\s*emotion:\s*([A-Za-z0-9_]+)\s*-->", rt, re.I):
        tag = m.group(1).lower()
    emo = tag or ""
open(emo_path, "w", encoding="utf-8").write(emo)
b64 = j.get("reply_wav_b64") or j.get("audio_b64") or j.get("wav_b64")
url = j.get("audio_url") or j.get("reply_url") or j.get("url")
path = j.get("reply_path") or j.get("audio_path")
if b64:
    open(dst, "wb").write(base64.b64decode(b64))
elif url:
    if url.startswith("/"):
        base = os.environ.get("DSH_VOICE_BRIDGE_URL", "http://192.168.137.1:43128").rstrip("/")
        url = base + url
    urllib.request.urlretrieve(url, dst)
elif path and os.path.isfile(path):
    open(dst, "wb").write(open(path, "rb").read())
else:
    raise SystemExit("no audio field in JSON: " + ",".join(j.keys()))
PY
	mv -f "$REPLY_WAV.out" "$REPLY_WAV"
	if [[ -z "$VOICE_EMOTION" && -f "${REPLY_WAV}.emotion.txt" ]]; then
		VOICE_EMOTION=$(tr -d '\r\n' <"${REPLY_WAV}.emotion.txt")
	fi
fi
rm -f "$REPLY_HDR"
# persist for PTT SKIP_PLAY path
printf '%s' "${VOICE_EMOTION:-}" >"${REPLY_WAV}.emotion"
[[ -n "${VOICE_EMOTION:-}" ]] && echo "voice-once: emotion=${VOICE_EMOTION}" >&2

# sanity + decode Edge TTS mp3 → wav for aplay (prefer board convert for CN quality)
rsz=$(wc -c <"$REPLY_WAV" | tr -d ' ')
[[ "${rsz:-0}" -gt 44 ]] || die "empty reply audio"

PLAY_WAV="$REPLY_WAV"
# TTS loudness: light normalize headroom + optional dB (default +1; user OK “稍微小一点”).
# Override: TTS_SOX_GAIN=0 .. 6
TTS_SOX_GAIN="${TTS_SOX_GAIN:-1}"
loud_48k() {
	# $1=in $2=out — 48 kHz stereo S16; gain -n -3 leaves headroom, then TTS_SOX_GAIN
	local inn="$1" outn="$2"
	if command -v sox >/dev/null 2>&1; then
		sox "$inn" -r 48000 -c 2 -b 16 "$outn" gain -n -3 gain "${TTS_SOX_GAIN}" 2>/dev/null \
			|| sox "$inn" -r 48000 -c 2 -b 16 "$outn" vol 1.4 2>/dev/null \
			|| return 1
		return 0
	fi
	return 1
}

magic=$(head -c 4 "$REPLY_WAV" | tr -d '\0' || true)
is_mp3=0
if echo "$CT" | grep -qE 'audio/mpeg|audio/mp3|octet-stream'; then
	is_mp3=1
fi
# ID3 or MPEG frame sync
if head -c 3 "$REPLY_WAV" | grep -q 'ID3'; then is_mp3=1; fi
b0=$(od -An -tx1 -N1 "$REPLY_WAV" 2>/dev/null | tr -d ' \n')
[[ "$b0" = "ff" ]] && is_mp3=1

if [[ "$magic" = "RIFF" ]]; then
	is_mp3=0
fi

WAV_OUT="${REPLY_WAV%.wav}.pcm.wav"
if [[ "$is_mp3" = "1" ]]; then
	echo "voice-once: reply is mp3 — convert+boost (gain -n +${TTS_SOX_GAIN}dB) for aplay" >&2
	RAW_WAV="${REPLY_WAV%.wav}.raw.wav"
	if command -v ffmpeg >/dev/null 2>&1; then
		ffmpeg -y -i "$REPLY_WAV" -acodec pcm_s16le -ar 48000 -ac 2 "$RAW_WAV" >/dev/null 2>&1 \
			|| die "ffmpeg mp3→wav failed"
		loud_48k "$RAW_WAV" "$WAV_OUT" || mv -f "$RAW_WAV" "$WAV_OUT"
	elif command -v mpg123 >/dev/null 2>&1; then
		mpg123 -q -w "$RAW_WAV" "$REPLY_WAV" 2>/dev/null || die "mpg123 mp3→wav failed"
		loud_48k "$RAW_WAV" "$WAV_OUT" || die "sox loud resample failed"
	elif command -v sox >/dev/null 2>&1; then
		loud_48k "$REPLY_WAV" "$WAV_OUT" || die "sox mp3→wav failed"
	else
		die "need ffmpeg, mpg123, or sox to convert Edge TTS mp3 → wav"
	fi
	PLAY_WAV="$WAV_OUT"
elif [[ "$magic" = "RIFF" ]]; then
	if loud_48k "$REPLY_WAV" "$WAV_OUT"; then
		PLAY_WAV="$WAV_OUT"
	fi
fi
rsz=$(wc -c <"$PLAY_WAV" | tr -d ' ')

# PTT daemon plays with barge-in: SKIP_PLAY=1 → leave reply wav + .emotion for caller
if [[ "${SKIP_PLAY:-0}" == "1" ]]; then
	# Prefer converted PLAY_WAV path for caller
	if [[ "$PLAY_WAV" != "$REPLY_WAV" && -f "$PLAY_WAV" ]]; then
		cp -f "$PLAY_WAV" "$REPLY_WAV.play.wav" 2>/dev/null || true
		echo "voice-once: SKIP_PLAY=1 reply=${REPLY_WAV} play=${REPLY_WAV}.play.wav (${rsz}B) emotion=${VOICE_EMOTION:-}" >&2
	else
		echo "voice-once: SKIP_PLAY=1 reply=${REPLY_WAV} (${rsz}B) emotion=${VOICE_EMOTION:-}" >&2
	fi
	echo "voice-once: done (no aplay)" >&2
	exit 0
fi

# HDMI eyes sync with TTS
HOLD_S=$(python3 -c "print(max(2.0, ${rsz}/(48000*2*2)+0.5))" 2>/dev/null || echo 20)
if [[ -x "$EMOTION_HELPER" ]]; then
	"$EMOTION_HELPER" ensure || true
	"$EMOTION_HELPER" play-start "${VOICE_EMOTION:-}" "$HOLD_S" || true
fi

echo "voice-once: playing reply ${rsz}B on ${DEV} (${PLAY_WAV}) emotion=${VOICE_EMOTION:-speaking}" >&2
AUDIO_UP_QUIET=1 "$AUDIO_UP" 2>/dev/null || true
play_rc=0
# Prefer exact hw params; fall back to plughw rate conversion
if ! aplay -D "$DEV" "$PLAY_WAV" >&2; then
	echo "voice-once: hw play failed — retry plughw:0,0" >&2
	aplay -D "plughw:${CARD},0" "$PLAY_WAV" >&2 || play_rc=$?
fi
if [[ -x "$EMOTION_HELPER" ]]; then
	"$EMOTION_HELPER" play-end || true
fi
[[ "$play_rc" -eq 0 ]] || die "aplay failed"
echo "voice-once: done" >&2
