# `server.mjs` 分节讲解（DSH LAN 语音桥）

路径：repo `windows/dsh-voice-bridge/server.mjs` → Windows 运行副本 `%USERPROFILE%\dsh-voice-bridge\server.mjs`。  
作用：板端 WAV → PC 本机 **ASR**（`:43129` voice-mode）→ 同会话 **`session.prompt`**（`:43127`）→ **TTS** → 音频回板。契约总览见 [`dsh-voice-bridge.md`](./dsh-voice-bridge.md)。

**端口角色**

| 端口 | 谁 | 干什么 |
|------|-----|--------|
| **43128** | 本桥 `server.mjs` | 板可直连（ICS `192.168.137.1`） |
| **43129** | `dsh-voice-mode` | loopback only：toggle / ASR / 可选 SSE |
| **43127** | 手机桥 `/api/rpc` | `session.prompt` / `session.history`（要 cookie） |

---

## 头注释与导入（1–21）

| 行 | 代码 | 含义 |
|----|------|------|
| 1–10 | shebang + 块注释 | 流水线、绑定、上游、鉴权方式（cookie 或 bridge token） |
| 11–18 | `http` / `crypto` / `child_process` / `fs` / `os` / `path` / `url` | Node 内建；无 Express |
| 20–21 | `createRequire` + `__dirname` | ESM 里 `require` 插件 CJS；定位同目录 |

## 环境常量（23–61）

| 行 / 组 | 变量 | 含义 |
|---------|------|------|
| 23–24 | `BIND` / `PORT` | 默认 `0.0.0.0:43128` |
| 25–26 | `RPC_BASE` / `VOICE_BASE` | `:43127` / `:43129`，去尾 `/` |
| 27 | `BRIDGE_TOKEN` | 可选烟测 token；**不替代** cookie 做完整 turn |
| 29–30 | `DEFAULT_VOICE` / `TTS_MODE` | 默认 `zh-CN-XiaoxuanNeural`；`edge` \| `sapi` \| `auto` |
| 32 | `TTS_PREFER_SSE` | `=1` 才优先 voice-mode SSE（易截断）；默认全文 Edge |
| 33–39 | 超时 / 稳定轮询 | ASR / prompt / SSE idle·max；`REPLY_STABLE_POLLS`×`REPLY_POLL_MS` 防流式首句 |
| 40 | `ORIGIN_RPC` | 打 RPC 时的 `Origin` |
| 41–43 | `INJECT_PREFIX` | 主动播注入历史的指令前缀（要求模型把正文放进一对【】） |
| 44–60 | `GREET_TEXT` / `PROACTIVE_LINES` | 开场句；闲置短句（可 env 覆盖，按行拆） |
| 60–61 | `GREET_ONCE` / `PROACTIVE_COOLDOWN_MS` | 每 session 问候一次；主动播冷却默认 120 s |

**概念：sessionId** — 与文本 chat 同一 `DSH_SESSION_ID`；voice-mode 也必须认这个已存在会话，否则 toggle `403 unknown_session`。

## 进程内状态（63–82）

| 行 | 结构 | 含义 |
|----|------|------|
| 64–65 | `greetedSessions` / `lastProactiveAt` | session → 上次 greet / tick 时间 |
| 67 | `inflightVoiceTurns` | 同 session 并发 voice-turn 去重 |
| 69–80 | `PLUGIN_LIB` + `MsEdgeTTS` | 从 Desktop harness 里的 `dsh-voice-mode` 加载 Edge TTS |
| 82 | `lastReply` | 上一包音频缓存（供 `/v1/last-reply`） |

## 小工具：日志 / JSON / body / Cookie / 鉴权（84–140）

