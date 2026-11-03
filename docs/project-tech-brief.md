# TL3576 小智 / 大肥鱼 — 技术深讲提纲

> 讲解用：八节硬知识 + 脚本讲解。无 secrets。板上路径以 `/userdata/…` 为准；仓库镜像在 store `docs/`。

延伸细节：
[board-headset-audio.md](./board-headset-audio.md) ·
[board-ptt-key5.md](./board-ptt-key5.md) ·
[board-postflash-restore.md](./board-postflash-restore.md) ·
[dsh-board-client.md](./dsh-board-client.md) ·
[dsh-dafeiyu-persona-setup.md](./dsh-dafeiyu-persona-setup.md) ·
[dsh-voice-bridge.md](./dsh-voice-bridge.md) ·
[board-hdmi-emotion-ui.md](./board-hdmi-emotion-ui.md) ·
[board-voice-emotion-sync.md](./board-voice-emotion-sync.md)

---

## 1. 设备树与外设

| 外设 | 硬件 / Linux | DT / 驱动落点（项目文档已确认） |
|------|--------------|----------------------------------|
| **耳机检测 hp-det** | GPIO4_PB2 → **gpio-138**；插耳物理 **低电平** | SDK：`kernel-6.1/.../tl3576-evm.dts`、`sbc-tl3576-base.dtsi` 中 `hp-det-gpio` 改为 **`GPIO_ACTIVE_LOW`**（原 ACTIVE_HIGH → Jack 永远 off → LOUT1 不上电）。DTB 打进 **boot.img FIT 的 `fdt`**，无独立 dtb 分区。交付图：`media/tl3576-hp-det-boot.img`（用户自刷 boot only）。 |
| **耳机座 CON24** | 丝印 LINE IN；**实测 hp-det + 可听放音 + 麦** 均在 CON24（CON23 丝印 HP/MIC，与实测错位） | 同一 ALSA 卡；Jack 读-only，Jack=off 时靠强制 HP 路径出声 |
| **hp-con** | **gpio-490**（xl8574t P2，DT ACTIVE_HIGH） | DAPM Headphone PMU 或 `amixer sset "hp switch" on` → `out hi` |
| **KEY5 PTT** | 丝印 KEY5；原理图 **GPIOB3** → **gpio-43**；`/dev/input/event7`（`gpio-keys`） | DT：`gpio-keys` / `user_key0`：`gpios = <&gpio1 RK_PB3 GPIO_ACTIVE_LOW>`，`linux,code = <KEY_PROG2>`（149），label `user-key1`。**勿** `export 43`（已被占用）。 |
| **声卡** | ES8388 | ALSA card0 名 **`rockchip-es8388`**，设备 **`hw:0,0`**（播/录同设备） |
| **HDMI 眼睛** | DRM/`rockchipdrm`；UI 默认停 Weston，写 **`/dev/fb0`** | 应用层：`/userdata/dafeiyu-hdmi/emotion_fb.py`（非内核新节点） |

**口述要点：** 极性错了 Jack 压死 DAPM；改 DT 必须整包 boot，Agent 默认不 flash。KEY5 走 evdev，不走 sysfs export。

---

## 2. 驱动资源发现与 Mixer

**发现顺序（板上）：**

```bash
cat /proc/asound/cards          # rockchip-es8388
arecord -l / aplay -l          # card0 device0 → hw:0,0
amixer -c 0 contents | head    # 控件清单
grep -E '138|490|43' /sys/kernel/debug/gpio
```

**一键强制声路：** `/userdata/xiaozhi-cli/board-audio-up.sh`  
（store：[`docs/cli-llm-chat/board-audio-up.sh`](./cli-llm-chat/board-audio-up.sh)）  
开机：`/userdata/xiaozhi-cli/S43xiaozhi-audio.sh` → `/etc/init.d/S43xiaozhi-audio`  
（store：[`docs/cli-llm-chat/S43xiaozhi-audio.sh`](./cli-llm-chat/S43xiaozhi-audio.sh)）

| 用途 | 关键 `amixer -c 0` 控件 |
|------|-------------------------|
| 强制 HP 使能 | **`hp switch` on** → gpio-490 **hi** |
| 放音路径 | `Headphone` on · `Speaker`/`OUT2`/`spk switch` off · **`OUT1` on** |
| 音量 | `Output 1` / `PCM` → 100%（脚本先试绝对值再百分比） |
| 左右混音 | `Left Mixer Left Playback Switch` / `Right Mixer Right Playback Switch` on |
| 麦（路由 A，CON24 可用） | `Headset Mic`+`Main Mic` on · `Capture Mute` off · PGA **DifferentialL/R** · **`Differential Mux` = `Line 2`** |

