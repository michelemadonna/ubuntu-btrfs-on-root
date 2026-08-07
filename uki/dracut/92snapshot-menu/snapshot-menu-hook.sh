#!/bin/sh

/usr/libexec/snapshot-menu || {
    warn "snapshot-menu: menu helper failed; continuing normal boot"
}


return 0