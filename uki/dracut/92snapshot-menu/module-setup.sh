#!/bin/bash

check() {
    return 0
}

depends() {
    echo "btrfs rootfs-block plymouth"
    return 0
}

install() {
    inst_multiple \
        /bin/bash \
        mount \
        umount \
        mkdir \
        mv \
        sort \
        sed \
        head \
        sleep \
        readlink \
        chvt \
        plymouth \
        stty

    #
    # Source:
    #   snapshot-menu.sh
    #
    # Installed inside initrd as:
    #   /usr/libexec/snapshot-menu
    #
    # DO NOT change this destination:
    # the UKI validation expects it.
    #
    inst_simple \
        "$moddir/snapshot-menu.sh" \
        "/usr/libexec/snapshot-menu"

    #
    # Configuration.
    #
    inst_simple \
            "$moddir/snapshot-menu.conf" \
            "/etc/snapshot-menu.conf"

    #
    # Run before root is mounted.
    #
    inst_hook \
        pre-mount \
        20 \
        "$moddir/snapshot-menu-hook.sh"
}
