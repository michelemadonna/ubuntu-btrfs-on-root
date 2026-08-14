#!/usr/bin/env bash

# Shared logging primitives. This library deliberately does not change shell
# options, traps or umask because those settings belong to the caller.

log.info() {
	printf '\033[32mINFO:\033[0m %s\n' "$*"
}

log.warn() {
	printf '\033[33mWARN:\033[0m %s\n' "$*" >&2
}

log.error() {
	printf '\033[31mERROR:\033[0m %s\n' "$*" >&2
}

log.success() {
	printf '\033[32mSUCCESS:\033[0m %s\n' "$*"
}

log.section() {
	printf '\n\033[1m==> %s\033[0m\n' "$*"
}

log.summary_item() {
	local label=$1
	local value=$2

	printf '  %-24s %s\n' "$label:" "$value"
}

log.die() {
	log.error "$*"
	exit 1
}
