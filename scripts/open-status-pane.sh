#!/usr/bin/env bash
# open-status-pane.sh – orchestrator helper to create a vertical status pane in Herdr
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIRECTION="${1:-right}"
RATIO="${2:-0.28}"

mkdir -p "$REPO_ROOT/.herdr/status"

if ! command -v herdr >/dev/null 2>&1; then
  echo "[WARN] 'herdr' CLI not found on PATH."
  echo "You can run the status board manually in any terminal split:"
  echo "  $REPO_ROOT/scripts/status-board.sh"
  exit 1
fi

echo "Creating Herdr vertical split (direction: $DIRECTION, ratio: $RATIO)..."
SPLIT_OUTPUT=$(herdr pane split --current --direction "$DIRECTION" --ratio "$RATIO" --cwd "$REPO_ROOT" --no-focus 2>&1 || true)

# Extract pane_id from JSON output
PANE_ID=""
if command -v jq >/dev/null 2>&1; then
  PANE_ID=$(echo "$SPLIT_OUTPUT" | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi

if [[ -z "$PANE_ID" ]]; then
  # Fallback regex extraction
  PANE_ID=$(echo "$SPLIT_OUTPUT" | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
fi

if [[ -n "$PANE_ID" ]]; then
  echo "Created pane: $PANE_ID"
  echo "Launching status board in pane $PANE_ID..."
  herdr pane run "$PANE_ID" "$REPO_ROOT/scripts/status-board.sh"
  echo "[OK] Status pane running in $PANE_ID"
else
  echo "[NOTICE] Could not automatically split pane via Herdr (not in an active Herdr session or server not responding)."
  echo "Herdr output: $SPLIT_OUTPUT"
  echo
  echo "To run the status board manually, open a pane split and run:"
  echo "  $REPO_ROOT/scripts/status-board.sh"
fi
