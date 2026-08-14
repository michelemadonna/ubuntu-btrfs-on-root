#!/bin/bash

set -u

CONFIG="/etc/snapshot-menu.conf"

#
# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
#

if [[ ! -r "$CONFIG" ]]; then
	exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

#
# Required configuration.
#
: "${ROOT_SUBVOL:?ROOT_SUBVOL is not configured}"
: "${SNAPSHOT_DIR:?SNAPSHOT_DIR is not configured}"
: "${TTY:?TTY is not configured}"
: "${MOUNTPOINT:?MOUNTPOINT is not configured}"
: "${RESULT:?RESULT is not configured}"
: "${CMDLINE_DIR:?CMDLINE_DIR is not configured}"
: "${SNAPSHOT_CMDLINE:?SNAPSHOT_CMDLINE is not configured}"

#
# Optional pagination configuration.
#
PAGE_SIZE="${PAGE_SIZE:-20}"

if [[ ! "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
	PAGE_SIZE=20
fi

#
# Optional description length configuration.
#
DESCRIPTION_MAX_LENGTH="${DESCRIPTION_MAX_LENGTH:-24}"

if [[ ! "$DESCRIPTION_MAX_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
	DESCRIPTION_MAX_LENGTH=24
fi

if ((DESCRIPTION_MAX_LENGTH > 40)); then
	DESCRIPTION_MAX_LENGTH=40
fi

#
# Optional snapshot PIN configuration.
#
SNAPSHOT_PIN_ENABLED="${SNAPSHOT_PIN_ENABLED:-no}"
SNAPSHOT_PIN_ATTEMPTS="${SNAPSHOT_PIN_ATTEMPTS:-3}"
SNAPSHOT_PIN_MAX_LENGTH="${SNAPSHOT_PIN_MAX_LENGTH:-12}"
SNAPSHOT_PIN_SALT="${SNAPSHOT_PIN_SALT:-}"
SNAPSHOT_PIN_HASH="${SNAPSHOT_PIN_HASH:-}"

case "${SNAPSHOT_PIN_ENABLED,,}" in

yes | true | 1)
	SNAPSHOT_PIN_ENABLED="yes"
	;;

*)
	SNAPSHOT_PIN_ENABLED="no"
	;;

esac

if [[ ! "$SNAPSHOT_PIN_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
	SNAPSHOT_PIN_ATTEMPTS=3
fi

if [[ ! "$SNAPSHOT_PIN_MAX_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
	SNAPSHOT_PIN_MAX_LENGTH=12
fi

#
# Avoid unreasonable values inside the initramfs.
#
if ((SNAPSHOT_PIN_ATTEMPTS > 10)); then
	SNAPSHOT_PIN_ATTEMPTS=10
fi

if ((SNAPSHOT_PIN_MAX_LENGTH > 64)); then
	SNAPSHOT_PIN_MAX_LENGTH=64
fi

SNAPSHOT_PIN_READY="no"

if [[ "$SNAPSHOT_PIN_ENABLED" == "yes" ]]; then

	if [[ -n "$SNAPSHOT_PIN_SALT" &&
		"$SNAPSHOT_PIN_HASH" =~ ^[[:xdigit:]]{64}$ ]]; then

		SNAPSHOT_PIN_HASH="${SNAPSHOT_PIN_HASH,,}"
		SNAPSHOT_PIN_READY="yes"

	fi

fi

#
# ------------------------------------------------------------
# Root device
# ------------------------------------------------------------
#

ROOT_DEV="${1:-}"

if [[ -z "$ROOT_DEV" || ! -b "$ROOT_DEV" ]]; then
	exit 1
fi

#
# TTY fallback.
#
if [[ ! -c "$TTY" ]]; then
	TTY="/dev/console"
fi

mkdir -p "$MOUNTPOINT"

#
# One file descriptor for keyboard and display.
#
exec 3<>"$TTY"

mounted=0
terminal_configured=0

CURRENT_KERNEL="$(uname -r)"

#
# Results produced by keyboard functions.
#
KEY_RESULT=""
PIN_RESULT=""

#
# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
#

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
snapshot-menu.cleanup() {

	if ((terminal_configured)); then

		printf '\033[0m\033[?25h' >&3 2>/dev/null || true
		stty sane <&3 2>/dev/null || true

	fi

	if ((mounted)); then

		umount "$MOUNTPOINT" \
			>/dev/null 2>&1 || true

	fi

	exec 3>&- 2>/dev/null || true
}

#
# ------------------------------------------------------------
# Safe cancellation
# ------------------------------------------------------------
#

# Invoked indirectly by the INT and QUIT traps.
# shellcheck disable=SC2329
snapshot-menu.boot_current_system() {

	#
	# Ctrl-C and Ctrl-\ cancel snapshot selection and explicitly
	# select the normal root.
	#
	printf '%s\n' \
		"$ROOT_SUBVOL" \
		>"${RESULT}.tmp"

	mv \
		"${RESULT}.tmp" \
		"$RESULT"

	#
	# Never leave snapshot overlay enabled after cancellation.
	#
	rm -f "$SNAPSHOT_CMDLINE"

	printf '\n\033[0mSnapshot selection cancelled.\n' >&3
	printf 'Booting current system...\n' >&3

	exit 0
}

#
# Ctrl-C.
#
trap snapshot-menu.boot_current_system INT

#
# Ctrl-\.
#
trap snapshot-menu.boot_current_system QUIT

#
# Do not allow Ctrl-Z to suspend the menu in the initramfs.
#
trap '' TSTP

#
# External termination must remain an actual failure.
#
trap 'exit 129' HUP
trap 'exit 143' TERM

trap snapshot-menu.cleanup EXIT

#
# ------------------------------------------------------------
# Mount Btrfs top-level
# ------------------------------------------------------------
#

if ! mount \
	-t btrfs \
	-o ro,subvolid=5 \
	"$ROOT_DEV" \
	"$MOUNTPOINT"; then

	printf '\nUnable to mount Btrfs root: %s\n' \
		"$ROOT_DEV" >&3

	sleep 2
	exit 1
fi

mounted=1

SNAPDIR="${MOUNTPOINT}/${ROOT_SUBVOL}/${SNAPSHOT_DIR}"

#
# ------------------------------------------------------------
# Menu entries
# ------------------------------------------------------------
#

declare -a SUBVOLS
declare -a SNAPSHOT_PATHS
declare -a SNAPSHOT_INFOS
declare -a SNAPSHOT_NUMBERS
declare -a LABELS
declare -a KERNEL_STATUS
declare -a ENTRY_LOADED

SUBVOLS=()
SNAPSHOT_PATHS=()
SNAPSHOT_INFOS=()
SNAPSHOT_NUMBERS=()
LABELS=()
KERNEL_STATUS=()
ENTRY_LOADED=()

#
# Entry 0 = current system.
#
SUBVOLS+=(
	"$ROOT_SUBVOL"
)

SNAPSHOT_PATHS+=("")
SNAPSHOT_INFOS+=("")
SNAPSHOT_NUMBERS+=("")

LABELS+=(
	"Ubuntu - current system"
)

KERNEL_STATUS+=(
	"Present"
)

ENTRY_LOADED+=(
	"1"
)

#
# ------------------------------------------------------------
# Enumerate Snapper snapshots
# ------------------------------------------------------------
#
# Only numbers and paths are collected here.
# Metadata and kernel status are loaded when a page is displayed.
#

if [[ -d "$SNAPDIR" ]]; then

	while IFS= read -r snap; do

		[[ -n "$snap" ]] || continue
		[[ "$snap" =~ ^[0-9]+$ ]] || continue

		snapshot="${SNAPDIR}/${snap}/snapshot"
		info="${SNAPDIR}/${snap}/info.xml"

		[[ -d "$snapshot" ]] || continue

		SUBVOLS+=(
			"${ROOT_SUBVOL}/${SNAPSHOT_DIR}/${snap}/snapshot"
		)

		SNAPSHOT_PATHS+=(
			"$snapshot"
		)

		SNAPSHOT_INFOS+=(
			"$info"
		)

		SNAPSHOT_NUMBERS+=(
			"$snap"
		)

		LABELS+=("")
		KERNEL_STATUS+=("")
		ENTRY_LOADED+=("0")

	done < <(

		for path in "$SNAPDIR"/*; do

			[[ -d "$path" ]] || continue

			snap="${path##*/}"

			[[ "$snap" =~ ^[0-9]+$ ]] || continue

			printf '%s\n' "$snap"

		done |
			sort -rn

	)

fi

COUNT=${#SUBVOLS[@]}
PAGE_COUNT=$(((COUNT + PAGE_SIZE - 1) / PAGE_SIZE))

#
# ------------------------------------------------------------
# Lazy entry loading
# ------------------------------------------------------------
#

snapshot-menu.load_entry() {

	local index="$1"
	local snapshot
	local info
	local snap
	local description=""
	local date=""
	local type=""

	if [[ "${ENTRY_LOADED[$index]}" == "1" ]]; then
		return 0
	fi

	snapshot="${SNAPSHOT_PATHS[$index]}"
	info="${SNAPSHOT_INFOS[$index]}"
	snap="${SNAPSHOT_NUMBERS[$index]}"

	#
	# Read Snapper metadata.
	#
	if [[ -r "$info" ]]; then

		description="$(
			sed -n \
				's:.*<description>\(.*\)</description>.*:\1:p' \
				"$info" |
				head -n 1
		)"

		date="$(
			sed -n \
				's:.*<date>\(.*\)</date>.*:\1:p' \
				"$info" |
				head -n 1
		)"

		type="$(
			sed -n \
				's:.*<type>\(.*\)</type>.*:\1:p' \
				"$info" |
				head -n 1
		)"

	fi

	[[ -n "$description" ]] ||
		description="Snapshot"

	#
	# Remove characters capable of breaking the terminal layout.
	#
	description="${description//$'\n'/ }"
	description="${description//$'\r'/ }"
	description="${description//$'\t'/ }"

	type="${type//$'\n'/ }"
	type="${type//$'\r'/ }"
	type="${type//$'\t'/ }"

	#
	# Truncate the description and append "..." when necessary.
	#
	if ((${#description} > DESCRIPTION_MAX_LENGTH)); then
		if ((DESCRIPTION_MAX_LENGTH > 3)); then
			description="${description:0:DESCRIPTION_MAX_LENGTH-3}..."
		else
			description="${description:0:DESCRIPTION_MAX_LENGTH}"
		fi
	fi

	#
	# Build a fixed-width label:
	#
	#   snapshot  date                 description               type
	#   #9        2026-08-12 14:40:21  boot                      single
	#
	if [[ -n "$date" ]]; then

		printf -v 'LABELS[index]' \
			'#%-5.5s  %-19.19s  %-*s  %-8.8s' \
			"$snap" \
			"$date" \
			"$DESCRIPTION_MAX_LENGTH" \
			"$description" \
			"$type"

	else

		printf -v 'LABELS[index]' \
			'#%-5.5s  %-19s  %-*s  %-8.8s' \
			"$snap" \
			"-" \
			"$DESCRIPTION_MAX_LENGTH" \
			"$description" \
			"$type"

	fi

	#
	# The UKI contains the running kernel. The selected snapshot
	# must contain the matching modules.
	#
	if [[ -d "${snapshot}/usr/lib/modules/${CURRENT_KERNEL}" ]]; then

		KERNEL_STATUS[index]="Present"

	else

		KERNEL_STATUS[index]="Missing"

	fi

	ENTRY_LOADED[index]="1"
}

#
# ------------------------------------------------------------
# Configure terminal
# ------------------------------------------------------------
#

stty \
	-echo \
	-icanon \
	-ixon \
	-ixoff \
	min 1 \
	time 0 \
	<&3

terminal_configured=1

#
# Hide cursor.
#
printf '\033[?25l' >&3

selected=0

#
# ------------------------------------------------------------
# Draw menu
# ------------------------------------------------------------
#

snapshot-menu.draw_menu() {

	local i
	local page
	local first
	local last
	local label_width

	label_width=$((5 + 4 + 19 + 2 + DESCRIPTION_MAX_LENGTH + 2 + 8))

	page=$((selected / PAGE_SIZE))
	first=$((page * PAGE_SIZE))
	last=$((first + PAGE_SIZE))

	if ((last > COUNT)); then
		last=$COUNT
	fi

	printf '\033[2J\033[H' >&3

	printf '\033[1;36m' >&3
	printf 'Ubuntu Snapshot Boot\n' >&3
	printf '\033[0m' >&3

	printf 'Kernel: %s\n' \
		"$CURRENT_KERNEL" >&3

	if [[ "$SNAPSHOT_PIN_ENABLED" == "yes" ]]; then

		if [[ "$SNAPSHOT_PIN_READY" == "yes" ]]; then
			printf 'Snapshot PIN: enabled\n' >&3
		else
			printf '\033[1;31mSnapshot PIN: configuration error\033[0m\n' >&3
		fi

	fi

	printf '\n' >&3

	printf 'Select root filesystem:  Page %d/%d  Entries %d-%d of %d\n\n' \
		"$((page + 1))" \
		"$PAGE_COUNT" \
		"$((first + 1))" \
		"$last" \
		"$COUNT" >&3

	printf '   %-7s  %-19s  %-*s  %-8s  %-10s\n' \
		'Snapshot' \
		'Date' \
		"$DESCRIPTION_MAX_LENGTH" \
		'Description' \
		'Type' \
		'Kernel' >&3

	printf '   %-7s  %-19s  %-*s  %-8s  %-10s\n' \
		'--------' \
		'-------------------' \
		"$DESCRIPTION_MAX_LENGTH" \
		'-----------' \
		'--------' \
		'------' >&3

	for ((i = first; i < last; i++)); do

		snapshot-menu.load_entry "$i"

		if ((i == selected)); then

			printf '\033[7m' >&3

			printf ' > %-*.*s  %-10.10s' \
				"$label_width" \
				"$label_width" \
				"${LABELS[$i]}" \
				"${KERNEL_STATUS[$i]}" >&3

			printf '\033[0m\n' >&3

		else

			printf '   %-*.*s  %-10.10s\n' \
				"$label_width" \
				"$label_width" \
				"${LABELS[$i]}" \
				"${KERNEL_STATUS[$i]}" >&3

		fi

	done

	printf '\n' >&3

	printf '\033[2m' >&3
	printf 'Up/Down: select    Left/Right: page    Enter: boot\n' >&3
	printf 'j/k: select        h/l: page          Ctrl-C: current system\n' >&3
	printf '\033[0m' >&3
}

#
# ------------------------------------------------------------
# Keyboard input
# ------------------------------------------------------------
#

snapshot-menu.read_key() {

	local key=""
	local seq=""

	KEY_RESULT="OTHER"

	IFS= read \
		-r \
		-s \
		-n 1 \
		-u 3 \
		key || return 1

	case "$key" in

	$'\e')

		seq=""

		IFS= read \
			-r \
			-s \
			-n 2 \
			-t 0.15 \
			-u 3 \
			seq || true

		case "$seq" in

		'[A')
			KEY_RESULT="UP"
			;;

		'[B')
			KEY_RESULT="DOWN"
			;;

		'[C')
			KEY_RESULT="RIGHT"
			;;

		'[D')
			KEY_RESULT="LEFT"
			;;

		*)
			KEY_RESULT="ESC"
			;;

		esac
		;;

	"")

		KEY_RESULT="ENTER"
		;;

	j | J)

		KEY_RESULT="DOWN"
		;;

	k | K)

		KEY_RESULT="UP"
		;;

	h | H)

		KEY_RESULT="LEFT"
		;;

	l | L)

		KEY_RESULT="RIGHT"
		;;

	$'\f')

		#
		# Ctrl-L.
		#
		KEY_RESULT="REDRAW"
		;;

	*)

		KEY_RESULT="OTHER"
		;;

	esac

	return 0
}

