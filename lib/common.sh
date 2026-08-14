#!/usr/bin/env bash

# Shared, side-effect-free helpers for repository scripts. This library does
# not change shell options because doing so would alter the behavior of callers.

log_info() {
	printf '\033[32mINFO:\033[0m %s\n' "$*"
}

log_warn() {
	printf 'WARN: %s\n' "$*" >&2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_root() {
	((EUID == 0)) || die "Must be run as root."
}

require_readable_file() {
	local path=$1
	local description=${2:-File}

	[[ -r $path ]] || die "$description not found or not readable: $path"
}

require_nonempty() {
	local name=$1
	local value=${2:-}

	[[ -n $value ]] || die "$name must be configured."
}
