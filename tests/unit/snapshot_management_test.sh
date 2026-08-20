#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export SETUP_CONFIG_FILE="$repository_root/setup.conf.example"
# shellcheck source=/dev/null
source "$repository_root/btrfs-snapshots-mng/scripts/btrfs-snapshots-mng-setup"

snapshot-management-test.assert_contains() {
	local output=$1
	local expected=$2

	[[ $output == *"$expected"* ]] || {
		printf 'Expected output to contain: %s\n' "$expected" >&2
		return 1
	}
}

snapshot-management-test.base_config() {
	local kali_output output

	output="$(btrfs-snapshots-mng-setup.render_base_config '@noble/@' ubuntu noble)"
	snapshot-management-test.assert_contains "$output" 'ROOT_SUBVOL="@noble/@"'
	snapshot-management-test.assert_contains "$output" 'SUITE="noble"'
	snapshot-management-test.assert_contains "$output" 'SNAPSHOT_TRIGGER="B"'
	snapshot-management-test.assert_contains "$output" 'PAGE_SIZE=20'
	[[ $output != *'Alt-based triggers are unsupported'* ]]
	[[ $output != *'SNAPSHOT_PLYMOUTH_KEY_FALLBACK'* ]]

	kali_output="$(btrfs-snapshots-mng-setup.render_base_config '@kali/@' kali kali)"
	snapshot-management-test.assert_contains "$kali_output" 'SUITE="kali"'
	snapshot-management-test.assert_contains "$kali_output" 'SNAPSHOT_TRIGGER="B"'
	snapshot-management-test.assert_contains \
		"$kali_output" \
		'Alt-based triggers are unsupported'
	[[ $kali_output != *'SNAPSHOT_PLYMOUTH_KEY_FALLBACK'* ]]
}

snapshot-management-test.pin_config() {
	local output

	output="$(btrfs-snapshots-mng-setup.append_pin_config fake-salt fake-hash)"
	snapshot-management-test.assert_contains "$output" 'SNAPSHOT_PIN_ENABLED=yes'
	snapshot-management-test.assert_contains "$output" 'SNAPSHOT_PIN_ATTEMPTS=3'
	snapshot-management-test.assert_contains "$output" 'SNAPSHOT_PIN_SALT="fake-salt"'
	snapshot-management-test.assert_contains "$output" 'SNAPSHOT_PIN_HASH="fake-hash"'
}

snapshot-management-test.kernel_guard() {
	local menu="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/snapshot-menu.sh"
	local hook="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/snapshot-menu-hook.sh"

	rg -q 'KERNEL_STATUS\[(\$)?selected\].*Present' "$menu"
	rg -q 'Cannot boot snapshot.*kernel modules' "$menu"
	rg -Fq 'UUID=*)' "$hook"
	rg -Fq "snapshot-menu: pre-mount:" "$hook"
	rg -Fq "request marker is absent" "$hook"
	dash -n "$hook"
}

snapshot-management-test.snapper_resume_contract() {
	local setup="$repository_root/btrfs-snapshots-mng/scripts/snapper-setup"

	rg -q 'Reuse existing Snapper profile' "$setup"
	rg -q 'Remove migrated source snapshot directory' "$setup"
	rg -q 'rm -Rf -- "\$snapshot_path"' "$setup"
	rg -q 'Remove source snapshot directories before creating target Snapper profiles' \
		"$repository_root/btrfs-root/scripts/cross-disk-migration"
}

snapshot-management-test.initramfs_logging() {
	local hook="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/snapshot-menu-hook.sh"
	local listener_stop="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/listener/snapshot-key-listener-stop"

	rg -Fq "snapshot-menu: listener-stop:" "$listener_stop"
	rg -Fq "listener finished status=" "$listener_stop"
	rg -Fq "snapshot menu requested" "$listener_stop"
	rg -Fq "plymouth watch-keystroke" "$listener_stop"
	rg -Fq "Plymouth splash restored after trigger" "$listener_stop"
	rg -Fq "enabled message retained until pre-mount" "$listener_stop"
	rg -Fq 'plymouth hide-message' "$hook"
	rg -Fq -- '--text="Snapshot menu ENABLED"' "$hook"
	rg -Fq 'keys=bB' "$listener_stop"
}

snapshot-management-test.suite_labels() {
	local menu="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/snapshot-menu.sh"

	rg -Fq '"$SUITE - current system"' "$menu"
	rg -Fq "printf '%s Snapshot Boot\\n' \"\$SUITE\"" "$menu"
	if rg -Fq 'Ubuntu Snapshot Boot' "$menu" || rg -Fq 'Ubuntu - current system' "$menu"; then
		return 1
	fi
}

snapshot-management-test.function_key_mapping() {
	local listener="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/listener/snapshot-key-listener.c"
	local listener_stop="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/listener/snapshot-key-listener-stop"
	local module_setup="$repository_root/btrfs-snapshots-mng/dracut/92snapshot-menu/module-setup.sh"

	rg -Fq 'case 12: return KEY_F12;' "$listener"
	rg -Fq 'trigger_argument = "B";' "$listener"
	if rg -Fq 'return KEY_F1 + (int)number - 1;' "$listener"; then
		return 1
	fi
	rg -Fq 'DEFAULT_TRIGGER="B"' "$listener_stop"
	rg -q '^[[:space:]]*instmods evdev$' "$module_setup"
	rg -Fq 'accepted input device path=' "$listener"
	rg -Fq 'trigger event device=event%u code=%u value=%d' "$listener"
	rg -Fq 'request marker created' "$listener"
}

snapshot-management-test.run() {
	snapshot-management-test.base_config
	snapshot-management-test.pin_config
	snapshot-management-test.kernel_guard
	snapshot-management-test.snapper_resume_contract
	snapshot-management-test.initramfs_logging
	snapshot-management-test.suite_labels
	snapshot-management-test.function_key_mapping
	printf 'snapshot_management_test: PASS\n'
}

snapshot-management-test.run
