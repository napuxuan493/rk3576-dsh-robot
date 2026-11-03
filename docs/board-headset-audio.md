# TL3576-EVM CON23 / CON24 耳机座试播

| 字段 | 值 |
|------|-----|
| 板型 | `TL3576-EVM`（`tronlong,tl3576-evm`） |
| 日期 | 2026-10-28（Asia/Shanghai） |
| 通道 | ADB USB（无 Wi‑Fi） |
| 烧录 | **boot 分区 only**（用户自刷）；Agent **未**写板。镜像：`tl3576-hp-det-boot.img` |
| 结论 | **CON24 可听**（用户 2026-10-28 ~16:47 确认「有声音了」）。丝印仍标 LINE IN，但 **hp-det 在 CON24**；强制 `hp switch` + OUT1 后 `hw:0,0` 440 Hz 可出声。RTT BSP **无** ES8388 例程。 |
| ADB 复验（用户重刷后，2026-10-28 ~16:02，**无 flash**） | **声路 OK。** 分区整盘 MD5 因 boot 块 64 MiB、镜像 41.4 MiB 会不一致；**镜像长度前缀** MD5=`d324da61…` **匹配**交付图。DT `hp-det-gpio`=**ACTIVE_LOW**；插耳 GPIO138=`lo` + `Headphone Jack=on`。tone 曾被写成 0 B（已重推）；unmute 后 `aplay -D hw:0,0` → S16_LE 48 kHz stereo，**exit 0**。 |
| CON24 强制试播（2026-10-28 ~16:47 Asia/Shanghai，**无 flash**） | 用户确认 jack=**CON24**。`amixer -c 0 sset 'hp switch' on`；Headphone/OUT1/PCM/Output1/左右 Mixer **on/100%**；`sox` 生成 7 s **440 Hz** → `/userdata/tl3576-con24-440hz-7s.wav`；`aplay -D hw:0,0` **×2，均 exit 0**。播中：**Jack=off**，gpio-138=`in hi`（ACTIVE_LOW→未判插入），gpio-490=`out hi`。**用户反馈有声音。** Jack 读-only，无法软件置 on；本次靠强制 HP 路径绕过。 |
| CON24 mic 录→播（2026-10-28 ~16:50 Asia/Shanghai，**无 flash**） | 设备 **`hw:0,0` capture**。首录 mono 16 kHz 近静音（peak≈10）。路由对比：**A**=PGA Differential + DiffMux **Line 2** + Headset+Main Mic → peak≈**600**（相对最好）；B=Line1+MicL/R、C=Diff+Line1 ≈静音。文件 `/userdata/tl3576-con24-rec.wav`（=A，384 044 B，6 s stereo 16 kHz）+ `…-rec-loud.wav`（gain -n）。`arecord`/`aplay` 均 **exit 0**。**Headset Mic Jack=off**、Jack=off 仍读-only。**待用户确认是否听回自己的声音。** |
| 开机自动 HP/麦 + ASR/TTS 钩子（2026-10-28 ~16:56，**无 flash**） | `/userdata/xiaozhi-cli/board-audio-up.sh` + boot `S43xiaozhi-audio.sh` → `/etc/init.d/S43xiaozhi-audio`。烟测：mixer OK。ASR/TTS 脚本已钩 chat；**真语音需独立 speech 厂商**（见下）。 |
| DeepSeek key 澄清（2026-10-28 ~17:12，**无 flash**） | 板上 `.env` 可留 `OPENAI_API_KEY=sk-…bce5` 作 **文本 LLM**。**DeepSeek 无 `/v1/audio/*`**。真语音走 **LAN voice bridge**（见 [`dsh-voice-bridge.md`](./dsh-voice-bridge.md)），不用 DeepSeek speech。 |
| LAN voice bridge 板端（2026-10-28 ~17:22，**无 flash**） | `board-voice-once.sh`：audio-up→arecord→`POST :43128/v1/voice-turn`→aplay。同 `DSH_SESSION_ID`/cookie。ICS `192.168.137.2` OK；**`:43128` 尚未监听**（Windows 建桥中）。占位契约见 bridge 文档。 |

