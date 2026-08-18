#!/bin/bash

# shellcheck source=/dev/null
command -v getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

SNAPSHOT_MENU="/usr/libexec/snapshot-menu"
SNAPSHOT_MENU_CONF="/etc/snapshot-menu.conf"
SNAPSHOT_MENU_DONE="/run/snapshot-menu-done"
SNAPSHOT_MENU_REQUESTED="/run/snapshot-menu-requested"
SNAPSHOT_SELECTION="/run/snapshot-menu-selected"

snapshot-menu-hook.log() {
	printf '<6>snapshot-menu: pre-mount: %s\n' "$1" \
		2>/dev/null >/dev/kmsg || :
}

#
# Dracut hooks are sourced.
# Never use exit here.
#

#
# Menu already handled.
#
if [ -e "$SNAPSHOT_MENU_DONE" ]; then
	snapshot-menu-hook.log "skipped because completion marker exists"
	return 0
fi

#
# The early keyboard listener did not request the menu.
#
if [ ! -e "$SNAPSHOT_MENU_REQUESTED" ]; then
	snapshot-menu-hook.log "skipped because request marker is absent"
	return 0
fi

snapshot-menu-hook.log \
	"entered with request marker present root=${root:-<unset>} dev_root=$([ -e /dev/root ] && readlink -f /dev/root 2>/dev/null || printf absent)"

#
# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
#

if [ ! -r "$SNAPSHOT_MENU_CONF" ]; then
	snapshot-menu-hook.log "configuration is missing"
	warn "snapshot-menu: configuration missing"

	rm -f "$SNAPSHOT_MENU_REQUESTED"
	touch "$SNAPSHOT_MENU_DONE"

	return 0
fi

# shellcheck disable=SC1090
. "$SNAPSHOT_MENU_CONF"

#
# ------------------------------------------------------------
# Determine unlocked root block device
# ------------------------------------------------------------
#

root_dev=""

if [ -e /dev/root ]; then
	root_dev="$(readlink -f /dev/root 2>/dev/null)"
fi

