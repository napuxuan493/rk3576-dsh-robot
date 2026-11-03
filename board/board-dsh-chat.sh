#!/usr/bin/env bash
# Board thin client → DSH Desktop LAN bridge (/api/rpc).
# Default base: http://192.168.137.1:43127  (Windows ICS Ethernet; not Pinggy, not VM).
# Auth: Cookie dsh_mobile from board-dsh-pair.sh → .env (chmod 600).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

# Explicit export wins over .env (same rule as board-dsh-pair.sh).
_PRE_BASE="${DSH_BASE_URL-}"
_PRE_COOKIE="${DSH_MOBILE_COOKIE-}"
_PRE_SESSION="${DSH_SESSION_ID-}"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

[[ -n "${_PRE_BASE}" ]] && DSH_BASE_URL="$_PRE_BASE"
[[ -n "${_PRE_COOKIE}" ]] && DSH_MOBILE_COOKIE="$_PRE_COOKIE"
[[ -n "${_PRE_SESSION}" ]] && DSH_SESSION_ID="$_PRE_SESSION"
unset _PRE_BASE _PRE_COOKIE _PRE_SESSION

DSH_BASE_URL="${DSH_BASE_URL:-http://192.168.137.1:43127}"
DSH_BASE_URL="${DSH_BASE_URL%/}"
RAW_COOKIE="${DSH_MOBILE_COOKIE:-}"

# Voice path hooks (CON24). See board-audio-up.sh / board-tts-pull.sh / dsh-voice-bridge.md
AUDIO_UP="${AUDIO_UP:-$SCRIPT_DIR/board-audio-up.sh}"
VOICE_ONCE="${VOICE_ONCE:-$SCRIPT_DIR/board-voice-once.sh}"
# Legacy cloud ASR script — not used by VOICE_IN (was api.openai.com / curl 6)
ASR_ONCE="${ASR_ONCE:-$SCRIPT_DIR/board-asr-once.sh}"
TTS_SAY="${TTS_SAY:-$SCRIPT_DIR/board-tts-say.sh}"
TTS_PULL="${TTS_PULL:-$SCRIPT_DIR/board-tts-pull.sh}"
GREET_SH="${GREET_SH:-$SCRIPT_DIR/board-greet.sh}"
PROACTIVE_SH="${PROACTIVE_SH:-$SCRIPT_DIR/board-proactive-tick.sh}"
VOICE_IN="${VOICE_IN:-0}"    # 1: empty Enter = LAN /v1/voice-turn via board-voice-once
VOICE_OUT="${VOICE_OUT:-1}"  # 1: after *text* reply, try TTS (prefer bridge)
# 主动开口：聊天一开始 POST /v1/greet（inject+TTS；once/session）。VOICE_GREET=0 关闭
VOICE_GREET="${VOICE_GREET:-1}"
GREET_ON_START="${GREET_ON_START:-$VOICE_GREET}"
CHAT_GREET_TEXT="${CHAT_GREET_TEXT:-}"  # optional override; empty → bridge default 大肥鱼 greet
# 闲置 nudge：秒；0=关闭。也可用 PROACTIVE_IDLE_S（同义）
VOICE_IDLE_SECS="${VOICE_IDLE_SECS:-${PROACTIVE_IDLE_S:-0}}"
CHAT_IDLE_TEXT="${CHAT_IDLE_TEXT:-}"    # empty → bridge /v1/proactive-tick random lines
IDLE_PID=""

if [[ -x "$AUDIO_UP" ]]; then
  AUDIO_UP_QUIET=1 "$AUDIO_UP" || true
fi

[[ -n "$RAW_COOKIE" ]] || die "DSH_MOBILE_COOKIE unset. Run ./board-dsh-pair.sh first (LAN pair)."
# Accept either raw value or "dsh_mobile=value"
if [[ "$RAW_COOKIE" == dsh_mobile=* ]]; then
  COOKIE_HEADER="$RAW_COOKIE"
else
  COOKIE_HEADER="dsh_mobile=${RAW_COOKIE}"
fi

