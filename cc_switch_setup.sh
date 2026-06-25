#!/usr/bin/env bash
set -Eeuo pipefail

CC_SWITCH_INSTALL_URL="https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh"
CC_SWITCH_INSTALL_URL_FAST="https://ghfast.top/${CC_SWITCH_INSTALL_URL}"
SELF_SCRIPT_URL="https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/cc_switch_setup.sh"
SELF_SCRIPT_URL_FAST="https://ghfast.top/${SELF_SCRIPT_URL}"
GHFAST_PREFIX="${GHFAST_PREFIX:-https://ghfast.top/}"
GHFAST_PREFIX="${GHFAST_PREFIX%/}/"
RTK_INSTALL_URLS=(
  "https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh"
  "https://raw.githubusercontent.com/rtk-ai/rtk/main/install.sh"
)
RTK_BIN_DIR="$HOME/.local/bin"

PROVIDER_ID="ictrek"
PROVIDER_NAME="ICTrek"
API_BASE_URL="https://ai.ictrek.com"
API_KEY="${CC_SWITCH_API_KEY:-${API_KEY:-dummy-keys}}"
HAIKU_MODEL="volces/DeepSeek-V4-Flash"
DEFAULT_MODEL="volces/GLM-5.1"
INSTALL_RTK="${CC_SWITCH_INSTALL_RTK:-${INSTALL_RTK:-0}}"
AGENT_TARGET="${CC_SWITCH_AGENT:-both}"

CODEX_PROVIDER_ID="${CC_SWITCH_CODEX_PROVIDER_ID:-$PROVIDER_ID}"
CODEX_PROVIDER_NAME="${CC_SWITCH_CODEX_PROVIDER_NAME:-$PROVIDER_NAME Codex}"
CODEX_PROVIDER_KEY="${CC_SWITCH_CODEX_PROVIDER_KEY:-custom}"
CODEX_API_BASE_URL="${CC_SWITCH_CODEX_API_BASE_URL:-${API_BASE_URL%/}/v1}"
CODEX_API_KEY="${CC_SWITCH_CODEX_API_KEY:-$API_KEY}"
CODEX_MODEL="${CC_SWITCH_CODEX_MODEL:-$DEFAULT_MODEL}"
CODEX_WIRE_API="${CC_SWITCH_CODEX_WIRE_API:-responses}"

CLAUDE_CODE_WAS_PRESENT=0
CLAUDE_CODE_INSTALLED_BY_SCRIPT=0

usage() {
  cat <<'EOF'
Usage: cc_switch_setup.sh [--agent claude|codex|both]

Environment:
  CC_SWITCH_AGENT=claude|codex|both
  CC_SWITCH_API_KEY=your-key
  CC_SWITCH_CODEX_API_KEY=your-codex-key
  CC_SWITCH_INSTALL_RTK=1
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent)
        [ "$#" -ge 2 ] || { err "--agent 需要参数：claude|codex|both"; exit 1; }
        AGENT_TARGET="$2"
        shift 2
        ;;
      --agent=*)
        AGENT_TARGET="${1#--agent=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "未知参数：$1"
        usage >&2
        exit 1
        ;;
    esac
  done

  case "$AGENT_TARGET" in
    claude|codex|both) ;;
    *)
      err "无效 agent：$AGENT_TARGET，只支持 claude、codex、both。"
      exit 1
      ;;
  esac
}

wants_claude() {
  [ "$AGENT_TARGET" = "claude" ] || [ "$AGENT_TARGET" = "both" ]
}

wants_codex() {
  [ "$AGENT_TARGET" = "codex" ] || [ "$AGENT_TARGET" = "both" ]
}

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

