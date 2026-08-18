#!/bin/bash

# Dracut discovers these three function names as part of its module API.
# They are intentionally not project-namespaced.

check() {
	return 0
}

depends() {
	printf '%s\n' "btrfs rootfs-block plymouth overlayfs"
	return 0
}

# Dracut defines moddir before invoking this module API function.
# shellcheck disable=SC2154
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

	if grep -qE \
		'^SNAPSHOT_INPUT_GRAB=(yes|true|1)$' \
		/etc/snapshot-menu.conf; then

		inst_simple \
			"$moddir/listener/snapshot-key-listener-start" \
			"/usr/libexec/snapshot-key-listener-start"

		inst_simple \
			"$moddir/snapshot-key-listener.service" \
			"/usr/lib/systemd/system/snapshot-key-listener.service"

		mkdir -p \
			"$initdir/etc/systemd/system/sysinit.target.wants"

		ln -sfn \
			/usr/lib/systemd/system/snapshot-key-listener.service \
			"$initdir/etc/systemd/system/sysinit.target.wants/snapshot-key-listener.service"
	fi
}