command -v curl >/dev/null 2>&1 || die "need curl"
command -v jq >/dev/null 2>&1 || die "need jq"
command -v python3 >/dev/null 2>&1 || die "need python3 (uuid + history parse)"

rpc() {
  local method="$1"
  local payload_json="$2"
  local body
  body="$(jq -nc --arg m "$method" --argjson p "$payload_json" '{method:$m, payload:$p}')"
  # -m so a stuck Desktop cannot pin the shell; SIGINT still exits via trap.
  curl -sS -m "${DSH_RPC_TIMEOUT:-45}" -X POST "${DSH_BASE_URL}/api/rpc" \
    -H "Content-Type: application/json" \
    -H "Origin: ${DSH_BASE_URL}" \
    -H "Cookie: ${COOKIE_HEADER}" \
    --data-binary "$body"
}

# Extract assistant user-facing text.
# Env AFTER_USER=… → prefer assistant reply after that user turn.
# Env EXTRACT_MODE=count → print assistant message count only.
extract_assistant() {
  EXTRACT_MODE="${EXTRACT_MODE:-text}" python3 -c '
import json, os, re, sys

THINK_TYPES = {
    "thinking", "reasoning", "thought", "analysis", "chain_of_thought",
    "reasoning_content", "model_thinking", "internal",
}
GOOD_TYPES = {"text", "output_text", "input_text", "paragraph", "markdown"}

def is_think_type(t):
    t = (t or "").lower().replace("-", "_").replace("/", "_")
    if t in THINK_TYPES:
        return True
    return any(x in t for x in ("think", "reason", "cot", "scratch"))

def flatten_content(c, skip_think=True):
    if c is None:
        return ""
    if isinstance(c, str):
        return c
    if isinstance(c, dict):
        if skip_think and is_think_type(c.get("type")):
            return ""
        if skip_think:
            c = {k: v for k, v in c.items() if k not in ("reasoning_content", "thinking", "reasoning")}
        t = c.get("type")
        # Multi-part: gather only good typed parts (skip thinking), prefer last good
        if isinstance(c.get("content"), list):
            goods = []
            for item in c["content"]:
                if isinstance(item, dict) and is_think_type(item.get("type")):
                    continue
                piece = flatten_content(item, skip_think=skip_think)
                if piece and piece.strip():
                    goods.append(piece.strip())
            if goods:
                return goods[-1]
        if isinstance(c.get("text"), str) and not is_think_type(t):
            return c["text"]
        if "content" in c:
            return flatten_content(c["content"], skip_think=skip_think)
        parts = []
        for k in ("message", "data", "value"):
            if k in c:
                x = flatten_content(c[k], skip_think=skip_think)
                if x:
                    parts.append(x)
        return "\n".join(parts)
    if isinstance(c, list):
        goods = []
        for item in c:
            if isinstance(item, dict) and is_think_type(item.get("type")):
                continue
            x = flatten_content(item, skip_think=skip_think)
            if x and x.strip():
                goods.append(x.strip())
        if not goods:
            return ""
        return goods[-1] if len(goods) > 1 else goods[0]
    return ""

def strip_thinking_prose(text):
    if not text:
        return text
    text = re.sub(r"<think>[\s\S]*?</think>", "", text, flags=re.I)
    text = re.sub(r"```(?:thinking|reasoning)[\s\S]*?```", "", text, flags=re.I)
    meta = re.compile(
        r"^(User |I.m |I am |Maybe |Actually |Avoid |Respond |Keep |Reply |Ask |"
        r"Could be |So |Let me |Don.t |Briefly |Playful |Same again|Follow up|"
        r"用户|要问|可能|简短|避免|保持|重新考虑)",
        re.I,
    )
    kept = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            if kept:
                kept.append("")
            continue
        if meta.match(s):
            continue
        kept.append(ln)
    text = "\n".join(kept).strip()
    m = re.search(r"[\u4e00-\u9fff]{2,}", text)
    if m and m.start() > 20:
        prefix = text[: m.start()]
        if re.search(r"[A-Za-z]{3,}", prefix) and prefix.count(" ") >= 2:
            text = text[m.start() :].lstrip(" \t\-–—:：")
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()

def role_of(obj):
    if not isinstance(obj, dict):
        return None
    role = str(obj.get("role") or "").lower()
    t = str(obj.get("type") or "").lower()
    if role in ("user", "human"):
        return "user"
    if role == "assistant":
        return "assistant"
    if "user" in t and "assistant" not in t:
        return "user"
    if "assistant" in t and "thinking" not in t:
        return "assistant"
    return None

def msg_text(obj):
    text = flatten_content(obj.get("content"), skip_think=True)
    if not text:
        text = flatten_content(obj.get("text"), skip_think=True)
    if not text:
        text = flatten_content(obj.get("data"), skip_think=True)
    if not text and isinstance(obj.get("message"), dict):
        text = flatten_content(obj["message"], skip_think=True)
    return strip_thinking_prose(text or "")

def collect_turns(o, turns, seen):
    """DFS but prefer list order; record user/assistant turns in encounter order."""
    if id(o) in seen:
        return
    if isinstance(o, dict):
        seen.add(id(o))
        r = role_of(o)
        if r:
            tx = msg_text(o)
            if tx:
                turns.append((r, tx))
                return  # do not descend into message body again
        # Prefer common array fields in order
        for k in ("items", "messages", "history", "entries", "value", "data", "content"):
            if k in o:
                collect_turns(o[k], turns, seen)
        for k, v in o.items():
            if k in ("items", "messages", "history", "entries", "value", "data", "content"):
                continue
            collect_turns(v, turns, seen)
    elif isinstance(o, list):
        for v in o:
            collect_turns(v, turns, seen)

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
turns = []
collect_turns(data, turns, set())
assist = [t for r, t in turns if r == "assistant"]
mode = os.environ.get("EXTRACT_MODE", "text")
if mode == "count":
    sys.stdout.write(str(len(assist)))
    sys.exit(0)
after = (os.environ.get("AFTER_USER") or "").strip()
require_after = os.environ.get("REQUIRE_AFTER", "").strip() in ("1", "true", "yes")
chosen = ""
if after:
    # Exact match on last user turn equal to AFTER_USER (normalized strip)
    for i in range(len(turns) - 1, -1, -1):
        r, t = turns[i]
        if r == "user" and t.strip() == after:
            for r2, t2 in turns[i + 1 :]:
                if r2 == "assistant":
                    chosen = t2
                    break
            break
if not chosen and not require_after and assist:
    chosen = assist[-1]
if chosen:
    sys.stdout.write(chosen)
'
}

