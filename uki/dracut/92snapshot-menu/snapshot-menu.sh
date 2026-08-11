#!/bin/bash

set -u

CONFIG="/etc/snapshot-menu.conf"

#
# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
#

if [[ ! -r "$CONFIG" ]]; then
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

#
# Required configuration.
#
: "${ROOT_SUBVOL:?ROOT_SUBVOL is not configured}"
: "${SNAPSHOT_DIR:?SNAPSHOT_DIR is not configured}"
: "${TTY:?TTY is not configured}"
: "${MOUNTPOINT:?MOUNTPOINT is not configured}"
: "${RESULT:?RESULT is not configured}"
: "${CMDLINE_DIR:?CMDLINE_DIR is not configured}"
: "${SNAPSHOT_CMDLINE:?SNAPSHOT_CMDLINE is not configured}"

#
# ------------------------------------------------------------
# Root device
# ------------------------------------------------------------
#

ROOT_DEV="${1:-}"

if [[ -z "$ROOT_DEV" || ! -b "$ROOT_DEV" ]]; then
    exit 1
fi

#
# TTY fallback.
#
if [[ ! -c "$TTY" ]]; then
    TTY="/dev/console"
fi

mkdir -p "$MOUNTPOINT"

#
# One file descriptor for both keyboard and display.
#
exec 3<>"$TTY"

mounted=0
CURRENT_KERNEL="$(uname -r)"

#
# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
#

cleanup() {

    printf '\033[?25h' >&3 2>/dev/null || true

    stty sane <&3 2>/dev/null || true

    if (( mounted )); then

        umount "$MOUNTPOINT" \
            >/dev/null 2>&1 || true

    fi

    exec 3>&- 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT TERM

#
# ------------------------------------------------------------
# Mount Btrfs top-level
# ------------------------------------------------------------
#

if ! mount \
    -t btrfs \
    -o ro,subvolid=5 \
    "$ROOT_DEV" \
    "$MOUNTPOINT"
then

    printf '\nUnable to mount Btrfs root: %s\n' \
        "$ROOT_DEV" >&3

    sleep 2
    exit 1
fi

mounted=1

SNAPDIR="${MOUNTPOINT}/${ROOT_SUBVOL}/${SNAPSHOT_DIR}"

#
# ------------------------------------------------------------
# Menu entries
# ------------------------------------------------------------
#

declare -a SUBVOLS
declare -a LABELS
declare -a KERNEL_STATUS

SUBVOLS=()
LABELS=()
KERNEL_STATUS=()

#
# Entry 0 = normal root.
#
SUBVOLS+=(
    "$ROOT_SUBVOL"
)

LABELS+=(
    "Ubuntu - current system"
)

kernel_status=""

if [[ -d "${MOUNTPOINT}/${ROOT_SUBVOL}/usr/lib/modules/${CURRENT_KERNEL}" ]]; then
    kernel_status="Present"
else
    kernel_status="Missing"
fi


KERNEL_STATUS+=(
    "$kernel_status"
)

#
# ------------------------------------------------------------
# Snapper snapshots
# ------------------------------------------------------------
#

if [[ -d "$SNAPDIR" ]]; then

    while IFS= read -r snap; do

        [[ -n "$snap" ]] || continue
        [[ "$snap" =~ ^[0-9]+$ ]] || continue

        snapshot="${SNAPDIR}/${snap}/snapshot"
        info="${SNAPDIR}/${snap}/info.xml"

        [[ -d "$snapshot" ]] || continue

        if [[ -d "${snapshot}/usr/lib/modules/${CURRENT_KERNEL}" ]]; then
            kernel_status="Present"
        else
            kernel_status="Missing"
        fi

        description=""
        date=""
        type=""

        #
        # Read Snapper metadata.
        #
        if [[ -r "$info" ]]; then

            description="$(
                sed -n \
                    's:.*<description>\(.*\)</description>.*:\1:p' \
                    "$info" |
                head -n 1
            )"

            date="$(
                sed -n \
                    's:.*<date>\(.*\)</date>.*:\1:p' \
                    "$info" |
                head -n 1
            )"

            type="$(
                sed -n \
                    's:.*<type>\(.*\)</type>.*:\1:p' \
                    "$info" |
                head -n 1
            )"

        fi

        [[ -n "$description" ]] ||
            description="Snapshot"

        #
        # Path relative to Btrfs top-level.
        #
        SUBVOLS+=(
            "${ROOT_SUBVOL}/${SNAPSHOT_DIR}/${snap}/snapshot"
        )

        if [[ -n "$date" ]]; then

            LABELS+=(
                "#${snap}   ${date}   ${description}   ${type}"
            )

        else

            LABELS+=(
                "#${snap}   ${description}   ${type}"
            )

        fi

        KERNEL_STATUS+=(
            "$kernel_status"
        )

    done < <(

        for path in "$SNAPDIR"/*; do

            [[ -d "$path" ]] || continue

            snap="${path##*/}"

            [[ "$snap" =~ ^[0-9]+$ ]] || continue

            printf '%s\n' "$snap"

        done |
            sort -rn

    )

