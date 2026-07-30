#!/bin/sh
# Shared Kobo device helpers, sourced by deploy.sh and collect-diagnostics.sh.
# Not executable on its own.
#
# Provides: maybe_sudo, die, find_kobo_devices, device_mountpoint,
#           kobo_mount (sets KOBO_DEV/KOBO_MOUNT/KOBO_ROOT/... and
#           ALREADY_MOUNTED), kobo_unmount.

# Fallback mount point, used only when the Kobo is not already mounted.
KOBO_MOUNT="${KOBO_MOUNT:-/mnt/kobo}"

# The Kobo always labels its user partition "KOBOeReader", so we locate it by
# label rather than by device node: the node moves around (/dev/sdb, /dev/sde…)
# depending on how many USB disks are attached, and guessing it wrong means
# touching somebody else's disk.
KOBO_LABEL="${KOBO_LABEL:-KOBOeReader}"
# Set KOBO_DEV=/dev/sdX to skip autodetection entirely.
KOBO_DEV="${KOBO_DEV:-}"

maybe_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif [ -x /usr/bin/sudo ]; then
		sudo "$@"
	else
		"$@"
	fi
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# Prints every block device whose filesystem label matches KOBO_LABEL.
# The Kobo exposes its storage as a whole-disk FAT filesystem with no partition
# table, so this normally prints a bare disk (e.g. /dev/sde) rather than sdeN.
find_kobo_devices() {
	lsblk -rno PATH,LABEL 2>/dev/null | while read -r _path _label _rest; do
		[ "$_label" = "$KOBO_LABEL" ] && echo "$_path"
	done
	# blkid as a fallback for setups where lsblk reports no label.
	if [ -z "$(lsblk -rno LABEL 2>/dev/null | grep -Fx "$KOBO_LABEL" || true)" ]; then
		maybe_sudo blkid -L "$KOBO_LABEL" 2>/dev/null || true
	fi
}

# Prints the mount point of $1, or nothing when it is not mounted.
device_mountpoint() {
	findmnt -nfo TARGET --source "$1" 2>/dev/null || true
}

# Locates the Kobo, mounts it if needed, and exports the derived paths.
# Sets ALREADY_MOUNTED=1 when it was mounted before we got here, so callers
# know whether to unmount afterwards.
kobo_mount() {
	if [ -n "$KOBO_DEV" ]; then
		echo "Using device from KOBO_DEV: $KOBO_DEV"
		[ -b "$KOBO_DEV" ] || die "$KOBO_DEV is not a block device."
	else
		echo "Looking for a device labelled '$KOBO_LABEL'..."
		_found="$(find_kobo_devices | sort -u)"
		_count="$(printf '%s\n' "$_found" | grep -c . || true)"

		case "$_count" in
		0) die "No device labelled '$KOBO_LABEL' found. Is the Kobo plugged in and unlocked?
       Connect it, or set the device explicitly: KOBO_DEV=/dev/sdX $0" ;;
		1) KOBO_DEV="$_found" ;;
		*) die "Multiple devices labelled '$KOBO_LABEL':
$_found
       Pick one explicitly: KOBO_DEV=/dev/sdX $0" ;;
		esac
		echo "  Found Kobo at $KOBO_DEV"
	fi

	# Respect an existing mount wherever it is — desktop auto-mounters typically
	# put it under /run/media/$USER/KOBOeReader, not our fallback mount point.
	EXISTING_MOUNT="$(device_mountpoint "$KOBO_DEV")"
	if [ -n "$EXISTING_MOUNT" ]; then
		ALREADY_MOUNTED=1
		KOBO_MOUNT="$EXISTING_MOUNT"
		echo "  Already mounted at $KOBO_MOUNT — using it."
	else
		ALREADY_MOUNTED=0
		echo "Mounting $KOBO_DEV at $KOBO_MOUNT ..."
		[ -d "$KOBO_MOUNT" ] || maybe_sudo mkdir -p "$KOBO_MOUNT"
		maybe_sudo mount "$KOBO_DEV" "$KOBO_MOUNT" ||
			die "Failed to mount $KOBO_DEV at $KOBO_MOUNT."
	fi

	# Derived paths depend on where it actually got mounted, so resolve them
	# here rather than at the top of the calling script.
	KOBO_ROOT="$KOBO_MOUNT/.adds/koreader"
	KOBO_PLUGINS="$KOBO_ROOT/plugins"
	KOBO_CACHE="$KOBO_ROOT/cache"
	KOBO_HTML_CACHE="$KOBO_CACHE/md"
	KOBO_SECRETS="$KOBO_ROOT/secrets"

	# Guard against touching something that merely shares the label.
	[ -d "$KOBO_ROOT" ] ||
		die "$KOBO_ROOT does not exist — $KOBO_MOUNT does not look like a KOReader install."
}

# Unmounts only if we were the ones who mounted it.
kobo_unmount() {
	sync
	if [ "${ALREADY_MOUNTED:-1}" -eq 0 ]; then
		echo "Unmounting $KOBO_MOUNT ..."
		maybe_sudo umount "$KOBO_MOUNT" ||
			die "Failed to unmount $KOBO_MOUNT — do not disconnect until it succeeds."
		echo "Safe to disconnect."
	else
		echo "Kobo was already mounted at $KOBO_MOUNT — left mounted."
	fi
}
