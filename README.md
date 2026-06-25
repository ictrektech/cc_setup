# cc_setup

Claude / Codex / RTK / skills / digital-workers 的一键安装脚本集合。

## Agent 环境安装

这里提供两种互斥方案。推荐新机器优先使用 cc-switch 方案；如果已经在使用 cc-haha，可以继续使用 cc-haha 方案，或者运行 cc-switch 方案自动卸载 cc-haha 后切换。

### 方案一：cc-switch + 官方 Claude Code / Codex（macOS / Linux）

这个方案安装 [saladday/cc-switch-cli](https://github.com/saladday/cc-switch-cli)，可选择安装官方 `@anthropic-ai/claude-code`、`@openai/codex` + `chat-codex`，或两者都安装，并自动配置 ICTrek provider。若检测到 cc-switch 版本低于 `5.8.4`，脚本会自动升级；若检测到 Node.js 低于 `20`，脚本会安装或切换到可用的新版本，并把路径写入 shell 配置。

默认同时安装 Claude Code、Codex 和 chat-codex：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

只安装 Claude Code：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh) --agent claude
```

只安装 Codex 和 chat-codex：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh) --agent codex
```

fish shell 可以执行：

```fish
bash -lc 'bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)'
```

以上的安装过程会按所选 agent 写入如下配置内容：

```text
Claude API 地址: https://ai.ictrek.com
Codex API 地址: https://ai.ictrek.com/v1
API Key: dummy-keys（占位，安装后请改成自己的 key）
Claude Haiku 模型: volces/DeepSeek-V4-Flash
Claude Sonnet/Opus/Reasoning/默认模型: volces/GLM-5.1
Claude Small Fast 模型: volces/DeepSeek-V4-Flash
Codex 模型: volces/GLM-5.1
Provider ID: ictrek
```

**十分建议**安装时直接写入自己的 API Key。`CC_SWITCH_API_KEY` 会同时用于 Claude Code 和 Codex：

```bash
CC_SWITCH_API_KEY="你的 API Key" bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

如果 Codex 要使用单独的 key：

```bash
CC_SWITCH_API_KEY="Claude API Key" CC_SWITCH_CODEX_API_KEY="Codex API Key" bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

如果还希望方案一自动安装并初始化 RTK：

```bash
CC_SWITCH_API_KEY="你的 API Key" CC_SWITCH_INSTALL_RTK=1 bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

`CC_SWITCH_INSTALL_RTK=1` 会安装/修复 `rtk` 到 `~/.local/bin`，并自动执行 `rtk init -g`。初始化后脚本会检查 `~/.claude/CLAUDE.md`，确保它引用 `@RTK.md` 并包含“先调用工具再回答”的 Agent 工作规则；如发现缺失或不完整，会先备份原文件再修复。RTK 是可选项，如果安装或初始化失败，脚本会继续完成 Claude 和 cc-switch 配置。

已经安装过后，可以用一条命令把 `dummy-keys` 改成自己的 key：

```bash
CC_SWITCH_API_KEY="你的 API Key" claude-update
CC_SWITCH_API_KEY="你的 API Key" codex-update
```

如果当前终端还没重新加载 PATH，可以执行：

```bash
CC_SWITCH_API_KEY="你的 API Key" ~/.local/bin/claude-update
CC_SWITCH_API_KEY="你的 API Key" ~/.local/bin/codex-update
```

这条命令会重新写入 cc-switch 的 `ictrek` provider，并同步所选 agent 的配置。也可以指定范围：

```bash
CC_SWITCH_API_KEY="你的 API Key" claude-update --agent claude
CC_SWITCH_API_KEY="你的 API Key" codex-update --agent codex
CC_SWITCH_API_KEY="你的 API Key" claude-update --agent both
CC_SWITCH_API_KEY="你的 API Key" codex-update --agent both
```

`claude-update` 默认只更新 Claude Code；`codex-update` 默认只更新 Codex 和 chat-codex。需要同时更新两边时使用 `--agent both`。

如果系统里已经有官方 Claude Code，脚本会跳过 Claude Code 的重复 npm 安装，但选择 `--agent claude` 或 `--agent both` 时仍会写入并同步 cc-switch Claude provider。Claude 安装流程会打开 Claude 代理接管和 VS Code Claude 插件接管，并关闭 Claude Code 首次打开登录/引导验证。Codex 安装流程会安装 `@openai/codex` 和 `chat-codex`，通过 cc-switch 写入 NewAPI 兼容的 `model_provider = "ictrek"` 配置，启用 cc-switch Codex 代理接管，生成 Codex model catalog，并使用本地路由把 Codex 的 Responses 请求转为上游 Chat Completions。

查看配置：

```bash
cc-switch --app claude provider current
cc-switch --app claude proxy show
claude --help
claude -p "hello"
cc-switch --app codex provider current
cc-switch --app codex proxy show
codex --version
chat-codex --help
codex
```

更新：

```bash
claude-update
codex-update
```

卸载：

```bash
claude-uninstall
codex-uninstall
```

`claude-uninstall` 默认只卸载 Claude Code 相关内容；`codex-uninstall` 默认只卸载 Codex 和 chat-codex 相关内容。需要同时卸载两边时执行：

```bash
claude-uninstall --agent both
codex-uninstall --agent both
```

卸载会移除对应 agent 的 `ictrek` provider；Claude 卸载会关闭 Claude 代理接管和 VS Code Claude 插件接管，并卸载官方 Claude Code npm 包；Codex 卸载会清理本方案写入的 Codex 配置，并卸载 Codex 和 chat-codex npm 包。它不会删除 cc-switch 本体和 `~/.cc-switch` 里的其它 provider。

### 方案二：cc-haha（macOS / Linux）

这个方案安装 `NanmiCoder/cc-haha`，并写入 `claude`、`claude-haha`、`claude-env`、`claude-update`、`claude-uninstall`。

安装：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh)
```

