#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# agent-room Docker image build and Feishu release-table update script.
#
# Usage:
#   ./docker/build_images.sh amd
#   ./docker/build_images.sh arm
#   ./docker/build_images.sh --profile arm --sheet l4t
#   ./docker/build_images.sh --profile amd --no-push --no-feishu
#
# The component column is created only when the exact header is missing. The
# script inserts one column directly after the last non-empty header/repository
# cell, then writes row 1 and row 2 before writing the date row.
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMG_NAME="agent-room"
COMPONENT_NAME="agent-room"
FEISHU_CONFIG_FILE="${FEISHU_CONFIG_FILE:-${HOME}/.feishu.json}"
FEISHU_SPREADSHEET_TOKEN="${FEISHU_SPREADSHEET_TOKEN:-Htotsn3oahO1zxt73YMcaB1zn8e}"
SWR_REGISTRY="${SWR_REGISTRY:-swr.cn-southwest-2.myhuaweicloud.com/ictrek}"

AMD_SHEETS=("AMD_with_cuda" "AMD_with_mxn100")
ARM_SHEETS=("l4t" "ARM_without_cuda" "ARM_with_cuda" "thor_spark" "SOPHON_bm1688")

declare -A PROFILE_TO_PLATFORM=(
  ["amd"]="linux/amd64"
  ["arm"]="linux/arm64"
)

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

detect_profile() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd" ;;
    aarch64|arm64) echo "arm" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

read_feishu_field() {
  local field="$1"
  python3 - "$FEISHU_CONFIG_FILE" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data.get(field, "")
print(value if isinstance(value, str) else str(value))
PY
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

feishu_api_json() {
  local method="$1"
  local url="$2"
  local token="$3"
  local body="${4:-}"

  if [[ -n "$body" ]]; then
    curl --fail -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl --fail -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}"
  fi
}

get_sheet_id_by_title() {
  local token="$1"
  local target_title="$2"
  local resp

  resp="$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/sheets/query" \
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
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/values/${range}" \
    "$token"
}

write_cell() {
  local token="$1"
  local sheet_id="$2"
  local cell="$3"
  local value="$4"
  local resp

  resp="$(feishu_api_json "PUT" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/values" \
    "$token" \
    "{\"valueRange\":{\"range\":\"${sheet_id}!${cell}:${cell}\",\"values\":[[\"${value}\"]]}}")"

  python3 - "$resp" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"write_cell failed: {data}")
PY
}

find_component_column_letter() {
  local token="$1"
  local sheet_id="$2"
  local component="$3"
  local repository="$4"
  local resp result status value meta_resp column_count resp2 cell

  resp="$(get_range_values "$token" "${sheet_id}!A1:ZZ2")"
  result="$(python3 - "$component" "$resp" <<'PY'
import json
import sys

target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"read header failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
rows = values[:2]
header = rows[0] if rows else []
repo = rows[1] if len(rows) > 1 else []

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

for index, value in enumerate(header, start=1):
    if text(value) == target:
        print(f"FOUND\t{col(index)}")
        raise SystemExit(0)

last = 1
for row in (header, repo):
    for index, value in enumerate(row, start=1):
        if text(value):
            last = max(last, index)
print(f"MISSING\t{last}")
PY
)"

  status="${result%%$'\t'*}"
  value="${result#*$'\t'}"
  if [[ "$status" == "FOUND" ]]; then
    echo "$value"
    return 0
  fi
  [[ "$status" == "MISSING" ]] || die "unexpected column lookup result: $result"

  meta_resp="$(feishu_api_json "GET" \
    "https://open.feishu.cn/open-apis/sheets/v3/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/sheets/query" \
    "$token")"
  column_count="$(python3 - "$sheet_id" "$meta_resp" <<'PY'
import json
import sys

sheet_id, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"query sheets failed: {data}")
for sheet in data.get("data", {}).get("sheets", []):
    if sheet.get("sheet_id") == sheet_id:
        print(sheet.get("grid_properties", {}).get("column_count", 0))
        raise SystemExit(0)
