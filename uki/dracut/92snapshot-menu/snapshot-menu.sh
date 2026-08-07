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

: "${ROOT_SUBVOL:?}"
: "${SNAPSHOT_DIR:?}"
: "${TTY:?}"
: "${MOUNTPOINT:?}"
: "${RESULT:?}"
: "${CMDLINE_DIR:?}"
: "${SNAPSHOT_CMDLINE:?}"

#
# ------------------------------------------------------------
# Root device
# ------------------------------------------------------------
#

ROOT_DEV="${1:-}"

if [[ -z "$ROOT_DEV" || ! -b "$ROOT_DEV" ]]; then
    exit 1
fi

if [[ ! -c "$TTY" ]]; then
    TTY="/dev/console"
fi

mkdir -p "$MOUNTPOINT"

#
# Input/output terminal FD.
#
exec 3<>"$TTY"

mounted=0

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
# Mount Btrfs top level
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
# Entries
# ------------------------------------------------------------
#

declare -a SUBVOLS
declare -a LABELS

SUBVOLS=()
LABELS=()

#
# Current system.
#
SUBVOLS+=(
    "$ROOT_SUBVOL"
)

LABELS+=(
    "Ubuntu - current system"
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

        description=""
        date=""

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

        [[ -n "$description" ]] ||
            description="Snapshot"

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

        for path in "$SNAPDIR"/*; do

            [[ -d "$path" ]] || continue

            snap="${path##*/}"

            [[ "$snap" =~ ^[0-9]+$ ]] || continue

            printf '%s\n' "$snap"

        done | sort -rn

    )

fi

COUNT=${#SUBVOLS[@]}

#
# ------------------------------------------------------------
# Terminal
# ------------------------------------------------------------
#

stty \
    -echo \
    -icanon \
    min 1 \
    time 0 \
    <&3

printf '\033[?25l' >&3

selected=0

#
# ------------------------------------------------------------
# Draw menu
# ------------------------------------------------------------
#

draw_menu() {

    local i

    printf '\033[2J\033[H' >&3

    printf '\033[1;36m' >&3
    printf 'Ubuntu Snapshot Boot\n' >&3
    printf '\033[0m\n' >&3

    printf '\nSelect root filesystem:\n\n' >&3

    for ((i = 0; i < COUNT; i++)); do

        if (( i == selected )); then

            printf '\033[7m' >&3
            printf ' > %-74s' "${LABELS[$i]}" >&3
            printf '\033[0m\n' >&3

        else

            printf '   %-74s\n' "${LABELS[$i]}" >&3

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
    # Wait for first key.
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
            # ESC [ A/B.
            #
            # Timeout prevents the old dd-style blocking issue.
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
# Menu
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
# Selection
# ------------------------------------------------------------
#

SELECTED_SUBVOL="${SUBVOLS[$selected]}"
SELECTED_LABEL="${LABELS[$selected]}"

printf '%s\n' \
    "$SELECTED_SUBVOL" \
    >"${RESULT}.tmp"

mv \
    "${RESULT}.tmp" \
    "$RESULT"

#
# ------------------------------------------------------------
# Overlay
# ------------------------------------------------------------
#

if [[ "$SELECTED_SUBVOL" != "$ROOT_SUBVOL" ]]; then

    mkdir -p "$CMDLINE_DIR"

    #
    # getargbool rd.overlay will see this.
    #
    printf '%s\n' \
        'rd.overlay=1' \
        >"$SNAPSHOT_CMDLINE"

else

    #
    # Normal boot:
    # absolutely no overlay.
    #
    rm -f "$SNAPSHOT_CMDLINE"

fi

#
# ------------------------------------------------------------
# Terminal restore
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