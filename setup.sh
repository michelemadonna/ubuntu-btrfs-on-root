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
# shellcheck source=btrfs-root/scripts/cross-disk-migration
source "$repository_root/btrfs-root/scripts/cross-disk-migration"

setup.write_config_value() {
	local file=$1 name=$2 value=$3
	printf 'export %s=%q\n' "$name" "$value" >>"$file"
}

setup.checkpoint_dir() {
	if [[ ${1:-} == "$INNER_MODE" ]]; then
		printf '/var/lib/ubuntu-btrfs-on-root/checkpoints\n'
	else
		printf '%s/var/lib/ubuntu-btrfs-on-root/checkpoints\n' "$mp"
	fi
}

setup.checkpoint_identity() {
	local luks_uuid

	luks_uuid="$(blkid -c /dev/null -s UUID -o value "/dev/$root_dev")"
	common.require_nonempty "Target LUKS UUID" "$luks_uuid"
	printf '%s:%s\n' "$luks_uuid" "$suite"
}

setup.checkpoint_reached() {
	local mode=$1 name=$2 directory marker identity

	directory="$(setup.checkpoint_dir "$mode")"
	marker="$directory/$suite.$name"
	[[ -r $marker ]] || return 1
	identity="$(setup.checkpoint_identity)"
	[[ $(<"$marker") == "$identity" ]] ||
		log.die "Checkpoint identity mismatch: $marker"
}

setup.persist_checkpoint() {
	local mode=$1 name=$2 directory marker temporary identity

	directory="$(setup.checkpoint_dir "$mode")"
	marker="$directory/$suite.$name"
	identity="$(setup.checkpoint_identity)"
	install -d -m 0700 "$directory"
	temporary="$(mktemp "$directory/.${suite}.${name}.XXXXXX")"
	printf '%s\n' "$identity" >"$temporary"
	chmod 0600 "$temporary"
	mv -f -- "$temporary" "$marker"
	sync -f "$directory" 2>/dev/null || sync
	log.success "Installation checkpoint persisted: $name"
}

setup.run_checkpointed() {
	local mode=$1 name=$2
	shift 2

	if setup.checkpoint_reached "$mode" "$name"; then
		log.info "Resume installation: skip completed phase $name"
		return 0
	fi
	"$@"
	setup.persist_checkpoint "$mode" "$name"
}

