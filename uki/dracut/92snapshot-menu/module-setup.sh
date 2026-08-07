#!/bin/bash

check() {
    require_binaries \
        dialog mount umount find sort sed grep tr dd stty uname awk \
        blkid head chvt fgconsole setterm sleep clear cat || return 1

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

    command -v plymouth >/dev/null 2>&1 && inst_multiple plymouth

    inst_simple "$moddir/snapshot-menu.conf" "/etc/snapshot-menu.conf"
    inst_hook pre-mount 05 "$moddir/snapshot-menu.sh"
}