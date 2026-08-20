#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$test_dir/../.." && pwd)"
export SETUP_CONFIG_FILE="$repository_root/setup.conf.example"

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
	secure-boot-test.assert_equal direct-sbctl "$(secure-boot-setup.trust_path sbctl)"
	secure-boot-test.assert_equal shim-mok "$(secure-boot-setup.trust_path mok)"
	if secure-boot-setup.trust_path invalid >/dev/null; then
		secure-boot-test.fail "invalid enrollment method selected a trust path"
	fi
}

secure-boot-test.test_refind_loader_path() {
	export REFIND_EFI=/boot/efi/EFI/refind
	secure-boot-test.assert_equal \
		/boot/efi/EFI/refind/refind_x64.efi \
		"$(refind-setup.repository_signed_loader_path sbctl)"
	secure-boot-test.assert_equal \
		/boot/efi/EFI/refind/grubx64.efi \
		"$(refind-setup.repository_signed_loader_path mok)"
}

secure-boot-test.test_fallback_directory_creation() {
	local test_root

	test_root="$(mktemp -d "${TMPDIR:-/tmp}/refind-fallback-test.XXXXXX")"
	REFIND_FALLBACK_EFI="$test_root/EFI/BOOT"
	refind-setup.prepare_fallback_directory >/dev/null
	[[ -d $REFIND_FALLBACK_EFI ]] || secure-boot-test.fail "UEFI fallback directory was not created"
	rm -rf -- "$test_root"
}

secure-boot-test.test_remove_grubefi_directories() {
	local test_root

	test_root="$(mktemp -d "${TMPDIR:-/tmp}/refind-cleanup-test.XXXXXX")"
	mkdir -p "$test_root/EFI/remove/nested" "$test_root/EFI/keep"
	: >"$test_root/EFI/remove/nested/grubx64.efi"
	: >"$test_root/EFI/keep/other-loader.efi"
	refind-setup.remove_grubefi_directories "$test_root/EFI" >/dev/null
	[[ ! -e $test_root/EFI/remove ]] || secure-boot-test.fail "directory containing grubx64.efi was retained"
	[[ -d $test_root/EFI/keep ]] || secure-boot-test.fail "unrelated EFI directory was removed"
	rm -rf -- "$test_root"
}

secure-boot-test.test_fwupd_trust_mode() {
	secure-boot-test.assert_equal true "$(fwupd-setup.disable_shim_for_mode sbctl)"
	secure-boot-test.assert_equal false "$(fwupd-setup.disable_shim_for_mode mok)"
	if fwupd-setup.disable_shim_for_mode invalid >/dev/null; then
		secure-boot-test.fail "invalid enrollment method selected an fwupd trust mode"
	fi
}

secure-boot-test.test_summary_has_no_secret() {
	local output

	# Values are consumed dynamically by the sourced summary function.
	# shellcheck disable=SC2034
	SETUP_MODE=0
	# shellcheck disable=SC2034
	SECURE_BOOT=1
	secure_boot_mode=enabled
	secure_boot_enrollment=mok
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

secure-boot-test.test_public_certificate_copy() {
	local test_root

	test_root="$(mktemp -d "${TMPDIR:-/tmp}/secure-boot-cert-test.XXXXXX")"
	ESP="$test_root/esp"
	SBCTL_KEYROOT="$test_root/private"
	DB_CERT_DER="$SBCTL_KEYROOT/db/db.cer"
	mkdir -p "$ESP/EFI" "$SBCTL_KEYROOT/PK" "$SBCTL_KEYROOT/KEK" "$SBCTL_KEYROOT/db"
	printf 'public-pk\n' >"$SBCTL_KEYROOT/PK/PK.pem"
	printf 'public-kek\n' >"$SBCTL_KEYROOT/KEK/KEK.pem"
	printf 'public-db\n' >"$SBCTL_KEYROOT/db/db.pem"
	printf 'public-der\n' >"$DB_CERT_DER"
	printf 'private-db\n' >"$SBCTL_KEYROOT/db/db.key"
	secure-boot-setup.copy_public_certificates >/dev/null
	for certificate in PK.pem KEK.pem db.pem db.cer; do
		[[ -f $ESP/EFI/keys/$certificate ]] || secure-boot-test.fail "public certificate was not copied: $certificate"
	done
	[[ ! -e $ESP/EFI/keys/db.key ]] || secure-boot-test.fail "private key was copied to the ESP"
	rm -rf -- "$test_root"
}

secure-boot-test.test_sbctl_enrollment_contract() {
	local script="$repository_root/secure-boot/scripts/sbctl-setup"

	rg -q '^\s*sbctl enroll-keys --microsoft$' "$script" || secure-boot-test.fail "standard sbctl enrollment command is missing"
	rg -q 'EXPERIMENTAL_SBCTL_APPEND != true' "$script" || secure-boot-test.fail "experimental append guard is missing"
	rg -Fq '/usr/sbin/sbctl' "$script" || secure-boot-test.fail "sbctl is not installed in /usr/sbin"
}

secure-boot-test.test_trust_path
secure-boot-test.test_refind_loader_path
secure-boot-test.test_fallback_directory_creation
secure-boot-test.test_remove_grubefi_directories
secure-boot-test.test_fwupd_trust_mode
secure-boot-test.test_summary_has_no_secret
secure-boot-test.test_public_certificate_copy
secure-boot-test.test_sbctl_enrollment_contract
printf 'Secure Boot helper tests passed.\n'