echo "=== board → DSH (LAN bridge) ==="
echo "DSH_BASE_URL=$DSH_BASE_URL"
echo "auth=dsh_mobile cookie (value not printed)"

STATUS="$(curl -sS -H "Origin: ${DSH_BASE_URL}" -H "Cookie: ${COOKIE_HEADER}" \
  "${DSH_BASE_URL}/api/status" || true)"
echo "status: $STATUS"
echo "$STATUS" | jq -e '.connected == true' >/dev/null 2>&1 \
  || die "/api/status not connected — re-pair on LAN (Desktop Connect phone + board-dsh-pair.sh)"

# Prefer pinned session (DSH_SESSION_ID / .env) over list[0] / session.create —
# otherwise prompts attach to a newly created or unrelated Desktop task.
DSH_SESSION_ID="${DSH_SESSION_ID:-}"

LIST="$(rpc 'session.list' '{}')"
if ! echo "$LIST" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "$LIST" | jq -c . 2>/dev/null || echo "$LIST"
  die "session.list failed (check cookie / Desktop still paired)"
fi

SESSION_ID=""
SESSION_SRC=""
if [[ -n "$DSH_SESSION_ID" ]]; then
  SESSION_ID="$DSH_SESSION_ID"
  SESSION_SRC="env"
  # Soft check: warn if not in current list (still send — Desktop may filter list)
  if ! echo "$LIST" | jq -e --arg sid "$SESSION_ID" '
      (.value.items // []) | map(.sessionId // .id // empty) | index($sid) != null
    ' >/dev/null 2>&1; then
    echo "WARN: DSH_SESSION_ID not in session.list — still using it (set a listed id to silence)"
  fi
  echo "using pinned session ${SESSION_ID} (from ${SESSION_SRC})"
else
  SESSION_ID="$(echo "$LIST" | jq -r '.value.items[0].sessionId // .value.items[0].id // empty')"
  if [[ -n "$SESSION_ID" ]]; then
    SESSION_SRC="list[0]"
    echo "reusing session ${SESSION_ID} (from ${SESSION_SRC}; set DSH_SESSION_ID in .env to pin)"
  else
    CREATE="$(rpc 'session.create' '{}')"
    SESSION_ID="$(echo "$CREATE" | jq -r '.value.sessionId // .value.id // empty')"
    [[ -n "$SESSION_ID" ]] || {
      echo "$CREATE" | jq -c . 2>/dev/null || echo "$CREATE"
      die "session.create did not return sessionId"
    }
    SESSION_SRC="create"
    echo "created session ${SESSION_ID} (no DSH_SESSION_ID / empty list)"
  fi
fi

# Export for board-tts-pull (sessionId + inject)
export DSH_SESSION_ID="$SESSION_ID"
export DSH_BASE_URL DSH_MOBILE_COOKIE DSH_VOICE_BRIDGE_URL

# Chat-open greet: prefer /v1/greet (once/session); fallback /v1/speak via tts-pull
voice_greet_once() {
  [[ "${GREET_ON_START:-1}" = "1" || "$VOICE_GREET" = "1" ]] || return 0
  if [[ -x "$GREET_SH" ]]; then
    echo "(主动开口 /v1/greet → CON24 + Desktop inject)…" >&2
    set +e
    GREET_FORCE="${GREET_FORCE:-0}" "$GREET_SH"
    local ec=$?
    set -e
    if [[ $ec -ne 0 ]]; then
      echo "(greet failed ec=$ec — chat continues; check bridge :43128)" >&2
    fi
    return 0
  fi
  [[ -x "$TTS_PULL" ]] || return 0
  echo "(主动开口 fallback board-tts-pull)…" >&2
  SPEAK_INJECT=1 "$TTS_PULL" "${CHAT_GREET_TEXT:-主人，本鱼等你好久了。}" || true
}

voice_idle_loop() {
  [[ "${VOICE_IDLE_SECS:-0}" -gt 0 ]] || return 0
  local secs="$VOICE_IDLE_SECS"
  while true; do
    sleep "$secs" || break
    echo "(idle nudge ${secs}s)…" >&2
    if [[ -x "$PROACTIVE_SH" ]]; then
      "$PROACTIVE_SH" || true
    elif [[ -x "$TTS_PULL" ]]; then
      SPEAK_INJECT=1 "$TTS_PULL" "${CHAT_IDLE_TEXT:-主人？本鱼有点无聊了……你在忙什么？}" || true
    fi
  done
}

voice_greet_once
if [[ "${VOICE_IDLE_SECS:-0}" -gt 0 ]]; then
  voice_idle_loop &
  IDLE_PID=$!
  echo "(VOICE_IDLE_SECS=${VOICE_IDLE_SECS} / PROACTIVE_IDLE_S — idle nudge pid $IDLE_PID)" >&2
fi

# HDMI eyes: reply [emotion:…] during TTS; wait = idle so IDLE_LIVELY (blink/look/drift).
# Special pack clips are higher priority; API locks one-at-a-time; force idle releases.
# EMOTION_ENABLE=0 disables. EMOTION_SPEAK_S / EMOTION_REACT_S hold times.
# On chat start: ensure BACKEND=fb UI if API down. On exit: stop + UI.
EMOTION_START_SH="${EMOTION_START_SH:-/userdata/dafeiyu-hdmi/board-hdmi-emotion-start.sh}"
EMOTION_STOP_SH="${EMOTION_STOP_SH:-/userdata/dafeiyu-hdmi/board-hdmi-emotion-stop.sh}"
EMOTION_HELPER="${EMOTION_HELPER:-$SCRIPT_DIR/board-emotion-voice.sh}"
EMOTION_CYCLE_PID=""
# Legacy: EMOTION_CYCLE_LIST specials ate idle lively + RAM; wait now forces idle only.
EMOTION_CYCLE_S="${EMOTION_CYCLE_S:-4}"

emotion_api_up() {
  local port="${EMOTION_PORT:-8765}"
  curl -sS -m 1 "http://127.0.0.1:${port}/api/emotion" >/dev/null 2>&1
}

emotion_ui_ensure() {
  [[ "${EMOTION_ENABLE:-1}" == "1" ]] || return 0
  if emotion_api_up; then
    echo "(eyes UI already up :${EMOTION_PORT:-8765})"
    return 0
  fi
  local start_sh="$EMOTION_START_SH"
  if [[ ! -x "$start_sh" ]]; then
    echo "(eyes UI start missing: $start_sh)" >&2
    return 0
  fi
  echo "(starting eyes UI BACKEND=fb…)"
  BACKEND=fb "$start_sh" || echo "(eyes UI start failed; chat continues)" >&2
}

emotion_ui_stop() {
  [[ "${EMOTION_ENABLE:-1}" == "1" ]] || return 0
  local stop_sh="$EMOTION_STOP_SH"
  if [[ -x "$stop_sh" ]]; then
    "$stop_sh" >/dev/null 2>&1 || true
  fi
}

# emotion_set NAME [HOLD] [force]
emotion_set() {
  local s="${1:-idle}"
  local hold="${2:-}"
  local force="${3:-}"
  [[ "${EMOTION_ENABLE:-1}" == "1" ]] || return 0
  local port="${EMOTION_PORT:-8765}"
  local set_sh="${EMOTION_SET_SH:-/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh}"
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
  curl -sS -m 1 -X POST "http://127.0.0.1:${port}/api/emotion" \
    -H 'Content-Type: application/json' \
    --data-binary "$body" >/dev/null 2>&1 \
    && return 0
  if [[ -x "$set_sh" ]]; then
    if [[ -n "$hold" ]]; then
      "$set_sh" "$s" "$hold" >/dev/null 2>&1 || true
    else
      "$set_sh" "$s" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

emotion_cycle_stop() {
  local pid="${EMOTION_CYCLE_PID:-}"
  EMOTION_CYCLE_PID=""
  [[ -n "$pid" ]] || return 0
  # TERM process group first (cycle may be mid-sleep/curl); never block forever on wait.
  kill -TERM "$pid" 2>/dev/null || true
  kill -TERM -"$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [[ $i -lt 20 ]]; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  kill -KILL -"$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Wait/idle: force idle so emotion_fb IDLE_LIVELY (blink + look + drift + breath) runs.
# Do NOT rotate pack specials here — that locked eyes off idle and OOMed bake cache.
emotion_cycle_start() {
  emotion_cycle_stop
  [[ "${EMOTION_ENABLE:-1}" == "1" ]] || return 0
  if [[ -x "$EMOTION_HELPER" ]]; then
    "$EMOTION_HELPER" play-end >/dev/null 2>&1 || emotion_set idle 0.5 force
  else
    emotion_set idle 0.5 force
  fi
}

# Strip structured emotion tags for display (keep human text only).
strip_emotion_tags() {
  local text="${1:-}"
  REPLY_TEXT="$text" python3 - <<'PY'
import os, re
t = os.environ.get("REPLY_TEXT") or ""
t = re.sub(r"\[emotion:\s*[A-Za-z0-9_]+\s*\]", "", t, flags=re.I)
t = re.sub(r"<!--\s*emotion:\s*[A-Za-z0-9_]+\s*-->", "", t, flags=re.I)
t = re.sub(r"[ \t]+\n", "\n", t)
t = re.sub(r"\n{3,}", "\n\n", t).strip()
print(t, end="")
PY
}

# Special reaction: structured tag first, keywords only as fallback. Empty = no special.
# Tags: [emotion:happy] or <!--emotion:happy--> (pack clip names). Prefer over keywords.
emotion_from_reply() {
  local text="${1:-}"
  REPLY_TEXT="$text" python3 - <<'PY'
import os, re
raw = os.environ.get("REPLY_TEXT") or ""
# Pack specials only — never idle/listening/speaking (phase hooks).
SPECIAL = {
    "happy", "excited", "love", "surprised", "confused", "thinking",
    "sad", "angry", "sleepy", "sleep", "wink", "dizzy", "blink",
    "look_around", "boot", "shutdown",
}
# 1) Structured tag (prefer). Last match wins if several.
tag = None
for m in re.finditer(r"\[emotion:\s*([A-Za-z0-9_]+)\s*\]", raw, re.I):
    tag = m.group(1).lower()
for m in re.finditer(r"<!--\s*emotion:\s*([A-Za-z0-9_]+)\s*-->", raw, re.I):
    tag = m.group(1).lower()
if tag in SPECIAL:
    print(tag)
    raise SystemExit(0)
# 2) Keyword fallback on text with tags stripped
t = re.sub(r"\[emotion:\s*[A-Za-z0-9_]+\s*\]", "", raw, flags=re.I)
t = re.sub(r"<!--\s*emotion:\s*[A-Za-z0-9_]+\s*-->", "", t, flags=re.I).lower()
rules = [
    ("angry",     r"生气|愤怒|怒|滚|混蛋|该死|angry|furious|mad\b|hate\b"),
    ("sad",       r"难过|伤心|抱歉|对不起|遗憾|哭|sad|sorry|unfortunate|regret"),
    ("love",      r"爱你|喜欢你|亲亲|比心|love you|爱了|么么"),
    ("excited",   r"太棒|万岁|兴奋|精彩|amazing|awesome|fantastic|太好了|绝了"),
    ("surprised", r"哇+|天哪|竟然|居然|surprised|what\?!|不会吧|咦"),
    ("confused",  r"不懂|不清楚|没听懂|困惑|confused|unclear|不确定|什么意思|？{2,}|\?{2,}"),
    ("sleepy",    r"困了|睡觉|晚安|sleepy|good\s*night|休息吧"),
    ("wink",      r"眨眼|嘿嘿|😉|wink|俏皮"),
    ("dizzy",     r"晕|dizzy|转圈|头昏"),
    ("happy",     r"哈哈|开心|高兴|好呀|不错|棒|glad|happy|great|nice|😊|😄|👍"),
]
for name, pat in rules:
    if re.search(pat, t, re.I):
        print(name)
        raise SystemExit(0)
print("")
PY
}

emotion_ui_ensure

# Why Ctrl+C used to "hang": INT trap only stopped eyes then *returned*, so the
# `read -e` loop kept running (readline often just clears the line). Also
# `wait` on the emotion cycle child could block the trap. Fix: INT/TERM must
# cleanup + exit; cycle kill must be bounded.
chat_cleanup() {
  if [[ -n "${IDLE_PID:-}" ]]; then
    kill "$IDLE_PID" 2>/dev/null || true
    wait "$IDLE_PID" 2>/dev/null || true
    IDLE_PID=""
  fi
  emotion_cycle_stop
  emotion_ui_stop
}
chat_interrupt() {
  trap - EXIT INT TERM
  echo "" >&2
  echo "(Ctrl+C — stopping chat + eyes)" >&2
  chat_cleanup
  exit 130
}
trap chat_cleanup EXIT
trap chat_interrupt INT TERM

if [[ "$VOICE_IN" = "1" ]]; then
  echo "Voice+text: Enter=LAN bridge mic turn (${REC_SECS:-5}s → :43128/v1/voice-turn → aplay); or type a line. quit/Ctrl-D leave."
  echo "(No OpenAI ASR — uses ${DSH_VOICE_BRIDGE_URL:-http://192.168.137.1:43128})"
else
  echo "Type a line to send; empty ignored; quit/exit/Ctrl-D to leave. Ctrl+C stops chat + eyes."
  echo "(Tip: VOICE_IN=1 ./board-dsh-chat.sh for CON24 mic via LAN bridge.)"
fi
echo
# Wait/idle: IDLE_LIVELY on idle (blink / look-left-right / drift / breath)
emotion_cycle_start

while true; do
  # read failure: EOF (Ctrl-D) or interrupted — leave loop; INT trap already exits.
  if ! IFS= read -r -e line; then
    break
  fi
  if [[ -z "${line// /}" ]]; then
    if [[ "$VOICE_IN" = "1" ]]; then
      if [[ ! -x "$VOICE_ONCE" ]]; then
        echo "(VOICE_IN: missing board-voice-once.sh — cannot use LAN bridge)" >&2
        continue
      fi
      echo "(VOICE_IN → board-voice-once /v1/voice-turn; speak now)…" >&2
      set +e
      # Greet already ran at chat start; skip second greet. Export session for bridge.
      export DSH_SESSION_ID="$SESSION_ID" DSH_BASE_URL DSH_MOBILE_COOKIE
      export DSH_VOICE_BRIDGE_URL="${DSH_VOICE_BRIDGE_URL:-http://192.168.137.1:43128}"
      GREET_ON_START=0 REC_SECS="${REC_SECS:-5}" "$VOICE_ONCE"
      voc_ec=$?
      set -e
      if [[ $voc_ec -ne 0 ]]; then
        echo "(voice-once failed ec=$voc_ec — check bridge :43128 / cookie; type text instead)" >&2
      fi
      # voice-once already play-start/end around aplay — return to idle lively
      emotion_cycle_start
      continue
    fi
    continue
  fi
  case "$line" in
    quit|exit|q) break ;;
  esac

  # Snapshot assistant count/text so we wait for *this* turn's reply
  PREV_ASSIST=""
  PREV_COUNT=0
  HIST0="$(rpc 'session.history' "$(jq -nc --arg sid "$SESSION_ID" '{sessionId:$sid}')" || true)"
  if echo "$HIST0" | jq -e '.ok == true' >/dev/null 2>&1; then
    PREV_ASSIST="$(printf '%s' "$HIST0" | extract_assistant || true)"
    PREV_COUNT="$(printf '%s' "$HIST0" | EXTRACT_MODE=count extract_assistant 2>/dev/null | tr -cd '0-9' || true)"
    PREV_COUNT="${PREV_COUNT:-0}"
  fi

  REQ_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  PAYLOAD="$(jq -nc \
    --arg sid "$SESSION_ID" \
    --arg rid "$REQ_ID" \
    --arg text "$line" \
    '{sessionId:$sid, requestId:$rid, mode:"queue", content:[{type:"text", text:$text}]}')"

  # Stay on idle lively while generating / polling for reply

  RESP="$(rpc 'session.prompt' "$PAYLOAD")"
  if ! echo "$RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "prompt error: $(echo "$RESP" | jq -c . 2>/dev/null || echo "$RESP")" >&2
    emotion_cycle_stop
    if [[ -x "$EMOTION_HELPER" ]]; then
      "$EMOTION_HELPER" play-start confused "${EMOTION_REACT_S:-2.5}" || true
      sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
      "$EMOTION_HELPER" play-end || true
    else
      emotion_set confused "${EMOTION_REACT_S:-2.5}" force
      sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
      emotion_set idle 0.5 force
    fi
    emotion_cycle_start
    continue
  fi
  echo "(accepted)"

  # ONLY accept assistant text that appears *after this user line* in history.
  # Never fall back to "last assistant" — that causes one-turn lag vs Desktop.
  ASSIST=""
  for wait in 1 1 2 2 2 3 3 3 4 5 5 6 8; do
    sleep "$wait" || chat_interrupt
    HIST="$(rpc 'session.history' "$(jq -nc --arg sid "$SESSION_ID" '{sessionId:$sid}')" || true)"
    if ! echo "$HIST" | jq -e '.ok == true' >/dev/null 2>&1; then
      continue
    fi
    TIED="$(printf '%s' "$HIST" | AFTER_USER="$line" REQUIRE_AFTER=1 EXTRACT_MODE=text extract_assistant || true)"
    if [[ -n "$TIED" && "$TIED" != "]" && "$TIED" != "[" && "$TIED" != "$PREV_ASSIST" ]]; then
      ASSIST="$TIED"
      break
    fi
  done

  emotion_cycle_stop
  if [[ -n "$ASSIST" ]]; then
    REACT="$(emotion_from_reply "$ASSIST" || true)"
    DISPLAY="$(strip_emotion_tags "$ASSIST" || true)"
    [[ -z "$DISPLAY" ]] && DISPLAY="$ASSIST"
    echo "DSH: $DISPLAY"
    # Eyes follow reply emotion *during* TTS (fallback speaking). Hold covers play.
    EYE_EMO="${REACT:-speaking}"
    HOLD_S="${EMOTION_SPEAK_S:-8}"
    if [[ -n "$REACT" ]]; then
      # Prefer react hold at least speak window so clip is visible through TTS.
      HOLD_S=$(python3 -c "print(max(float('${EMOTION_REACT_S:-2.5}'), float('${EMOTION_SPEAK_S:-8}')))" 2>/dev/null || echo 8)
    fi
    if [[ -x "$EMOTION_HELPER" ]]; then
      "$EMOTION_HELPER" play-start "$EYE_EMO" "$HOLD_S" || emotion_set "$EYE_EMO" "$HOLD_S" force
    else
      emotion_set "$EYE_EMO" "$HOLD_S" force
    fi
    if [[ "$VOICE_OUT" != "0" ]]; then
      # Prefer LAN Edge bridge (board-tts-pull → /v1/speak); OpenAI board-tts-say only if pull missing.
      TTS_TEXT="$(
        printf '%s' "$DISPLAY" | python3 -c '
import sys, re
t = sys.stdin.read()
t = re.sub(r"\[emotion:\s*[A-Za-z0-9_]+\s*\]", "", t, flags=re.I)
t = re.sub(r"<!--\s*emotion:\s*[A-Za-z0-9_]+\s*-->", "", t, flags=re.I)
if "【" in t and "】" in t:
    parts = re.findall(r"【([^】]*)】", t)
    sys.stdout.write("".join(parts) if parts else t)
else:
    t = re.sub(r"<think>[\s\S]*?</think>", "", t, flags=re.I)
    t = re.sub(r"```(?:thinking|reasoning)[\s\S]*?```", "", t, flags=re.I)
    sys.stdout.write(t.strip())
'
      )"
      [[ -z "$TTS_TEXT" ]] && TTS_TEXT="$DISPLAY"
      set +e
      if [[ -x "$TTS_PULL" ]]; then
        SPEAK_INJECT=0 "$TTS_PULL" "$TTS_TEXT"
        tts_ec=$?
      elif [[ -x "$TTS_SAY" ]]; then
        "$TTS_SAY" "$TTS_TEXT"
        tts_ec=$?
      else
        tts_ec=3
      fi
      set -e
      if [[ $tts_ec -eq 3 ]]; then
        echo "(TTS unavailable — need board-tts-pull.sh bridge or TTS_SAY/TTS_STUB)" >&2
        sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
      elif [[ $tts_ec -ne 0 ]]; then
        echo "(TTS failed ec=$tts_ec)" >&2
        sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
      fi
    else
      sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
    fi
    if [[ -x "$EMOTION_HELPER" ]]; then
      "$EMOTION_HELPER" play-end || emotion_set idle 0.5 force
    else
      emotion_set idle 0.5 force
    fi
  else
    echo "(prompt accepted; no reply after this turn in history yet — wait or check Desktop)"
    if [[ -x "$EMOTION_HELPER" ]]; then
      "$EMOTION_HELPER" play-start confused "${EMOTION_REACT_S:-2.5}" || true
      sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
      "$EMOTION_HELPER" play-end || true
    else
      emotion_set confused "${EMOTION_REACT_S:-2.5}" force
      sleep "${EMOTION_REACT_S:-2.5}" || chat_interrupt
      emotion_set idle 0.5 force
    fi
  fi
  emotion_cycle_start
done

emotion_cycle_stop
echo "bye"
# trap EXIT also runs chat_cleanup → emotion_cycle_stop + emotion_ui_stop
