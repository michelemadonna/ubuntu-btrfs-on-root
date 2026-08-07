#!/bin/sh

SNAPSHOT_MENU="/usr/libexec/snapshot-menu"
SNAPSHOT_MENU_DONE="/run/snapshot-menu-done"

#
# Dracut hooks are sourced.
# Never use exit here.
#

[ -e "$SNAPSHOT_MENU_DONE" ] && return 0

#
# ------------------------------------------------------------
# Determine unlocked root device
# ------------------------------------------------------------
#

root_dev=""

if [ -e /dev/root ]; then
    root_dev="$(readlink -f /dev/root 2>/dev/null)"
fi

#
# Fallback to Dracut root variable.
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
# Root device is not ready yet.
#
# Do NOT create the done marker.
#
if [ -z "$root_dev" ] || [ ! -b "$root_dev" ]; then
    return 0
fi

#
# We have reached the point where the menu can run.
#
touch "$SNAPSHOT_MENU_DONE"

#
# ------------------------------------------------------------
# Plymouth
# ------------------------------------------------------------
#

plymouth_active=0

if command -v plymouth >/dev/null 2>&1; then

    if plymouth --ping >/dev/null 2>&1; then

        plymouth_active=1

        plymouth hide-splash \
            >/dev/null 2>&1 || :

    fi
fi

#
# ------------------------------------------------------------
# Switch to tty1
# ------------------------------------------------------------
#

if [ -c /dev/tty1 ]; then

    chvt 1 \
        >/dev/null 2>&1 || :

fi

sleep 0.2

#
# Clear tty1.
#
if [ -c /dev/tty1 ]; then

    printf '\033[2J\033[H' \
        >/dev/tty1 2>/dev/null || :

fi

#
# ------------------------------------------------------------
# Show menu
# ------------------------------------------------------------
#

menu_rc=1

if [ -x "$SNAPSHOT_MENU" ]; then

    "$SNAPSHOT_MENU" "$root_dev"

    menu_rc=$?

else

    warn "snapshot-menu: $SNAPSHOT_MENU not found"

fi

#
# ------------------------------------------------------------
# Restore Plymouth
# ------------------------------------------------------------
#

if [ "$plymouth_active" -eq 1 ]; then

    if [ -c /dev/tty1 ]; then

        printf '\033[2J\033[H' \
            >/dev/tty1 2>/dev/null || :

    fi

    plymouth show-splash \
        >/dev/null 2>&1 || :

fi

#
# Failure is non-fatal.
#
if [ "$menu_rc" -ne 0 ]; then

    warn "snapshot-menu: menu failed; continuing with normal root"

fi

unset root_dev
unset plymouth_active
unset menu_rc
unset SNAPSHOT_MENU
unset SNAPSHOT_MENU_DONE

return 0
