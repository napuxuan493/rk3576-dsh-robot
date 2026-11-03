# KEY5 PTT（GPIOB3 → hold/toggle → voice bridge）

| 字段 | 值 |
|------|-----|
| 板型 | TL3576-EVM / RK3576 |
| 丝印 | **KEY5** |
| 原理图/用户名 | **GPIOB3** |
| DT | `gpio-keys` / `user_key0`：`gpios = <&gpio1 RK_PB3 GPIO_ACTIVE_LOW>`，`linux,code = <KEY_PROG2>`（0x95=149），label `user-key1` |
| Linux GPIO | **`gpio-43`** |
| 公式 | Rockchip：`N = bank×32 + group×8 + pin` → GPIO1_B3 = `1×32 + 1×8 + 3 = 43` |
| 输入节点 | `/dev/input/event7`（`Name=gpio-keys`） |
| 极性 | **ACTIVE_LOW**（按下 = `in lo`） |
| 烧录 | **无 flash**（仅 userdata 脚本） |
| 桥 | [`dsh-voice-bridge.md`](./dsh-voice-bridge.md) `:43128` |
| 眼睛同步 | 播报时跟 `[emotion:…]` / `x-emotion` → HDMI；见 [`board-voice-emotion-sync.md`](./board-voice-emotion-sync.md) |
| 提示音样例 | [`media/diii.wav`](../media/diii.wav)（开录）· [`media/di-du.wav`](../media/di-du.wav)（结束） |

> 不要 `echo 43 > /sys/class/gpio/export` —— 已被 `gpio-keys` 占用。用 **evdev**（主路径）或读 `/sys/kernel/debug/gpio`。

## 脚本（`/userdata/xiaozhi-cli/`）

| 文件 | 作用 |
|------|------|
| `board-ptt-hold.sh` | PTT 守护：按键 →「diii」→ 录音 →「滴嘟」→ `board-voice-once` → 播回复；支持打断 |
| `S44xiaozhi-ptt.sh` | SysV 后台启动（可选） |
| `diii.wav` | 开录提示音（sox，单音 ~1400 Hz，48 kHz stereo） |
| `di-du.wav` | 结束提示音（sox，滴+嘟，48 kHz stereo） |
| `board-voice-once.sh` | `USE_EXISTING_REC=1` + `SKIP_PLAY=1` 供 PTT 播报/打断 |

## UX

默认 **`PTT_MODE=toggle`**：

1. **第一次按下** KEY5 → 播本地 **「diii」**（`diii.wav`）→ 开始 `arecord`（若正在播 TTS：**立刻 `kill aplay`**，丢弃该回复，**不续播**，再 diii+开录）。
2. **第二次按下** → 结束录音 → 播本地 **「滴嘟」**（`di-du.wav`）→ `POST` voice bridge → **只等新回复** 再 `aplay`。
3. 播回复期间再按 → 同 (1) 打断并开录。

可选 **`PTT_MODE=hold`**：按下 = diii+开录；松开 = 滴嘟+桥+打断。

## GPIO / 边沿

```text
gpiochip1: GPIOs 32–63 (gpio1)
 gpio-43  ( |user-key1 ) in  hi IRQ ACTIVE LOW   # 空闲 hi；按下 lo
```

轮询/边沿：守护进程 `select` 读 `event7` 的 `EV_KEY`（按下 value=1 / 松开 value=0）。  
DT 为 KEY_PROG2(149)；板上 `capabilities/key` 可能只见 bit21 —— 脚本接受该节点上任意 `EV_KEY`。

## 生成提示音（sox）

```bash
/userdata/xiaozhi-cli/board-ptt-hold.sh --mk-didu   # regenerates diii.wav + di-du.wav
# diii (start):
# sox -n -r 48000 -c 2 -b 16 diii.wav synth 0.14 sine 1400 vol 0.4
# 滴嘟 (end):
# sox -n -r 48000 -c 2 -b 16 di-du.wav \
#   synth 0.09 sine 1200 vol 0.4 : synth 0.05 sine 0 : synth 0.12 sine 880 vol 0.4
aplay -D hw:0,0 /userdata/xiaozhi-cli/diii.wav
aplay -D hw:0,0 /userdata/xiaozhi-cli/di-du.wav
```

## 运行

```bash
cd /userdata/xiaozhi-cli
./board-ptt-hold.sh --self-test
./board-ptt-hold.sh              # 守护（toggle）
./board-ptt-hold.sh --once       # 一轮后退出
PTT_MODE=hold ./board-ptt-hold.sh
# 开机（可选）:
ln -sfn /userdata/xiaozhi-cli/S44xiaozhi-ptt.sh /etc/init.d/S44xiaozhi-ptt
/etc/init.d/S44xiaozhi-ptt start
# 无按键烟测（需 bridge + cookie）:
PTT_SMOKE=1 ./board-ptt-hold.sh
```

## 冒烟记录

| 时间（Asia/Shanghai） | 结果 |
|----------------------|------|
| 2026-10-29 ~10:25 | `--self-test` OK（gpio-43 / event7）；`--mk-didu` 滴嘟 + `aplay` rc0；barge OK；`PTT_SMOKE=1` bridge **rc0**。 |
| 2026-10-29 ~10:32 | 开录 **「diii」** cue；`--mk-didu` 双 wav；push + 守护重启（无 flash）。 |
| 2026-10-29 ~10:44 | **XR-92 真机 PTT OK**。截断 TTS 已修：bridge 等 stable `reply_text` → Edge 全文；烟测 `x-tts-engine: edge`，mp3 **115632 B**（~19 s，`x-reply-chars=158`）≫ 旧 ~10 KB。PTT 加 post-end guard 防误打断。**请用户 KEY5 再听一遍是否整段。** |
| 2026-10-29 ~11:00 | 同内容进 chat **两次**：双 `python` 占 event7。已 `flock`+`EVIOCGRAB`+杀孤儿；bridge 跳过重复 `session.prompt`。见 [`internal/ptt-double-turn-fix.md`](../internal/ptt-double-turn-fix.md)。**请再 KEY5 一轮（必要时先重启 PC bridge）。** |
