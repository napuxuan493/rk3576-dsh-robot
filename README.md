# RK3576 DSH Robot（板端 / 桥接代码）

本仓库只收录**可运行脚本与配套短技术说明**，不含长篇讲义 / 公众号文稿 / 大体积媒体。

## 快速入口

- 技术概要：[docs/project-tech-brief.md](docs/project-tech-brief.md)
- 板端配对逐行说明：[docs/board-dsh-pair-line-by-line.md](docs/board-dsh-pair-line-by-line.md)
- 板端客户端：[docs/dsh-board-client.md](docs/dsh-board-client.md)
- 语音桥接：[docs/dsh-voice-bridge.md](docs/dsh-voice-bridge.md) · [docs/dsh-voice-bridge-server-mjs.md](docs/dsh-voice-bridge-server-mjs.md)
- 耳机音频：[docs/board-headset-audio.md](docs/board-headset-audio.md)
- PTT KEY5：[docs/board-ptt-key5.md](docs/board-ptt-key5.md)
- HDMI 表情 UI：[docs/board-hdmi-emotion-ui.md](docs/board-hdmi-emotion-ui.md)
- 语音与表情同步：[docs/board-voice-emotion-sync.md](docs/board-voice-emotion-sync.md)
- 额外插件安装笔记：[docs/dsh-extra-plugins.md](docs/dsh-extra-plugins.md)

## 目录

### `docs/cli-llm-chat/`（板端脚本）

- `board-*.sh`：配对、对话、ASR/TTS、PTT、网络/音频等
- `S42xiaozhi-ics.sh` / `S43xiaozhi-audio.sh` / `S44xiaozhi-ptt.sh`：启动相关
- `hdmi-emotion-ui/`：HDMI 表情帧缓冲 UI（`emotion_fb.py`、`emotion_api.py`、启停脚本）
- `board-dsh.env.example` / `env.example`：环境变量模板（勿提交真实 `.env`）

详见 [docs/cli-llm-chat/README.md](docs/cli-llm-chat/README.md)。

### `docs/dsh-voice-bridge/`（PC 侧桥接）

- `server.mjs`：语音桥接服务
- `start.ps1`：启动脚本
- `env.example`：配置模板

## 安全说明

请只使用 `*.env.example` 作为模板；真实密钥、cookie、凭证与 `internal/` 工作笔记不要推入本仓库。