#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export SETUP_CONFIG_FILE="$repository_root/setup.conf.example"
# shellcheck source=/dev/null
source "$repository_root/uki/scripts/install-uki"
# shellcheck source=/dev/null
source "$repository_root/uki/scripts/generate-uki"

uki-test.assert_equal() {
	local expected=$1 actual=$2
	[[ $actual == "$expected" ]] || {
		printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
		return 1
	}
}

uki-test.cmdline() {
	local actual
	actual="$(install-uki.build_cmdline btrfs-uuid luks-uuid 'defaults,compress=zstd:1' '@ubuntu/@')"
	uki-test.assert_equal \
		'root=UUID=btrfs-uuid rootfstype=btrfs rootflags=defaults,compress=zstd:1,subvol=@ubuntu/@ rd.luks.uuid=luks-luks-uuid rd.shell=0 rd.emergency=halt quiet splash' \
		"$actual"
}

uki-test.trim() {
	uki-test.assert_equal ubuntu "$(generate-uki.trim $' \tubuntu \n')"
}

uki-test.artifact_contract() {
	local generator="$repository_root/uki/scripts/generate-uki"
	local menu_hook="$repository_root/uki/hooks/kernel/install.d/99-refind-menu.install"
	local package_bridge="$repository_root/uki/hooks/kernel/postinst.d/debian-kernel-install-bridge"

	rg -q '^[[:space:]]*\.linux' "$generator"
	rg -q '\.pcrsig' "$generator"
	rg -q '\.sbat' "$generator"
	rg -Fq '/usr/sbin/generate-uki' "$repository_root/uki/scripts/install-uki"
	if rg -Fq '/usr/local/sbin/generate-uki --all' "$repository_root/uki/scripts/install-uki"; then
		return 1
	fi
	rg -q 'sort -Vr' "$menu_hook"
	rg -q 'refind-menu\.generate' "$menu_hook"
	rg -q 'ICON_TOKEN_FILE="/etc/kernel/refind-icon"' "$menu_hook"
	rg -q 'os_\$\{ICON_TOKEN\}\.png' "$menu_hook"
	rg -q 'submenuentry' "$menu_hook"
	rg -q 'add | remove' "$menu_hook"
	rg -q 'kernel-install add "\$version" "\$kernel_image"' "$package_bridge"
	rg -q 'kernel-install remove "\$version"' "$package_bridge"
}

uki-test.reject_invalid_artifact() {
	local artifact
	artifact="$(mktemp "${TMPDIR:-/tmp}/uki-test.XXXXXX.efi")"
	# Consumed by generate-uki.reject_artifact sourced above.
	# shellcheck disable=SC2034
	REFIND_MENU_HOOK=/nonexistent/refind-menu-hook
	generate-uki.reject_artifact "$artifact" 2>/dev/null
	[[ ! -e $artifact ]]
}

uki-test.run() {
	uki-test.cmdline
	uki-test.trim
	uki-test.artifact_contract
	uki-test.reject_invalid_artifact
	printf 'uki_test: PASS\n'
}

uki-test.run
