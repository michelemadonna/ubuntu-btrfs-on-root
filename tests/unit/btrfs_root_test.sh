#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$test_dir/../.." && pwd)"
export SETUP_CONFIG_FILE="$repository_root/setup.conf.example"

# Paths are runtime-derived so tests work from any current directory.
# shellcheck disable=SC1090,SC1091
source "$repository_root/lib/common.sh"
# shellcheck disable=SC1090,SC1091
source "$repository_root/btrfs-root/scripts/btrfs-root-setup"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_equal() {
	local expected=$1
	local actual=$2

	[[ $actual == "$expected" ]] ||
		fail "expected '$expected', got '$actual'"
}

test_crypttab_entry() {
	assert_equal \
		"root UUID=1234-abcd none luks,discard" \
		"$(luks-setup.build_crypttab_entry "1234-abcd")"
}

test_subvolume_paths() {
	local output

	root_sub_vol="@ubuntu"
	output="$(btrfs-root-setup.configured_subvolume_paths)"
	[[ $output == *$'@ubuntu/@home\n'* ]] || fail "@home path is missing"
	[[ $output == *$'@ubuntu/@swap'* ]] || fail "@swap path is missing"
}

test_fstab_entries() {
	local output

	output="$(fstab-setup.build_entries "defaults,noatime" "@ubuntu")"
	assert_equal \
		"/dev/mapper/root / btrfs defaults,noatime,subvol=@ubuntu/@ 0 1" \
		"$(fstab-setup.build_root_entry "defaults,noatime" "@ubuntu")"
	[[ $output == *"subvol=@ubuntu/@home"* ]] || fail "@home fstab entry is missing"
	[[ $output == *"/swap/swapfile none"* ]] || fail "swapfile entry is missing"
	output="$(fstab-setup.build_fstab "root-uuid" "efi-uuid" "defaults,noatime" "@ubuntu")"
	[[ $output == *"UUID=root-uuid / btrfs defaults,noatime,subvol=@ubuntu/@ 0 1"* ]] || fail "UUID root entry is missing"
	[[ $output == *"UUID=efi-uuid /boot/efi vfat"* ]] || fail "UUID EFI entry is missing"
}

test_summary() {
	local output

	root_dev="vda3"
	efi_dev="vda2"
	mp="/mnt/target"
	root_sub_vol="@ubuntu"
	swap_size="4G"
	keyslot_size="32m"
	iter_time="3000"
	enlarge="no"
	PASSPHRASE="must-not-appear"
	output="$(btrfs-root-setup.print_summary)"

	[[ $output == *"/dev/vda3"* ]] || fail "source partition is missing from summary"
	[[ $output == *"/dev/vda2 (label ESP)"* ]] || fail "EFI label is missing from summary"
	[[ $output == *"/dev/mapper/root"* ]] || fail "mapper is missing from summary"
	[[ $output == *"3000 ms"* ]] || fail "Argon2id time target is missing from summary"
	[[ $output == *"/mnt/target/etc/crypttab"* ]] || fail "crypttab path is missing from summary"
	[[ $output != *"$PASSPHRASE"* ]] || fail "passphrase leaked into summary"
}

test_configuration_validation() {
	root_dev="vda3"
	efi_dev="vda2"
	mp="/mnt/target"
	root_sub_vol="@ubuntu"
	swap_size="4G"
	keyslot_size="32m"
	iter_time="3000"
	export btrfs_options="defaults,noatime"
	enlarge="no"
	PASSPHRASE="configured"
	btrfs-subvol-setup.validate_configuration
	luks-setup.validate_configuration
	fstab-setup.validate_configuration

	iter_time="0"
	if (luks-setup.validate_configuration) 2>/dev/null; then
		fail "zero iter_time was accepted"
	fi
	iter_time="3000"

	mp="/"
	if (btrfs-subvol-setup.validate_configuration) 2>/dev/null; then
		fail "root mount point was accepted as an installation target"
	fi
}

test_crypttab_entry
test_subvolume_paths
test_fstab_entries
test_summary
test_configuration_validation
printf 'Btrfs root helper tests passed.\n'
