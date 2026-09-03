---
name: progress-tracker
description: >-
  Track, update, and report worker task progress via structured JSON status files and Herdr pane metadata for the orchestrator status board. Use whenever an agent is assigned a multi-step task, or when setting up the orchestrator status board.
---

# Herdr Worker Progress Tracker

This skill defines the structured progress-reporting protocol between AGY worker agents and the orchestrator status board in Herdr, as specified in [progress-tracker.md](file:///home/denial/Projects/kobo-notes/docs/progress-tracker.md).

---

## 1. Overview & Layout

- **Orchestrator Pane**: Runs the coordinator agent.
- **Status Pane**: A narrow vertical split (~28% ratio) running `scripts/status-board.sh`.
- **Worker Tabs/Panes**: AGY workers operating in parallel, each maintaining its own status file under `.herdr/status/<worker_id>.json`.
- **Global Sidebar**: Herdr agent state (`working`, `blocked`, `done`) and metadata tokens (`$summary`, `$task`).

---

## 2. Worker Status File Schema

Each worker maintains `.herdr/status/<worker_id>.json`:

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
  "last_update": "2026-09-03T12:00:00Z",
  "notes": "Auth middleware complete"
}
```

### Supported Phases
- `planning`: Scoping task, listing requirements and todos.
- `implementation`: Actively writing code / features.
- `testing`: Running unit, regression, or integration tests.
- `review`: Verifying diffs and edge cases.
- `done`: Task fully finished and verified.
- `blocked`: Waiting on dependencies or external feedback.

### Supported Todo Statuses
- `todo`: Pending work (renders as `·`).
- `in_progress`: Actively being worked on (renders as yellow `→`).
- `done`: Completed (renders as green `✓`).
- `blocked`: Stuck or waiting (renders as red `!`).

---

## 3. Worker Protocol (How AGY Workers Report Progress)

Workers should update their status at every state transition. Use the helper script `./scripts/update-progress.sh`:

### 1. Initialize Task
When starting an assigned task:
```bash
./scripts/update-progress.sh --worker-id "$WORKER_ID" init \
  --task "Implement parser and discovery tests" \
  --todos "Write unit tests" "Implement discovery logic" "Run test suite"
```

### 2. Update Active Item
When starting work on a subtask:
```bash
./scripts/update-progress.sh --worker-id "$WORKER_ID" todo \
  --text "Write unit tests" --status in_progress
```

### 3. Complete an Item
When a subtask finishes (progress percentage updates automatically):
```bash
./scripts/update-progress.sh --worker-id "$WORKER_ID" todo \
  --text "Write unit tests" --status done
```

### 4. Add Dynamic / Newly Discovered Subtasks
```bash
./scripts/update-progress.sh --worker-id "$WORKER_ID" add-todo \
  --text "Fix edge case with empty frontmatter"
```

### 5. Report Blocker
If blocked or requiring orchestrator / user decision:
```bash
./scripts/update-progress.sh --worker-id "$WORKER_ID" blocked \
  --reason "Missing auth secret for GitHub API"
```

### 6. Mark Completion
When all work and tests are done:
```bash
./scripts/update-progress.sh --worker-id "$WORKER_ID" done \
  --notes "164 tests passing, zero lint regressions"
```

> [!NOTE]
> `update-progress.sh` writes status atomically (`.json.tmp.<pid>` -> `.json`).
> If `$HERDR_PANE_ID` is present in the environment, it automatically reports state (`working`, `blocked`, `done`) and metadata tokens (`summary`, `task`) to Herdr.

---

## 4. Orchestrator Setup

### Open the Status Pane
From the orchestrator pane:
```bash
./scripts/open-status-pane.sh
```
This performs `herdr pane split --current --direction right --ratio 0.28 --no-focus` and starts `scripts/status-board.sh` in the new pane.

### Inspect Status Programmatically
To inspect the board once without a continuous watch loop:
```bash
./scripts/status-board.sh --once
```

Or query worker JSON files directly:
```bash
cat .herdr/status/*.json | jq '{worker: .worker_id, progress: .progress_label, phase: .phase}'
```
