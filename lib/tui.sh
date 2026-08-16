#!/usr/bin/env bash

# Small terminal UI helpers. Prompts and menus go to stderr so callers may
# safely collect the selected value from stdout.

TUI_INPUT_DEVICE="${TUI_INPUT_DEVICE:-/dev/tty}"

tui.input() {
	local prompt=$1
	local default=${2:-}
	local value

	printf '%s [default: %s]: ' "$prompt" "$default" >&2
	IFS= read -r value <"$TUI_INPUT_DEVICE"
	printf '%s\n' "${value:-$default}"
}

tui.password() {
	local prompt=$1
	local default=${2:-}
	local value='' character masked_default input_fd

	masked_default="$(printf '%*s' "${#default}" '' | tr ' ' '*')"
	printf '%s [default: %s]: ' "$prompt" "${masked_default:-none}" >&2
	exec {input_fd}<"$TUI_INPUT_DEVICE"
	while IFS= read -r -s -n 1 -u "$input_fd" character; do
		case $character in
		'')
			break
			;;
		$'\177' | $'\b')
			if [[ -n $value ]]; then
				value=${value%?}
				printf '\b \b' >&2
			fi
			;;
		*)
			value+=$character
			printf '*' >&2
			;;
		esac
	done
	exec {input_fd}<&-

	printf '\n' >&2
	printf '%s\n' "${value:-$default}"
}

tui.toggle() {
	local prompt=$1
	local default=$2
	local answer

	[[ $default == yes || $default == no ]] || return 1
	while true; do
		printf '%s [default: %s] (yes/no): ' "$prompt" "$default" >&2
		IFS= read -r answer <"$TUI_INPUT_DEVICE"
		answer=${answer:-$default}
		case $answer in
		y | Y | yes | Yes | YES)
			printf 'yes\n'
			return 0
			;;
		n | N | no | No | NO)
			printf 'no\n'
			return 0
			;;
		*) printf 'Please enter yes or no.\n' >&2 ;;
		esac
	done
}

tui.select_one() {
	local prompt=$1
	local default=$2
	shift 2
	local choice index item value label default_index=1
	local -a values=()

	printf '\n%s\n' "$prompt" >&2
	index=0
	for item in "$@"; do
		index=$((index + 1))
		value=${item%%|*}
		label=${item#*|}
		values+=("$value")
		[[ $value != "$default" ]] || default_index=$index
		printf '  %d) %s [%s]\n' "$index" "$label" "$value" >&2
	done
	((${#values[@]} > 0)) || return 1
	printf 'Selection [default: %d - %s]: ' "$default_index" "${values[default_index - 1]}" >&2
	IFS= read -r choice <"$TUI_INPUT_DEVICE"
	choice=${choice:-$default_index}
	[[ $choice =~ ^[0-9]+$ ]] || return 1
	((choice >= 1 && choice <= ${#values[@]})) || return 1
	printf '%s\n' "${values[choice - 1]}"
}

tui.select_many() {
	local prompt=$1
	shift
	local answer index item value label enabled defaults="" token
	local -a values=() selected=()

	printf '\n%s\n' "$prompt" >&2
	index=0
	for item in "$@"; do
		index=$((index + 1))
		value=${item%%|*}
		item=${item#*|}
		label=${item%%|*}
		enabled=${item##*|}
		values+=("$value")
		if [[ $enabled == yes ]]; then
			defaults+="${defaults:+,}$index"
		fi
		printf '  %d) %s [%s]%s\n' "$index" "$label" "$value" "$([[ $enabled == yes ]] && printf ' (default)')" >&2
	done
	printf 'Selections, comma separated [default: %s]: ' "${defaults:-none}" >&2
	IFS= read -r answer <"$TUI_INPUT_DEVICE"
	answer=${answer:-$defaults}
	[[ -n $answer ]] || return 0
	IFS=',' read -r -a selected <<<"$answer"
	for token in "${selected[@]}"; do
		token=${token//[[:space:]]/}
		[[ $token =~ ^[0-9]+$ ]] || return 1
		((token >= 1 && token <= ${#values[@]})) || return 1
		printf '%s\n' "${values[token - 1]}"
	done
}
