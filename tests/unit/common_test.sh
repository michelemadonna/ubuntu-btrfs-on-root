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

	output="$(log_info "installation ready")"
	assert_equal $'\033[32mINFO:\033[0m installation ready' "$output"
}

test_require_readable_file() {
	require_readable_file "$repository_root/setup.conf" "Configuration file"
}

test_require_nonempty() {
	local output

	require_nonempty "suite" "ubuntu"
	if output="$(require_nonempty "suite" "" 2>&1)"; then
		fail "require_nonempty accepted an empty value"
	fi
	assert_equal "ERROR: suite must be configured." "$output"
}

test_log_info
test_require_readable_file
test_require_nonempty
printf 'Common framework tests passed.\n'
