#!/bin/sh
# Set expression for rk3576-robot-eyes v1.1.0 (all pack clips).
# Usage:
#   board-hdmi-emotion-set.sh                 # show current
#   board-hdmi-emotion-set.sh list            # list all expressions
#   board-hdmi-emotion-set.sh happy
#   board-hdmi-emotion-set.sh idle
#   board-hdmi-emotion-set.sh look_around
set -eu
PORT="${EMOTION_PORT:-8765}"
STATE="${1:-}"

if [ -z "$STATE" ]; then
	python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:${PORT}/api/emotion').read().decode())"
	exit 0
fi

if [ "$STATE" = "list" ] || [ "$STATE" = "--list" ] || [ "$STATE" = "-l" ]; then
	python3 -c "import urllib.request,json; j=json.loads(urllib.request.urlopen('http://127.0.0.1:${PORT}/api/emotion/list').read()); print('count', j['count']); print(' '.join(j['animations']))"
	exit 0
fi

# Optional 2nd arg: hold seconds. 3rd arg or FORCE=1: preempt special lock.
HOLD="${2:-}"
FORCE="${3:-${FORCE:-}}"
if [ -n "$HOLD" ] && [ -n "$FORCE" ]; then
	BODY=$(printf '{"state":"%s","hold":%s,"force":true}' "$STATE" "$HOLD")
elif [ -n "$HOLD" ]; then
	BODY=$(printf '{"state":"%s","hold":%s}' "$STATE" "$HOLD")
elif [ -n "$FORCE" ]; then
	BODY=$(printf '{"state":"%s","force":true}' "$STATE")
else
	BODY=$(printf '{"state":"%s"}' "$STATE")
fi

python3 - "$PORT" "$BODY" <<'PY'
import sys, urllib.request
port, body = sys.argv[1], sys.argv[2].encode()
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/api/emotion",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=3) as r:
        print(r.read().decode())
except Exception as e:
    if hasattr(e, "read"):
        print(e.read().decode(), file=sys.stderr)
    raise
PY
