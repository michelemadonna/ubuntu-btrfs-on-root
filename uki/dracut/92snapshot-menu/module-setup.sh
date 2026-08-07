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

    #
    # NON CAMBIARE:
    # la validazione UKI si aspetta /usr/libexec/snapshot-menu
    #
    inst_simple \
        "$moddir/snapshot-menu.sh" \
        "/usr/libexec/snapshot-menu"

    #
    # NON CAMBIARE:
    # la validazione UKI si aspetta /etc/snapshot-menu.conf
    #
    inst_simple \
        "$moddir/snapshot-menu.conf" \
        "/etc/snapshot-menu.conf"

    #
    # Deve precedere:
    #
    # 70overlayfs -> pre-mount 01
    #
    inst_hook \
        pre-mount \
        00 \
        "$moddir/snapshot-menu-hook.sh"
}