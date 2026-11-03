# Repository conventions

This repo stays a **thin scripts + short tech notes** tree. No React/webpack monorepo, no root package manager, no build system for the board scripts.

## Layout

```
board/                         # board runtime scripts (deploy → /userdata/xiaozhi-cli)
  board-*.sh                   # pair / chat / ASR / TTS / PTT / net / audio
  S42xiaozhi-ics.sh …          # optional init.d-style boot helpers
  hdmi-emotion-ui/             # HDMI emotion FB UI (Python + start/stop)
  *.env.example                # templates only
windows/dsh-voice-bridge/      # Windows LAN voice bridge (Node ESM)
  server.mjs
  start.ps1
  env.example
  package.json                 # optional metadata only (no deps)
docs/                          # short tech notes (not runtime)
scripts/                       # maintainer checks (optional)
```

Historical names: `docs/cli-llm-chat/` → `board/`; `docs/dsh-voice-bridge/` (code) → `windows/dsh-voice-bridge/`. Tech notes such as `docs/dsh-voice-bridge.md` stay under `docs/`.

## Naming

| Kind | Pattern | Notes |
|------|---------|--------|
| Board shell | `board-<role>.sh` | Prefer `#!/usr/bin/env bash` (or `#!/bin/sh` for tiny boot helpers) |
| Boot helpers | `S4Nxiaozhi-*.sh` | Copied to board init paths when used |
| HDMI helpers | `board/hdmi-emotion-ui/board-hdmi-emotion-*.sh` | Live next to `emotion_fb.py` |
| Windows bridge | `server.mjs`, `start.ps1` | ESM; no bundler |
| Env templates | `*.env.example` / `env.example` | Never commit real `.env` |
| Docs | `docs/<topic>.md` | Short; no lecture-length dumps |

## SCRIPT_DIR pattern (board)

Key board scripts must resolve themselves, then load local `.env`:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# optional: source "$SCRIPT_DIR/.env"
```

Do **not** hard-code Windows checkout paths inside board scripts. Absolute board runtime path is `/userdata/xiaozhi-cli/` (or `/userdata/dafeiyu-hdmi/` for the emotion UI). Repo `board/` is the source mirror.

## Paths: board vs Windows

| Role | Path |
|------|------|
| Board scripts (runtime) | `/userdata/xiaozhi-cli/` |
| HDMI emotion UI (runtime) | `/userdata/dafeiyu-hdmi/` (sometimes `/opt/dafeiyu-hdmi/`) |
| Voice bridge **run copy** | `%USERPROFILE%\dsh-voice-bridge\` |
| Voice bridge **repo source** | `windows/dsh-voice-bridge/` |
| Docs / conventions | `docs/` in this repo |

Board ↔ PC LAN defaults (ICS): Desktop RPC `http://192.168.137.1:43127`, voice bridge `http://192.168.137.1:43128`.

## Environment variables (`DSH_*` and friends)

Prefix LAN/Desktop bridge settings with **`DSH_`**. Prefer copying examples:

- Board: `board/board-dsh.env.example` → `board/.env` (on board: `/userdata/xiaozhi-cli/.env`, `chmod 600`)
- Bridge: `windows/dsh-voice-bridge/env.example` → run-dir `.env` if needed

Common board vars: `DSH_BASE_URL`, `DSH_MOBILE_COOKIE`, `DSH_PAIR_TOKEN`, `DSH_SESSION_ID`, `DSH_VOICE_BRIDGE_URL`.

Common bridge vars: `DSH_VOICE_BIND`, `DSH_VOICE_PORT`, `DSH_RPC_BASE`, `DSH_VOICE_MODE_BASE`, `DSH_TTS_VOICE`.

**Secrets:** cookies, tokens, API keys, Pinggy URLs with credentials — local only. Commit only `*.env.example`. Scripts must not `echo` cookie values.

LLM text keys (`LLM_API_KEY` / `OPENAI_API_KEY`) are optional and separate from voice; DeepSeek is text-only (no `/v1/audio/*`).

## How to run

### Windows voice bridge

```powershell
# From repo (start.ps1 syncs server.mjs → %USERPROFILE%\dsh-voice-bridge)
powershell -ExecutionPolicy Bypass -File .\windows\dsh-voice-bridge\start.ps1

# Or metadata entry (no npm install required):
cd .\windows\dsh-voice-bridge
npm start
# equivalent: node server.mjs  (after syncing to run dir if you use that workflow)
```

Requires Node 18+ (or DSH Desktop’s bundled node). DSH Desktop must already be up for RPC/voice-mode.

### Board

```bash
adb push board/board-dsh-chat.sh /userdata/xiaozhi-cli/
# …push other board-*.sh as needed; create .env on device, never from committed secrets
adb shell 'cd /userdata/xiaozhi-cli && ./board-dsh-pair-url.sh "http://192.168.137.1:43127/pair?token=…"'
adb shell 'cd /userdata/xiaozhi-cli && ./board-dsh-chat.sh'
```

## Sync rules

1. **Repo → Windows run dir:** `windows/dsh-voice-bridge/start.ps1` copies `server.mjs` (and itself) into `%USERPROFILE%\dsh-voice-bridge\` when launched from the repo tree. Prefer editing the repo copy, then re-run `start.ps1`.
2. **Repo → board:** `adb push` selected files from `board/` to `/userdata/xiaozhi-cli/` (HDMI UI under `/userdata/dafeiyu-hdmi/`). Do not push `.env` from a shared/git tree.
3. **Docs stay docs:** `docs/` is not deployed to the board.

## What we deliberately do *not* add

- Root `package.json` / lockfile for the whole repo
- React, webpack, Vite, or other SPA toolchains
- Committing `node_modules/`, `.env`, cookies, `*.bak`, `last-*.wav`, media dumps, `__pycache__/`

## Maintainer check

```powershell
.\scripts\check-conventions.ps1
# or (Git Bash / Linux / board-side tooling):
./scripts/check-conventions.sh
```

Checks: required paths exist, shebangs on board scripts, `SCRIPT_DIR` on key scripts, no tracked `.env`, optional `shellcheck` if installed.
