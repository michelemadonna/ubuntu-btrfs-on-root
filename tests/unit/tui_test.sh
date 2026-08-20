#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$repository_root/lib/tui.sh"

tui-test.assert_equal() {
	local expected=$1 actual=$2
	[[ $actual == "$expected" ]] || {
		printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
		return 1
	}
}

tui-test.with_input() {
	local content=$1
	shift
	local input_file
	input_file="$(mktemp "${TMPDIR:-/tmp}/tui-test.XXXXXX")"
	printf '%s' "$content" >"$input_file"
	TUI_INPUT_DEVICE=$input_file "$@"
	rm -f -- "$input_file"
}

tui-test.input_and_password_defaults() {
	local output prompt
	output="$(tui-test.with_input $'\n' tui.input "Value" "default" 2>/dev/null)"
	tui-test.assert_equal default "$output"
	prompt="$(tui-test.with_input $'secret\n' tui.password "Password" "fallback" 2>&1 >/dev/null)"
	[[ $prompt == *'Password [default: ********]: ******'* ]] || {
		printf 'Password prompt must mask the default and entered value.\n' >&2
		return 1
	}
	output="$(tui-test.with_input $'secret\n' tui.password "Password" "fallback" 2>/dev/null)"
	tui-test.assert_equal secret "$output"
}

tui-test.selections() {
	local output
	output="$(tui-test.with_input $'2\n' tui.select_one "Device" /dev/sda '/dev/sda|Disk A' '/dev/nvme0n1|Disk B' 2>/dev/null)"
	tui-test.assert_equal /dev/nvme0n1 "$output"
	output="$(tui-test.with_input $'1,3\n' tui.select_many "Features" 'a|A|yes' 'b|B|no' 'c|C|yes' 2>/dev/null)"
	tui-test.assert_equal $'a\nc' "$output"
}

tui-test.toggles() {
	local output
	output="$(tui-test.with_input $'\n' tui.toggle "Feature" yes 2>/dev/null)"
	tui-test.assert_equal yes "$output"
	output="$(tui-test.with_input $'n\n' tui.toggle "Feature" yes 2>/dev/null)"
	tui-test.assert_equal no "$output"
	output="$(tui-test.with_input $'YES\n' tui.toggle "Feature" no 2>/dev/null)"
	tui-test.assert_equal yes "$output"
}

