#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL_SCRIPT="$SCRIPT_DIR/dworkers_setup.sh"
REMOTE_SCRIPT="https://raw.githubusercontent.com/huluxiaohuowa/cc_setup/main/dworkers_setup.sh"
REMOTE_SCRIPT_FAST="https://ghfast.top/${REMOTE_SCRIPT}"

if [[ -x "$LOCAL_SCRIPT" ]]; then
  exec bash "$LOCAL_SCRIPT" "$@"
fi

exec bash <(curl -LfsS "$REMOTE_SCRIPT" || curl -LfsS "$REMOTE_SCRIPT_FAST") "$@"