fish shell 可以执行：

```fish
bash -lc 'bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh)'
```

配置方式：

```bash
claude-env
```

`claude-env` 会打开 cc-haha 安装目录中的 `.env`。修改保存后重新打开终端或重新运行命令即可。

常用命令：

```bash
claude --help
claude-haha --help
claude -p "hello"
```

更新：

```bash
claude-update
```

卸载：

```bash
claude-uninstall
```

### Windows（cc-haha）

在 PowerShell 中执行：

```powershell
$script = Join-Path $env:TEMP "cc_setup_win.ps1"
$url = "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_win.ps1"
$fastUrl = "https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_win.ps1"
try { Invoke-WebRequest -Uri $url -OutFile $script -UseBasicParsing } catch { Invoke-WebRequest -Uri $fastUrl -OutFile $script -UseBasicParsing }
powershell -NoProfile -ExecutionPolicy Bypass -File $script
```

配置、更新、卸载：

```powershell
claude
claude-env
claude-update
claude-uninstall
```

## digital-workers / skills 安装

安装并更新 digital-workers，同时重新安装仓库里的 skills 到 `~/.claude/skills`：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh)
```

指定项目目录：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh) ~/projects/demo
```

如果 Claude 命令不在 PATH 中，可以指定：

```bash
CLAUDE_BIN=/home/jhu/.local/npm/bin/claude bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh)
```

安装完成后，脚本会输出项目目录，并生成示例任务。进入项目目录运行：

```bash
./run-example-full.sh
```

也可以手动运行：

```bash
cd <digital-workers 仓库目录>
CLAUDE_BIN=claude python3 -m digital_worker.runner full \
  "<项目目录>/runs/example-health-api" \
  "<项目目录>"
```

## Agent Room Web 控制台

仓库里提供了一个本地 Web 控制台，可启动和管理当前机器上的 Claude / Codex agent 会话，并提供 Git 工作区、文件树和文本编辑器。

![Agent Room Web 控制台](docs/images/agent-room.jpg)

Token 登录页：

![Agent Room token 登录](docs/images/agent-room-login.png)

左侧 Files 面板：

![Agent Room Files 面板](docs/images/agent-room-files.png)

### 启动

```bash
cd web
bash dev.sh
```

默认打开：

```text
http://localhost:3766
```

在远端机器上运行后，可以直接打开：

```text
http://<远端 IP>:3766
```

首次打开需要输入访问 token。启动服务的 Linux 用户可以在任意目录运行：

```bash
cat ~/.agentroom/token
```

也可以用服务端脚本查询，适合知道安装路径时使用：

```bash
python3 /home/jhu/dev/repos/agentroom/server.py token
```

### 配置

常用启动配置：

```bash
CLAUDE_BIN=/home/jhu/.local/npm/bin/claude CODEX_BIN=/home/jhu/.local/npm/bin/codex PORT=3766 bash dev.sh
```

支持的环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `3766` | Web 服务监听端口 |
| `CLAUDE_BIN` | `claude` | Claude CLI 路径或命令名 |
| `CODEX_BIN` | `codex` | Codex CLI 路径或命令名 |
| `CLAUDE_RUN_TIMEOUT` | `600` | Claude 单轮任务超时时间，单位秒 |
| `CODEX_RUN_TIMEOUT` | `600` | Codex 单轮任务超时时间，单位秒 |
| `AGENTROOM_AUTH_DIR` | `~/.agentroom` | token 和 session secret 保存目录 |
| `AGENTROOM_TOKEN` | 空 | 直接指定登录 token；为空时读取或生成 `~/.agentroom/token` |
| `AGENTROOM_TOKEN_PATH` | `~/.agentroom/token` | token 文件路径 |
| `AGENTROOM_AUTH_MAX_AGE` | `604800` | 登录 cookie 有效期，单位秒 |
| `AGENTROOM_SESSIONS_PATH` | `web/.agentroom_sessions.json` | Agent Room 会话恢复文件 |

