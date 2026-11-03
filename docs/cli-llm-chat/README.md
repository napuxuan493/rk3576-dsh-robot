# 小智 CLI — LLM 多轮闲聊冒烟工具

在 **全 Linux + 自拼 REST** 架构下，用 OpenAI 兼容 `/v1/chat/completions` 做交互式文字对话。板上 DSH 薄客户端 + CON24 音频见同目录 `board-dsh-*.sh` / `board-audio-up.sh` / `board-asr-once.sh` / `board-tts-say.sh`。**DeepSeek key = 文本 LLM only**（无 `/v1/audio/*`）；真 ASR/TTS 需独立 speech 厂商或未来 DSH Desktop 语音工具。

## 依赖

- `bash`、`jq`、`python3`（HTTPS）
- 推荐再装 `curl`（`sudo apt install curl`）；本脚本在无 curl 时自动用 python3 回退

## 配置

```bash
cd ~/xiaozhi-cli
cp env.example .env
# 编辑 .env，填入真实 Key；权限建议：
chmod 600 .env
```

当前已锁定（DeepSeek）：

| 变量 | 值 |
|------|-----|
| `LLM_API_BASE` | `https://api.deepseek.com` |
| `LLM_MODEL` | `deepseek-chat` |
| `LLM_API_KEY` | 写在本地 `.env`（勿提交） |

请求 URL：`{LLM_API_BASE}/v1/chat/completions`  
（若 BASE 已以 `/v1` 结尾，则拼 `/chat/completions`，避免双 `/v1`。）

也可不写 `.env`，直接 export：

```bash
export LLM_API_BASE=https://api.deepseek.com
export LLM_API_KEY=sk-***   # 换成你的 Key
export LLM_MODEL=deepseek-chat
```

## 在本 VM（na）上运行

```bash
cd ~/xiaozhi-cli
./chat.sh
```

输入一句话回车；`quit` / `exit` / Ctrl-D 退出。多轮上下文保存在临时 JSON 消息数组中。

单轮冒烟（非交互）：

```bash
printf '%s\nquit\n' '你好，请用一句话介绍你自己' | ./chat.sh
```

## 推到板端（adb，可选）

板端需有网络、`bash`/`jq`/`curl` 或 python3：

```bash
adb push ~/xiaozhi-cli/chat.sh /userdata/xiaozhi-cli/
adb push ~/xiaozhi-cli/env.example /userdata/xiaozhi-cli/
# 在板端自行创建 .env（不要把本机 .env 推进仓库；可用 adb push 私密传输）
adb shell 'chmod +x /userdata/xiaozhi-cli/chat.sh && cd /userdata/xiaozhi-cli && ./chat.sh'
```

## 板端网络冒烟（board-net-test）

全 Linux 板上探测网卡、有线优先 / WiFi 回退、DHCP、`ping`、可选 HTTP：

```bash
~/xiaozhi-cli/board-net-test.sh
# 覆盖实验室默认：export WIFI_SSID=... WIFI_PASS=...
```

默认 SSID/密码见脚本内 LAB 默认值或环境变量（实验室专用）。详见 [board-net-test.md](./board-net-test.md)。

## 板端 → PC DSH（LAN，XR-31）

直连 DeepSeek 之外的路径：板走 Windows WLAN 上的 Desktop 桥（默认 `http://10.23.9.124:43127`），**不用 Pinggy**。

- 说明：[`../dsh-board-client.md`](../dsh-board-client.md) · 刷机还原演示 [`../board-postflash-restore.md`](../board-postflash-restore.md)
- `board-dsh.env.example` → `.env`（chmod 600）
- **Pair one-liner（粘贴完整 URL）：**  
  `./board-dsh-pair-url.sh 'http://192.168.137.1:43127/pair?token=…'`  
  然后 `./board-dsh-chat.sh`
- 也可用：`board-dsh-pair.sh`（env token）/ `board-dsh-chat.sh`

## Context 镜像

同内容副本：`docs/cli-llm-chat/`（含 README、env.example、chat.sh、board-dsh-*、board-net-test、smoke-log；**不含** `.env`）。

## 错误提示

| 情况 | 表现 |
|------|------|
| 无网络 | `ERROR: 网络失败：无法连接 ...` |
| 无 Key | `ERROR: LLM_API_KEY 未设置` |
| HTTP 非 200 | 打印状态码与响应体前 2KB |
