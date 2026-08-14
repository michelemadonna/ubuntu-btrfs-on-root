#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$test_dir/../.." && pwd)"

# Runtime-derived sources let tests run from any current directory.
# shellcheck disable=SC1090,SC1091
source "$repository_root/secure-boot/scripts/secure-boot-setup"
# shellcheck disable=SC1090,SC1091
source "$repository_root/secure-boot/scripts/refind-setup"
# shellcheck disable=SC1090,SC1091
source "$repository_root/secure-boot/scripts/fwupd-setup"

secure-boot-test.fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

secure-boot-test.assert_equal() {
	local expected=$1
	local actual=$2

	[[ $actual == "$expected" ]] ||
		secure-boot-test.fail "expected '$expected', got '$actual'"
}

secure-boot-test.test_trust_path() {
	secure-boot-test.assert_equal direct "$(secure-boot-setup.trust_path 1)"
	secure-boot-test.assert_equal shim-mok "$(secure-boot-setup.trust_path 0)"
	if secure-boot-setup.trust_path 2 >/dev/null; then
		secure-boot-test.fail "invalid SetupMode selected a trust path"
	fi
}

secure-boot-test.test_refind_loader_path() {
	REFIND_EFI=/boot/efi/EFI/refind
	secure-boot-test.assert_equal \
		/boot/efi/EFI/refind/refind_x64.efi \
		"$(refind-setup.repository_signed_loader_path 1)"
	secure-boot-test.assert_equal \
		/boot/efi/EFI/refind/grubx64.efi \
		"$(refind-setup.repository_signed_loader_path 0)"
}

secure-boot-test.test_remove_grubefi_directories() {
	local test_root

	test_root="$(mktemp -d "${TMPDIR:-/tmp}/refind-cleanup-test.XXXXXX")"
	mkdir -p "$test_root/EFI/remove/nested" "$test_root/EFI/keep"
	: >"$test_root/EFI/remove/nested/grubefi_x64.efi"
	: >"$test_root/EFI/keep/grubx64.efi"
	refind-setup.remove_grubefi_directories "$test_root/EFI" >/dev/null
	[[ ! -e $test_root/EFI/remove ]] || secure-boot-test.fail "directory containing grubefi_x64.efi was retained"
	[[ -d $test_root/EFI/keep ]] || secure-boot-test.fail "unrelated EFI directory was removed"
	rm -rf -- "$test_root"
}

secure-boot-test.test_fwupd_trust_mode() {
	secure-boot-test.assert_equal true "$(fwupd-setup.disable_shim_for_mode 1)"
	secure-boot-test.assert_equal false "$(fwupd-setup.disable_shim_for_mode 0)"
	if fwupd-setup.disable_shim_for_mode 2 >/dev/null; then
		secure-boot-test.fail "invalid SetupMode selected an fwupd trust mode"
	fi
}

secure-boot-test.test_summary_has_no_secret() {
	local output

	# Values are consumed dynamically by the sourced summary function.
	# shellcheck disable=SC2034
	SETUP_MODE=0
	# shellcheck disable=SC2034
	SECURE_BOOT=1
	# shellcheck disable=SC2034
	SBCTL_KEYROOT=/keys
	# shellcheck disable=SC2034
	ESP=/esp
	# shellcheck disable=SC2034
	SHIM_DIR=/shim
	# shellcheck disable=SC2034
	mok_pin=must-not-appear
	output="$(secure-boot-setup.print_summary 2>&1)"
	[[ $output == *"shim-mok"* ]] || secure-boot-test.fail "trust path missing from summary"
	[[ $output != *"$mok_pin"* ]] || secure-boot-test.fail "MOK PIN leaked into summary"
}

secure-boot-test.test_trust_path
secure-boot-test.test_refind_loader_path
secure-boot-test.test_remove_grubefi_directories
secure-boot-test.test_fwupd_trust_mode
secure-boot-test.test_summary_has_no_secret
printf 'Secure Boot helper tests passed.\n'