## 丝印 vs 功能

| 丝印 | 功能（规格/既有标注） | ALSA |
|------|----------------------|------|
| **CON23** | **HP OUT / MIC IN**（丝印） | card0 `rockchip-es8388` / `hw:0,0`，走 **OUT1 / LOUT1+ROUT1** |
| **CON24** | **LINE IN**（丝印）；**实测 hp-det + 可听播放** | 同 `hw:0,0`；用户确认 detect 在 CON24，强制 HP 后 440 Hz **有声** |

> 2026-10-28 插拔：用户称 **仅 CON24 有 click**；后确认 **hp-det 在 CON24**。板上 `hp-det`（gpio-138）插拔有 hi↔lo。**CON24 强制试播已出声**（见上表）。丝印/放音座是否与 CON23 错位仍见 [`internal/jack-det-con23-con24.md`](../internal/jack-det-con23-con24.md)。**未 flash。**

## CON24 强制试播（命令摘要）

```bash
adb shell 'amixer -c 0 sset "hp switch" on; amixer -c 0 sset Headphone on; amixer -c 0 sset Speaker off; amixer -c 0 sset OUT1 on; amixer -c 0 sset "Output 1" 100%; amixer -c 0 sset PCM 100%; amixer -c 0 cset name="Left Mixer Left Playback Switch" on; amixer -c 0 cset name="Right Mixer Right Playback Switch" on'
adb shell 'sox -n -r 48000 -c 2 -b 16 /userdata/tl3576-con24-440hz-7s.wav synth 7 sine 440 vol 0.8'
adb shell 'aplay -D hw:0,0 /userdata/tl3576-con24-440hz-7s.wav'   # ×2, exit 0
# 播中：Jack=off, gpio-138=hi, gpio-490=hi(hp-con); 用户：有声音
```

## CON24 mic 录→播（命令摘要）

Capture 设备：`arecord -l` → card0 `rockchip-es8388` **device 0**（`hw:0,0`）。格式：S16_LE，8–96 kHz，1–2 ch。

```bash
# 最佳实测路由（A）：Differential + Line 2
adb shell 'amixer -c 0 sset "Headset Mic" on; amixer -c 0 sset "Main Mic" on; amixer -c 0 sset "Capture Mute" off
  amixer -c 0 sset "Capture Digital" 100%; amixer -c 0 sset "Left Channel" 100%; amixer -c 0 sset "Right Channel" 100%
  amixer -c 0 sset "Left PGA Mux" DifferentialL; amixer -c 0 sset "Right PGA Mux" DifferentialR
  amixer -c 0 sset "Differential Mux" "Line 2"'
adb shell 'arecord -D hw:0,0 -f S16_LE -r 16000 -c 2 -d 6 /userdata/tl3576-con24-rec.wav'   # exit 0; peak~600
adb shell 'sox /userdata/tl3576-con24-rec.wav /userdata/tl3576-con24-rec-loud.wav gain -n -1'
adb shell 'amixer -c 0 sset "hp switch" on; amixer -c 0 sset Headphone on; amixer -c 0 sset OUT1 on
  amixer -c 0 sset "Output 1" 100%; amixer -c 0 sset PCM 100%; aplay -D hw:0,0 /userdata/tl3576-con24-rec-loud.wav'  # exit 0
```

| 路由 | peak (int16) | RMS (sox) | 备注 |
|------|--------------|-----------|------|
| 初录 MicL/R + Line1 PGA，mono | ~10 | ~0.00007 | 近静音 |
| **A Diff + Line2 + Headset+Main** | **~600** | ~0.00064 | **相对最强**；仍偏弱 |
| B Line1 PGA + Headset only | ~11 | ~0.00007 | 近静音 |
| C Diff + Line1 | ~7 | ~0.00005 | 近静音 |

播中 Jack / Headset Mic Jack 均为 **off**；gpio-138=`hi`，gpio-490=`hi`。**未 flash。** 请用户确认回放是否为自己的语音。

## 开机自动开 HP/麦（S43）

脚本在 **`/userdata/xiaozhi-cli/`**（survives boot flash）：

