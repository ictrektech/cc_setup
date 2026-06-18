# Agent Room

一个本地 Web 控制台，用来启动和管理当前机器上的 Claude agent 会话。Web app 只使用 `claude` 命令。

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

如果你的命令不在 PATH 里，可以指定：

```bash
CLAUDE_BIN=/Users/you/.local/bin/claude bash dev.sh
```

## 当前功能

- 选择工作目录并启动 Claude agent。
- 可输入初始任务，也可以启动后继续发送消息。
- 使用 `claude -p --verbose --output-format stream-json --include-partial-messages` 运行任务。
- 主对话窗口基于 Claude 的 `content_block_delta` 做真实流式输出。
- 回答区按 `System / You / Claude` 气泡显示，避免 TUI 控制符、spinner 和 Raw JSON 干扰阅读。
- 顶部显示会话统计和运行状态，任务过程中会提示等待首字、生成中、完成。
- Raw 标签保留原始输出，方便调试底层 Claude CLI 行为。
- 支持浅色/深色主题切换。
- 可以并行开多个会话，在房间卡片中切换；同一目录已有 running 会话时会直接切换过去。
- 可以停止当前会话。