patch_download_asset_fallback_to_ghfast() {
  local file="$1"

  GHFAST_PREFIX="$GHFAST_PREFIX" python3 - "$file" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
prefix = os.environ["GHFAST_PREFIX"]
content = path.read_text(encoding="utf-8")

old = '''download_asset() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --output "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget --quiet --output-document="${dest}" "${url}"
  else
    err "Neither curl nor wget found. Please install one and retry."
    exit 1
  fi
}
'''

new = '''download_asset() {
  local url="$1"
  local dest="$2"
  local fast_url=""

  case "${url}" in
    https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*)
      fast_url="''' + prefix + '''${url}"
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    if curl --fail --location --silent --show-error --output "${dest}" "${url}"; then
      return 0
    fi
    if [ -n "${fast_url}" ]; then
      warn "GitHub download failed, retrying with mirror: ${fast_url}"
      curl --fail --location --silent --show-error --output "${dest}" "${fast_url}" && return 0
    fi
    return 1
  elif command -v wget >/dev/null 2>&1; then
    if wget --quiet --output-document="${dest}" "${url}"; then
      return 0
    fi
    if [ -n "${fast_url}" ]; then
      warn "GitHub download failed, retrying with mirror: ${fast_url}"
      wget --quiet --output-document="${dest}" "${fast_url}" && return 0
    fi
    return 1
  else
    err "Neither curl nor wget found. Please install one and retry."
    exit 1
  fi
}
'''

if old in content and "GitHub download failed, retrying with mirror" not in content:
    content = content.replace(old, new)

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
  local sh_content='export PATH="$HOME/.local/node/bin:$HOME/.local/npm/bin:$HOME/.local/bin:$PATH"'
  local fish_content='fish_add_path "$HOME/.local/node/bin" "$HOME/.local/npm/bin" "$HOME/.local/bin"'

  upsert_shell_block "$HOME/.bashrc" "$sh_content"
  upsert_shell_block "$HOME/.zshrc" "$sh_content"
  upsert_shell_block "$HOME/.zprofile" "$sh_content"
  upsert_shell_block "$HOME/.config/fish/config.fish" "$fish_content"
}

setup_user_npm_prefix() {
  mkdir -p "$HOME/.local/bin" "$HOME/.local/npm" "$HOME/.local/node"
  export PATH="$HOME/.local/node/bin:$HOME/.local/npm/bin:$HOME/.local/bin:/data/$USER/dev/bin:/data/jhu/dev/bin:$PATH"
  export NPM_CONFIG_PREFIX="$HOME/.local/npm"

  if need_cmd npm; then
    npm config set prefix "$HOME/.local/npm" >/dev/null 2>&1 || true
  fi
}

node_major_version() {
  if ! need_cmd node; then
    echo 0
    return 0
  fi

  node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0
}

node_version_is_supported() {
  [ "$(node_major_version)" -ge 18 ]
}

install_node_with_nodesource() {
  if [ "$OS_TYPE" = "macos" ]; then
    return 1
  fi

  if ! need_cmd apt; then
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  if ! curl -LfsS --connect-timeout 10 --max-time 120 https://deb.nodesource.com/setup_20.x -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  warn "将通过 NodeSource 安装 Node.js 20。接下来可能需要你输入 sudo 密码授权。"
  if ! sudo -E bash "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"

  sudo apt install -y nodejs
}

install_node_from_tarball() {
  if [ "$OS_TYPE" = "macos" ]; then
    return 1
  fi

  local arch platform index tmp tarball_name url
  platform="linux"

  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv7l" ;;
    *)
      err "当前架构暂不支持自动安装 Node.js：$(uname -m)"
      return 1
      ;;
  esac

  index="$(mktemp)"
  if ! curl -LfsS --connect-timeout 10 --max-time 120 https://nodejs.org/dist/latest-v20.x/SHASUMS256.txt -o "$index"; then
    rm -f "$index"
    return 1
  fi

  tarball_name="$(awk -v platform="$platform" -v arch="$arch" '$2 ~ "node-v.*-" platform "-" arch "\\.tar\\.xz$" { print $2; exit }' "$index")"
  rm -f "$index"

  if [ -z "$tarball_name" ]; then
    err "未找到适配当前平台的 Node.js 20 安装包。"
    return 1
  fi

  if ! need_cmd tar; then
    install_with_apt tar
  fi

  tmp="$(mktemp -d)"
  url="https://nodejs.org/dist/latest-v20.x/${tarball_name}"
  log "下载 Node.js 20：$url"
  if ! curl -LfsS --connect-timeout 10 --max-time 300 "$url" -o "$tmp/node.tar.xz"; then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$HOME/.local/node"
  mkdir -p "$HOME/.local/node"
  if ! tar -xJf "$tmp/node.tar.xz" -C "$HOME/.local/node" --strip-components=1; then
    warn "解压 Node.js 失败，尝试安装 xz-utils 后重试。"
    install_with_apt xz-utils
    tar -xJf "$tmp/node.tar.xz" -C "$HOME/.local/node" --strip-components=1
  fi
  rm -rf "$tmp"

  export PATH="$HOME/.local/node/bin:$PATH"
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

