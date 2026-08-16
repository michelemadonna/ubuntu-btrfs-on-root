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
	local output
	output="$(tui-test.with_input $'\n' tui.input "Value" "default" 2>/dev/null)"
	tui-test.assert_equal default "$output"
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
	rg -q 'setup\.generate_configuration' "$repository_root/setup.sh"
	if rg -q 'source .*setup\.conf\.example' "$repository_root/setup.sh"; then
		printf 'setup.sh must not depend on setup.conf.example\n' >&2
		return 1
	fi
	rg -q "local root_dev=sda3 efi_dev=sda2 boot_dev='' rescue_dev=sda1 iter_time=3000 swap_size=4G suite=resolute suite_type=ubuntu" "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target/boot/efi' "$repository_root/setup.sh"
	rg -q 'setup\.mounted_device /target/boot' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" boot_dev "\$boot_dev"' "$repository_root/setup.sh"
	rg -q 'Reuse .* as the rescue partition after copying /boot into Btrfs' "$repository_root/setup.sh"
	if awk '/^setup\.prepare_target\(\)/,/^}/' "$repository_root/setup.sh" | rg -q 'umount'; then
		printf 'setup.prepare_target must not unmount the Ubiquity target\n' >&2
		return 1
	fi
	rg -q 'setup\.write_config_value "\$temporary_config" mp "\$mp"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" keyslot_size "\$keyslot_size"' "$repository_root/setup.sh"
	rg -q 'setup\.write_config_value "\$temporary_config" btrfs_options "\$btrfs_options"' "$repository_root/setup.sh"
	rg -q "'resolute|Ubuntu Resolute' 'noble|Ubuntu Noble'" "$repository_root/setup.sh"
	rg -q 'not suitable for converting an existing production system' "$repository_root/setup.sh"
	rg -q "'ubuntu|Ubuntu'" "$repository_root/setup.sh"
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
