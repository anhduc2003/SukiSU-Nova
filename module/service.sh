#!/system/bin/sh
# shellcheck disable=SC1090,SC1091
# Runs once late_start services are up.
#
# This is the pass that can touch the rest: SuSFS maps and bootconfig spoofing
# need the system mounted, and the companion modules only have their data
# directories by now. Everything here is idempotent, so a second pass after
# boot (boot-completed.sh) is cheap.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$MODDIR/common/module.sh"

apply_all ""

exit 0
