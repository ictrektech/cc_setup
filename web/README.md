# Agent Room

一个本地 Web 控制台，用来启动和管理当前机器上的 Claude / Codex agent 会话。

![Agent Room Web 控制台](../docs/images/agent-room.jpg)

## 启动

```bash
cd web
bash dev.sh
```

打开：

```text
http://localhost:3766
```

首次打开需要输入访问 token。启动服务的 Linux 用户可以在任意目录运行：

```bash
cat ~/.agentroom/token
```

也可以用服务脚本查询：

```bash
python3 /path/to/agentroom/server.py token
```

如果你的命令不在 PATH 里，可以指定：

```bash
CLAUDE_BIN=/Users/you/.local/bin/claude CODEX_BIN=/Users/you/.local/bin/codex bash dev.sh
```

## 当前功能

- 选择工作目录和 agent 类型，并启动 Claude 或 Codex agent。
- 默认启用 token 登录；只有能读取启动用户 `~/.agentroom/token` 的用户才能进入 Web 控制台。
- 可输入初始任务，也可以启动后继续发送消息。
- 使用 `claude -p --verbose --output-format stream-json --include-partial-messages` 运行任务。
- 使用 `codex exec --json` 和 `codex exec resume --json` 运行 Codex 任务。
- 主对话窗口基于 Claude 的 `content_block_delta` 做真实流式输出。
- 回答区按 `System / You / Agent` 气泡显示，避免 TUI 控制符、spinner 和 Raw JSON 干扰阅读。
- 顶部显示会话统计和运行状态，任务过程中会提示等待首字、生成中、完成。
- Raw 标签保留原始输出，方便调试底层 Claude / Codex CLI 行为。
- 支持浅色/深色主题切换。
- 可以并行开多个会话，在房间卡片中切换；同一目录已有 running 会话时会直接切换过去。
- 可以停止当前会话。
