#!/system/bin/sh
# shellcheck disable=SC1090,SC1091
# Runs after sys.boot_completed=1.
#
# One more pass, now that every module has mounted and the system is settled:
# this is the state the report and the module description should describe, and
# the state a user sees when they open the manager after a reboot.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$MODDIR/common/module.sh"

log_init
log_info "boot-completed: start"

apply_all ""

log_info "boot-completed: done"
exit 0
