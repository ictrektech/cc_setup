#!/usr/bin/env bash
set -euo pipefail

APP_NAME="agent-room"
APP_ID="com.ictrek.agent-room"
REGISTRY="swr.cn-southwest-2.myhuaweicloud.com/ictrek"
IMAGE_NAME="${REGISTRY}/${APP_NAME}"
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

PLATFORM=""
SKIP_PULL="${SKIP_PULL:-0}"
IMAGE_SOURCE="${IMAGE_SOURCE:-local}"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./scripts/package.sh [--platform PLATFORM] [--image-source local|pull]

Options:
  --platform NAME   Target platform. Supported: arm64, amd64.
                    Defaults to local architecture.
  --skip-pull       Do not docker pull before docker save.
  --image-source    local: package images as docker-archive assets.
                    pull: write image names only and let the VOS host pull.
                    Default: local.
  -h, --help        Show this help.

Environment:
  FEISHU_CONFIG_FILE        Feishu credential JSON.
  FEISHU_FALLBACK_CONFIG_FILE
                            Fallback credential JSON.
  FEISHU_SPREADSHEET_TOKEN  Release spreadsheet token.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

acquire_lock() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 1
  done
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

detect_platform() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "unsupported architecture: $(uname -m). Use --platform arm64|amd64." ;;
  esac
}

arch_tag() {
  case "$1" in
    amd64|amd|AMD_with_cuda|AMD_with_mxn100) echo "amd" ;;
    arm64|arm|l4t|thor_spark|ARM_with_cuda|ARM_without_cuda|SOPHON_bm1688) echo "arm" ;;
    *) die "unsupported arch: $1" ;;
  esac
}

platform_arch() {
  case "$1" in
    arm64|l4t|thor_spark|ARM_with_cuda|ARM_without_cuda|SOPHON_bm1688) echo "arm64" ;;
    amd64|amd|AMD_with_cuda|AMD_with_mxn100) echo "amd64" ;;
    *) die "unsupported platform: $1" ;;
  esac
}

platform_sheet() {
  case "$1" in
    arm64) echo "l4t" ;;
    amd64) echo "AMD_with_cuda" ;;
    arm|l4t|thor_spark|ARM_with_cuda|ARM_without_cuda|SOPHON_bm1688|amd|AMD_with_cuda|AMD_with_mxn100) echo "$1" ;;
    *) die "unsupported platform: $1" ;;
  esac
}

platform_package_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_'
}

validate_image_source() {
  case "$1" in
    local|pull) ;;
    *) die "unsupported image source: $1. Use local or pull." ;;
  esac
}

manifest_assets_block() {
  if [[ "$IMAGE_SOURCE" == "pull" ]]; then
    return 0
  fi
  cat <<EOF
assets:
  - filename: ${IMAGE_ARCHIVE}
    kind: docker-archive
    arch: host
EOF
}

pull_policy_line() {
  if [[ "$IMAGE_SOURCE" == "pull" ]]; then
    printf '    pull_policy: always'
  fi
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
  python3 - "$config_file" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
val = data.get(field, "")
print(val if isinstance(val, str) else str(val))
PY
}

feishu_api_json() {
  local method="$1"
  local url="$2"
  local token="$3"
  curl --fail -sS -X "$method" "$url" \
    -H "Authorization: Bearer ${token}"
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
  python3 - "$resp" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"get_feishu_token failed: {data}")
print(data["tenant_access_token"])
PY
}

get_sheet_id_by_title() {
  local token="$1"
  local target_title="$2"
  local resp
  resp="$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${SPREADSHEET_TOKEN}/sheets/query" \
    "$token")"
  python3 - "$target_title" "$resp" <<'PY'
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
PY
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
  python3 - "$component" "$resp" <<'PY'
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
PY
}

find_latest_tag() {
  local token="$1"
  local sheet_id="$2"
  local column="$3"
  local resp
  resp="$(get_range_values "$token" "${sheet_id}!${column}4:${column}2000")"
  python3 - "$resp" <<'PY'
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
PY
}

latest_image() {
  local token="$1"
  local sheet_id="$2"
  local component="$3"
  local repository="$4"
  local column tag
  column="$(find_component_column_letter "$token" "$sheet_id" "$component")"
  tag="$(find_latest_tag "$token" "$sheet_id" "$column")"
  echo "${repository}:${tag}"
}

resolve_feishu_images() {
  local sheet_title="$1"
  local config_file tried=""
  for config_file in "$FEISHU_CONFIG_FILE" "$FEISHU_FALLBACK_CONFIG_FILE"; do
    [[ -n "$config_file" && "$tried" != *"|$config_file|"* ]] || continue
    tried="${tried}|${config_file}|"
    [[ -r "$config_file" ]] || { log "Skip unreadable Feishu config: ${config_file}"; continue; }
    log "Read component versions with Feishu config: ${config_file}"
    if FEISHU_APP_ID="$(read_feishu_field "$config_file" "feishu_app_id")" \
      && FEISHU_APP_SECRET="$(read_feishu_field "$config_file" "feishu_app_secret")" \
      && [[ -n "$FEISHU_APP_ID" && -n "$FEISHU_APP_SECRET" ]] \
      && FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")" \
      && SHEET_ID="$(get_sheet_id_by_title "$FEISHU_TOKEN" "$sheet_title")" \
      && COMPONENT_IMAGE="$(latest_image "$FEISHU_TOKEN" "$SHEET_ID" "${APP_NAME}" "${IMAGE_NAME}")"; then
      return 0
    fi
    log "Cannot read component versions from ${config_file}; trying fallback"
  done
  die "failed to read component versions from Feishu configs"
}

