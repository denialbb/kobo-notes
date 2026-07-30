#!/bin/sh
# Deploy plugins + secrets to Kobo (USB-mounted).
# Builds the C-wrapper before deployment.
# Mounts/unmounts automatically. Prompts for sudo if needed.
# Clears generated HTML + SVG caches so render tests start fresh.
set -eu

# --- Configuration Variables ---
KOBO_MOUNT="/mnt/kobo"
KOBO_ROOT="$KOBO_MOUNT/.adds/koreader"
KOBO_PLUGINS="$KOBO_ROOT/plugins"
KOBO_CACHE="$KOBO_ROOT/cache"
KOBO_HTML_CACHE="$KOBO_CACHE/md"
KOBO_SECRETS="$KOBO_ROOT/secrets"
KOBO_DEV="/dev/sdb"

# Remote cleanup (SSH to Kobo, optional — set KOBO_SSH to a host string)
# Typical: KOBO_SSH="root@192.168.2.2"  port 2222
# Leave empty to skip remote SVG-cache cleanup.
KOBO_SSH=""
KOBO_SSH_PORT="2222"

PLUGIN_MARKDOWN="plugins/markdownreader.koplugin"
PLUGIN_SYNCNOTES="plugins/syncnotes.koplugin"

# --- Helper Functions ---
maybe_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif [ -x /usr/bin/sudo ]; then
		sudo "$@"
	else
		"$@"
	fi
}

# --- Step 1: Build C-Wrapper ---
echo "Building C-Wrapper for Kobo (ARMhf)..."
cd "$PLUGIN_MARKDOWN"
make clean
make kobo
mv kobo-libmicrotex.so libmicrotex.so
cd - >/dev/null
echo "Build successful."
echo ""

# --- Step 2: Mount Kobo ---
if mount | grep -q "$KOBO_MOUNT"; then
	ALREADY_MOUNTED=1
else
	ALREADY_MOUNTED=0
	echo "Mounting Kobo..."
	maybe_sudo mount "$KOBO_DEV" "$KOBO_MOUNT"
fi

# --- Step 3: Clean caches (before copy, so fresh start) ---
echo "Clearing HTML cache at $KOBO_HTML_CACHE ..."
if [ -d "$KOBO_HTML_CACHE" ]; then
	# Remove generated HTML files
	maybe_sudo rm -rf "$KOBO_HTML_CACHE"/*.html 2>/dev/null || true
	maybe_sudo rm -rf "$KOBO_HTML_CACHE"/*.htm 2>/dev/null || true
	# Also remove stale KOReader sidecar dirs (bookmarks/progress from old render)
	for d in "$KOBO_HTML_CACHE"/*.sdr; do
		[ -d "$d" ] && maybe_sudo rm -rf "$d" 2>/dev/null || true
	done
	echo "  HTML cache cleared (files + .sdr sidecars)."
else
	echo "  No HTML cache directory found (created on first use)."
fi

# Clear SVG cache from onboard storage (SVGs are now stored alongside the HTML)
echo "Clearing onboard SVG cache at $KOBO_CACHE/md/svg ..."
if [ -d "$KOBO_CACHE/md/svg" ]; then
	maybe_sudo rm -rf "$KOBO_CACHE/md/svg"/*.svg 2>/dev/null || true
	echo "  Onboard SVG cache cleared."
else
	echo "  No SVG cache directory found on onboard storage."
fi

# Remote SVG cache cleanup (optional, requires network on Kobo)
# Default SVG cache is now on onboard storage (cleared above), but if the
# plugin used /tmp/microtex-cache/ on a previous run, clean that too.
if [ -n "$KOBO_SSH" ]; then
	echo "Clearing remote SVG cache at ${KOBO_SSH}:/tmp/microtex-cache/ ..."
	ssh -p "$KOBO_SSH_PORT" "$KOBO_SSH" "rm -rf /tmp/microtex-cache && mkdir -p /tmp/microtex-cache" 2>/dev/null &&
		echo "  Remote SVG cache cleared." ||
		echo "  SSH cleanup failed (Kobo not reachable? skipping)."
else
	echo "SVG cache note: SVGs are now stored on onboard storage ($KOBO_CACHE/md/svg/)"
	echo "  and cleared above. Reboot also clears /tmp/microtex-cache/."
fi

# --- Step 4: Deploy Files ---
echo "Deploying plugins..."
maybe_sudo cp -rv "$PLUGIN_MARKDOWN" "$KOBO_PLUGINS/"
maybe_sudo cp -rv "$PLUGIN_SYNCNOTES" "$KOBO_PLUGINS/"

echo "Deploying secrets..."
if [ -d secrets ]; then
	maybe_sudo mkdir -p "$KOBO_SECRETS"
	maybe_sudo cp -rv secrets/* "$KOBO_SECRETS/"
fi

echo "Syncing..."
sync

echo "Done."
echo ""

# --- Step 5: Cleanup ---
# Unmount unless it was already mounted
if [ "$ALREADY_MOUNTED" -eq 0 ]; then
	echo "Unmounting Kobo..."
	maybe_sudo umount "$KOBO_MOUNT"
	echo "Safe to disconnect."
else
	echo "Kobo was already mounted — left mounted."
fi
