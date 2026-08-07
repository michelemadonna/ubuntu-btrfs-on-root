#!/bin/bash

set -u

CONFIG="/etc/snapshot-menu.conf"

#
# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------
#

ROOT_SUBVOL="@ubuntu"
SNAPSHOT_DIR=".snapshots"

TTY="/dev/tty1"

MOUNTPOINT="/run/snapshot-menu-root"
RESULT="/run/snapshot-menu-selected"

#
# ------------------------------------------------------------
# Read configuration
# ------------------------------------------------------------
#

if [[ -r "$CONFIG" ]]; then

    # shellcheck disable=SC1090
    source "$CONFIG"

fi

#
# ------------------------------------------------------------
# Root device
# ------------------------------------------------------------
#

ROOT_DEV="${1:-}"

if [[ -z "$ROOT_DEV" ]]; then
    exit 1
fi

if [[ ! -b "$ROOT_DEV" ]]; then
    exit 1
fi

#
# tty1 normally exists in initrd.
# Fall back to console if necessary.
#
if [[ ! -c "$TTY" ]]; then
    TTY="/dev/console"
fi

mkdir -p "$MOUNTPOINT"

#
# ------------------------------------------------------------
# Open terminal
#
# FD 3 is used for BOTH input and output.
# ------------------------------------------------------------
#

exec 3<>"$TTY"

mounted=0

#
# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
#

cleanup() {

    #
    # Restore cursor.
    #
    printf '\033[?25h' >&3 2>/dev/null || true

    #
    # Restore sane terminal state.
    #
    stty sane <&3 2>/dev/null || true

    #
    # Remove temporary Btrfs mount.
    #
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

SUBVOLS=()
LABELS=()

#
# First entry = normal root.
#
SUBVOLS+=(
    "$ROOT_SUBVOL"
)

LABELS+=(
    "Ubuntu - current system"
)

#
# ------------------------------------------------------------
# Read Snapper snapshots
# ------------------------------------------------------------
#

if [[ -d "$SNAPDIR" ]]; then

    while IFS= read -r snap; do

        [[ -n "$snap" ]] ||
            continue

        [[ "$snap" =~ ^[0-9]+$ ]] ||
            continue

        snapshot="${SNAPDIR}/${snap}/snapshot"
        info="${SNAPDIR}/${snap}/info.xml"

        [[ -d "$snapshot" ]] ||
            continue

        description=""
        date=""

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

        fi

        if [[ -z "$description" ]]; then
            description="Snapshot"
        fi

        #
        # Path relative to Btrfs top-level.
        #
        SUBVOLS+=(
            "${ROOT_SUBVOL}/${SNAPSHOT_DIR}/${snap}/snapshot"
        )

        if [[ -n "$date" ]]; then

            LABELS+=(
                "#${snap}   ${date}   ${description}"
            )

        else

            LABELS+=(
                "#${snap}   ${description}"
            )

        fi

    done < <(

        #
        # Numeric snapshot directories,
        # newest first.
        #
        for path in "$SNAPDIR"/*; do

            [[ -d "$path" ]] ||
                continue

            snap="${path##*/}"

            [[ "$snap" =~ ^[0-9]+$ ]] ||
                continue

            printf '%s\n' "$snap"

        done | sort -rn

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
# Draw menu
# ------------------------------------------------------------
#

draw_menu() {

    local i

    #
    # Clear screen + cursor home.
    #
    printf '\033[2J\033[H' >&3

    #
    # Header.
    #
    printf '\033[1;36m' >&3
    printf 'Ubuntu Snapshot Boot\n' >&3
    printf '\033[0m' >&3

    printf '\n' >&3

    printf 'Select root filesystem:\n\n' >&3

    #
    # Entries.
    #
    for ((i = 0; i < COUNT; i++)); do

        if (( i == selected )); then

            #
            # Selected entry: reverse video.
            #
            printf '\033[7m' >&3

            printf ' > %-74s' \
                "${LABELS[$i]}" >&3

            printf '\033[0m\n' >&3

        else

            printf '   %-74s\n' \
                "${LABELS[$i]}" >&3

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
    # Read exactly ONE key.
    #
    # This is intentionally blocking because the menu
    # remains visible until the user chooses an entry.
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
            # ANSI cursor keys:
            #
            # UP    ESC [ A
            # DOWN  ESC [ B
            # RIGHT ESC [ C
            # LEFT  ESC [ D
            #
            # The remaining bytes have a timeout.
            # Therefore an incomplete ESC sequence cannot
            # leave us blocked as happened with dd.
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

            #
            # Enter.
            #
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
# Save selected root
# ------------------------------------------------------------
#

SELECTED_SUBVOL="${SUBVOLS[$selected]}"
SELECTED_LABEL="${LABELS[$selected]}"

#
# Write through temporary file so the consumer never sees
# a partially-written selection.
#
printf '%s\n' \
    "$SELECTED_SUBVOL" \
    >"${RESULT}.tmp"

mv \
    "${RESULT}.tmp" \
    "$RESULT"

#
# ------------------------------------------------------------
# Restore terminal
# ------------------------------------------------------------
#

printf '\033[?25h' >&3

stty sane <&3

printf '\nBooting: %s\n' \
    "$SELECTED_LABEL" >&3

sleep 0.4

exit 0
