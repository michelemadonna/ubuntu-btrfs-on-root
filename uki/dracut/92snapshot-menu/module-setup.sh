#!/bin/bash

check() {
    require_binaries \
        dialog mount umount find sort sed grep tr dd stty uname awk \
        blkid head chvt fgconsole setterm sleep clear cat ||
        return 1

    return 0
}

depends() {
    echo "base rootfs-block btrfs"
    return 0
}

install() {
    inst_multiple \
        dialog mount umount find sort sed grep tr dd stty uname awk \
        blkid head chvt fgconsole setterm sleep clear cat

    if command -v plymouth >/dev/null 2>&1; then
        inst_multiple plymouth
    fi

    inst_simple \
        "$moddir/snapshot-menu.conf" \
        "/etc/snapshot-menu.conf"

    # The actual menu runs as a separate process.
    inst_simple \
        "$moddir/snapshot-menu.sh" \
        "/usr/libexec/snapshot-menu"

    # Only this tiny wrapper is sourced by Dracut.
    inst_hook \
        pre-mount \
        05 \
        "$moddir/snapshot-menu-hook.sh"
}