ensure_claude_agent_work_rules() {
  local claude_dir="$HOME/.claude"
  local claude_md="$claude_dir/CLAUDE.md"
  local needs_fix=0

  mkdir -p "$claude_dir"
  if [ ! -f "$claude_md" ]; then
    needs_fix=1
  elif ! grep -qx '@RTK.md' "$claude_md" 2>/dev/null \
    || ! grep -q 'Use tools first\.' "$claude_md" 2>/dev/null \
    || ! grep -q 'If a response claims to check, read, inspect, list, or verify something' "$claude_md" 2>/dev/null; then
    needs_fix=1
  fi

  if [ "$needs_fix" -ne 1 ]; then
    log "~/.claude/CLAUDE.md agent work rules 已就绪。"
    return 0
  fi

  if [ -f "$claude_md" ]; then
    cp "$claude_md" "$claude_md.bak.$(date +%Y%m%d%H%M%S)" || true
  fi

  cat > "$claude_md" <<'EOF'
@RTK.md

# Agent Work Rules

When the user asks about files, repositories, code, configuration, shell commands, or project status:

- Use tools first.
- Do not answer from assumptions.
- For direct shell commands like `ls`, `pwd`, `cat`, `grep`, `find`, execute them directly.
- For repository analysis, inspect files before answering.
- If a response claims to check, read, inspect, list, or verify something, it must call the appropriate tool first.
EOF
  log "已修复 ~/.claude/CLAUDE.md agent work rules。"
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
      warn "RTK install.sh 下载失败。"
      return 1
    fi
    RTK_INSTALL_DIR="$RTK_BIN_DIR" RTK_BIN_DIR="$RTK_BIN_DIR" bash "$tmp" || true
    rm -f "$tmp"
  fi

  if ! command -v rtk >/dev/null 2>&1; then
    warn "RTK 安装后仍不可用，请检查 $RTK_BIN_DIR 是否在 PATH 中。"
    return 1
  fi

  if ! rtk --version >/dev/null 2>&1; then
    warn "rtk --version 执行失败，重新安装后仍不可用。"
    return 1
  fi

  rtk --version || true
  local init_ok=1
  if ! printf 'y\n' | rtk init -g; then
    warn "rtk init -g 执行失败，但 rtk 已安装。"
    init_ok=0
  fi

  ensure_claude_agent_work_rules || warn "修复 ~/.claude/CLAUDE.md 失败，请手动检查。"

  if [ "$init_ok" -ne 1 ]; then
    return 1
  fi

  return 0
}

maybe_install_rtk() {
  case "${INSTALL_RTK}" in
    1|true|TRUE|yes|YES|y|Y|on|ON)
      ensure_rtk || warn "RTK 自动安装/初始化失败，继续执行 Claude 和 cc-switch 安装。"
      ;;
    *)
      log "跳过 RTK 自动安装。如需安装，请使用：CC_SWITCH_INSTALL_RTK=1"
      ;;
  esac
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

