#!/usr/bin/env bash
set -Eeuo pipefail

CC_SWITCH_INSTALL_URL="https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh"
CC_SWITCH_INSTALL_URL_FAST="https://ghfast.top/${CC_SWITCH_INSTALL_URL}"
GHFAST_PREFIX="${GHFAST_PREFIX:-https://ghfast.top/}"
GHFAST_PREFIX="${GHFAST_PREFIX%/}/"

PROVIDER_ID="ictrek"
PROVIDER_NAME="ICTrek"
API_BASE_URL="https://ai.ictrek.com"
API_KEY="dummy-keys"
HAIKU_MODEL="volces/DeepSeek-V4-Flash"
DEFAULT_MODEL="volces/GLM-5.1"

OS_TYPE="linux"
if [ "$(uname -s)" = "Darwin" ]; then
  OS_TYPE="macos"
fi

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download_nonempty() {
  local primary="$1"
  local fallback="$2"
  local output="$3"

  rm -f "$output"

  if curl -LfsS --connect-timeout 10 --max-time 120 "$primary" -o "$output" && [ -s "$output" ]; then
    return 0
  fi

  warn "主地址下载失败或为空，尝试备用地址：$fallback"
  rm -f "$output"

  if curl -LfsS --connect-timeout 10 --max-time 120 "$fallback" -o "$output" && [ -s "$output" ]; then
    return 0
  fi

  return 1
}

rewrite_github_urls_to_ghfast() {
  local file="$1"

  GHFAST_PREFIX="$GHFAST_PREFIX" python3 - "$file" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
prefix = os.environ["GHFAST_PREFIX"]
content = path.read_text(encoding="utf-8")

for url in ("https://github.com", "https://api.github.com", "https://raw.githubusercontent.com"):
    content = content.replace(url, prefix + url)

path.write_text(content, encoding="utf-8")
PY
}

install_with_apt() {
  if ! need_cmd apt; then
    err "当前系统没有 apt，请手动安装：$*"
    exit 1
  fi

  warn "将通过 apt 安装：$*。接下来可能需要你输入 sudo 密码授权。"
  sudo apt update
  sudo apt install -y "$@"
}

install_with_brew() {
  if ! need_cmd brew; then
    err "当前 macOS 未检测到 brew。请先安装 Homebrew 后重试：https://brew.sh"
    exit 1
  fi

  brew install "$@"
}

install_basic_tools_if_needed() {
  local missing=()
  local cmd

  for cmd in curl python3; do
    if ! need_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    local brew_packages=()
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        curl) brew_packages+=("curl") ;;
        python3) brew_packages+=("python") ;;
      esac
    done
    install_with_brew "${brew_packages[@]}"
  else
    local apt_packages=()
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        curl) apt_packages+=("curl") ;;
        python3) apt_packages+=("python3") ;;
      esac
    done
    install_with_apt "${apt_packages[@]}"
  fi
}

install_npm_if_needed() {
  if need_cmd npm; then
    log "npm 已存在：$(npm --version)"
    return 0
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    warn "未检测到 npm，将通过 Homebrew 安装 node。"
    install_with_brew node
  else
    warn "未检测到 npm，将通过 apt 安装 nodejs/npm。"
    install_with_apt nodejs npm
  fi

  if ! need_cmd npm; then
    err "npm 安装后仍不可用，请检查 Node.js/npm 安装状态。"
    exit 1
  fi

  log "npm 安装完成：$(npm --version)"
}

claude_path_looks_like_cc_haha() {
  local claude_path="${1:-}"
  local resolved="$claude_path"

  if [ -n "$claude_path" ] && need_cmd readlink; then
    resolved="$(readlink "$claude_path" 2>/dev/null || printf '%s' "$claude_path")"
  fi

  case "$claude_path:$resolved" in
    *cc-haha*|*claude-haha*) return 0 ;;
  esac

  return 1
}

has_official_claude_code() {
  local claude_path="${1:-}"

  [ -n "$claude_path" ] || return 1
  claude_path_looks_like_cc_haha "$claude_path" && return 1

  if need_cmd npm && npm list -g @anthropic-ai/claude-code --depth=0 >/dev/null 2>&1; then
    return 0
  fi

  if "$claude_path" --version 2>/dev/null | grep -qiE 'claude code|anthropic'; then
    return 0
  fi

  case "$claude_path" in
    */node_modules/@anthropic-ai/claude-code/*|*/.npm-global/bin/claude|*/npm/bin/claude)
      return 0
      ;;
  esac

  return 1
}

