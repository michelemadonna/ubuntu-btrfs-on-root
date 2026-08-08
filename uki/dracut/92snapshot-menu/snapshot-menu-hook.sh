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
# LUKS/root device is not ready yet.
#
# Do NOT mark the hook as done in this case.
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

#
# ------------------------------------------------------------
# Press B for snapshot menu
#
# Keyboard handling is executed explicitly with Bash because
# read -n / read -t are Bash features.
# ------------------------------------------------------------
#

open_menu=0

if [ -c "$menu_tty" ]; then

    if /bin/bash -c '
        tty="$1"

        exec 3<>"$tty"

        #
        # Save terminal state.
        #
        old_stty="$(stty -g <&3 2>/dev/null || true)"

        #
        # Disable echo and canonical input.
        #
        stty \
            -echo \
            -icanon \
            min 0 \
            time 0 \
            <&3 2>/dev/null || true

        #
        # Clear screen + scrollback and move cursor home.
        #
        printf "\033[2J\033[3J\033[H" >&3

        #
        # Header.
        #
        printf "\033[1;36m" >&3
        printf "Ubuntu Snapshot Boot" >&3
        printf "\033[0m\n\n" >&3

        #
        # Five-second window.
        #
        for countdown in 5 4 3 2 1; do

            printf \
                "\rPress \033[1mb\033[0m for snapshot menu... %s " \
                "$countdown" >&3

            key=""

            #
            # Wait at most one second for one character.
            #
            if IFS= read \
                -r \
                -s \
                -n 1 \
                -t 1 \
                key \
                <&3
            then

                case "$key" in

                    b|B)

                        #
                        # Restore terminal.
                        #
                        if [ -n "$old_stty" ]; then

                            stty "$old_stty" \
                                <&3 2>/dev/null || true

                        else

                            stty sane \
                                <&3 2>/dev/null || true

                        fi

                        exec 3>&-

                        #
                        # 0 = open snapshot menu.
                        #
                        exit 0
                        ;;

                esac

            fi

        done

        printf "\n" >&3

        #
        # Timeout.
        # Restore terminal state.
        #
        if [ -n "$old_stty" ]; then

            stty "$old_stty" \
                <&3 2>/dev/null || true

        else

            stty sane \
                <&3 2>/dev/null || true

        fi

        exec 3>&-

        #
        # 1 = continue normal boot.
        #
        exit 1

    ' bash "$menu_tty"
    then

        open_menu=1

    fi

fi

#
# ------------------------------------------------------------
# B was NOT pressed
#
# Clear screen and continue normal boot.
# ------------------------------------------------------------
#

if [ "$open_menu" -ne 1 ]; then

    #
    # Clear countdown screen.
    #
    if [ -c "$menu_tty" ]; then

        printf '\033[2J\033[3J\033[H' \
            >"$menu_tty" 2>/dev/null || :

    fi

    #
    # Restore Plymouth.
    #
    if [ "$plymouth_active" -eq 1 ]; then

        plymouth show-splash \
            >/dev/null 2>&1 || :

    fi

    unset root_dev
    unset menu_tty
    unset plymouth_active
    unset open_menu

    return 0
fi

#
# ------------------------------------------------------------
# B was pressed
#
# Clear countdown before opening the real snapshot menu.
# ------------------------------------------------------------
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

    "$SNAPSHOT_MENU" "$root_dev"
    menu_rc=$?

else

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
        # ----------------------------------------------------
        # Current system
        # ----------------------------------------------------
        #
        # Leave root untouched.
        # Normal Dracut root mounting continues.
        #
        if [ "$selected_subvol" = "$ROOT_SUBVOL" ]; then

            info "snapshot-menu: normal root boot"

        else

            #
            # ------------------------------------------------
            # Snapshot boot
            # ------------------------------------------------
            #
            # snapshot-menu.sh has already created:
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
            # 70overlayfs will subsequently use it as the
            # lower layer and create a volatile tmpfs upper.
            #

            mkdir -p "$NEWROOT"

            info "snapshot-menu: mounting snapshot $selected_subvol"

            if ! mount \
                -t btrfs \
                -o "ro,subvol=${selected_subvol}" \
                "$root_dev" \
                "$NEWROOT"
            then

                warn "snapshot-menu: cannot mount selected snapshot"

                #
                # Snapshot mount failed.
                # Disable overlay so normal root boot can continue.
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

#
# Menu failure is non-fatal.
#
if [ "$menu_rc" -ne 0 ]; then

    warn "snapshot-menu: menu failed; continuing normal boot"

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
unset open_menu

return 0