#
# ------------------------------------------------------------
# PIN input
# ------------------------------------------------------------
#

snapshot-menu.read_pin() {

	local pin=""
	local char=""
	local i

	PIN_RESULT=""

	while true; do

		char=""

		IFS= read \
			-r \
			-s \
			-n 1 \
			-u 3 \
			char || return 1

		case "$char" in

		"")

			PIN_RESULT="$pin"
			return 0
			;;

		$'\e' | $'\004')

			#
			# Esc or Ctrl-D cancels PIN entry.
			#
			PIN_RESULT=""
			return 1
			;;

		$'\177' | $'\b')

			#
			# Backspace.
			#
			if [[ -n "$pin" ]]; then

				pin="${pin%?}"
				printf '\b \b' >&3

			fi
			;;

		$'\025')

			#
			# Ctrl-U: clear the entire PIN.
			#
			for ((i = 0; i < ${#pin}; i++)); do
				printf '\b \b' >&3
			done

			pin=""
			;;

		[0-9])

			if ((${#pin} < SNAPSHOT_PIN_MAX_LENGTH)); then

				pin+="$char"
				printf '*' >&3

			fi
			;;

		esac

	done
}

#
# ------------------------------------------------------------
# PIN verification
# ------------------------------------------------------------
#

snapshot-menu.check_snapshot_pin() {

	local attempt
	local calculated_hash

	if [[ "$SNAPSHOT_PIN_ENABLED" != "yes" ]]; then
		return 0
	fi

	#
	# Fail closed for snapshots, but keep the current-system
	# entry available.
	#
	if [[ "$SNAPSHOT_PIN_READY" != "yes" ]]; then

		printf '\033[2J\033[H' >&3
		printf '\033[1;31mSnapshot PIN configuration error.\033[0m\n\n' >&3
		printf 'Snapshot boot is disabled.\n' >&3
		printf 'Press any key to return to the menu.' >&3

		snapshot-menu.read_key || true
		return 1

	fi

	for ((attempt = 1; attempt <= SNAPSHOT_PIN_ATTEMPTS; attempt++)); do

		printf '\033[2J\033[H' >&3

		printf '\033[1;36m' >&3
		printf 'Ubuntu Snapshot Boot\n' >&3
		printf '\033[0m' >&3

		printf '\nSnapshot: %s\n' \
			"${LABELS[$selected]}" >&3

		printf 'Enter PIN (%d/%d): ' \
			"$attempt" \
			"$SNAPSHOT_PIN_ATTEMPTS" >&3

		if ! snapshot-menu.read_pin; then

			printf '\nPIN entry cancelled.\n' >&3
			sleep 0.5
			return 1

		fi

		printf '\n' >&3

		calculated_hash="$(
			printf '%s' \
				"${SNAPSHOT_PIN_SALT}${PIN_RESULT}" |
				sha256sum
		)"

		calculated_hash="${calculated_hash%% *}"
		calculated_hash="${calculated_hash,,}"

		#
		# Remove the plaintext PIN as soon as possible.
		#
		PIN_RESULT=""

		if [[ "$calculated_hash" == "$SNAPSHOT_PIN_HASH" ]]; then

			printf '\033[1;32mPIN accepted.\033[0m\n' >&3
			sleep 0.4
			return 0

		fi

		printf '\033[1;31mInvalid PIN.\033[0m\n' >&3

		if ((attempt < SNAPSHOT_PIN_ATTEMPTS)); then
			sleep 1
		fi

	done

	printf '\nSnapshot boot cancelled.\n' >&3
	sleep 1.5

	return 1
}

#
# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
#

snapshot-menu.draw_menu

while true; do

	if ! snapshot-menu.read_key; then
		continue
	fi

	case "$KEY_RESULT" in

	UP)

		if ((selected > 0)); then
			((selected--))
		else
			selected=$((COUNT - 1))
		fi

		snapshot-menu.draw_menu
		;;

	DOWN)

		if ((selected < COUNT - 1)); then
			((selected++))
		else
			selected=0
		fi

		snapshot-menu.draw_menu
		;;

	LEFT)

		current_page=$((selected / PAGE_SIZE))

		if ((current_page > 0)); then

			selected=$(((current_page - 1) * PAGE_SIZE))

		else

			selected=$(((PAGE_COUNT - 1) * PAGE_SIZE))

		fi

		snapshot-menu.draw_menu
		;;

	RIGHT)

		current_page=$((selected / PAGE_SIZE))

		if ((current_page < PAGE_COUNT - 1)); then

			selected=$(((current_page + 1) * PAGE_SIZE))

		else

			selected=0

		fi

		snapshot-menu.draw_menu
		;;

	REDRAW)

		snapshot-menu.draw_menu
		;;

	ENTER)

		#
		# Entry 0 is the current system and never requires
		# snapshot PIN authentication.
		#
		if ((selected != 0)); then

			snapshot-menu.load_entry "$selected"

			if [[ ${KERNEL_STATUS[selected]} != "Present" ]]; then
				printf '\nCannot boot snapshot %s: kernel modules for %s are missing.\n' \
					"${LABELS[$selected]}" \
					"$CURRENT_KERNEL" >&3
				printf 'Select another entry.\n' >&3
				sleep 2
				snapshot-menu.draw_menu
				continue
			fi

			if ! snapshot-menu.check_snapshot_pin; then
				snapshot-menu.draw_menu
				continue
			fi

		fi

		break
		;;

	esac

