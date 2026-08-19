#!/usr/bin/env bash
# shellcheck disable=SC2034

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$repository_root/new-install/scripts/new-install-setup"

new-install-test.fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

new-install-test.value() {
	local name=$1 content=$2
	awk -F= -v name="$name" '$1 == name { print $2 }' <<<"$content"
}

new-install-test.layout_all_space() {
	local output

	output="$(new-install.calculate_layout 131072 1024 no all 70 no 0)"
	[[ $(new-install-test.value root_mib "$output") == 130044 ]] || new-install-test.fail "all-space root calculation is wrong"
	[[ $(new-install-test.value remaining_mib "$output") == 0 ]] || new-install-test.fail "all-space layout left allocatable space"
}

new-install-test.layout_with_rescue_and_windows() {
	local output

	output="$(new-install.calculate_layout 262144 1024 yes percent 60 yes 65536)"
	[[ $(new-install-test.value rescue_mib "$output") == 10240 ]] || new-install-test.fail "rescue is not 10 GiB"
	[[ $(new-install-test.value windows_required_mib "$output") == 66576 ]] || new-install-test.fail "Windows/MSR/RE size is wrong"
}

new-install-test.reject_windows_with_all_space() {
	if (new-install.calculate_layout 262144 1024 no all 70 yes 65536) >/dev/null 2>&1; then
		new-install-test.fail "Windows was accepted with all-space root"
	fi
}

new-install-test.insufficient_windows_is_retryable() {
	local status

	set +e
	(new-install.calculate_layout 131072 1024 no percent 80 yes 65536) >/dev/null 2>&1
	status=$?
	set -e
	[[ $status == 2 ]] || new-install-test.fail "insufficient Windows space did not return status 2"
}

new-install-test.partition_command_contract() {
	local commands_file
	commands_file="$(mktemp "${TMPDIR:-/tmp}/new-install-sgdisk.XXXXXX")"
	trap 'rm -f -- "$commands_file"' RETURN

	sgdisk() { printf '%s\n' "$*" >>"$commands_file"; }
	partprobe() { :; }
	udevadm() { :; }
	esp_size_mib=1024
	install_rescue=yes
	root_size_mib=100000
	install_windows=yes
	windows_size_mib=65536
	new-install.create_partition_table /dev/test-disk

	grep -Fq -- '-Z -o' "$commands_file" || new-install-test.fail "sgdisk does not wipe and create GPT"
	grep -Fq -- '-t 1:ef00 -c 1:ESP' "$commands_file" || new-install-test.fail "ESP GPT type is wrong"
	grep -Fq -- '-t 3:8309 -c 3:linux-root' "$commands_file" || new-install-test.fail "LUKS GPT type is wrong"
	grep -Fq -- 'Microsoft-reserved' "$commands_file" || new-install-test.fail "MSR is missing"
	grep -Fq -- 'Windows-RE' "$commands_file" || new-install-test.fail "Windows RE is missing"
}

new-install-test.wizard_windows_gate() {
	local body

	body="$(awk '/root_size_strategy == percent/,/root_size_mib=/' "$repository_root/setup.sh")"
	grep -Fq 'Reserve partitions for Windows and Windows RE' <<<"$body" || new-install-test.fail "Windows prompt is not inside percentage branch"
	grep -Fq 'install_windows=no' <<<"$body" || new-install-test.fail "all-space branch does not force Windows off"
}

new-install-test.archive_trust_contract() {
	grep -Fq '827C8569F2518CC677FECA1AED65462EC8D5E4C5' "$repository_root/new-install/scripts/new-install-setup" ||
		new-install-test.fail "Kali archive fingerprint is not pinned"
	grep -Fq 'Downloaded Kali keyring does not contain the pinned archive fingerprint' "$repository_root/new-install/scripts/new-install-setup" ||
		new-install-test.fail "Kali keyring verification is missing"
	if rg -q -- '--no-check-gpg' "$repository_root/new-install"; then
		new-install-test.fail "debootstrap signature verification was disabled"
	fi
}

new-install-test.destructive_ordering_contract() {
	local run_body confirm_line partition_line discover_line persist_line

	run_body="$(awk '/^new-install\.run\(\)/,/^}/' "$repository_root/new-install/scripts/new-install-setup")"
	confirm_line="$(grep -n 'new-install.confirm_destruction' <<<"$run_body" | cut -d: -f1)"
	partition_line="$(grep -n 'new-install.create_partition_table' <<<"$run_body" | cut -d: -f1)"
	discover_line="$(grep -n 'new-install.discover_partitions' <<<"$run_body" | cut -d: -f1)"
	persist_line="$(grep -n 'setup.persist_runtime_devices "' <<<"$run_body" | cut -d: -f1)"
	((confirm_line < partition_line)) || new-install-test.fail "sgdisk can run before exact-device confirmation"
	((partition_line < discover_line && discover_line < persist_line)) || new-install-test.fail "resolved devices are not persisted immediately after discovery"
}

new-install-test.distribution_repository_contract() {
	local installer="$repository_root/new-install/scripts/new-install-setup"

	grep -Fq 'mirror=https://http.kali.org/kali' "$installer" || new-install-test.fail "Kali debootstrap mirror is missing"
	grep -Fq 'keyring=/usr/share/keyrings/kali-archive-keyring.gpg' "$installer" || new-install-test.fail "Kali keyring is missing"
	grep -Fq 'kali-rolling main contrib non-free non-free-firmware' "$installer" || new-install-test.fail "Kali APT components are incomplete"
	grep -Fq 'mirror=http://archive.ubuntu.com/ubuntu' "$installer" || new-install-test.fail "Ubuntu debootstrap mirror is missing"
	grep -Fq 'keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg' "$installer" || new-install-test.fail "Ubuntu keyring is missing"
	grep -Fq "\$suite main restricted universe multiverse" "$installer" || new-install-test.fail "Ubuntu APT components are incomplete"
}

