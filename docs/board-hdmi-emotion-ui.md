# Board HDMI emotion UI（XR-32）

Board: TL3576-EVM-H · path: **HDMI + DRM**（Weston or fb0）· persona vibe only: [dafeiyu-persona.md](./dafeiyu-persona.md)  
Voice sync: reply `[emotion:…]` / bridge `x-emotion` → eyes during TTS — [board-voice-emotion-sync.md](./board-voice-emotion-sync.md)  
FPS: capped **`EMOTION_FPS=12`**; offscreen present. IPD **`EYE_SEP=1.4`**; elliptical **`EYE_GAP_X=1.28`**; **`EYE_SCALE=1.25`** tuned at **`EYE_REF=1024×600`** and remapped onto the active CRTC (so 1920×1080 keeps that apparent size). Idle lively: blink + look-around + drift + breath (`IDLE_LIVELY=1`). Special hold auto→idle; bake cache evicts non-idle packs (no OOM after remap). Chat voice sync: [board-voice-emotion-sync.md](./board-voice-emotion-sync.md).

## Principle

1. **Full-bleed black** — stock image sets `WESTON_DRM_KEEP_RATIO=1` (mirror keep-aspect) → letterbox / 「铺不满」. Emotion bring-up forces `KEEP_RATIO=0`, shell `background-color=0xFF000000`, `panel-position=none`. Default request **`HDMI_MODE=1024x600`** (override for 1440x900 etc.); **centering uses the active HDMI CRTC/plane**, not `modes[0]` alone.
2. **Only this look** — kill `weston-terminal` / flower / chat overlay; no desktop launchers while UI runs.
3. **Scene** — centered white eyes (pair midline on scanout center); Chromium path may still show fish.
4. **Thin control plane** — local HTTP emotion stub; eth0 ICS + DSH left intact.

## FB snow / top-left eyes (fix)

**Cause:** After Weston stop, HDMI CRTC often stays **1920×1080** while `emotion_fb` used preferred **`modes[0]=1024x600`**, so eyes were drawn only in the top-left 1024×600 and the rest of the plane looked like snow/garbage. First chat line merely coincided with bake finishing.

**Fix:** Clear opaque black + DRM settle before first present; detect **active** HDMI CRTC/plane src (1024×600 / 1440×900 / 1920×1080); present idle frame 0 ASAP. Board path: **`/userdata/dafeiyu-hdmi/`** (also `/opt/dafeiyu-hdmi/` if present).

## On-board client

Install tree (also mirrored in store):

`docs/cli-llm-chat/hdmi-emotion-ui/` → board **`/userdata/dafeiyu-hdmi/`** (and `/opt/dafeiyu-hdmi/` when used)

| File | Role |
|------|------|
| `emotion_fb.py` | **Default** renderer: `/dev/fb0` black + fish + eyes (Weston stopped) |
| `index.html` + Chromium | Optional kiosk (`BACKEND=chromium`) on Weston |
| `emotion_api.py` | Emotion stub on `127.0.0.1:8765` |
| `board-hdmi-emotion-start.sh` | Full-bleed knobs + launch |
| `board-hdmi-emotion-set.sh` | Set state |
| `board-hdmi-emotion-stop.sh` | Stop (`RESTORE=1` restores desktop ini) |

### Launch

```sh
# default: fb backend (recommended) — eyes appear after black settle, no chat needed
/userdata/dafeiyu-hdmi/board-hdmi-emotion-start.sh
# or: restart board-dsh-chat.sh (auto-starts BACKEND=fb if API down)

# optional Weston + Chromium kiosk
BACKEND=chromium /userdata/dafeiyu-hdmi/board-hdmi-emotion-start.sh

/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh happy
/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh listening
/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh thinking
/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh speaking
/userdata/dafeiyu-hdmi/board-hdmi-emotion-set.sh idle
```

### Emotion API stub

States: **`idle` | `happy` | `listening` | `thinking` | `speaking`**

Idle variants: `blink` · `look-left` · `look-right` · `look-up` · `sleepy` · `curious` · `squint`

```text
GET  /api/emotion
POST /api/emotion   {"state":"happy"}
GET  /api/emotion/set?state=listening
PUT  /api/emotion/thinking
```

## Proof notes (2026-10-27)

| Item | Status |
|------|--------|
| Deploy to `/opt/dafeiyu-hdmi` | Done over SSH |
| `WESTON_DRM_KEEP_RATIO` → `0` + `99-dafeiyu-emotion.ini` + mode `1440x900` | Applied |
| Extras cancelled (terminal/flower/overlay) | Applied on start |
| Emotion API `:8765` | Came up; states exercised once |
| Chromium kiosk attempt | Process started; **board then dropped off ICS** (`192.168.137.2` unreachable). Prefer **`BACKEND=fb`** thereafter |
| Physical HDMI eyes+fish proof | **Blocked** until board returns (power cycle / free serial `/dev/ttyUSB1` from picocom + re-static eth0) |
| Screenshots | Still hard under Weston (`weston-screenshooter` unauthorized; fb0 not front buffer while Weston owns planes). fb backend can be dumped from `/dev/fb0` once live |

Keep ICS: start script does not rewrite eth0 unless address missing or `ETH0_STATIC=1`.