Claude / Codex 命令查找顺序：

1. `CLAUDE_BIN` / `CODEX_BIN` 环境变量。
2. 当前启动用户的 `~/.local/npm/bin/claude`、`~/.local/npm/bin/codex`。
3. 当前启动用户的 `~/.local/bin/claude`、`~/.local/bin/codex`。
4. `PATH` 里的 `claude`、`codex`。

如果以上位置都找不到，需要通过 `CLAUDE_BIN` / `CODEX_BIN` 显式指定。

认证相关文件：

```text
~/.agentroom/token
~/.agentroom/session_secret
```

这两个文件会自动生成，权限为当前启动用户可读写。Webapp 不验证 Linux 密码，只验证 token；能读取启动用户 `~/.agentroom/token` 的人才能登录。

远端后台启动示例：

```bash
cd /home/jhu/dev/repos/agentroom
setsid env \
  CLAUDE_BIN=/home/jhu/.local/npm/bin/claude \
  CODEX_BIN=/home/jhu/.local/npm/bin/codex \
  PORT=3766 \
  CLAUDE_RUN_TIMEOUT=600 \
  CODEX_RUN_TIMEOUT=120 \
  bash dev.sh > /tmp/agentroom-3766.log 2>&1 < /dev/null &
```

### 当前功能

- 默认启用 token 登录；只有能读取启动用户 `~/.agentroom/token` 的用户才能进入 Web 控制台。
- 以项目目录和 agent 类型为单位创建 Agent Room，并在顶部显示运行中、已结束和总会话数。
- 支持 Claude 和 Codex 两种 agent；新建房间时可选择 agent 类型，房间会保存对应的 provider session/thread id。
- 使用 `claude -p --verbose --output-format stream-json --include-partial-messages` 运行任务，主对话窗口按 Claude 的真实 `content_block_delta` 流式输出。
- 使用 `codex exec --json` / `codex exec resume --json` 运行 Codex 任务，并在 Raw 视图保留 Codex JSONL 事件。
- 主窗口显示结构化的 `System / You / Agent` 对话气泡，避免 CLI spinner、控制字符和 JSON 流污染回答。
- 提供 Raw 视图查看原始输出，方便排查 Claude CLI 或 JSON stream 问题。
- 中间工作区支持 `对话 / Raw / 文件` 标签页切换，聊天输入框固定在对话窗口底部，聊天历史保持固定高度并支持鼠标滚动查看上下文。
- 左侧项目区提供文件夹树，点击文件夹可展开并选为当前目标目录；新建文件会落在当前目录，文件也可拖拽移动到其它文件夹。
- 发送任务时显示运行状态，例如等待首字、正在生成、完成。
- 支持浅色/深色主题切换，界面采用更接近 macOS 的浅色优先、半透明面板和系统控件风格。
- 右侧 Git 面板会自动识别当前项目仓库，显示分支、提交、ahead/behind、变更文件、diff 和可点击的 SVG Git graph 分支图。
- Git 面板支持单文件或全部 `stage / unstage`、填写提交信息后 `commit`，以及 `fetch / pull --ff-only / push`。
- 文件编辑器支持轻量代码高亮、保存当前文件，保存后右侧 Git 状态会刷新。
- 同一工作目录已有 running 房间时，再次启动会切换到已有房间，避免误触重复创建。

## 脚本说明

- `cc_switch_setup.sh`: macOS / Linux 安装官方 Claude Code、Codex、chat-codex 和 cc-switch-cli，按 `--agent claude|codex|both` 配置 ICTrek provider，并写入 `claude-update`、`codex-update`、`claude-uninstall`、`codex-uninstall`。
- `cc_setup_unix.sh`: macOS / Linux 安装 Claude 环境、RTK，并写入 `claude`、`claude-env`、`claude-update`、`claude-uninstall`。
- `cc_setup_win.ps1`: Windows PowerShell 安装 Claude 环境、RTK，并写入对应命令。
- `dworkers_setup.sh`: 克隆/更新 `ictrektech/digital-workers`，重装 skills，生成 `.env` 和示例任务。
- `digital_workers_setup.sh`: 兼容入口，本地执行时转到 `dworkers_setup.sh`，远程执行时拉取 `dworkers_setup.sh`。
- `web/`: Agent Room Web 控制台，支持 `claude` / `codex` 命令，提供项目目录选择、会话启动、实时输出、多会话切换、Git 工作区管理和项目文件编辑。