播测：`aplay -D hw:0,0 …`；录测：`arecord -D hw:0,0 -f S16_LE -r 16000 -c 2 …`。

**口述要点：** Jack=off 时仍可出声，靠的是 `hp switch` 拉高 hp-con，不是「插拔检测好看」。

### 脚本讲解 — Mixer

#### `board-audio-up.sh`：强制 CON24 声路

调用顺序固定：**先放音块 → 再麦块 → 可选回读状态**。关键变量：`ALSA_CARD`（默认 `0`）、`ALSA_DEV`（`hw:0,0`）、`AUDIO_UP_QUIET=1`（静默，被 voice/PTT 调用时用）。

`amixer_c` 吞掉所有失败（控件名因驱动版本可能缺）：

```10:12:docs/cli-llm-chat/board-audio-up.sh
amixer_c() {
	amixer -c "$CARD" "$@" >/dev/null 2>&1 || return 0
}
```

放音核心（`hp switch` → OUT1，关扬声器；音量先绝对值再百分比）：

```15:27:docs/cli-llm-chat/board-audio-up.sh
amixer_c sset "hp switch" on
amixer_c sset Headphone on
amixer_c sset Speaker off
amixer_c sset OUT1 on
amixer_c sset OUT2 off
amixer_c sset "spk switch" off
# Absolute max (ES8388): Output 1 = 33, PCM = 192
amixer_c sset "Output 1" 33
amixer_c sset PCM 192
amixer_c sset "Output 1" 100%
amixer_c sset PCM 100%
amixer_c cset name="Left Mixer Left Playback Switch" on
amixer_c cset name="Right Mixer Right Playback Switch" on
```

麦路由 A（CON24 实测可用）：Differential + Line 2：

```34:44:docs/cli-llm-chat/board-audio-up.sh
amixer_c sset "Headset Mic" on
amixer_c sset "Main Mic" on
amixer_c sset "Capture Mute" off
…
amixer_c sset "Left PGA Mux" DifferentialL
amixer_c sset "Right PGA Mux" DifferentialR
amixer_c sset "Differential Mux" "Line 2"
```

**坑：** 脚本不改 Jack 读数；Jack=off 时仍能出声是因为 `hp switch` 拉 hp-con。静默模式跳过末尾 `sget`/`gpio` 回读。

#### `S43xiaozhi-audio.sh`：开机包装

本体在 userdata；app 重刷后需重链：`ln -sfn /userdata/xiaozhi-cli/S43xiaozhi-audio.sh /etc/init.d/S43xiaozhi-audio`。

`start`：等 card0 最多 15s → 调 `board-audio-up.sh`，日志 `/userdata/xiaozhi-cli/audio-up.log`。`stop` 空操作（mixer 状态粘性）。`status` 回读 `hp switch` / Headset Mic / Differential Mux。

```27:37:docs/cli-llm-chat/S43xiaozhi-audio.sh
	# Sound card may appear slightly after local_fs; brief retry.
	i=0
	while [ "$i" -lt 15 ]; do
		if [ -d /proc/asound/card0 ] || [ -e /dev/snd/controlC0 ]; then
			break
		fi
		i=$((i + 1))
		sleep 1
	done
	AUDIO_UP_QUIET=0 "$AUDIO_UP" >"$LOG" 2>&1 || true
```

---

## 3. 网络 IP（ICS）

| 角色 | 地址 |
|------|------|
| Windows ICS 主机 | **`192.168.137.1`** |
| 板 USB-LAN 静态客户端 | **`192.168.137.2/24`**，默认路由经 `.1` |

**步骤：**

1. Windows 对 USB 网卡开 ICS 共享。
2. 板：`/userdata/xiaozhi-cli/S42xiaozhi-ics.sh`（软链 `/etc/init.d/S42xiaozhi-ics`）开机跑；或手动  
   `IFACE=eth0 /userdata/xiaozhi-cli/board-eth0-ics-up.sh`  
   （store：[`S42xiaozhi-ics.sh`](./cli-llm-chat/S42xiaozhi-ics.sh) · [`board-eth0-ics-up.sh`](./cli-llm-chat/board-eth0-ics-up.sh)）
3. **IFACE 自动选择：** 已有 `.2` 的口 → 有 carrier 的 **eth0** → **eth2** → 任一 `eth*` up。覆盖：`IFACE=ethN`。
4. `board-eth0-ics-up.sh`：`ip link up` → flush → `192.168.137.2/24` → default via `.1` → `resolv.conf` 写 nameserver `.1`；并从其他口删掉冲突的 `.2`。（/etc/resolv.conf 是 Linux 的 DNS 配置文件：程序查域名时读这里的 nameserver。

