# shellcheck shell=sh disable=SC2034
# Kernel hiding features.
#
# SukiSU Nova has three kernel-side switches that matter for detection:
#
#   selinux_hide  sanitises /sys/fs/selinux reads for app UIDs
#   avc_spoof     fixes the SELinux context leaks in AVC denial logs
#   mount_hide    filters module mounts out of app and isolated /proc views
#
# A module can own a feature by writing `manage.<name>=true` into its module
# config; ksud then skips that feature during its own init and only lets the
# owning module change it. Owning them is the point: without an owner, a user
# toggling a switch in the manager can silently turn one back off.

FEATURES="selinux_hide avc_spoof mount_hide"
FEATURE_SUMMARY=

declare_features() {
    for feature in $FEATURES; do
        if ! KSU_MODULE="$NOVAHIDE_ID" "$KSUD" module config set "manage.$feature" true >/dev/null 2>&1; then
            log_warn "features: could not declare manage.$feature (ksud too old?)"
        fi
    done
}

enable_features() {
    FEATURE_SUMMARY=
    for feature in $FEATURES; do
        state=$("$KSUD" feature check "$feature" 2>/dev/null)
        case "$state" in
            unsupported)
                FEATURE_SUMMARY="${FEATURE_SUMMARY:+$FEATURE_SUMMARY }$feature=unsupported"
                log_warn "features: $feature is not supported by this kernel"
                continue
                ;;
        esac
        if "$KSUD" feature set "$feature" 1 >/dev/null 2>&1; then
            FEATURE_SUMMARY="${FEATURE_SUMMARY:+$FEATURE_SUMMARY }$feature=1"
        else
            FEATURE_SUMMARY="${FEATURE_SUMMARY:+$FEATURE_SUMMARY }$feature=failed"
            log_warn "features: could not enable $feature (state: ${state:-unknown})"
        fi
    done
    log_info "features:$FEATURE_SUMMARY"
}

# Read-only: current value of each managed feature, for the status report.
audit_features() {
    FEATURE_SUMMARY=
    for feature in $FEATURES; do
        value=$("$KSUD" feature get "$feature" 2>/dev/null | head -n 1)
        case "$value" in
            0|1) FEATURE_SUMMARY="${FEATURE_SUMMARY:+$FEATURE_SUMMARY }$feature=$value" ;;
            *) FEATURE_SUMMARY="${FEATURE_SUMMARY:+$FEATURE_SUMMARY }$feature=?" ;;
        esac
    done
}
