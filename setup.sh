#!/usr/bin/env bash

set -Eeuo pipefail

readonly INNER_MODE="//inner"

script_path="$(readlink -f -- "$0")"
script_name="$(basename -- "$script_path")"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_name="$(basename -- "$repository_root")"
cleanup_required=false
setup_action=install

# The path is runtime-derived so setup.sh works from any current directory.
# shellcheck disable=SC1090,SC1091
source "$repository_root/lib/common.sh"
# shellcheck source=lib/tui.sh
source "$repository_root/lib/tui.sh"

setup.write_config_value() {
	local file=$1 name=$2 value=$3
	printf 'export %s=%q\n' "$name" "$value" >>"$file"
}

setup.mounted_device() {
	local mountpoint_path=$1
	local source

	source="$(findmnt -rn -M "$mountpoint_path" -o SOURCE 2>/dev/null || true)"
	source=${source%%\[*}
	[[ $source == /dev/* ]] || return 1
	readlink -f -- "$source"
}

setup.minimum_rescue_size_mib() {
	local source_directory=${1:-/cdrom}
	local source_size_mib=0

	if [[ -d $source_directory ]]; then
		read -r source_size_mib _ < <(du -sm -- "$source_directory")
	fi
	if ((source_size_mib + 256 > 7168)); then
		printf '%s\n' "$((source_size_mib + 256 + 512))"
	else
		printf '7680\n'
	fi
}

setup.device_size_mib() {
	local device=$1
	printf '%s\n' "$(($(blockdev --getsize64 "$device") / 1024 / 1024))"
}

setup.read_efi_uint8() {
	local name=$1
	local file

	file="$(find /sys/firmware/efi/efivars -maxdepth 1 -name "${name}-*" -print -quit 2>/dev/null)"
	[[ -n $file ]] || return 1
	od -An -j4 -N1 -t u1 "$file" | tr -d '[:space:]'
}

setup.detect_secure_boot_mode() {
	local setup_mode secure_boot

	setup_mode="$(setup.read_efi_uint8 SetupMode 2>/dev/null || true)"
	secure_boot="$(setup.read_efi_uint8 SecureBoot 2>/dev/null || true)"
	if [[ $setup_mode == 1 ]]; then
		printf 'setup\n'
	elif [[ $secure_boot == 1 ]]; then
		printf 'enabled\n'
	elif [[ $secure_boot == 0 ]]; then
		printf 'disabled\n'
	else
		printf 'unknown\n'
	fi
}

setup.generate_configuration() {
	local config_file=$1
	local disk default_disk root_path efi_path boot_path rescue_path name type size detail confirmation config_mode config_name
	local detected_root_path detected_efi_path detected_boot_path boot_default reuse_boot_as_rescue=no install_rescue=yes
	local minimum_rescue_mib boot_size_mib
	local root_dev=sda3 efi_dev=sda2 boot_dev='' rescue_dev=sda1 iter_time=3000 swap_size=4G suite=resolute suite_type=ubuntu
	local PASSPHRASE=password mok_pin='' secure_boot_enrollment=sbctl secure_boot_mode EXPERIMENTAL_SBCTL_APPEND=false
	local pre_download=yes enable_tpm=yes snapshot_menu=yes enlarge=no snapshot_menu_pin=yes snapshot_menu_pin_value=123456
	local mp=/mnt/root keyslot_size=32m btrfs_options='defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1'
	local -a disk_items=() partition_items=() efi_items=() boot_items=() rescue_items=()

	common.require_commands bash blockdev du find findmnt grep lsblk mktemp mv od readlink stat tr
	[[ -r $TUI_INPUT_DEVICE ]] || log.die "Interactive terminal is unavailable: $TUI_INPUT_DEVICE"
	log.section "Guided setup.conf creation"
	log.warn "This procedure is intended only for a freshly installed Ubuntu system created from the live environment."
	log.warn "It is not suitable for converting an existing production system."
	log.info "The wizard is using the built-in supported defaults."

	log.section "Storage configuration"
	detected_root_path="$(setup.mounted_device /target || true)"
	detected_efi_path="$(setup.mounted_device /target/boot/efi || true)"
	detected_boot_path="$(setup.mounted_device /target/boot || true)"
	if [[ -n $detected_root_path ]]; then
		root_dev=${detected_root_path#/dev/}
		mp=/target
		log.info "Detected installed root $detected_root_path mounted at /target"
	fi
	if [[ -n $detected_efi_path ]]; then
		efi_dev=${detected_efi_path#/dev/}
		log.info "Detected EFI System Partition $detected_efi_path mounted at /target/boot/efi"
	fi
	if [[ -n $detected_boot_path && $detected_boot_path != "$detected_root_path" ]]; then
		boot_dev=${detected_boot_path#/dev/}
		log.info "Detected separate boot partition $detected_boot_path mounted at /target/boot"
	else
		detected_boot_path=""
		log.info "No separate /boot mount detected; boot_dev remains optional"
	fi
	while read -r name type size detail; do
		[[ $type == disk ]] || continue
		disk_items+=("$name|$name $size ${detail:-unknown model}")
	done < <(lsblk -dnpo NAME,TYPE,SIZE,MODEL)
	((${#disk_items[@]} > 0)) || log.die "No installation disks were discovered."
	default_disk="$(lsblk -ndo PKNAME "/dev/$root_dev" 2>/dev/null || true)"
	default_disk=${default_disk:+/dev/$default_disk}
	disk="$(tui.select_one "Select the disk containing the installed Ubuntu system" "${default_disk:-/dev/sda}" "${disk_items[@]}")" ||
		log.die "Invalid disk selection."

	while read -r name type size detail; do
		[[ $type == part ]] || continue
		partition_items+=("$name|$name $size ${detail:-unknown filesystem}")
	done < <(lsblk -nrpo NAME,TYPE,SIZE,FSTYPE "$disk")
	((${#partition_items[@]} >= 3)) || log.die "Selected disk must expose at least three partitions."
	root_path="$(tui.select_one "Select the Btrfs root partition" "/dev/$root_dev" "${partition_items[@]}")" ||
		log.die "Invalid root partition selection."
	for detail in "${partition_items[@]}"; do
		[[ ${detail%%|*} == "$root_path" ]] || efi_items+=("$detail")
	done
	efi_path="$(tui.select_one "Select the EFI System Partition" "/dev/$efi_dev" "${efi_items[@]}")" ||
		log.die "Invalid EFI partition selection."
	boot_items+=("none|No separate /boot partition")
	for detail in "${partition_items[@]}"; do
		[[ ${detail%%|*} == "$root_path" || ${detail%%|*} == "$efi_path" ]] || boot_items+=("$detail")
	done
	boot_default=${detected_boot_path:-none}
	boot_path="$(tui.select_one "Select the optional separate /boot partition" "$boot_default" "${boot_items[@]}")" ||
		log.die "Invalid boot partition selection."
	[[ $boot_path != none ]] || boot_path=""

	log.section "Distribution configuration"
	suite="$(tui.select_one "Select the distribution suite/release" "$suite" 'resolute|Ubuntu Resolute' 'noble|Ubuntu Noble' 'kali|Kali Linux')" ||
		log.die "Invalid suite selection."
	suite_type="$(tui.select_one "Select the distribution type used for the rEFInd icon" "$suite_type" 'ubuntu|Ubuntu' 'kali|Kali Linux')" ||
		log.die "Invalid distribution type selection."
	if [[ $suite == kali ]]; then
		suite_type=kali
	fi
	[[ $suite =~ ^[a-z0-9][a-z0-9._-]*$ ]] || log.die "Suite must be a safe lowercase identifier."
	[[ $suite_type =~ ^[a-z0-9][a-z0-9._-]*$ ]] || log.die "Distribution icon identifier is invalid."

	if [[ $suite_type == kali ]]; then
		install_rescue=no
		log.info "Kali Linux does not support rescue-system creation during installation"
	else
		install_rescue="$(tui.toggle "Create the persistent rescue system" "$install_rescue")" ||
			log.die "Invalid rescue-system toggle."
	fi
	if [[ $install_rescue == yes && -n $boot_path ]]; then
		minimum_rescue_mib="$(setup.minimum_rescue_size_mib /cdrom)"
		boot_size_mib="$(setup.device_size_mib "$boot_path")"
		if ((boot_size_mib >= minimum_rescue_mib)); then
			log.info "$boot_path is large enough for the live system and writable persistence; suggested rescue target"
			reuse_boot_as_rescue="$(tui.toggle "Use $boot_path as the rescue partition after copying /boot into Btrfs" yes)" ||
				log.die "Invalid boot-partition reuse toggle."
		else
			log.info "$boot_path is ${boot_size_mib} MiB; rescue reuse requires at least ${minimum_rescue_mib} MiB"
		fi
	fi

	if [[ $install_rescue == no ]]; then
		rescue_path=""
	elif [[ $reuse_boot_as_rescue == yes ]]; then
		rescue_path=$boot_path
	else
		for detail in "${partition_items[@]}"; do
			[[ ${detail%%|*} == "$root_path" || ${detail%%|*} == "$efi_path" || ${detail%%|*} == "$boot_path" ]] || rescue_items+=("$detail")
		done
		rescue_path="$(tui.select_one "Select the oversized partition reserved for rescue" "/dev/$rescue_dev" "${rescue_items[@]}")" ||
			log.die "Invalid rescue partition selection."
	fi
	swap_size="$(tui.input "Btrfs swapfile size" "$swap_size")"
	[[ $swap_size =~ ^[1-9][0-9]*[KMGTP]$ ]] || log.die "Swap size must use a value such as 4G."

	root_dev=${root_path#/dev/}
	efi_dev=${efi_path#/dev/}
	boot_dev=${boot_path#/dev/}
	rescue_dev=${rescue_path#/dev/}

	log.section "Encryption and boot security"
	secure_boot_mode="$(setup.detect_secure_boot_mode)"
	log.info "Current Secure Boot firmware state: $secure_boot_mode"
	if [[ $secure_boot_mode != setup ]]; then
		log.warn "Firmware is not in Setup Mode; sbctl can create and use signing keys, but direct firmware enrollment cannot be completed now."
	fi
	secure_boot_enrollment="$(tui.select_one "Select the Secure Boot enrollment method" "$secure_boot_enrollment" \
		'sbctl|Direct firmware enrollment with sbctl' \
		'mok|Shim and Machine Owner Key enrollment')" || log.die "Invalid Secure Boot enrollment method."
	if [[ $secure_boot_enrollment == sbctl && $secure_boot_mode != setup ]]; then
		log.warn "sbctl was selected while firmware is not in Setup Mode; configuration will continue without automatic firmware enrollment."
	fi
	iter_time="$(tui.input "Argon2id time target in milliseconds" "$iter_time")"
	PASSPHRASE="$(tui.password "Initial LUKS passphrase" "$PASSPHRASE")"
	if [[ $secure_boot_enrollment == mok ]]; then
		mok_pin="$(tui.password "MOK enrollment PIN" 123456)"
		[[ -n $mok_pin ]] || log.die "MOK PIN cannot be empty."
	fi
	[[ $iter_time =~ ^[1-9][0-9]*$ ]] || log.die "Argon2id time target must be a positive integer."
	[[ -n $PASSPHRASE ]] || log.die "LUKS passphrase cannot be empty."

	log.section "Optional features"
	pre_download="$(tui.toggle "Pre-download target packages" "$pre_download")" || log.die "Invalid pre-download toggle."
	enable_tpm="$(tui.toggle "Install TPM integration" "$enable_tpm")" || log.die "Invalid TPM toggle."
	snapshot_menu="$(tui.toggle "Install the early-boot snapshot selector" "$snapshot_menu")" || log.die "Invalid snapshot-menu toggle."
	enlarge="$(tui.toggle "Extend the root partition to available space" "$enlarge")" || log.die "Invalid enlargement toggle."

	if [[ $snapshot_menu == yes ]]; then
		snapshot_menu_pin="$(tui.toggle "Protect snapshot selection with a PIN" "$snapshot_menu_pin")" ||
			log.die "Invalid snapshot PIN selection."
		if [[ $snapshot_menu_pin == yes ]]; then
			snapshot_menu_pin_value="$(tui.password "Snapshot selector PIN" "$snapshot_menu_pin_value")"
		fi
	fi

	local temporary_config
	temporary_config="$(mktemp "$repository_root/.setup.conf.XXXXXX")"
	chmod 0600 "$temporary_config"
	setup.write_config_value "$temporary_config" root_dev "$root_dev"
	setup.write_config_value "$temporary_config" efi_dev "$efi_dev"
	setup.write_config_value "$temporary_config" boot_dev "$boot_dev"
	setup.write_config_value "$temporary_config" mp "$mp"
	setup.write_config_value "$temporary_config" rescue_dev "$rescue_dev"
	setup.write_config_value "$temporary_config" install_rescue "$install_rescue"
	setup.write_config_value "$temporary_config" keyslot_size "$keyslot_size"
	setup.write_config_value "$temporary_config" iter_time "$iter_time"
	setup.write_config_value "$temporary_config" enlarge "$enlarge"
	setup.write_config_value "$temporary_config" swap_size "$swap_size"
	setup.write_config_value "$temporary_config" btrfs_options "$btrfs_options"
	setup.write_config_value "$temporary_config" suite "$suite"
	setup.write_config_value "$temporary_config" suite_type "$suite_type"
	setup.write_config_value "$temporary_config" secure_boot_mode "$secure_boot_mode"
	setup.write_config_value "$temporary_config" secure_boot_enrollment "$secure_boot_enrollment"
	setup.write_config_value "$temporary_config" EXPERIMENTAL_SBCTL_APPEND "$EXPERIMENTAL_SBCTL_APPEND"
	setup.write_config_value "$temporary_config" PASSPHRASE "$PASSPHRASE"
	setup.write_config_value "$temporary_config" pre_download "$pre_download"
	setup.write_config_value "$temporary_config" root_sub_vol "@$suite"
	setup.write_config_value "$temporary_config" enable_tpm "$enable_tpm"
	setup.write_config_value "$temporary_config" snapshot_menu "$snapshot_menu"
	setup.write_config_value "$temporary_config" snapshot_menu_pin "$snapshot_menu_pin"
	setup.write_config_value "$temporary_config" snapshot_menu_pin_value "$snapshot_menu_pin_value"
	setup.write_config_value "$temporary_config" mok_pin "$mok_pin"
	mv "$temporary_config" "$config_file"
	log.success "Generated protected configuration: $config_file"
	log.section_end

	log.section "setup.conf summary"
	log.summary_item "Disk" "$disk"
	log.summary_item "Root" "$root_path"
	log.summary_item "ESP" "$efi_path"
	log.summary_item "Separate boot" "${boot_path:-none}"
	log.summary_item "Create rescue" "$install_rescue"
	log.summary_item "Rescue" "${rescue_path:-not configured}"
	log.summary_item "Boot reused for rescue" "$reuse_boot_as_rescue"
	log.summary_item "Mount point" "$mp"
	log.summary_item "LUKS header space" "$keyslot_size"
	log.summary_item "Btrfs options" "$btrfs_options"
	log.summary_item "Suite" "$suite"
	log.summary_item "Distribution icon" "$suite_type"
	log.summary_item "Detected Secure Boot mode" "$secure_boot_mode"
	log.summary_item "Secure Boot enrollment" "$secure_boot_enrollment"
	log.summary_item "Argon2id target" "${iter_time} ms"
	log.summary_item "Swap size" "$swap_size"
	log.summary_item "Enlarge root" "$enlarge"
	log.summary_item "Pre-download packages" "$pre_download"
	log.summary_item "TPM integration" "$enable_tpm"
	log.summary_item "Snapshot menu" "$snapshot_menu"
	log.summary_item "Snapshot menu PIN" "$snapshot_menu_pin"
	log.summary_item "Secrets" "configured; values hidden from summary"
	log.section_end

	log.section "Post-summary validation"
	[[ -r $config_file ]] || log.die "Generated configuration is not readable: $config_file"
	bash -n "$config_file" || log.die "Generated configuration contains invalid Bash syntax: $config_file"
	config_mode=$(stat -c '%a' "$config_file")
	[[ $config_mode == 600 ]] || log.die "Generated configuration permissions are $config_mode; expected 600."
	for config_name in root_dev efi_dev boot_dev mp rescue_dev install_rescue keyslot_size iter_time enlarge swap_size btrfs_options suite suite_type secure_boot_mode secure_boot_enrollment EXPERIMENTAL_SBCTL_APPEND \
		PASSPHRASE pre_download root_sub_vol enable_tpm snapshot_menu snapshot_menu_pin snapshot_menu_pin_value mok_pin; do
		grep -q "^export ${config_name}=" "$config_file" ||
			log.die "Generated configuration is missing required value: $config_name"
	done
	log.success "Configuration syntax, permissions, and required values are valid."
	log.section_end

	confirmation="$(tui.toggle "Proceed with the installation using these values" yes)" || log.die "Invalid confirmation."
	if [[ $confirmation == no ]]; then
		log.warn "Installation cancelled; generated configuration retained at $config_file"
		exit 0
	fi
}

setup.load_configuration() {
	local config_file="$repository_root/setup.conf"

	if [[ ! -e $config_file ]]; then
		setup.generate_configuration "$config_file"
	fi
	common.require_readable_file "$config_file" "Configuration file"
	# The configuration path is runtime-derived so the script works from any cwd.
	# shellcheck disable=SC1090,SC1091
	source "$config_file"

	common.require_nonempty "root_dev" "${root_dev:-}"
	common.require_nonempty "efi_dev" "${efi_dev:-}"
	common.require_nonempty "mp" "${mp:-}"
	common.require_nonempty "root_sub_vol" "${root_sub_vol:-}"
	common.require_nonempty "suite" "${suite:-}"
	common.require_nonempty "suite_type" "${suite_type:-}"
	[[ $suite_type == ubuntu || $suite_type == kali ]] || log.die "suite_type must be ubuntu or kali."
	if [[ $suite == kali && $suite_type != kali ]]; then
		log.die "suite=kali requires suite_type=kali."
	fi
	common.require_nonempty "pre_download" "${pre_download:-}"
	common.require_nonempty "secure_boot_mode" "${secure_boot_mode:-}"
	common.require_nonempty "secure_boot_enrollment" "${secure_boot_enrollment:-}"
	[[ $secure_boot_mode == setup || $secure_boot_mode == enabled || $secure_boot_mode == disabled || $secure_boot_mode == unknown ]] ||
		log.die "secure_boot_mode must be setup, enabled, disabled, or unknown."
	[[ $secure_boot_enrollment == sbctl || $secure_boot_enrollment == mok ]] ||
		log.die "secure_boot_enrollment must be sbctl or mok."
	install_rescue=${install_rescue:-yes}
	[[ $install_rescue == yes || $install_rescue == no ]] || log.die "install_rescue must be yes or no."
	if [[ $suite_type == kali ]]; then
		install_rescue=no
	fi
	EXPERIMENTAL_SBCTL_APPEND=${EXPERIMENTAL_SBCTL_APPEND:-false}
	[[ $EXPERIMENTAL_SBCTL_APPEND == true || $EXPERIMENTAL_SBCTL_APPEND == false ]] ||
		log.die "EXPERIMENTAL_SBCTL_APPEND must be true or false."
	if [[ $secure_boot_enrollment == mok ]]; then
		common.require_nonempty "mok_pin" "${mok_pin:-}"
	fi
	boot_dev=${boot_dev:-}
	[[ -z $boot_dev || ($boot_dev != */* && $boot_dev != *..*) ]] ||
		log.die "boot_dev must be empty or a device name relative to /dev."
	[[ -z $boot_dev || ($boot_dev != "$root_dev" && $boot_dev != "$efi_dev") ]] ||
		log.die "boot_dev must be distinct from root_dev and efi_dev."
	rescue_dev=${rescue_dev:-}
	if [[ ($install_rescue == yes && $suite_type != kali) || $setup_action == install-rescue-live ]]; then
		common.require_nonempty "rescue_dev" "$rescue_dev"
		[[ $rescue_dev != */* && $rescue_dev != *..* ]] ||
			log.die "rescue_dev must be a device name relative to /dev."
		[[ $rescue_dev != "$root_dev" && $rescue_dev != "$efi_dev" ]] ||
			log.die "rescue_dev must be distinct from root_dev and efi_dev."
	fi
}

setup.show_help() {
	cat <<-'EOF'
		Configure an Ubuntu installation with a LUKS-encrypted Btrfs root,
		Secure Boot, UKIs, TPM2 unlock, and Snapper snapshot support.

		Usage: sudo ./setup.sh [option]

		Options:
		  -h, --help                    show this help
		  --install-rescue-live         install only the persistent rescue system
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
	--install-rescue-live)
		setup_action=install-rescue-live
		return
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
	log.section "Installed target preflight"
	common.require_commands apt-get chmod install mkdir mount mountpoint umount
	install -d -m 1777 /tmp
	chmod 1777 /tmp
	if ! command -v btrfs >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
		log.info "Install live-session storage tools required for Btrfs conversion"
		apt-get install -y btrfs-progs rsync
	fi
	mkdir -p -- "$mp"
	if [[ $suite_type == kali ]]; then
		log.info "Kali mode: mount the configured filesystems for conversion"
		mountpoint -q "$mp" || mount "/dev/$root_dev" "$mp"
		mkdir -p "$mp/boot/efi"
		mountpoint -q "$mp/boot/efi" || mount "/dev/$efi_dev" "$mp/boot/efi"
		if [[ -n $boot_dev ]]; then
			mkdir -p "$mp/boot"
			mountpoint -q "$mp/boot" || mount "/dev/$boot_dev" "$mp/boot"
		fi
		log.success "Kali filesystems mounted and ready for validation"
		return
	fi
	mountpoint -q "$mp" || log.die "Configured target is not mounted: $mp"
	log.info "Preserve the existing target mount at $mp; storage scripts will consume it in place"
	if mountpoint -q /target/cdrom; then
		log.info "Unmount the live-medium bind mount from /target/cdrom"
		umount /target/cdrom || log.die "Unable to unmount /target/cdrom."
		log.success "Unmounted /target/cdrom"
	else
		log.info "/target/cdrom is not mounted; no unmount is required"
	fi
	log.success "Installed target is mounted and ready for validation"
	log.section_end
}

setup.install_rescue_system() {
	local rescue_source_dir=${RESCUE_SOURCE_DIR:-/cdrom}

	common.require_commands apt-get env
	log.section "Persistent rescue system"
	log.info "Install rescue-system filesystem and synchronization tools"
	apt-get install -y dosfstools e2fsprogs rsync
	log.info "Create the rescue system from $rescue_source_dir on /dev/$rescue_dev"
	env \
		repository_root="$repository_root" \
		SOURCE_DIR="$rescue_source_dir" \
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
		libtss2-tcti-tabrmd0 openssl pcscd pkgconf pkgconf-bin rsync
		sbsigntool snapper systemd-cryptsetup systemd-ukify tpm2-tools tpm2-tss
		util-linux
	)
	if [[ $suite_type == kali ]]; then
		packages+=(libtss2-esys-3.0.2-0 libtss2-mu-4.0.1-0 libtss2-rc0)
	else
		packages+=(libtss2-esys-3.0.2-0t64 libtss2-mu-4.0.1-0t64 libtss2-rc0t64 refind)
	fi

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

	if [[ ${1:-} != "$INNER_MODE" ]]; then
		setup.parse_arguments "$@"
	fi
	setup.load_configuration
	log.info "Script path: $script_path"
	if [[ $setup_action == install-rescue-live ]]; then
		setup.install_rescue_system
		return
	fi

	if [[ ${1:-} == "$INNER_MODE" ]]; then
		setup.inner_installation
		return
	fi

	[[ -n ${PASSPHRASE:-} ]] || log.die "PASSPHRASE must be configured for the root volume."

	setup.prepare_target
	cleanup_required=true
	trap setup.cleanup_on_exit EXIT

	cd "$repository_root"
	"$repository_root/btrfs-root/scripts/btrfs-root-setup"
	setup.prepare_chroot
	setup.run_inner_installation
	if [[ $install_rescue == yes && $suite_type != kali ]]; then
		setup.install_rescue_system
	else
		log.info "Persistent rescue-system creation was not requested"
	fi
	setup.restore_chroot_files
	cleanup_required=false
	trap - EXIT
	log.info "Finished; target filesystems and the root mapper remain mounted"
}

setup.main "$@"