| 函数 | 行 | 含义 |
|------|-----|------|
| `log` | 84–86 | ISO 时间戳 + `console.log` |
| `json` | 88–96 | JSON 响应；`no-store`；CORS `*` |
| `readBody` | 98–114 | 拼 Buffer；默认最大 16 MB（超则 413） |
| `parseCookie` | 116–125 | 简易 `Cookie` 头解析 |
| `authOk` | 127–140 | **优先** `dsh_mobile`；否则 Bearer / `X-Voice-Bridge-Token` == `BRIDGE_TOKEN` |

**概念：cookie** — 板与 chat 相同的 `dsh_mobile`；桥把它原样塞进 `:43127` 的 `Cookie` 头做 RPC。token 模式只够本机 TTS 烟测；`voice-turn` 要 `session.prompt` 时**必须** cookie。

## Multipart 与 WAV↔PCM（142–255）

| 函数 | 行 | 含义 |
|------|-----|------|
| `parseMultipart` | 142–177 | 手写 boundary；抽出 `name` / `filename` / `body`（板传 `sessionId` + `file`） |
| `wavToFloat32Mono16k` | 179–231 | 只收 PCM S16 RIFF；混成 mono；线性重采样到 **16 kHz Float32**（ASR 输入） |
| `pcmS16Wav` | 233–255 | Float32 → 16 kHz mono WAV（工具用；主路径多走 Edge MP3） |

## 上游 HTTP：`httpJson` / `rpc` / `voice*`（257–341）

| 函数 | 行 | 含义 |
|------|-----|------|
| `httpJson` | 257–298 | 低层 `http.request`；JSON 自动 parse；可超时 |
| `rpc` | 300–314 | `POST ${RPC_BASE}/api/rpc`，body `{method,payload}`，带 `dsh_mobile` |
| `voicePost` / `voiceGet` | 316–341 | 打 `:43129`；binary 时 `octet-stream` |

## Voice session 与 ASR（343–419）

| 函数 | 行 | 调用顺序要点 |
|------|-----|----------------|
| `ensureVoiceSession` | 343–351 | `POST /voice-mode/toggle` `{on:true, tabId:lan-bridge}` |
| `releaseVoiceSession` | 353–359 | `on:false`；失败忽略 |
| `waitAsrReady` | 361–375 | 轮询 `/models/status`；未就绪则 `models/retry` kind=asr |
| `asrFinal` | 377–419 | reset 段 → 按 ~0.9 s（14400 floats）分块 POST `/voice-mode/asr`；末块 `final=1`；`202/loading` 则重试 |

**概念：ASR** — Automatic Speech Recognition。板 WAV 先转 f32 PCM，再喂 voice-mode；返回 `text` 即用户口语句，再进 `session.prompt`。

## SSE 音频与截断判断（421–512）

| 函数 | 行 | 含义 |
|------|-----|------|
| `openAudioSse` | 421–503 | GET `/voice-mode/stream`；收 `event:audio` base64；idle / hard-cap 结束 |
| `sseLooksTruncated` | 505–512 | 按口播字数估最短秒数；SSE 字节过少则当截断 → 回退全文 Edge |

默认 `TTS_PREFER_SSE` 关：主路径**不**依赖 SSE。

## 历史扁平化与助手文本（514–580）

| 函数 | 行 | 含义 |
|------|-----|------|
| `flattenHistoryTurns` | 514–543 | 递归扫 history JSON，抽出 user/assistant 文本轮次 |
| `extractAssistantText` | 545–560 | 优先「某条 user 之后」的助手句；否则最后一条助手 |
| `extractLastUserText` | 562–568 | 最后一条用户句 |
| `countTrailingUserDupes` | 570–580 | 末尾连续相同 user 条数（防 voice-mode 注入 + prompt 双发） |

`recentPrompts` / `turnLocks`（582–584）：同 session+文本 15 s 内跳过重复 prompt；按 session 串行化 turn。

## 口播清洗：emotion / 【】 / CoT（586–914）

这是「只念该念的」核心。