#
# Fallback to the Dracut root variable.
#
if [ -z "$root_dev" ] && [ -n "${root:-}" ]; then
	case "$root" in
	block:*)
		root_dev="${root#block:}"
		;;

	/dev/*)
		root_dev="$root"
		;;

	UUID=*)
		root_dev="/dev/disk/by-uuid/${root#UUID=}"
		;;
	esac
fi

#
# LUKS/root device is not ready yet.
#
# Do not remove the request marker and do not mark the hook as
# completed: Dracut must be allowed to invoke the hook again.
#
if [ -z "$root_dev" ] || [ ! -b "$root_dev" ]; then
	snapshot-menu-hook.log \
		"root device is not ready resolved=${root_dev:-<empty>}"
	unset root_dev
	return 0
fi

snapshot-menu-hook.log "root device resolved to ${root_dev}"

#
# From this point onward execute only once.
#
touch "$SNAPSHOT_MENU_DONE"
rm -f "$SNAPSHOT_MENU_REQUESTED"

#
# Remove any stale selection left by an earlier invocation.
#
rm -f "$SNAPSHOT_SELECTION"

#
# ------------------------------------------------------------
# Plymouth
# ------------------------------------------------------------
#

plymouth_active=0

if command -v plymouth >/dev/null 2>&1 &&
	plymouth --ping >/dev/null 2>&1; then

	plymouth_active=1

	plymouth hide-splash \
		>/dev/null 2>&1 || :
fi

snapshot-menu-hook.log "plymouth_active=${plymouth_active}"

#
# ------------------------------------------------------------
# Console
# ------------------------------------------------------------
#

menu_tty="${TTY:-/dev/tty1}"

if [ "$menu_tty" = "/dev/tty1" ] &&
	[ -c /dev/tty1 ]; then

	chvt 1 \
		>/dev/null 2>&1 || :
fi

sleep 0.2

#
# Clear the console before opening the menu.
#
if [ -c "$menu_tty" ]; then
	printf '\033[2J\033[3J\033[H' \
		>"$menu_tty" 2>/dev/null || :
fi

#
# ------------------------------------------------------------
# Run snapshot menu
# ------------------------------------------------------------
#

menu_rc=1

if [ -x "$SNAPSHOT_MENU" ]; then
	snapshot-menu-hook.log "starting snapshot menu"
	"$SNAPSHOT_MENU" "$root_dev"
	menu_rc=$?
	snapshot-menu-hook.log \
		"snapshot menu finished status=${menu_rc} selection_present=$([ -s "$SNAPSHOT_SELECTION" ] && printf yes || printf no)"
else
	snapshot-menu-hook.log "snapshot menu executable is missing"
	warn "snapshot-menu: $SNAPSHOT_MENU is missing"
fi

#
# ------------------------------------------------------------
# Apply selected snapshot
# ------------------------------------------------------------
#

if [ "$menu_rc" -eq 0 ] &&
	[ -s "$SNAPSHOT_SELECTION" ]; then

	IFS= read -r selected_subvol <"$SNAPSHOT_SELECTION"

	if [ -n "$selected_subvol" ]; then
		info "snapshot-menu: selected root: $selected_subvol"

		#
		# --------------------------------------------------------
		# Current system
		# --------------------------------------------------------
		#
		# Leave the root untouched. Normal Dracut root mounting
		# continues.
		#
		if [ "$selected_subvol" = "$ROOT_SUBVOL" ]; then
			info "snapshot-menu: normal root boot"

			#
			# Ensure that a stale overlay cmdline fragment cannot
			# affect a normal boot.
			#
			rm -f "$SNAPSHOT_CMDLINE"
		else
			#
			# ----------------------------------------------------
			# Snapshot boot
			# ----------------------------------------------------
			#
			# snapshot-menu has already created:
			#
			#   /etc/cmdline.d/99-snapshot.conf
			#
			# containing:
			#
			#   rd.overlay=1
			#
			# Mount the selected Btrfs snapshot directly on
			# NEWROOT as read-only.
			#
			# The Dracut overlay module will use this mount as its
			# lower layer and create a volatile tmpfs upper layer.
			#

			mkdir -p "$NEWROOT"

			info "snapshot-menu: mounting snapshot $selected_subvol"

			if ! mount \
				-t btrfs \
				-o "ro,subvol=${selected_subvol}" \
				"$root_dev" \
				"$NEWROOT"; then
				warn "snapshot-menu: cannot mount selected snapshot"

				#
				# Snapshot mounting failed. Disable the overlay so
				# normal root boot can continue.
				#
				rm -f "$SNAPSHOT_CMDLINE"
			else
				info "snapshot-menu: snapshot mounted on $NEWROOT"
				info "snapshot-menu: overlay enabled"
			fi
		fi
	else
		warn "snapshot-menu: empty snapshot selection"
		rm -f "$SNAPSHOT_CMDLINE"
	fi
else
	#
	# Cancellation or menu failure must result in a normal boot.
	#
	rm -f "$SNAPSHOT_CMDLINE"
fi

#
# The selection is no longer needed.
#
rm -f "$SNAPSHOT_SELECTION"

#
# ------------------------------------------------------------
# Clear menu before returning to Plymouth
# ------------------------------------------------------------
#

if [ -c "$menu_tty" ]; then
	printf '\033[2J\033[3J\033[H' \
		>"$menu_tty" 2>/dev/null || :
fi

#
# ------------------------------------------------------------
# Restore Plymouth
# ------------------------------------------------------------
#

if [ "$plymouth_active" -eq 1 ]; then
	plymouth show-splash \
		>/dev/null 2>&1 || :
fi

snapshot-menu-hook.log \
	"completed status=${menu_rc} plymouth_restored=${plymouth_active}"

#
# Menu failure is non-fatal.
#
if [ "$menu_rc" -ne 0 ]; then
	warn "snapshot-menu: menu cancelled or failed; continuing normal boot"
fi

#
# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
#

unset root_dev
unset selected_subvol
unset menu_tty
unset menu_rc
unset plymouth_active

return 0