setup.mounted_device() {
	local mountpoint_path=$1
	local source

	source="$(findmnt -rn -M "$mountpoint_path" -o SOURCE 2>/dev/null || true)"
	source=${source%%\[*}
	[[ $source == /dev/* ]] || return 1
	readlink -f -- "$source"
}

setup.read_os_release_value() {
	local file=$1 key=$2 value
	value="$(awk -v key="$key" '$0 ~ "^" key "=" { value = substr($0, index($0, "=") + 1); if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2); print value; exit }' "$file")"
	[[ -n $value ]] || log.die "Missing $key in $file."
	printf '%s\n' "$value"
}

setup.detect_source_distribution() {
	local root=$1 os_release
	if [[ -r $root/etc/os-release ]]; then
		os_release=$root/etc/os-release
	elif [[ -r $root/@/etc/os-release ]]; then
		os_release=$root/@/etc/os-release
	else log.die "Unable to find /etc/os-release in source root $root."; fi
	suite_type="$(setup.read_os_release_value "$os_release" ID)"
	suite="$(setup.read_os_release_value "$os_release" VERSION_CODENAME)"
	[[ $suite_type == ubuntu || $suite_type == kali ]] || log.die "Unsupported source distribution ID: $suite_type."
	[[ $suite =~ ^[a-z0-9][a-z0-9._-]*$ ]] || log.die "Source VERSION_CODENAME is invalid: $suite."
	log.info "Detected source distribution: $suite_type $suite"
}

setup.detect_cross_disk_distribution() {
	local source_root=$1 source_mount
	source_mount="$(mktemp -d /tmp/cross-disk-os-release.XXXXXX)"
	mount -o subvolid=5 "/dev/$source_root" "$source_mount" || {
		rmdir "$source_mount"
		log.die "Unable to mount source Btrfs filesystem read-only for distribution detection."
	}
	setup.detect_source_distribution "$source_mount"
	umount "$source_mount"
	rmdir "$source_mount"
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

setup.cleanup_sbctl_key_scan() {
	local scan_mount=$1
	local stale_mount

	if mountpoint -q "$scan_mount"; then
		umount "$scan_mount" || log.warn "Unable to unmount temporary sbctl scan mount $scan_mount"
	fi
	while IFS= read -r stale_mount; do
		[[ -n $stale_mount && $stale_mount != "$scan_mount" ]] || continue
		umount "$stale_mount" ||
			log.warn "Unable to unmount stale sbctl scan mount $stale_mount"
	done < <(findmnt -rn -S /dev/mapper/sbctl-key-scan -o TARGET 2>/dev/null || true)
	if [[ -e /dev/mapper/sbctl-key-scan ]]; then
		cryptsetup close sbctl-key-scan || log.warn "Unable to close temporary mapper sbctl-key-scan"
	fi
	rmdir "$scan_mount" 2>/dev/null || true
}

setup.stage_existing_sbctl_keys() {
	local target_disk=$1
	local root_device='' scan_device=/dev/mapper/root key_search_root partition partition_type partition_label mapper_filesystem mapped_device mounted_source mounted_fsroot
	local scan_mount staged_root="$repository_root/.sbctl-key-import" password selected
	local -a key_paths=() key_items=()
	SETUP_SBCTL_STAGED_ROOT=''
	SETUP_TARGET_LUKS_PASSWORD=''

	common.require_commands awk blkid btrfs cp cryptsetup find findmnt install lsblk mount sort umount
	while read -r partition partition_type; do
		[[ $partition_type == part ]] || continue
		cryptsetup isLuks "$partition" >/dev/null 2>&1 || continue
		partition_label="$(blkid -c /dev/null -s LABEL -o value "$partition" 2>/dev/null || true)"
		if [[ $partition_label == ROOT ]]; then
			if [[ -n $root_device ]]; then
				log.die "Disk $target_disk contains more than one LUKS partition labelled ROOT."
			fi
			root_device=$partition
		fi
	done < <(lsblk -nrpo PATH,TYPE "$target_disk")
	if [[ -z $root_device ]]; then
		log.info "No LUKS partition labelled ROOT found on $target_disk"
		return 0
	fi
	scan_mount="$(mktemp -d /tmp/sbctl-key-scan.XXXXXX)"
	if [[ ! -e $scan_device ]]; then
		password="$(tui.password "ROOT LUKS password for key discovery" password)"
		SETUP_TARGET_LUKS_PASSWORD=$password
		scan_device=/dev/mapper/sbctl-key-scan
		if ! printf '%s' "$password" | cryptsetup open --key-file=- "$root_device" sbctl-key-scan; then
			if printf '%s\n' "$password" | cryptsetup open --key-file=- "$root_device" sbctl-key-scan; then
				SETUP_TARGET_LUKS_PASSWORD=$password$'\n'
				log.warn "Unlocked ROOT using the legacy newline-terminated passphrase format"
			else
				log.warn "Unable to unlock ROOT for sbctl key discovery; continue migration without imported keys"
				setup.cleanup_sbctl_key_scan "$scan_mount"
				return 0
			fi
		fi
	else
		mapped_device="$(cryptsetup status root | awk '$1 == "device:" { print $2; exit }')"
		[[ -n $mapped_device && $(readlink -f -- "$mapped_device") == "$(readlink -f -- "$root_device")" ]] ||
			log.die "Existing mapper root does not belong to target ROOT $root_device."
		password="$(tui.password "ROOT LUKS password for configuration" password)"
		if ! printf '%s' "$password" | cryptsetup open --test-passphrase --key-file=- "$root_device"; then
			if printf '%s\n' "$password" | cryptsetup open --test-passphrase --key-file=- "$root_device"; then
				password=$password$'\n'
				log.warn "Validated the legacy newline-terminated ROOT passphrase format"
			else
				log.die "ROOT LUKS password validation failed for the already-open target mapper."
			fi
		fi
		SETUP_TARGET_LUKS_PASSWORD=$password
	fi
	mapper_filesystem="$(blkid -c /dev/null -s TYPE -o value "$scan_device" 2>/dev/null || true)"
	if [[ $mapper_filesystem != btrfs ]]; then
		log.info "ROOT contains no Btrfs filesystem to inspect; continue with new-system migration"
		setup.cleanup_sbctl_key_scan "$scan_mount"
		return 0
	fi
	if [[ $scan_device == /dev/mapper/root ]] && mountpoint -q "$mp"; then
		mounted_source="$(findmnt -rn -M "$mp" -o SOURCE)"
		mounted_source=${mounted_source%%\[*}
		mounted_fsroot="$(findmnt -rn -M "$mp" -o FSROOT)"
		[[ $(readlink -f -- "$mounted_source") == "$(readlink -f -- /dev/mapper/root)" && $mounted_fsroot == / ]] ||
			log.die "Existing target mount at $mp is not the Btrfs top level from /dev/mapper/root."
		key_search_root=$mp
		log.info "Reuse mounted target Btrfs top level at $mp for sbctl key discovery"
	else
		if ! mount -o subvolid=5 "$scan_device" "$scan_mount"; then
			log.warn "Unable to mount target Btrfs for sbctl key discovery; continue without imported keys"
			setup.cleanup_sbctl_key_scan "$scan_mount"
			return 0
		fi
		key_search_root=$scan_mount
	fi
	log.info "Btrfs top-level content from LUKS ROOT on $target_disk"
	btrfs subvolume list "$key_search_root" | awk 'index($0, "/.snapshots") == 0' || true
	find "$key_search_root" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
	[[ -d $key_search_root ]] || {
		log.info "No sbctl key directory found at /var/lib/sbctl/keys"
		setup.cleanup_sbctl_key_scan "$scan_mount"
		return 0
	}
	while IFS= read -r selected; do
		[[ -f $selected/PK/PK.key && -f $selected/PK/PK.pem ]] || continue
		[[ -f $selected/KEK/KEK.key && -f $selected/KEK/KEK.pem ]] || continue
		[[ -f $selected/db/db.key && -f $selected/db/db.pem ]] || continue
		key_paths+=("$selected")
		key_items+=("$selected|${selected#"$key_search_root"}")
	done < <(
		find "$key_search_root" -type d -name .snapshots -prune -o -type d -print
	)
	if ((${#key_items[@]} == 0)); then
		log.info "No complete sbctl key hierarchy found anywhere in the target Btrfs filesystem"
		setup.cleanup_sbctl_key_scan "$scan_mount"
		return 0
	fi
	if ! selected="$(tui.select_one "Select the existing sbctl key hierarchy to import" "${key_paths[0]}" "${key_items[@]}")"; then
		setup.cleanup_sbctl_key_scan "$scan_mount"
		log.die "Invalid sbctl key hierarchy selection."
	fi
	if ! install -d -m 0700 "$staged_root" || ! cp -a -- "$selected/." "$staged_root/"; then
		setup.cleanup_sbctl_key_scan "$scan_mount"
		log.die "Unable to stage the selected sbctl key hierarchy."
	fi
	if ! find "$staged_root" -type f -print -quit | grep -q .; then
		setup.cleanup_sbctl_key_scan "$scan_mount"
		log.die "Existing sbctl key directory is empty."
	fi
	SETUP_SBCTL_STAGED_ROOT=/root/.sbctl-key-import
	log.success "Staged selected sbctl keys from ${selected#"$key_search_root"} for chroot import"
	setup.cleanup_sbctl_key_scan "$scan_mount"
}

setup.show_target_inventory() {
	local target_disk=$1 partition partition_type filesystem_type scan_mount

	log.section "Target disk inventory"
	common.require_commands blkid btrfs find lsblk mount sort umount
	log.info "Partitions currently present on $target_disk"
	lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$target_disk"
	while read -r partition partition_type; do
		[[ $partition_type == part ]] || continue
		filesystem_type="$(blkid -c /dev/null -s TYPE -o value "$partition" 2>/dev/null || true)"
		[[ $filesystem_type == btrfs ]] || continue
		scan_mount="$(mktemp -d /tmp/btrfs-root-inventory.XXXXXX)"
		if mount -o ro,subvolid=5 "$partition" "$scan_mount"; then
			log.info "Btrfs top-level content from $partition"
			btrfs subvolume list "$scan_mount" || true
			find "$scan_mount" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
			umount "$scan_mount"
		fi
		rmdir "$scan_mount"
	done < <(lsblk -nrpo PATH,TYPE "$target_disk")
	log.section_end
}

setup.generate_configuration() {
	local config_file=$1
	local disk target_disk default_disk root_path efi_path boot_path rescue_path name type size detail confirmation config_mode config_name
	local detected_root_path detected_efi_path detected_boot_path boot_default reuse_boot_as_rescue=no install_rescue=yes rescue_filesystem_label=''
	local minimum_rescue_mib boot_size_mib
	local root_dev=sda3 efi_dev=sda2 boot_dev='' rescue_dev=sda1 iter_time=3000 swap_size=4G suite='' suite_type=''
	local root_sub_vol=''
	local source_root_dev='' source_boot_dev='' target_root_dev='' target_efi_dev='' migration_mode=in_place install_mode=in_place sbctl_import_keyroot=''
	local PASSPHRASE=password mok_pin='' secure_boot_enrollment=sbctl secure_boot_mode EXPERIMENTAL_SBCTL_APPEND=false
	local pre_download=yes enable_tpm=yes snapshot_menu=yes enlarge=no snapshot_menu_pin=yes snapshot_menu_pin_value=123456
	local install_hwe_kernel=no
	local mp=/mnt/root keyslot_size=32m btrfs_options='defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1'
	local -a disk_items=() partition_items=() efi_items=() boot_items=() rescue_items=()

	common.require_commands awk bash blockdev du find findmnt grep lsblk mktemp mount mv od readlink stat tr umount
	[[ -r $TUI_INPUT_DEVICE ]] || log.die "Interactive terminal is unavailable: $TUI_INPUT_DEVICE"
	log.section "Guided setup.conf creation"
	log.warn "This procedure is intended only for a freshly installed Ubuntu system created from the live environment."
	log.warn "It is not suitable for converting an existing production system."
	log.info "The wizard is using the built-in supported defaults."
	install_mode="$(tui.select_one "Select the installation mode" "$install_mode" \
		'in_place|In Place Migration' \
		'new_setup|New Setup or Migrate From another Disk')" || log.die "Invalid installation mode selection."
	log.section "Storage configuration"
	while read -r name type size detail; do
		[[ $type == disk ]] || continue
		disk_items+=("$name|$name $size ${detail:-unknown model}")
	done < <(lsblk -dnpo NAME,TYPE,SIZE,MODEL)
	((${#disk_items[@]} > 0)) || log.die "No installation disks were discovered."
	target_disk="$(tui.select_one "Select the target disk" "${disk_items[0]%%|*}" "${disk_items[@]}")" || log.die "Invalid target disk selection."
	setup.show_target_inventory "$target_disk"
	if [[ $install_mode == in_place ]]; then
		migration_mode=in_place
	else
		setup.stage_existing_sbctl_keys "$target_disk"
		sbctl_import_keyroot=$SETUP_SBCTL_STAGED_ROOT
		if [[ -n $SETUP_TARGET_LUKS_PASSWORD ]]; then
			PASSPHRASE=$SETUP_TARGET_LUKS_PASSWORD
		fi
		if [[ -n $sbctl_import_keyroot ]]; then
			secure_boot_enrollment=existing
			log.info "Secure Boot enrollment is already complete; skip sbctl/MOK selection"
		fi
	fi
	if [[ $install_mode == new_setup ]] && cross-disk-migration.initialized_target "$target_disk"; then
		migration_mode=cross_disk
		efi_path="$(cross-disk-migration.require_unique_label "$target_disk" ESP)"
		root_path="$(cross-disk-migration.require_unique_label "$target_disk" ROOT)"
		target_efi_dev=${efi_path#/dev/}
		target_root_dev=${root_path#/dev/}
		[[ -n $SETUP_TARGET_LUKS_PASSWORD ]] ||
			log.die "Target ROOT was not unlocked during the initial LUKS discovery."
		log.info "Detected initialized target $target_disk with ESP and ROOT labels"
	elif [[ $install_mode == new_setup ]]; then
		local esp_mib=1024 root_size=all create_rescue=yes reserve_windows=no new_passphrase
		esp_mib="$(tui.input "ESP size in MiB" "$esp_mib")"
		root_size="$(tui.input "ROOT size in GiB (or all)" "$root_size")"
		create_rescue="$(tui.toggle "Create RESCUE partition" "$create_rescue")" || log.die "Invalid rescue toggle."
		reserve_windows="$(tui.toggle "Reserve space for Windows" "$reserve_windows")" || log.die "Invalid Windows toggle."
		log.section "New target layout"
		cross-disk-migration.layout "$target_disk" "$esp_mib" "$root_size" "$([[ $create_rescue == yes ]] && printf 10240 || printf 0)" "$reserve_windows"
		confirmation="$(tui.toggle "Destroy the selected target and create this layout" no)" || log.die "Invalid confirmation."
		[[ $confirmation == yes ]] || log.die "Target initialization cancelled."
		log.section "LUKS and Argon2id"
		new_passphrase="$(tui.password "ROOT LUKS passphrase" password)"
		iter_time="$(tui.input "Argon2id time target in milliseconds" "$iter_time")"
		[[ -n $new_passphrase ]] || log.die "ROOT LUKS passphrase cannot be empty."
		[[ $iter_time =~ ^[1-9][0-9]*$ ]] || log.die "Argon2id time target must be a positive integer."
		log.section_end
		cross-disk-migration.partition_new_target "$target_disk" "$esp_mib" "$root_size" "$([[ $create_rescue == yes ]] && printf 10240 || printf 0)" "$reserve_windows" "$iter_time" "$new_passphrase"
		log.warn "Re-run setup.sh to detect the initialized target and migrate the source."
		exit 0
	fi
	disk_items=()
	if [[ $install_mode == in_place ]]; then
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
	fi
	while read -r name type size detail; do
		[[ $type == disk ]] || continue
		disk_items+=("$name|$name $size ${detail:-unknown model}")
	done < <(lsblk -dnpo NAME,TYPE,SIZE,MODEL)
	((${#disk_items[@]} > 0)) || log.die "No installation disks were discovered."
	if [[ $install_mode == in_place ]]; then
		default_disk=${target_disk#/dev/}
	else
		default_disk="$(lsblk -ndo PKNAME "/dev/$root_dev" 2>/dev/null || true)"
	fi
	default_disk=${default_disk:+/dev/$default_disk}
	disk="$(tui.select_one "Select the source disk containing the installed system" "${default_disk:-/dev/sda}" "${disk_items[@]}")" ||
		log.die "Invalid disk selection."
	if [[ $install_mode == in_place ]]; then
		[[ $disk == "$target_disk" ]] || log.die "In Place Migration requires source and target to be the same disk."
	else
		[[ $disk != "$target_disk" ]] || log.die "Source and target disks must be different."
	fi

	while read -r name type size detail; do
		[[ $type == part ]] || continue
		partition_items+=("$name|$name $size ${detail:-unknown filesystem}")
	done < <(lsblk -nrpo NAME,TYPE,SIZE,FSTYPE "$disk")
	((${#partition_items[@]} >= 2)) || log.die "Selected disk must expose at least ESP and ROOT partitions."
	root_path="$(tui.select_one "Select the Btrfs root partition" "/dev/$root_dev" "${partition_items[@]}")" ||
		log.die "Invalid root partition selection."
	source_root_dev=${root_path#/dev/}
	if [[ $install_mode == in_place ]]; then
		setup.detect_source_distribution /target
	else
		setup.detect_cross_disk_distribution "$source_root_dev"
	fi
	if [[ $install_mode == in_place ]]; then
		for detail in "${partition_items[@]}"; do
			[[ ${detail%%|*} == "$root_path" ]] || efi_items+=("$detail")
		done
		efi_path="$(tui.select_one "Select the EFI System Partition" "/dev/$efi_dev" "${efi_items[@]}")" ||
			log.die "Invalid EFI partition selection."
	fi
	boot_items+=("none|No separate /boot partition")
	for detail in "${partition_items[@]}"; do
		[[ ${detail%%|*} == "$root_path" ]] && continue
		[[ $install_mode == in_place && ${detail%%|*} == "$efi_path" ]] && continue
		boot_items+=("$detail")
	done
	if [[ $install_mode == in_place ]]; then
		boot_default=${detected_boot_path:-none}
	else
		boot_default=none
	fi
	boot_path="$(tui.select_one "Select the optional separate /boot partition" "$boot_default" "${boot_items[@]}")" ||
		log.die "Invalid boot partition selection."
	[[ $boot_path != none ]] || boot_path=""
	source_boot_dev=${boot_path#/dev/}

	swap_size="$(tui.input "Btrfs swapfile size" "$swap_size")"
	[[ $swap_size =~ ^[1-9][0-9]*[KMGTP]$ ]] || log.die "Swap size must use a value such as 4G."

	if [[ $migration_mode != cross_disk ]]; then
		log.section "LUKS and Argon2id"
		iter_time="$(tui.input "Argon2id time target in milliseconds" "$iter_time")"
		PASSPHRASE="$(tui.password "Initial LUKS passphrase" "$PASSPHRASE")"
		[[ $iter_time =~ ^[1-9][0-9]*$ ]] || log.die "Argon2id time target must be a positive integer."
		log.section_end
	fi
	[[ -n $PASSPHRASE ]] || log.die "LUKS passphrase cannot be empty."

	log.section "Distribution configuration"
	root_sub_vol="$(tui.input "Btrfs root subvolume container" "@$suite")"
	[[ $root_sub_vol != /* && $root_sub_vol != *..* && $root_sub_vol =~ ^[a-zA-Z0-9_@./-]+$ ]] ||
		log.die "Btrfs root subvolume container must be a safe relative path."

	if [[ $migration_mode == cross_disk ]]; then
		root_dev=$target_root_dev
		efi_dev=$target_efi_dev
		boot_dev=''
	else
		root_dev=${root_path#/dev/}
		efi_dev=${efi_path#/dev/}
		boot_dev=${boot_path#/dev/}
	fi

	log.section "Encryption and boot security"
	secure_boot_mode="$(setup.detect_secure_boot_mode)"
	log.info "Current Secure Boot firmware state: $secure_boot_mode"
	if [[ $install_mode == in_place && $secure_boot_mode != setup ]]; then
		log.warn "Firmware is not in Setup Mode; sbctl can create and use signing keys, but direct firmware enrollment cannot be completed now."
	fi
	if [[ $install_mode == in_place || -z $sbctl_import_keyroot ]]; then
		secure_boot_enrollment="$(tui.select_one "Select the Secure Boot enrollment method" "$secure_boot_enrollment" \
			'sbctl|Direct firmware enrollment with sbctl' \
			'mok|Shim and Machine Owner Key enrollment')" || log.die "Invalid Secure Boot enrollment method."
		if [[ $secure_boot_enrollment == mok ]]; then
			mok_pin="$(tui.password "MOK enrollment PIN" 123456)"
			[[ -n $mok_pin ]] || log.die "MOK PIN cannot be empty."
		fi
		if [[ $secure_boot_enrollment == sbctl && $secure_boot_mode != setup ]]; then
			log.warn "sbctl was selected while firmware is not in Setup Mode; configuration will continue without automatic firmware enrollment."
		fi
	else
		log.info "Existing Secure Boot enrollment selected; no enrollment prompt or firmware enrollment will run"
	fi

	log.section "Optional features"
	pre_download="$(tui.toggle "Pre-download target packages" "$pre_download")" || log.die "Invalid pre-download toggle."
	enlarge="$(tui.toggle "Extend the root partition to available space" "$enlarge")" || log.die "Invalid enlargement toggle."
	if [[ $suite_type == ubuntu ]]; then
		install_hwe_kernel="$(tui.toggle "Install the Ubuntu HWE kernel" "$install_hwe_kernel")" || log.die "Invalid HWE-kernel toggle."
	else
		install_hwe_kernel=no
	fi
	if [[ $suite_type == kali ]]; then
		install_rescue=no
		log.info "Kali Linux does not support rescue-system creation during installation"
	elif [[ $install_mode == new_setup ]]; then
		rescue_path="$(cross-disk-migration.require_unique_label "$target_disk" RESCUE)"
		rescue_dev=${rescue_path#/dev/}
		rescue_filesystem_label="$(blkid -c /dev/null -s LABEL -o value "$rescue_path" 2>/dev/null || true)"
		case $rescue_filesystem_label in
		RESCUE)
			install_rescue=yes
			log.info "Target rescue partition is labelled RESCUE; install the Ubuntu live system"
			;;
		UBUNTU_LIVE)
			install_rescue=no
			log.info "Target rescue partition is already labelled UBUNTU_LIVE; skip rescue installation"
			;;
		*) log.die "Target rescue partition $rescue_path has unsupported filesystem label '${rescue_filesystem_label:-none}'." ;;
		esac
	else
		install_rescue="$(tui.toggle "Create the persistent rescue system" "$install_rescue")" ||
			log.die "Invalid rescue-system toggle."
	fi
	if [[ $install_rescue == yes && -n $boot_path && $install_mode == in_place ]]; then
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
	elif [[ $install_mode == new_setup ]]; then
		log.info "Use the target RESCUE partition without requesting a rescue device"
	elif [[ $reuse_boot_as_rescue == yes ]]; then
		rescue_path=$boot_path
	else
		for detail in "${partition_items[@]}"; do
			[[ ${detail%%|*} == "$root_path" || ${detail%%|*} == "$efi_path" || ${detail%%|*} == "$boot_path" ]] || rescue_items+=("$detail")
		done
		rescue_path="$(tui.select_one "Select the oversized partition reserved for rescue" "/dev/$rescue_dev" "${rescue_items[@]}")" ||
			log.die "Invalid rescue partition selection."
	fi
	rescue_dev=${rescue_path#/dev/}

	log.section "TPM integration"
	enable_tpm="$(tui.toggle "Install TPM integration" "$enable_tpm")" || log.die "Invalid TPM toggle."

	log.section "Snapshot menu"
	snapshot_menu="$(tui.toggle "Install the early-boot snapshot selector" "$snapshot_menu")" || log.die "Invalid snapshot-menu toggle."
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
	setup.write_config_value "$temporary_config" source_root_dev "$source_root_dev"
	setup.write_config_value "$temporary_config" source_boot_dev "$source_boot_dev"
	setup.write_config_value "$temporary_config" migration_mode "$migration_mode"
	setup.write_config_value "$temporary_config" install_mode "$install_mode"
	setup.write_config_value "$temporary_config" SBCTL_IMPORT_KEYROOT "$sbctl_import_keyroot"
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
	setup.write_config_value "$temporary_config" install_hwe_kernel "$install_hwe_kernel"
	setup.write_config_value "$temporary_config" root_sub_vol "$root_sub_vol"
	setup.write_config_value "$temporary_config" enable_tpm "$enable_tpm"
	setup.write_config_value "$temporary_config" snapshot_menu "$snapshot_menu"
	setup.write_config_value "$temporary_config" snapshot_menu_pin "$snapshot_menu_pin"
	setup.write_config_value "$temporary_config" snapshot_menu_pin_value "$snapshot_menu_pin_value"
	setup.write_config_value "$temporary_config" mok_pin "$mok_pin"
	mv "$temporary_config" "$config_file"
	log.success "Generated protected configuration: $config_file"
	log.section_end

	log.section "setup.conf summary"
	if [[ $install_mode == new_setup ]]; then
		log.summary_item "Source disk" "$disk"
		log.summary_item "Source root" "$root_path"
		log.summary_item "Source separate boot" "${boot_path:-none}"
		log.summary_item "Target disk" "$target_disk"
		log.summary_item "Target ROOT" "/dev/$root_dev"
		log.summary_item "Target ESP" "/dev/$efi_dev"
		log.summary_item "Target rescue" "${rescue_dev:+/dev/$rescue_dev}"
		log.summary_item "Install rescue live" "$install_rescue"
		log.summary_item "Rescue filesystem label" "${rescue_filesystem_label:-not configured}"
	else
		log.summary_item "Disk" "$disk"
		log.summary_item "Root" "$root_path"
		log.summary_item "ESP" "$efi_path"
		log.summary_item "Separate boot" "${boot_path:-none}"
		log.summary_item "Create rescue" "$install_rescue"
		log.summary_item "Rescue" "${rescue_path:-not configured}"
		log.summary_item "Boot reused for rescue" "$reuse_boot_as_rescue"
	fi
	log.summary_item "Mount point" "$mp"
	log.summary_item "LUKS header space" "$keyslot_size"
	log.summary_item "Btrfs options" "$btrfs_options"
	log.summary_item "Suite" "$suite"
	log.summary_item "Distribution icon" "$suite_type"
	log.summary_item "Ubuntu HWE kernel" "$install_hwe_kernel"
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
	for config_name in root_dev efi_dev boot_dev mp rescue_dev install_rescue install_hwe_kernel keyslot_size iter_time enlarge swap_size btrfs_options suite suite_type secure_boot_mode secure_boot_enrollment EXPERIMENTAL_SBCTL_APPEND \
		PASSPHRASE pre_download root_sub_vol source_root_dev source_boot_dev migration_mode install_mode SBCTL_IMPORT_KEYROOT enable_tpm snapshot_menu snapshot_menu_pin snapshot_menu_pin_value mok_pin; do
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
	install_mode=${install_mode:-in_place}
	[[ $install_mode == in_place || $install_mode == new_setup ]] || log.die "install_mode is invalid."
	migration_mode=${migration_mode:-in_place}
	[[ $migration_mode == in_place || $migration_mode == cross_disk ]] || log.die "migration_mode is invalid."
	if [[ $migration_mode == cross_disk ]]; then
		common.require_nonempty "source_root_dev" "${source_root_dev:-}"
	fi
	[[ $suite_type == ubuntu || $suite_type == kali ]] || log.die "suite_type must be ubuntu or kali."
	if [[ $suite == kali && $suite_type != kali ]]; then
		log.die "suite=kali requires suite_type=kali."
	fi
	common.require_nonempty "pre_download" "${pre_download:-}"
	install_hwe_kernel=${install_hwe_kernel:-no}
	[[ $install_hwe_kernel == yes || $install_hwe_kernel == no ]] || log.die "install_hwe_kernel must be yes or no."
	if [[ $suite_type == kali ]]; then
		install_hwe_kernel=no
	fi
	common.require_nonempty "secure_boot_mode" "${secure_boot_mode:-}"
	common.require_nonempty "secure_boot_enrollment" "${secure_boot_enrollment:-}"
	[[ $secure_boot_mode == setup || $secure_boot_mode == enabled || $secure_boot_mode == disabled || $secure_boot_mode == unknown ]] ||
		log.die "secure_boot_mode must be setup, enabled, disabled, or unknown."
	[[ $secure_boot_enrollment == sbctl || $secure_boot_enrollment == mok || $secure_boot_enrollment == existing ]] ||
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

setup.ensure_live_storage_tools() {
	if command -v btrfs >/dev/null 2>&1 && command -v cryptsetup >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1; then
		return 0
	fi
	common.require_commands apt-get
	log.info "Install live-session storage tools required by discovery and migration"
	apt-get update
	apt-get install -y btrfs-progs cryptsetup rsync
	common.require_commands btrfs cryptsetup rsync
}

setup.prepare_target() {
	local mounted_efi

	log.section "Installed target preflight"
	common.require_commands apt-get chmod install mkdir mount mountpoint umount
	install -d -m 1777 /tmp
	chmod 1777 /tmp
	setup.ensure_live_storage_tools
	mkdir -p -- "$mp"
	if [[ $migration_mode == cross_disk ]]; then
		log.info "Cross-disk mode: import the selected Btrfs source into the initialized target"
		log.info "Cross-disk migration code: $repository_root/btrfs-root/scripts/cross-disk-migration"
		cross-disk-migration.import_source "$source_root_dev" "$source_boot_dev"
		if ! setup.checkpoint_reached outer source-import; then
			setup.persist_checkpoint outer source-import
		fi
		mkdir -p "$mp/boot/efi"
		if mountpoint -q "$mp/boot/efi"; then
			mounted_efi="$(setup.mounted_device "$mp/boot/efi" || true)"
			[[ $mounted_efi == "$(readlink -f -- "/dev/$efi_dev")" ]] ||
				log.die "Existing ESP mount at $mp/boot/efi uses ${mounted_efi:-unknown}, not /dev/$efi_dev."
			log.info "Reuse already-mounted target ESP at $mp/boot/efi"
		else
			mount "/dev/$efi_dev" "$mp/boot/efi"
		fi
		log.success "Cross-disk target mounted and source imported"
		return
	fi
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

setup.ensure_target_subvolume_mount() {
	local target_path=$1 subvolume=$2 options=$3
	local mounted_source mounted_subvolume

	mkdir -p "$mp$target_path"
	if mountpoint -q "$mp$target_path"; then
		mounted_source="$(findmnt -rn -M "$mp$target_path" -o SOURCE)"
		mounted_source=${mounted_source%%\[*}
		mounted_subvolume="$(findmnt -rn -M "$mp$target_path" -o FSROOT)"
		[[ $(readlink -f -- "$mounted_source") == "$(readlink -f -- /dev/mapper/root)" ]] ||
			log.die "Existing $mp$target_path mount uses $mounted_source instead of /dev/mapper/root."
		[[ $mounted_subvolume == "/$subvolume" ]] ||
			log.die "Existing $mp$target_path mount uses Btrfs path $mounted_subvolume instead of /$subvolume."
		log.info "Reuse target subvolume $subvolume mounted at $mp$target_path"
		return
	fi
	log.info "Mount target subvolume $subvolume at $mp$target_path"
	mount -o "$options,subvol=$subvolume" /dev/mapper/root "$mp$target_path"
}

setup.prepare_chroot() {
	local mounted_source

	log.info "Prepare $mp for chroot"
	setup.ensure_target_subvolume_mount /home "$root_sub_vol/@home" "$btrfs_options"
	setup.ensure_target_subvolume_mount /var/log "$root_sub_vol/@log" "$btrfs_options"
	setup.ensure_target_subvolume_mount /var/cache "$root_sub_vol/@cache" "$btrfs_options"
	setup.ensure_target_subvolume_mount /tmp "$root_sub_vol/@tmp" "$btrfs_options"
	setup.ensure_target_subvolume_mount /var/lib/libvirt "$root_sub_vol/@libvirt" 'defaults,ssd,discard=async,noatime,space_cache=v2'
	setup.ensure_target_subvolume_mount /var/lib/docker "$root_sub_vol/@docker" 'defaults,ssd,discard=async,noatime,compress=zstd:1'
	setup.ensure_target_subvolume_mount /swap "$root_sub_vol/@swap" 'defaults,noatime'
	mountpoint -q "$mp/dev" || mount --rbind /dev "$mp/dev"
	mount --make-rslave "$mp/dev"
	mountpoint -q "$mp/proc" || mount -t proc proc "$mp/proc"
	mountpoint -q "$mp/dev/pts" || mount -t devpts pts "$mp/dev/pts"
	mountpoint -q "$mp/sys" || mount --rbind /sys "$mp/sys"
	mount --make-rslave "$mp/sys"
	mountpoint -q "$mp/run" || mount -t tmpfs tmpfs "$mp/run"
	if mountpoint -q "$mp/boot/efi"; then
		mounted_source="$(setup.mounted_device "$mp/boot/efi" || true)"
		[[ $mounted_source == "$(readlink -f -- "/dev/$efi_dev")" ]] ||
			log.die "Existing ESP mount at $mp/boot/efi uses ${mounted_source:-unknown}, not /dev/$efi_dev."
	else
		mount "/dev/$efi_dev" "$mp/boot/efi"
	fi
	mkdir -p "$mp/sys/firmware/efi/efivars"
	mountpoint -q "$mp/sys/firmware/efi/efivars" ||
		mount --bind /sys/firmware/efi/efivars "$mp/sys/firmware/efi/efivars"
	mkdir -p "$mp/run/dbus"

	if [[ ! -e $mp/etc/resolv.conf.chroot-save && ! -L $mp/etc/resolv.conf.chroot-save ]] &&
		[[ -e $mp/etc/resolv.conf || -L $mp/etc/resolv.conf ]]; then
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
	local target_keyroot="$mp/root/.sbctl-key-import"

	cp -Rf "$repository_root" "$mp/root/"
	if [[ -d $repository_root/.sbctl-key-import ]]; then
		install -d -m 0700 "$target_keyroot"
		cp -a -- "$repository_root/.sbctl-key-import/." "$target_keyroot/"
	fi
	chmod a+x "$mp$inner_repository/$script_name"
	log.info "Run installation phases in the target chroot"
	unshare --mount --fork chroot "$mp" "$inner_repository/$script_name" "$INNER_MODE"
}

setup.pre_download_all() {
	local hwe_package
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
		packages+=(libtss2-esys-3.0.2-0t64 libtss2-mu-4.0.1-0t64 libtss2-rc0t64)
		apt-cache show refind >/dev/null 2>&1 && packages+=(refind)
		if [[ $install_hwe_kernel == yes ]]; then
			hwe_package="$(setup.ubuntu_hwe_package)"
			packages+=("$hwe_package")
		fi
	fi

	apt install --no-install-recommends -y --download-only \
		btrfs-assistant btrfsmaintenance
	apt install --download-only -y "${packages[@]}"
	apt install -y openssh-server open-vm-tools-desktop
}

setup.ubuntu_hwe_package() {
	local version_id

	[[ $suite_type == ubuntu ]] || log.die "The Ubuntu HWE kernel is only supported for Ubuntu targets."
	version_id="$(setup.read_os_release_value /etc/os-release VERSION_ID)"
	[[ $version_id =~ ^[0-9]+\.[0-9]+$ ]] || log.die "Ubuntu VERSION_ID is invalid for HWE kernel selection: $version_id."
	printf 'linux-generic-hwe-%s\n' "$version_id"
}

setup.cleanup_suite_efi() {
	rm -rf -- "/boot/efi/EFI/$suite"
}

setup.install_target_packages() {
	local hwe_package
	if [[ $pre_download == yes ]]; then
		setup.pre_download_all
	fi

	log.info "Install target initramfs integration for the configured LUKS root"
	apt-get install -y btrfs-progs cryptsetup-initramfs
	if [[ $install_hwe_kernel == yes ]]; then
		hwe_package="$(setup.ubuntu_hwe_package)"
		apt-cache show "$hwe_package" | grep -q '^Package:' ||
			log.die "Requested Ubuntu HWE kernel package is unavailable: $hwe_package"
		log.info "Install Ubuntu HWE kernel package $hwe_package"
		apt-get install -y "$hwe_package"
	fi
	if [[ $secure_boot_enrollment == existing && $suite_type != kali ]]; then
		log.info "Install rEFInd in the new system without installing it into the ESP"
		printf '%s\n' 'refind refind/install_to_esp boolean false' | debconf-set-selections
		apt-get install -y --no-install-recommends refind
	fi
}

setup.prepare_inner_dbus() {
	local pid=''

	install -d -m 0755 /run/dbus
	if [[ -r /run/dbus/pid ]]; then
		read -r pid </run/dbus/pid || true
	fi
	if [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null && [[ -S /run/dbus/system_bus_socket ]]; then
		log.info "Reuse running target D-Bus daemon with PID $pid"
		return 0
	fi
	if [[ -e /run/dbus/pid || -e /run/dbus/system_bus_socket ]]; then
		log.info "Remove stale target D-Bus runtime files"
		rm -f -- /run/dbus/pid /run/dbus/system_bus_socket
	fi
	dbus-daemon --system --fork
	[[ -S /run/dbus/system_bus_socket ]] || log.die "Target D-Bus system socket was not created."
}

setup.inner_installation() {
	cd "$repository_root"
	setup.prepare_inner_dbus
	apt-get update
	setup.run_checkpointed "$INNER_MODE" efi-suite-cleanup setup.cleanup_suite_efi
	setup.run_checkpointed "$INNER_MODE" target-packages setup.install_target_packages

	# The Btrfs/LUKS storage phase has already completed outside the chroot.
	# Security-sensitive phase coordinators execute as isolated entry points.
	setup.run_checkpointed "$INNER_MODE" secure-boot \
		"$repository_root/secure-boot/scripts/secure-boot-setup"
	setup.run_checkpointed "$INNER_MODE" snapshot-management \
		"$repository_root/btrfs-snapshots-mng/scripts/btrfs-snapshots-mng-setup"
	setup.run_checkpointed "$INNER_MODE" uki \
		"$repository_root/uki/scripts/install-uki"
}

setup.restore_chroot_files() {
	rm -f -- "$mp/usr/sbin/policy-rc.d" "$mp/etc/resolv.conf"
	if [[ -e $mp/etc/resolv.conf.chroot-save || -L $mp/etc/resolv.conf.chroot-save ]]; then
		mv "$mp/etc/resolv.conf.chroot-save" "$mp/etc/resolv.conf"
	fi
}

setup.remove_target_installer() {
	local target_repository="$mp/root/$repository_name"

	[[ $repository_name != . && $repository_name != .. && $repository_name != */* ]] ||
		log.die "Unsafe installer repository name: $repository_name"
	if [[ ! -e $target_repository && ! -L $target_repository ]]; then
		log.info "Target installer directory is already absent: $target_repository"
		return 0
	fi
	[[ -f $target_repository/$script_name ]] ||
		log.die "Refusing to remove unexpected target directory without $script_name: $target_repository"
	log.info "Remove installation scripts from target: $target_repository"
	rm -Rf -- "$target_repository"
	[[ ! -e $target_repository && ! -L $target_repository ]] ||
		log.die "Unable to remove target installer directory: $target_repository"
	log.success "Installation scripts removed from target"
}

setup.unmount_everything() {
	local lazy_fallback="${1:-false}"
	local target
	local index
	local failed=0
	local -a mounts=()

	[[ -e $mp ]] || return 0
	setup.restore_chroot_files
	while IFS= read -r target; do
		[[ -n $target ]] && mounts+=("$target")
	done < <(findmnt -Rrn -o TARGET "$mp" 2>/dev/null)

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
		log.warn "Leaving target mounts and LUKS mapper open for post-failure debugging"
	fi
	exit "$status"
}

setup.main() {
	common.require_root

	if [[ ${1:-} != "$INNER_MODE" ]]; then
		setup.parse_arguments "$@"
		setup.ensure_live_storage_tools
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
	if setup.checkpoint_reached outer storage; then
		log.info "Resume installation: skip completed phase storage"
		if mountpoint -q "$mp/boot/efi"; then
			umount "$mp/boot/efi"
		fi
	else
		"$repository_root/btrfs-root/scripts/btrfs-root-setup"
		setup.persist_checkpoint outer storage
	fi
	setup.prepare_chroot
	setup.run_inner_installation
	if [[ $install_rescue == yes && $suite_type != kali ]]; then
		setup.run_checkpointed outer rescue setup.install_rescue_system
	else
		log.info "Persistent rescue-system creation was not requested"
	fi
	setup.restore_chroot_files
	setup.remove_target_installer
	cleanup_required=false
	trap - EXIT
	log.info "Finished; target filesystems and the root mapper remain mounted"
}

setup.main "$@"
