# cc_setup

Claude / RTK / skills / digital-workers 的一键安装脚本集合。

## Claude 环境安装

### macOS / Linux

```bash
wget -P /tmp -N --no-check-certificate "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh" && chmod 700 /tmp/cc_setup_unix.sh && /tmp/cc_setup_unix.sh
```

如果 GitHub 直连失败，使用 ghfast：

```bash
wget -P /tmp -N --no-check-certificate "https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh" && chmod 700 /tmp/cc_setup_unix.sh && /tmp/cc_setup_unix.sh
```

fish shell 可以执行：

```fish
bash -lc 'wget -P /tmp -N --no-check-certificate "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_unix.sh" && chmod 700 /tmp/cc_setup_unix.sh && /tmp/cc_setup_unix.sh'
```

### Windows

在 PowerShell 中执行：

```powershell
$script = Join-Path $env:TEMP "cc_setup_win.ps1"
$url = "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_win.ps1"
$fastUrl = "https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_setup_win.ps1"
try { Invoke-WebRequest -Uri $url -OutFile $script -UseBasicParsing } catch { Invoke-WebRequest -Uri $fastUrl -OutFile $script -UseBasicParsing }
powershell -NoProfile -ExecutionPolicy Bypass -File $script
```

安装完成后重新打开终端，常用命令：

```bash
claude --help
claude-haha --help
claude -p "hello"
claude-env
claude-update
claude-uninstall
```

Windows 下使用：

```powershell
claude
claude-env
claude-update
claude-uninstall
```

## digital-workers / skills 安装

安装并更新 digital-workers，同时重新安装仓库里的 skills 到 `~/.claude/skills`：

```bash
wget -P /tmp -N --no-check-certificate "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh" && chmod 700 /tmp/dworkers_setup.sh && /tmp/dworkers_setup.sh
```

如果 GitHub 直连失败，使用 ghfast：

```bash
wget -P /tmp -N --no-check-certificate "https://ghfast.top/https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh" && chmod 700 /tmp/dworkers_setup.sh && /tmp/dworkers_setup.sh
```

指定项目目录：

```bash
wget -P /tmp -N --no-check-certificate "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh" && chmod 700 /tmp/dworkers_setup.sh && /tmp/dworkers_setup.sh ~/projects/demo
```

如果 Claude 命令不在 PATH 中，可以指定：

```bash
wget -P /tmp -N --no-check-certificate "https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh" && chmod 700 /tmp/dworkers_setup.sh && CLAUDE_BIN=claude-haha /tmp/dworkers_setup.sh
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

## 脚本说明

- `cc_setup_unix.sh`: macOS / Linux 安装 Claude 环境、RTK，并写入 `claude`、`claude-env`、`claude-update`、`claude-uninstall`。
- `cc_setup_win.ps1`: Windows PowerShell 安装 Claude 环境、RTK，并写入对应命令。
- `dworkers_setup.sh`: 克隆/更新 `ictrektech/digital-workers`，重装 skills，生成 `.env` 和示例任务。
- `digital_workers_setup.sh`: 兼容入口，本地执行时转到 `dworkers_setup.sh`，远程执行时拉取 `dworkers_setup.sh`。
