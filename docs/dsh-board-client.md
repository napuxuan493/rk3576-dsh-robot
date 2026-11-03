# 板端 → Windows DSH（XR-31）

**已锁定：板端走 LAN，不走 Pinggy。**

目标：TL3576 瘦客户端调 PC 上 DSH（人设 / 工具 / 记忆）。DSH 只跑 Windows；Linux VM 只做板端调试。

勿把 pair token、`dsh_mobile` cookie、API Key 写入仓库。若曾在聊天中暴露 pairing/Pinggy token → Desktop **断开手机** 并重新配对以轮换（本仓库不保存任何真实 token）。

---

## 1. 通道锁定

| 通道 | 用途 | 板端 |
|------|------|------|
| **LAN 手机桥** `http://<Windows-WLAN-IP>:43127` | 板 ↔ DSH（本方案） | **是** |
| Pinggy / Cloudflare `…/pair?token=` | **仅手机**公网配对 | **否** — 不为板设计 |
| Harness `127.0.0.1:43129` | PC 本机 Agent RPC | 板不可直连 |
| PC Gateway（可选后续） | 本机签 cookie 再对外 | 备选，非当前默认 |

当前直连以太网 ICS：`192.168.137.1` → 板端应设  
`DSH_BASE_URL=http://192.168.137.1:43127`  
（板 eth0 在 `192.168.137.0/24` 时用这个；WLAN `10.23.9.124` 仅当板也在同 Wi‑Fi 网段。**不要**用 VMware `192.168.129.1` / `192.168.200.1`。）

### 防火墙（必做）

在 Windows 放行 **入站 TCP 43127**，来源限制为板所在网段（例如 `10.23.0.0/16`），配置文件选「专用」。不放行 43129 到局域网/公网。

---

## 2. Pair 端点 vs Chat 端点

同一 LAN 主机 `http://10.23.9.124:43127`：

| 阶段 | 路径 | 凭据 | 说明 |
|------|------|------|------|
| **配对** | `GET /pair?token=<PAIR_TOKEN>` | Desktop「连接手机」生成的短时 token（~5 min） | 仅私网；**当前 Desktop 无「批准」按钮，请求即连接** |
| **Cookie** | 同次 `/pair` 响应（常为 **302**） | `Set-Cookie: dsh_mobile=…` | 空 body / `Location=/` 也可能已带 cookie；勿只解析 HTML |
| **轮询** | `GET /pair/status?id=…` | — | 旧桥/需批准时的后备；本机 UX 通常不需要 |
| **聊天** | `POST /api/rpc` | **`Cookie: dsh_mobile=…`** | 白名单 RPC → Desktop 转发本机 Harness |
| **状态** | `GET /api/status` | `dsh_mobile` | 探测是否仍已配对 |

Pair URL **不是**聊天 URL。聊天只用 `DSH_BASE_URL` + `DSH_MOBILE_COOKIE`。

**坑：** Desktop 显示「已连接」只说明 PC 侧会话在；板端必须从 `/pair` 响应写入 `.env` 的 `DSH_MOBILE_COOKIE`，否则 `board-dsh-chat.sh` 仍报 unset。

`POST /api/rpc` 白名单：`workspace.list`、`session.list`、`session.history`、`session.create`、`session.prompt`、`session.cancel`。

```http
POST /api/rpc
Origin: http://10.23.9.124:43127
Cookie: dsh_mobile=<from-env>
Content-Type: application/json

{"method":"session.prompt","payload":{…}}
```

---

## 3. 板端配置与脚本

### `.env`（chmod 600）

见 [`board/board-dsh.env.example`](../board/board-dsh.env.example)。

| 变量 | 含义 |
|------|------|
| `DSH_BASE_URL` | 默认 `http://10.23.9.124:43127`（无 path、无 token） |
| `DSH_MOBILE_COOKIE` | 配对成功后的 cookie 值 |
| `DSH_PAIR_TOKEN` | 仅配对用；完成后可删 |
| `DSH_SESSION_ID` | **置顶会话**（优先于 `session.list[0]` / `session.create`）。大肥鱼演示默认 `session-dafeiyu-smoke-1793077192324`；换 agent 就改这一项或临时 `DSH_SESSION_ID=… ./board-dsh-chat.sh` |

### 脚本

| 文件 | 作用 |
|------|------|
| [`board-dsh-pair-url.sh`](../board/board-dsh-pair-url.sh) | **推荐**：粘贴完整 `http://HOST:PORT/pair?token=…` → 解析 base+token → pair → `.env` |
| [`board-dsh-pair.sh`](../board/board-dsh-pair.sh) | LAN pair（`DSH_PAIR_TOKEN` / 或同样接受完整 URL）→ cookie → `.env`（不打印秘密） |
| [`board-dsh-chat.sh`](../board/board-dsh-chat.sh) | 多轮 `/api/rpc` 聊天 |

### 操作顺序

1. PC 启动 **DSH Desktop**，菜单 **连接手机**（生成 LAN 配对；可忽略 Pinggy）  
2. 板或调试机（推荐一键）：  
   `./board-dsh-pair-url.sh 'http://192.168.137.1:43127/pair?token=…'`  
   （当前 Desktop 无「批准」按钮，请求即连接）  
3. 确认 `.env` 有 `DSH_MOBILE_COOKIE`，`chmod 600`  
4. `board-dsh-chat.sh` 交互对话  
5. Desktop「断开手机」会使 cookie 失效，需重新 pair  

刷机后还原与演示步骤见 [`board-postflash-restore.md`](./board-postflash-restore.md)。

---

## 4. 本机 Harness 发现（备查，非板默认）

`127.0.0.1:43129`：无 cookie → `/api/*` 401；可用 `%APPDATA%\dsh-desktop\harness\.credentials.yaml` 中 `client-connection/browser-session` 签名 cookie。已冒烟：`session/list`、`session/prompt`（accepted）。板默认不走此路径。

---

## 5. Blocker

1. 每次 Desktop「断开手机」或重启配对会话后需重新 pair。  
2. 经桥的 `session.prompt` payload 需与当前 Desktop 转发对齐；脚本按白名单封装。  
3. MVP 用 `session.history` 拉回复；完整流式 follow 桥未直接暴露。  

相关：[`dsh-pc-setup.md`](./dsh-pc-setup.md)、[`board/README.md`](../board/README.md)。
