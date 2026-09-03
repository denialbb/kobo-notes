#!/usr/bin/env python3
"""
Herdr Worker Progress Status Board
Renders a compact, live terminal view of all worker progress files in .herdr/status/
Designed for narrow vertical split panes in Herdr.
"""

import argparse
import datetime
import glob
import json
import os
import shutil
import sys
import time

# ANSI Color codes
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
RED = "\033[31m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
WHITE = "\033[37m"
GRAY = "\033[90m"

PHASE_COLORS = {
    "planning": BLUE,
    "implementation": CYAN,
    "testing": MAGENTA,
    "review": YELLOW,
    "done": GREEN,
    "completed": GREEN,
    "blocked": RED,
    "idle": GRAY,
}

STATUS_ICONS = {
    "done": (GREEN, "✓"),
    "in_progress": (YELLOW, "→"),
    "blocked": (RED, "!"),
    "todo": (GRAY, "·"),
}


def strip_ansi(text: str) -> str:
    import re
    return re.sub(r"\033\[[0-9;]*m", "", text)


def render_progress_bar(progress: float, width: int = 10) -> str:
    clamped = max(0.0, min(1.0, progress))
    filled = int(round(clamped * width))
    bar = "█" * filled + "░" * (width - filled)
    return bar


def format_relative_time(iso_str: str) -> str:
    if not iso_str:
        return "unknown"
    try:
        # Handle 'Z' suffix or tz offset
        iso_clean = iso_str.replace("Z", "+00:00")
        dt = datetime.datetime.fromisoformat(iso_clean)
        # Convert to local or compare naive/aware
        now = datetime.datetime.now(datetime.timezone.utc) if dt.tzinfo else datetime.datetime.now()
        delta = now - dt
        seconds = int(delta.total_seconds())
        if seconds < 5:
            return "just now"
        elif seconds < 60:
            return f"{seconds}s ago"
        elif seconds < 3600:
            return f"{seconds // 60}m ago"
        else:
            return f"{seconds // 3600}h ago"
    except Exception:
        # Return last 8 chars if it's like a time or truncated ISO
        return iso_str[:19].replace("T", " ")


def truncate_line(text: str, max_width: int) -> str:
    if max_width <= 3:
        return text[:max_width]
    visible_len = len(strip_ansi(text))
    if visible_len <= max_width:
        return text
    # Truncate visible chars while keeping ANSI if possible, or simpler: strip ANSI truncation
    plain = strip_ansi(text)
    return plain[: max_width - 1] + "…"


def load_worker_files(status_dir: str):
    workers = []
    pattern = os.path.join(status_dir, "*.json")
    for filepath in sorted(glob.glob(pattern)):
        basename = os.path.basename(filepath)
        if basename == "template.json" or basename.endswith(".tmp"):
            continue
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    data["_filepath"] = filepath
                    workers.append(data)
        except Exception:
            # File might be mid-write; skip this tick
            continue
    return workers


def render_board(status_dir: str, no_color: bool = False) -> str:
    cols = shutil.get_terminal_size((40, 20)).columns
    workers = load_worker_files(status_dir)

    def c(color_code: str, text: str) -> str:
        if no_color:
            return text
        return f"{color_code}{text}{RESET}"

    lines = []

    # Header
    now_str = datetime.datetime.now().strftime("%H:%M:%S")
    header_text = f"=== Herdr Workers ({len(workers)}) ==="
    lines.append(c(BOLD + CYAN, header_text.center(min(cols, 60))))
    lines.append(c(GRAY, f"Updated: {now_str}".center(min(cols, 60))))
    lines.append(c(GRAY, "─" * min(cols, 60)))

    if not workers:
        lines.append("")
        lines.append(c(YELLOW, "  No active workers found."))
        lines.append(c(GRAY, f"  Watching: {status_dir}/*.json"))
        lines.append("")
        return "\n".join(lines)

    for i, w in enumerate(workers):
        if i > 0:
            lines.append(c(GRAY, "┄" * min(cols, 60)))

        worker_id = str(w.get("worker_id", "unknown"))
        phase = str(w.get("phase", "idle")).lower()
        phase_color = PHASE_COLORS.get(phase, WHITE)

        # Progress calculation
        progress_val = w.get("progress")
        todos = w.get("todos", [])
        if progress_val is None:
            if todos:
                done_count = sum(1 for t in todos if t.get("status") == "done")
                progress_val = done_count / len(todos)
            else:
                progress_val = 0.0
        else:
            try:
                progress_val = float(progress_val)
            except (ValueError, TypeError):
                progress_val = 0.0

        percent = int(round(progress_val * 100))
        label = w.get("progress_label") or f"{percent}%"
        bar = render_progress_bar(progress_val, width=8)

        # Worker title line
        bar_str = c(GREEN if percent == 100 else CYAN, f"[{bar}] {label}")
        phase_badge = c(BOLD + phase_color, f"[{phase.upper()}]")
        worker_title = f"▸ {c(BOLD + WHITE, worker_id)} {phase_badge} {bar_str}"
        lines.append(worker_title)

        # Task
        task = w.get("task", "").strip()
        if task:
            lines.append(f"  {c(BOLD, 'Task:')} {task}")

        # Todos
        if todos:
            for t in todos:
                t_status = str(t.get("status", "todo")).lower()
                icon_color, icon_char = STATUS_ICONS.get(t_status, (GRAY, "·"))
                t_text = str(t.get("text", "")).strip()
                line = f"   {c(icon_color, icon_char)} {t_text}"
                lines.append(line)

        # Notes
        notes = w.get("notes", "").strip()
        if notes:
            lines.append(f"  {c(GRAY, 'Note:')} {c(DIM, notes)}")

        # Last updated
        last_update = w.get("last_update", "")
        if last_update:
            rel = format_relative_time(last_update)
            lines.append(f"  {c(GRAY, f'Last ping: {rel}')}")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Herdr Worker Status Board")
    parser.add_argument(
        "--dir", "-d",
        default=".herdr/status",
        help="Path to status files directory (default: .herdr/status)"
    )
    parser.add_argument(
        "--interval", "-i",
        type=float,
        default=3.0,
        help="Refresh interval in seconds (default: 3.0)"
    )
    parser.add_argument(
        "--once", "-1",
        action="store_true",
        help="Render board once and exit"
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI color output"
    )
    args = parser.parse_args()

    status_dir = os.path.abspath(args.dir)

    if args.once or not sys.stdout.isatty():
        output = render_board(status_dir, no_color=args.no_color or not sys.stdout.isatty())
        print(output)
        return

    # Interactive continuous loop
    # Hide cursor
    sys.stdout.write("\033[?25l")
    sys.stdout.flush()

    try:
        while True:
            # Clear screen and move cursor to top-left
            sys.stdout.write("\033[2J\033[H")
            output = render_board(status_dir, no_color=args.no_color)
            sys.stdout.write(output + "\n")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        # Show cursor
        sys.stdout.write("\033[?25h\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
