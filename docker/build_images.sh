#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# agent-room build script
# Builds agent-room Docker image tagged for SWR (local only, no push).
#
# Usage:
#   ./build_images.sh                                    # build agent-room only
#   ./build_images.sh --component agent-room             # same as above
#   ./build_images.sh --component agent-room --tag v1.0  # custom version tag
#
# Legacy model-hub components (backend / frontend) are kept for backward
# compatibility but are no longer the primary target.
# =============================================================================

cd "$(dirname "$0")"

# ---- Registry & naming ----
SWR_REGISTRY="swr.cn-southwest-2.myhuaweicloud.com/ictrek"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# ---- Architecture detection ----
case "$(uname -m)" in
  x86_64|amd64) ARCH_TAG="amd" ;;
  aarch64|arm64) ARCH_TAG="arm" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# ---- Parse args ----
COMPONENTS=()
CUSTOM_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component)
      COMPONENTS+=("$2")
      shift 2
      ;;
    --tag)
      CUSTOM_TAG="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  ./build_images.sh                                    # build agent-room
  ./build_images.sh --component agent-room --tag v1.0  # custom version tag

Options:
  --component <name>   Build a specific component (agent-room, backend, frontend)
  --tag <string>       Override the default version tag
  -h, --help           Show this help
EOF
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
  COMPONENTS=("agent-room")
fi

for component in "${COMPONENTS[@]}"; do
  case "$component" in
    agent-room|backend|frontend) ;;
    *) die "unsupported component: $component" ;;
  esac
done

# ---- Build args (proxy) ----
BUILD_ARGS=()
if [[ -n "${PROXY:-}" ]]; then
  log "Using PROXY=${PROXY}"
  BUILD_ARGS+=(--build-arg "PROXY=${PROXY}")
fi

# ---- Tag calculation ----
DATE=$(date +%Y%m%d)
if [[ -n "$CUSTOM_TAG" ]]; then
  TAG="${ARCH_TAG}_${CUSTOM_TAG}"
elif [[ -f "../VERSION" ]]; then
  VERSION=$(tr -d " \t\n\r" < ../VERSION)
  TAG="${ARCH_TAG}_${VERSION}_${DATE}"
else
  TAG="${ARCH_TAG}_${DATE}"
fi

require_cmd docker

log "Architecture: ${ARCH_TAG}"
log "Tag: ${TAG}"
log "Registry: ${SWR_REGISTRY}"

# ---- Build ----
for component in "${COMPONENTS[@]}"; do
  case "$component" in
    agent-room)
      log "Building ${SWR_REGISTRY}/agent-room:${TAG}"
      docker build \
        "${BUILD_ARGS[@]}" \
        -t "${SWR_REGISTRY}/agent-room:${TAG}" \
        -t "${SWR_REGISTRY}/agent-room:latest" \
        -f Dockerfile \
        ..
      log "Done: ${SWR_REGISTRY}/agent-room:${TAG}"
      ;;

    backend)
      log "[legacy] Building model-hub-backend:${TAG}"
      docker build \
        "${BUILD_ARGS[@]}" \
        -t "model-hub-backend:${TAG}" \
        -f Dockerfile \
        ..
      ;;

    frontend)
      log "[legacy] Building model-hub-frontend:${TAG}"
      docker build \
        -t "model-hub-frontend:${TAG}" \
        -f ../frontend/Dockerfile \
        ..
      ;;
  esac
done

log "All done."
