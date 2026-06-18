# cc_setup

Claude / RTK / skills / digital-workers 的一键安装脚本集合。

## Claude 环境安装

这里提供两种互斥方案。推荐新机器优先使用 cc-switch 方案；如果已经在使用 cc-haha，可以继续使用 cc-haha 方案，或者运行 cc-switch 方案自动卸载 cc-haha 后切换。

### 方案一：cc-switch + 官方 Claude Code（macOS / Linux）

这个方案安装官方 `@anthropic-ai/claude-code`，安装 [saladday/cc-switch-cli](https://github.com/saladday/cc-switch-cli)，并自动配置 ICTrek provider。

安装：

```bash
bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

fish shell 可以执行：

```fish
bash -lc 'bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)'
```

以上的安装过程会写入如下配置内容：

```text
API 地址: https://ai.ictrek.com
API Key: dummy-keys（占位，安装后请改成自己的 key）
Haiku 模型: volces/DeepSeek-V4-Flash
Sonnet/Opus/默认模型: volces/GLM-5.1
Provider ID: ictrek
```

**十分建议**安装时直接写入自己的 API Key：

```bash
CC_SWITCH_API_KEY="你的 API Key" bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

如果还希望方案一自动安装并初始化 RTK：

```bash
CC_SWITCH_API_KEY="你的 API Key" CC_SWITCH_INSTALL_RTK=1 bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh)
```

`CC_SWITCH_INSTALL_RTK=1` 会安装/修复 `rtk` 到 `~/.local/bin`，并自动执行 `rtk init -g`。RTK 是可选项，如果安装或初始化失败，脚本会继续完成 Claude 和 cc-switch 配置。

已经安装过后，可以用一条命令把 `dummy-keys` 改成自己的 key：

```bash
CC_SWITCH_API_KEY="你的 API Key" claude-update
```

如果当前终端还没重新加载 PATH，可以执行：

```bash
CC_SWITCH_API_KEY="你的 API Key" ~/.local/bin/claude-update
```

这条命令会重新写入 cc-switch 的 `ictrek` provider，并同步 Claude 配置。

脚本还会打开 Claude 代理接管和 VS Code Claude 插件接管，并关闭 Claude Code 首次打开登录/引导验证。

查看配置：

```bash
cc-switch --app claude provider current
cc-switch --app claude proxy show
claude --help
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

卸载会移除 `ictrek` provider、关闭 Claude 代理接管、关闭 VS Code Claude 插件接管、卸载官方 Claude Code npm 包，并删除本方案写入的 `claude-update` / `claude-uninstall`。它不会删除 cc-switch 本体和 `~/.cc-switch` 里的其它 provider。

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
CLAUDE_BIN=claude-haha bash <(curl -LfsS https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh || curl -LfsS https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh)
```

安装完成后，脚本会输出项目目录，并生成示例任务。进入项目目录运行：

```bash
./run-example-full.sh
```

也可以手动运行：

```bash
cd <digital-workers 仓库目录>
CLAUDE_BIN=claude-haha python3 -m digital_worker.runner full \
  "<项目目录>/runs/example-health-api" \
  "<项目目录>"
```

## Agent Room Web 控制台

仓库里提供了一个本地 Web 控制台，可启动和管理当前机器上的 Claude agent 会话。它兼容 cc-switch 方案和 cc-haha 方案，会优先使用 `claude` 命令，找不到时回退到 `claude-haha`。

```bash
cd web
bash dev.sh
```

默认端口：

```text
http://localhost:3766
```

在远端机器上运行后，可以直接打开：

```text
http://<远端 IP>:3766
```

## 脚本说明

- `cc_switch_setup.sh`: macOS / Linux 安装官方 Claude Code 和 cc-switch-cli，配置 ICTrek provider，打开 Claude 代理接管和 VS Code Claude 插件接管，并写入 `claude-update`、`claude-uninstall`。
- `cc_setup_unix.sh`: macOS / Linux 安装 Claude 环境、RTK，并写入 `claude`、`claude-env`、`claude-update`、`claude-uninstall`。
- `cc_setup_win.ps1`: Windows PowerShell 安装 Claude 环境、RTK，并写入对应命令。
- `dworkers_setup.sh`: 克隆/更新 `ictrektech/digital-workers`，重装 skills，生成 `.env` 和示例任务。
- `digital_workers_setup.sh`: 兼容入口，本地执行时转到 `dworkers_setup.sh`，远程执行时拉取 `dworkers_setup.sh`。
- `web/`: Agent Room Web 控制台，兼容 `claude` 和 `claude-haha`，提供项目目录选择、会话启动、实时终端输出和多会话切换。
