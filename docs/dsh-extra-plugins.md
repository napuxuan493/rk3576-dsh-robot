# DSH Desktop 额外插件

本机（用户 na puxuan）web profile 已装上主动消息、活记忆、自学、表情包和 ChatPlus，并放了 5 个工程向 skill。板子、`/userdata` 和人设文件都没改。

| 项 | 值 |
|----|-----|
| Desktop | `C:\Program Files\DSH Desktop` |
| Profile | `%APPDATA%\dsh-desktop\harness\profiles\web` |
| 安装命令 | 下面这一条 |
| 人设 | `cordis.patch.yml` **未改**。安装前备份：同目录 `cordis.patch.yml.bak-pre-extra-20261030-174611` |
| 启动结果 | Harness 已就绪，**没有**进入 Safe Mode |

```powershell
$env:DSH_HOME = "$env:APPDATA\dsh-desktop\harness"
& "$env:USERPROFILE\.dsh-tools\node_modules\.bin\dsh.cmd" plugin --profile web add dsh-proactive dsh-living-memory dsh-plugins-learn dsh-meme dsh-chat-plus
```

这些包已经写进 `package.json` 的 `dependencies` 和 `dsh.profile.bundles`，打开 Desktop 就会加载。侧栏 **插件 → 已安装** 里应能看到下表包名。若某一行是关的，把开关打开。

## 已安装的插件

