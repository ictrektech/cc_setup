#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/NanmiCoder/cc-haha"
REPO_URL_FAST="https://ghfast.top/https://github.com/NanmiCoder/cc-haha"

ENV_URL="https://gist.githubusercontent.com/huluxiaohuowa/804df4c68c28c0841150801e170d2449/raw/gistfile1.txt"
ENV_URL_FAST="https://ghfast.top/https://gist.githubusercontent.com/huluxiaohuowa/804df4c68c28c0841150801e170d2449/raw/gistfile1.txt"

GHFAST_PREFIX="${GHFAST_PREFIX:-https://ghfast.top/}"
GHFAST_PREFIX="${GHFAST_PREFIX%/}/"
RTK_INSTALL_URLS=(
  "https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh"
  "https://raw.githubusercontent.com/rtk-ai/rtk/main/install.sh"
)
RTK_BIN_DIR="$HOME/.local/bin"

DEFAULT_DIR="$HOME/cc-haha"

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

sed_delete_inplace() {
  local expr="$1"
  local file="$2"

  if [ "$OS_TYPE" = "macos" ]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

sed_replace_inplace() {
  local expr="$1"
  local file="$2"

  if [ "$OS_TYPE" = "macos" ]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

download_nonempty() {
  local primary="$1"
  local fallback="$2"
  local output="$3"

  rm -f "$output"

  if curl -LfsS --connect-timeout 10 --max-time 60 "$primary" -o "$output" && [ -s "$output" ]; then
    return 0
  fi

  warn "主地址下载失败或为空，尝试备用地址：$fallback"
  rm -f "$output"

  if curl -LfsS --connect-timeout 10 --max-time 60 "$fallback" -o "$output" && [ -s "$output" ]; then
    return 0
  fi

  return 1
}

download_rtk_install() {
  local output="$1"
  local url

  for url in "${RTK_INSTALL_URLS[@]}"; do
    if download_nonempty "$url" "${GHFAST_PREFIX}${url}" "$output"; then
      return 0
    fi
    warn "RTK install.sh 下载失败，尝试下一个分支。"
  done

  return 1
}

upsert_shell_block() {
  local file="$1"
  local content="$2"
  local begin="# >>> cc-haha setup >>>"
  local end="# <<< cc-haha setup <<<"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  python3 - "$file" "$begin" "$end" "$content" <<'PY'
import sys, os
path, begin, end, content = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
old = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        old = f.read()
while begin in old and end in old:
    s = old.index(begin)
    e = old.index(end, s) + len(end)
    old = old[:s].rstrip() + "\n" + old[e:].lstrip()
new = old.rstrip() + "\n\n" + begin + "\n" + content.rstrip() + "\n" + end + "\n"
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PY
}

remove_old_claude_aliases() {
  local file

  for file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
    [ -f "$file" ] || continue
    cp "$file" "$file.bak.$(date +%Y%m%d_%H%M%S)"
    sed_delete_inplace '/^[[:space:]]*alias[[:space:]]\+claude=/d' "$file"
  done

  local fish_config="$HOME/.config/fish/config.fish"
  if [ -f "$fish_config" ]; then
    cp "$fish_config" "$fish_config.bak.$(date +%Y%m%d_%H%M%S)"
    sed_delete_inplace '/^[[:space:]]*alias[[:space:]]\+claude[[:space:]]/d' "$fish_config"
  fi
}

sync_claude_command() {
  local target="$1"
  local src="$target/bin/claude-haha"
  local dst="$target/bin/claude"

  if [ ! -x "$src" ]; then
    err "claude-haha 不存在或不可执行：$src"
    exit 1
  fi

  cp -f "$src" "$dst"
  chmod +x "$dst"

  log "已同步真实 claude 命令：$dst"
}

setup_claude_json() {
  log "修复 ~/.claude.json。"

  python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude.json")
data = {}
if os.path.exists(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
data["hasCompletedOnboarding"] = True
data["hasAcceptedTerms"] = True
data["hasSeenIdeIntegrationNudge"] = True
data["hasCompletedProjectOnboarding"] = True
data["disableAllTelemetry"] = True
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(p)
PY
}

setup_claude_settings_json() {
  log "修复 ~/.claude/settings.json：CLAUDE_CODE_ATTRIBUTION_HEADERS=0。"

  python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.exists(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
env = data.get("env")
if not isinstance(env, dict):
    env = {}
env["CLAUDE_CODE_ATTRIBUTION_HEADERS"] = "0"
data["env"] = env
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(p)
PY
}

repair_claude_configs() {
  setup_claude_json
  setup_claude_settings_json
}

ensure_rtk() {
  mkdir -p "$RTK_BIN_DIR"
  export PATH="$RTK_BIN_DIR:$PATH"

  local ok=0
  if command -v rtk >/dev/null 2>&1 && rtk --version >/dev/null 2>&1; then
    ok=1
  fi

  if [ "$ok" -ne 1 ]; then
    log "安装/修复 RTK 到：$RTK_BIN_DIR"
    local tmp
    tmp="$(mktemp)"
    if ! download_rtk_install "$tmp"; then
      rm -f "$tmp"
      err "RTK install.sh 下载失败。"
      exit 1
    fi
    sed_replace_inplace "s#https://github.com#${GHFAST_PREFIX}https://github.com#g" "$tmp"
    sed_replace_inplace "s#https://raw.githubusercontent.com#${GHFAST_PREFIX}https://raw.githubusercontent.com#g" "$tmp"
    RTK_INSTALL_DIR="$RTK_BIN_DIR" RTK_BIN_DIR="$RTK_BIN_DIR" bash "$tmp" || true
    rm -f "$tmp"
  fi

  if ! command -v rtk >/dev/null 2>&1; then
    err "RTK 安装后仍不可用，请检查 $RTK_BIN_DIR 是否在 PATH 中。"
    exit 1
  fi

  if ! rtk --version >/dev/null 2>&1; then
    err "rtk --version 执行失败，重新安装后仍不可用。"
    exit 1
  fi

  rtk --version || true
  printf 'y\n' | rtk init -g || warn "rtk init -g 执行失败，但 rtk 已安装。"
}


install_basic_tools_if_needed() {
  local missing=()

  for cmd in git curl; do
    if ! need_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    warn "缺少基础工具：${missing[*]}。macOS 将尝试使用 Homebrew 安装。"

    if ! need_cmd brew; then
      err "当前 macOS 未检测到 brew。请先安装 Homebrew 后重试：https://brew.sh"
      exit 1
    fi

    for cmd in "${missing[@]}"; do
      case "$cmd" in
        git) brew install git ;;
        curl) brew install curl ;;
      esac
    done

    return 0
  fi

  warn "缺少基础工具：${missing[*]}，将通过 apt 安装。"
  warn "接下来可能需要你输入 sudo 密码授权。"

  if ! need_cmd apt; then
    err "当前系统没有 apt，请手动安装：${missing[*]}"
    exit 1
  fi

  sudo apt update
  sudo apt install -y "${missing[@]}"
}

install_python_if_needed() {
  if need_cmd python3; then
    log "python3 已存在：$(python3 --version)"
    return 0
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    warn "macOS 未检测到 python3，将尝试使用 Homebrew 安装 python。"

    if ! need_cmd brew; then
      err "当前 macOS 未检测到 brew。请先安装 Homebrew 后重试：https://brew.sh"
      exit 1
    fi

    brew install python
    return 0
  fi

  warn "系统未检测到 python3，将执行 sudo apt install python3 python3-pip"
  warn "接下来可能需要你输入 sudo 密码授权。"

  if ! need_cmd apt; then
    err "当前系统没有 apt，请手动安装 python3/python3-pip 后重试。"
    exit 1
  fi

  sudo apt update
  sudo apt install -y python3 python3-pip
}

install_bun_if_needed() {
  if need_cmd bun; then
    log "bun 已存在：$(bun --version)"
    return 0
  fi

  log "未检测到 bun，开始安装 bun..."

  local bun_install_script
  bun_install_script="$(mktemp)"

  curl -fsSL https://bun.sh/install -o "$bun_install_script"

  sed_replace_inplace 's#https://github.com#https://ghfast.top/https://github.com#g' "$bun_install_script"

  bash "$bun_install_script"

  rm -f "$bun_install_script"

  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"

  if ! need_cmd bun; then
    err "bun 安装后仍不可用，请重新打开终端，或检查 ~/.bun/bin 是否在 PATH 中。"
    exit 1
  fi

  log "bun 安装完成：$(bun --version)"
}

configure_bun_mirror() {
  log "配置 bun npm registry 加速：npmmirror"

  local bunfig="$HOME/.bunfig.toml"
  touch "$bunfig"

  if ! grep -q 'registry = "https://registry.npmmirror.com"' "$bunfig"; then
    cat >> "$bunfig" <<'EOF'
[install]
registry = "https://registry.npmmirror.com"
EOF
  fi
}

clone_or_update_repo() {
  local target="$1"

  if [ -d "$target/.git" ]; then
    log "目标目录已存在，执行 git pull：$target"
    git -C "$target" pull --ff-only || warn "git pull 失败，继续使用现有目录。"
    return 0
  fi

  if [ -e "$target" ]; then
    err "目标路径已存在但不是 git 仓库：$target"
    exit 1
  fi

  log "开始拉取 cc-haha 到：$target"

  if git clone "$REPO_URL" "$target"; then
    return 0
  fi

  warn "GitHub 直连失败，尝试 ghfast：$REPO_URL_FAST"
  git clone "$REPO_URL_FAST" "$target"
}

replace_env_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"

  log "下载 .env 配置文件..."

  if ! download_nonempty "$ENV_URL" "$ENV_URL_FAST" "$tmp"; then
    rm -f "$tmp"
    err ".env 下载失败，主地址和备用地址都不可用。"
    exit 1
  fi

  if [ -f "$target/.env" ]; then
    cp "$target/.env" "$target/.env.bak.$(date +%Y%m%d_%H%M%S)"
    warn "原 .env 已备份。"
  fi

  mv "$tmp" "$target/.env"
  chmod 600 "$target/.env"
  log ".env 已替换：$target/.env"
}

install_deps() {
  local target="$1"

  log "执行 bun install..."
  cd "$target"

  if [ -f "package.json" ]; then
    bun install
  else
    err "未找到 package.json，目录可能不是 cc-haha 仓库。"
    exit 1
  fi

  chmod +x "$target/bin/claude-haha" 2>/dev/null || true
  sync_claude_command "$target"
}

write_claude_env_script() {
  local target="$1"
  local bin_path="$target/bin"
  local script="$bin_path/claude-env"

  mkdir -p "$bin_path"

  cat > "$script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
env_file="$(cd "$bin_dir/.." && pwd -P)/.env"
if [ ! -f "$env_file" ]; then
  echo "[ERR] .env 不存在：$env_file" >&2
  exit 1
fi

if command -v code >/dev/null 2>&1; then
  exec code "$env_file"
fi

exec vi "$env_file"
EOF

  chmod +x "$script"
  log "claude-env 命令已写入：$script"
}

write_claude_uninstall_script() {
  local target="$1"
  local bin_path="$target/bin"
  local uninstall_script="$bin_path/claude-uninstall"

  mkdir -p "$bin_path"

  local q_target
  printf -v q_target '%q' "$target"

  cat > "$uninstall_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
TARGET_DIR=$q_target
EOF

  cat >> "$uninstall_script" <<'EOF'
log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

remove_block_from_file() {
  local file="$1"
  local begin="# >>> cc-haha setup >>>"
  local end="# <<< cc-haha setup <<<"

  [ -f "$file" ] || return 0

  python3 - "$file" "$begin" "$end" <<'PY'
import sys, os
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(path):
    raise SystemExit(0)
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    old = f.read()
while begin in old and end in old:
    s = old.index(begin)
    e = old.index(end, s) + len(end)
    old = old[:s].rstrip() + "\n" + old[e:].lstrip()
with open(path, "w", encoding="utf-8") as f:
    f.write(old)
PY
}

main() {
  if [ -z "${TARGET_DIR:-}" ] || [ "$TARGET_DIR" = "/" ] || [ "$TARGET_DIR" = "$HOME" ]; then
    echo "[ERR] TARGET_DIR 异常，拒绝卸载：$TARGET_DIR" >&2
    exit 1
  fi

  cd "$HOME"

  remove_block_from_file "$HOME/.bashrc"
  remove_block_from_file "$HOME/.zshrc"
  remove_block_from_file "$HOME/.zprofile"
  remove_block_from_file "$HOME/.config/fish/config.fish"

  rm -rf "$TARGET_DIR"

  log "已卸载 cc-haha：$TARGET_DIR"
  warn "如当前 shell 缓存了命令，请执行：hash -r 2>/dev/null || true；fish 请重新打开终端。"
}

main "$@"
EOF

  chmod +x "$uninstall_script"
  log "claude-uninstall 命令已写入：$uninstall_script"
}

write_claude_update_script() {
  local target="$1"
  local bin_path="$target/bin"
  local update_script="$bin_path/claude-update"

  mkdir -p "$bin_path"

  local q_repo q_repo_fast q_target q_os
  printf -v q_repo '%q' "$REPO_URL"
  printf -v q_repo_fast '%q' "$REPO_URL_FAST"
  printf -v q_target '%q' "$target"
  printf -v q_os '%q' "$OS_TYPE"

  cat > "$update_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL=$q_repo
REPO_URL_FAST=$q_repo_fast
TARGET_DIR=$q_target
OS_TYPE=$q_os
GHFAST_PREFIX="${GHFAST_PREFIX:-https://ghfast.top/}"
GHFAST_PREFIX="${GHFAST_PREFIX%/}/"
RTK_INSTALL_URLS=(
  "https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh"
  "https://raw.githubusercontent.com/rtk-ai/rtk/main/install.sh"
)
RTK_BIN_DIR="$HOME/.local/bin"
EOF

  cat >> "$update_script" <<'EOF'
log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sed_delete_inplace() {
  local expr="$1"
  local file="$2"
  if [ "$OS_TYPE" = "macos" ]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

sed_replace_inplace() {
  local expr="$1"
  local file="$2"
  if [ "$OS_TYPE" = "macos" ]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

download_nonempty() {
  local primary="$1"
  local fallback="$2"
  local output="$3"
  rm -f "$output"
  if curl -LfsS --connect-timeout 10 --max-time 60 "$primary" -o "$output" && [ -s "$output" ]; then
    return 0
  fi
  warn "主地址下载失败或为空，尝试备用地址：$fallback"
  rm -f "$output"
  if curl -LfsS --connect-timeout 10 --max-time 60 "$fallback" -o "$output" && [ -s "$output" ]; then
    return 0
  fi
  return 1
}

download_rtk_install() {
  local output="$1"
  local url
  for url in "${RTK_INSTALL_URLS[@]}"; do
    if download_nonempty "$url" "${GHFAST_PREFIX}${url}" "$output"; then
      return 0
    fi
    warn "RTK install.sh 下载失败，尝试下一个分支。"
  done
  return 1
}

upsert_shell_block() {
  local file="$1"
  local content="$2"
  local begin="# >>> cc-haha setup >>>"
  local end="# <<< cc-haha setup <<<"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  python3 - "$file" "$begin" "$end" "$content" <<'PY'
import sys, os
path, begin, end, content = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
old = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        old = f.read()
while begin in old and end in old:
    s = old.index(begin)
    e = old.index(end, s) + len(end)
    old = old[:s].rstrip() + "\n" + old[e:].lstrip()
new = old.rstrip() + "\n\n" + begin + "\n" + content.rstrip() + "\n" + end + "\n"
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PY
}

remove_old_claude_aliases() {
  local file
  for file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
    [ -f "$file" ] || continue
    cp "$file" "$file.bak.$(date +%Y%m%d_%H%M%S)"
    sed_delete_inplace '/^[[:space:]]*alias[[:space:]]\+claude=/d' "$file"
  done
  local fish_config="$HOME/.config/fish/config.fish"
  if [ -f "$fish_config" ]; then
    cp "$fish_config" "$fish_config.bak.$(date +%Y%m%d_%H%M%S)"
    sed_delete_inplace '/^[[:space:]]*alias[[:space:]]\+claude[[:space:]]/d' "$fish_config"
  fi
}

sync_claude_command() {
  local src="$TARGET_DIR/bin/claude-haha"
  local dst="$TARGET_DIR/bin/claude"
  if [ ! -x "$src" ]; then
    err "claude-haha 不存在或不可执行：$src"
    exit 1
  fi
  cp -f "$src" "$dst"
  chmod +x "$dst"
  log "已同步真实 claude 命令：$dst"
}

setup_claude_json() {
  log "修复 ~/.claude.json。"
  python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude.json")
data = {}
if os.path.exists(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
data["hasCompletedOnboarding"] = True
data["hasAcceptedTerms"] = True
data["hasSeenIdeIntegrationNudge"] = True
data["hasCompletedProjectOnboarding"] = True
data["disableAllTelemetry"] = True
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(p)
PY
}

setup_claude_settings_json() {
  log "修复 ~/.claude/settings.json：CLAUDE_CODE_ATTRIBUTION_HEADERS=0。"
  python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.exists(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
env = data.get("env")
if not isinstance(env, dict):
    env = {}
env["CLAUDE_CODE_ATTRIBUTION_HEADERS"] = "0"
data["env"] = env
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(p)
PY
}

repair_claude_configs() {
  setup_claude_json
  setup_claude_settings_json
}

ensure_rtk() {
  mkdir -p "$RTK_BIN_DIR"
  export PATH="$RTK_BIN_DIR:$PATH"

  local ok=0
  if command -v rtk >/dev/null 2>&1 && rtk --version >/dev/null 2>&1; then
    ok=1
  fi

  if [ "$ok" -ne 1 ]; then
    log "安装/修复 RTK 到：$RTK_BIN_DIR"
    local tmp
    tmp="$(mktemp)"
    if ! download_rtk_install "$tmp"; then
      rm -f "$tmp"
      err "RTK install.sh 下载失败。"
      exit 1
    fi
    sed_replace_inplace "s#https://github.com#${GHFAST_PREFIX}https://github.com#g" "$tmp"
    sed_replace_inplace "s#https://raw.githubusercontent.com#${GHFAST_PREFIX}https://raw.githubusercontent.com#g" "$tmp"
    RTK_INSTALL_DIR="$RTK_BIN_DIR" RTK_BIN_DIR="$RTK_BIN_DIR" bash "$tmp" || true
    rm -f "$tmp"
  fi

  if ! command -v rtk >/dev/null 2>&1; then
    err "RTK 安装后仍不可用，请检查 $RTK_BIN_DIR 是否在 PATH 中。"
    exit 1
  fi

  if ! rtk --version >/dev/null 2>&1; then
    err "rtk --version 执行失败，重新安装后仍不可用。"
    exit 1
  fi

  rtk --version || true
  printf 'y\n' | rtk init -g || warn "rtk init -g 执行失败，但 rtk 已安装。"
}

write_claude_env_script() {
  local bin_path="$TARGET_DIR/bin"
  local script="$bin_path/claude-env"
  mkdir -p "$bin_path"
  cat > "$script" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
env_file="$(cd "$bin_dir/.." && pwd -P)/.env"
if [ ! -f "$env_file" ]; then
  echo "[ERR] .env 不存在：$env_file" >&2
  exit 1
fi
if command -v code >/dev/null 2>&1; then
  exec code "$env_file"
fi
exec vi "$env_file"
EOS
  chmod +x "$script"
}

write_claude_uninstall_script() {
  local bin_path="$TARGET_DIR/bin"
  local uninstall_script="$bin_path/claude-uninstall"
  mkdir -p "$bin_path"
  cat > "$uninstall_script" <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
TARGET_DIR='$TARGET_DIR'
EOS
  cat >> "$uninstall_script" <<'EOS'
remove_block_from_file() {
  local file="$1"
  local begin="# >>> cc-haha setup >>>"
  local end="# <<< cc-haha setup <<<"
  [ -f "$file" ] || return 0
  python3 - "$file" "$begin" "$end" <<'PY'
import sys, os
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(path):
    raise SystemExit(0)
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    old = f.read()
while begin in old and end in old:
    s = old.index(begin)
    e = old.index(end, s) + len(end)
    old = old[:s].rstrip() + "\n" + old[e:].lstrip()
with open(path, "w", encoding="utf-8") as f:
    f.write(old)
PY
}
main() {
  if [ -z "${TARGET_DIR:-}" ] || [ "$TARGET_DIR" = "/" ] || [ "$TARGET_DIR" = "$HOME" ]; then
    echo "[ERR] TARGET_DIR 异常，拒绝卸载：$TARGET_DIR" >&2
    exit 1
  fi
  cd "$HOME"
  remove_block_from_file "$HOME/.bashrc"
  remove_block_from_file "$HOME/.zshrc"
  remove_block_from_file "$HOME/.zprofile"
  remove_block_from_file "$HOME/.config/fish/config.fish"
  rm -rf "$TARGET_DIR"
  echo "[INFO] 已卸载 cc-haha：$TARGET_DIR"
}
main "$@"
EOS
  chmod +x "$uninstall_script"
}

restore_shell_config() {
  local bin_path="$TARGET_DIR/bin"
  local bash_zsh_content='export PATH="'"$bin_path"':$PATH"
export PATH="'"$RTK_BIN_DIR"':$PATH"
# claude / claude-haha / claude-env / claude-update / claude-uninstall 都是 bin 目录里的真实命令，不再依赖 alias'
  local fish_content='fish_add_path "'"$bin_path"'"
fish_add_path "'"$RTK_BIN_DIR"'"
# claude / claude-haha / claude-env / claude-update / claude-uninstall 都是 bin 目录里的真实命令，不再依赖 alias'

  upsert_shell_block "$HOME/.bashrc" "$bash_zsh_content"

  if [ -f "$HOME/.zshrc" ] || [[ "${SHELL:-}" == *"/zsh" ]] || [ "$OS_TYPE" = "macos" ]; then
    upsert_shell_block "$HOME/.zshrc" "$bash_zsh_content"
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    upsert_shell_block "$HOME/.zprofile" "$bash_zsh_content"
  fi

  if [ -d "$HOME/.config/fish" ] || [[ "${SHELL:-}" == *"/fish" ]]; then
    upsert_shell_block "$HOME/.config/fish/config.fish" "$fish_content"
  fi

  remove_old_claude_aliases
}

main() {
  if ! need_cmd git || ! need_cmd curl; then
    err "缺少 git 或 curl，请先安装。"
    exit 1
  fi
  if ! need_cmd bun; then
    err "缺少 bun，请先运行安装脚本安装 bun。"
    exit 1
  fi
  if ! need_cmd python3; then
    err "缺少 python3，请先安装 python3。"
    exit 1
  fi
  if [ -z "$TARGET_DIR" ] || [ "$TARGET_DIR" = "/" ] || [ "$TARGET_DIR" = "$HOME" ]; then
    err "TARGET_DIR 异常，拒绝继续：$TARGET_DIR"
    exit 1
  fi
  if [ ! -d "$TARGET_DIR/.git" ]; then
    err "目标目录不是 git 仓库：$TARGET_DIR"
    exit 1
  fi
  log "更新仓库：$TARGET_DIR"
  cd "$TARGET_DIR"
  git fetch --all
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    git reset --hard origin/main
  elif git rev-parse --verify origin/master >/dev/null 2>&1; then
    git reset --hard origin/master
  else
    git pull --ff-only
  fi
  if [ -f "$TARGET_DIR/.env" ]; then
    log "保留原 .env：$TARGET_DIR/.env"
    chmod 600 "$TARGET_DIR/.env" || true
  else
    warn "未找到 .env；claude-update 不会重新下载 .env。"
  fi
  log "重新执行 bun install..."
  bun install
  chmod +x "$TARGET_DIR/bin/claude-haha" 2>/dev/null || true
  sync_claude_command
  repair_claude_configs
  ensure_rtk
  write_claude_env_script
  write_claude_uninstall_script
  restore_shell_config
  log "更新完成。重新打开终端后 claude / claude-haha / claude-env / claude-update / claude-uninstall 应正常可用。"
}
main "$@"
EOF

  chmod +x "$update_script"
  log "claude-update 命令已写入：$update_script"
}

configure_shell_path() {
  local target="$1"
  local bin_path="$target/bin"

  local bash_zsh_content='export PATH="'"$bin_path"':$PATH"
export PATH="'"$RTK_BIN_DIR"':$PATH"
# claude / claude-haha / claude-env / claude-update / claude-uninstall 都是 bin 目录里的真实命令，不再依赖 alias'

  local fish_content='fish_add_path "'"$bin_path"'"
fish_add_path "'"$RTK_BIN_DIR"'"
# claude / claude-haha / claude-env / claude-update / claude-uninstall 都是 bin 目录里的真实命令，不再依赖 alias'

  log "当前默认 shell：${SHELL:-unknown}"
  log "当前进程 shell：$(ps -p $$ -o comm= 2>/dev/null || echo unknown)"

  upsert_shell_block "$HOME/.bashrc" "$bash_zsh_content"

  if [ -f "$HOME/.zshrc" ] || [[ "${SHELL:-}" == *"/zsh" ]] || [ "$OS_TYPE" = "macos" ]; then
    upsert_shell_block "$HOME/.zshrc" "$bash_zsh_content"
  fi

  if [ "$OS_TYPE" = "macos" ]; then
    upsert_shell_block "$HOME/.zprofile" "$bash_zsh_content"
  fi

  if [ -d "$HOME/.config/fish" ] || [[ "${SHELL:-}" == *"/fish" ]]; then
    upsert_shell_block "$HOME/.config/fish/config.fish" "$fish_content"
  fi

  remove_old_claude_aliases

  log "PATH、claude 真实命令、claude-env 命令、claude-update 命令、claude-uninstall 命令已写入/修复。"
}

main() {
  echo "请输入 cc-haha 创建位置，直接回车默认：$DEFAULT_DIR"
  read -r -p "> " INSTALL_DIR

  INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
  INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

  log "系统类型：$OS_TYPE"
  log "安装目录：$INSTALL_DIR"

  install_basic_tools_if_needed
  install_python_if_needed
  install_bun_if_needed
  configure_bun_mirror

  clone_or_update_repo "$INSTALL_DIR"
  replace_env_file "$INSTALL_DIR"
  install_deps "$INSTALL_DIR"
  repair_claude_configs
  ensure_rtk
  write_claude_env_script "$INSTALL_DIR"
  write_claude_update_script "$INSTALL_DIR"
  write_claude_uninstall_script "$INSTALL_DIR"
  configure_shell_path "$INSTALL_DIR"

  echo ""
  log "安装完成。"
  echo ""
  echo "当前终端立即生效："
  echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\""
  echo "  unalias claude 2>/dev/null || true"
  echo "  hash -r 2>/dev/null || true"
  echo ""
  echo "测试："
  echo "  claude --help"
  echo "  claude-haha --help"
  echo "  claude -p \"hello\""
  echo "  claude-env"
  echo "  claude-update"
  echo "  claude-uninstall"
  echo ""
  if [ "$OS_TYPE" = "macos" ]; then
    warn "macOS 默认 shell 多为 zsh。请重新打开终端，或执行：source ~/.zshrc"
  fi
  warn "如果当前 shell 是 fish，请重新打开终端，或执行：source ~/.config/fish/config.fish"
  warn "如果当前 shell 是 bash，请执行：source ~/.bashrc"
  warn "如果当前 shell 是 zsh，请执行：source ~/.zshrc"
}

main "$@"