ensure_node_npm() {
  setup_user_npm_prefix

  if [ "$OS_TYPE" = "macos" ]; then
    if ! need_cmd node || ! node_version_is_supported || ! need_cmd npm; then
      warn "未检测到 Node.js >= 18/npm，将通过 Homebrew 安装 node。"
      install_with_brew node
      setup_user_npm_prefix
    fi
  else
    if ! need_cmd node || ! node_version_is_supported || ! need_cmd npm; then
      warn "当前 Node.js 不可用或版本过低，需要 Node.js >= 18。"
      if ! install_node_with_nodesource; then
        warn "NodeSource 安装失败，改为安装用户目录版 Node.js 20。"
        install_node_from_tarball
      fi
      setup_user_npm_prefix
    fi
  fi

  if ! need_cmd node || ! node_version_is_supported; then
    err "Node.js 版本仍不满足要求。当前版本：$(node --version 2>/dev/null || echo not-found)，需要 >= 18。"
    exit 1
  fi

  if ! need_cmd npm; then
    err "npm 安装后仍不可用，请检查 Node.js/npm 安装状态。"
    exit 1
  fi

  log "Node.js 已就绪：$(node --version)"
  log "npm 已就绪：$(npm --version)，全局 prefix：$(npm config get prefix)"
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

  case "$claude_path" in
    /data/*/dev/bin/claude|*/node_modules/@anthropic-ai/claude-code/*|*/.npm-global/bin/claude|*/.local/npm/bin/claude|*/npm/bin/claude)
      return 0
      ;;
  esac

  if need_cmd npm && npm list -g @anthropic-ai/claude-code --depth=0 >/dev/null 2>&1; then
    return 0
  fi

  if timeout 5 "$claude_path" --version 2>/dev/null | grep -qiE 'claude code|anthropic'; then
    return 0
  fi

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
    CLAUDE_CODE_WAS_PRESENT=1
    return 0
  fi

  setup_user_npm_prefix

  log "安装官方 Claude Code 到用户目录：npm install -g @anthropic-ai/claude-code"
  npm install -g @anthropic-ai/claude-code

  hash -r 2>/dev/null || true

  if ! need_cmd claude; then
    err "Claude Code 安装后未找到 claude 命令，请检查 ~/.local/npm/bin 是否在 PATH 中。"
    exit 1
  fi

  CLAUDE_CODE_INSTALLED_BY_SCRIPT=1
  log "Claude Code 安装完成：$(command -v claude)"
}

install_codex_if_needed() {
  if need_cmd codex; then
    log "Codex CLI 已存在：$(command -v codex)"
    return 0
  fi

  setup_user_npm_prefix

  log "安装 Codex CLI 到用户目录：npm install -g @openai/codex"
  npm install -g @openai/codex

  hash -r 2>/dev/null || true

  if ! need_cmd codex; then
    err "Codex CLI 安装后未找到 codex 命令，请检查 ~/.local/npm/bin 是否在 PATH 中。"
    exit 1
  fi

  log "Codex CLI 安装完成：$(command -v codex)"
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

  patch_download_asset_fallback_to_ghfast "$tmp"

  if ! CC_SWITCH_FORCE=1 bash "$tmp"; then
    warn "cc-switch-cli 安装失败，重新注入 GitHub 下载失败时的镜像重试逻辑后再试一次。"
    patch_download_asset_fallback_to_ghfast "$tmp"
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
  local codex_update_script="$bin_dir/codex-update"
  local uninstall_script="$bin_dir/claude-uninstall"
  local codex_uninstall_script="$bin_dir/codex-uninstall"

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
  local self_name default_agent
  tmp="$(mktemp)"
  self_name="$(basename "$0")"
  default_agent="both"
  case "$self_name" in
    claude-update) default_agent="claude" ;;
    codex-update) default_agent="codex" ;;
  esac

  log "拉取最新版 cc_switch_setup.sh 并重新执行安装/配置。"
  if ! download_nonempty "$SELF_SCRIPT_URL" "$SELF_SCRIPT_URL_FAST" "$tmp"; then
    rm -f "$tmp"
    err "cc_switch_setup.sh 下载失败。"
    exit 1
  fi

  if [ "$#" -eq 0 ]; then
    bash "$tmp" --agent "$default_agent"
  else
    bash "$tmp" "$@"
  fi
  rm -f "$tmp"
}