uninstall_cc_haha_if_needed() {
  local claude_path
  claude_path="$(command -v claude 2>/dev/null || true)"

  if [ -z "$claude_path" ]; then
    return 0
  fi

  if has_official_claude_code "$claude_path"; then
    log "检测到官方 Claude Code：${claude_path}，跳过 claude-code 安装。"
    return 0
  fi

  if claude_path_looks_like_cc_haha "$claude_path"; then
    log "检测到 cc-haha Claude：${claude_path}，执行 claude-uninstall。"
    if need_cmd claude-uninstall; then
      claude-uninstall
      hash -r 2>/dev/null || true
    else
      err "检测到 cc-haha，但未找到 claude-uninstall。请先卸载 cc-haha 后重试。"
      exit 1
    fi
    return 0
  fi

  warn "检测到未知来源 claude：${claude_path}，将继续安装官方 Claude Code。"
}

install_claude_code_if_needed() {
  local claude_path
  claude_path="$(command -v claude 2>/dev/null || true)"

  if has_official_claude_code "$claude_path"; then
    log "官方 Claude Code 已存在，跳过安装。"
    return 0
  fi

  log "安装官方 Claude Code：npm install -g @anthropic-ai/claude-code"
  if ! npm install -g @anthropic-ai/claude-code; then
    warn "普通 npm 全局安装失败，尝试 sudo npm install -g。"
    sudo npm install -g @anthropic-ai/claude-code
  fi

  hash -r 2>/dev/null || true

  if ! need_cmd claude; then
    err "Claude Code 安装后未找到 claude 命令，请检查 npm global bin 是否在 PATH 中。"
    exit 1
  fi

  log "Claude Code 安装完成：$(command -v claude)"
}

install_cc_switch_if_needed() {
  export PATH="$HOME/.local/bin:$PATH"

  if need_cmd cc-switch; then
    log "cc-switch 已存在：$(command -v cc-switch)"
    return 0
  fi

  log "安装 cc-switch-cli。"

  local tmp
  tmp="$(mktemp)"
  if ! download_nonempty "$CC_SWITCH_INSTALL_URL" "$CC_SWITCH_INSTALL_URL_FAST" "$tmp"; then
    rm -f "$tmp"
    err "cc-switch-cli install.sh 下载失败。"
    exit 1
  fi

  if ! CC_SWITCH_FORCE=1 bash "$tmp"; then
    warn "cc-switch-cli 直连 GitHub 安装失败，改用 ghfast.top 加速后重试。"
    rewrite_github_urls_to_ghfast "$tmp"
    CC_SWITCH_FORCE=1 bash "$tmp"
  fi
  rm -f "$tmp"

  export PATH="$HOME/.local/bin:$PATH"

  if [ "$OS_TYPE" = "macos" ] && need_cmd xattr && [ -x "$HOME/.local/bin/cc-switch" ]; then
    xattr -cr "$HOME/.local/bin/cc-switch" 2>/dev/null || true
  fi

  if ! need_cmd cc-switch; then
    err "cc-switch 安装后仍不可用，请检查 ~/.local/bin 是否在 PATH 中。"
    exit 1
  fi

  log "cc-switch 安装完成：$(command -v cc-switch)"
}

init_cc_switch_if_needed() {
  log "初始化 cc-switch 配置。"
  cc-switch --app claude provider list >/dev/null 2>&1 || true
}

configure_cc_switch_provider() {
  log "写入 cc-switch Claude provider：${PROVIDER_NAME}。"

  PROVIDER_ID="$PROVIDER_ID" \
  PROVIDER_NAME="$PROVIDER_NAME" \
  API_BASE_URL="$API_BASE_URL" \
  API_KEY="$API_KEY" \
  HAIKU_MODEL="$HAIKU_MODEL" \
  DEFAULT_MODEL="$DEFAULT_MODEL" \
  python3 - <<'PY'
import json
import os
import sqlite3
import time
from pathlib import Path

home = Path.home()
config_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or home / ".cc-switch")
db_path = config_dir / "cc-switch.db"

