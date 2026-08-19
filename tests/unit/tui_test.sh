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
	[[ $prompt == *'Password [default: fallback]: ******'* ]] || {
		printf 'Password prompt must show the default and mask the entered value.\n' >&2
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
	rg -q "local disk default_disk root_path efi_path boot_path='' rescue_path" "$repository_root/setup.sh"
	rg -q 'Select installation mode' "$repository_root/setup.sh"
	rg -q 'root_size_strategy == percent' "$repository_root/setup.sh"
	rg -q 'Reserve partitions for Windows and Windows RE' "$repository_root/setup.sh"
	rg -q 'tui\.password_confirm "Initial LUKS passphrase"' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target/boot/efi' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target/boot' "$repository_root/setup.sh"
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
	rg -q 'log\.section "Distribution configuration"' "$repository_root/setup.sh"
	rg -q 'log\.section "Encryption and boot security"' "$repository_root/setup.sh"
	rg -q 'log\.section "Optional features"' "$repository_root/setup.sh"
	rg -q 'Proceed with the installation using these values' "$repository_root/setup.sh"
}

tui-test.input_and_password_defaults
tui-test.selections
tui-test.toggles
tui-test.generated_config_contract
printf 'tui_test: PASS\n'