done

#
# ------------------------------------------------------------
# Selected entry
# ------------------------------------------------------------
#

snapshot-menu.load_entry "$selected"

SELECTED_SUBVOL="${SUBVOLS[$selected]}"
SELECTED_LABEL="${LABELS[$selected]}"

#
# Save selection for snapshot-menu-hook.sh.
#
printf '%s\n' \
	"$SELECTED_SUBVOL" \
	>"${RESULT}.tmp"

mv \
	"${RESULT}.tmp" \
	"$RESULT"

#
# ------------------------------------------------------------
# Dynamic Dracut command line
# ------------------------------------------------------------
#

if [[ "$SELECTED_SUBVOL" != "$ROOT_SUBVOL" ]]; then

	mkdir -p "$CMDLINE_DIR"

	printf '%s\n' \
		'rd.overlay=1' \
		>"$SNAPSHOT_CMDLINE"

else

	rm -f "$SNAPSHOT_CMDLINE"

fi

#
# ------------------------------------------------------------
# Restore terminal
# ------------------------------------------------------------
#

printf '\033[0m\033[?25h' >&3
stty sane <&3

terminal_configured=0

printf '\nBooting: %s\n' \
	"$SELECTED_LABEL" >&3

if [[ "$SELECTED_SUBVOL" != "$ROOT_SUBVOL" ]]; then

	printf 'Root:    %s\n' \
		"$SELECTED_SUBVOL" >&3

	printf 'Kernel:  %s\n' \
		"${KERNEL_STATUS[selected]}" >&3

	printf 'Overlay: tmpfs\n' >&3

fi

sleep 0.4

exit 0