main "$@"
EOF

  cp "$update_script" "$codex_update_script"

  cat > "$uninstall_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER_ID="ictrek"
API_BASE_URL="https://ai.ictrek.com"
API_KEY="dummy-keys"
HAIKU_MODEL="volces/DeepSeek-V4-Flash"
DEFAULT_MODEL="volces/GLM-5.1"
CODEX_API_BASE_URL="https://ai.ictrek.com/v1"
CODEX_API_KEY="dummy-keys"
CODEX_MODEL="volces/GLM-5.1"
AGENT_TARGET="both"

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  local self_name
  self_name="$(basename "$0")"
  case "$self_name" in
    claude-uninstall) AGENT_TARGET="claude" ;;
    codex-uninstall) AGENT_TARGET="codex" ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent)
        [ "$#" -ge 2 ] || { echo "ERR: --agent 需要参数：claude|codex|both" >&2; exit 1; }
        AGENT_TARGET="$2"
        shift 2
        ;;
      --agent=*)
        AGENT_TARGET="${1#--agent=}"
        shift
        ;;
      -h|--help)
        echo "Usage: $(basename "$0") [--agent claude|codex|both]"
        exit 0
        ;;
      *)
        echo "ERR: 未知参数：$1" >&2
        exit 1
        ;;
    esac
  done

  case "$AGENT_TARGET" in
    claude|codex|both) ;;
    *)
      echo "ERR: 无效 agent：$AGENT_TARGET，只支持 claude、codex、both。" >&2
      exit 1
      ;;
  esac
}

wants_claude() {
  [ "$AGENT_TARGET" = "claude" ] || [ "$AGENT_TARGET" = "both" ]
}

