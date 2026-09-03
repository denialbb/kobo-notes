#!/usr/bin/env bash
# status-board.sh – run this in the Herdr status pane
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(which python3 2>/dev/null || true)"

if [[ -n "$PYTHON_BIN" ]]; then
  exec "$PYTHON_BIN" "$SCRIPT_DIR/status_board.py" "$@"
fi

# Fallback: pure bash + jq if python3 is unavailable
STATUS_DIR="${1:-.herdr/status}"

while true; do
  clear
  echo "=== Worker Progress ==="
  echo
  found=0
  for f in "$STATUS_DIR"/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [[ "$base" == "template.json" ]] && continue
    found=1
    jq -r '
      "▸ \(.worker_id)  [\(.progress_label // ((.progress // 0)*100|floor|tostring + "%"))]",
      "  \(.task // "")",
      ((.todos // [])[] | "  \(if .status=="done" then "✓" elif .status=="in_progress" then "→" elif .status=="blocked" then "!" else "·" end) \(.text)"),
      (if .notes and (.notes != "") then "  Note: \(.notes)" else empty end),
      ""
    ' "$f" 2>/dev/null || true
  done
  if [[ $found -eq 0 ]]; then
    echo "  No active workers found in $STATUS_DIR"
  fi
  sleep 3
done
