#!/usr/bin/env bash
set -euo pipefail

APP_NAME="agent-room"
APP_ID="com.ictrek.agent-room"
SPREADSHEET_TOKEN="${FEISHU_SPREADSHEET_TOKEN:-Htotsn3oahO1zxt73YMcaB1zn8e}"
FEISHU_CONFIG_FILE="${FEISHU_CONFIG_FILE:-${HOME}/.feishu.components.json}"
FEISHU_FALLBACK_CONFIG_FILE="${FEISHU_FALLBACK_CONFIG_FILE:-${HOME}/.feishu.json}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/src"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="${DIST_DIR}/staging"
PACKAGE_ROOT="${DIST_DIR}/package-root"
VERSION_FILE="${ROOT_DIR}/VERSION"
LOCK_DIR="${DIST_DIR}/.package.lock"

PROFILES=(
  "amd|AMD_with_cuda"
)
COMPONENTS=(
  "AGENT_ROOM|agent-room|swr.cn-southwest-2.myhuaweicloud.com/ictrek/agent-room"
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/package.sh

This builds one VOS app tarball for all supported Docker Compose profiles.
The package is always pull mode: it contains app.tar.gz only, writes image
names into app.tar.gz/.env, and never embeds docker image archives.
EOF
}

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

acquire_lock() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 1
  done
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

next_version() {
  local current major minor patch
  current="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid VERSION: $current"
  IFS=. read -r major minor patch <<< "$current"
  if (( patch < 999 )); then
    patch=$((patch + 1))
  else
    patch=0
    if (( minor < 999 )); then
      minor=$((minor + 1))
    else
      minor=0
      major=$((major + 1))
    fi
  fi
  echo "${major}.${minor}.${patch}"
}

read_feishu_field() {
  local config_file="$1"
  local field="$2"
  python3 - "$config_file" "$field" <<'PYJSON'
import json
import sys
path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
val = data.get(field, "")
print(val if isinstance(val, str) else str(val))
PYJSON
}

feishu_api_json() {
  local method="$1"
  local url="$2"
  local token="$3"
  curl --fail -sS -X "$method" "$url" -H "Authorization: Bearer ${token}"
}

get_feishu_token() {
  local app_id="$1"
  local app_secret="$2"
  local resp
  resp="$(
    curl --fail -sS -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
      -H "Content-Type: application/json" \
      -d "{\"app_id\":\"${app_id}\",\"app_secret\":\"${app_secret}\"}"
  )"
  python3 - "$resp" <<'PYJSON'
import json
import sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"get_feishu_token failed: {data}")
print(data["tenant_access_token"])
PYJSON
}

get_sheet_id_by_title() {
  local token="$1"
  local target_title="$2"
  local resp
  resp="$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${SPREADSHEET_TOKEN}/sheets/query" \
    "$token")"
  python3 - "$target_title" "$resp" <<'PYJSON'
import json
import sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"query sheets failed: {data}")
for sheet in data.get("data", {}).get("sheets", []):
    if sheet.get("title") == target:
        print(sheet["sheet_id"])
        raise SystemExit(0)
raise SystemExit(f"sheet title not found: {target}")
PYJSON
}

get_range_values() {
  local token="$1"
  local range="$2"
  feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${SPREADSHEET_TOKEN}/values/${range}" \
    "$token"
}

find_component_column_letter() {
  local token="$1"
  local sheet_id="$2"
  local component="$3"
  local resp
  resp="$(get_range_values "$token" "${sheet_id}!A1:ZZ1")"
  python3 - "$component" "$resp" <<'PYJSON'
import json
import sys
target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"read header failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
row = values[0] if values else []

def text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        return str(value.get("text") or value.get("link") or "").strip()
    if isinstance(value, list):
        return "".join(text(v) for v in value).strip()
    return str(value).strip()

def col(num):
    out = ""
    while num > 0:
        num, rem = divmod(num - 1, 26)
        out = chr(ord("A") + rem) + out
    return out

for index, value in enumerate(row, start=1):
    if text(value) == target:
        print(col(index))
        raise SystemExit(0)
raise SystemExit(f"component column not found in row1: {target}")
PYJSON
}

find_latest_tag() {
  local token="$1"
  local sheet_id="$2"
  local column="$3"
  local resp
  resp="$(get_range_values "$token" "${sheet_id}!${column}4:${column}2000")"
  python3 - "$resp" <<'PYJSON'
import json
import sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"read version column failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
for row in values:
    if not row:
        continue
    value = row[0]
    if value is None:
        continue
    text = str(value).strip()
    if text:
        print(text)
        raise SystemExit(0)
raise SystemExit("latest version not found")
PYJSON
}

latest_image() {
  local token="$1"
  local sheet_id="$2"
  local component="$3"
  local repository="$4"
  local column tag
  column="$(find_component_column_letter "$token" "$sheet_id" "$component")" || return 1
  tag="$(find_latest_tag "$token" "$sheet_id" "$column")" || return 1
  [[ -n "$tag" ]] || return 1
  echo "${repository}:${tag}"
}

