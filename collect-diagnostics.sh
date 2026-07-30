#!/bin/sh
# Pull every piece of debugging state off the Kobo into one timestamped folder,
# so an agent (or a human) can start diagnosing without touching the device.
#
# Usage:
#   ./collect-diagnostics.sh            # autodetect, collect, unmount if we mounted
#   KOBO_DEV=/dev/sdX ./collect-diagnostics.sh
#   ./collect-diagnostics.sh --keep-mounted
#
# Writes to diagnostics/<timestamp>/ and refreshes the diagnostics/latest symlink.
# Read diagnostics/latest/SUMMARY.md first — it is written for exactly that.
set -eu

. "$(dirname "$0")/kobo-lib.sh"

KEEP_MOUNTED=0
[ "${1:-}" = "--keep-mounted" ] && KEEP_MOUNTED=1

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="$REPO_DIR/diagnostics/$STAMP"

kobo_mount

mkdir -p "$OUT"
echo ""
echo "Collecting into $OUT"

# copy_in <source> <destination-name>  — best effort, never fatal.
copy_in() {
	if [ -e "$1" ]; then
		cp -r "$1" "$OUT/$2" 2>/dev/null && echo "  + $2" && return 0
	fi
	echo "  - $2 (absent)"
	return 0
}

# --- 1. KOReader's own log ---
copy_in "$KOBO_ROOT/crash.log" "crash.log"

# --- 2. Our plugin's preserved artifacts (written outside the wiped cache) ---
# These are the exact bytes handed to crengine, plus the report from main.lua.
mkdir -p "$OUT/markdownreader-debug"
for f in last.html last-converted.md last.log; do
	copy_in "$KOBO_ROOT/markdownreader-debug/$f" "markdownreader-debug/$f"
done
# The USB-visible copy, if the in-app menu action was used.
copy_in "$KOBO_MOUNT/markdownreader-debug" "markdownreader-debug-usb"

# --- 3. Generated HTML still sitting in the cache ---
# cleanCache() wipes this on every KOReader start, so it is only present if the
# device has not been restarted since the failure.
mkdir -p "$OUT/cache-md"
if [ -d "$KOBO_HTML_CACHE" ]; then
	find "$KOBO_HTML_CACHE" -maxdepth 1 -type f -exec cp {} "$OUT/cache-md/" \; 2>/dev/null || true
	echo "  + cache-md/ ($(find "$OUT/cache-md" -type f | wc -l) file(s))"
else
	echo "  - cache-md/ (absent)"
fi

# --- 4. The plugin sources actually on the device ---
# Device state drifts from the repo; past bugs were fixes that only ever existed
# on the Kobo and were lost on the next deploy.
mkdir -p "$OUT/plugins-on-device"
for p in markdownreader.koplugin syncnotes.koplugin; do
	copy_in "$KOBO_PLUGINS/$p" "plugins-on-device/$p"
done

# --- 5. Settings and environment ---
copy_in "$KOBO_ROOT/git-rev" "git-rev"
copy_in "$KOBO_ROOT/settings.reader.lua" "settings.reader.lua"
# Only the small .lua settings files. The settings dir also holds sqlite caches
# (bookinfo_cache.sqlite3 alone is ~25 MB) that are useless here and are the
# user's library metadata besides.
mkdir -p "$OUT/settings"
if [ -d "$KOBO_ROOT/settings" ]; then
	find "$KOBO_ROOT/settings" -maxdepth 1 -type f -name '*.lua' \
		-exec cp {} "$OUT/settings/" \; 2>/dev/null || true
	echo "  + settings/ ($(find "$OUT/settings" -type f | wc -l) .lua file(s))"
else
	echo "  - settings/ (absent)"
fi
# Never collect secrets/ — it holds the GitHub PAT.

# Redact credentials from anything collected. syncnotes stores the GitHub PAT
# in its settings file, and these bundles get pasted into issues and chats.
redact_tree() {
	find "$1" -type f \( -name '*.lua' -o -name '*.log' -o -name '*.txt' -o -name '*.md' \) \
		-exec sed -i -E \
		-e 's/(gh[pousr]_)[A-Za-z0-9]{10,}/\1<REDACTED>/g' \
		-e 's/(github_pat_)[A-Za-z0-9_]{10,}/\1<REDACTED>/g' \
		-e 's/(["'"'"']?(token|pat|password|secret|api_key)["'"'"']?[[:space:]]*=[[:space:]]*["'"'"'])[^"'"'"']{8,}/\1<REDACTED>/gI' \
		-e 's/(Authorization:[[:space:]]*(token|Bearer)[[:space:]]+)[^[:space:]"]+/\1<REDACTED>/gI' \
		{} + 2>/dev/null || true
}

# --- 6. Environment report ---
{
	echo "collected      : $(date '+%Y-%m-%d %H:%M:%S')"
	echo "host           : $(uname -srm)"
	echo "device         : $KOBO_DEV"
	echo "mount point    : $KOBO_MOUNT"
	echo "koreader root  : $KOBO_ROOT"
	echo "koreader ver   : $(cat "$KOBO_ROOT/git-rev" 2>/dev/null || echo unknown)"
	echo ""
	echo "--- plugins present on device ---"
	ls -1 "$KOBO_PLUGINS" 2>/dev/null || echo "(none)"
	echo ""
	echo "--- filesystem ---"
	df -h "$KOBO_MOUNT" 2>/dev/null || true
} >"$OUT/environment.txt"
echo "  + environment.txt"

