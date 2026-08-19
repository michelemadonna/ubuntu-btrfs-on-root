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
# shellcheck source=new-install/scripts/new-install-setup
source "$repository_root/new-install/scripts/new-install-setup"

setup.write_config_value() {
	local file=$1 name=$2 value=$3
	printf 'export %s=%q\n' "$name" "$value" >>"$file"
}

setup.persist_runtime_devices() {
	local config_file=$1 temporary_file name value line
	local -a names=(root_dev efi_dev rescue_dev)

	temporary_file="$(mktemp "${config_file}.XXXXXX")"
	chmod 0600 "$temporary_file"
	cp -- "$config_file" "$temporary_file"
	for name in "${names[@]}"; do
		value=${!name}
		line="$(printf 'export %s=%q' "$name" "$value")"
		sed -i "s|^export ${name}=.*$|${line}|" "$temporary_file"
	done
	mv "$temporary_file" "$config_file"
}

setup.persist_config_value() {
	local config_file=$1 name=$2 value=$3 temporary_file

	temporary_file="$(mktemp "${config_file}.XXXXXX")"
	chmod 0600 "$temporary_file"
	cp -- "$config_file" "$temporary_file"
	sed -i "s|^export ${name}=.*$|$(printf 'export %s=%q' "$name" "$value")|" "$temporary_file"
	mv -- "$temporary_file" "$config_file"
}

setup.inner_phase_number() {
	case $1 in
	none) printf '0\n' ;;
	secure_boot) printf '1\n' ;;
	snapshots) printf '2\n' ;;
	uki) printf '3\n' ;;
	complete) printf '4\n' ;;
	*) log.die "Unknown inner installation phase: $1" ;;
	esac
}

setup.inner_phase_reached() {
	local current=none

	if [[ -r /var/lib/ubuntu-btrfs-on-root/install-phase ]]; then
		current="$(</var/lib/ubuntu-btrfs-on-root/install-phase)"
	fi
	(($(setup.inner_phase_number "$current") >= $(setup.inner_phase_number "$1")))
}