| 你要的能力 | 实际安装 | 版本 | 界面里怎么开 |
|------------|----------|------|----------------|
| 主动消息 | `dsh-proactive`（[john-walks-slow/dsh-proactive](https://github.com/john-walks-slow/dsh-proactive)） | 0.3.2 | **设置 → 主动唤醒**。模型用 `proactive_set` 定闹钟；到点由宿主唤醒会话，没事可报就 `proactive_reclaim` 静默收尾。这是 Desktop 插件，没有改板端问候桥。 |
| 活记忆 | `dsh-living-memory`（[dearbld/dsh-living-memory](https://github.com/dearbld/dsh-living-memory)） | 0.2.10 | 装上即用，不用再点开关。工具：`memory`（搜索 / 时间线）和 `memory_write`。数据在 `%USERPROFILE%\.dsh\dsh-living-memory\`。 |
| 自学 | `dsh-plugins-learn`（[kouyichi/dsh-plugins](https://github.com/kouyichi/dsh-plugins) 里的 `dsh-learn`） | 1.0.1 | 插件 id 仍是 `dsh-learn`。对话里让模型调用 `learn_record` / `learn_draft` / `learn_promote` / `learn_review`。发布后的 skill 出现在 Harness 的 `skills` 目录。 |
| 表情包管理器 | `dsh-meme`（[yyh-001/dsh-meme](https://github.com/yyh-001/dsh-meme)） | 0.1.71 | 输入框旁 **😊** 选图。管理在 **设置 → 表情包**（图库开关、上传、ZIP 导入导出、市场安装）。内置大肥鱼图库。旧名 `dsh-expression` 只是内部 id。 |
| ChatPlus | `dsh-chat-plus`（npm；仓库 [kr-atg/dsh-chat-plus](https://github.com/kr-atg/dsh-chat-plus)） | 1.2.0 | 装上即生效：思考和工具调用收成一行，点开是活动抽屉；消息栏有截图。供应商相关项在 **设置 → 供应商**（不要把 Key 写进本文）。 |

原先已在的 `dsh-pet`、`dshmarket`、`dsh-voice-mode` 仍在 bundles 里。

## 改过的文件

- `%APPDATA%\dsh-desktop\harness\profiles\web\package.json` — 五个新依赖和对应 bundle。安装前备份：`package.json.bak-pre-extra-20261030-174611`。
- 同目录 `pnpm-lock.yaml` 与 `node_modules\` — `dsh plugin` 交给 pnpm 装的包。
- `node_modules\dsh-plugins-learn\cordis.patch.yml` — **只改了一行**。上游写的是 `name: dsh-learn`，但 npm 包名是 `dsh-plugins-learn`，按那个名字去加载会找不到模块。现为 `name: dsh-plugins-learn`，插件 id 仍是 `dsh-learn`。
- `%APPDATA%\dsh-desktop\harness\skills\` — 下面 5 个 skill，外加 ChatPlus 自己复制进去的 2 个。
- 插件运行后自己建的数据：`%USERPROFILE%\.dsh\dsh-living-memory\`、`%APPDATA%\dsh-desktop\harness\proactive\`。

`cordis.patch.yml`（人设）的内容与备份一致，没有手改缩进。

## 额外 skill（5 个）

来自 [ben7am1n/dsh-review-skills](https://github.com/ben7am1n/dsh-review-skills) 的 `skills/`。该仓库没有上 npm，用 GitHub 地址装插件会跑 `tsc`，pnpm 默认不让执行安装脚本，所以没有装成插件，只把通过 frontmatter 检查的 `SKILL.md` 拷进 skill 根目录：

`%APPDATA%\dsh-desktop\harness\skills\`

| Skill | 何时用 |
|-------|--------|
| `code-review` | 看 diff：正确性、测试、边界、多余复杂度和安全问题 |
| `simplify` | 改完之后去掉多余层次 |
| `plan-then-execute` | 先写计划再改代码 |
| `test-first` | 先写会失败的测试再实现 |
| `resolve-conflict` | 处理合并冲突 |

在会话里直接说「按 code-review 看这次改动」即可。输入框 `/` 菜单里也能看到 skill 名（ChatPlus 接管了官方 skill 菜单）。

ChatPlus 启动时还会把自己包里的 `diagram-design`、`motion-primitives` 拷进同一个 skill 目录。那是插件自带的，不是另外从 GitHub 挑的。

## 没有装的，以及原因

- **没有**名叫「主动消息」的第二个包。对应能力就是 `dsh-proactive`。板端 LAN 问候桥没动。
- npm 上的 **`dsh-learn` 0.1.1 是另一套教学/测验插件**（`/teach`），不是这次要的自学，所以没装。自学用的是 `dsh-plugins-learn`。
- **`dsh-rsi`** 不在 npm 上。
- **`@lmzhen/dsh-evolution-all`** 是大约 30 个插件的大包，和已装的自学插件叠在一起容易抢记忆和 skill。没有装。
- **`find-plugins` skill**（Nagi-ovo/dsh-find-plugins）能装，但它的脚本会读本机 `gh` 登录令牌去调 GitHub API。没有放进 skill 目录。

## 语音没有改

| 检查 | 结果 |
|------|------|
| `dsh-voice-mode` | 仍在 bundles 里。`GET http://127.0.0.1:43129/voice-mode` → `enabled: true` |
| 音色 | `voice-mode.settings.json` 仍是 `zh-CN-XiaoxuanNeural` |
| 手机桥 43127 | `http://127.0.0.1:43127/` 返回 200 |
| 语音桥 43128 | 这次开始前就没有在听；`%USERPROFILE%\dsh-voice-bridge` 没改 |

## 启动时的一句警告

Desktop 会尝试把插件迁进 generations。这次停在 `dsh-meme`：它声明的 peer `@deepseek-ai/dsh-tools` 不在「安装闭包」里（宿主运行时才提供，和以前 `dsh-pet` / `dsh-voice-mode` 的 peer 警告是同一类）。日志是 `profile maintenance frozen`，然后 **恢复原 profile 并正常启动**。表情包插件仍注册了 `send_meme`，活记忆也写了库。这不是 Safe Mode。

不要为了消掉这句警告去手改人设，也不要 `pnpm update dsh-plugins-learn`，除非准备把上面那一行 `name:` 再改回 `dsh-plugins-learn`。上游包若仍写 `name: dsh-learn`，更新后会再次指错包名。
