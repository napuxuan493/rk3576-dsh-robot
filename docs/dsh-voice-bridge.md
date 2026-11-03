# DSH LAN voice bridge（板 ↔ PC）

目标：**同一 DSH 会话** — CON24 录音 wav → Windows ASR → `session.prompt` → TTS → wav/mp3 回板 `aplay`。  
**不用** DeepSeek `/v1/audio/*`。PC 用已装 **`dsh-voice-mode`** + 手机桥 `:43127`。

| 字段 | 值 |
|------|-----|
| **Listen URL** | **`http://192.168.137.1:43128`**（绑定 `0.0.0.0:43128`；本机 `http://127.0.0.1:43128`） |
| 板脚本 | [`board/board-voice-once.sh`](../board/board-voice-once.sh)；PTT：[`board-ptt-key5.md`](./board-ptt-key5.md) / `board-ptt-hold.sh` |
| 文本会话 | 同 [`board-dsh-chat.sh`](../board/board-dsh-chat.sh)：`DSH_MOBILE_COOKIE` + **`DSH_SESSION_ID`** |
| 手机桥聊天 | `:43127` `/api/rpc` |
| voice-mode | `:43129` `/voice-mode/*` **loopback only** — 桥在本机代调 |
| 实现 | [`windows/dsh-voice-bridge/server.mjs`](../windows/dsh-voice-bridge/server.mjs) → 运行副本 `%USERPROFILE%\dsh-voice-bridge\` |
| **默认音色** | **`zh-CN-XiaoxuanNeural`**（御姐向；`DSH_TTS_VOICE` + voice-mode settings） |
| 插件说明 | [`dsh-voice-plugins.md`](./dsh-voice-plugins.md) |
| 御姐样例 | [`media/dafeiyu-yujie-xiaoxuan.mp3`](../media/dafeiyu-yujie-xiaoxuan.mp3) |

## 启动（Windows，Desktop 须已开）

```powershell
# 推荐：从 Project store 脚本启动（会同步到 %USERPROFILE%\dsh-voice-bridge）
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\dsh-voice-bridge\start.ps1"
# 或直接：
cd $env:USERPROFILE\dsh-voice-bridge
node .\server.mjs
```

可选环境变量见 [`windows/dsh-voice-bridge/env.example`](../windows/dsh-voice-bridge/env.example)。  
防火墙：入站 **TCP 43128**（建议仅 `192.168.137.0/24`），与 43127 同策略。

冒烟：

```powershell
curl http://127.0.0.1:43128/health
curl http://192.168.137.1:43128/health
```

本机已冒烟（2026-10-28）：`/health` → 200；`asrReady:true`；`ttsVoice=zh-CN-XiaoxuanNeural`；`POST /v1/speak` → `audio/mpeg`；ICS `192.168.137.1:43128` 可达。

**Status 2026-11-02 ~09:50 Asia/Shanghai：** bridge restarted (`start.ps1`) → `0.0.0.0:43128` listening；`127.0.0.1` + `192.168.137.1` `/health` **200** `asrReady:true` `tts.engine=edge` `ttsVoice=zh-CN-XiaoxuanNeural`；DSH Desktop **yes** (`:43129` voice-mode enabled). Board can re-run `./board-dsh-chat.sh` / greet.

### 板端 E2E（2026-10-28 ~17:36 Asia/Shanghai，**无 flash**）

| 检查 | 结果 |
|------|------|
| Pair | `192.168.137.1:43127/pair?token=***` → **302** + cookie；`/api/status` → **200** `connected` |
| ICS / bridge | eth2 `.2`；`GET :43128/health` → **200** |
| 旧 `DSH_SESSION_ID=session-dafeiyu-smoke-…` | voice-turn **403** `unknown_session`（list 里有但 voice-mode 不认） |
| `session.create` → 新 SID | 已写入 `.env`；sine 试音 → **422** ASR empty（预期） |
| 真人 6 s `board-voice-once` | turn **200** `audio/mpeg`（Edge）→ mpg123→sox **48 kHz stereo** → `aplay hw:0,0` **OK**（初版 24 kHz mono 失败后已修脚本并重播） |

**请用户确认：** 耳机 CON24 是否听到回复朗读。

### TTS 截断修复烟测（2026-10-29 ~10:44 Asia/Shanghai，**无 flash**）

| 检查 | 结果 |
|------|------|
| 根因 | 流式 `history` 首段即 TTS；旧 SSE 亦易半截 |
| 修复 | stable polls → **Edge 全文**；`x-tts-engine=edge` |
| 板 curl turn | **115632 B** mp3，`x-reply-chars=158`，CL 匹配（旧 ~10 KB） |
| KEY5 | 收发已 OK；**请再听一轮是否整段** |

## HTTP 契约

### Auth

| 方式 | 用法 |
|------|------|
| **Cookie `dsh_mobile`**（板默认） | 与 chat 相同；桥转发到 `:43127` 做 `session.prompt` |
| `X-Voice-Bridge-Token` / `Authorization: Bearer` | 等于环境变量 `DSH_VOICE_BRIDGE_TOKEN`（本机烟测）；**不能**替代 cookie 做完整 turn |

### `GET /health`（或 `GET /`）

```json
{
  "ok": true,
  "listen": "http://0.0.0.0:43128",
  "voice": { "ok": true, "enabled": true },
  "models": { "asrReady": true, "tts": { "engine": "edge", "ready": true } },
  "headless": { "...": "see response" }
}
```

### 御姐音色（Edge）

| ShortName | 结果 | 备注 |
|-----------|------|------|
| **`zh-CN-XiaoxuanNeural`** ★ | 合成 OK（~32 KB 样例） | **默认**；偏成熟、稳，接近御姐 |
| `zh-CN-XiaoyiNeural` | OK（官方 voices 列表内） | 备选；略偏活泼 |
| `zh-CN-XiaoxiaoNeural` | OK（列表内） | 偏甜/邻家，不作御姐默认 |
| Xiaochen / Xiaomeng / Xiaohan… | 本机合成失败 | 未采用 |

已写入：

- 桥：`DSH_TTS_VOICE=zh-CN-XiaoxuanNeural`（`env.example`）
- voice-mode：`POST /voice-mode/settings` + `%APPDATA%\dsh-desktop\harness\voice-mode.settings.json` → `voice` / `rate:1.05`

### 主动开口总览（greet / idle / speak）

同一 DSH 会话里，桥在**没有板端 ASR**时也能先说话：TTS（默认御姐 `zh-CN-XiaoxuanNeural`）+ 可选 `session.prompt` inject。

| 入口 | 用途 | once / cooldown |
|------|------|------------------|
| **`POST /v1/greet`** | 配对后 / 聊天或 voice-once 开场问候 | 默认 **每 session 一次**（`force:true` 可再发） |
| **`POST /v1/proactive-tick`** | 闲置 nudge（随机短句） | 默认冷却 **120 s**/session（`DSH_PROACTIVE_COOLDOWN_MS`） |
| **`POST /v1/speak`** | 任意主动播 | 无 once；由调用方控制 |

板脚本：

| 脚本 | 何时 |
|------|------|
| [`board-greet.sh`](../board/board-greet.sh) | `board-dsh-chat.sh` / `board-voice-once.sh` 开场；可选 `GREET_ON_PAIR=1` 于 [`board-dsh-pair.sh`](../board/board-dsh-pair.sh) |
| [`board-proactive-tick.sh`](../board/board-proactive-tick.sh) | `VOICE_IDLE_SECS` / `PROACTIVE_IDLE_S` 后台循环；或手动 |
| [`board-tts-pull.sh`](../board/board-tts-pull.sh) | 任意 `/v1/speak` |

板 `.env`：`VOICE_GREET=1`（默认）、`VOICE_IDLE_SECS=180`（可选）、见 [`board-dsh.env.example`](../board/board-dsh.env.example)。

人设：[`dafeiyu-persona.md`](./dafeiyu-persona.md) §主动说话；改完按 [`dsh-dafeiyu-persona-setup.md`](./dsh-dafeiyu-persona-setup.md) 灌入 `cordis.patch.yml` 并重启 Desktop。

### `POST /v1/greet`

```http
POST /v1/greet
Cookie: dsh_mobile=<same-as-chat>
Content-Type: application/json
Accept: application/json