ICS 脚本把它写成 nameserver 192.168.137.1，是因为板子用静态 IP 上 Windows 共享网，不会再靠 DHCP 自动写 DNS；不覆盖的话经常仍指向空/旧服务器，就会出现你之前那种 Could not resolve host: api.openai.com。覆盖后走 ICS 主机做解析（能上网的域名才通）。只影响 DNS，不改 IP/路由本身。）
5. 验收：`curl http://192.168.137.1:43127/` / `:43128/health`（**勿信 ping**，ICS 常丢 ICMP）。

app 重刷会丢 `/etc/init.d` 软链，需重链；脚本本体在 **userdata** 保留。

### 脚本讲解 — ICS

#### `S42xiaozhi-ics.sh`：选口 + 等待 carrier

`pick_ics_iface` 优先级（与硬事实表一致）：

```21:63:docs/cli-llm-chat/S42xiaozhi-ics.sh
pick_ics_iface() {
	…
	# Prefer iface already holding the ICS client address
	…
	# Prefer eth0 when present and carrier is up
	…
	# Classic USB-LAN name on this board → eth2
	…
	# Any eth* with carrier → fallbacks eth0 / eth2
}
```

`WAIT_SECS` 默认 30。显式 `IFACE=ethN` 时只等该设备出现，不再跑 auto-pick。`start` 最终：`IFACE="$IFACE" "$ICS_UP"`。

**坑：** `stop` 不删地址（pair/chat 可能还在用）。USB-LAN 重命名在 eth0/eth2 间漂移 → 靠 auto-pick，不要写死。

#### `board-eth0-ics-up.sh`：真正配 IP

变量：`IFACE`（默认 eth0）、`ADDR=192.168.137.2/24`、`GW=192.168.137.1`。

调用顺序：

1. **先从其他口删掉同地址**（防 linkdown NIC 抢默认路由）  
2. `ip link set up` → `addr flush` → `addr add`  
3. `route replace default via GW`  
4. 覆盖 `/etc/resolv.conf` 为 `nameserver $GW`

```9:22:docs/cli-llm-chat/board-eth0-ics-up.sh
for n in /sys/class/net/*; do
	dev="${n##*/}"
	[ "$dev" = "$IFACE" ] && continue
	…
	ip addr del "$ADDR" dev "$dev" 2>/dev/null || true
done
ip link set "$IFACE" up
ip addr flush dev "$IFACE"
ip addr add "$ADDR" dev "$IFACE"
ip route replace default via "$GW" dev "$IFACE"
echo "nameserver $GW" > /etc/resolv.conf
```

**坑：** `flush` 会清该口全部 IPv4；只应在选定的 USB-LAN 口上跑。DNS 被整文件覆盖。

---

## 4. DSH Pair（概念 + 步骤）

**概念**

Cookie 是 pair 成功后，Desktop 通过 Set-Cookie: dsh_mobile=… 发给板子的会话凭证。token 只在 /pair?token=… 里用一次；之后板访问 :43127 的 RPC/status 要在请求头带上这个 cookie（脚本写进 .env 的 DSH_MOBILE_COOKIE），证明「已经配对过」。token 短时失效，cookie 才是日常鉴权；断开手机/重 pair 会换新 cookie。

- Desktop 菜单 **「连接手机」** 生成短时 **pair token URL**：`http://192.168.137.1:43127/pair?token=…`
- 板 `GET /pair`（常 **302**）→ 响应 **`Set-Cookie: dsh_mobile=…`**
- 此后所有板→Desktop RPC / 语音桥鉴权靠 cookie，**不是**一直带着 token
- Pair URL ≠ 聊天 URL；聊天只用 `DSH_BASE_URL` + cookie
- 当前 Desktop：**无「批准」按钮**，请求即连。断开手机 → cookie 失效 → 重 pair

**推荐步骤（板上）**

```bash
cd /userdata/xiaozhi-cli
./board-dsh-pair-url.sh 'http://192.168.137.1:43127/pair?token=…'
# 脚本：解析 BASE+TOKEN → 调 board-dsh-pair.sh → 写 .env；不打印 token/cookie
curl -sS -b "dsh_mobile=$(grep ^DSH_MOBILE_COOKIE= .env | cut -d= -f2-)" \
  http://192.168.137.1:43127/api/status   # 期望 connected（勿投影 cookie）
```

