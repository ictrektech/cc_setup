#!/usr/bin/env bash
set -Eeuo pipefail

CC_SWITCH_INSTALL_URL="https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh"
CC_SWITCH_INSTALL_URL_FAST="https://ghfast.top/${CC_SWITCH_INSTALL_URL}"
SELF_SCRIPT_URL="https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh"
SELF_SCRIPT_URL_FAST="https://ghfast.top/${SELF_SCRIPT_URL}"
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

upsert_shell_block() {
  local file="$1"
  local content="$2"
  local begin="# >>> cc-switch setup >>>"
  local end="# <<< cc-switch setup <<<"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  python3 - "$file" "$begin" "$end" "$content" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin, end, content = sys.argv[2], sys.argv[3], sys.argv[4]
old = path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""
while begin in old and end in old:
    start = old.index(begin)
    finish = old.index(end, start) + len(end)
    old = old[:start].rstrip() + "\n" + old[finish:].lstrip()
new = old.rstrip() + "\n\n" + begin + "\n" + content.rstrip() + "\n" + end + "\n"
path.write_text(new, encoding="utf-8")
PY
}

ensure_local_bin_in_path() {
  local sh_content='export PATH="$HOME/.local/bin:$PATH"'
  local fish_content='fish_add_path "$HOME/.local/bin"'

  upsert_shell_block "$HOME/.bashrc" "$sh_content"
  upsert_shell_block "$HOME/.zshrc" "$sh_content"
  upsert_shell_block "$HOME/.zprofile" "$sh_content"
  upsert_shell_block "$HOME/.config/fish/config.fish" "$fish_content"
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

write_management_scripts() {
  local bin_dir="$HOME/.local/bin"
  local update_script="$bin_dir/claude-update"
  local uninstall_script="$bin_dir/claude-uninstall"

  mkdir -p "$bin_dir"

  cat > "$update_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SELF_SCRIPT_URL="https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh"
SELF_SCRIPT_URL_FAST="https://ghfast.top/${SELF_SCRIPT_URL}"

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

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

main() {
  local tmp
  tmp="$(mktemp)"

  log "拉取最新版 cc_switch_setup.sh 并重新执行安装/配置。"
  if ! download_nonempty "$SELF_SCRIPT_URL" "$SELF_SCRIPT_URL_FAST" "$tmp"; then
    rm -f "$tmp"
    err "cc_switch_setup.sh 下载失败。"
    exit 1
  fi

  bash "$tmp" "$@"
  rm -f "$tmp"
}

main "$@"
EOF

  cat > "$uninstall_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_ID="ictrek"
API_BASE_URL="https://ai.ictrek.com"
API_KEY="dummy-keys"
HAIKU_MODEL="volces/DeepSeek-V4-Flash"
DEFAULT_MODEL="volces/GLM-5.1"

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

remove_shell_block() {
  local file="$1"
  local begin="# >>> cc-switch setup >>>"
  local end="# <<< cc-switch setup <<<"

  [ -f "$file" ] || return 0

  python3 - "$file" "$begin" "$end" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin, end = sys.argv[2], sys.argv[3]
old = path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""
while begin in old and end in old:
    start = old.index(begin)
    finish = old.index(end, start) + len(end)
    old = old[:start].rstrip() + "\n" + old[finish:].lstrip()
path.write_text(old, encoding="utf-8")
PY
}

remove_ictrek_provider() {
  PROVIDER_ID="$PROVIDER_ID" python3 - <<'PY'
import os
import sqlite3
from pathlib import Path

config_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or Path.home() / ".cc-switch")
db_path = config_dir / "cc-switch.db"
if not db_path.exists():
    raise SystemExit(0)

provider_id = os.environ["PROVIDER_ID"]
with sqlite3.connect(db_path) as conn:
    current = conn.execute(
        "SELECT is_current FROM providers WHERE id = ? AND app_type = 'claude'",
        (provider_id,),
    ).fetchone()
    conn.execute("DELETE FROM providers WHERE id = ? AND app_type = 'claude'", (provider_id,))
    if current and current[0]:
        conn.execute("UPDATE providers SET is_current = 0 WHERE app_type = 'claude'")
    conn.commit()

print(db_path)
PY
}

clean_claude_settings() {
  API_BASE_URL="$API_BASE_URL" \
  API_KEY="$API_KEY" \
  HAIKU_MODEL="$HAIKU_MODEL" \
  DEFAULT_MODEL="$DEFAULT_MODEL" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

settings_path = Path.home() / ".claude" / "settings.json"
if not settings_path.exists():
    raise SystemExit(0)

try:
    data = json.loads(settings_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

if not isinstance(data, dict):
    raise SystemExit(0)

env = data.get("env")
if isinstance(env, dict):
    expected = {
        "ANTHROPIC_API_KEY": os.environ["API_KEY"],
        "ANTHROPIC_BASE_URL": os.environ["API_BASE_URL"],
        "ANTHROPIC_MODEL": os.environ["DEFAULT_MODEL"],
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ["HAIKU_MODEL"],
        "ANTHROPIC_DEFAULT_SONNET_MODEL": os.environ["DEFAULT_MODEL"],
        "ANTHROPIC_DEFAULT_OPUS_MODEL": os.environ["DEFAULT_MODEL"],
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }
    for key, value in expected.items():
        if env.get(key) == value:
            env.pop(key, None)
    if env:
        data["env"] = env
    else:
        data.pop("env", None)

settings_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(settings_path)
PY
}

disable_proxy_takeover() {
  if need_cmd cc-switch; then
    cc-switch --app claude proxy disable || warn "cc-switch CLI 关闭代理接管失败，使用数据库配置兜底。"
  fi

  python3 - <<'PY'
import os
import sqlite3
from pathlib import Path

config_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or Path.home() / ".cc-switch")
db_path = config_dir / "cc-switch.db"
if not db_path.exists():
    raise SystemExit(0)

with sqlite3.connect(db_path) as conn:
    conn.execute(
        "UPDATE proxy_config SET enabled = 0, auto_failover_enabled = 0, updated_at = datetime('now') WHERE app_type = 'claude'"
    )
    other_enabled = conn.execute(
        "SELECT COUNT(*) FROM proxy_config WHERE app_type != 'claude' AND enabled = 1"
    ).fetchone()[0]
    if other_enabled == 0:
        conn.execute("UPDATE proxy_config SET proxy_enabled = 0, updated_at = datetime('now')")
    conn.commit()

print(db_path)
PY
}

disable_claude_plugin_integration() {
  python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path.home()
cc_switch_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or home / ".cc-switch")
settings_path = cc_switch_dir / "settings.json"
claude_config_dir = home / ".claude"

if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception:
        settings = {}
    if isinstance(settings, dict):
        claude_config_dir = Path(settings.get("claudeConfigDir") or claude_config_dir)
        settings["enableClaudePluginIntegration"] = False
        settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(settings_path)

plugin_config_path = claude_config_dir / "config.json"
if not plugin_config_path.exists():
    raise SystemExit(0)

try:
    plugin_config = json.loads(plugin_config_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

if not isinstance(plugin_config, dict):
    raise SystemExit(0)

if plugin_config.get("primaryApiKey") == "any":
    plugin_config.pop("primaryApiKey", None)
    plugin_config_path.write_text(json.dumps(plugin_config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(plugin_config_path)
PY
}

uninstall_claude_code() {
  if ! need_cmd npm; then
    warn "未检测到 npm，跳过官方 Claude Code npm 包卸载。"
    return 0
  fi

  if npm list -g @anthropic-ai/claude-code --depth=0 >/dev/null 2>&1; then
    log "卸载官方 Claude Code npm 包。"
    npm uninstall -g @anthropic-ai/claude-code || sudo npm uninstall -g @anthropic-ai/claude-code
  else
    warn "未检测到全局 @anthropic-ai/claude-code，跳过 npm 卸载。"
  fi
}

main() {
  disable_proxy_takeover || warn "关闭 cc-switch 代理接管失败，继续清理其它项目。"
  disable_claude_plugin_integration || warn "关闭 VS Code Claude 插件接管失败，继续清理其它项目。"
  remove_ictrek_provider || warn "移除 cc-switch provider 失败，继续清理其它项目。"
  clean_claude_settings || warn "清理 Claude settings 失败，继续清理其它项目。"
  uninstall_claude_code || warn "卸载官方 Claude Code 失败。"

  remove_shell_block "$HOME/.bashrc"
  remove_shell_block "$HOME/.zshrc"
  remove_shell_block "$HOME/.zprofile"
  remove_shell_block "$HOME/.config/fish/config.fish"

  rm -f "$HOME/.local/bin/claude-update" "$HOME/.local/bin/claude-uninstall"

  log "已卸载 cc-switch Claude 方案。"
  warn "未删除 cc-switch 本体和 ~/.cc-switch 其它配置，避免影响你已有的 provider。"
  warn "如当前 shell 缓存了命令，请执行：hash -r 2>/dev/null || true；fish 请重新打开终端。"
}

main "$@"
EOF

  chmod +x "$update_script" "$uninstall_script"
  log "claude-update 命令已写入：$update_script"
  log "claude-uninstall 命令已写入：$uninstall_script"
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

enable_proxy_flags_direct() {
  log "写入 cc-switch 代理接管开关兜底配置。"

  python3 - <<'PY'
import os
import sqlite3
from pathlib import Path

config_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or Path.home() / ".cc-switch")
db_path = config_dir / "cc-switch.db"
if not db_path.exists():
    raise SystemExit(f"cc-switch 数据库不存在：{db_path}")

with sqlite3.connect(db_path) as conn:
    conn.execute("INSERT OR IGNORE INTO proxy_config (app_type) VALUES ('claude')")
    conn.execute(
        "UPDATE proxy_config SET proxy_enabled = 1, enabled = 1, updated_at = datetime('now') WHERE app_type = 'claude'"
    )
    conn.commit()

print(db_path)
PY
}

configure_claude_plugin_integration() {
  log "打开 VS Code Claude 插件接管。"

  python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path.home()
cc_switch_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or home / ".cc-switch")
cc_switch_dir.mkdir(parents=True, exist_ok=True)
settings_path = cc_switch_dir / "settings.json"

settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception:
        settings = {}
if not isinstance(settings, dict):
    settings = {}
settings["enableClaudePluginIntegration"] = True
settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

claude_config_dir = Path(settings.get("claudeConfigDir") or home / ".claude")
claude_config_dir.mkdir(parents=True, exist_ok=True)
plugin_config_path = claude_config_dir / "config.json"
plugin_config = {}
if plugin_config_path.exists():
    try:
        plugin_config = json.loads(plugin_config_path.read_text(encoding="utf-8"))
    except Exception:
        plugin_config = {}
if not isinstance(plugin_config, dict):
    plugin_config = {}
plugin_config["primaryApiKey"] = "any"
plugin_config_path.write_text(json.dumps(plugin_config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print(settings_path)
print(plugin_config_path)
PY
}

enable_cc_switch_proxy_and_plugin() {
  log "打开 cc-switch Claude 代理接管。"
  if ! cc-switch --app claude proxy enable; then
    warn "cc-switch CLI 打开代理接管失败，使用数据库配置兜底。"
    enable_proxy_flags_direct
  fi

  configure_claude_plugin_integration
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
  ensure_local_bin_in_path
  uninstall_cc_haha_if_needed
  install_claude_code_if_needed
  install_cc_switch_if_needed
  init_cc_switch_if_needed
  configure_cc_switch_provider
  enable_cc_switch_proxy_and_plugin
  setup_claude_first_run_state
  write_management_scripts

  log "完成。重新打开终端后可执行：claude"
  log "管理命令：claude-update / claude-uninstall"
  log "cc-switch provider：$PROVIDER_ID -> $API_BASE_URL"
}

main "$@"