{ "sessionId": "<DSH_SESSION_ID>", "inject": true, "force": false }
```

| 字段 | 说明 |
|------|------|
| `sessionId` | 推荐；用于 once/session 与 inject |
| `inject` | 默认 `true`（有 cookie+session 时写入 Desktop） |
| `force` | `true`：忽略已问候 |
| `text` | 可选；默认 `DSH_GREET_TEXT`（大肥鱼开场） |
| `voice` | 可选；默认御姐 |

**响应：** 始终 JSON：`audio_b64` / `injected` / `voice`；若已问候则 `skipped:true` `reason:already_greeted`（无新音频）。

```bash
./board-greet.sh
GREET_FORCE=1 ./board-greet.sh
```

本机冒烟（2026-10-28）：`POST /v1/greet` + fake cookie → **200** `kind=greet` `mime=audio/mpeg` `audio_b64`≈46 KB；同 session 再调 → `skipped:already_greeted`。板端 aplay 需 USB 连着且 `.env` cookie 有效（当前 adb 无设备，板冒烟待插板）。

### `POST /v1/proactive-tick`

```http
POST /v1/proactive-tick
Cookie: dsh_mobile=<same-as-chat>
Content-Type: application/json

{ "sessionId": "<DSH_SESSION_ID>", "inject": true }
```

随机取 `DSH_PROACTIVE_LINES`（或 body.`text`）。冷却内返回 `skipped:true` `reason:cooldown` + `retry_after_ms`。

```bash
# chat 内：VOICE_IDLE_SECS=180 ./board-dsh-chat.sh
./board-proactive-tick.sh
PROACTIVE_FORCE=1 ./board-proactive-tick.sh
```

### `POST /v1/speak`（主动开口，无板端 ASR）

Desktop / 板端 / 定时任务都可以先推一句，不必等人说话。

```http
POST /v1/speak
Cookie: dsh_mobile=<same-as-chat>   # 或 X-Voice-Bridge-Token（仅 TTS；inject 仍要 cookie）
Content-Type: application/json

