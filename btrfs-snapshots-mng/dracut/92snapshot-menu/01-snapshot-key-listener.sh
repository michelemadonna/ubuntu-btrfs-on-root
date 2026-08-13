#!/bin/sh

command -v getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

LISTENER="/usr/libexec/snapshot-key-listener"
PIDFILE="/run/snapshot-key-listener.pid"
MARKER="/run/snapshot-menu-requested"

#
# Dracut hooks are sourced.
# Never use exit here.
#

[ -e "$MARKER" ] && return 0
[ -s "$PIDFILE" ] && return 0
[ -x "$LISTENER" ] || return 0

"$LISTENER" \
    </dev/null \
    >/dev/null \
    2>&1 &

unset LISTENER
unset PIDFILE
unset MARKER

return 0