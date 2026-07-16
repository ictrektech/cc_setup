# cc_setup

Claude / Codex / RTK / skills / digital-workers 的一键安装脚本集合。

`ictrek.app/` 是后续 VOS 应用定义、打包脚本和安装说明的入口目录；当前先保留说明和生成产物忽略规则。

## Agent Room VOS 镜像

VOS app 使用 `agent-room` 镜像。构建脚本会推送镜像并把 tag 写入飞书发布表：

```bash
./docker/build_images.sh amd
./docker/build_images.sh arm
```

- `amd` 默认写入 `AMD_with_cuda`、`AMD_with_mxn100`
- `arm` 默认写入 `l4t`、`ARM_without_cuda`、`ARM_with_cuda`、`SOPHON_bm1688`

脚本只查找精确表头 `agent-room`。表头不存在时只新增一列并写入表头/仓库地址，不会反复扩出空列。

## Claude / Codex 环境安装

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

### ~~方案二：cc-haha（macOS / Linux）~~

> 已停止维护。新安装请使用方案一：cc-switch + 官方 Claude Code / Codex。

~~这个方案安装 `NanmiCoder/cc-haha`，并写入 `claude`、`claude-haha`、`claude-env`、`claude-update`、`claude-uninstall`。~~

~~安装、配置、更新、卸载命令不再维护。~~

~~旧安装已存在时，可以继续自行使用 `claude-env`、`claude-update`、`claude-uninstall`。~~

### ~~Windows（cc-haha）~~

> 已停止维护。Windows 旧安装方式不再推荐。

~~PowerShell 安装、配置、更新、卸载命令不再维护。~~

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

仓库里提供了一个独立的 Agent Room Web Server，可启动和管理当前机器上的 Claude / Codex agent 会话，并提供 Git 工作区、文件树和文本编辑器。

![Agent Room Web 控制台](docs/images/agent-room.jpg)

完整部署说明、配置项、界面功能介绍和使用教程见：[web/README.md](web/README.md)。

主要能力：

- token 登录和右上角登出。
- Claude / Codex agent 房间管理、流式对话和 Raw 输出查看。
- 项目文件树、新建文件、拖拽移动文件、代码编辑和保存。
- Git 状态、diff、SVG git graph、stage、commit、fetch、pull、push。
- 浅色/深色主题和远端部署配置。

## 脚本说明

- `cc_switch_setup.sh`: macOS / Linux 安装官方 Claude Code、Codex、chat-codex 和 cc-switch-cli，按 `--agent claude|codex|both` 配置 ICTrek provider，并写入 `claude-update`、`codex-update`、`claude-uninstall`、`codex-uninstall`。
- `cc_setup_unix.sh`: macOS / Linux 安装 Claude 环境、RTK，并写入 `claude`、`claude-env`、`claude-update`、`claude-uninstall`。
- `cc_setup_win.ps1`: Windows PowerShell 安装 Claude 环境、RTK，并写入对应命令。
- `dworkers_setup.sh`: 克隆/更新 `ictrektech/digital-workers`，重装 skills，生成 `.env` 和示例任务。
- `digital_workers_setup.sh`: 兼容入口，本地执行时转到 `dworkers_setup.sh`，远程执行时拉取 `dworkers_setup.sh`。
- `web/`: Agent Room Web 控制台，支持 `claude` / `codex` 命令，提供项目目录选择、会话启动、实时输出、多会话切换、Git 工作区管理和项目文件编辑。
