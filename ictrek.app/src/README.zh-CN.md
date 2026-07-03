# Agent Room

Claude / Codex AI Agent 远程管理控制台。

## 功能

- 通过 Web 浏览器创建 Claude / Codex Agent 会话
- 实时终端输出（WebSocket）
- 会话持久化，重启后恢复
- 简易认证（Token）
- Git 仓库状态查看
- 文件浏览与编辑
- 与 VOS 平台集成，通过侧边栏导航访问

## 使用

1. 安装后在 VOS 平台侧边栏找到 **Agent Room**
2. 首次打开需要输入访问 Token（安装时设置，或在容器内查看）
3. 在控制台页面创建新房间，选择 Agent 类型和项目目录
4. 输入任务指令启动 Agent

## Token 管理

安装时可设置固定 Token，也可以留空让系统自动生成。自动生成的 Token 持久化在 storage 中：

```bash
# 在宿主机查看自动生成的 Token
cat ${VOS_APP_STORAGE_PATH}/config/token
```

## 环境变量

| 变量 | 说明 |
|:---|:---|
| `ANTHROPIC_API_KEY` | Claude API Key |
| `ANTHROPIC_BASE_URL` | API 端点地址 |
| `ANTHROPIC_MODEL` | 默认模型 |
| `AGENT_ROOM_TOKEN` | Web 登录 Token |
| `AGENT_ROOM_PORT` | 服务端口 |
