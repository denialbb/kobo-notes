#!/bin/sh
# Deploy plugins + secrets to Kobo (USB-mounted at /mnt/kobo).
# Mounts/unmounts automatically. Prompts for sudo if needed.
set -eu

KOBO_MOUNT="/mnt/kobo"
KOBO_ROOT="$KOBO_MOUNT/.adds/koreader"
KOBO_PLUGINS="$KOBO_ROOT/plugins"
KOBO_SECRETS="$KOBO_ROOT/secrets"
KOBO_DEV="/dev/sdb"

# Helper: run a command, fall back to sudo if plain fails
maybe_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif [ -x /usr/bin/sudo ]; then
		sudo "$@"
	else
		"$@"
	fi
}

# Check if Kobo is already mounted
if mount | grep -q "$KOBO_MOUNT"; then
	ALREADY_MOUNTED=1
else
	ALREADY_MOUNTED=0
	echo "Mounting Kobo..."
	maybe_sudo mount "$KOBO_DEV" "$KOBO_MOUNT"
fi

echo "Deploying plugins..."
maybe_sudo cp -rv plugins/markdownreader.koplugin "$KOBO_PLUGINS/"
maybe_sudo cp -rv plugins/syncnotes.koplugin "$KOBO_PLUGINS/"

echo "Deploying secrets..."
if [ -d secrets ]; then
	maybe_sudo mkdir -p "$KOBO_SECRETS"
	maybe_sudo cp -rv secrets/* "$KOBO_SECRETS/"
fi

echo "Syncing..."
sync

echo "Done."
echo ""

# Unmount unless it was already mounted
if [ "$ALREADY_MOUNTED" -eq 0 ]; then
	echo "Unmounting Kobo..."
	maybe_sudo umount "$KOBO_MOUNT"
	echo "Safe to disconnect."
else
	echo "Kobo was already mounted — left mounted."
fi