| 函数组 | 行 | 含义 |
|--------|-----|------|
| `stripEmotion` / `stripEmotionTags` | 586–593, 686–691 | 剥 `[emotion:…]` / HTML 注释式 emotion；顺带清 markdown 噪音 |
| `hasCjk` / `isEnglishProse` / `cjkCount` / `latinCount` / `scrubLatinCrumbs` | 595–625 | 中英判断；抹掉混进中文口播的英文碎词 |
| `isCotOrToolChatter` / `stripThinkingPreamble` | 627–684 | 识别思考/工具/规划段，绝不念 |
| `EMOTION_SPECIAL` / `extractEmotionTag` | 693–728 | 白名单 pack 名；取回复里**最后**一个有效 emotion |
| `isUserEcho` | 730–744 | 复述「主人说：…」/ 主动发言指令等，不念 |
| `hasSpokenBracketMarkers` / `extractTopLevelBracketInners` / `extractOutermostSpokenBracket` | 746–798 | 深度感知取顶层【…】；多段时取最长一段 |
| `dedupeConsecutiveSentences` | 811–853 | 句级去重（短前缀/后缀重复） |
| **`spokenForTts`** | 862–914 | **硬闸**：有【】→ **只**念括号内；无【】→ 剥 thinking/EN/echo 后留中文 |

**概念：【】** — 人设约定：口播正文放进一对全角【】；思考写在外面。桥见到【】就绝不念括号外（即使外面也是中文）。

**概念：`x-emotion`** — 从回复抽 `happy`/`wink`/…，经响应头 `x-emotion`（或 JSON `emotion`）回板，驱动 HDMI 眼睛；TTS 仍剥标签只念正文。

## TTS 引擎（916–1011）

| 函数 | 行 | 含义 |
|------|-----|------|
| `wantsWav` | 916–927 | `format=wav` / Accept 更偏 wav / `DSH_TTS_FORCE_WAV` |
| `edgeTtsMp3` | 929–947 | `spokenForTts` → Edge 24 kHz 48 kbps mono MP3 |
| `sapiTtsWav` | 949–988 | PowerShell `System.Speech` 写临时 WAV（中文常弱） |
| `synthesizeReply` | 990–1011 | preferWav/sapi 先试 SAPI；否则 Edge；空则 502 |

**概念：TTS** — Text-to-Speech。本桥默认 Edge 御姐音色；voice-mode 无「任意文本 TTS」HTTP，故回复朗读靠桥内 Edge（或可选 SSE）。

## 主动播：`doSpeak` / greet / proactive / speak（1013–1197）

| 函数 | 行 | 含义 |
|------|-----|------|
| `doSpeak` | 1013–1045 | TTS；若 `inject`：需 sessionId + cookie → `session.prompt`（`INJECT_PREFIX`+正文） |
| `respondSpeak` | 1047–1074 | JSON 信封（inject/json）或裸音频；inject 失败可 **207** |
| `handleSpeak` | 1076–1105 | `POST /v1/speak` |
| `handleGreet` | 1107–1152 | 默认 once/session；始终 JSON；默认 inject |
| `handleProactiveTick` | 1154–1197 | 冷却；随机 `PROACTIVE_LINES`；默认 inject |

## 等助手稳定 + prompt 去重（1199–1296）

| 函数 | 行 | 含义 |
|------|-----|------|
| `waitStableAssistant` | 1199–1241 | 轮询 `session.history`；raw+spoken 连续稳定 N 次且 CJK≥2 才返回 |
| `promptAndWait` | 1243–1278 | 若历史已有同 user 文 / 15 s 内刚 prompt 过 → **跳过**再 prompt，只等稳定 |
| `withSessionTurnLock` | 1280–1296 | 同 session Promise 链，串行 turn |

## `handleVoiceTurn` 调用顺序（1298–1548）

板一回合主路径（`POST /v1/voice-turn`）：

