#!/usr/bin/env bash

set -Eeuo pipefail

readonly INNER_MODE="//inner"

script_path="$(readlink -f -- "$0")"
script_name="$(basename -- "$script_path")"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_name="$(basename -- "$repository_root")"
cleanup_required=false

# The path is runtime-derived so setup.sh works from any current directory.
# shellcheck disable=SC1090,SC1091
source "$repository_root/lib/common.sh"

setup.load_configuration() {
	local config_file="$repository_root/setup.conf"

	common.require_readable_file "$config_file" "Configuration file"
	# The configuration path is runtime-derived so the script works from any cwd.
	# shellcheck disable=SC1090,SC1091
	source "$config_file"

	common.require_nonempty "root_dev" "${root_dev:-}"
	common.require_nonempty "efi_dev" "${efi_dev:-}"
	common.require_nonempty "rescue_dev" "${rescue_dev:-}"
	common.require_nonempty "mp" "${mp:-}"
	common.require_nonempty "root_sub_vol" "${root_sub_vol:-}"
	common.require_nonempty "suite" "${suite:-}"
	common.require_nonempty "pre_download" "${pre_download:-}"
	[[ $rescue_dev != */* && $rescue_dev != *..* ]] ||
		log.die "rescue_dev must be a device name relative to /dev."
	[[ $rescue_dev != "$root_dev" && $rescue_dev != "$efi_dev" ]] ||
		log.die "rescue_dev must be distinct from root_dev and efi_dev."
}

setup.show_help() {
	cat <<-'EOF'
		Configure an Ubuntu installation with a LUKS-encrypted Btrfs root,
		Secure Boot, UKIs, TPM2 unlock, and Snapper snapshot support.

		Usage: sudo ./setup.sh [option]

		Options:
		  -h, --help                    show this help
		  --setup-tpm-luks-auto-unlock  enroll TPM-based LUKS unlock
		  --seal-luks-disk-tpm          replace all TPM2 tokens and reseal
	EOF
}

setup.parse_arguments() {
	case ${1:-} in
	'')
		return
		;;
	-h | -\? | --help)
		setup.show_help
		exit 0
		;;
	--setup-tpm-luks-auto-unlock)
		common.require_commands tpm-enroll
		tpm-enroll
		exit 0
		;;
	--seal-luks-disk-tpm)
		common.require_commands tpm-reseal
		tpm-reseal --wipe-all-tpm2
		exit 0
		;;
	--*)
		log.die "Invalid option $1. Use --help for more information."
		;;
	*)
		log.die "Unexpected argument: $1"
		;;
	esac
}

setup.prepare_target() {
	log.info "Prepare installation target"
	umount /target/boot/efi
	umount /target/cdrom
	umount /target
	mkdir "$mp"
}

setup.install_rescue_system() {
	common.require_commands apt-get env
	log.section "Persistent rescue system"
	log.info "Install rescue-system filesystem and synchronization tools in the live environment"
	apt-get install -y dosfstools e2fsprogs rsync
	log.info "Create the rescue system from /cdrom on /dev/$rescue_dev"
	env \
		repository_root="$repository_root" \
		SOURCE_DIR=/cdrom \
		TARGET_DEV="/dev/$rescue_dev" \
		"$repository_root/rescue/script/install-rescue-live"
	log.section_end
}

setup.prepare_chroot() {
	log.info "Prepare $mp for chroot"
	mount --rbind /dev "$mp/dev"
	mount --make-rslave "$mp/dev"
	mount -t proc proc "$mp/proc"
	mount -t devpts pts "$mp/dev/pts"
	mount --rbind /sys "$mp/sys"
	mount --make-rslave "$mp/sys"
	mount -t tmpfs tmpfs "$mp/run"
	mount -o "subvol=$root_sub_vol/@home" /dev/mapper/root "$mp/home"
	mount "/dev/$efi_dev" "$mp/boot/efi"
	mkdir -p "$mp/sys/firmware/efi/efivars"
	mount --bind /sys/firmware/efi/efivars "$mp/sys/firmware/efi/efivars"
	mkdir -p "$mp/run/dbus"

	if [[ -e $mp/etc/resolv.conf || -L $mp/etc/resolv.conf ]]; then
		mv "$mp/etc/resolv.conf" "$mp/etc/resolv.conf.chroot-save"
	fi

	cat >"$mp/etc/resolv.conf" <<-'EOF'
		nameserver 1.1.1.1
		nameserver 8.8.8.8
	EOF

	cat >"$mp/usr/sbin/policy-rc.d" <<-'EOF'
		#!/bin/sh
		exit 101
	EOF
	chmod 0755 "$mp/usr/sbin/policy-rc.d"
}

setup.run_inner_installation() {
	local inner_repository="/root/$repository_name"

	cp -Rf "$repository_root" "$mp/root/"
	chmod a+x "$mp$inner_repository/$script_name"
	log.info "Run installation phases in the target chroot"
	unshare --mount --fork chroot "$mp" "$inner_repository/$script_name" "$INNER_MODE"
}

setup.pre_download_all() {
	local -a packages=(
		asciidoc-base binutils build-essential ca-certificates coreutils cryptsetup-bin
		cryptsetup-initramfs curl dialog dosfstools dracut e2fsprogs efibootmgr findutils fwupd
		fwupd-unsigned git golang-go jq libpcsclite-dev libpcsclite1
		libtss2-esys-3.0.2-0t64 libtss2-mu-4.0.1-0t64 libtss2-rc0t64
		libtss2-tcti-tabrmd0 openssl pcscd pkgconf pkgconf-bin refind rsync
		sbsigntool snapper systemd-cryptsetup systemd-ukify tpm2-tools tpm2-tss
		util-linux
	)

	apt install --no-install-recommends -y --download-only \
		btrfs-assistant btrfsmaintenance
	apt install --download-only -y "${packages[@]}"
	apt install -y openssh-server open-vm-tools-desktop
}

setup.inner_installation() {
	cd "$repository_root"
	dbus-daemon --system --fork
	rm -rf -- "/boot/efi/EFI/$suite"
	apt-get update

	if [[ $pre_download == yes ]]; then
		setup.pre_download_all
	fi

	log.info "Install target initramfs integration for the configured LUKS root"
	apt-get install -y cryptsetup-initramfs

	# The Btrfs/LUKS storage phase has already completed outside the chroot.
	# Security-sensitive phase coordinators execute as isolated entry points.
	"$repository_root/secure-boot/scripts/secure-boot-setup"
	"$repository_root/btrfs-snapshots-mng/scripts/btrfs-snapshots-mng-setup"
	"$repository_root/uki/scripts/install-uki"
}

setup.restore_chroot_files() {
	rm -f -- "$mp/usr/sbin/policy-rc.d" "$mp/etc/resolv.conf"
	if [[ -e $mp/etc/resolv.conf.chroot-save || -L $mp/etc/resolv.conf.chroot-save ]]; then
		mv "$mp/etc/resolv.conf.chroot-save" "$mp/etc/resolv.conf"
	fi
}

setup.unmount_everything() {
	local lazy_fallback="${1:-false}"
	local target
	local index
	local failed=0
	local -a mounts=()

	[[ -e $mp ]] || return 0
	setup.restore_chroot_files
	mapfile -t mounts < <(findmnt -Rrn -o TARGET "$mp" 2>/dev/null)

	for ((index = ${#mounts[@]} - 1; index >= 0; index--)); do
		target="${mounts[index]}"
		mountpoint -q "$target" || continue
		log.info "Unmounting $target"

		if umount "$target"; then
			continue
		fi

		log.warn "Retrying unmount: $target"
		sync
		sleep 0.2
		if umount "$target"; then
			continue
		fi

		if [[ $lazy_fallback == true ]] && umount -l "$target"; then
			continue
		fi

		log.error "Unable to unmount $target"
		failed=1
	done

	sleep 2
	cryptsetup close root
	return "$failed"
}

setup.cleanup_on_exit() {
	local status=$?

	if [[ $cleanup_required == true ]]; then
		setup.unmount_everything true || status=1
	fi
	exit "$status"
}

setup.main() {
	common.require_root
	setup.load_configuration
	log.info "Script path: $script_path"

	if [[ ${1:-} == "$INNER_MODE" ]]; then
		setup.inner_installation
		return
	fi

	setup.parse_arguments "$@"
	[[ -n ${PASSPHRASE:-} ]] || log.die "PASSPHRASE must be configured for the root volume."

	setup.prepare_target
	cleanup_required=true
	trap setup.cleanup_on_exit EXIT

	cd "$repository_root"
	"$repository_root/btrfs-root/scripts/btrfs-root-setup"
	setup.prepare_chroot
	setup.run_inner_installation
	setup.unmount_everything
	cleanup_required=false
	trap - EXIT
	setup.install_rescue_system
	log.info "Finished"
}

setup.main "$@"
