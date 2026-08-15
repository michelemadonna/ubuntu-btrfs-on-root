#!/usr/bin/env bash

# Shared, side-effect-free helpers for repository scripts. This library does
# not change shell options because doing so would alter the behavior of callers.

common_library_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the static source relative to this library while retaining the
# runtime-derived absolute path for callers launched from any directory.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=log.sh
# shellcheck disable=SC1091
source "$common_library_dir/log.sh"
unset common_library_dir

common.require_root() {
	((EUID == 0)) || log.die "Must be run as root."
}

common.require_readable_file() {
	local path=$1
	local description=${2:-File}

	[[ -r $path ]] || log.die "$description not found or not readable: $path"
}

common.require_commands() {
	local command_name

	for command_name in "$@"; do
		command -v "$command_name" >/dev/null 2>&1 ||
			log.die "Required command not found: $command_name"
	done
}

common.require_nonempty() {
	local name=$1
	local value=${2:-}

	[[ -n $value ]] || log.die "$name must be configured."
}