1. 解析 multipart（`sessionId` + wav）或 raw audio + query `sessionId`
2. 校验：要 cookie（token 不够）；`/api/status` 验配对
3. **去重**：同 session、wav 字节接近 → await 已有 inflight；否则占坑
4. `withSessionTurnLock` 内：
   - `wavToFloat32Mono16k`
   - `ensureVoiceSession`
   - （可选）`openAudioSse`
   - `asrFinal` → `asrText`（空 → 422）
   - `promptAndWait` → `replyText`
   - `spokenForTts` / `extractEmotionTag`
   - TTS：SSE 可用且未截断则用 SSE，否则 `synthesizeReply(ttsText)`
   - `releaseVoiceSession`
5. 写 `lastReply`；响应裸音频（带头 `x-emotion` 等）或 JSON

## `handleHealth` 与路由表（1550–1697）

| 路径 | 方法 | 鉴权 | 作用 |
|------|------|------|------|
| `/` 或 `/health` | GET | 无 | 探活：listen、rpc、voice-mode、models、greet/proactive 提示 |
| `/v1/last-reply` | GET | 无* | 上一包音频（无则 404） |
| `/v1/speak` | POST | cookie 或 token | 主动 TTS；可 inject |
| `/v1/tts` | POST | 同上 | speak 别名：仅 TTS、无 inject |
| `/v1/greet` | GET/POST | 同上 | 开场；once/session |
| `/v1/proactive-tick` | GET/POST | 同上 | 闲置 nudge；cooldown |
| `/v1/voice-turn` | POST | **需 cookie**（完整 turn） | 板 ASR→prompt→TTS |
| 其他 | * | — | 404 + paths 列表 |
| OPTIONS | — | — | CORS 预检 |

`server.listen(PORT, BIND)` 打日志后挂起。

---

## 数据流一句话

板 WAV（+ `dsh_mobile` + 同会话 `sessionId`）→ `:43128` 桥转 PCM → `:43129` ASR → `:43127` `session.prompt`/history 等到稳定【】口播 → Edge TTS（+ `x-emotion`）→ 音频回板播放。

---

## 函数词典

读代码时先查这里。每条：**一句话做什么** + **何时被调用**。不含密钥/token 取值。

### Node 内建与类 curl 调用（你在文件里会看到）

| 名字 | 做什么 | 何时出现 |
|------|--------|----------|
| `http.createServer` | 建 HTTP 服务器，每个请求进回调 | 文件末尾挂路由表；`server.listen` 开听 |
| `http.request` | 主动发 HTTP 请求（类似 curl） | `httpJson`、`openAudioSse` 打上游 |
| `Buffer` | 二进制字节块（WAV/PCM/MP3/multipart） | 读 body、拼响应、ASR 切片、TTS 输出 |
| `URL` / `new URL(...)` | 解析路径、query、`format=` 等 | 路由、`wantsWav`、`voice-turn` 取 `sessionId` |
| `fetch` | **本文件不用**；上游用 `http.request` 代替 | — |
| `httpJson` | 本桥的「curl -H …」：发请求、收包、JSON 则 parse | `rpc` / `voicePost` / `voiceGet` / `/api/status` |
| `randomUUID` | 生成唯一 id | inject/`session.prompt` 的 `requestId`；SSE tabId；临时文件名 |
| `spawn` | 起子进程 | 仅 `sapiTtsWav` 调 PowerShell |
| `fs` / `os` / `path` | 写/读临时 ps1·wav；拼插件路径 | SAPI TTS、加载 `msedge-tts` |
| `createRequire` + `fileURLToPath` | ESM 里 `require` CJS；算 `__dirname` | 启动时加载 Edge TTS 插件 |
| `Promise` / `setTimeout` | 异步等待与轮询间隔 | ASR 就绪、history 稳定、SSE idle |