fi

COUNT=${#SUBVOLS[@]}

#
# ------------------------------------------------------------
# Configure terminal
# ------------------------------------------------------------
#

stty \
    -echo \
    -icanon \
    min 1 \
    time 0 \
    <&3

#
# Hide cursor.
#
printf '\033[?25l' >&3

selected=0

#
# ------------------------------------------------------------
# Draw
# ------------------------------------------------------------
#

draw_menu() {

    local i

    printf '\033[2J\033[H' >&3

    printf '\033[1;36m' >&3
    printf 'Ubuntu Snapshot Boot\n' >&3
    printf '\033[0m' >&3

    printf 'Kernel: %s\n' \
        "$CURRENT_KERNEL" >&3

    printf '\n' >&3
    printf 'Select root filesystem:\n\n' >&3

    printf '   %-62s %-10s\n' \
        'Snapshot' \
        'Kernel' >&3

    printf '   %-62s %-10s\n' \
        '--------' \
        '------' >&3

    for ((i = 0; i < COUNT; i++)); do

        if (( i == selected )); then

            printf '\033[7m' >&3

            printf ' > %-62s %-10s' \
                "${LABELS[$i]}" \
                "${KERNEL_STATUS[$i]}" >&3

            printf '\033[0m\n' >&3

        else

            printf '   %-62s %-10s\n' \
                "${LABELS[$i]}" \
                "${KERNEL_STATUS[$i]}" >&3

        fi

    done

    printf '\n' >&3

    printf '\033[2m' >&3
    printf 'Up/Down: select    Enter: boot    j/k: select\n' >&3
    printf '\033[0m' >&3
}

#
# ------------------------------------------------------------
# Keyboard
# ------------------------------------------------------------
#

read_key() {

    local key=""
    local seq=""

    #
    # First byte blocks intentionally.
    #
    IFS= read \
        -r \
        -s \
        -n 1 \
        -u 3 \
        key || true

    case "$key" in

        $'\e')

            #
            # ESC sequence continuation MUST NOT block.
            #
            seq=""

            IFS= read \
                -r \
                -s \
                -n 2 \
                -t 0.15 \
                -u 3 \
                seq || true

            case "$seq" in

                '[A')
                    printf '%s' "UP"
                    ;;

                '[B')
                    printf '%s' "DOWN"
                    ;;

                '[C')
                    printf '%s' "RIGHT"
                    ;;

                '[D')
                    printf '%s' "LEFT"
                    ;;

                *)
                    printf '%s' "ESC"
                    ;;

            esac
            ;;

        "")

            printf '%s' "ENTER"
            ;;

        j|J)

            printf '%s' "DOWN"
            ;;

        k|K)

            printf '%s' "UP"
            ;;

        *)

            printf '%s' "OTHER"
            ;;

    esac
}

#
# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
#

draw_menu

while true; do

    key="$(read_key)"

    case "$key" in

        UP)

            if (( selected > 0 )); then
                ((selected--))
            else
                selected=$((COUNT - 1))
            fi

            draw_menu
            ;;

        DOWN)

            if (( selected < COUNT - 1 )); then
                ((selected++))
            else
                selected=0
            fi

            draw_menu
            ;;

        ENTER)

            break
            ;;

    esac

done

#
# ------------------------------------------------------------
# Selected entry
# ------------------------------------------------------------
#

SELECTED_SUBVOL="${SUBVOLS[$selected]}"
SELECTED_LABEL="${LABELS[$selected]}"

#
# Save the subvolume for snapshot-menu-hook.sh.
#
printf '%s\n' \
    "$SELECTED_SUBVOL" \
    >"${RESULT}.tmp"

mv \
    "${RESULT}.tmp" \
    "$RESULT"

#
# ------------------------------------------------------------
# Dynamic Dracut command line
# ------------------------------------------------------------
#

if [[ "$SELECTED_SUBVOL" != "$ROOT_SUBVOL" ]]; then

    #
    # Snapshot:
    #
    # enable volatile overlay.
    #
    mkdir -p "$CMDLINE_DIR"

    printf '%s\n' \
        'rd.overlay=1' \
        >"$SNAPSHOT_CMDLINE"

else

    #
    # Current root:
    #
    # normal RW boot, no overlay.
    #
    rm -f "$SNAPSHOT_CMDLINE"

fi

#
# ------------------------------------------------------------
# Restore terminal
# ------------------------------------------------------------
#

printf '\033[?25h' >&3
stty sane <&3

printf '\nBooting: %s\n' \
    "$SELECTED_LABEL" >&3

if [[ "$SELECTED_SUBVOL" != "$ROOT_SUBVOL" ]]; then

    printf 'Root:    %s\n' \
        "$SELECTED_SUBVOL" >&3

    printf 'Overlay: tmpfs\n' >&3

fi

sleep 0.4

exit 0