| 文件 | 作用 |
|------|------|
| `board-audio-up.sh` | 强制播放+路由 A 采集（chat/ASR/TTS 前也可手动调） |
| `S43xiaozhi-audio.sh` | SysV：等 card0 → 调 `board-audio-up`，日志 `audio-up.log` |
| `board-asr-once.sh` | `arecord` → OpenAI 兼容 `/v1/audio/transcriptions`（需 key） |
| `board-tts-say.sh` | 文本 → `/v1/audio/speech` wav → `aplay`（或 `TTS_STUB=1` 蜂鸣） |
| `board-voice-once.sh` | 录→LAN bridge→TTS 一键（`USE_EXISTING_REC` / `SKIP_PLAY` 供 PTT） |
| `board-ptt-hold.sh` / `S44xiaozhi-ptt.sh` | **KEY5**（GPIOB3→gpio-43）PTT：toggle/打断/滴嘟 → bridge；见 [board-ptt-key5.md](./board-ptt-key5.md) |
| `board-dsh-chat.sh` | `VOICE_IN=1` 空行录音；`VOICE_OUT=1` 回复后 TTS |

```bash
ln -sfn /userdata/xiaozhi-cli/S43xiaozhi-audio.sh /etc/init.d/S43xiaozhi-audio
/etc/init.d/S43xiaozhi-audio start   # 无 reboot 烟测
/userdata/xiaozhi-cli/board-audio-up.sh
TTS_STUB=1 /userdata/xiaozhi-cli/board-tts-say.sh 'path ok'
# 真语音：在 .env 写入 OPENAI_API_KEY=…（或 ASR_/TTS_ 分拆 + 可选 BASE_URL）
```

## RuiChing RTT SDK 巡检（XR-81，`test_3576` / BSP V2.0.1）

路径：

- 工程：`C:\RuiChingStudio\workspace_gd32\test_3576`（由 `00_base_helloworld` 生成，`app/main.c` 仅 `Hello, RuiChing`）
- BSP：`C:\RuiChingStudio\repo\Local\Board_Support_Packages\Real-Thread\TL3576-EVM-H\V2.0.1`

| 项 | 结果 |
|----|------|
| `app.yaml` 例程 | **无** `*audio*` / `*es8388*` / `*headphone*` / `*sai*` / `*wifi*` |
| `CONFIG_RT_USING_AUDIO` | **not set**（application + `tl3576_evm` driver） |
| ES8388 / codec 板级驱动 | **无**（无 `es8388` 字符串；板级仅有 GPIO 扩展/iomux/GMAC 等） |
| 可用底座 | HAL：`hal_sai` / `hal_i2s` / `hal_audio`…；框架：`driver_framework/audio/{audio,audio_pipe}.c`；USB gadget `audio_speaker.c` 期望设备名 `sound0` |
| Rockit AI/AO Kconfig | 有开关文案，**不是** CON23 ES8388 播音例程 |
| 对照误读 | `workspace/08_misc_amp_factory_default/board/amp.dtsi` 含 `es8388-sound` + Headphone/LOUT1 路由，但是 **RC-Pi-3506 / RK3506** AMP 工程，**不是** TL3576 |

**含义：** 要用 RTT 播 CON23，需自写 SAI+ES8388+音量/插拔路径，并处理与 Linux 的外设归属；当前 BSP **没有**可抄的 headphone/test-tone 例程。**未刷机、未改 DT。**

### 同包 WiFi 对照（细看）

| 项 | 结果 |
|----|------|
| TL3576 BSP WiFi 例程 | **无**（网络例程只有 GMAC `03_network_tcp/udp_*`） |
| `CONFIG_RT_USING_WIFI` / `SDIO` / `SPI_WIFI` | **全部 not set** |
| 框架残留 | `driver_framework/wlan/*`、`sdio/*` 源码在；Kconfig 可选 `RT_USING_WIFI`；`SPI_WIFI` 指向 **RW009/007**，非板载 **FCS950U** |
| 工作区 `03_network_*` / `4g_webclient` | 多为 **RC-Pi-3506** 工程，不是 TL3576 WiFi |
| 3506 对照 BSP | 同样 **无** `*wifi*` / `*wlan*` / `*es8388*` 例程名 |
| 与现板关系 | 见 [`board-wifi-bringup.md`](board-wifi-bringup.md)：FCS950U **SDIO 归 Linux**；RTT **不占用** WiFi；缺的是 `wcnmodem` + Unisoc ko，不是 AMP 抢总线 |

