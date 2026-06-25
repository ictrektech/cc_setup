# Agent Room

一个本地 Web 控制台，用来启动和管理当前机器上的 Claude / Codex agent 会话，并提供 Git 工作区、文件树和文本编辑器。

![Agent Room Web 控制台](../docs/images/agent-room.jpg)

Token 登录页：

![Agent Room token 登录](../docs/images/agent-room-login.png)

左侧 Files 面板：

![Agent Room Files 面板](../docs/images/agent-room-files.png)

## 启动

```bash
cd web
bash dev.sh
```

默认打开：

```text
http://localhost:3766
```

远端机器运行后，打开：

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

## 配置

常用启动配置：

```bash
CLAUDE_BIN=/data/jhu/dev/bin/claude CODEX_BIN=/home/jhu/.local/npm/bin/codex PORT=3766 bash dev.sh
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
  CLAUDE_BIN=/data/jhu/dev/bin/claude \
  CODEX_BIN=/home/jhu/.local/npm/bin/codex \
  PORT=3766 \
  CLAUDE_RUN_TIMEOUT=600 \
  CODEX_RUN_TIMEOUT=120 \
  bash dev.sh > /tmp/agentroom-3766.log 2>&1 < /dev/null &
```

## 当前功能

- 默认启用 token 登录；只有能读取启动用户 `~/.agentroom/token` 的用户才能进入 Web 控制台。
- 以项目目录和 agent 类型为单位创建 Agent Room，并在顶部显示运行中、已结束和总会话数。
- 支持 Claude 和 Codex 两种 agent；新建房间时可选择 agent 类型，房间会保存对应的 provider session/thread id。
- 使用 `claude -p --verbose --output-format stream-json --include-partial-messages` 运行任务，主对话窗口按 Claude 的真实 `content_block_delta` 流式输出。
- 使用 `codex exec --json` / `codex exec resume --json` 运行 Codex 任务，并在 Raw 视图保留 Codex JSONL 事件。
- 主窗口显示结构化的 `System / You / Agent` 对话气泡，避免 TUI spinner、控制字符和 JSON 流污染回答。
- 提供 Raw 视图查看原始输出，方便排查 Claude CLI、Codex CLI 或 JSON stream 问题。
- 中间工作区支持 `对话 / Raw / 文件` 标签页切换，聊天输入框固定在对话窗口底部，聊天历史保持固定高度并支持鼠标滚动查看上下文。
- 左侧项目区提供文件夹树，点击文件夹可展开，点击单文件会在中间工作区打开文本编辑器标签页。
- 发送任务时显示运行状态，例如等待首字、正在生成、工具调用、完成。
- 支持浅色/深色主题切换，界面采用浅色优先、半透明面板和系统控件风格。
- 右侧 Git 面板会自动识别当前项目仓库，显示分支、提交、ahead/behind、变更文件、diff 和可点击的 SVG Git graph 分支图。
- Git 面板支持单文件或全部 `stage / unstage`、填写提交信息后 `commit`，以及 `fetch / pull --ff-only / push`。
- 文件编辑器支持轻量代码高亮、保存当前文件，保存后右侧 Git 状态会刷新。
- 同一工作目录已有 running 房间时，再次启动会切换到已有房间，避免误触重复创建。
