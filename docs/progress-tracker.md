**The most practical approach is a dedicated status pane (vertical split) next to the orchestrator, driven by shared progress files that each AGY worker updates, combined with Herdr’s native agent state and metadata reporting.**

Herdr already provides an excellent global sidebar for agent lifecycle state (`working` / `blocked` / `done` / `idle`). It does not natively surface per-worker todo lists or fine-grained development progress. A status pane solves this cleanly while remaining fully within the Herdr model.

### Recommended Layout

In the orchestrator’s tab:

- Keep the orchestrator AGY as the main pane.
- Create a vertical split (right side preferred) for a narrow status pane.
- Run a lightweight watcher script in that pane that continuously renders a compact board of every worker’s todo list and current progress.

This gives an at-a-glance view without leaving the orchestrator tab. Workers stay in their own tabs (as you already have them).

### How Each AGY Worker Tracks Progress

Workers must write structured, machine-readable progress. The cleanest pattern is a shared directory of status files (one per worker) that the status pane reads.

1. **Define a simple status format** (JSON recommended for reliability):

   ```json
   {
     "worker_id": "worker-api",
     "task": "Implement FastAPI user endpoints",
     "phase": "implementation",
     "progress": 0.65,
     "progress_label": "3/5 endpoints + tests",
     "todos": [
       { "id": "1", "text": "POST /users", "status": "done" },
       { "id": "2", "text": "GET /users/{id}", "status": "in_progress" },
       { "id": "3", "text": "Unit tests", "status": "todo" },
       { "id": "4", "text": "Integration tests", "status": "todo" }
     ],
     "last_update": "2026-09-03T00:12:00Z",
     "notes": "Auth middleware complete"
   }
   ```

2. **Instruct every worker AGY** (in its system prompt / skill / initial brief) to:
   - Maintain a local todo list for its assigned work.
   - On every significant state change (todo completed, phase advanced, blocked, etc.), rewrite its status file atomically.
   - Optionally also call Herdr’s reporting API so the global sidebar stays rich:
     ```bash
     herdr pane report-agent "$HERDR_PANE_ID" \
       --source custom:agy-worker \
       --state working \
       --message "3/5 endpoints done"
     herdr pane report-metadata "$HERDR_PANE_ID" \
       --source custom:agy-worker \
       --token summary="API 65%" \
       --token task="user endpoints"
     ```

3. **Place the files** in a well-known location relative to the project, for example:
   ```
   .herdr/status/
     worker-api.json
     worker-frontend.json
     worker-tests.json
   ```
   (Git-ignore the directory if desired.)

### Scripts and Skills Required

| Component                                                                 | Purpose                                              | Notes                                                                                                                     |
| ------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Worker skill / prompt instructions**                                    | Force each AGY to maintain and write the status file | Put this in the worker’s system prompt or a dedicated skill that every worker loads.                                      |
| **Status watcher script** (`status-board.sh` or a small Python/Node tool) | Continuously renders the board in the status pane    | Reads all `*.json` files, formats a compact vertical board, refreshes every 2–5 s.                                        |
| **Optional Herdr plugin**                                                 | More polished long-term solution                     | A small plugin that opens a persistent status pane and refreshes via the socket API. Not required for a working solution. |
| **Orchestrator helper**                                                   | Spawn workers + create the status pane               | Simple shell or skill that does `herdr pane split … --direction right`, starts the watcher, and records worker IDs.       |

Minimal watcher sketch (bash + `jq`):

```bash
#!/usr/bin/env bash
# status-board.sh – run this in the status pane
STATUS_DIR=".herdr/status"
while true; do
  clear
  echo "=== Worker Progress ==="
  echo
  for f in "$STATUS_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -r '
      "▸ \(.worker_id)  [\(.progress_label // (.progress*100|floor|tostring + "%"))]",
      "  \(.task)",
      (.todos[] | "  \(if .status=="done" then "✓" elif .status=="in_progress" then "→" else "·" end) \(.text)"),
      ""
    ' "$f"
  done
  sleep 3
done
```

### Putting It Together – Practical Steps

1. Create the status directory and a template status file.
2. Update the worker AGY prompt/skill so every worker writes/updates its own JSON file and (optionally) reports metadata to Herdr.
3. From the orchestrator tab, create the vertical split and start the watcher:
   ```bash
   herdr pane split --current --direction right --ratio 0.28 --no-focus
   # then in the new pane:
   ./scripts/status-board.sh
   ```
4. When spawning a worker, pass it its `worker_id` and the path to its status file so it knows exactly where to write.
5. (Optional but recommended) Configure the Herdr sidebar to surface the custom tokens:
   ```toml
   [ui.sidebar.agents]
   rows = [
     ["state_icon", "workspace", "tab"],
     ["$summary", "$task"]
   ]
   ```
   Then reload config with `herdr server reload-config`.

### Why This Approach Is Best

- Fully visible inside the orchestrator’s own tab (exactly the vertical side-panel you requested).
- Works with pure AGY workers; no dependency on a specific orchestration plugin.
- Leverages Herdr’s existing strengths (agent state, metadata tokens, pane splitting) instead of fighting them.
- Status files are durable, easy to inspect, and can be extended later (e.g., feed a web dashboard or another agent).
- Extremely low overhead.

If you later want a more polished solution, several community plugins already explore similar ideas (task boards, git status in the sidebar, custom metadata). The file-based board above, however, is the fastest reliable path that matches your current layout of one orchestrator AGY + multiple AGY workers in separate tabs.