wants_codex() {
  [ "$AGENT_TARGET" = "codex" ] || [ "$AGENT_TARGET" = "both" ]
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
  PROVIDER_ID="$PROVIDER_ID" \
  AGENT_TARGET="$AGENT_TARGET" \
  python3 - <<'PY'
import os
import sqlite3
from pathlib import Path

config_dir = Path(os.environ.get("CC_SWITCH_CONFIG_DIR") or Path.home() / ".cc-switch")
db_path = config_dir / "cc-switch.db"
if not db_path.exists():
    raise SystemExit(0)

provider_id = os.environ["PROVIDER_ID"]
agent_target = os.environ["AGENT_TARGET"]
app_types = {
    "claude": ("claude",),
    "codex": ("codex",),
    "both": ("claude", "codex"),
}[agent_target]
with sqlite3.connect(db_path) as conn:
    for app_type in app_types:
        current = conn.execute(
            "SELECT is_current FROM providers WHERE id = ? AND app_type = ?",
            (provider_id, app_type),
        ).fetchone()
        conn.execute("DELETE FROM providers WHERE id = ? AND app_type = ?", (provider_id, app_type))
        if current and current[0]:
            conn.execute("UPDATE providers SET is_current = 0 WHERE app_type = ?", (app_type,))
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

clean_codex_config() {
  CODEX_API_BASE_URL="$CODEX_API_BASE_URL" \
  CODEX_API_KEY="$CODEX_API_KEY" \
  CODEX_MODEL="$CODEX_MODEL" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

codex_dir = Path.home() / ".codex"
config_path = codex_dir / "config.toml"
auth_path = codex_dir / "auth.json"

if auth_path.exists():
    try:
        auth = json.loads(auth_path.read_text(encoding="utf-8"))
    except Exception:
        auth = None
    if isinstance(auth, dict) and auth.get("OPENAI_API_KEY") == os.environ["CODEX_API_KEY"]:
        auth_path.unlink()
        print(auth_path)

if config_path.exists():
    text = config_path.read_text(encoding="utf-8", errors="ignore")
    if os.environ["CODEX_API_BASE_URL"] in text and os.environ["CODEX_MODEL"] in text:
        config_path.unlink()
        print(config_path)
PY
}

uninstall_claude_code() {
  export PATH="$HOME/.local/node/bin:$HOME/.local/npm/bin:$HOME/.local/bin:$PATH"
  export NPM_CONFIG_PREFIX="$HOME/.local/npm"

  if ! need_cmd npm; then
    warn "未检测到 npm，跳过官方 Claude Code npm 包卸载。"
    return 0
  fi

  if npm list -g @anthropic-ai/claude-code --depth=0 >/dev/null 2>&1; then
    log "卸载官方 Claude Code npm 包。"
    npm uninstall -g @anthropic-ai/claude-code
  else
    warn "未检测到全局 @anthropic-ai/claude-code，跳过 npm 卸载。"
  fi
}

uninstall_codex_cli() {
  export PATH="$HOME/.local/node/bin:$HOME/.local/npm/bin:$HOME/.local/bin:$PATH"
  export NPM_CONFIG_PREFIX="$HOME/.local/npm"

  if ! need_cmd npm; then
    warn "未检测到 npm，跳过 Codex CLI npm 包卸载。"
    return 0
  fi

  if npm list -g @openai/codex --depth=0 >/dev/null 2>&1; then
    log "卸载 Codex CLI npm 包。"
    npm uninstall -g @openai/codex
  else
    warn "未检测到全局 @openai/codex，跳过 npm 卸载。"
  fi
}

main() {
  parse_args "$@"

  if wants_claude; then
    disable_proxy_takeover || warn "关闭 cc-switch 代理接管失败，继续清理其它项目。"
    disable_claude_plugin_integration || warn "关闭 VS Code Claude 插件接管失败，继续清理其它项目。"
  fi
  remove_ictrek_provider || warn "移除 cc-switch provider 失败，继续清理其它项目。"
  if wants_claude; then
    clean_claude_settings || warn "清理 Claude settings 失败，继续清理其它项目。"
    uninstall_claude_code || warn "卸载官方 Claude Code 失败。"
  fi
  if wants_codex; then
    clean_codex_config || warn "清理 Codex config 失败，继续清理其它项目。"
    uninstall_codex_cli || warn "卸载 Codex CLI 失败。"
  fi

  if [ "$AGENT_TARGET" = "both" ]; then
    remove_shell_block "$HOME/.bashrc"
    remove_shell_block "$HOME/.zshrc"
    remove_shell_block "$HOME/.zprofile"
    remove_shell_block "$HOME/.config/fish/config.fish"
  fi

  if wants_claude; then
    rm -f "$HOME/.local/bin/claude-update" "$HOME/.local/bin/claude-uninstall"
  fi
  if wants_codex; then
    rm -f "$HOME/.local/bin/codex-update" "$HOME/.local/bin/codex-uninstall"
  fi

  log "已卸载 cc-switch ${AGENT_TARGET} 方案。"
  warn "未删除 cc-switch 本体和 ~/.cc-switch 其它配置，避免影响你已有的 provider。"
  warn "如当前 shell 缓存了命令，请执行：hash -r 2>/dev/null || true；fish 请重新打开终端。"
}

main "$@"
EOF

  cp "$uninstall_script" "$codex_uninstall_script"

  chmod +x "$update_script" "$codex_update_script" "$uninstall_script" "$codex_uninstall_script"
  log "claude-update 命令已写入：$update_script"
  log "codex-update 命令已写入：$codex_update_script"
  log "claude-uninstall 命令已写入：$uninstall_script"
  log "codex-uninstall 命令已写入：$codex_uninstall_script"
}

