#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
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
	local output

	output="$(btrfs-snapshots-mng-setup.render_base_config '@ubuntu/@')"
	snapshot-management-test.assert_contains "$output" 'ROOT_SUBVOL="@ubuntu/@"'
	snapshot-management-test.assert_contains "$output" 'SNAPSHOT_TRIGGER="ALT+B"'
	snapshot-management-test.assert_contains "$output" 'PAGE_SIZE=20'
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

	rg -q 'KERNEL_STATUS\[\$selected\].*Present' "$menu"
	rg -q 'Cannot boot snapshot.*kernel modules' "$menu"
}

snapshot-management-test.run() {
	snapshot-management-test.base_config
	snapshot-management-test.pin_config
	snapshot-management-test.kernel_guard
	printf 'snapshot_management_test: PASS\n'
}

snapshot-management-test.run
