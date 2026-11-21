#!/system/bin/sh
# shellcheck disable=SC1090,SC1091
# Runs before zygote starts.
#
# The properties and kernel features set here are what a freshly started app
# process sees, so they cannot wait for service.sh: a detector launched at boot
# would already have read the unlocked values by then. The SuSFS packs are
# applied here too, for the same reason.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$MODDIR/common/module.sh"

log_init
cfg_load
detect_all
log_info "post-fs-data: start ($(module_version), $DEVICE_LABEL)"

apply_early
apply_hide ""

log_info "post-fs-data: done"
exit 0
