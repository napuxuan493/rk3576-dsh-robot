# RK3576 DSH Robot（板端 / 桥接代码）

本仓库只收录**可运行脚本与配套短技术说明**，不含长篇讲义 / 公众号文稿 / 大体积媒体。  
约定见 **[docs/CONVENTIONS.md](docs/CONVENTIONS.md)**（布局、命名、DSH_*、同步路径、禁止事项）。

## 树图

`
board/                         # 板端运行时脚本 → /userdata/xiaozhi-cli
  board-*.sh                   # 配对 / 对话 / ASR·TTS / PTT / 网络·音频
  S42…S44xiaozhi-*.sh          # 开机辅助
  hdmi-emotion-ui/             # HDMI 表情帧缓冲 UI
  *.env.example
windows/dsh-voice-bridge/      # Windows LAN 语音桥（Node ESM）
  server.mjs · start.ps1 · env.example · package.json
docs/                          # 短技术说明（非运行时）
  CONVENTIONS.md               # 本仓库约定
scripts/                       # 约定检查（可选）
`

历史上 docs/cli-llm-chat/ 已迁到 oard/；语音桥代码已迁到 windows/dsh-voice-bridge/。板上绝对路径仍是 **/userdata/xiaozhi-cli**。

## 快速开始

### 1. Windows 语音桥（Desktop 须已开）

`powershell
powershell -ExecutionPolicy Bypass -File .\windows\dsh-voice-bridge\start.ps1
# 会同步到 %USERPROFILE%\dsh-voice-bridge 并监听 :43128
`

或：cd windows\dsh-voice-bridge → 
pm start / 
ode server.mjs。

### 2. 板端配对 + 文字聊

`ash
# 将 board/ 推到 /userdata/xiaozhi-cli/ 后：
./board-dsh-pair-url.sh 'http://192.168.137.1:43127/pair?token=…'
./board-dsh-chat.sh
`

环境变量模板：oard/board-dsh.env.example → 板上 .env（chmod 600，勿提交）。

### 3. 约定检查

`powershell
.\scripts\check-conventions.ps1
`

## 文档入口

- 约定：[docs/CONVENTIONS.md](docs/CONVENTIONS.md)
- 技术概要：[docs/project-tech-brief.md](docs/project-tech-brief.md)
- 板端配对逐行：[docs/board-dsh-pair-line-by-line.md](docs/board-dsh-pair-line-by-line.md)
- 板端客户端：[docs/dsh-board-client.md](docs/dsh-board-client.md)
- 语音桥接：[docs/dsh-voice-bridge.md](docs/dsh-voice-bridge.md) · [docs/dsh-voice-bridge-server-mjs.md](docs/dsh-voice-bridge-server-mjs.md)
- 耳机音频：[docs/board-headset-audio.md](docs/board-headset-audio.md)
- PTT KEY5：[docs/board-ptt-key5.md](docs/board-ptt-key5.md)
- HDMI 表情 UI：[docs/board-hdmi-emotion-ui.md](docs/board-hdmi-emotion-ui.md)
- 语音与表情同步：[docs/board-voice-emotion-sync.md](docs/board-voice-emotion-sync.md)
- 额外插件笔记：[docs/dsh-extra-plugins.md](docs/dsh-extra-plugins.md)
- 板端脚本说明：[board/README.md](board/README.md)

## 安全

只用 *.env.example 作模板；真实密钥、cookie、凭证与本地工作笔记不要推入本仓库。
