#!/bin/bash

check() {
    return 0
}

depends() {
    echo "btrfs rootfs-block plymouth overlayfs"
    return 0
}

install() {
    inst_multiple \
        /bin/bash \
        mount \
        umount \
        mkdir \
        rm \
        mv \
        sort \
        sed \
        head \
        sleep \
        readlink \
        chvt \
        plymouth \
        stty \
        touch

    inst_simple \
        "$moddir/snapshot-menu.sh" \
        "/usr/libexec/snapshot-menu"

    inst_simple \
            "$moddir/snapshot-menu.conf" \
            "/etc/snapshot-menu.conf"
    

    inst_hook \
        pre-mount \
        00 \
        "$moddir/snapshot-menu-hook.sh"
}