音频与 WiFi 同构：**RTT 侧只有通用框架开关，没有板级芯片例程；可工作路径在 Linux。**

## 无声根因（Linux 侧，已定位）

1. 插着耳机时 `hp-det`（GPIO4_PB2）为 **物理低电平**。
2. 原 DT：`hp-det-gpio = GPIO_ACTIVE_HIGH` → `Headphone Jack=off`。
3. Jack=off 时 multicodecs **禁用 Headphone DAPM** → **LOUT1 不上电** → CON23 静音。
4. Pulse 曾默认 HDMI；模拟卡 Active Port=`Speaker`（OUT2）。
5. 仅 `amixer sset Headphone on` **压不过** Jack；须 Jack=on 或改 DT 极性。

源码已改并已按 SDK 正常路径重打 FIT（**Agent 未烧板**）：

- `kernel-6.1/.../tl3576-evm.dts` / `sbc-tl3576-base.dtsi`：`hp-det` → **`GPIO_ACTIVE_LOW`**
- 构建：`cd ~/sdk && ./build.sh kernel` → `mk-fitimage.sh`（`boot.its` + SHA256 哈希；与 WiFi DT boot 同一官方路径）
- FIT 内 `fdt` 已核：`hp-det-gpio = <… 0x01>`（`GPIO_ACTIVE_LOW`）

### 交付镜像（供用户自刷）

| 项 | 值 |
|----|-----|
| 文件名 | **`tl3576-hp-det-boot.img`** |
| Windows 共享 | `share_docs\tl3576-hp-det-boot.img`（`~/hgfs/share_docs/`） |
| Context media | [`media/tl3576-hp-det-boot.img`](../media/tl3576-hp-det-boot.img) |
| SDK 产物 | `/home/na/sdk/kernel-6.1/boot.img`（同文件） |
| 大小 | 43399680 字节（≈41.4 MiB） |
| **MD5** | **`d324da61e6c11a06031dda4a641f3b70`** |
| 构建时间 | 2026-10-28 15:43 Asia/Shanghai |

> 曾打过**非 SDK 路径**打包的 FIT 进 `boot` 时，板子可能停在 U-Boot。恢复见下。原 boot 备份：主机 `/tmp/tl3576-boot.img`。

## 用户烧录（RKDevTool — **仅 boot 分区**；Agent 不写板）

本板启动介质是 **eMMC**。只更新耳机检测极性，**不要**勾 SPINAND / loader / uboot / rootfs / 整包 `update.img`。

1. **拔掉 SD 卡**（插着会优先从 SD 启）。
2. USB OTG 进 **Loader**（或 Maskrom → Download Boot → Loader）。存储选 **EMMC**。
3. RKDevTool → **下载镜像**：
   - **只勾选 eMMC 的 `boot` 行**
   - 路径：`share_docs\tl3576-hp-det-boot.img`
   - **取消**所有 **SPINAND** 行，以及其它未改分区
4. 执行下载 → 复位（不要按住 Maskrom）。
5. 冒烟（插耳机）：
   ```bash
   adb shell 'amixer -c 0 cget iface=CARD,name="Headphone Jack"'
   # 期望：values=on
   ```
   然后按下文「如何播测试音」播 880 Hz。

Linux 侧等价（Loader 已连上时，用户可自用；**Agent 不执行**）：

```bash
upgrade_tool DI -b ~/hgfs/share_docs/tl3576-hp-det-boot.img
```

## Maskrom 恢复 boot（若 ADB 全无；需用户操作）