### 日志 / 响应 / Body / 鉴权

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `log` | 打带 ISO 时间戳的 `console.log` | 全程诊断（turn/asr/reply/sse/tts） |
| `json` | 写 JSON 响应（`no-store` + CORS `*`） | 错误、探活、JSON 信封、`207` inject 失败等 |
| `readBody` | 把请求体拼成一个 `Buffer`（默认可到 16 MB，超则 413） | multipart/`voice-turn`、speak/greet/tts POST |
| `parseCookie` | 把 `Cookie` 头拆成键值表 | `authOk` |
| `authOk` | 校验鉴权：优先 `dsh_mobile` cookie，否则 Bearer/`X-Voice-Bridge-Token` | 每个受保护路由入口 |

### Multipart 与音频格式

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `parseMultipart` | 手写拆 multipart，抽出字段 `name`/`filename`/`body` | `handleVoiceTurn` 收到 `multipart/form-data` |
| `wavToFloat32Mono16k` | RIFF PCM S16 → 单声道 16 kHz Float32（ASR 输入） | voice-turn 拿到 wav 之后 |
| `pcmS16Wav` | Float32 → 16 kHz mono WAV 文件头+数据 | 工具路径；主路径多走 Edge MP3 |

### 上游 HTTP 封装

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `httpJson` | 低层 HTTP：可选 body/超时；JSON 自动 parse | 所有出站调用的底座 |
| `rpc` | `POST :43127/api/rpc`，body `{method,payload}`，带 `dsh_mobile` | `session.prompt` / `session.history`；inject |
| `voicePost` | `POST :43129`（JSON 或 binary octet-stream） | toggle、ASR、models/retry |
| `voiceGet` | `GET :43129` | models/status、health 探 voice-mode |

### Voice session 与 ASR

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `ensureVoiceSession` | `toggle` `{on:true, tabId:lan-bridge}` 打开该 session 语音态 | voice-turn 锁内、ASR 之前 |
| `releaseVoiceSession` | `toggle` `{on:false}`；失败忽略 | voice-turn `finally`，无论成败 |
| `waitAsrReady` | 轮询 models/status；未就绪则 retry 拉 ASR 模型 | `asrFinal` 开头 |
| `asrFinal` | reset 段 → 按 ~0.9 s 块 POST ASR；末块 `final=1`；返回转写文本 | voice-turn 在 PCM 就绪后 |

### SSE 音频

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `openAudioSse` | GET `/voice-mode/stream`，收 `event:audio` base64；idle/硬上限结束 | 仅 `TTS_PREFER_SSE=1` 时与 ASR/prompt 并行开 |
| `sseLooksTruncated` | 按口播字数估最短秒数；SSE 字节过少 → 当截断 | SSE 收完后，决定是否回退 Edge |

### 历史与 prompt 去重

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `flattenHistoryTurns` | 递归扫 history JSON，抽出 user/assistant 文本轮次 | 所有 history 抽取的底层 |
| `extractAssistantText` | 取「某条 user 之后」或最后一条助手句 | `waitStableAssistant` |
| `extractLastUserText` | 取最后一条用户句 | `promptAndWait` 判断是否已注入 |
| `countTrailingUserDupes` | 末尾连续相同 user 条数 | 防 voice-mode 注入 + prompt 双发 |
| `waitStableAssistant` | 轮询 history；raw+spoken 连续稳定 N 次且 CJK≥2 才返回 | `promptAndWait` 之后等回复 |
| `promptAndWait` | 必要时 `session.prompt`，否则跳过重复；再等稳定助手句 | voice-turn 在 ASR 文本到手后 |
| `withSessionTurnLock` | 同 session 用 Promise 链串行化 | voice-turn 包住整段 ASR→TTS |

