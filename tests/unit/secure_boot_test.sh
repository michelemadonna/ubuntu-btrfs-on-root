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

secure-boot-test.test_fwupd_trust_mode() {
	secure-boot-test.assert_equal true "$(fwupd-setup.disable_shim_for_mode 1)"
	secure-boot-test.assert_equal false "$(fwupd-setup.disable_shim_for_mode 0)"
	if fwupd-setup.disable_shim_for_mode 2 >/dev/null; then
		secure-boot-test.fail "invalid SetupMode selected an fwupd trust mode"
	fi
}

secure-boot-test.test_summary_has_no_secret() {
	local output

	SETUP_MODE=0
	SECURE_BOOT=1
	SBCTL_KEYROOT=/keys
	ESP=/esp
	SHIM_DIR=/shim
	mok_pin=must-not-appear
	output="$(secure-boot-setup.print_summary 2>&1)"
	[[ $output == *"shim-mok"* ]] || secure-boot-test.fail "trust path missing from summary"
	[[ $output != *"$mok_pin"* ]] || secure-boot-test.fail "MOK PIN leaked into summary"
}

secure-boot-test.test_trust_path
secure-boot-test.test_refind_loader_path
secure-boot-test.test_fwupd_trust_mode
secure-boot-test.test_summary_has_no_secret
printf 'Secure Boot helper tests passed.\n'