setup.persist_inner_phase() {
	local phase=$1 directory=/var/lib/ubuntu-btrfs-on-root temporary_file

	install -d -m 0755 "$directory"
	temporary_file="$(mktemp "$directory/.install-phase.XXXXXX")"
	printf '%s\n' "$phase" >"$temporary_file"
	chmod 0644 "$temporary_file"
	mv -- "$temporary_file" "$directory/install-phase"
	log.info "Checkpoint saved: inner installation phase '$phase'"
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
	local disk default_disk root_path efi_path boot_path='' rescue_path name type size detail confirmation config_mode config_name
	local detected_root_path detected_efi_path detected_boot_path boot_default reuse_boot_as_rescue=no install_rescue=yes
	local minimum_rescue_mib boot_size_mib layout layout_status available_mib required_mib
	local root_dev=sda3 efi_dev=sda2 boot_dev='' rescue_dev=sda1 iter_time=3000 swap_size=4G suite=resolute suite_type=ubuntu
	local PASSPHRASE=password TARGET_USERNAME=ubuntu TARGET_USER_PASSWORD=password mok_pin='' secure_boot_enrollment=sbctl secure_boot_mode EXPERIMENTAL_SBCTL_APPEND=false
	local pre_download=yes enable_tpm=yes snapshot_menu=yes enlarge=no snapshot_menu_pin=yes snapshot_menu_pin_value=123456
	local mp=/mnt/root keyslot_size=32m btrfs_options='defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1'
	local install_mode=migration install_disk='' disk_size_mib=0 esp_size_mib=1024 root_size_strategy=all root_size_percent=70 root_size_mib=0 install_hwe=no
	local install_windows=no windows_size_mib=65536 target_locale=en_US.UTF-8 target_timezone=Europe/Rome keyboard_layout=it keyboard_variant=''
	local target_hostname=linux install_disk_identity=''
	local -a disk_items=() partition_items=() efi_items=() boot_items=() rescue_items=()

	common.require_commands bash blockdev cp du find findmnt grep lsblk mktemp mv od readlink sed stat tr
	[[ -r $TUI_INPUT_DEVICE ]] || log.die "Interactive terminal is unavailable: $TUI_INPUT_DEVICE"
	log.section "Guided setup.conf creation"
	log.info "The wizard is using the built-in supported defaults."
	install_mode="$(tui.select_one "Select installation mode" "$install_mode" \
		'migration|In-place migration of an already installed system' \
		'new|New installation; erase a whole disk and bootstrap the system')" || log.die "Invalid installation mode."
	if [[ $install_mode == migration ]]; then
		log.warn "Migration is intended only for a freshly installed system created by the distribution installer."
		log.warn "It is not suitable for converting an existing production system."
	else
		log.warn "New installation permanently erases the selected whole disk after an exact-device confirmation."
	fi

	log.section "Storage configuration"
	if [[ $install_mode == new ]]; then
		while read -r name type size detail; do
			[[ $type == disk ]] || continue
			disk_items+=("$name|$name $size ${detail:-unknown model}")
		done < <(lsblk -dnpo NAME,TYPE,SIZE,MODEL)
		((${#disk_items[@]} > 0)) || log.die "No installation disks were discovered."
		disk="$(tui.select_one "Select the whole disk to erase for the new installation" /dev/sda "${disk_items[@]}")" ||
			log.die "Invalid disk selection."
		install_disk="$(readlink -f -- "$disk")"
		new-install.validate_target_disk "$install_disk"
		install_disk_identity="$(lsblk -dnro SIZE,MODEL,SERIAL,WWN "$install_disk" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
		disk_size_mib="$(setup.device_size_mib "$install_disk")"
		esp_size_mib="$(tui.input "EFI System Partition size in MiB" "$esp_size_mib")"
		[[ $esp_size_mib =~ ^[1-9][0-9]*$ ]] || log.die "ESP size must be a positive integer in MiB."
		install_rescue="$(tui.toggle "Reserve 10 GiB for the persistent rescue system" "$install_rescue")" ||
			log.die "Invalid rescue-system toggle."
		root_size_strategy="$(tui.select_one "Select encrypted root sizing" "$root_size_strategy" \
			'all|Use all remaining space' 'percent|Use a percentage of available space')" || log.die "Invalid root sizing strategy."
		if [[ $root_size_strategy == percent ]]; then
			while true; do
				root_size_percent="$(tui.input "Encrypted root percentage" "$root_size_percent")"
				[[ $root_size_percent =~ ^[1-9][0-9]*$ ]] || log.die "Root percentage must be an integer from 1 to 99."
				install_windows="$(tui.toggle "Reserve partitions for Windows and Windows RE" "$install_windows")" ||
					log.die "Invalid Windows toggle."
				if [[ $install_windows == yes ]]; then
					windows_size_mib="$(tui.input "Windows partition size in MiB" "$windows_size_mib")"
				fi
				set +e
				layout="$(new-install.calculate_layout "$disk_size_mib" "$esp_size_mib" "$install_rescue" "$root_size_strategy" "$root_size_percent" "$install_windows" "$windows_size_mib")"
				layout_status=$?
				set -e
				if ((layout_status == 0)); then
					break
				elif ((layout_status == 2)); then
					available_mib=$((disk_size_mib - NEW_INSTALL_GPT_RESERVE_MIB - esp_size_mib))
					[[ $install_rescue == no ]] || available_mib=$((available_mib - NEW_INSTALL_RESCUE_MIB))
					available_mib=$((available_mib - (available_mib * root_size_percent / 100)))
					required_mib=$((NEW_INSTALL_MSR_MIB + windows_size_mib + NEW_INSTALL_WINRE_MIB))
					log.warn "Windows layout requires $required_mib MiB but only $available_mib MiB remain; choose smaller root/Windows values."
					continue
				fi
				log.die "Invalid new-installation layout."
			done
		else
			install_windows=no
			layout="$(new-install.calculate_layout "$disk_size_mib" "$esp_size_mib" "$install_rescue" all "$root_size_percent" no 0)"
		fi
		root_size_mib="$(awk -F= '$1 == "root_mib" { print $2 }' <<<"$layout")"
		root_path=pending
		efi_path=pending
		rescue_path=$([[ $install_rescue == yes ]] && printf pending || true)
		mp=/mnt/root
	else
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
	fi

	log.section "Distribution configuration"
	suite_type="$(tui.select_one "Select the distribution type used for the rEFInd icon" "$suite_type" 'ubuntu|Ubuntu' 'kali|Kali Linux')" ||
		log.die "Invalid distribution type selection."
	if [[ $suite_type == kali ]]; then
		suite=kali
	else
		suite="$(tui.select_one "Select the Ubuntu suite/release" "$suite" 'resolute|Ubuntu Resolute' 'noble|Ubuntu Noble')" ||
			log.die "Invalid Ubuntu suite selection."
	fi
	[[ $suite =~ ^[a-z0-9][a-z0-9._-]*$ ]] || log.die "Suite must be a safe lowercase identifier."
	[[ $suite_type =~ ^[a-z0-9][a-z0-9._-]*$ ]] || log.die "Distribution icon identifier is invalid."
	if [[ $install_mode == new && $suite_type == ubuntu ]]; then
		install_hwe="$(tui.toggle "Install the Ubuntu HWE kernel" "$install_hwe")" || log.die "Invalid HWE kernel toggle."
	fi

	if [[ $install_mode == migration ]]; then
		if [[ $suite_type == kali ]]; then
			install_rescue=no
			log.info "Kali Linux does not support rescue-system creation during migration"
		else
			install_rescue="$(tui.toggle "Create the persistent rescue system" "$install_rescue")" ||
				log.die "Invalid rescue-system toggle."
		fi
	fi
	if [[ $install_mode == migration && $install_rescue == yes && -n $boot_path ]]; then
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

	if [[ $install_mode == new ]]; then
		:
	elif [[ $install_rescue == no ]]; then
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
	PASSPHRASE="$(tui.password_confirm "Initial LUKS passphrase" "$PASSPHRASE")" || log.die "LUKS passphrases do not match."
	if [[ $secure_boot_enrollment == mok ]]; then
		mok_pin="$(tui.password "MOK enrollment PIN" 123456)"
		[[ -n $mok_pin ]] || log.die "MOK PIN cannot be empty."
	fi
	[[ $iter_time =~ ^[1-9][0-9]*$ ]] || log.die "Argon2id time target must be a positive integer."
	[[ -n $PASSPHRASE ]] || log.die "LUKS passphrase cannot be empty."
	if [[ $install_mode == new ]]; then
		log.section "Target identity and localization"
		TARGET_USERNAME="$(tui.input "Initial user name" "$TARGET_USERNAME")"
		TARGET_USER_PASSWORD="$(tui.password_confirm "Initial user password" "$TARGET_USER_PASSWORD")" || log.die "Initial user passwords do not match."
		target_hostname="$(tui.input "Target hostname" "$target_hostname")"
		target_locale="$(tui.input "System locale" "$target_locale")"
		target_timezone="$(tui.input "Timezone" "$target_timezone")"
		keyboard_layout="$(tui.input "Keyboard layout" "$keyboard_layout")"
		keyboard_variant="$(tui.input "Keyboard variant (empty for default)" "$keyboard_variant")"
		[[ $TARGET_USERNAME =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || log.die "Initial user name is invalid."
		[[ $target_hostname =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || log.die "Target hostname is invalid."
		[[ $target_locale =~ ^[A-Za-z][A-Za-z0-9_@.-]*$ ]] || log.die "Target locale is invalid."
		[[ $target_timezone != /* && $target_timezone != *..* && -f /usr/share/zoneinfo/$target_timezone ]] || log.die "Timezone is not available in the live environment: $target_timezone"
		[[ $keyboard_layout =~ ^[a-z0-9_-]+$ ]] || log.die "Keyboard layout is invalid."
		[[ -z $keyboard_variant || $keyboard_variant =~ ^[a-z0-9_-]+$ ]] || log.die "Keyboard variant is invalid."
		[[ -n $TARGET_USER_PASSWORD ]] || log.die "Initial user password cannot be empty."
	fi

	log.section "Optional features"
	pre_download="$(tui.toggle "Pre-download target packages" "$pre_download")" || log.die "Invalid pre-download toggle."
	enable_tpm="$(tui.toggle "Install TPM integration" "$enable_tpm")" || log.die "Invalid TPM toggle."
	snapshot_menu="$(tui.toggle "Install the early-boot snapshot selector" "$snapshot_menu")" || log.die "Invalid snapshot-menu toggle."
	if [[ $install_mode == migration ]]; then
		enlarge="$(tui.toggle "Extend the root partition to available space" "$enlarge")" || log.die "Invalid enlargement toggle."
	else
		enlarge=no
	fi

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
	setup.write_config_value "$temporary_config" install_mode "$install_mode"
	setup.write_config_value "$temporary_config" install_disk "$install_disk"
	setup.write_config_value "$temporary_config" install_disk_identity "$install_disk_identity"
	setup.write_config_value "$temporary_config" disk_size_mib "$disk_size_mib"
	setup.write_config_value "$temporary_config" esp_size_mib "$esp_size_mib"
	setup.write_config_value "$temporary_config" root_size_strategy "$root_size_strategy"
	setup.write_config_value "$temporary_config" root_size_percent "$root_size_percent"
	setup.write_config_value "$temporary_config" root_size_mib "$root_size_mib"
	setup.write_config_value "$temporary_config" install_windows "$install_windows"
	setup.write_config_value "$temporary_config" windows_size_mib "$windows_size_mib"
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
	setup.write_config_value "$temporary_config" install_hwe "$install_hwe"
	setup.write_config_value "$temporary_config" secure_boot_mode "$secure_boot_mode"
	setup.write_config_value "$temporary_config" secure_boot_enrollment "$secure_boot_enrollment"
	setup.write_config_value "$temporary_config" EXPERIMENTAL_SBCTL_APPEND "$EXPERIMENTAL_SBCTL_APPEND"
	setup.write_config_value "$temporary_config" PASSPHRASE "$PASSPHRASE"
	setup.write_config_value "$temporary_config" TARGET_USERNAME "$TARGET_USERNAME"
	setup.write_config_value "$temporary_config" TARGET_USER_PASSWORD "$TARGET_USER_PASSWORD"
	setup.write_config_value "$temporary_config" target_hostname "$target_hostname"
	setup.write_config_value "$temporary_config" target_locale "$target_locale"
	setup.write_config_value "$temporary_config" target_timezone "$target_timezone"
	setup.write_config_value "$temporary_config" keyboard_layout "$keyboard_layout"
	setup.write_config_value "$temporary_config" keyboard_variant "$keyboard_variant"
	setup.write_config_value "$temporary_config" pre_download "$pre_download"
	setup.write_config_value "$temporary_config" root_sub_vol "@$suite"
	setup.write_config_value "$temporary_config" enable_tpm "$enable_tpm"
	setup.write_config_value "$temporary_config" snapshot_menu "$snapshot_menu"
	setup.write_config_value "$temporary_config" snapshot_menu_pin "$snapshot_menu_pin"
	setup.write_config_value "$temporary_config" snapshot_menu_pin_value "$snapshot_menu_pin_value"
	setup.write_config_value "$temporary_config" mok_pin "$mok_pin"
	setup.write_config_value "$temporary_config" NEW_INSTALL_PHASE "none"
	mv "$temporary_config" "$config_file"
	log.success "Generated protected configuration: $config_file"
	log.section_end

	log.section "setup.conf summary"
	log.summary_item "Disk" "$disk"
	log.summary_item "Install mode" "$install_mode"
	if [[ $install_mode == new ]]; then
		log.summary_item "Disk erase target" "$install_disk ($disk_size_mib MiB)"
		log.summary_item "ESP size" "$esp_size_mib MiB"
		if [[ $root_size_strategy == all ]]; then
			log.summary_item "Root sizing" "all remaining space"
		else
			log.summary_item "Root sizing" "$root_size_percent% of available space"
		fi
		log.summary_item "Calculated root" "$root_size_mib MiB"
		if [[ $install_windows == yes ]]; then
			log.summary_item "Windows layout" "$windows_size_mib MiB + MSR + Windows RE"
		else
			log.summary_item "Windows layout" "disabled"
		fi
		log.summary_item "Localization" "$target_locale; $target_timezone; $keyboard_layout${keyboard_variant:+/$keyboard_variant}"
		log.summary_item "Hostname" "$target_hostname"
		log.summary_item "Initial sudo user" "$TARGET_USERNAME"
		log.summary_item "Ubuntu HWE kernel" "$install_hwe"
	fi
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
		PASSPHRASE TARGET_USERNAME TARGET_USER_PASSWORD NEW_INSTALL_PHASE install_hwe install_mode install_disk install_disk_identity disk_size_mib esp_size_mib root_size_strategy root_size_percent root_size_mib install_windows windows_size_mib target_hostname target_locale target_timezone keyboard_layout keyboard_variant \
		pre_download root_sub_vol enable_tpm snapshot_menu snapshot_menu_pin snapshot_menu_pin_value mok_pin; do
		grep -q "^export ${config_name}=" "$config_file" ||
			log.die "Generated configuration is missing required value: $config_name"
	done
	log.success "Configuration syntax, permissions, and required values are valid."
	log.section_end
	if [[ $install_mode == new ]]; then
		new-install.print_planned_layout
	fi

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
	install_mode=${install_mode:-migration}
	[[ $install_mode == migration || $install_mode == new ]] || log.die "install_mode must be migration or new."
	NEW_INSTALL_PHASE=${NEW_INSTALL_PHASE:-none}
	[[ $NEW_INSTALL_PHASE == none || $NEW_INSTALL_PHASE == partitions || $NEW_INSTALL_PHASE == filesystems || $NEW_INSTALL_PHASE == encrypted || $NEW_INSTALL_PHASE == subvolumes || $NEW_INSTALL_PHASE == bootstrapped || $NEW_INSTALL_PHASE == configured || $NEW_INSTALL_PHASE == complete ]] ||
		log.die "NEW_INSTALL_PHASE is invalid: $NEW_INSTALL_PHASE"
	install_hwe=${install_hwe:-no}
	[[ $install_hwe == yes || $install_hwe == no ]] || log.die "install_hwe must be yes or no."
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
	if [[ $install_mode == migration && $suite_type == kali ]]; then
		install_rescue=no
	fi
	EXPERIMENTAL_SBCTL_APPEND=${EXPERIMENTAL_SBCTL_APPEND:-false}
	[[ $EXPERIMENTAL_SBCTL_APPEND == true || $EXPERIMENTAL_SBCTL_APPEND == false ]] ||
		log.die "EXPERIMENTAL_SBCTL_APPEND must be true or false."
	if [[ $secure_boot_enrollment == mok ]]; then
		common.require_nonempty "mok_pin" "${mok_pin:-}"
	fi
	boot_dev=${boot_dev:-}
	if [[ $install_mode == migration ]]; then
		[[ -z $boot_dev || ($boot_dev != */* && $boot_dev != *..*) ]] ||
			log.die "boot_dev must be empty or a device name relative to /dev."
		[[ -z $boot_dev || ($boot_dev != "$root_dev" && $boot_dev != "$efi_dev") ]] ||
			log.die "boot_dev must be distinct from root_dev and efi_dev."
	fi
	rescue_dev=${rescue_dev:-}
	if [[ ($install_rescue == yes && ($suite_type != kali || $install_mode == new)) || $setup_action == install-rescue-live ]]; then
		common.require_nonempty "rescue_dev" "$rescue_dev"
		if [[ $install_mode == migration || $setup_action == install-rescue-live ]]; then
			[[ $rescue_dev != */* && $rescue_dev != *..* ]] ||
				log.die "rescue_dev must be a device name relative to /dev."
			[[ $rescue_dev != "$root_dev" && $rescue_dev != "$efi_dev" ]] ||
				log.die "rescue_dev must be distinct from root_dev and efi_dev."
		fi
	fi
	if [[ $install_mode == new ]]; then
		common.require_nonempty "install_disk" "${install_disk:-}"
		common.require_nonempty "install_disk_identity" "${install_disk_identity:-}"
		common.require_nonempty "disk_size_mib" "${disk_size_mib:-}"
		common.require_nonempty "esp_size_mib" "${esp_size_mib:-}"
		common.require_nonempty "root_size_strategy" "${root_size_strategy:-}"
		common.require_nonempty "root_size_mib" "${root_size_mib:-}"
		common.require_nonempty "install_windows" "${install_windows:-}"
		common.require_nonempty "target_hostname" "${target_hostname:-}"
		common.require_nonempty "target_locale" "${target_locale:-}"
		common.require_nonempty "target_timezone" "${target_timezone:-}"
		common.require_nonempty "keyboard_layout" "${keyboard_layout:-}"
		common.require_nonempty "TARGET_USERNAME" "${TARGET_USERNAME:-}"
		common.require_nonempty "TARGET_USER_PASSWORD" "${TARGET_USER_PASSWORD:-}"
		[[ $install_disk == /dev/* && $install_disk != *..* ]] || log.die "install_disk must be an absolute /dev path."
		[[ $root_size_strategy == all || $root_size_strategy == percent ]] || log.die "root_size_strategy must be all or percent."
		[[ $install_windows == yes || $install_windows == no ]] || log.die "install_windows must be yes or no."
		[[ $root_size_strategy != all || $install_windows == no ]] || log.die "Windows cannot be configured when root uses all remaining space."
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
	if [[ $install_mode == new ]]; then
		log.info "New installation target will be prepared by the dedicated provisioning subsystem"
		return
	fi
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
		SKIP_CONFIRMATION=yes \
		"$repository_root/rescue/script/install-rescue-live"
	log.section_end
}

setup.install_new_live_dependencies() {
	local -a packages=(btrfs-progs cryptsetup-bin curl debootstrap dosfstools gdisk gnupg ntfs-3g zstd)

	log.section "New-installation live dependencies"
	apt-get update
	if [[ $suite_type == kali ]]; then
		:
	else
		packages+=(ubuntu-keyring)
	fi
	apt-get install -y "${packages[@]}"
	if [[ $suite_type == kali ]]; then
		new-install.prepare_kali_bootstrap
	fi
	log.success "New-installation tools and archive keyring are available"
	log.section_end
}

setup.prepare_chroot() {
	local chroot_nameservers

	log.info "Prepare $mp for chroot"
	mount --rbind /dev "$mp/dev"
	mount --make-rslave "$mp/dev"
	mount -t proc proc "$mp/proc"
	mount -t devpts pts "$mp/dev/pts"
	mount --rbind /sys "$mp/sys"
	mount --make-rslave "$mp/sys"
	mount -t tmpfs tmpfs "$mp/run"
	mountpoint -q "$mp/home" || mount -o "subvol=$root_sub_vol/@home" /dev/mapper/root "$mp/home"
	mountpoint -q "$mp/boot/efi" || mount "/dev/$efi_dev" "$mp/boot/efi"
	mkdir -p "$mp/sys/firmware/efi/efivars"
	mount --bind /sys/firmware/efi/efivars "$mp/sys/firmware/efi/efivars"
	mkdir -p "$mp/run/dbus"

	if [[ -e $mp/etc/resolv.conf || -L $mp/etc/resolv.conf ]]; then
		mv "$mp/etc/resolv.conf" "$mp/etc/resolv.conf.chroot-save"
	fi

	if [[ $install_mode == new ]]; then
		chroot_nameservers="$(awk '$1 == "nameserver" && $2 !~ /^127\./ && $2 !~ /^::1$/ { print "nameserver " $2 }' /etc/resolv.conf 2>/dev/null | head -n 3)"
	fi
	if [[ -z ${chroot_nameservers:-} ]]; then
		chroot_nameservers=$'nameserver 1.1.1.1\nnameserver 8.8.8.8'
	fi
	if [[ $install_mode == new ]]; then
		chroot_nameservers+=$'\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\noptions timeout:2 attempts:3 single-request-reopen'
	fi
	printf '%s\n' "$chroot_nameservers" >"$mp/etc/resolv.conf"

	cat >"$mp/usr/sbin/policy-rc.d" <<-'EOF'
		#!/bin/sh
		exit 101
	EOF
	chmod 0755 "$mp/usr/sbin/policy-rc.d"
	if [[ $install_mode == new ]]; then
		setup.ensure_target_journal
		setup.configure_target_networkd
	fi
	setup.start_chroot_dbus
}

setup.ensure_target_journal() {
	local journal_directory="$mp/var/log/journal"

	install -d -m 0755 "$journal_directory"
	install -d -m 0755 "$mp/etc/systemd/journald.conf.d"
	cat >"$mp/etc/systemd/journald.conf.d/20-installer-persistent.conf" <<-'EOF'
		[Journal]
		Storage=persistent
	EOF
	if chroot "$mp" getent group systemd-journal >/dev/null 2>&1; then
		chroot "$mp" chown root:systemd-journal /var/log/journal
		chmod 2755 "$journal_directory"
	fi
}

setup.configure_target_networkd() {
	install -d -m 0755 "$mp/etc/systemd/network"
	install -d -m 0755 "$mp/etc/netplan"
	cat >"$mp/etc/netplan/01_netcfg.yaml" <<-'EOF'
		network:
		  version: 2
		  renderer: NetworkManager
		  ethernets:
		    alleths:
		      optional: true
		      match:
		        name: e*
		      dhcp4: true
		      dhcp6: true

		# Optional bridge example, intentionally disabled:
		# bridges:
		#   br0:
		#     interfaces: [alleths]
		#     dhcp4: true
		#     dhcp6: true
	EOF
	install -d -m 0755 "$mp/etc/NetworkManager/conf.d"
	cat >"$mp/etc/NetworkManager/conf.d/10-globally-managed-devices.conf" <<-'EOF'
		[keyfile]
		unmanaged-devices=*,except:type:wifi,except:type:wwan,except:type:ethernet
	EOF
	cat >"$mp/etc/NetworkManager/conf.d/20-systemd-resolved.conf" <<-'EOF'
		[main]
		dns=systemd-resolved
	EOF
	systemctl --root="$mp" unmask systemd-networkd.service >/dev/null 2>&1 || true
	systemctl --root="$mp" disable systemd-networkd.service >/dev/null 2>&1 || true
}

setup.configure_snap_store_install() {
	if [[ $install_mode == new && $suite_type == ubuntu ]]; then
		cat >/etc/systemd/system/ubuntu-btrfs-install-snap-store.service <<-'EOF'
			[Unit]
			Description=Install Ubuntu Snap Store
			After=network-online.target snapd.service
			Wants=network-online.target snapd.service
			ConditionPathExists=!/var/lib/ubuntu-btrfs-on-root/snap-store-installed

			[Service]
			Type=oneshot
			ExecStart=/bin/sh -c '/usr/bin/snap install snap-store --stable && install -D -m 0644 /dev/null /var/lib/ubuntu-btrfs-on-root/snap-store-installed'
			RemainAfterExit=yes

			[Install]
			WantedBy=multi-user.target
		EOF
		install -d -m 0755 /var/lib/ubuntu-btrfs-on-root
		systemctl enable ubuntu-btrfs-install-snap-store.service
	fi
}

setup.start_chroot_dbus() {
	local socket="$mp/run/dbus/system_bus_socket"

	command -v chroot >/dev/null 2>&1 || log.die "chroot is unavailable."
	[[ -x $mp/usr/bin/dbus-daemon ]] || log.die "The target does not contain dbus-daemon."
	if [[ ! -s $mp/etc/machine-id ]]; then
		chroot "$mp" dbus-uuidgen --ensure=/etc/machine-id
	fi
	if [[ ! -S $socket ]]; then
		rm -f -- "$socket"
		chroot "$mp" dbus-daemon --system --fork --nopidfile
	fi
	[[ -S $socket ]] || log.die "The target D-Bus system socket was not created."
	if [[ $install_mode != new ]]; then
		log.success "D-Bus system bus is running inside the target chroot"
		return 0
	fi
	for _ in {1..20}; do
		if chroot "$mp" dbus-send --system --print-reply --dest=org.freedesktop.DBus \
			/org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
			log.success "D-Bus system bus is running inside the target chroot"
			return 0
		fi
		sleep 0.25
	done
	log.die "The target D-Bus system bus did not become ready."
}

setup.run_inner_installation() {
	local inner_repository="/root/$repository_name"

	cp -Rf "$repository_root" "$mp/root/"
	chmod a+x "$mp$inner_repository/$script_name"
	log.info "Run installation phases in the target chroot"
	unshare --mount --fork chroot "$mp" "$inner_repository/$script_name" "$INNER_MODE"
}

setup.preseed_kdump() {
	common.require_commands debconf-set-selections
	printf '%s\n' 'kdump-tools kdump-tools/use_kdump boolean true' | debconf-set-selections
	log.info "Preseed kdump-tools to enable kdump without an interactive prompt"
}

setup.preseed_gdm() {
	if [[ $install_mode == new && $suite_type == ubuntu ]]; then
		common.require_commands debconf-set-selections
		printf '%s\n' \
			'shared/default-x-display-manager shared/default-x-display-manager select gdm3' \
			'gdm3 shared/default-x-display-manager select gdm3' |
			debconf-set-selections
		log.info "Preseed GDM as the Ubuntu display manager"
	fi
}

setup.prepare_apt_environment() {
	local man_db_dir=/usr/lib/man-db

	if [[ $install_mode == new ]]; then
		setup.normalize_new_target_permissions
	fi
	install -d -m 0755 /var/lib/apt/lists /var/cache/apt/archives
	install -d -m 0700 /var/lib/apt/lists/partial /var/cache/apt/archives/partial
	if id _apt >/dev/null 2>&1; then
		chown _apt:root /var/lib/apt/lists/partial /var/cache/apt/archives/partial
	fi
	if [[ -d $man_db_dir ]]; then
		chmod 0755 "$man_db_dir"
		while IFS= read -r library; do
			chmod 0755 "$library"
		done < <(find "$man_db_dir" -maxdepth 1 -type f -name 'libmandb-*.so' -print)
		if [[ -f /usr/lib/man-db/mandb ]]; then
			chmod 0755 /usr/lib/man-db/mandb
		fi
	fi
	command -v ldconfig >/dev/null 2>&1 || log.die "ldconfig is unavailable in the target."
	command -v dbus-uuidgen >/dev/null 2>&1 || log.die "dbus-uuidgen is unavailable in the target."
	ldconfig
	if [[ ! -s /etc/machine-id ]]; then
		rm -f -- /etc/machine-id
		dbus-uuidgen --ensure=/etc/machine-id
	fi
	[[ -s /etc/machine-id ]] || log.die "Target machine-id could not be generated."
	install -d -m 0755 /run/dbus
	if [[ ! -S /run/dbus/system_bus_socket ]]; then
		rm -f -- /run/dbus/system_bus_socket
		dbus-daemon --system --fork --nopidfile
	fi
}

setup.normalize_new_target_permissions() {
	local path

	if findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | grep -Fxq noexec; then
		log.die "The new target root is mounted noexec; executable libraries cannot run."
	fi
	for path in / /usr /usr/lib /usr/lib/x86_64-linux-gnu /run /run/dbus /var/log; do
		[[ -d $path ]] && chmod 0755 "$path"
	done
	if [[ -d /usr/lib/man-db ]]; then
		find /usr/lib/man-db -maxdepth 1 -type f -name 'libmandb-*.so' -exec chmod 0755 {} +
	fi
	find /usr/lib -maxdepth 3 -type f -name 'libdconf.so*' -exec chmod 0644 {} +
	ldconfig
}

setup.finalize_package_triggers() {
	log.info "Finalize package triggers and rebuild man-db cache"
	dpkg --configure -a
	ldconfig
	if command -v mandb >/dev/null 2>&1; then
		mandb --quiet
	fi
}

setup.configure_persistent_journal() {
	local journal_directory=/var/log/journal

	getent group systemd-journal >/dev/null 2>&1 || log.die "systemd-journal group is unavailable."
	install -d -m 2755 -o root -g systemd-journal "$journal_directory"
	install -d -m 0755 /etc/systemd/journald.conf.d
	cat >/etc/systemd/journald.conf.d/20-installer-persistent.conf <<-'EOF'
		[Journal]
		Storage=persistent
	EOF
	log.success "Persistent system journal configured at $journal_directory"
}

setup.configure_graphical_login() {
	if [[ $install_mode == new && $suite_type == ubuntu ]]; then
		rm -f -- /etc/systemd/system/gdm3.service /etc/systemd/system/gdm.service
		systemctl unmask gdm3.service gdm.service >/dev/null 2>&1 || true
		if dpkg-query -W -f='${Status}' gdm3 2>/dev/null | grep -Fq 'install ok installed'; then
			dpkg-reconfigure -f noninteractive gdm3
		fi
		if [[ -f /lib/systemd/system/gdm3.service ]]; then
			systemctl enable /lib/systemd/system/gdm3.service
			install -d -m 0755 /etc/systemd/system
			rm -f -- /etc/systemd/system/display-manager.service
			ln -s /lib/systemd/system/gdm3.service /etc/systemd/system/display-manager.service
			install -d -m 0755 /etc/systemd/system/graphical.target.wants
			ln -sfn /lib/systemd/system/gdm3.service /etc/systemd/system/graphical.target.wants/gdm3.service
		else
			log.die "gdm3.service is not installed in the target."
		fi
		log.success "Enabled GDM graphical login"
	fi
}

setup.configure_debug_console() {
	local getty_unit=getty@tty1.service

	[[ -d /etc/systemd/system ]] || log.die "Target systemd unit directory is unavailable."
	log.info "Enable virtual debug console on tty1"
	rm -f -- "/etc/systemd/system/$getty_unit"
	rm -f -- /etc/systemd/system/getty@.service
	systemctl unmask "$getty_unit" >/dev/null 2>&1 || true
	systemctl unmask getty@.service >/dev/null 2>&1 || true
	systemctl enable "$getty_unit" >/dev/null 2>&1 ||
		log.die "Unable to enable $getty_unit in the target."
	[[ -L /etc/systemd/system/getty.target.wants/$getty_unit ]] ||
		log.die "$getty_unit is not enabled in the target."
	log.success "Virtual debug console tty1 enabled"
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
		packages+=(libtss2-esys-3.0.2-0t64 libtss2-mu-4.0.1-0t64 libtss2-rc0t64)
		apt-cache show refind >/dev/null 2>&1 && packages+=(refind)
	fi

	apt-get -o APT::Sandbox::User=root install --no-install-recommends -y --download-only \
		btrfs-assistant btrfsmaintenance
	apt-get -o APT::Sandbox::User=root install --download-only -y "${packages[@]}"
	apt-get -o APT::Sandbox::User=root install -y openssh-server open-vm-tools-desktop
}

setup.inner_installation() {
	cd "$repository_root"
	export DEBIAN_FRONTEND=noninteractive
	if [[ $install_mode == new ]]; then
		export LD_LIBRARY_PATH="/usr/lib/man-db${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	fi
	rm -rf -- "/boot/efi/EFI/$suite"
	setup.prepare_apt_environment
	setup.preseed_kdump
	setup.preseed_gdm
	apt-get -o APT::Sandbox::User=root update
	if [[ $install_mode == new ]]; then
		new-install.install_ubuntu_manual_packages
	fi

	if [[ $pre_download == yes ]]; then
		setup.pre_download_all
	fi

	log.info "Install target initramfs integration for the configured LUKS root"
	apt-get -o APT::Sandbox::User=root install -y btrfs-progs cryptsetup-initramfs zstd
	if [[ $install_mode == new && $suite_type == ubuntu ]]; then
		systemctl unmask NetworkManager.service >/dev/null 2>&1 || true
		systemctl enable NetworkManager.service >/dev/null 2>&1 ||
			log.die "Unable to enable NetworkManager after package installation."
		systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
		systemctl enable systemd-resolved.service >/dev/null 2>&1 ||
			log.die "Unable to enable systemd-resolved after package installation."
		setup.configure_snap_store_install
	fi
	if [[ $install_mode == new ]]; then
		env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales
		env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure tzdata
		env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure keyboard-configuration
	fi
	setup.finalize_package_triggers

	# The Btrfs/LUKS storage phase has already completed outside the chroot.
	# Security-sensitive phase coordinators execute as isolated entry points.
	if ! setup.inner_phase_reached secure_boot; then
		"$repository_root/secure-boot/scripts/secure-boot-setup"
		setup.persist_inner_phase secure_boot
	fi
	if ! setup.inner_phase_reached snapshots; then
		"$repository_root/btrfs-snapshots-mng/scripts/btrfs-snapshots-mng-setup"
		setup.persist_inner_phase snapshots
	fi
	if ! setup.inner_phase_reached uki; then
		"$repository_root/uki/scripts/install-uki"
		setup.persist_inner_phase uki
	fi
	if [[ $install_mode == new ]]; then
		setup.configure_persistent_journal
		setup.configure_debug_console
	fi
	setup.configure_graphical_login
	rm -f -- /run/dbus/system_bus_socket
	setup.persist_inner_phase complete
}

setup.restore_chroot_files() {
	rm -f -- "$mp/usr/sbin/policy-rc.d" "$mp/etc/resolv.conf"
	if [[ -e $mp/etc/resolv.conf.chroot-save || -L $mp/etc/resolv.conf.chroot-save ]]; then
		mv "$mp/etc/resolv.conf.chroot-save" "$mp/etc/resolv.conf"
	fi
	if [[ $install_mode == new && $suite_type == ubuntu ]]; then
		rm -f -- "$mp/etc/resolv.conf"
		ln -s /run/systemd/resolve/stub-resolv.conf "$mp/etc/resolv.conf"
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

setup.print_final_summary() {
	log.section "Installation summary"
	log.summary_item "Status" "completed successfully"
	log.summary_item "Mode" "$install_mode"
	log.summary_item "Distribution" "$suite_type/$suite"
	log.summary_item "Encrypted root" "/dev/$root_dev -> /dev/mapper/root"
	log.summary_item "ESP" "/dev/$efi_dev"
	log.summary_item "Rescue" "$([[ $install_rescue == yes ]] && printf '/dev/%s' "$rescue_dev" || printf disabled)"
	if [[ $install_mode == new ]]; then
		log.summary_item "Install disk" "$install_disk"
		log.summary_item "Windows layout" "$install_windows"
		log.summary_item "Localization" "$target_locale; $target_timezone; $keyboard_layout${keyboard_variant:+/$keyboard_variant}"
	fi
	log.summary_item "Target mount" "$mp (left mounted for inspection)"
	log.success "Installation and common post-installation phases completed"
	log.section_end
}

setup.validate_final_state() {
	log.section "Post-summary validation"
	cryptsetup isLuks "/dev/$root_dev" || log.die "Configured root is not a LUKS container."
	[[ -b /dev/mapper/root ]] || log.die "Root mapper is unavailable after installation."
	mountpoint -q "$mp" || log.die "Target root is not mounted after installation."
	mountpoint -q "$mp/boot/efi" || log.die "ESP is not mounted in the target."
	[[ -s $mp/etc/os-release ]] || log.die "Target operating-system identity is missing."
	[[ -s $mp/etc/fstab && -s $mp/etc/crypttab ]] || log.die "Target storage configuration is incomplete."
	if [[ $install_mode == new ]]; then
		[[ -d $mp/var/log/journal ]] || log.die "Persistent journal directory is missing from the target."
	fi
	log.success "Validated mounted target, LUKS access and persistent target configuration"
	log.section_end
}

setup.main() {
	common.require_root

	if [[ ${1:-} != "$INNER_MODE" ]]; then
		setup.parse_arguments "$@"
	fi
	setup.load_configuration "${1:-}"
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

	cleanup_required=true
	trap setup.cleanup_on_exit EXIT

	cd "$repository_root"
	if [[ $install_mode == new ]]; then
		setup.install_new_live_dependencies
		new-install.run
	else
		setup.prepare_target
		"$repository_root/btrfs-root/scripts/btrfs-root-setup"
	fi
	setup.prepare_chroot
	setup.run_inner_installation
	if [[ $install_rescue == yes && ($suite_type != kali || $install_mode == new) ]]; then
		setup.install_rescue_system
	else
		log.info "Persistent rescue-system creation was not requested"
	fi
	setup.restore_chroot_files
	cleanup_required=false
	trap - EXIT
	setup.print_final_summary
	setup.validate_final_state
	log.info "Finished; target filesystems and the root mapper remain mounted"
}

setup.main "$@"
