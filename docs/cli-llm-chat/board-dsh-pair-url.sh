#!/usr/bin/env bash
# Paste a full Desktop LAN pair URL → parse base + token → run board-dsh-pair.sh.
# Example:
#   ./board-dsh-pair-url.sh 'http://10.23.9.124:43127/pair?token=TOKEN'
#   ./board-dsh-pair-url.sh   # prompts for URL
# Never prints the token or cookie.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

PAIR_SH="${SCRIPT_DIR}/board-dsh-pair.sh"
[[ -x "$PAIR_SH" ]] || die "missing executable $PAIR_SH"

RAW="${1:-}"
if [[ -z "$RAW" ]]; then
  if [[ -t 0 ]]; then
    printf 'Paste full pair URL (http://HOST:PORT/pair?token=…): ' >&2
    IFS= read -r RAW || true
  else
    IFS= read -r RAW || true
  fi
fi

# Strip wrapping quotes / whitespace from clipboard paste
RAW="$(printf '%s' "$RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')"
[[ -n "$RAW" ]] || die "empty URL. Usage: $0 'http://HOST:PORT/pair?token=…'"

command -v python3 >/dev/null 2>&1 || die "need python3"

# Parse scheme://host[:port][/…]?token=… → BASE + TOKEN (never print token)
eval "$(
  python3 - "$RAW" <<'PY'
import sys, urllib.parse
raw = sys.argv[1].strip()
# Allow accidental "pair URL:" prefix
for prefix in ("pair url:", "url:", "lan:"):
    if raw.lower().startswith(prefix):
        raw = raw[len(prefix):].strip()
        break
u = urllib.parse.urlparse(raw)
if u.scheme not in ("http", "https") or not u.netloc:
    print("echo 'ERROR: need http(s)://HOST[:PORT]/… URL' >&2; exit 1")
    raise SystemExit(0)
qs = urllib.parse.parse_qs(u.query, keep_blank_values=False)
token = (qs.get("token") or [None])[0]
if not token:
    # some UIs put token in fragment ? rare; also path /pair/TOKEN
    frag_qs = urllib.parse.parse_qs(urllib.parse.urlparse("x?" + u.fragment).query)
    token = (frag_qs.get("token") or [None])[0]
if not token and u.path.startswith("/pair/") and len(u.path) > len("/pair/"):
    token = urllib.parse.unquote(u.path[len("/pair/"):].strip("/"))
if not token:
    print("echo 'ERROR: URL missing ?token=…' >&2; exit 1")
    raise SystemExit(0)
base = f"{u.scheme}://{u.netloc}"
# shell-escape via %q-like: use single quotes with escape
def shq(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"
print(f"DSH_BASE_URL={shq(base)}")
print(f"DSH_PAIR_TOKEN={shq(token)}")
print(f"echo \"Parsed BASE={base} token_len={len(token)} (token not printed)\"")
PY
)"

# Export wins over board .env ICS default when pair.sh sources .env.
export DSH_BASE_URL DSH_PAIR_TOKEN
echo "Using BASE=$DSH_BASE_URL (from pasted URL; .env will not override)"
exec "$PAIR_SH"