tui-test.generated_config_contract() {
	local prepare_target_body

	rg -q 'setup\.generate_configuration' "$repository_root/setup.sh"
	if rg -q 'source .*setup\.conf\.example' "$repository_root/setup.sh"; then
		printf 'setup.sh must not depend on setup.conf.example\n' >&2
		return 1
	fi
	rg -q "local root_dev=sda3 efi_dev=sda2 boot_dev='' rescue_dev=sda1 iter_time=3000 swap_size=4G suite=resolute suite_type=ubuntu" "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target/boot/efi' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target/boot' "$repository_root/setup.sh"
	rg -q 'if \[\[ \$install_mode == in_place \]\]; then' "$repository_root/setup.sh"
	rg -q 'source_boot_dev=\${boot_path#/dev/}' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" boot_dev "\$boot_dev"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" secure_boot_mode "\$secure_boot_mode"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" secure_boot_enrollment "\$secure_boot_enrollment"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" install_rescue "\$install_rescue"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" EXPERIMENTAL_SBCTL_APPEND "\$EXPERIMENTAL_SBCTL_APPEND"' "$repository_root/setup.sh"
	rg -q 'Select the Secure Boot enrollment method' "$repository_root/setup.sh"
	rg -q 'Use .* as the rescue partition after copying /boot into Btrfs' "$repository_root/setup.sh"
	prepare_target_body="$(awk '/^setup\.prepare_target\(\)/,/^}/' "$repository_root/setup.sh")"
	[[ $prepare_target_body == *'mountpoint -q /target/cdrom'* ]] || return 1
	[[ $prepare_target_body == *'umount /target/cdrom'* ]] || return 1
	if grep -Fq "umount \"\$mp\"" <<<"$prepare_target_body"; then
		return 1
	fi
	if awk '/^setup\.main\(\)/,/^}/' "$repository_root/setup.sh" | rg -q '^\s*setup\.unmount_everything$'; then
		return 1
	fi
	rg -q 'setup\.write_config_value "\$temporary_config" mp "\$mp"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" keyslot_size "\$keyslot_size"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" btrfs_options "\$btrfs_options"' "$repository_root/setup.sh"
	rg -q "suite_type=\"\$\(tui\.select_one.*'ubuntu|Ubuntu' 'kali|Kali Linux'" "$repository_root/setup.sh"
	rg -q "'resolute|Ubuntu Resolute' 'noble|Ubuntu Noble'" "$repository_root/setup.sh"
	rg -q 'suite=kali' "$repository_root/setup.sh"
	rg -q 'not suitable for converting an existing production system' "$repository_root/setup.sh"
	rg -q "'ubuntu|Ubuntu' 'kali|Kali Linux'" "$repository_root/setup.sh"
	rg -q 'suite_type == kali' "$repository_root/setup.sh"
	rg -q 'log\.section "Storage configuration"' "$repository_root/setup.sh"
	rg -q 'Select the installation mode' "$repository_root/setup.sh"
	rg -q 'setup\.show_target_inventory' "$repository_root/setup.sh"
	rg -q 'Target disk inventory' "$repository_root/setup.sh"
	rg -q 'Btrfs top-level content' "$repository_root/setup.sh"
	rg -q "'in_place|In Place Migration'" "$repository_root/setup.sh"
	rg -q "'new_setup|New Setup or Migrate From another Disk'" "$repository_root/setup.sh"
	rg -q 'setup\.stage_existing_sbctl_keys' "$repository_root/setup.sh"
	rg -q 'ROOT LUKS password for key discovery' "$repository_root/setup.sh"
	rg -q 'cryptsetup open --key-file=-' "$repository_root/setup.sh"
	rg -q 'SETUP_TARGET_LUKS_PASSWORD=\$password' "$repository_root/setup.sh"
	rg -q 'Reuse the password already entered to unlock target ROOT' "$repository_root/setup.sh"
	if rg -q 'Target ROOT LUKS passphrase' "$repository_root/setup.sh"; then
		printf 'Target ROOT password must not be requested twice.\n' >&2
		return 1
	fi
	rg -q 'continue migration without imported keys' "$repository_root/setup.sh"
	rg -q 'ROOT contains no Btrfs filesystem to inspect' "$repository_root/setup.sh"
	rg -q 'mkfs\.btrfs -L ROOT /dev/mapper/root' "$repository_root/btrfs-root/scripts/cross-disk-migration"
	rg -q 'require_unique_label "\$target_disk" RESCUE' "$repository_root/setup.sh"
	rg -q 'Target rescue partition is already labelled UBUNTU_LIVE' "$repository_root/setup.sh"
	rg -q 'Target rescue partition is labelled RESCUE' "$repository_root/setup.sh"
	rg -q 'migration_mode != cross_disk' "$repository_root/setup.sh"
	rg -q 'subvolid=5 /dev/mapper/sbctl-key-scan' "$repository_root/setup.sh"
	rg -q 'find "\$scan_mount" -type d -print' "$repository_root/setup.sh"
	if rg -q 'source_root=/target/var/lib/sbctl/keys' "$repository_root/setup.sh"; then
		printf 'sbctl key discovery must not assume /target.\n' >&2
		return 1
	fi
	rg -q 'secure_boot_enrollment=existing' "$repository_root/setup.sh"
	rg -q 'if \[\[ -n \$sbctl_import_keyroot \]\]' "$repository_root/setup.sh"
	rg -q 'sbctl_import_keyroot' "$repository_root/setup.sh"
	rg -q 'secure_boot_enrollment == existing' "$repository_root/secure-boot/scripts/sbctl-setup"
	rg -q 'import_existing_keys' "$repository_root/secure-boot/scripts/sbctl-setup"
	rg -q 'Skip rEFInd installation in the ESP' "$repository_root/secure-boot/scripts/secure-boot-setup"
	rg -q 'log\.section "Distribution configuration"' "$repository_root/setup.sh"
	rg -q 'log\.section "Encryption and boot security"' "$repository_root/setup.sh"
	rg -q 'log\.section "LUKS and Argon2id"' "$repository_root/setup.sh"
	rg -q 'log\.section "Optional features"' "$repository_root/setup.sh"
	rg -q 'log\.section "TPM integration"' "$repository_root/setup.sh"
	rg -q 'log\.section "Snapshot menu"' "$repository_root/setup.sh"
	rg -q 'cross-disk-migration\.initialized_target' "$repository_root/setup.sh"
	rg -q 'cross-disk-migration\.partition_new_target' "$repository_root/setup.sh"
	rg -q 'cross-disk-migration\.import_source' "$repository_root/setup.sh"
	rg -q 'migration_mode' "$repository_root/setup.sh"
	rg -q 'PARTLABEL' "$repository_root/btrfs-root/scripts/cross-disk-migration"
	rg -q 'sgdisk --zap-all' "$repository_root/btrfs-root/scripts/cross-disk-migration"
	rg -q 'luksFormat.*--label ROOT' "$repository_root/btrfs-root/scripts/cross-disk-migration"
	rg -q 'Proceed with the installation using these values' "$repository_root/setup.sh"
}

tui-test.input_and_password_defaults
tui-test.selections
tui-test.toggles
tui-test.generated_config_contract
printf 'tui_test: PASS\n'
