#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$test_dir/../.." && pwd)"

# The path is runtime-derived so the test works from any current directory.
# shellcheck disable=SC1090,SC1091
source "$repository_root/lib/common.sh"

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

test_log_info() {
	local output

	output="$(log.info "installation ready")"
	assert_equal $'\033[1;36mℹ [INFO]\033[0m installation ready' "$output"
}

test_log_summary_item() {
	local output

	output="$(log.summary_item "Root mapper" "/dev/mapper/root")"
	assert_equal $'  \033[1;36m• Root mapper:          \033[0m /dev/mapper/root' "$output"
}

test_log_error() {
	local output

	output="$(log.error "installation failed" 2>&1)"
	assert_equal $'\033[1;31m✖ [ERROR]\033[0m installation failed' "$output"
}

test_log_section_boundaries_and_color_rotation() {
	local output

	output="$(
		log.section "First phase"
		log.section "Second phase"
		log.section_end
	)"
	[[ $output == *$'\033[1;35m╔══▶ BEGIN: First phase\033[0m'* ]] || fail "first section begin marker is missing"
	[[ $output == *$'\033[1;35m╚══■ END:   First phase\033[0m'* ]] || fail "automatic section end marker is missing"
	[[ $output == *$'\033[1;34m╔══▶ BEGIN: Second phase\033[0m'* ]] || fail "section color did not rotate"
	[[ $output == *$'\033[1;34m╚══■ END:   Second phase\033[0m'* ]] || fail "explicit section end marker is missing"
}

test_require_readable_file() {
	common.require_readable_file "$repository_root/setup.conf" "Configuration file"
}

test_require_nonempty() {
	local output

	common.require_nonempty "suite" "ubuntu"
	if output="$(common.require_nonempty "suite" "" 2>&1)"; then
		fail "require_nonempty accepted an empty value"
	fi
	assert_equal \
		$'\033[1;31m✖ [ERROR]\033[0m suite must be configured.\n\033[1;31m✖ [ERROR]\033[0m Command exit status: 1' \
		"$output"
}

test_log_die_preserves_status_and_detail() {
	local output status

	set +e
	output="$(bash -c 'source "$1"; log.die "command failed" "captured stderr" 42' _ "$repository_root/lib/log.sh" 2>&1)"
	status=$?
	set -e

	assert_equal "42" "$status"
	[[ $output == *"Command exit status: 42"* ]] || fail "log.die omitted command exit status"
	[[ $output == *"Command error: captured stderr"* ]] || fail "log.die omitted explicit command error"
}

test_require_commands() {
	common.require_commands printf
	if (common.require_commands codex-command-that-does-not-exist) 2>/dev/null; then
		fail "require_commands accepted a missing command"
	fi
}

test_log_info
test_log_summary_item
test_log_error
test_log_section_boundaries_and_color_rotation
test_log_die_preserves_status_and_detail
test_require_readable_file
test_require_nonempty
test_require_commands
printf 'Common framework tests passed.\n'
