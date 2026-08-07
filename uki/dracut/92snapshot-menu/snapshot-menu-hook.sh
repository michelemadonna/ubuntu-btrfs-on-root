#!/bin/sh

command -v getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

SNAPSHOT_MENU="/usr/libexec/snapshot-menu"
SNAPSHOT_MENU_CONF="/etc/snapshot-menu.conf"
SNAPSHOT_MENU_DONE="/run/snapshot-menu-done"
SNAPSHOT_SELECTION="/run/snapshot-menu-selected"

#
# Dracut hooks are sourced.
# Never use exit here.
#

[ -e "$SNAPSHOT_MENU_DONE" ] && return 0

#
# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
#

if [ ! -r "$SNAPSHOT_MENU_CONF" ]; then
    warn "snapshot-menu: configuration missing"
    return 0
fi

. "$SNAPSHOT_MENU_CONF"

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
# Fallback to Dracut's root variable.
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
# At pre-mount the LUKS mapper should already be available.
# If not, don't mark the hook as completed.
#
if [ -z "$root_dev" ] || [ ! -b "$root_dev" ]; then
    return 0
fi

#
# From this point onward execute only once.
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
# Switch to the menu VT
# ------------------------------------------------------------
#

menu_tty="${TTY:-/dev/tty1}"

if [ "$menu_tty" = "/dev/tty1" ] &&
   [ -c /dev/tty1 ]; then

    chvt 1 >/dev/null 2>&1 || :

fi

sleep 0.2

if [ -c "$menu_tty" ]; then

    printf '\033[2J\033[H' \
        >"$menu_tty" 2>/dev/null || :

fi

#
# ------------------------------------------------------------
# Run menu
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
# Apply selected Btrfs subvolume
# ------------------------------------------------------------
#

if [ "$menu_rc" -eq 0 ] &&
   [ -s "$SNAPSHOT_SELECTION" ]; then

    IFS= read -r selected_subvol <"$SNAPSHOT_SELECTION"

    if [ -n "$selected_subvol" ]; then

        #
        # rflags contains the options rootfs-block will use
        # for the real root mount.
        #
        # Keep every existing option except:
        #
        #   subvol=
        #   subvolid=
        #
        # and then add our selected subvolume.
        #

        old_rflags="${rflags:-}"
        new_rflags=""

        old_ifs="$IFS"
        IFS=','

        for opt in $old_rflags; do

            case "$opt" in

                subvol=*|subvolid=*)
                    ;;

                "")
                    ;;

                *)
                    if [ -n "$new_rflags" ]; then
                        new_rflags="${new_rflags},${opt}"
                    else
                        new_rflags="$opt"
                    fi
                    ;;

            esac

        done

        IFS="$old_ifs"

        if [ -n "$new_rflags" ]; then

            rflags="${new_rflags},subvol=${selected_subvol}"

        else

            rflags="subvol=${selected_subvol}"

        fi

        export rflags

        info "snapshot-menu: selected ${selected_subvol}"
        info "snapshot-menu: rflags=${rflags}"

    fi

fi

#
# ------------------------------------------------------------
# Restore Plymouth
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

    warn "snapshot-menu: menu failed; using normal root"

fi

unset root_dev
unset selected_subvol
unset old_rflags
unset new_rflags
unset old_ifs
unset opt
unset menu_tty
unset menu_rc
unset plymouth_active

return 0
