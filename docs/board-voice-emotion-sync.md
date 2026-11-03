# Voice ↔ HDMI eyes sync

Wire reply `[emotion:xxx]` (or bridge `x-emotion`) to `/userdata/dafeiyu-hdmi` during TTS; idle after. **No flash.**

| Piece | Role |
|-------|------|
| Bridge | Already parses tag → header **`x-emotion`** + JSON `emotion` on `/v1/voice-turn` |
| `board-emotion-voice.sh` | ensure UI · parse tag · `play-start` / `play-end` (**force**) |
| `board-dsh-chat.sh` | text TTS path: parse tag → `play-start` **during** TTS → `play-end` → idle |
| `board-voice-once.sh` | read `x-emotion` (or JSON); set eyes for aplay duration; idle after |
| `board-ptt-hold.sh` | on reply aplay: read `last-reply.wav.emotion`; same play-start/end |
| Assets | `/userdata/animation-assets/rk3576-robot-eyes/fb-raw` via `emotion_fb` |

## Flow

1. KEY5 / voice-once / text chat → reply with e.g. `【…】[emotion:happy]`
2. TTS (【】 only) + eyes = tagged emotion (else **`speaking`**)
3. Board: `play-start <emo> <hold>` (**force**) → aplay/TTS → `play-end` → **idle** (`force`)
4. Wait/idle: stay **`idle`** so `IDLE_LIVELY` does blink + look-around + drift + breath (no special rotation)

Special hold auto-expires → **idle** (confused can leave). Non-loop clips `force` idle when done. Bake cache keeps idle/blink/look only (1080p remap otherwise OOM).

## Commands

```bash
BACKEND=fb /userdata/dafeiyu-hdmi/board-hdmi-emotion-start.sh   # once
/userdata/xiaozhi-cli/board-emotion-voice.sh parse '【嗨】[emotion:wink]'
/userdata/xiaozhi-cli/board-emotion-voice.sh play-start happy 5
/userdata/xiaozhi-cli/board-emotion-voice.sh play-start confused 3
/userdata/xiaozhi-cli/board-emotion-voice.sh play-end
# EMOTION_ENABLE=0 to disable
```

**Knobs (keep):** `EMOTION_FPS=12` · `EYE_SEP=1.4` · `EYE_GAP_X=1.28` · `EYE_SCALE=1.25` (+ ref remap) · `IDLE_LIVELY=1`

## Smoke (2026-11-02 board)

| Check | Result |
|-------|--------|
| `scale=2.160` / `EYE_SEP=1.4` / `IDLE_LIVELY=1` | OK (CRTC center kept) |
| play-start happy → confused → play-end | API idle; bake drop; animates |
| special hold expire | auto → idle (confused can leave) |
| wait idle | `play blink` + `play look_around` (no special cycle) |
| text chat `[emotion:…]` | `play-start` during TTS (restart `board-dsh-chat.sh`) |