# --- 7. Extract the interesting parts of crash.log ---
if [ -f "$OUT/crash.log" ]; then
	# Last boot: everything after the final KOReader banner.
	_last_start="$(grep -n 'launching\.\.\.' "$OUT/crash.log" | tail -1 | cut -d: -f1 || true)"
	if [ -n "$_last_start" ]; then
		tail -n "+$_last_start" "$OUT/crash.log" >"$OUT/crash-last-session.log"
		echo "  + crash-last-session.log"
	fi
	grep -nE 'ERROR|WARN|error|failed|Failed|traceback' "$OUT/crash.log" \
		>"$OUT/crash-errors.log" 2>/dev/null || true
	echo "  + crash-errors.log ($(wc -l <"$OUT/crash-errors.log" 2>/dev/null || echo 0) line(s))"
fi

# --- 8. Does the device match the repo? ---
{
	echo "Diff between repo plugin sources and what is on the device."
	echo "Non-empty output means the device is running something other than HEAD."
	echo ""
	for p in markdownreader.koplugin syncnotes.koplugin; do
		echo "=== $p ==="
		if [ -d "$OUT/plugins-on-device/$p" ]; then
			diff -ru "$REPO_DIR/plugins/$p" "$OUT/plugins-on-device/$p" \
				--exclude=.git --exclude=.gitignore 2>&1 || true
		else
			echo "(not on device)"
		fi
		echo ""
	done
} >"$OUT/device-vs-repo.diff"
echo "  + device-vs-repo.diff"

# --- 9. Summary, written for whoever reads this next ---
{
	echo "# Kobo diagnostics — $STAMP"
	echo ""
	echo "Collected by \`collect-diagnostics.sh\`. Everything here is a copy;"
	echo "the device was not modified."
	echo ""
	echo "## Environment"
	echo ""
	echo '```'
	cat "$OUT/environment.txt"
	echo '```'
	echo ""
	echo "## Start here"
	echo ""
	echo "| File | What it is |"
	echo "| --- | --- |"
	echo "| \`crash-last-session.log\` | KOReader's log for the most recent boot only |"
	echo "| \`crash-errors.log\` | every ERROR/WARN/traceback line, with line numbers into \`crash.log\` |"
	echo "| \`crash.log\` | the full log |"
	echo "| \`markdownreader-debug/last.html\` | exact bytes the plugin handed to crengine |"
	echo "| \`markdownreader-debug/last-converted.md\` | markdown after math extraction, before conversion |"
	echo "| \`markdownreader-debug/last.log\` | plugin's own report: paths, sizes, formula counts |"
	echo "| \`cache-md/\` | generated HTML still in cache (wiped on each KOReader start) |"
	echo "| \`plugins-on-device/\` | plugin sources as they exist on the Kobo |"
	echo "| \`device-vs-repo.diff\` | device vs repo — non-empty means drift |"
	echo ""
	echo "## Quick triage"
	echo ""
	if [ -s "$OUT/device-vs-repo.diff" ] && grep -q '^diff ' "$OUT/device-vs-repo.diff" 2>/dev/null; then
		echo "- ⚠️  **Device differs from the repo** — see \`device-vs-repo.diff\`."
		echo "  Fixes have previously existed only on the device and been lost on deploy."
	else
		echo "- Device plugin sources match the repo."
	fi
	_errs="$(wc -l <"$OUT/crash-errors.log" 2>/dev/null || echo 0)"
	echo "- \`crash-errors.log\` has $_errs line(s)."
	if [ -f "$OUT/markdownreader-debug/last.log" ]; then
		echo "- Plugin diagnostics present. Last render report:"
		echo ""
		echo '```'
		cat "$OUT/markdownreader-debug/last.log"
		echo '```'
	else
		echo "- ⚠️  No \`markdownreader-debug/last.log\`. Open a Markdown file on the"
		echo "  device to generate one, then re-run this script."
	fi
	echo ""
	echo "## Most recent errors"
	echo ""
	echo '```'
	tail -30 "$OUT/crash-errors.log" 2>/dev/null || echo "(none)"
	echo '```'
} >"$OUT/SUMMARY.md"
echo "  + SUMMARY.md"

# --- 10. Strip credentials before anyone shares this ---
redact_tree "$OUT"
if grep -rqE 'gh[pousr]_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}' "$OUT" 2>/dev/null; then
	echo "  ! WARNING: a credential-shaped string survived redaction — review before sharing"
else
	echo "  + credentials redacted"
fi

ln -sfn "$STAMP" "$REPO_DIR/diagnostics/latest"

echo ""
if [ "$KEEP_MOUNTED" -eq 1 ]; then
	echo "Left mounted (--keep-mounted)."
else
	kobo_unmount
fi

echo ""
echo "Done. $(du -sh "$OUT" 2>/dev/null | cut -f1) collected."
echo "Read this first:  diagnostics/latest/SUMMARY.md"
