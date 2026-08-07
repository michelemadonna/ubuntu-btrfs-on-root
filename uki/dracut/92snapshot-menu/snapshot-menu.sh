#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH TERM=linux

. /etc/snapshot-menu.conf

STATE_DIR="/run/snapshot-menu"
BTRFS_TOP="${STATE_DIR}/top"
MENU_FILE="${STATE_DIR}/menu"
DETAIL_FILE="${STATE_DIR}/details"
CONSOLE="/dev/console"

mkdir -p "$STATE_DIR" "$BTRFS_TOP"

log() {
    printf '[snapshot-menu] %s\n' "$*" >"$CONSOLE"
}

sanitize() {
    printf '%s' "$1" |
        tr '\n\r\t' '   ' |
        sed -e 's/[[:space:]][[:space:]]*/ /g' \
            -e 's/^ *//' \
            -e 's/ *$//'
}

xml_unescape() {
    sed -e 's/&amp;/\&/g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&apos;/'/g"
}

xml_value() {
    file="$1"
    tag="$2"

    sed -n "s:.*<${tag}>\(.*\)</${tag}>.*:\1:p" "$file" |
        head -n 1 |
        xml_unescape
}

xml_userdata() {
    file="$1"

    awk '
        /<userdata>/ {
            active=1
            next
        }

        /<\/userdata>/ {
            exit
        }

        active {
            print
        }
    ' "$file" |
        sed -e 's/<entry>//g' \
            -e 's/<\/entry>/ /g' \
            -e 's/<key>//g' \
            -e 's/<\/key>/=/g' \
            -e 's/<value>//g' \
            -e 's/<\/value>/ /g' \
            -e 's/<[^>]*>//g' |
        xml_unescape |
        tr '\n\r\t' '   ' |
        sed -e 's/[[:space:]][[:space:]]*/ /g' \
            -e 's/^ *//' \
            -e 's/ *$//'
}

cmdline_value() {
    wanted="$1"
    value=""

    for item in $(cat /proc/cmdline); do
        case "$item" in
            "$wanted"=*)
                value="${item#*=}"
                ;;
        esac
    done

    printf '%s\n' "$value"
}

