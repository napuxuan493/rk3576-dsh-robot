#!/usr/bin/env bash
# Light convention checks for rk3576-dsh-robot (bash / Git Bash / Linux).
# Optional: SHELLCHECK=1 to run shellcheck on board/*.sh when installed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
failed=0
ok() { printf 'OK:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failed=$((failed + 1)); }

required=(
  README.md
  docs/CONVENTIONS.md
  board/board-dsh-chat.sh
  board/board-dsh-pair.sh
  board/board-dsh-pair-url.sh
  board/board-voice-once.sh
  board/board-dsh.env.example
  board/hdmi-emotion-ui/emotion_fb.py
  windows/dsh-voice-bridge/server.mjs
  windows/dsh-voice-bridge/start.ps1
  windows/dsh-voice-bridge/env.example
  windows/dsh-voice-bridge/package.json
)
for rel in "${required[@]}"; do
  if [[ -e "$ROOT/$rel" ]]; then ok "exists $rel"; else fail "missing $rel"; fi
done

if git ls-files '*.env' '.env' '*/.env' 2>/dev/null | grep -v '\.env\.example$' | grep -q .; then
  fail "tracked .env files present"
else
  ok "no tracked .env"
fi

key_scripts=(
  board/board-dsh-chat.sh
  board/board-dsh-pair.sh
  board/board-dsh-pair-url.sh
  board/board-voice-once.sh
  board/board-tts-pull.sh
  board/board-greet.sh
)
for rel in "${key_scripts[@]}"; do
  [[ -f "$ROOT/$rel" ]] || { fail "missing $rel"; continue; }
  head -n1 "$ROOT/$rel" | grep -q '^#!/' && ok "$rel shebang" || fail "$rel missing shebang"
  grep -q 'SCRIPT_DIR=' "$ROOT/$rel" && ok "$rel SCRIPT_DIR" || fail "$rel missing SCRIPT_DIR pattern"
done

while IFS= read -r -d '' f; do
  head -n1 "$f" | grep -q '^#!/' || fail "missing shebang: ${f#"$ROOT"/}"
done < <(find "$ROOT/board" -type f -name '*.sh' -print0)

if [[ "${SHELLCHECK:-0}" == "1" ]]; then
  if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    if shellcheck $(find "$ROOT/board" -type f -name '*.sh'); then
      ok "shellcheck clean"
    else
      fail "shellcheck reported issues"
    fi
  else
    printf 'WARN: SHELLCHECK=1 but shellcheck not on PATH\n'
  fi
fi

if grep -q '"type"[[:space:]]*:[[:space:]]*"module"' "$ROOT/windows/dsh-voice-bridge/package.json"; then
  ok "package.json type=module"
else
  fail "package.json type must be module"
fi
if grep -q '"start"[[:space:]]*:[[:space:]]*"node server.mjs"' "$ROOT/windows/dsh-voice-bridge/package.json"; then
  ok "package.json scripts.start"
else
  fail "package.json missing scripts.start"
fi

if (( failed > 0 )); then
  printf '\n%d check(s) failed.\n' "$failed"
  exit 1
fi
printf '\nAll convention checks passed.\n'
exit 0