render_file() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" \
    "$APP_VERSION" "$VOS_ARCH" \
    "$COMPONENT_IMAGE" \
    "$IMAGE_ARCHIVE" \
    "$(manifest_assets_block)" "$(pull_policy_line)" <<'PY'
import sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
replacements = {
    "__APP_VERSION__": sys.argv[3],
    "__VOS_ARCH__": sys.argv[4],
    "__IMAGE__": sys.argv[5],
    "__IMAGE_ARCHIVE__": sys.argv[6],
    "__ASSETS_BLOCK__": sys.argv[7],
    "__PULL_POLICY__": sys.argv[8],
}
text = src.read_text(encoding="utf-8")
for key, value in replacements.items():
    text = text.replace(key, value)
dst.write_text(text, encoding="utf-8")
PY
}

safe_name_from_image() {
  local image="$1"
  echo "$image" | sed -E 's|.*/||; s|[:/]|-|g'
}

export_image() {
  local image="$1"
  local archive="$2"
  local out_dir="$3"
  mkdir -p "$out_dir"
  if [[ "$SKIP_PULL" != "1" ]]; then
    log "Pull ${image}"
    docker pull --platform "linux/${VOS_ARCH}" "$image"
  fi
  log "Save ${image} -> ${out_dir}/${archive}"
  docker save "$image" | gzip > "${out_dir}/${archive}"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$out_dir" && sha256sum "$archive" > "${archive}.sha256")
  else
    (cd "$out_dir" && shasum -a 256 "$archive" > "${archive}.sha256")
  fi
}

verify_package() {
  local package_path="$1"
  local app_tarball="$2"
  log "Verify app.tar.gz contents"
  tar tzf "$app_tarball" >/dev/null
  tar tf "$package_path" | grep -qx "app.tar.gz"
  if [[ "$IMAGE_SOURCE" == "local" ]]; then
    tar tf "$package_path" | grep -qx "assets/${VOS_ARCH}/${IMAGE_ARCHIVE}"
  else
    ! tar tf "$package_path" | grep -q "^assets/"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --skip-pull)
      SKIP_PULL=1
      shift
      ;;
    --image-source)
      IMAGE_SOURCE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd curl
require_cmd python3
require_cmd tar

validate_image_source "$IMAGE_SOURCE"
if [[ "$IMAGE_SOURCE" == "local" ]]; then
  require_cmd docker
  require_cmd gzip
fi

[[ -f "$VERSION_FILE" ]] || echo "0.0.0" > "$VERSION_FILE"

PLATFORM="${PLATFORM:-$(detect_platform)}"
VOS_ARCH="$(platform_arch "$PLATFORM")"
SHEET_TITLE="$(platform_sheet "$PLATFORM")"
PACKAGE_PLATFORM="$(platform_package_name "$SHEET_TITLE")"

mkdir -p "$DIST_DIR"
acquire_lock

APP_VERSION="$(next_version)"
log "Package version: ${APP_VERSION}"
log "Platform: ${PLATFORM} (${VOS_ARCH}), sheet: ${SHEET_TITLE}"
log "Image source: ${IMAGE_SOURCE}"

# 从飞书读取镜像版本，如果飞书配置不存在则使用本地日期标签
ARCH_TAG="$(arch_tag "$PLATFORM")"
LOCAL_IMAGE="${IMAGE_NAME}:${ARCH_TAG}_$(date +%Y%m%d)"
if [[ -f "$FEISHU_CONFIG_FILE" ]]; then
  resolve_feishu_images "$SHEET_TITLE"
else
  log "Feishu config not found, using local image: ${LOCAL_IMAGE}"
  COMPONENT_IMAGE="$LOCAL_IMAGE"
  SKIP_PULL=1
fi

IMAGE_ARCHIVE="$(safe_name_from_image "$COMPONENT_IMAGE").tar.gz"

log "Image: ${COMPONENT_IMAGE}"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

for file in manifest.yml docker-compose.yml configs.yml routers.yml README.zh-CN.md; do
  render_file "${SRC_DIR}/${file}" "${STAGE_DIR}/${file}"
done

APP_TARBALL="${DIST_DIR}/app.tar.gz"
PACKAGE_NAME="${APP_NAME}_${APP_VERSION}_${PACKAGE_PLATFORM}.tar"
if [[ "$IMAGE_SOURCE" == "pull" ]]; then
  PACKAGE_NAME="${APP_NAME}_${APP_VERSION}_${PACKAGE_PLATFORM}_pull.tar"
fi
PACKAGE_PATH="${DIST_DIR}/${PACKAGE_NAME}"
ASSET_DIR="${PACKAGE_ROOT}/assets/${VOS_ARCH}"

tar czf "$APP_TARBALL" -C "$STAGE_DIR" manifest.yml docker-compose.yml configs.yml routers.yml README.zh-CN.md

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT"
cp "$APP_TARBALL" "${PACKAGE_ROOT}/app.tar.gz"
if [[ "$IMAGE_SOURCE" == "local" ]]; then
  export_image "$COMPONENT_IMAGE" "$IMAGE_ARCHIVE" "$ASSET_DIR"
  tar cf "$PACKAGE_PATH" -C "$PACKAGE_ROOT" app.tar.gz assets
else
  tar cf "$PACKAGE_PATH" -C "$PACKAGE_ROOT" app.tar.gz
fi
verify_package "$PACKAGE_PATH" "$APP_TARBALL"

echo "$APP_VERSION" > "$VERSION_FILE"
log "Done: ${PACKAGE_PATH}"
