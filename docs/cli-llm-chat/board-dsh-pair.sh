#!/usr/bin/env bash
# LAN pair against DSH Desktop mobile bridge → write DSH_MOBILE_COOKIE into .env
# Desktop UX: no Approve button — GET /pair?token= connects immediately.
# Cookie usually arrives as Set-Cookie: dsh_mobile=… on the /pair response (often HTTP 302).
# Never prints cookie/token values.
#
# Prefer full URL paste via board-dsh-pair-url.sh, or:
#   DSH_PAIR_TOKEN=… ./board-dsh-pair.sh
#   ./board-dsh-pair.sh 'http://HOST:PORT/pair?token=…'   # same as pair-url wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

# Optional argv: full pair URL → defer to URL wrapper (keeps parse logic in one place)
if [[ "${1:-}" == http://* || "${1:-}" == https://* ]]; then
  exec "${SCRIPT_DIR}/board-dsh-pair-url.sh" "$1"
fi

# Caller export / pair-url parse must win over stale .env (e.g. ICS .1 vs Wi‑Fi host).
_PRE_BASE="${DSH_BASE_URL-}"
_PRE_TOKEN="${DSH_PAIR_TOKEN-}"
_PRE_COOKIE="${DSH_MOBILE_COOKIE-}"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

[[ -n "${_PRE_BASE}" ]] && DSH_BASE_URL="$_PRE_BASE"
[[ -n "${_PRE_TOKEN}" ]] && DSH_PAIR_TOKEN="$_PRE_TOKEN"
[[ -n "${_PRE_COOKIE}" ]] && DSH_MOBILE_COOKIE="$_PRE_COOKIE"
unset _PRE_BASE _PRE_TOKEN _PRE_COOKIE

DSH_BASE_URL="${DSH_BASE_URL:-http://192.168.137.1:43127}"
DSH_BASE_URL="${DSH_BASE_URL%/}"
DSH_PAIR_TOKEN="${DSH_PAIR_TOKEN:-}"

[[ -n "$DSH_PAIR_TOKEN" ]] || die "DSH_PAIR_TOKEN unset. Paste full URL into ./board-dsh-pair-url.sh, or export the short-lived LAN token (not a Pinggy URL)."

command -v curl >/dev/null 2>&1 || die "need curl"
command -v python3 >/dev/null 2>&1 || die "need python3"
# jq only required for legacy pending-id /pair/status poll path
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

COOKIE_JAR="$(mktemp /tmp/dsh-pair-cookies.XXXXXX)"
HDR="$(mktemp /tmp/dsh-pair-hdr.XXXXXX)"
BODY="/tmp/dsh-pair-body.html"
trap 'rm -f "$COOKIE_JAR" "$HDR" "$BODY"' EXIT

cookie_from_jar() {
  # Netscape jar: fields may be space- or tab-separated; name is field 6, value field 7
  awk 'BEGIN{FS="[\t ]+"} $0 !~ /^#/ && NF>=7 && tolower($6)=="dsh_mobile"{print $7}' "$COOKIE_JAR" | tail -1 || true
}

cookie_from_headers() {
  # Robust parse via python (board sed/grep often miss folded or oddly cased Set-Cookie)
  python3 - "$1" <<'PY' || true
import re, sys
path = sys.argv[1]
try:
    text = open(path, "rb").read().decode("utf-8", "replace")
except FileNotFoundError:
    sys.exit(0)
text = text.replace("\r\n", "\n").replace("\r", "\n")
# join folded continuation lines
lines, buf = [], ""
for line in text.split("\n"):
    if line.startswith((" ", "\t")) and buf:
        buf += line.strip()
        continue
    if buf:
        lines.append(buf)
    buf = line
if buf:
    lines.append(buf)
val = None
for line in lines:
    if not line.lower().startswith("set-cookie:"):
        continue
    body = line.split(":", 1)[1].strip()
    m = re.search(r"(?i)\bdsh_mobile=([^;]+)", body)
    if m:
        val = m.group(1).strip().strip('"')
print(val or "", end="")
PY
}

extract_pending_id() {
  local text="$1"
  local id=""
  id="$(printf '%s' "$text" | grep -oE 'pair/status\?id=[0-9a-fA-F-]{36}' | head -1 | sed 's/.*id=//' || true)"
  if [[ -z "$id" ]]; then
    id="$(printf '%s' "$text" | grep -oE 'id=[0-9a-fA-F-]{36}' | head -1 | sed 's/^id=//' || true)"
  fi
  if [[ -z "$id" ]]; then
    id="$(printf '%s' "$text" | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1 || true)"
  fi
  printf '%s' "$id"
}

write_env_cookie() {
  local cookie_val="$1"
  local env_file="$SCRIPT_DIR/.env"
  touch "$env_file"
  chmod 600 "$env_file" 2>/dev/null || true
  python3 - "$env_file" "$DSH_BASE_URL" "$cookie_val" <<'PY'
import sys, re
path, base, cookie = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
def upsert(text, key, val):
    line = f"{key}={val}"
    if re.search(rf"(?m)^{re.escape(key)}=", text):
        return re.sub(rf"(?m)^{re.escape(key)}=.*$", line, text)
    if text and not text.endswith("\n"):
        text += "\n"
    return text + line + "\n"
text = upsert(text, "DSH_BASE_URL", base)
text = upsert(text, "DSH_MOBILE_COOKIE", cookie)
text = re.sub(r"(?m)^DSH_PAIR_TOKEN=.*\n?", "", text)
open(path, "w", encoding="utf-8").write(text)
print(f"wrote {path}: DSH_BASE_URL + DSH_MOBILE_COOKIE (len={len(cookie)}); removed DSH_PAIR_TOKEN if any")
PY
}

echo "BASE=$DSH_BASE_URL"
echo "Opening /pair (Desktop connects immediately — no Approve step)…"

# Capture headers: cookie is often on this response even when body is empty / Location=/
HTTP_CODE="$(curl -sS -D "$HDR" -o "$BODY" -w '%{http_code}' \
  -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -H "Accept: text/html" \
  "${DSH_BASE_URL}/pair?token=${DSH_PAIR_TOKEN}" || echo 000)"
PAIR_HTML="$(cat "$BODY" 2>/dev/null || true)"
LOCATION="$(grep -i '^location:' "$HDR" | tail -1 | sed -E 's/^[Ll]ocation:[[:space:]]*//;s/\r$//' || true)"
echo "GET /pair → HTTP ${HTTP_CODE}, body_bytes=${#PAIR_HTML}, location=${LOCATION:-none}"

COOKIE_VAL="$(cookie_from_jar)"
if [[ -z "$COOKIE_VAL" ]]; then
  COOKIE_VAL="$(cookie_from_headers "$HDR")"
fi

# Optional: follow Location once (may set cookie on second hop)
if [[ -z "$COOKIE_VAL" && -n "$LOCATION" && "$LOCATION" != "/" && "$LOCATION" != "${DSH_BASE_URL}/" ]]; then
  FOLLOW_URL="$LOCATION"
  case "$FOLLOW_URL" in
    http://*|https://*) ;;
    /*) FOLLOW_URL="${DSH_BASE_URL}${FOLLOW_URL}" ;;
    *) FOLLOW_URL="${DSH_BASE_URL}/${FOLLOW_URL}" ;;
  esac
  echo "Following Location once (still looking for dsh_mobile cookie)…"
  HTTP2="$(curl -sS -D "$HDR" -o "$BODY" -w '%{http_code}' \
    -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Accept: text/html" \
    "$FOLLOW_URL" || echo 000)"
  echo "GET follow → HTTP ${HTTP2}"
  COOKIE_VAL="$(cookie_from_jar)"
  if [[ -z "$COOKIE_VAL" ]]; then
    COOKIE_VAL="$(cookie_from_headers "$HDR")"
  fi
fi

# Fallback: pending-id + status poll (older bridges that require approve)
if [[ -z "$COOKIE_VAL" ]]; then
  PENDING_ID="$(extract_pending_id "$LOCATION")"
  if [[ -z "$PENDING_ID" ]]; then
    PENDING_ID="$(extract_pending_id "$PAIR_HTML")"
  fi
  if [[ -n "$PENDING_ID" ]]; then
    echo "pending_id=${PENDING_ID:0:8}… (polling /pair/status; some builds set cookie here)"
    for _ in $(seq 1 60); do
      RESP="$(curl -sS -D "$HDR" -o - -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${DSH_BASE_URL}/pair/status?id=${PENDING_ID}" || true)"
      COOKIE_VAL="$(cookie_from_jar)"
      if [[ -z "$COOKIE_VAL" ]]; then
        COOKIE_VAL="$(cookie_from_headers "$HDR")"
      fi
      [[ -n "$COOKIE_VAL" ]] && break
      if [[ "$HAVE_JQ" -eq 1 ]]; then
        if echo "$RESP" | jq -e '.denied == true or .expired == true' >/dev/null 2>&1; then
          die "pairing denied or expired"
        fi
      else
        case "$RESP" in
          *'"denied":true'*|*'\"denied\": true'*|*'"expired":true'*|*'\"expired\": true'*)
            die "pairing denied or expired" ;;
        esac
      fi
      sleep 1
    done
  fi
fi

if [[ -z "$COOKIE_VAL" ]]; then
  echo "--- response headers (set-cookie names only) ---"
  sed 's/\r$//' "$HDR" | grep -i '^set-cookie:' | sed -E 's/(dsh_mobile=)[^;]+/\1***/I' || echo "(no set-cookie)"
  echo "--- jar cookie names ---"
  awk 'NF>=7 && $1 !~ /^#/ {print $6}' "$COOKIE_JAR" | sort -u || true
  die "no dsh_mobile cookie after /pair. Token may be expired, or Desktop already holding a stale session — Disconnect phone, mint a fresh LAN token, retry."
fi

write_env_cookie "$COOKIE_VAL"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' -b "dsh_mobile=${COOKIE_VAL}" \
  -H "Origin: ${DSH_BASE_URL}" \
  "${DSH_BASE_URL}/api/status" || echo 000)"
echo "GET /api/status → HTTP ${CODE} (expect 200)"
STATUS_BODY="$(curl -sS -b "dsh_mobile=${COOKIE_VAL}" -H "Origin: ${DSH_BASE_URL}" \
  "${DSH_BASE_URL}/api/status" || true)"
echo "status_body: $(printf '%s' "$STATUS_BODY" | head -c 200)"

# Optional greet right after pair (needs DSH_SESSION_ID in .env + bridge :43128)
GREET_ON_PAIR="${GREET_ON_PAIR:-0}"
if [[ "$GREET_ON_PAIR" == "1" && -x "${SCRIPT_DIR}/board-greet.sh" ]]; then
  export DSH_MOBILE_COOKIE="$COOKIE_VAL"
  # shellcheck disable=SC1091
  [[ -f "$SCRIPT_DIR/.env" ]] && set -a && source "$SCRIPT_DIR/.env" && set +a
  export DSH_MOBILE_COOKIE="$COOKIE_VAL"
  if [[ -n "${DSH_SESSION_ID:-}" ]]; then
    echo "(GREET_ON_PAIR=1 → board-greet.sh)…"
    "${SCRIPT_DIR}/board-greet.sh" || echo "(greet after pair failed; continue)" >&2
  else
    echo "(GREET_ON_PAIR skip: set DSH_SESSION_ID in .env first, or greet from board-dsh-chat.sh)"
  fi
fi

echo "Done. Run ./board-dsh-chat.sh  (greets on start when GREET_ON_START/VOICE_GREET=1)"