store：[`board-dsh-pair-url.sh`](./cli-llm-chat/board-dsh-pair-url.sh) · [`board-dsh-pair.sh`](./cli-llm-chat/board-dsh-pair.sh) · [`board-dsh.env.example`](./cli-llm-chat/board-dsh.env.example)

**`.env` 写入内容（`/userdata/xiaozhi-cli/.env`，chmod 600）**

| 键 | 谁写 | 含义 |
|----|------|------|
| `DSH_BASE_URL` | pair 脚本（来自粘贴 URL 的 host） | 例 `http://192.168.137.1:43127`（无 path） |
| `DSH_MOBILE_COOKIE` | pair 成功 | cookie **值**（无 `dsh_mobile=` 前缀） |
| `DSH_PAIR_TOKEN` | 临时 | 成功后脚本会清掉 |
| `DSH_SESSION_ID` | **人工固定**（非 pair 自动） | 见 §6 |
| `DSH_VOICE_BRIDGE_URL` | 人工 | 默认 `http://192.168.137.1:43128` |

### 脚本讲解 — Pair

#### `board-dsh-pair-url.sh`：粘贴完整 URL → 解析

1. 吃 argv 或 stdin 一整行 URL（去引号/空白）  
2. 内嵌 python 用 `urllib.parse` 拆出 `scheme://netloc` → `DSH_BASE_URL`，`?token=` → `DSH_PAIR_TOKEN`（也认 fragment / `/pair/TOKEN`）  
3. **export 覆盖** `.env` 里旧 BASE（ICS `.1` vs Wi‑Fi 主机）  
4. `exec board-dsh-pair.sh`  

**从不打印 token。** 只回 `token_len=`。

```68:71:docs/cli-llm-chat/board-dsh-pair-url.sh
# Export wins over board .env ICS default when pair.sh sources .env.
export DSH_BASE_URL DSH_PAIR_TOKEN
echo "Using BASE=$DSH_BASE_URL (from pasted URL; .env will not override)"
exec "$PAIR_SH"
```

#### `board-dsh-pair.sh`：GET /pair → 写 cookie

调用顺序：

1. 若 argv 是 `http(s)://…` → 转给 pair-url（解析逻辑唯一）  
2. 记住 `_PRE_*` export，再 `source .env`，再把 PRE 盖回去（新粘贴赢过旧 env）  
3. `curl -D headers -c jar GET $BASE/pair?token=…`  
4. 从 jar（Netscape 第 6/7 列）或 headers（python 折行 Set-Cookie）取 `dsh_mobile`  
5. 没有则跟一次 Location；再没有则旧桥 pending-id 轮询 `/pair/status`  
6. `write_env_cookie`：upsert `DSH_BASE_URL` + `DSH_MOBILE_COOKIE`，**删掉** `DSH_PAIR_TOKEN`；chmod 600  
7. 探活 `/api/status`；可选 `GREET_ON_PAIR=1` → `board-greet.sh`（需已有 `DSH_SESSION_ID`）

```107:131:docs/cli-llm-chat/board-dsh-pair.sh
write_env_cookie() {
  …
  text = upsert(text, "DSH_BASE_URL", base)
  text = upsert(text, "DSH_MOBILE_COOKIE", cookie)
  text = re.sub(r"(?m)^DSH_PAIR_TOKEN=.*\n?", "", text)
  …
}
```

**坑：** cookie 常在 302 上；只看 body 会漏。失败时日志只打 Set-Cookie **名**（值打码）。token 过期或 Desktop 仍挂旧手机会话 → Disconnect → 新 token。**pair 不写 `DSH_SESSION_ID`。**

#### `board-dsh.env.example` 模板要点

见 §6 引用；pair 相关键：`DSH_BASE_URL`、`DSH_MOBILE_COOKIE`、`DSH_PAIR_TOKEN`（注释态）。勿提交真 cookie；板端勿用 Pinggy URL。

---

## 5. 人设 Persona

| 件 | 路径 |
|----|------|
| 人设正文（源） | store `docs/dafeiyu-persona.md` |
| 应用说明 | store [`docs/dsh-dafeiyu-persona-setup.md`](./dsh-dafeiyu-persona-setup.md) |
| Desktop 落地 | Windows `%APPDATA%\dsh-desktop\harness\profiles\web\cordis.patch.yml` |

**怎么灌：**

1. 编辑 `dafeiyu-persona.md`（口播一对【】、末尾 `[emotion:…]`、主动说话等）。
2. 在 Windows 把全文写入 patch 两处：  
   - `system-prompt.config.personaPrefix`  
   - `preset-standard` → `@deepseek-ai/dsh-persona` 的 `prefix`（`complete: true`；UI 名「大肥鱼」）