load_feishu_auth() {
  local config_file tried=""
  for config_file in "$FEISHU_CONFIG_FILE" "$FEISHU_FALLBACK_CONFIG_FILE"; do
    [[ -n "$config_file" && "$tried" != *"|$config_file|"* ]] || continue
    tried="${tried}|${config_file}|"
    [[ -r "$config_file" ]] || { log "Skip unreadable Feishu config: ${config_file}"; continue; }
    log "Read component versions with Feishu config: ${config_file}"
    if FEISHU_APP_ID="$(read_feishu_field "$config_file" "feishu_app_id")" \
      && FEISHU_APP_SECRET="$(read_feishu_field "$config_file" "feishu_app_secret")" \
      && [[ -n "$FEISHU_APP_ID" && -n "$FEISHU_APP_SECRET" ]] \
      && FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"; then
      return 0
    fi
    log "Cannot read Feishu auth from ${config_file}; trying fallback"
  done
  die "failed to read Feishu credentials"
}

render_text_file() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" "$APP_VERSION" <<'PYRENDER'
import sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text(encoding="utf-8").replace("__APP_VERSION__", sys.argv[3])
dst.write_text(text, encoding="utf-8")
PYRENDER
}

verify_package() {
  local package_path="$1"
  local app_tarball="$2"
  log "Verify app.tar.gz contents"
  tar tzf "$app_tarball" >/dev/null
  tar tf "$package_path" | grep -qx "app.tar.gz"
  ! tar tf "$package_path" | grep -q "^assets/"
  if tar xOf "$package_path" app.tar.gz | tar tzf - | grep -q '__APP_VERSION__'; then
    die "unrendered __APP_VERSION__ placeholder remains"
  fi
}


env_key() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -c 'A-Z0-9_' '_'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-source)
      [[ "${2:-}" == "pull" ]] || die "only pull mode is supported"
      shift 2
      ;;
    --platform|--profile)
      die "platform/profile is selected during VOS install; package.sh now creates one tarball for all profiles"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd curl
require_cmd python3
require_cmd tar
[[ -f "$VERSION_FILE" ]] || echo "0.0.0" > "$VERSION_FILE"
mkdir -p "$DIST_DIR"
acquire_lock

if [[ -n "${PACKAGE_VERSION:-}" ]]; then
  [[ "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid PACKAGE_VERSION: $PACKAGE_VERSION"
  APP_VERSION="$PACKAGE_VERSION"
else
  APP_VERSION="$(next_version)"
fi
log "Package version: ${APP_VERSION}"
log "Image source: pull"
load_feishu_auth

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

ENV_FILE="${STAGE_DIR}/.env"
: > "$ENV_FILE"
for profile_spec in "${PROFILES[@]}"; do
  IFS='|' read -r profile sheet_title <<< "$profile_spec"
  sheet_title="${sheet_title:-$profile}"
  profile_key="$(env_key "$profile")"
  for component_spec in "${COMPONENTS[@]}"; do
    IFS='|' read -r env_prefix component repository <<< "$component_spec"
    image=""
    IFS=',' read -ra candidate_sheets <<< "$sheet_title"
    for candidate_sheet in "${candidate_sheets[@]}"; do
      sheet_id="$(get_sheet_id_by_title "$FEISHU_TOKEN" "$candidate_sheet")"
      if image="$(latest_image "$FEISHU_TOKEN" "$sheet_id" "$component" "$repository")"; then
        log "$profile ($candidate_sheet) $component -> $image"
        break
      fi
      log "$profile cannot read $component from $candidate_sheet; trying fallback"
    done
    [[ -n "$image" ]] || die "failed to resolve image for profile=$profile component=$component sheets=$sheet_title"
    printf '%s_%s_IMAGE=%s
' "$env_prefix" "$profile_key" "$image" >> "$ENV_FILE"
  done
done

for file in manifest.yml docker-compose.yml configs.yml routers.yml README.zh-CN.md README.en.md; do
  if [[ -f "${SRC_DIR}/${file}" ]]; then
    render_text_file "${SRC_DIR}/${file}" "${STAGE_DIR}/${file}"
  fi
done


APP_TARBALL="${DIST_DIR}/app.tar.gz"
PACKAGE_NAME="${APP_NAME}_${APP_VERSION}_pull.tar"
PACKAGE_PATH="${DIST_DIR}/${PACKAGE_NAME}"

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT"
tar czf "$APP_TARBALL" -C "$STAGE_DIR" .
cp "$APP_TARBALL" "${PACKAGE_ROOT}/app.tar.gz"
tar cf "$PACKAGE_PATH" -C "$PACKAGE_ROOT" app.tar.gz
verify_package "$PACKAGE_PATH" "$APP_TARBALL"

echo "$APP_VERSION" > "$VERSION_FILE"
log "Done: ${PACKAGE_PATH}"
