#!/usr/bin/env python3
"""
CLI tool to initialize and update AGY worker progress status files.
Updates .herdr/status/<worker_id>.json atomically and optionally notifies Herdr.
"""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys


def get_status_path(status_dir: str, worker_id: str) -> str:
    return os.path.join(status_dir, f"{worker_id}.json")


def load_status(path: str, default_worker_id: str) -> dict:
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
        except Exception:
            pass
    return {
        "worker_id": default_worker_id,
        "task": "",
        "phase": "planning",
        "progress": 0.0,
        "progress_label": "0/0",
        "todos": [],
        "last_update": "",
        "notes": "",
    }


def save_status_atomically(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data["last_update"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, path)


def recalculate_progress_if_needed(data: dict) -> None:
    todos = data.get("todos", [])
    if todos:
        done_count = sum(1 for t in todos if t.get("status") == "done")
        total = len(todos)
        progress = round(done_count / total, 2)
        data["progress"] = progress
        data["progress_label"] = f"{done_count}/{total} done"


def report_to_herdr(pane_id: str, data: dict) -> None:
    if not pane_id or not shutil.which("herdr"):
        return

    phase = data.get("phase", "implementation").lower()
    if phase in ("done", "completed"):
        herdr_state = "done"
    elif phase == "blocked":
        herdr_state = "blocked"
    else:
        herdr_state = "working"

    summary = data.get("progress_label") or f"{int(round(data.get('progress', 0.0) * 100))}%"
    task = data.get("task", "")
    message = data.get("notes") or f"{summary} ({task})" if task else summary

    try:
        subprocess.run(
            [
                "herdr", "pane", "report-agent", pane_id,
                "--source", "custom:agy-worker",
                "--state", herdr_state,
                "--message", message[:80],
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        subprocess.run(
            [
                "herdr", "pane", "report-metadata", pane_id,
                "--source", "custom:agy-worker",
                "--token", f"summary={summary[:20]}",
                "--token", f"task={task[:40]}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        pass


def cmd_init(args):
    path = get_status_path(args.dir, args.worker_id)
    todos = []
    if args.todos:
        for idx, text in enumerate(args.todos, start=1):
            todos.append({"id": str(idx), "text": text, "status": "todo"})

    data = {
        "worker_id": args.worker_id,
        "task": args.task or "",
        "phase": args.phase or "planning",
        "progress": 0.0,
        "progress_label": f"0/{len(todos)} done" if todos else "0%",
        "todos": todos,
        "last_update": "",
        "notes": args.notes or "",
    }
    save_status_atomically(path, data)
    print(f"[OK] Initialized status for '{args.worker_id}' at {path}")
    if not args.no_herdr:
        report_to_herdr(args.pane_id, data)


def cmd_set(args):
    path = get_status_path(args.dir, args.worker_id)
    data = load_status(path, args.worker_id)

    if args.task is not None:
        data["task"] = args.task
    if args.phase is not None:
        data["phase"] = args.phase
    if args.progress is not None:
        data["progress"] = max(0.0, min(1.0, args.progress))
    if args.progress_label is not None:
        data["progress_label"] = args.progress_label
    if args.notes is not None:
        data["notes"] = args.notes

    if args.progress is None and args.progress_label is None:
        recalculate_progress_if_needed(data)

    save_status_atomically(path, data)
    print(f"[OK] Updated status for '{args.worker_id}': phase={data.get('phase')}, progress={data.get('progress')}")
    if not args.no_herdr:
        report_to_herdr(args.pane_id, data)


def cmd_todo(args):
    path = get_status_path(args.dir, args.worker_id)
    data = load_status(path, args.worker_id)
    todos = data.setdefault("todos", [])

    matched = False
    for t in todos:
        if (args.id and str(t.get("id")) == str(args.id)) or (args.text and args.text.lower() in str(t.get("text", "")).lower()):
            t["status"] = args.status
            matched = True
            print(f"[OK] Set todo #{t.get('id')} '{t.get('text')}' to '{args.status}'")
            break

    if not matched:
        print(f"[WARN] No matching todo found for ID='{args.id}' or text='{args.text}'")
        return

    recalculate_progress_if_needed(data)
    if args.notes is not None:
        data["notes"] = args.notes

    save_status_atomically(path, data)
    if not args.no_herdr:
        report_to_herdr(args.pane_id, data)


def cmd_add_todo(args):
    path = get_status_path(args.dir, args.worker_id)
    data = load_status(path, args.worker_id)
    todos = data.setdefault("todos", [])

    new_id = str(len(todos) + 1)
    todos.append({"id": new_id, "text": args.text, "status": args.status or "todo"})
    recalculate_progress_if_needed(data)

    save_status_atomically(path, data)
    print(f"[OK] Added todo #{new_id} '{args.text}' for '{args.worker_id}'")
    if not args.no_herdr:
        report_to_herdr(args.pane_id, data)


def cmd_done(args):
    path = get_status_path(args.dir, args.worker_id)
    data = load_status(path, args.worker_id)
    data["phase"] = "done"
    data["progress"] = 1.0
    data["progress_label"] = args.progress_label or "Completed"
    for t in data.get("todos", []):
        if t.get("status") != "done":
            t["status"] = "done"
    if args.notes is not None:
        data["notes"] = args.notes

    save_status_atomically(path, data)
    print(f"[OK] Marked '{args.worker_id}' as DONE")
    if not args.no_herdr:
        report_to_herdr(args.pane_id, data)


def cmd_blocked(args):
    path = get_status_path(args.dir, args.worker_id)
    data = load_status(path, args.worker_id)
    data["phase"] = "blocked"
    if args.reason:
        data["notes"] = f"BLOCKED: {args.reason}"

    save_status_atomically(path, data)
    print(f"[OK] Marked '{args.worker_id}' as BLOCKED: {args.reason or 'No reason provided'}")
    if not args.no_herdr:
        report_to_herdr(args.pane_id, data)


def main():
    parser = argparse.ArgumentParser(description="Update AGY worker status")
    parser.add_argument("--dir", "-d", default=".herdr/status", help="Status directory")
    parser.add_argument("--worker-id", "-w", required=True, help="Worker ID")
    parser.add_argument("--pane-id", default=os.environ.get("HERDR_PANE_ID", ""), help="Herdr pane ID")
    parser.add_argument("--no-herdr", action="store_true", help="Skip reporting to Herdr API")

    subparsers = parser.add_subparsers(dest="command", required=True)

    # init
    p_init = subparsers.add_parser("init", help="Initialize status file")
    p_init.add_argument("--task", "-t", required=True, help="Task description")
    p_init.add_argument("--phase", default="planning", help="Initial phase (planning, implementation, etc.)")
    p_init.add_argument("--todos", nargs="*", help="Initial todo items")
    p_init.add_argument("--notes", help="Initial notes")
    p_init.set_defaults(func=cmd_init)

    # set
    p_set = subparsers.add_parser("set", help="Set fields directly")
    p_set.add_argument("--task", help="Task description")
    p_set.add_argument("--phase", help="Phase (planning, implementation, testing, done, blocked)")
    p_set.add_argument("--progress", type=float, help="Progress (0.0 - 1.0)")
    p_set.add_argument("--progress-label", help="Progress label (e.g. '3/5 endpoints')")
    p_set.add_argument("--notes", help="Notes / current state")
    p_set.set_defaults(func=cmd_set)

    # todo
    p_todo = subparsers.add_parser("todo", help="Update a specific todo item")
    p_todo.add_argument("--id", help="Todo ID")
    p_todo.add_argument("--text", help="Substring match on todo text")
    p_todo.add_argument("--status", choices=["todo", "in_progress", "done", "blocked"], required=True, help="New status")
    p_todo.add_argument("--notes", help="Optional note to attach")
    p_todo.set_defaults(func=cmd_todo)

    # add-todo
    p_add = subparsers.add_parser("add-todo", help="Add a new todo item")
    p_add.add_argument("--text", required=True, help="Todo text")
    p_add.add_argument("--status", choices=["todo", "in_progress", "done", "blocked"], default="todo", help="Initial status")
    p_add.set_defaults(func=cmd_add_todo)

    # done
    p_done = subparsers.add_parser("done", help="Mark worker as completed")
    p_done.add_argument("--progress-label", default="Completed", help="Custom completion label")
    p_done.add_argument("--notes", help="Final notes / summary")
    p_done.set_defaults(func=cmd_done)

    # blocked
    p_blocked = subparsers.add_parser("blocked", help="Mark worker as blocked")
    p_blocked.add_argument("--reason", required=True, help="Blocker explanation")
    p_blocked.set_defaults(func=cmd_blocked)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