3. **YAML：** `|` 块缩进 = keyIndent+2；嵌套 `dsh-persona.prefix` 错缩进 → Safe Mode。
4. **重启 DSH Desktop**（HMR 不可靠）。
5. 冒烟：「你是谁」→ 大肥鱼/本鱼，非「小伴」；回复带 `[emotion:…]`。

**不是**装 `dsh-dafeiyu` 桌宠插件；对话人设 ≠ 宠物 UI。板端工具不改人设，只消费会话回复。

### 脚本讲解 — Persona（Windows 应用路径）

无板上 shell；应用工具在 Windows，文档见 [`dsh-dafeiyu-persona-setup.md`](./dsh-dafeiyu-persona-setup.md)。

**YAML 写入键（markdown 正文落点）：**

| 键路径 | 内容 |
|--------|------|
| `system-prompt.config.personaPrefix` | 完整 `dafeiyu-persona.md`（`\|` 字面块） |
| `preset-standard` → `@deepseek-ai/dsh-persona` → `prefix` | 同一全文；`complete: true`；UI 名「大肥鱼」 |
| preset id | 保持 `standard`（工具集不变） |

**缩进坑：** `personaPrefix` 常见 indent=6；嵌套 `dsh-persona.prefix` 需 **keyIndent+2**（常见 12）。固定 6 空格会弄坏嵌套 → Desktop Safe Mode（`bad indentation of a mapping entry`）。改前备份 `cordis.patch.yml.bak-*`。

**Apply / 重载（PowerShell，无 secrets）：**

```powershell
# 1) 手工把 dafeiyu-persona.md 全文贴进上述两处 | 块后：
Stop-Process -Name "DSH Desktop","electron" -Force -ErrorAction SilentlyContinue
Start-Process "C:\Program Files\DSH Desktop\DSH Desktop.exe"

# 2) 确认合成配置（不打印凭据）：
$env:DSH_HOME = "$env:APPDATA\dsh-desktop\harness"
& "$env:USERPROFILE\.dsh-tools\node_modules\.bin\dsh.cmd" --profile web --dump-config
# Expect 大肥鱼 / 本鱼；expect zero 小伴
```

本 VM 写不到 `%APPDATA%\dsh-desktop\…`（不在 hgfs）；必须在 Windows 主机改 patch。旧 session 可能仍像「小伴」→ 换新 session / 清上下文（§6）。

---

## 6. sessionId

| 项 | 值 |
|----|-----|
| 存放 | **`/userdata/xiaozhi-cli/.env`** → **`DSH_SESSION_ID=…`** |
| 模板 | store [`docs/cli-llm-chat/board-dsh.env.example`](./cli-llm-chat/board-dsh.env.example) |
| 谁用 | `board-dsh-chat.sh`、`board-voice-once.sh`、语音桥 `POST /v1/voice-turn` 的 form 字段 `sessionId` |

**原理：** Desktop 侧一个 **Agent session**。板/桥用同一 id 调 `:43127` **`session.prompt` / `session.history`**，文字与语音共享上下文与人设。脚本优先读 `.env` 固定 id，避免每次 `session.list[0]` / 新建导致「不像大肥鱼」或 voice-mode **`unknown_session`（403）**。

换会话：改 `.env` 或临时 `DSH_SESSION_ID=… ./board-voice-once.sh`。旧 id 在 Desktop 被清掉后必须换新（可 `session.create` 再写回）。

### 脚本讲解 — sessionId

#### `board-dsh-chat.sh` 钉死逻辑（~269–310）

在 `/api/status` 确认 `connected` 之后：

1. 读已有 `DSH_SESSION_ID`（来自 `.env` / 环境）  
2. `session.list`；若 env 非空 → **直接用**（即使不在 list 也软警告仍发送）  
3. 否则 `list[0]`；再空则 `session.create`  
4. `export DSH_SESSION_ID` 给后续 greet / tts-pull

```269:310:docs/cli-llm-chat/board-dsh-chat.sh
# Prefer pinned session (DSH_SESSION_ID / .env) over list[0] / session.create —
DSH_SESSION_ID="${DSH_SESSION_ID:-}"
…
if [[ -n "$DSH_SESSION_ID" ]]; then
  SESSION_ID="$DSH_SESSION_ID"
  SESSION_SRC="env"
  …
else
  SESSION_ID="$(echo "$LIST" | jq -r '.value.items[0].sessionId // …')"
  …
fi
export DSH_SESSION_ID="$SESSION_ID"
```