if not db_path.exists():
    raise SystemExit(f"cc-switch 数据库不存在：{db_path}")

provider_id = os.environ["PROVIDER_ID"]
provider_name = os.environ["PROVIDER_NAME"]
api_base_url = os.environ["API_BASE_URL"]
api_key = os.environ["API_KEY"]
haiku_model = os.environ["HAIKU_MODEL"]
default_model = os.environ["DEFAULT_MODEL"]
now_ms = int(time.time() * 1000)

settings_config = {
    "env": {
        "ANTHROPIC_API_KEY": api_key,
        "ANTHROPIC_BASE_URL": api_base_url,
        "ANTHROPIC_MODEL": default_model,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": haiku_model,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": default_model,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": default_model,
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    },
    "includeCoAuthoredBy": False,
}

meta = {
    "apiKeyField": "ANTHROPIC_API_KEY",
    "apiFormat": "anthropic",
}

with sqlite3.connect(db_path) as conn:
    existing = conn.execute(
        "SELECT created_at, sort_index, is_current, in_failover_queue FROM providers WHERE id = ? AND app_type = 'claude'",
        (provider_id,),
    ).fetchone()

    if existing:
        created_at, sort_index, is_current, in_failover_queue = existing
    else:
        created_at = now_ms
        row = conn.execute("SELECT MAX(sort_index) FROM providers WHERE app_type = 'claude'").fetchone()
        sort_index = 0 if row is None or row[0] is None else int(row[0]) + 1
        is_current = 0
        in_failover_queue = 0

    conn.execute(
        """
        INSERT INTO providers (
          id, app_type, name, settings_config, website_url, category,
          created_at, sort_index, notes, icon, icon_color, meta,
          is_current, in_failover_queue
        )
        VALUES (?, 'claude', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id, app_type) DO UPDATE SET
          name = excluded.name,
          settings_config = excluded.settings_config,
          website_url = excluded.website_url,
          category = excluded.category,
          created_at = excluded.created_at,
          sort_index = excluded.sort_index,
          notes = excluded.notes,
          icon = excluded.icon,
          icon_color = excluded.icon_color,
          meta = excluded.meta,
          in_failover_queue = excluded.in_failover_queue
        """,
        (
            provider_id,
            provider_name,
            json.dumps(settings_config, ensure_ascii=False, separators=(",", ":")),
            api_base_url,
            "custom",
            created_at,
            sort_index,
            "Installed by cc_switch_setup.sh",
            "zap",
            "#0F62FE",
            json.dumps(meta, ensure_ascii=False, separators=(",", ":")),
            is_current,
            in_failover_queue,
        ),
    )
    conn.commit()

print(db_path)
PY

  log "切换 cc-switch provider 并同步 Claude settings。"
  cc-switch --app claude provider switch "$PROVIDER_ID"
}

setup_claude_first_run_state() {
  log "关闭 Claude Code 首次打开登录/引导验证。"

  python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path.home()

claude_json = home / ".claude.json"
data = {}
if claude_json.exists():
    try:
        data = json.loads(claude_json.read_text(encoding="utf-8"))
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
data.update({
    "hasCompletedOnboarding": True,
    "hasAcceptedTerms": True,
    "hasSeenIdeIntegrationNudge": True,
    "hasCompletedProjectOnboarding": True,
    "disableAllTelemetry": True,
})
claude_json.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

settings_path = home / ".claude" / "settings.json"
settings_path.parent.mkdir(parents=True, exist_ok=True)
settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception:
        settings = {}
if not isinstance(settings, dict):
    settings = {}
env = settings.get("env")
if not isinstance(env, dict):
    env = {}
env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
settings["env"] = env
settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print(claude_json)
print(settings_path)
PY
}

main() {
  install_basic_tools_if_needed
  install_npm_if_needed
  uninstall_cc_haha_if_needed
  install_claude_code_if_needed
  install_cc_switch_if_needed
  init_cc_switch_if_needed
  configure_cc_switch_provider
  setup_claude_first_run_state

  log "完成。重新打开终端后可执行：claude"
  log "cc-switch provider：$PROVIDER_ID -> $API_BASE_URL"
}

main "$@"
