#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/ictrektech/digital-workers.git"
REPO_FAST_URL="https://ghfast.top/https://github.com/ictrektech/digital-workers.git"
REPO_DIR_NAME="digital-workers"

log() {
  echo "[INFO] $*" >&2
}

warn() {
  echo "[WARN] $*" >&2
}

err() {
  echo "[ERR] $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'HELP'
Usage:
  bash setup-digital-workers.sh [PROJECT_DIR]

Examples:
  bash setup-digital-workers.sh
  bash setup-digital-workers.sh /home/jzy/my_project
  bash setup-digital-workers.sh ~/projects/demo

说明：
  - 如果传入 PROJECT_DIR，直接使用该目录。
  - 如果不传 PROJECT_DIR，会交互式询问项目目录。
  - 直接回车则自动创建：
      /home/<username>/project_<YYYYmmdd_HHMMSS>
  - 脚本会进入该目录，并克隆/更新：
      https://github.com/ictrektech/digital-workers.git
  - 如果 GitHub 原始地址拉取失败，会自动尝试：
      https://ghfast.top/https://github.com/ictrektech/digital-workers.git
  - 每次运行都会重新安装 skills：
      先删除 ~/.claude/skills 下同名 skill，再复制仓库里的最新版本。
HELP
}

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      err "缺少命令：$cmd。$hint"
    else
      err "缺少命令：$cmd"
    fi
  fi
}

expand_path() {
  local p="$1"

  if [[ "$p" == "~" ]]; then
    echo "$HOME"
  elif [[ "$p" == "~/"* ]]; then
    echo "$HOME/${p#"~/"}"
  else
    echo "$p"
  fi
}

check_python_version() {
  require_cmd python3 "请先安装 Python 3.10+。"

  local version
  version="$(python3 - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)"

  local major minor
  major="${version%%.*}"
  minor="${version#*.}"

  if (( major < 3 || (major == 3 && minor < 10) )); then
    err "Python 版本过低：$version。digital-workers 需要 Python 3.10+。"
  fi

  log "Python 版本检查通过：$version"
}

detect_claude_command() {
  if [[ -n "${CLAUDE_BIN:-}" ]]; then
    echo "$CLAUDE_BIN"
    return 0
  fi

  if command -v claude >/dev/null 2>&1; then
    echo "claude"
    return 0
  fi

  if bash -ic 'type claude >/dev/null 2>&1' >/dev/null 2>&1; then
    echo "claude"
    return 0
  fi

  return 1
}

check_claude() {
  local detected

  if detected="$(detect_claude_command)"; then
    DETECTED_CLAUDE_BIN="$detected"
    export DETECTED_CLAUDE_BIN
    log "检测到 Claude 命令：$DETECTED_CLAUDE_BIN"
    return 0
  fi

  warn "未检测到 claude 命令。"
  warn "请确认 claude 在 PATH 中："
  warn "  command -v claude"
  warn "也可以这样运行："
  warn "  CLAUDE_BIN=/path/to/claude bash setup-digital-workers.sh"

  DETECTED_CLAUDE_BIN="claude"
  export DETECTED_CLAUDE_BIN
}