#### 语音侧：**硬要求**同一 id

| 脚本 | 行为 |
|------|------|
| [`board-voice-once.sh`](./cli-llm-chat/board-voice-once.sh) | `[[ -n "$SESSION_ID" ]] \|\| die`；POST form `-F sessionId=…` |
| [`board-greet.sh`](./cli-llm-chat/board-greet.sh) | JSON `{"sessionId", "inject": true}` → `/v1/greet` |
| [`board-proactive-tick.sh`](./cli-llm-chat/board-proactive-tick.sh) | 同上 → `/v1/proactive-tick` |
| [`board-tts-pull.sh`](./cli-llm-chat/board-tts-pull.sh) | 有 sid 则塞进 body；`SPEAK_INJECT=1` 时注入 Desktop |

共性：`_PRE_SESSION` 保存调用方 export → `source .env` → PRE 盖回（临时覆盖 `.env`）。

```69:70:docs/cli-llm-chat/board-voice-once.sh
SESSION_ID="${DSH_SESSION_ID:-}"
[[ -n "$SESSION_ID" ]] || die "DSH_SESSION_ID unset — pin same session as board-dsh-chat.sh"
```

#### 模板行（`board-dsh.env.example`）

```15:17:docs/cli-llm-chat/board-dsh.env.example
# Pin Desktop agent/session (preferred over session.list[0] / session.create)
# Switch: change this value or `DSH_SESSION_ID=… ./board-dsh-chat.sh`
DSH_SESSION_ID=session-dafeiyu-smoke-1793077192324
```

**坑：** 文字 chat 无 pin 时会静默 create → 语音仍钉旧 id → 两套上下文。voice-mode 对未知 session 回 **403**。

---

## 7. 语音（ASR / TTS / 桥）

**结论先讲：语音不走 DeepSeek。** DeepSeek 仅可选文本 LLM（`/v1/chat/completions`）；**无** `/v1/audio/*`。板上真语音 = **LAN 桥**。

| 层 | 工具 / 文件 | 作用 |
|----|-------------|------|
| Desktop 插件 | **`dsh-voice-mode`**（loopback `:43129` `/voice-mode/*`） | 本机 ASR（zipformer/SenseVoice）；TTS 设置 |
| TTS 引擎 | **Edge** 默认 **`zh-CN-XiaoxuanNeural`** | 声音模组；`DSH_TTS_VOICE` |
| LAN 桥 | store [`docs/dsh-voice-bridge/server.mjs`](./dsh-voice-bridge/server.mjs) → 运行 `%USERPROFILE%\dsh-voice-bridge\server.mjs` | 听 **`0.0.0.0:43128`** |
| 板一回合 | `/userdata/xiaozhi-cli/board-voice-once.sh` | arecord → `POST …/v1/voice-turn` → mpg123/sox → `aplay hw:0,0` |
| PTT | `/userdata/xiaozhi-cli/board-ptt-hold.sh`（S44） | KEY5 toggle / barge-in → 同上 |

**`/v1/voice-turn` 内部（同会话）：**

1. toggle voice-mode on → ASR final  
2. `:43127` `session.prompt`（cookie + **同一 sessionId**）  
3. 轮询 history 至助手正文**稳定**  
4. **`spokenForTts`：有全角 `【…】` → 只合成括号内**；剥 `[emotion:…]`；无括号则回退剥 thinking  
5. Edge TTS → `audio/mpeg`；头 **`x-emotion`**  
6. toggle off  

板侧入口还可：`board-greet.sh` / `board-proactive-tick.sh` / `board-tts-pull.sh`（无麦主动播）。

### 脚本讲解 — 语音

#### `server.mjs`：voice-turn 主路径

鉴权：板必须带 `Cookie: dsh_mobile=…`（token 仅 smoke）。缺 `sessionId` → 400。同 session 并发用 `inflightVoiceTurns` 去重（双 PTT）。

核心顺序（锁内）：

```1420:1471:docs/dsh-voice-bridge/server.mjs
        await ensureVoiceSession(sessionId);
        …
          asrText = await asrFinal(sessionId, pcm);
        …
        replyText = await promptAndWait(auth.cookie, sessionId, asrText);
        ttsText = spokenForTts(replyText);
        emotion = extractEmotionTag(replyText);
        …
          audio = await synthesizeReply(ttsText, preferWav);
```

`spokenForTts` 硬规则：只要出现【】，**只念括号内**；剥 emotion 标签；无括号才走 thinking/EN 剥离回退：

