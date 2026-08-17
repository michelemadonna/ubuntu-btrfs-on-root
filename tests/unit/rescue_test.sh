#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$repository_root/rescue/script/install-rescue-live"

rescue-test.assert_equal() {
	local expected=$1 actual=$2
	[[ $actual == "$expected" ]] || {
		printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
		return 1
	}
}

rescue-test.rescue_size() {
	rescue-test.assert_equal 7168 "$(install-rescue-live.calculate_rescue_mib 4096)"
	rescue-test.assert_equal 8256 "$(install-rescue-live.calculate_rescue_mib 8000)"
}

rescue-test.grub_persistence() {
	local fixture
	fixture="$(mktemp "${TMPDIR:-/tmp}/rescue-grub.XXXXXX")"
	cat >"$fixture" <<-'EOF'
		menuentry "Try Ubuntu" {
		    linux /casper/vmlinuz quiet splash ---
		    initrd /casper/initrd
		}
		menuentry "Installed system" {
		    linux /vmlinuz root=/dev/test
		}
	EOF

	install-rescue-live.patch_grub_config "$fixture"
	install-rescue-live.patch_grub_config "$fixture"
	grep -Eq 'linux /casper/vmlinuz quiet splash persistent ---' "$fixture"
	[[ $(grep -o persistent "$fixture" | wc -l | tr -d ' ') == 1 ]]
	grep -Eq 'linux /vmlinuz root=/dev/test$' "$fixture"
	rm -f -- "$fixture"
}

rescue-test.setup_integration() {
	local rescue_line storage_line
	rg -q 'setup\.install_rescue_system' "$repository_root/setup.sh"
	rg -q 'TARGET_DEV="/dev/\$rescue_dev"' "$repository_root/setup.sh"
	rescue_line="$(rg -n 'setup\.install_rescue_system' "$repository_root/setup.sh" | tail -n1 | cut -d: -f1)"
	storage_line="$(rg -n $'^\t"\$repository_root/btrfs-root/scripts/btrfs-root-setup"$' "$repository_root/setup.sh" | cut -d: -f1)"
	((rescue_line > storage_line))
	rg -q 'if \[\[ \$install_rescue == yes && \$suite_type != kali \]\]' "$repository_root/setup.sh"
	rg -q 'install_rescue="\$\(tui\.toggle "Create the persistent rescue system"' "$repository_root/setup.sh"
	rg -q -- '--install-rescue-live' "$repository_root/setup.sh"
	rg -q 'setup_action=install-rescue-live' "$repository_root/setup.sh"
	rg -q 'RESCUE_SOURCE_DIR:-/cdrom' "$repository_root/setup.sh"
}

rescue-test.partition_backed_persistence_contract() {
	local installer="$repository_root/rescue/script/install-rescue-live"

	rg -q 'resizepart' "$installer"
	rg -q -- '---pretend-input-tty' "$installer"
	rg -q 'mkpart writable ext4' "$installer"
	rg -q 'mkfs\.ext4 -F -L writable "\$writable_dev"' "$installer"
	if rg -q 'of=.*writable|mkfs\.ext4.*rescue_mount_dir/writable' "$installer"; then
		return 1
	fi
}

rescue-test.run() {
	rescue-test.rescue_size
	rescue-test.grub_persistence
	rescue-test.setup_integration
	rescue-test.partition_backed_persistence_contract
	printf 'rescue_test: PASS\n'
}

rescue-test.run