resolve_root_device() {
    if [ -n "${ROOT_DEVICE:-}" ] && [ -b "$ROOT_DEVICE" ]; then
        printf '%s\n' "$ROOT_DEVICE"
        return 0
    fi

    root_arg="$(cmdline_value root)"

    case "$root_arg" in
        block:*)
            root_arg="${root_arg#block:}"
            ;;
    esac

    case "$root_arg" in
        UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
            blkid -l -t "$root_arg" -o device 2>/dev/null |
                head -n 1
            ;;

        /dev/*)
            printf '%s\n' "$root_arg"
            ;;

        *)
            return 1
            ;;
    esac
}

snapshot_rootflags() {
    selected="$1"
    original="$(cmdline_value rootflags)"

    filtered="$(
        printf '%s\n' "$original" |
            tr ',' '\n' |
            awk '
                /^subvol=/ || /^subvolid=/ || /^ro$/ || /^rw$/ {
                    next
                }

                NF && !seen[$0]++ {
                    if (out != "")
                        out=out ","

                    out=out $0
                }

                END {
                    print out
                }
            '
    )"

    if [ -n "$filtered" ]; then
        printf '%s,subvol=%s,ro\n' "$filtered" "$selected"
    else
        printf 'subvol=%s,ro\n' "$selected"
    fi
}

b_pressed() {
    tty="${MENU_TTY:-/dev/tty1}"
    [ -c "$tty" ] || tty="$CONSOLE"

    old_stty="$(stty -g <"$tty" 2>/dev/null || true)"

    stty -echo -icanon min 0 time 1 <"$tty" 2>/dev/null ||
        return 1

    count=0
    result=1

    while [ "$count" -lt "${KEY_TIMEOUT_DS:-20}" ]; do
        key="$(dd if="$tty" bs=1 count=1 2>/dev/null)"

        case "$key" in
            b|B)
                result=0
                break
                ;;
        esac

        count=$((count + 1))
    done

    if [ -n "$old_stty" ]; then
        stty "$old_stty" <"$tty" 2>/dev/null || true
    else
        stty sane <"$tty" 2>/dev/null || true
    fi

    return "$result"
}

prepare_console() {
    PREVIOUS_VT="$(fgconsole 2>/dev/null || printf '1')"
    PLYMOUTH_ACTIVE="no"

    if [ "${PLYMOUTH_INTEGRATION:-yes}" = "yes" ] &&
       command -v plymouth >/dev/null 2>&1 &&
       plymouth --ping >/dev/null 2>&1; then
        PLYMOUTH_ACTIVE="yes"

        plymouth pause-progress >/dev/null 2>&1 || true
        plymouth hide-splash >/dev/null 2>&1 || true
    fi

    chvt "${MENU_VT:-1}" >/dev/null 2>&1 || true
    sleep 1

    stty sane <"${MENU_TTY:-/dev/tty1}" 2>/dev/null || true

    setterm \
        --cursor on \
        --blank 0 \
        >"${MENU_TTY:-/dev/tty1}" \
        2>/dev/null ||
        true

    clear >"${MENU_TTY:-/dev/tty1}" 2>/dev/null || true
}

restore_console() {
    tty="${MENU_TTY:-/dev/tty1}"

    clear >"$tty" 2>/dev/null || true
    setterm --cursor off >"$tty" 2>/dev/null || true

    if [ "${PREVIOUS_VT:-1}" != "${MENU_VT:-1}" ]; then
        chvt "$PREVIOUS_VT" >/dev/null 2>&1 || true
    fi

    if [ "${PLYMOUTH_ACTIVE:-no}" = "yes" ]; then
        plymouth show-splash >/dev/null 2>&1 || true
        plymouth unpause-progress >/dev/null 2>&1 || true
    fi
}

kernel_status() {
    snapshot="$1"
    version="$2"

    if [ -d "$snapshot/usr/lib/modules/$version" ] ||
       [ -d "$snapshot/lib/modules/$version" ]; then
        printf 'OK\n'
    else
        printf 'MISSING\n'
    fi
}

build_menu() {
    kernel="$1"
    snapshots="${BTRFS_TOP}/${NORMAL_ROOT_SUBVOL}/${SNAPSHOT_DIRECTORY}"

    : >"$MENU_FILE"
    : >"$DETAIL_FILE"

    [ -d "$snapshots" ] || return 1

    numbers="$(
        find "$snapshots" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%f\n' |
            grep '^[0-9][0-9]*$'
    )"

    if [ "${NEWEST_FIRST:-yes}" = "yes" ]; then
        numbers="$(
            printf '%s\n' "$numbers" |
                sort -rn |
                head -n "${MAX_SNAPSHOTS:-100}"
        )"
    else
        numbers="$(
            printf '%s\n' "$numbers" |
                sort -n |
                head -n "${MAX_SNAPSHOTS:-100}"
        )"
    fi

    [ -n "$numbers" ] || return 1

    printf '%s\n' "$numbers" |
    while IFS= read -r number; do
        directory="${snapshots}/${number}"
        snapshot="${directory}/snapshot"
        info="${directory}/info.xml"

        [ -d "$snapshot" ] || continue

        type="-"
        pre_number="-"
        date_value="-"
        user_value="-"
        cleanup_value="-"
        description_value="-"
        userdata_value="-"

        if [ -r "$info" ]; then
            type="$(xml_value "$info" type)"
            pre_number="$(xml_value "$info" pre-number)"
            date_value="$(xml_value "$info" date)"
            user_value="$(xml_value "$info" user)"
            cleanup_value="$(xml_value "$info" cleanup)"
            description_value="$(xml_value "$info" description)"
            userdata_value="$(xml_userdata "$info")"
        fi

        type="$(sanitize "${type:--}")"
        pre_number="$(sanitize "${pre_number:--}")"
        date_value="$(sanitize "${date_value:--}")"
        user_value="$(sanitize "${user_value:--}")"
        cleanup_value="$(sanitize "${cleanup_value:--}")"
        description_value="$(sanitize "${description_value:--}")"
        userdata_value="$(sanitize "${userdata_value:--}")"
        status="$(kernel_status "$snapshot" "$kernel")"

        if [ "$status" = "OK" ]; then
            marker="[kernel OK]"
        else
            marker="[KERNEL MISSING]"
        fi

        short_description="$description_value"

        if [ "${#short_description}" -gt 46 ]; then
            short_description="$(printf '%.43s...' "$short_description")"
        fi

        printf '%s\n%s\n' \
            "$number" \
            "$marker | $date_value | $type | $short_description" \
            >>"$MENU_FILE"

        {
            printf 'NUMBER=%s\n' "$number"
            printf 'TYPE=%s\n' "$type"
            printf 'PRE_NUMBER=%s\n' "$pre_number"
            printf 'DATE=%s\n' "$date_value"
            printf 'USER=%s\n' "$user_value"
            printf 'CLEANUP=%s\n' "$cleanup_value"
            printf 'DESCRIPTION=%s\n' "$description_value"
            printf 'USERDATA=%s\n' "$userdata_value"
            printf 'KERNEL_STATUS=%s\n' "$status"
            printf '%s\n' "---"
        } >>"$DETAIL_FILE"
    done

    [ -s "$MENU_FILE" ]
}

detail() {
    selected="$1"
    key="$2"

    awk -v selected="$selected" -v key="$key" '
        $0 == "NUMBER=" selected {
            active=1
        }

        active && index($0, key "=") == 1 {
            sub("^" key "=", "")
            print
            exit
        }

        active && $0 == "---" {
            exit
        }
    ' "$DETAIL_FILE"
}

show_menu() {
    kernel="$1"
    tty="${MENU_TTY:-/dev/tty1}"

    set -- \
        --clear \
        --title "Snapshot boot - Snapper ${SNAPPER_CONFIG}" \
        --backtitle "UKI ${kernel} | Arrow keys: navigate | Enter: select | Esc: normal boot" \
        --cancel-label "Normal boot" \
        --menu "Select a snapshot:" \
        26 116 18

    while IFS= read -r tag && IFS= read -r text; do
        set -- "$@" "$tag" "$text"
    done <"$MENU_FILE"

    dialog "$@" <"$tty" 2>&1 1>"$tty"
}

confirm_snapshot() {
    selected="$1"
    kernel="$2"
    tty="${MENU_TTY:-/dev/tty1}"
    status="$(detail "$selected" KERNEL_STATUS)"

    if [ "$status" = "OK" ]; then
        kernel_line="UKI kernel ${kernel}: module directory found"
    else
        kernel_line="WARNING: /usr/lib/modules/${kernel} is missing"
    fi

    message="Number:         ${selected}
Type:           $(detail "$selected" TYPE)
Pre-number:     $(detail "$selected" PRE_NUMBER)
Date:           $(detail "$selected" DATE)
User:           $(detail "$selected" USER)
Cleanup:        $(detail "$selected" CLEANUP)
Description:    $(detail "$selected" DESCRIPTION)
Userdata:       $(detail "$selected" USERDATA)

${kernel_line}

The snapshot will be mounted read-only.
The existing Dracut overlay module will provide the writable layer."

    if [ "$status" != "OK" ] &&
       [ "${REQUIRE_MATCHING_KERNEL:-no}" = "yes" ]; then
        dialog \
            --title "Incompatible snapshot" \
            --msgbox "$message

Boot is blocked by the current configuration." \
            25 90 \
            <"$tty" \
            >"$tty" \
            2>"$tty"

        return 1
    fi

    dialog \
        --title "Confirm snapshot boot" \
        --yes-label "Boot" \
        --no-label "Back" \
        --yesno "$message" \
        25 90 \
        <"$tty" \
        >"$tty" \
        2>"$tty"
}

mount_snapshot() {
    device="$1"
    selected="$2"

    subvolume="${NORMAL_ROOT_SUBVOL}/${SNAPSHOT_DIRECTORY}/${selected}/snapshot"
    flags="$(snapshot_rootflags "$subvolume")"

    mkdir -p /sysroot

    mount \
        -t btrfs \
        -o "$flags" \
        "$device" \
        /sysroot

    printf '%s\n' "$selected" >"${STATE_DIR}/snapshot-number"
    printf '%s\n' "$subvolume" >"${STATE_DIR}/selected-subvolume"
    printf '%s\n' "$flags" >"${STATE_DIR}/rootflags"

    log "snapshot ${selected} mounted on /sysroot"
}

main() {
    b_pressed || exit 0

    prepare_console

    device="$(resolve_root_device)" || {
        dialog \
            --msgbox "Unable to resolve the Btrfs root device." \
            10 70 \
            <"$MENU_TTY" \
            >"$MENU_TTY" \
            2>"$MENU_TTY"

        restore_console
        exit 0
    }

    if ! mount \
        -t btrfs \
        -o ro,subvolid=5 \
        "$device" \
        "$BTRFS_TOP"
    then
        dialog \
            --msgbox "Unable to mount the Btrfs top level: ${device}" \
            10 78 \
            <"$MENU_TTY" \
            >"$MENU_TTY" \
            2>"$MENU_TTY"

        restore_console
        exit 0
    fi

    kernel="$(uname -r)"

    if ! build_menu "$kernel"; then
        dialog \
            --msgbox "No usable Snapper snapshots were found." \
            10 70 \
            <"$MENU_TTY" \
            >"$MENU_TTY" \
            2>"$MENU_TTY"

        umount "$BTRFS_TOP" 2>/dev/null || true
        restore_console
        exit 0
    fi

    while :; do
        selected="$(show_menu "$kernel")" || {
            umount "$BTRFS_TOP" 2>/dev/null || true
            restore_console
            exit 0
        }

        if confirm_snapshot "$selected" "$kernel"; then
            umount "$BTRFS_TOP" 2>/dev/null || true

            if ! mount_snapshot "$device" "$selected"; then
                dialog \
                    --msgbox "Snapshot mount failed. Continuing with normal boot." \
                    11 78 \
                    <"$MENU_TTY" \
                    >"$MENU_TTY" \
                    2>"$MENU_TTY"
            fi

            restore_console
            exit 0
        fi
    done
}

main "$@"