raise SystemExit(f"sheet id not found: {sheet_id}")
PY
)"

  if (( value >= column_count )); then
    resp2="$(feishu_api_json "POST" \
      "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/dimension_range" \
      "$token" \
      "{\"dimension\":{\"sheetId\":\"${sheet_id}\",\"majorDimension\":\"COLUMNS\",\"length\":1}}")"
  else
    resp2="$(feishu_api_json "POST" \
      "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/insert_dimension_range" \
      "$token" \
      "{\"dimension\":{\"sheetId\":\"${sheet_id}\",\"majorDimension\":\"COLUMNS\",\"startIndex\":${value},\"endIndex\":$((value + 1))},\"inheritStyle\":\"BEFORE\"}")"
  fi
  python3 - "$resp2" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"add component column failed: {data}")
PY

  cell="$(python3 - "$value" <<'PY'
import sys

n = int(sys.argv[1]) + 1
out = ""
while n > 0:
    n, rem = divmod(n - 1, 26)
    out = chr(ord("A") + rem) + out
print(out)
PY
)"
  write_cell "$token" "$sheet_id" "${cell}1" "$component" >/dev/null
  write_cell "$token" "$sheet_id" "${cell}2" "$repository" >/dev/null
  echo "$cell"
}

find_date_row() {
  local token="$1"
  local sheet_id="$2"
  local target_date="$3"
  local resp

  resp="$(get_range_values "$token" "${sheet_id}!A4:A2000")"
  python3 - "$target_date" "$resp" <<'PY'
import json
import sys

target, resp = sys.argv[1], sys.argv[2]
data = json.loads(resp)
if data.get("code") != 0:
    raise SystemExit(f"read date column failed: {data}")
values = data.get("data", {}).get("valueRange", {}).get("values", [])
for index, row in enumerate(values, start=4):
    if row and str(row[0]).strip() == target:
        print(index)
        raise SystemExit(0)
print("")
PY
}

prepend_date_row() {
  local token="$1"
  local sheet_id="$2"
  local today="$3"
  local resp

  resp="$(feishu_api_json "POST" \
    "https://open.feishu.cn/open-apis/sheets/v2/spreadsheets/${FEISHU_SPREADSHEET_TOKEN}/values_prepend" \
    "$token" \
    "{\"valueRange\":{\"range\":\"${sheet_id}!A4:A4\",\"values\":[[\"${today}\"]]}}")"

  python3 - "$resp" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if data.get("code") != 0:
    raise SystemExit(f"prepend_date_row failed: {data}")
PY
}

usage() {
  cat <<'EOF'
Usage:
  ./docker/build_images.sh [amd|arm]
  ./docker/build_images.sh --profile [amd|arm]
  ./docker/build_images.sh --sheet ARM_with_cuda
  ./docker/build_images.sh --no-push --no-feishu

Default sheets:
  amd -> AMD_with_cuda, AMD_with_mxn100
  arm -> l4t, ARM_without_cuda, ARM_with_cuda, thor_spark, SOPHON_bm1688
EOF
}

PROFILE="$(detect_profile)"
TARGET_SHEETS=()
PUSH_IMAGE=1
UPDATE_FEISHU=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    amd|arm)
      PROFILE="$1"
      shift
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --sheet)
      TARGET_SHEETS+=("${2:-}")
      shift 2
      ;;
    --no-push)
      PUSH_IMAGE=0
      shift
      ;;
    --no-feishu)
      UPDATE_FEISHU=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$PROFILE" == "amd" || "$PROFILE" == "arm" ]] || die "profile must be amd or arm"