init_cc_switch_if_needed() {
  log "初始化 cc-switch 配置。"
  if wants_claude; then
    cc-switch --app claude provider list >/dev/null 2>&1 || true
  fi
  if wants_codex; then
    cc-switch --app codex provider list >/dev/null 2>&1 || true
  fi
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

configure_cc_switch_codex_provider() {
  log "写入 cc-switch Codex provider：${CODEX_PROVIDER_NAME}。"

  CODEX_PROVIDER_ID="$CODEX_PROVIDER_ID" \
  CODEX_PROVIDER_NAME="$CODEX_PROVIDER_NAME" \
  CODEX_PROVIDER_KEY="$CODEX_PROVIDER_KEY" \
  CODEX_API_BASE_URL="$CODEX_API_BASE_URL" \
  CODEX_API_KEY="$CODEX_API_KEY" \
  CODEX_MODEL="$CODEX_MODEL" \
  CODEX_WIRE_API="$CODEX_WIRE_API" \
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

provider_id = os.environ["CODEX_PROVIDER_ID"]
provider_name = os.environ["CODEX_PROVIDER_NAME"]
provider_key = os.environ["CODEX_PROVIDER_KEY"]
api_base_url = os.environ["CODEX_API_BASE_URL"].rstrip("/")
api_key = os.environ["CODEX_API_KEY"]
model = os.environ["CODEX_MODEL"]
wire_api = os.environ["CODEX_WIRE_API"]
now_ms = int(time.time() * 1000)

def toml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')

config_toml = "\n".join([
    f'model_provider = "{toml_escape(provider_key)}"',
    f'model = "{toml_escape(model)}"',
    'model_reasoning_effort = "high"',
    'disable_response_storage = true',
    '',
    f'[model_providers.{provider_key}]',
    f'name = "{toml_escape(provider_key)}"',
    f'base_url = "{toml_escape(api_base_url)}"',
    f'wire_api = "{toml_escape(wire_api)}"',
    'requires_openai_auth = true',
    '',
])

settings_config = {
    "auth": {
        "OPENAI_API_KEY": api_key,
    },
    "config": config_toml,
}

meta = {
    "apiFormat": "openai_responses",
}

with sqlite3.connect(db_path) as conn:
    existing = conn.execute(
        "SELECT created_at, sort_index, is_current, in_failover_queue FROM providers WHERE id = ? AND app_type = 'codex'",
        (provider_id,),
    ).fetchone()

    if existing:
        created_at, sort_index, is_current, in_failover_queue = existing
    else:
        created_at = now_ms
        row = conn.execute("SELECT MAX(sort_index) FROM providers WHERE app_type = 'codex'").fetchone()
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
        VALUES (?, 'codex', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            "terminal",
            "#10A37F",
            json.dumps(meta, ensure_ascii=False, separators=(",", ":")),
            is_current,
            in_failover_queue,
        ),
    )
    conn.commit()

print(db_path)
PY

  log "切换 cc-switch Codex provider 并同步 Codex config。"
  cc-switch --app codex provider switch "$CODEX_PROVIDER_ID"
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
  parse_args "$@"

  export PATH="/data/$USER/dev/bin:/data/jhu/dev/bin:$PATH"
  install_basic_tools_if_needed
  ensure_local_bin_in_path
  if wants_claude; then
    maybe_install_rtk
  fi
  ensure_node_npm
  if wants_claude; then
    uninstall_cc_haha_if_needed
    install_claude_code_if_needed
  fi
  if wants_codex; then
    install_codex_if_needed
  fi
  install_cc_switch_if_needed
  init_cc_switch_if_needed
  if wants_claude; then
    configure_cc_switch_provider
    enable_cc_switch_proxy_and_plugin
    setup_claude_first_run_state
  fi
  if wants_codex; then
    configure_cc_switch_codex_provider
  fi
  write_management_scripts

  log "完成。重新打开终端后可执行：claude / codex"
  log "管理命令：claude-update / claude-uninstall"
  log "Claude provider：$PROVIDER_ID -> $API_BASE_URL"
  log "Codex provider：$CODEX_PROVIDER_ID -> $CODEX_API_BASE_URL"
}

main "$@"