{
  "text": "哼，主人终于想起本鱼了？过来听听本鱼说话。",
  "sessionId": "<optional DSH_SESSION_ID>",
  "voice": "zh-CN-XiaoxuanNeural",
  "inject": false
}
```

| 字段 | 说明 |
|------|------|
| `text` | 必填；要朗读的正文 |
| `sessionId` | 可选；与文本 chat 同会话 |
| `inject` | `true`：经 `:43127` `session.prompt` 注入「【主动发言指令】…」让大肥鱼在历史里落一条助手回复（需 cookie + 有效 session） |
| `voice` | 可选；默认 `DSH_TTS_VOICE` |
| `format` / `?format=` | `json` → 信封；`wav` → 尝试 SAPI（中文弱） |

**成功：** `200` + `audio/mpeg`（默认），或 JSON（`inject` / `format=json`）含 `audio_b64`、`injected`。

**板端触发示例：**

```bash
curl -sS -m 60 -X POST "${DSH_VOICE_BRIDGE_URL}/v1/speak" \
  -H "Cookie: dsh_mobile=${DSH_MOBILE_COOKIE}" \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"主人，本鱼等你好久了。\",\"sessionId\":\"${DSH_SESSION_ID}\",\"inject\":true}" \
  -o /userdata/xiaozhi-cli/proactive.mp3
# 再 mpg123/sox → aplay（同 voice-once）
```

**Desktop / PC 触发：**

```powershell
curl.exe -sS -X POST "http://127.0.0.1:43128/v1/speak?format=json" `
  -H "X-Voice-Bridge-Token: $env:DSH_VOICE_BRIDGE_TOKEN" `
  -H "Content-Type: application/json; charset=utf-8" `
  --data-binary "@speak.json" -o speak-out.json
```

### `POST /v1/voice-turn`（板一回合）

```http
POST /v1/voice-turn
Cookie: dsh_mobile=<same-as-chat>
Origin: http://192.168.137.1:43127
Content-Type: multipart/form-data

sessionId=<DSH_SESSION_ID>
file=<utt.wav; audio/wav>   # PCM S16 LE；16 kHz；mono 或 stereo
```

可选：`Accept: application/json` 或 `?format=json` → JSON 信封。

**成功（优先）：** `200` + `Content-Type: audio/mpeg`（Edge / voice-mode SSE）或 `audio/wav`（`DSH_TTS_FORCE_WAV=1` / SAPI）。

**眼睛情绪：** 从回复里的 `[emotion:xxx]` / `<!--emotion:xxx-->` 提取（最后一条有效 pack 名），经 **`x-emotion: happy`** 响应头返回；`?format=json` 时另有字段 **`emotion`**。TTS 口播仍剥掉该标签，只合成【】内正文。板端 `board-voice-once.sh` 读 `x-emotion` 调 HDMI emotion API。

板端 `aplay` **只认 WAV**：若收到 `audio/mpeg`，板上先转：

```bash
# 若有 ffmpeg / mpg123
ffmpeg -y -i last-reply.mp3 last-reply.wav && aplay -D hw:0,0 last-reply.wav
```

或桥侧设 `DSH_TTS_FORCE_WAV=1`（Windows SAPI，音质一般；中文依赖系统语音包）。

**JSON 备选：**

```json
{
  "ok": true,
  "asr_text": "…",
  "reply_text": "…",
  "tts_text": "…",
  "emotion": "happy",
  "tts": "voice-mode-sse|edge|sapi",
  "mime": "audio/mpeg",
  "audio_b64": "…",
  "audio_url": "/v1/last-reply"
}
```

### 内部流水线（同会话）

