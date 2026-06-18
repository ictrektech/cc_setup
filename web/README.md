# Agent Room

一个本地 Web 控制台，用来启动和管理当前机器上的 Claude agent 会话。它兼容 cc-switch 方案和 cc-haha 方案，默认优先使用 `claude`，找不到时回退到 `claude-haha`。

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
# 或
CLAUDE_HAHA_BIN=/Users/you/cc-haha/bin/claude-haha bash dev.sh
```

## 当前功能

- 选择工作目录并启动 Claude agent。
- 可输入初始任务，也可以启动后继续发送消息。
- 每个会话独立运行在 Python PTY 里，输出通过 WebSocket 实时同步到页面。
- 可以并行开多个会话，在侧边栏切换。
- 可以停止当前会话。
