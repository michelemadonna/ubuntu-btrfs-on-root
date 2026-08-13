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
        touch \
        sha256sum

    inst_simple \
        "$moddir/snapshot-menu.sh" \
        "/usr/libexec/snapshot-menu"

    inst_simple \
        "/etc/snapshot-menu.conf" \
        "/etc/snapshot-menu.conf"
    

    inst_hook \
        pre-mount \
        00 \
        "$moddir/snapshot-menu-hook.sh"
    
    #inst_hook \
    #    cmdline \
    #    01\
    #    "$moddir/01-snapshot-key-listener.sh"

    inst_binary \
        "$moddir/listener/snapshot-key-listener" \
        "/usr/libexec/snapshot-key-listener"

    inst_simple \
        "$moddir/listener/snapshot-key-listener-stop" \
        "/usr/libexec/snapshot-key-listener-stop"

    inst_simple \
        "$moddir/systemd-cryptsetup@.service.d/50-snapshot-key-listener-stop.conf" \
        "/etc/systemd/system/systemd-cryptsetup@.service.d/50-snapshot-key-listener-stop.conf"
}
