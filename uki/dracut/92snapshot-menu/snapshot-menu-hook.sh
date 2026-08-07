#!/bin/sh

command -v getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

SNAPSHOT_MENU="/usr/libexec/snapshot-menu"
SNAPSHOT_MENU_CONF="/etc/snapshot-menu.conf"
SNAPSHOT_MENU_DONE="/run/snapshot-menu-done"
SNAPSHOT_SELECTION="/run/snapshot-menu-selected"

#
# Dracut hooks are sourced.
# Mai usare exit in questo script.
#

[ -e "$SNAPSHOT_MENU_DONE" ] && return 0

#
# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
#

if [ ! -r "$SNAPSHOT_MENU_CONF" ]; then
    warn "snapshot-menu: configuration missing"
    return 0
fi

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
# Fallback.
#
if [ -z "$root_dev" ] && [ -n "${root:-}" ]; then

    case "$root" in

        block:*)
            root_dev="${root#block:}"
            ;;

        /dev/*)
            root_dev="$root"
            ;;

    esac

fi

#
# LUKS/root device not ready yet.
#
if [ -z "$root_dev" ] || [ ! -b "$root_dev" ]; then
    return 0
fi

#
# Execute menu only once.
#
touch "$SNAPSHOT_MENU_DONE"

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

if [ -c "$menu_tty" ]; then

    printf '\033[2J\033[H' \
        >"$menu_tty" 2>/dev/null || :

fi

#
# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------
#

menu_rc=1

if [ -x "$SNAPSHOT_MENU" ]; then

    "$SNAPSHOT_MENU" "$root_dev"
    menu_rc=$?

else

    warn "snapshot-menu: $SNAPSHOT_MENU is missing"

fi

#
# ------------------------------------------------------------
# Snapshot boot
# ------------------------------------------------------------
#

if [ "$menu_rc" -eq 0 ] &&
   [ -s "$SNAPSHOT_SELECTION" ]; then

    IFS= read -r selected_subvol <"$SNAPSHOT_SELECTION"

    if [ -n "$selected_subvol" ]; then

        info "snapshot-menu: selected root: $selected_subvol"

        #
        # Current system:
        #
        # Leave root completely untouched and let the normal
        # dracut/systemd root mount continue.
        #
        if [ "$selected_subvol" = "$ROOT_SUBVOL" ]; then

            info "snapshot-menu: normal root boot"

        else

            #
            # Snapshot boot.
            #
            # rd.overlay=1 has already been added by snapshot-menu.
            #
            # Mount the selected snapshot directly as NEWROOT.
            #
            # Snapshot is explicitly RO; overlayfs will provide
            # the writable volatile layer.
            #

            info "snapshot-menu: mounting snapshot $selected_subvol"

            mkdir -p "$NEWROOT"

            if ! mount \
                -t btrfs \
                -o "ro,subvol=${selected_subvol}" \
                "$root_dev" \
                "$NEWROOT"
            then

                warn "snapshot-menu: cannot mount selected snapshot"

                #
                # Do not leave overlay enabled if snapshot mount failed.
                #
                rm -f "$SNAPSHOT_CMDLINE"

            else

                info "snapshot-menu: snapshot mounted on $NEWROOT"
                info "snapshot-menu: overlay enabled"

            fi

        fi

    fi

fi

#
# ------------------------------------------------------------
# Plymouth
# ------------------------------------------------------------
#

if [ "$plymouth_active" -eq 1 ]; then

    if [ -c "$menu_tty" ]; then

        printf '\033[2J\033[H' \
            >"$menu_tty" 2>/dev/null || :

    fi

    plymouth show-splash \
        >/dev/null 2>&1 || :

fi

if [ "$menu_rc" -ne 0 ]; then
    warn "snapshot-menu: menu failed; continuing normal boot"
fi

unset root_dev
unset selected_subvol
unset menu_tty
unset menu_rc
unset plymouth_active

return 0