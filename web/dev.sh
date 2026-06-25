#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if command -v python3 >/dev/null 2>&1; then
  exec python3 server.py "$@"
fi

if command -v node >/dev/null 2>&1; then
  exec node server.js "$@"
fi

if command -v bun >/dev/null 2>&1; then
  exec bun server.js "$@"
fi

echo "Missing runtime: install Python 3, Node.js, or Bun first." >&2
exit 1