resolve_project_dir() {
  if [[ $# -gt 1 ]]; then
    usage
    err "参数过多。最多只能传一个 PROJECT_DIR。"
  fi

  local username
  username="$(id -un)"

  local ts
  ts="$(date '+%Y%m%d_%H%M%S')"

  local default_dir="/home/${username}/project_${ts}"

  if [[ $# -eq 1 ]]; then
    expand_path "$1"
    return 0
  fi

  echo >&2
  echo "请输入要创建/使用的项目目录。" >&2
  echo "直接回车使用默认目录：$default_dir" >&2
  echo >&2

  local input_dir
  read -r -p "项目目录 > " input_dir

  if [[ -z "$input_dir" ]]; then
    echo "$default_dir"
  else
    expand_path "$input_dir"
  fi
}

clone_or_update_repo() {
  local project_dir="$1"
  local repo_dir="$project_dir/$REPO_DIR_NAME"

  if [[ -d "$repo_dir/.git" ]]; then
    log "检测到已有仓库，执行更新：$repo_dir"

    local origin_url
    origin_url="$(git -C "$repo_dir" remote get-url origin || true)"

    if git -C "$repo_dir" fetch --all --prune >&2 && git -C "$repo_dir" pull --ff-only >&2; then
      log "仓库更新完成"
    else
      warn "原始 remote 更新失败，尝试切换到 ghfast 加速地址"

      git -C "$repo_dir" remote set-url origin "$REPO_FAST_URL"

      if git -C "$repo_dir" fetch --all --prune >&2 && git -C "$repo_dir" pull --ff-only >&2; then
        log "通过 ghfast 加速地址更新完成"
      else
        if [[ -n "$origin_url" ]]; then
          git -C "$repo_dir" remote set-url origin "$origin_url" || true
        fi
        err "仓库更新失败：原始地址和 ghfast 加速地址都不可用"
      fi
    fi

    git -C "$repo_dir" remote set-url origin "$REPO_URL" || true

  elif [[ -e "$repo_dir" ]]; then
    err "目标路径已存在但不是 git 仓库：$repo_dir"

  else
    log "克隆仓库：$REPO_URL"

    if git clone "$REPO_URL" "$repo_dir" >&2; then
      log "仓库克隆完成"
    else
      warn "原始 GitHub 地址克隆失败，尝试 ghfast 加速地址：$REPO_FAST_URL"

      rm -rf "$repo_dir"

      if git clone "$REPO_FAST_URL" "$repo_dir" >&2; then
        log "通过 ghfast 加速地址克隆完成"
        git -C "$repo_dir" remote set-url origin "$REPO_URL" || true
      else
        rm -rf "$repo_dir"
        err "仓库克隆失败：原始地址和 ghfast 加速地址都不可用"
      fi
    fi
  fi

  echo "$repo_dir"
}

reinstall_skills() {
  local repo_dir="$1"
  local skill_source="$repo_dir/skills"
  local skill_root="${SKILL_ROOT:-$HOME/.claude/skills}"

  if [[ ! -d "$skill_source" ]]; then
    err "skill 源目录不存在：$skill_source"
  fi

  mkdir -p "$skill_root"

  local installed=0

  log "开始重新安装 skills"
  log "skill 源目录：$skill_source"
  log "skill 目标目录：$skill_root"

  for skill_dir in "$skill_source"/*; do
    [[ -d "$skill_dir" ]] || continue
    [[ -f "$skill_dir/SKILL.md" ]] || continue

    local name
    name="$(basename "$skill_dir")"

    rm -rf "$skill_root/$name"
    mkdir -p "$skill_root/$name"

    cp -a "$skill_dir/." "$skill_root/$name/"

    echo "reinstalled: $name"
    installed=$((installed + 1))
  done

  log "skills 重新安装完成：$installed 个"
}

write_env_file() {
  local project_dir="$1"
  local repo_dir="$2"
  local env_file="$project_dir/.env"

  cat > "$env_file" <<EOF_ENV
# digital-workers local environment

CLAUDE_BIN=$DETECTED_CLAUDE_BIN
DIGITAL_WORKERS_HOME=$repo_dir
SKILL_ROOT=$HOME/.claude/skills
EOF_ENV

  log "已写入环境文件：$env_file"
}

create_example_task() {
  local project_dir="$1"
  local repo_dir="$2"

  local runs_dir="$project_dir/runs"
  local task_dir="$runs_dir/example-health-api"
  local request_file="$task_dir/00_request.md"

  mkdir -p "$task_dir"

  cat > "$request_file" <<'EOF_REQ'
给现有的 FastAPI 服务加一个 /health 接口。

要求：
1. 返回服务状态、版本号、当前时间
2. 响应格式为 JSON
3. 不影响已有接口
4. 给出 curl 测试命令
EOF_REQ

  log "已写入示例任务：$request_file"

  cat > "$project_dir/run-example-full.sh" <<EOF_RUN
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
DIGITAL_WORKERS_HOME="$repo_dir"

export CLAUDE_BIN="\${CLAUDE_BIN:-$DETECTED_CLAUDE_BIN}"

cd "\$DIGITAL_WORKERS_HOME"

python3 -m digital_worker.runner full \\
  "$task_dir" \\
  "\$PROJECT_DIR"
EOF_RUN

  chmod +x "$project_dir/run-example-full.sh"

  log "已写入示例运行脚本：$project_dir/run-example-full.sh"
}

print_summary() {
  local project_dir="$1"
  local repo_dir="$2"

  cat <<EOF_SUMMARY

============================================================
digital-workers 配置完成
============================================================

项目目录：
  $project_dir

digital-workers 仓库：
  $repo_dir

Claude 命令：
  $DETECTED_CLAUDE_BIN

skills 安装目录：
  ${SKILL_ROOT:-$HOME/.claude/skills}

环境文件：
  $project_dir/.env

示例任务：
  $project_dir/runs/example-health-api/00_request.md

运行示例 pipeline：

  cd "$project_dir"
  ./run-example-full.sh

手动运行：

  cd "$repo_dir"
  CLAUDE_BIN=$DETECTED_CLAUDE_BIN python3 -m digital_worker.runner full \\
    "$project_dir/runs/example-health-api" \\
    "$project_dir"

============================================================
EOF_SUMMARY
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd git "请先安装 git。"
  check_python_version
  check_claude

  local project_dir
  project_dir="$(resolve_project_dir "$@")"

  mkdir -p "$project_dir"
  project_dir="$(cd "$project_dir" && pwd)"

  log "进入项目目录：$project_dir"
  cd "$project_dir"

  local repo_dir
  repo_dir="$(clone_or_update_repo "$project_dir")"

  reinstall_skills "$repo_dir"
  write_env_file "$project_dir" "$repo_dir"
  create_example_task "$project_dir" "$repo_dir"

  print_summary "$project_dir" "$repo_dir"
}

main "$@"
