#!/usr/bin/env bash

# Shared, side-effect-free helpers for repository scripts. This library does
# not change shell options because doing so would alter the behavior of callers.

common.log_info() {
	printf '\033[32mINFO:\033[0m %s\n' "$*"
}

common.log_warn() {
	printf 'WARN: %s\n' "$*" >&2
}

common.log_success() {
	printf '\033[32mSUCCESS:\033[0m %s\n' "$*"
}

common.log_section() {
	printf '\n\033[1m==> %s\033[0m\n' "$*"
}

common.log_summary_item() {
	local label=$1
	local value=$2

	printf '  %-24s %s\n' "$label:" "$value"
}

common.die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

common.require_root() {
	((EUID == 0)) || common.die "Must be run as root."
}

common.require_readable_file() {
	local path=$1
	local description=${2:-File}

	[[ -r $path ]] || common.die "$description not found or not readable: $path"
}

common.require_commands() {
	local command_name

	for command_name in "$@"; do
		command -v "$command_name" >/dev/null 2>&1 ||
			common.die "Required command not found: $command_name"
	done
}

common.require_nonempty() {
	local name=$1
	local value=${2:-}

	[[ -n $value ]] || common.die "$name must be configured."
}
