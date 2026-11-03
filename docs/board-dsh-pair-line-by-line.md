# `board-dsh-pair.sh` 逐行讲解

路径：repo `board/board-dsh-pair.sh` → 板 `/userdata/xiaozhi-cli/board-dsh-pair.sh`。  
作用：用短时 pair token 访问 Desktop `:43127/pair`，拿到 `dsh_mobile` cookie，写入同目录 `.env`（不打印密钥）。

---

## 头注释与严格模式（1–10）

| 行 | 代码 | 含义 |
|----|------|------|
| 1 | `#!/usr/bin/env bash` | 用 `PATH` 里的 bash 跑 |
| 2–9 | `# …` | 说明：LAN pair、无 Approve、cookie 常在 302 的 Set-Cookie、勿打印密钥、推荐 pair-url |
| 10 | `set -euo pipefail` | 失败退出；未定义变量报错；管道任一段失败算失败 |

## 目录与 die（12–15）

| 行 | 代码 | 含义 |
|----|------|------|
| 12 | `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` | 脚本所在绝对目录 |
| 13 | `cd "$SCRIPT_DIR"` | 工作目录切到脚本旁，相对路径稳 |
| 15 | `die() { echo "ERROR: $*" >&2; exit 1; }` | 打错误到 stderr 并退出 |

## 完整 URL 转交（17–20）

| 行 | 代码 | 含义 |
|----|------|------|
| 18 | `if [[ "${1:-}" == http://* \|\| … https://* ]]` | 第 1 参已是完整链接 |
| 19 | `exec … board-dsh-pair-url.sh "$1"` | 换成 URL 包装脚本（解析逻辑只留一处），本进程结束 |

## 备份 → 读 .env → 恢复（22–37）

| 行 | 代码 | 含义 |
|----|------|------|
| 23–25 | `_PRE_BASE/TOKEN/COOKIE="${…-}"` | source 前备份环境里已有值（无冒号：仅「未设置」时为空） |
| 27–32 | `source .env` + `set -a/+a` | 读入 `.env` 并自动 export |
| 34–36 | `[[ -n "$_PRE_…" ]] && 恢复` | 调用方/环境非空则盖回，防止旧 `.env` 盖掉本次 BASE/token |
| 37 | `unset _PRE_*` | 删临时备份名 |

## 默认值与校验（39–49）

| 行 | 代码 | 含义 |
|----|------|------|
| 39 | `DSH_BASE_URL="${DSH_BASE_URL:-http://192.168.137.1:43127}"` | 空则默认 ICS 主机手机桥 |
| 40 | `${DSH_BASE_URL%/}` | 去掉末尾 `/` |
| 41 | `DSH_PAIR_TOKEN="${DSH_PAIR_TOKEN:-}"` | 保证变量存在（可空） |
| 43 | `[[ -n "$DSH_PAIR_TOKEN" ]] \|\| die "…"` | 仍无 token 就退出 |
| 45–46 | `command -v curl/python3` | 缺工具则 die |
| 48–49 | `HAVE_JQ=0/1` | 有 jq 则后面轮询可解析 JSON；没有也能跑 |

## 临时文件与清理（51–54）

| 行 | 代码 | 含义 |
|----|------|------|
| 51–53 | `mktemp` cookie jar / 响应头；固定 body 路径 | curl 落盘用 |
| 54 | `trap 'rm -f …' EXIT` | 脚本结束（含失败）删临时文件 |

## 函数：从 jar 取 cookie（56–59）

| 行 | 代码 | 含义 |
|----|------|------|
| 56–59 | `cookie_from_jar` | 读 Netscape cookie 文件；第 6 列名、第 7 列值；找 `dsh_mobile`；`tail -1` 取最后一次 |

## 函数：从响应头取 cookie（61–92）

| 行 | 代码 | 含义 |
|----|------|------|
| 63–91 | 内嵌 python | 读 `-D` 头文件；拼折叠行；找 `Set-Cookie:` 里 `dsh_mobile=`；打印值（不成功则空） |
| 用途 | | 板端 sed 容易漏大小写/折行，python 更稳 |

## 函数：旧版 pending id（94–105）

| 行 | 代码 | 含义 |
|----|------|------|
| 94–105 | `extract_pending_id` | 从 Location/HTML 抠 UUID（三种正则兜底），给旧「待批准」轮询用 |

## 函数：写 .env（107–132）

| 行 | 代码 | 含义 |
|----|------|------|
| 110–111 | `touch` + `chmod 600` | 建/收紧权限 |
| 112–131 | python upsert | 写/更新 `DSH_BASE_URL`、`DSH_MOBILE_COOKIE`；删掉 `DSH_PAIR_TOKEN` 行；打印长度不打印值 |

## 主流程：GET /pair（134–149）

| 行 | 代码 | 含义 |
|----|------|------|
| 134–135 | echo | 提示 BASE（无 token） |
| 138–141 | `curl -D HDR -o BODY -w http_code -c/-b jar …/pair?token=` | 取头+体+状态码；jar 存 cookie |
| 142–144 | 读 body、Location、打印摘要 | 常 302、`location=/`、body 空 |
| 146–149 | jar 优先，空则头解析 | 得到 `COOKIE_VAL` |

## 可选跟 Location（151–169）

cookie 仍空且 Location 不是 `/` 时，拼成绝对 URL 再 GET 一次，再从 jar/头取 cookie。

## 旧桥 pending 轮询（171–200）

仍无 cookie：从 Location/HTML 抽 pending id，最多 60 次每秒打 `/pair/status?id=`；denied/expired 则 die；拿到 cookie 就 break。当前 Desktop 多半不走这支。

## 失败诊断与成功写盘（202–210）

| 行 | 代码 | 含义 |
|----|------|------|
| 202–207 | 打印 Set-Cookie **名**（值打码）、jar 里 cookie 名 | 再 die |
| 210 | `write_env_cookie` | 成功写入 `.env` |

## 验收 /api/status（212–218）

带 `Cookie: dsh_mobile=…` 打 status，期望 HTTP 200；打印 body 前 200 字符（一般是 `connected`）。

## 可选 pair 后问候（220–233）

`GREET_ON_PAIR=1` 且有 `board-greet.sh`、`.env` 里有 `DSH_SESSION_ID` 时调问候；否则跳过。

## 结束（235）

提示下一步跑 `board-dsh-chat.sh`。

---

## 数据流一句话

`token`（一次性）→ `GET /pair` → `Set-Cookie: dsh_mobile` → 写入 `.env` → 以后 RPC/语音桥用 cookie，不再带 token。
