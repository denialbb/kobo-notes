#!/usr/bin/env bash
# update-progress.sh – worker helper to update progress in .herdr/status/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(which python3 2>/dev/null || true)"

if [[ -n "$PYTHON_BIN" ]]; then
  exec "$PYTHON_BIN" "$SCRIPT_DIR/update_progress.py" "$@"
fi

echo "[ERROR] python3 is required to run update-progress.sh" >&2
exit 1