```862:872:docs/dsh-voice-bridge/server.mjs
function spokenForTts(text) {
  const raw = String(text || "");
  // Hard gate: any 【】 present → bracket interiors ONLY.
  if (hasSpokenBracketMarkers(raw)) {
    const bracketBody = extractOutermostSpokenBracket(raw);
    if (!bracketBody) return "";
    …
  }
```

响应头：`x-emotion`、`x-asr-text`、`x-tts-engine`、`x-tts-bytes`。默认 full-text Edge（`DSH_VOICE_TTS_SSE=1` 才优先 SSE，截断则回退）。

#### `start.ps1`（简述）

同步 `server.mjs` → `%USERPROFILE%\dsh-voice-bridge\`；默认 `DSH_VOICE_BIND=0.0.0.0`、`PORT=43128`、`DSH_RPC_BASE=127.0.0.1:43127`、`DSH_VOICE_MODE_BASE=…:43129`；找 node（PATH 或 Desktop 自带）→ `node .\server.mjs`。Desktop 需已开。

#### `board-voice-once.sh`：板上单回合

顺序：`source .env`（PRE 覆盖）→ 校验 cookie + **硬要 sessionId** → `board-audio-up` → health → 可选 `board-greet.sh` → `arecord`（或 `USE_EXISTING_REC`）→ `POST /v1/voice-turn` multipart → 读 `x-emotion` → mp3→wav + sox 增益 → `emotion play-start` → `aplay` → `play-end`。

```134:140:docs/cli-llm-chat/board-voice-once.sh
HTTP=$(curl -sS --http1.1 -m "${VOICE_BRIDGE_TIMEOUT:-180}" -D "$TMP_HDR" -o "$REPLY_WAV" -w "%{http_code}" \
	-X POST "$TURN_URL" \
	-H "Cookie: ${COOKIE_HEADER}" \
	…
	-F "sessionId=${SESSION_ID}" \
	-F "file=@${REC_WAV};type=audio/wav;filename=utt.wav")