if [[ ${#TARGET_SHEETS[@]} -eq 0 ]]; then
  if [[ "$PROFILE" == "amd" ]]; then
    TARGET_SHEETS=("${AMD_SHEETS[@]}")
  else
    TARGET_SHEETS=("${ARM_SHEETS[@]}")
  fi
fi

for sheet in "${TARGET_SHEETS[@]}"; do
  if [[ "$PROFILE" == "amd" ]]; then
    contains "$sheet" "${AMD_SHEETS[@]}" || die "invalid amd sheet: $sheet"
  else
    contains "$sheet" "${ARM_SHEETS[@]}" || die "invalid arm sheet: $sheet"
  fi
done

DOCKERFILE="docker/Dockerfile"
PLATFORM="${PROFILE_TO_PLATFORM[$PROFILE]}"
DATE="$(date +%Y%m%d)"
VERSION="$(tr -d '[:space:]' < ictrek.app/VERSION)"
TAG="${PROFILE}_${VERSION}_${DATE}"
IMAGE_REPOSITORY="${SWR_REGISTRY}/${IMG_NAME}"
IMAGE_URI="${IMAGE_REPOSITORY}:${TAG}"

require_cmd docker
require_cmd python3
[[ "$UPDATE_FEISHU" -eq 0 ]] || require_cmd curl
[[ -f "$DOCKERFILE" ]] || die "Dockerfile not found: $DOCKERFILE"

log "PROFILE=${PROFILE}"
log "PLATFORM=${PLATFORM}"
log "DOCKERFILE=${DOCKERFILE}"
log "TARGET_SHEETS=${TARGET_SHEETS[*]}"
log "IMAGE_URI=${IMAGE_URI}"

DOCKER_BUILDKIT=1 docker build \
  --platform "$PLATFORM" \
  -t "$IMG_NAME" \
  -t "$IMAGE_URI" \
  -f "$DOCKERFILE" .

if [[ "$PUSH_IMAGE" -eq 1 ]]; then
  docker push "$IMAGE_URI"
  log "Docker push succeeded: ${IMAGE_URI}"
else
  log "Skip docker push: ${IMAGE_URI}"
fi

if [[ "$UPDATE_FEISHU" -eq 0 ]]; then
  log "Skip Feishu update"
  exit 0
fi

[[ -f "$FEISHU_CONFIG_FILE" ]] || die "Feishu config not found: $FEISHU_CONFIG_FILE"
FEISHU_APP_ID="$(read_feishu_field "feishu_app_id")"
FEISHU_APP_SECRET="$(read_feishu_field "feishu_app_secret")"
[[ -n "$FEISHU_APP_ID" && -n "$FEISHU_APP_SECRET" ]] || die "feishu_app_id or feishu_app_secret missing in $FEISHU_CONFIG_FILE"

for sheet in "${TARGET_SHEETS[@]}"; do
  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  SHEET_ID="$(get_sheet_id_by_title "$FEISHU_TOKEN" "$sheet")"
  log "Resolved sheet: ${sheet} -> ${SHEET_ID}"

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  COMPONENT_COL="$(find_component_column_letter "$FEISHU_TOKEN" "$SHEET_ID" "$COMPONENT_NAME" "$IMAGE_REPOSITORY")"
  log "Resolved component column: ${COMPONENT_NAME} -> ${COMPONENT_COL}"

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  write_cell "$FEISHU_TOKEN" "$SHEET_ID" "${COMPONENT_COL}1" "$COMPONENT_NAME" >/dev/null
  write_cell "$FEISHU_TOKEN" "$SHEET_ID" "${COMPONENT_COL}2" "$IMAGE_REPOSITORY" >/dev/null

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  DATE_ROW="$(find_date_row "$FEISHU_TOKEN" "$SHEET_ID" "$DATE")"
  if [[ -z "$DATE_ROW" ]]; then
    log "Date ${DATE} not found, creating a new row at top of data area"
    FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
    prepend_date_row "$FEISHU_TOKEN" "$SHEET_ID" "$DATE" >/dev/null
    DATE_ROW=4
  else
    log "Date ${DATE} already exists at row ${DATE_ROW}"
  fi

  FEISHU_TOKEN="$(get_feishu_token "$FEISHU_APP_ID" "$FEISHU_APP_SECRET")"
  write_cell "$FEISHU_TOKEN" "$SHEET_ID" "${COMPONENT_COL}${DATE_ROW}" "$TAG" >/dev/null
  log "Feishu updated: ${sheet}!${COMPONENT_COL}${DATE_ROW} = ${TAG}"
done
