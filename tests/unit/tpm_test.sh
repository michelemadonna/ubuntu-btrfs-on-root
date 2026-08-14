#!/usr/bin/env bash
# Test globals are consumed by functions sourced from the TPM scripts.
# shellcheck disable=SC2034

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TPM_CONFIG="$repository_root/tpm/config/tpm.conf"
# shellcheck source=/dev/null
source "$repository_root/tpm/scripts/install-tpm"
# shellcheck source=/dev/null
source "$repository_root/tpm/scripts/tpm-enroll"

tpm-test.assert_equal() {
	local expected=$1 actual=$2
	[[ $actual == "$expected" ]] || {
		printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
		return 1
	}
}

tpm-test.kernel_options() {
	tpm-test.assert_equal \
		'rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes' \
		"$(install-tpm.build_kernel_option auto)"
	tpm-test.assert_equal \
		'root=UUID=test quiet rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes' \
		"$(install-tpm.merge_kernel_option \
			'root=UUID=test rd.luks.options=tpm2-device=auto,tpm2-pin=yes quiet' \
			'rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes')"
}

tpm-test.enrollment_arguments() {
	LUKS_DEVICE=/dev/test
	TPM_DEVICE=auto
	TPM_LITERAL_PCRS=7+14
	TPM_SIGNED_PCRS=11
	PCR_PUBLIC_KEY=/etc/uki/keys/pcr-public.pem
	TPM_USE_PIN=false

	local output
	output="$(tpm-enroll.build_arguments no)"
	[[ $output != *'--wipe-slot=tpm2'* ]]
	output="$(tpm-enroll.build_arguments yes)"
	[[ $output == *'--wipe-slot=tpm2'* ]]
	[[ $output == *'--tpm2-public-key-pcrs=11'* ]]
}

tpm-test.token_detection_does_not_use_a_short_circuit_pipe() {
	tpm-enroll.has_tpm2_token $'Tokens:\n  0: systemd-tpm2' || return 1
	if tpm-enroll.has_tpm2_token $'Tokens:\n  0: systemd-recovery'; then
		return 1
	fi
	if rg -q 'cryptsetup luksDump .*\| grep -q' "$repository_root/tpm/scripts/tpm-enroll"; then
		return 1
	fi
}

tpm-test.configuration_paths() {
	rg -q 'INSTALL_TPM_CONFIG=/etc/tpm.conf' "$repository_root/tpm/scripts/install-tpm"
	if rg -q '/etc/uki/tpm\.conf' "$repository_root/tpm"; then
		return 1
	fi
	rg -q '^TPM_LITERAL_PCRS="7\+14\+15:sha256=0{64}"$' "$TPM_CONFIG"
	rg -q '^TPM_SIGNED_PCRS="11"$' "$TPM_CONFIG"
}

tpm-test.runtime_commands_are_standalone() {
	local command_file
	for command_file in \
		"$repository_root/uki/scripts/generate-uki" \
		"$repository_root/tpm/scripts/tpm-enroll" \
		"$repository_root/tpm/scripts/tpm-reseal" \
		"$repository_root/tpm/scripts/tpm-status"; do
		if rg -q 'common\.sh|repository_root' "$command_file"; then
			return 1
		fi
	done
}

tpm-test.run() {
	tpm-test.kernel_options
	tpm-test.enrollment_arguments
	tpm-test.token_detection_does_not_use_a_short_circuit_pipe
	tpm-test.configuration_paths
	tpm-test.runtime_commands_are_standalone
	printf 'tpm_test: PASS\n'
}

tpm-test.run