```

`SKIP_PLAY=1`（PTT 用）：只落盘 reply + `.emotion`，不 aplay。`SPEAK_TEXT=` / `--speak` → 转交 `board-tts-pull.sh`。

#### `board-ptt-hold.sh`：KEY5 → 同一 voice-once

录完后：`USE_EXISTING_REC=1 SKIP_PLAY=1 GREET_ON_START=0` 调 voice-once；本地读 `.emotion` / `.play.wav`，`emotion_play_start` → aplay（可 barge-in）→ `emotion_play_end`。桥等待中再按 KEY → SIGTERM 丢弃本轮。

#### `board-greet.sh` / `board-proactive-tick.sh` / `board-tts-pull.sh`

| 脚本 | 端点 | body 要点 |
|------|------|-----------|
| greet | `POST /v1/greet` | `{sessionId, inject:true[, force]}`；`skipped` 则退出 |
| proactive | `POST /v1/proactive-tick` | 同上；尊重桥 cooldown |
| tts-pull | `/v1/speak`→`/v1/tts` | `{text, voice, sessionId?, inject?}`；无麦 |

三者都：cookie + sessionId → 取 audio_b64/mp3 → sox 48k → `aplay hw:0,0`。

**坑：** 桥未起 → voice-once exit 5；不完整 Content-Length → die；缺 mpg123/ffmpeg/sox 无法播 Edge mp3。人设若漏【】，TTS 会念到 thinking 残留（回退路径）。

---

## 8. UI 与情绪同步

| 件 | 路径 |
|----|------|
| 渲染 | `/userdata/dafeiyu-hdmi/emotion_fb.py`（`BACKEND=fb`，写 `/dev/fb0`） |
| 启动 | `/userdata/dafeiyu-hdmi/board-hdmi-emotion-start.sh` |
| API | `emotion_api.py` → `127.0.0.1:8765` |
| 资源包 | `/userdata/animation-assets/rk3576-robot-eyes/fb-raw` |
| store 镜像 | [`docs/cli-llm-chat/hdmi-emotion-ui/`](./cli-llm-chat/hdmi-emotion-ui/) |

**默认视觉参数（start 脚本 export）：**

| 变量 | 默认 | 含义 |
|------|------|------|
| `EYE_SEP` | **1.4** | IPD / 眼距 |
| `EYE_GAP_X` | **1.28** | 椭圆（横扩） |
| `EYE_SCALE` | 1.25 | 整体放大 |
| `EMOTION_FPS` | **12** | present 上限 ~12 fps |
| `IDLE_LIVELY` | **1** | 待机眨眼 + 瞳孔微漂 + 呼吸缩放 |

**与语音同步：**

1. 人设要求回复：`【口播】…[emotion:happy]`  
2. 桥解析标签 → 响应头 **`x-emotion`**（JSON 时字段 `emotion`）  
3. `/userdata/xiaozhi-cli/board-emotion-voice.sh`：  
   `ensure` → `play-start <name> <hold≈wav秒>` → `aplay` → `play-end`（**force idle**）  
4. `board-voice-once.sh` / `board-ptt-hold.sh` 已接；无标签回退 **`speaking`**  
5. 关同步：`EMOTION_ENABLE=0`

**口述要点：** 眼睛跟的是 pack 名（happy/wink…），不是 idle/listening 相位钩子；TTS 只念【】，标签不出口。

### 脚本讲解 — UI / 情绪

#### `emotion_fb.py`：关键旋钮

从环境读（start 脚本 export）：

```32:54:docs/cli-llm-chat/hdmi-emotion-ui/emotion_fb.py
EYE_SCALE = float(os.environ.get("EYE_SCALE", "1.25"))
EYE_GAP_X = float(os.environ.get("EYE_GAP_X", "1.28"))
EYE_SEP = float(os.environ.get("EYE_SEP", "1.4"))
…
EMOTION_FPS = float(os.environ.get("EMOTION_FPS", "12"))
…
IDLE_LIVELY = os.environ.get("IDLE_LIVELY", "1") != "0"
```

- **`EYE_SEP`**：相对打包板的瞳距倍率（1.0=贴紧；~1.4 温和拉开）。过大（曾 2.0）两眼出画。  
- **`EMOTION_FPS`**：present 上限；30 会闪烁，默认 12。  
- **`IDLE_LIVELY`**：仅 API `state=idle` 时眨眼 / 漂移 / 呼吸（`IdleLively` 类）；`=0` 关。

写 `/dev/fb0`；轮询 `EMOTION_API`（默认 `127.0.0.1:8765/api/emotion`），`EMOTION_POLL_EVERY=3` 帧一次。

#### `board-hdmi-emotion-start.sh`

顺序：`sync_payload` →（可选）eth0 → 清 weston 杂项 → `apply_fullbleed_weston` 配置 → `start_api` → `BACKEND=fb` 时 `stop_weston_for_fb` + `start_fb`（带上 EYE_* / FPS / IDLE_LIVELY）→ POST idle。

**坑：** fb 路径必须停 Weston，否则抢 fb0。默认 `HDMI_MODE=1024x600`（勿盲上 1440x900）。`ETH0_STATIC` 默认不乱动 ICS。

#### `board-emotion-voice.sh`：parse / play-start / play-end

| 子命令 | 作用 |
|--------|------|
| `ensure` | API 不通则 `BACKEND=fb` 调 start |
| `parse '…'` | 抽最后一个 `[emotion:x]` / `<!--emotion:x-->`（白名单 pack 名） |
| `play-start [name] [hold]` | 空名 → `speaking`；`POST /api/emotion` `{state,hold}` |
| `play-end` | `set idle` **带 force**（否则 special lock 压不住 idle） |

```105:118:docs/cli-llm-chat/board-emotion-voice.sh
cmd_play_start() {
	local emo="${1:-}"
	local hold="${2:-30}"
	[[ -n "$emo" ]] || emo="$EMOTION_SPEAK_FALLBACK"
	…
	cmd_set "$emo" "$hold"
}
cmd_play_end() {
	cmd_set "$EMOTION_IDLE" "0.5" force
}
```

#### voice-once / ptt 如何调用

**voice-once（自播路径）：**

```288:305:docs/cli-llm-chat/board-voice-once.sh
HOLD_S=$(python3 -c "print(max(2.0, ${rsz}/(48000*2*2)+0.5))" …)
"$EMOTION_HELPER" ensure || true
"$EMOTION_HELPER" play-start "${VOICE_EMOTION:-}" "$HOLD_S" || true
… aplay …
"$EMOTION_HELPER" play-end || true
```

`VOICE_EMOTION` 来自响应头 `x-emotion`（或 JSON `emotion` / 正文标签）。

**ptt：** `SKIP_PLAY=1` 跑完 voice-once 后，内嵌 python 读 `reply.wav.emotion`，`emotion_play_start(wav)` → 可打断的 aplay → `emotion_play_end()`。`EMOTION_ENABLE=0` 整链短路。

---

*文档范围：§1–§8 硬事实 + 上列脚本讲解。无 flash 步骤、无 XR 史、无 smoke 表。*