new-install-test.user_and_swap_contract() {
	local installer="$repository_root/new-install/scripts/new-install-setup"

	grep -Fq 'keyboard-configuration,sudo' "$installer" || new-install-test.fail "sudo is not included in bootstrap"
	grep -Fq 'useradd --create-home --shell /bin/bash --groups sudo' "$installer" || new-install-test.fail "initial sudo user creation is missing"
	grep -Fq 'chpasswd' "$installer" || new-install-test.fail "initial user password setup is missing"
	grep -Fq 'btrfs filesystem mkswapfile --size' "$installer" || new-install-test.fail "Btrfs swapfile creation is missing"
	grep -Fq "grep -Fq '/swap/swapfile' \"\$mp/etc/fstab\"" "$installer" || new-install-test.fail "swapfile fstab validation is missing"
	if grep -Fq 'TARGET_PASSWORD' "$repository_root/setup.sh" "$installer"; then
		new-install-test.fail "root password variable remains in the new-installation flow"
	fi
	grep -Fq 'Initial user name to create' "$repository_root/setup.sh" || new-install-test.fail "existing new configuration does not request the username"
	username_prompt_line="$(grep -n 'Initial user name to create' "$repository_root/setup.sh" | cut -d: -f1)"
	password_prompt_line="$(grep -nF "Password for \$TARGET_USERNAME" "$repository_root/setup.sh" | cut -d: -f1)"
	((username_prompt_line < password_prompt_line)) || new-install-test.fail "existing new configuration requests password before username"
}

new-install-test.deferred_device_validation_contract() {
	local body

	body="$(awk '/^setup\.load_configuration\(\)/,/^}/' "$repository_root/setup.sh")"
	grep -Fq "if [[ \$install_mode == migration ]]; then" <<<"$body" || new-install-test.fail "boot device validation is not migration-scoped"
	grep -Fq "if [[ \$install_mode == migration || \$setup_action == install-rescue-live ]]; then" <<<"$body" || new-install-test.fail "rescue device validation is not deferred for new installation"
}

new-install-test.configuration_prompt_contract() {
	local body

	body="$(sed -n '/setup\.load_configuration()/,/setup\.show_help()/p' "$repository_root/setup.sh")"
	grep -Fq 'configuration_generated=true' <<<"$body" || new-install-test.fail "new configuration generation is not tracked"
	grep -Fq 'configuration_generated == false' <<<"$body" || new-install-test.fail "existing configuration prompt guard is missing"
}

new-install-test.checkpoint_contract() {
	local installer="$repository_root/new-install/scripts/new-install-setup"

	for phase in partitions filesystems encrypted subvolumes bootstrapped configured complete; do
		grep -Fq "new-install.persist_phase $phase" "$installer" || new-install-test.fail "checkpoint is missing for phase $phase"
	done
	grep -Fq 'NEW_INSTALL_PHASE' "$repository_root/setup.sh" || new-install-test.fail "checkpoint is not part of setup configuration"
	grep -Fq 'new-install.phase_reached partitions' "$installer" || new-install-test.fail "partition phase is not resumable"
}

new-install-test.ubuntu_manual_package_contract() {
	local installer="$repository_root/new-install/scripts/new-install-setup"

	for package in ubuntu-desktop ubuntu-desktop-minimal ubuntu-minimal ubuntu-standard ubuntu-wallpapers open-vm-tools-desktop language-pack-en; do
		grep -Fq "$package" "$installer" || new-install-test.fail "Ubuntu manual package is missing: $package"
	done
	grep -Fq "apt-mark manual \"\${packages[@]}\"" "$installer" || new-install-test.fail "Ubuntu packages are not marked manual"
	grep -Fq 'new-install.install_ubuntu_manual_packages' "$repository_root/setup.sh" || new-install-test.fail "Ubuntu manual package phase is not invoked"
	grep -Fq 'dbus-uuidgen --ensure=/etc/machine-id' "$installer" || new-install-test.fail "target machine-id setup is missing"
}

new-install-test.hwe_kernel_contract() {
	local installer="$repository_root/new-install/scripts/new-install-setup"

	grep -Fq 'linux-generic-hwe-26.04' "$installer" || new-install-test.fail "Resolute HWE package is missing"
	grep -Fq 'linux-generic-hwe-24.04' "$installer" || new-install-test.fail "Noble HWE package is missing"
	grep -Fq 'Install the Ubuntu HWE kernel' "$repository_root/setup.sh" || new-install-test.fail "HWE prompt is missing"
	grep -Fq 'install_hwe' "$repository_root/setup.sh" || new-install-test.fail "HWE choice is not persisted"
}

new-install-test.layout_all_space
new-install-test.layout_with_rescue_and_windows
new-install-test.reject_windows_with_all_space
new-install-test.insufficient_windows_is_retryable
new-install-test.partition_command_contract
new-install-test.wizard_windows_gate
new-install-test.archive_trust_contract
new-install-test.destructive_ordering_contract
new-install-test.distribution_repository_contract
new-install-test.user_and_swap_contract
new-install-test.deferred_device_validation_contract
new-install-test.configuration_prompt_contract
new-install-test.checkpoint_contract
new-install-test.ubuntu_manual_package_contract
new-install-test.hwe_kernel_contract
printf 'new_install_test: PASS\n'