1. `POST 127.0.0.1:43129/voice-mode/toggle` `{sessionId, on:true}`  
2. 等 ASR 模型就绪；`POST /voice-mode/asr?sessionId=&final=1`（body = f32 LE 16 kHz PCM）  
3. `POST 43127/api/rpc` `session.prompt`（同一 `sessionId` + `dsh_mobile`）  
4. 轮询 `session.history` 直到助手正文**稳定**（连续 `DSH_REPLY_STABLE_POLLS` 次相同；避免流式只拿到首句）  
5. **TTS（只读【】口播）：** 稳定后的 `reply_text` 经 `spokenForTts`：若有全角 `【…】` → **只合成括号内**（思考写在【】外）；否则回退剥 thinking/EN；并剥 `[emotion:…]`。Edge `zh-CN-XiaoxuanNeural`。  
   - 人设强制【】：[`dafeiyu-persona.md`](./dafeiyu-persona.md) §怎么说话。  
   - 默认不用 SSE；可选 `DSH_VOICE_TTS_SSE=1`。  
6. `toggle on:false`

### `POST /v1/tts`（板端「主动播」现用）

JSON `{"text":"…"}` → `audio/mpeg`（Edge）或 wav。需 cookie 或 bridge token。  
板脚本：[`board/board-tts-pull.sh`](../board/board-tts-pull.sh)

```bash
./board-tts-pull.sh '你好，我是小智'     # 无麦，只拉 TTS 播放
SPEAK_TEXT='待机中' ./board-voice-once.sh  # 同助手入口
```

### `POST /v1/speak`（主动播，已上线）

JSON `{ "text", "sessionId"?, "voice"?, "inject"? }` → 默认 **`zh-CN-XiaoxuanNeural`（御姐）** Edge `audio/mpeg`。  
`inject:true` + cookie + sessionId → 同时 `session.prompt` 进 Desktop（可能 JSON 信封）。  

板端冒烟（2026-10-28 ~17:50）：`./board-tts-pull.sh '你好，我是大飞鱼'` → `/v1/speak` **200** → 48 kHz aplay **exit 0**（`TTS_SOX_GAIN=1`）。样例 mp3：[`media/dafeiyu-yujie-xiaoxuan.mp3`](./media/dafeiyu-yujie-xiaoxuan.mp3)。

**聊天 / voice 开场自动问候：** `board-dsh-chat.sh` 与 `board-voice-once.sh` 在拿到 `SESSION_ID` 后默认 `VOICE_GREET=1` / `GREET_ON_START=1` → [`board-greet.sh`](../board/board-greet.sh) → **`POST /v1/greet`**（`inject:true`，once/session）。可选 `VOICE_IDLE_SECS` / `PROACTIVE_IDLE_S`（秒）后台调 [`board-proactive-tick.sh`](../board/board-proactive-tick.sh)。`GREET_ON_PAIR=1` 可在 pair 成功后问候一次。无 `board-greet.sh` 时 chat 回退 `SPEAK_INJECT=1 board-tts-pull`。
### `GET /v1/last-reply`

上一回合音频缓存。

## voice-mode 无头能力（实测）

| 能力 | 无头？ | 说明 |
|------|--------|------|
| `GET /voice-mode` | 是 | `enabled` / `active` |
| `GET /voice-mode/models/status` | 是 | 首次需下载 zipformer；本机已 `asrReady:true` |
| `POST /voice-mode/toggle` | 是* | *`sessionId` 必须是 Desktop **已存在**会话，否则 403 `unknown_session` |
| `POST /voice-mode/asr` | 是* | *须先 toggle；body 为 raw f32 PCM，不是 wav |
| `POST /voice-mode/preview` | 是 | **固定试听句**，不能合成任意回复文本 |
| 任意文本 TTS HTTP | **否** | 无 `/voice-mode/tts?text=`；回复朗读靠 UI 流式 tap → SSE `audio`，或桥内 Edge 回退 |
| 板直连 `:43129` | **否** | loopback + `allowLan=false`；必须走本桥 `:43128` |

## 板端用法

```bash
# ICS
/etc/init.d/S42xiaozhi-ics start

cd /userdata/xiaozhi-cli
# .env: DSH_MOBILE_COOKIE + DSH_SESSION_ID + DSH_VOICE_BRIDGE_URL=http://192.168.137.1:43128
./board-voice-once.sh
```

桥未起：exit **5**。HTTP 非 200：exit **6**。

## 与 OpenAI / DeepSeek speech

| 路径 | 状态 |
|------|------|
| DeepSeek key | **仅文本** |
| `board-asr-once.sh` / 独立 speech 厂商 | 旧钩子；本桥路径不依赖 |
| 本 LAN bridge | **首选**板语音闭环（同会话） |
