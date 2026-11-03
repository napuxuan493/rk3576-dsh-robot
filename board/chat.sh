#!/usr/bin/env bash
# Interactive OpenAI-compatible LLM chat (multi-turn).
# Env: LLM_API_BASE, LLM_API_KEY, LLM_MODEL  (optional: LLM_SYSTEM)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load local .env if present (never commit real keys)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

die() { echo "ERROR: $*" >&2; exit 1; }

LLM_API_BASE="${LLM_API_BASE:-}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-deepseek-chat}"
LLM_SYSTEM="${LLM_SYSTEM:-你是小智式桌面语音助手，回答简洁。}"

[[ -n "$LLM_API_BASE" ]] || die "LLM_API_BASE 未设置。请 cp env.example .env 并填写，或 export LLM_API_BASE=..."
[[ -n "$LLM_API_KEY" ]] || die "LLM_API_KEY 未设置。请在 .env 中填写或 export LLM_API_KEY=..."

# Normalize base: strip trailing slash; allow base that already ends with /v1
BASE="${LLM_API_BASE%/}"
if [[ "$BASE" == */v1 ]]; then
  URL="${BASE}/chat/completions"
else
  URL="${BASE}/v1/chat/completions"
fi

command -v jq >/dev/null 2>&1 || die "需要 jq（apt install jq）"

HAVE_CURL=0
if command -v curl >/dev/null 2>&1; then
  HAVE_CURL=1
fi
command -v python3 >/dev/null 2>&1 || die "需要 python3（curl 不可用时的 HTTPS 回退）"

MSG_FILE="$(mktemp -t xiaozhi-msgs.XXXXXX.json)"
trap 'rm -f "$MSG_FILE"' EXIT

jq -n --arg sys "$LLM_SYSTEM" '[{"role":"system","content":$sys}]' >"$MSG_FILE"

echo "=== 小智 CLI LLM 聊天 ==="
echo "BASE=$BASE"
echo "MODEL=$LLM_MODEL"
echo "URL=$URL"
echo "HTTP client: $([[ $HAVE_CURL -eq 1 ]] && echo curl || echo python3-fallback)"
echo "输入内容回车发送；空行忽略；quit / exit / Ctrl-D 退出"
echo

append_user() {
  local text="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg c "$text" '. + [{"role":"user","content":$c}]' "$MSG_FILE" >"$tmp"
  mv "$tmp" "$MSG_FILE"
}

append_assistant() {
  local text="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg c "$text" '. + [{"role":"assistant","content":$c}]' "$MSG_FILE" >"$tmp"
  mv "$tmp" "$MSG_FILE"
}

do_request() {
  local body http_code resp_file
  body="$(jq -n --arg model "$LLM_MODEL" --slurpfile msgs "$MSG_FILE" \
    '{model:$model, messages:$msgs[0], temperature:0.7}')"
  resp_file="$(mktemp)"

  if [[ $HAVE_CURL -eq 1 ]]; then
    http_code="$(curl -sS -o "$resp_file" -w "%{http_code}" \
      --connect-timeout 15 --max-time 120 \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${LLM_API_KEY}" \
      -d "$body" \
      "$URL")" || {
      rm -f "$resp_file"
      die "网络失败：无法连接 $URL（检查 DNS / 防火墙 / 代理）"
    }
  else
    # python3 HTTPS fallback (this VM has no apt-installable curl without sudo)
    http_code="$(LLM_URL="$URL" LLM_KEY="$LLM_API_KEY" LLM_BODY="$body" RESP_FILE="$resp_file" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
url = os.environ["LLM_URL"]
key = os.environ["LLM_KEY"]
body = os.environ["LLM_BODY"].encode("utf-8")
req = urllib.request.Request(
    url,
    data=body,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {key}",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
        code = r.status
except urllib.error.HTTPError as e:
    data = e.read()
    code = e.code
except Exception as e:
    print(f"NETWORK:{e}", file=sys.stderr)
    sys.exit(2)
open(os.environ["RESP_FILE"], "wb").write(data)
print(code)
PY
)" || {
      rm -f "$resp_file"
      die "网络失败：无法连接 $URL（检查 DNS / 防火墙 / 代理）"
    }
  fi

  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: HTTP $http_code from $URL" >&2
    head -c 2000 "$resp_file" >&2 || true
    echo >&2
    rm -f "$resp_file"
    return 1
  fi

  local reply
  reply="$(jq -r '.choices[0].message.content // empty' "$resp_file")"
  if [[ -z "$reply" ]]; then
    echo "ERROR: 响应无 choices[0].message.content：" >&2
    head -c 2000 "$resp_file" >&2 || true
    echo >&2
    rm -f "$resp_file"
    return 1
  fi
  rm -f "$resp_file"
  printf '%s\n' "$reply"
}

while true; do
  if ! IFS= read -r -e -p "你> " user_line; then
    echo
    echo "(EOF) 再见。"
    break
  fi
  # trim
  user_line="${user_line#"${user_line%%[![:space:]]*}"}"
  user_line="${user_line%"${user_line##*[![:space:]]}"}"
  [[ -z "$user_line" ]] && continue
  case "$user_line" in
    quit|exit|q|退出) echo "再见。"; break ;;
  esac

  append_user "$user_line"
  echo -n "助手> "
  if ! reply="$(do_request)"; then
    # drop last user turn on failure so retry is clean
    tmp="$(mktemp)"
    jq 'if length>1 then .[:-1] else . end' "$MSG_FILE" >"$tmp"
    mv "$tmp" "$MSG_FILE"
    continue
  fi
  printf '%s\n\n' "$reply"
  append_assistant "$reply"
done