1. USB OTG；按住 **Maskrom** → 复位/上电 → `upgrade_tool LD` 见 MaskRom。
2. Download Boot（RK3576 MiniLoader）→ Loader。
3. 写回原 boot：`upgrade_tool DI -b /tmp/tl3576-boot.img`（或再刷本页交付的 `tl3576-hp-det-boot.img`）。
4. **不要**用手搓未走 `./build.sh kernel` / `mk-fitimage.sh` 的 FIT。

## 能否只编 DTB / 只烧 DTB？（hp-det 极性）

**答：不能只烧独立 DTB 分区。**

| 项 | 事实 |
|----|------|
| GPT（`parameter.txt` / 板上 `by-name`） | `uboot misc boot recovery backup rootfs oem userdata`（本板另有 `rcboot`/`app` 等）— **无** `dtb` / `resource` 分区 |
| DTB 落点 | 打进 **`boot.img`（FIT）**：子镜像 **`fdt`**（U-Boot conf `fdt = "fdt"`，内核实际用的树） |
| `resource` | 也在 **同一 FIT** 内（`multi`），内含 `rk-kernel.dtb` + logo；**不是**可单独 `DI` 的分区 |
| 可只 **编译** DTB？ | **可以**（`make … tl3576-evm.dtb`） |
| 可只 **烧** DTB？ | **不可以** — 无独立 flash 目标；改 hp-det 必须重打并烧 **整包 `boot.img` → 分区 `boot`** |

**精确烧录目标：**

- 分区名：`boot`
- 块设备：`/dev/block/by-name/boot`
- 镜像：`tl3576-hp-det-boot.img`（FIT：`fdt` + `kernel` + `resource`）
- 工具：RKDevTool 只勾 `boot`，或 `upgrade_tool DI -b …`

只改 `fdt` 子镜像仍等于重打包整个 `boot.img` 再写 `boot` 分区；没有更小的官方分区可写。

## 如何播测试音（CON23，Linux / ADB）

极性正确（或 Jack=on）后：

```bash
adb shell 'sox -n -r 48000 -c 2 -b 16 /userdata/tl3576-test-tone.wav synth 1.5 sine 880 vol 0.5'
adb shell 'amixer -c 0 cget iface=CARD,name="Headphone Jack"'
adb shell 'amixer -c 0 sset PCM 100%; amixer -c 0 sset "Output 1" 100%; amixer -c 0 sset OUT1 on; amixer -c 0 sset Headphone on; amixer -c 0 sset Speaker off; amixer -c 0 sset "hp switch" on; amixer -c 0 cset name="Left Mixer Left Playback Switch" on; amixer -c 0 cset name="Right Mixer Right Playback Switch" on; aplay -D hw:0,0 /userdata/tl3576-test-tone.wav'
```

等价：`speaker-test -D hw:0,0 -c 2 -t sine -f 880 -l 1`

Pulse：sink 切到 `alsa_output.0.HiFi__hw_rockchipes8388__sink`，Active Port=**Headphones**（Jack=on 后才 available）。

## ALSA 卡

```
card 0: rockchipes8388   # CON23/24
card 1: rockchipdp0
card 2: rockchiphdmi     # Pulse 曾误用此为默认
```

## hp-con（gpio-490 / xl8574t P2）

DT：`hp-con-gpio = <&xl8574t 2 GPIO_ACTIVE_HIGH>`。空闲时常为 **`out lo`**；播音时 DAPM `Headphone` `POST_PMU` 才拉高。若 Jack/音量都对仍无声，先强制拉高（**无需刷机**）：

```bash
adb shell 'amixer -c 0 sset "hp switch" on'
adb shell 'grep 490 /sys/kernel/debug/gpio'   # 期望 out hi
adb shell 'aplay -D hw:0,0 /userdata/tl3576-test-tone-loud.wav'
```

实测：`hp switch on` → gpio-490=`out hi`；DAPM 播音时也会拉高。**不要**改成 `ACTIVE_LOW` 再刷，除非强制 HIGH 仍确认无声且示波器证明使能极性相反。Agent **未** flash。

## 测试音

- 板：`/userdata/tl3576-test-tone.wav`（勿放 `/tmp`）；大声：`/userdata/tl3576-test-tone-loud.wav`
- 仓库：`media/tl3576-test-tone.wav`