### 口播清洗（只念该念的）

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `stripEmotion` | 剥 `[emotion:…]`/注释式 emotion，顺带清 markdown 噪音 | TTS 日志对比前后 |
| `stripEmotionTags` | 只剥 emotion 标签，保留其余正文 | 括号内清洗、`spokenForTts` |
| `hasCjk` | 是否含中日韩字符 | 英/中分流、稳定判定门槛 |
| `isEnglishProse` | 是否基本是英文散文（无 CJK） | 无【】回退路径丢英文段 |
| `cjkCount` / `latinCount` | 统计汉字/拉丁字母个数 | 比例过滤、稳定门槛 |
| `scrubLatinCrumbs` | 抹掉混进中文口播的英文碎词 | `spokenForTts`、括号体清洗 |
| `isCotOrToolChatter` | 是否思考/工具/规划段（绝不念） | 句级过滤、`dedupe` |
| `stripThinkingPreamble` | 去掉 thinking 标签与「思考：」类前缀 | 无【】时的回退清洗 |
| `extractEmotionTag` | 取回复里**最后**一个白名单 emotion 名 | voice-turn → `x-emotion` / JSON |
| `isUserEcho` | 是否复述「主人说：…」/指令原文（不念） | 句级过滤 |
| `hasSpokenBracketMarkers` | 是否同时出现【与】 | `spokenForTts` 硬闸入口 |
| `extractTopLevelBracketInners` | 深度感知抽出所有顶层【…】内文 | `extractOutermostSpokenBracket` |
| `extractOutermostSpokenBracket` | 多段顶层【】时取最长一段 | 有【】时的口播正文 |
| `normSentenceKey` | 去空白/标点后的句指纹 | `dedupeConsecutiveSentences` |
| `dedupeConsecutiveSentences` | 句级去重（含短前缀/后缀重复） | `spokenForTts` 出口 |
| **`spokenForTts`** | **硬闸**：有【】只念括号内；无【】则剥 thinking/EN/echo 留中文 | 一切 TTS 前；稳定判断也用 |

### TTS 与主动播

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `wantsWav` | 客户端是否明确更想要 WAV | voice-turn 选引擎格式 |
| `edgeTtsMp3` | `spokenForTts` → Edge 24 kHz 48 kbps mono MP3 | `synthesizeReply` 默认路径 |
| `sapiTtsWav` | PowerShell `System.Speech` 写临时 WAV | `preferWav` 或 `TTS_MODE=sapi` |
| `synthesizeReply` | 编排 SAPI/Edge；空音频 → 502 | voice-turn、speak、`/v1/tts` |
| `doSpeak` | TTS；若 `inject` 则带 cookie 调 `session.prompt` 写入历史 | greet / proactive / speak |
| `respondSpeak` | JSON 信封（含 base64）或裸音频写出 | `doSpeak` 之后 |
| `handleSpeak` | 处理 `POST /v1/speak` | 路由表 |
| `handleGreet` | 开场白；默认 once/session + inject；始终 JSON | `GET/POST /v1/greet` |
| `handleProactiveTick` | 冷却内跳过；否则随机闲置短句 + inject | `GET/POST /v1/proactive-tick` |

### 主回合与探活

| 函数 | 做什么 | 何时调用 |
|------|--------|----------|
| `handleVoiceTurn` | 板一回合：WAV→ASR→prompt→口播清洗→TTS→回音频 | `POST /v1/voice-turn` |
| `handleHealth` | 汇总 listen/rpc/voice-mode/models 与用法提示 | `GET /` 或 `/health` |

### 进程内 Map / 缓存（不是函数，但常一起读）

| 名字 | 做什么 | 何时读写 |
|------|--------|----------|
| `greetedSessions` | 已问候过的 session | `handleGreet` |
| `lastProactiveAt` | 上次主动播时间 | `handleProactiveTick` |
| `inflightVoiceTurns` | 同 session 并发 voice-turn 去重 | `handleVoiceTurn` 入口/出口 |
| `recentPrompts` | 同 session+文本 15 s 内跳过再 prompt | `promptAndWait` |
| `turnLocks` | session → Promise 链 | `withSessionTurnLock` |
| `lastReply` | 上一包音频缓存 | TTS 成功后；`GET /v1/last-reply` |
