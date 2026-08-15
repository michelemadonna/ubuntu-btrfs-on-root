#!/usr/bin/env bash

# Shared logging primitives. This library deliberately does not change shell
# options, traps or umask because those settings belong to the caller.

LOG_SECTION_ACTIVE=false
LOG_SECTION_TITLE=""
LOG_SECTION_COLOR=35
LOG_SECTION_INDEX=0

log.info() {
	printf '\033[1;36mℹ [INFO]\033[0m %s\n' "$*"
}

log.warn() {
	printf '\033[1;33m⚠ [WARN]\033[0m %s\n' "$*" >&2
}

log.error() {
	printf '\033[1;31m✖ [ERROR]\033[0m %s\n' "$*" >&2
}

log.success() {
	printf '\033[1;32m✔ [SUCCESS]\033[0m %s\n' "$*"
}

log.section() {
	local -a colors=(35 34 36 33 32)

	[[ $LOG_SECTION_ACTIVE == false ]] || log.section_end
	LOG_SECTION_COLOR=${colors[LOG_SECTION_INDEX % ${#colors[@]}]}
	LOG_SECTION_INDEX=$((LOG_SECTION_INDEX + 1))
	LOG_SECTION_TITLE=$*
	LOG_SECTION_ACTIVE=true
	printf '\n\033[1;%sm╔══▶ BEGIN: %s\033[0m\n' "$LOG_SECTION_COLOR" "$LOG_SECTION_TITLE"
}

log.section_end() {
	[[ $LOG_SECTION_ACTIVE == true ]] || return 0
	printf '\033[1;%sm╚══■ END:   %s\033[0m\n' "$LOG_SECTION_COLOR" "$LOG_SECTION_TITLE"
	LOG_SECTION_ACTIVE=false
	LOG_SECTION_TITLE=""
}

log.summary_item() {
	local label=$1
	local value=$2

	printf '  \033[1;36m• %-22s\033[0m %s\n' "$label:" "$value"
}

log.die() {
	local previous_status=$?
	local message=${1:-Fatal error}
	local command_error=${2:-}
	local status=${3:-$previous_status}

	[[ $status =~ ^[0-9]+$ ]] || status=1
	log.section_end

	log.error "$message"
	if ((status != 0)); then
		log.error "Command exit status: $status"
	fi
	if [[ -n $command_error ]]; then
		log.error "Command error: $command_error"
	fi

	((status != 0)) || status=1
	exit "$status"
}
