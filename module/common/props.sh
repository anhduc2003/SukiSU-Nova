# shellcheck shell=sh disable=SC2034
# System properties.
#
# Two different operations, and the difference matters:
#
#   expect  the value is part of the hiding surface, so it is forced to the
#           locked/stock value even when the real one says otherwise
#           (verified boot state, warranty bit, debuggable).
#   fill    the value is device-specific and only written when it is missing,
#           because inventing a wrong value is worse than leaving the real one
#           (vbmeta size and digest are never touched at all).
#
# Nothing here spoofs a device identity: the fingerprint, model and product
# properties belong to PlayIntegrityFix, and writing them from two places is
# how a device ends up with a fingerprint that contradicts its own build.

PROPS_FIXED=0
PROPS_OK=0
PROPS_FAILED=0

props_reset() {
    PROPS_FIXED=0
    PROPS_OK=0
    PROPS_FAILED=0
}

# Read a property. getprop is the normal path; resetprop is the fallback for a
# recovery or a stripped environment where getprop is not on PATH.
prop_get() {
    if command -v getprop >/dev/null 2>&1; then
        getprop "$1" 2>/dev/null
    else
        "$KSUD" resetprop "$1" 2>/dev/null
    fi
}

# Write a property through the kernel property area. -n skips property_service,
# which is what makes an ro.* property writable after boot at all.
prop_set() {
    "$KSUD" resetprop -n "$1" "$2" >/dev/null 2>&1
}

prop_delete() {
    "$KSUD" resetprop -d "$1" >/dev/null 2>&1
}

apply_prop_expect() {
    current=$(prop_get "$1")
    if [ "$current" = "$2" ]; then
        PROPS_OK=$((PROPS_OK + 1))
        return 0
    fi
    if prop_set "$1" "$2"; then
        PROPS_FIXED=$((PROPS_FIXED + 1))
        log_info "prop $1: '$current' -> '$2'"
    else
        PROPS_FAILED=$((PROPS_FAILED + 1))
        log_warn "prop $1: could not set '$2' (still '$current')"
    fi
}

apply_prop_fill() {
    current=$(prop_get "$1")
    if [ -n "$current" ]; then
        PROPS_OK=$((PROPS_OK + 1))
        return 0
    fi
    if prop_set "$1" "$2"; then
        PROPS_FIXED=$((PROPS_FIXED + 1))
        log_info "prop $1: filled in '$2'"
    else
        PROPS_FAILED=$((PROPS_FAILED + 1))
        log_warn "prop $1: could not fill in '$2'"
    fi
}

apply_prop_delete() {
    current=$(prop_get "$1")
    if [ -z "$current" ]; then
        PROPS_OK=$((PROPS_OK + 1))
        return 0
    fi
    if prop_delete "$1"; then
        PROPS_FIXED=$((PROPS_FIXED + 1))
        log_info "prop $1: deleted ('$current')"
    else
        PROPS_FAILED=$((PROPS_FAILED + 1))
        log_warn "prop $1: could not delete '$current'"
    fi
}

# The bootloader surface. Every detector that asks "is this device modified"
# starts here: an unlocked device reports orange/unlocked/0 for these, a stock
# locked one reports green/locked/1.
apply_props() {
    props_reset

    while read -r name value; do
        [ -n "$name" ] || continue
        apply_prop_expect "$name" "$value"
    done <<'PROPS'
ro.boot.verifiedbootstate green
ro.boot.vbmeta.device_state locked
ro.boot.flash.locked 1
ro.boot.veritymode enforcing
ro.boot.warranty_bit 0
ro.warranty_bit 0
ro.vendor.boot.warranty_bit 0
ro.vendor.warranty_bit 0
vendor.boot.verifiedbootstate green
vendor.boot.vbmeta.device_state locked
ro.secureboot.lockstate locked
ro.debuggable 0
ro.force.debuggable 0
ro.secure 1
ro.adb.secure 1
ro.build.type user
ro.build.tags release-keys
ro.crypto.state encrypted
sys.oem_unlock_allowed 0
PROPS

    # Values whose real content is device-specific: only fill a gap.
    while read -r name value; do
        [ -n "$name" ] || continue
        apply_prop_fill "$name" "$value"
    done <<'FILL'
ro.boot.vbmeta.invalidate_on_error yes
ro.boot.vbmeta.avb_version 1.2
ro.boot.vbmeta.hash_alg sha256
FILL

    # An emulator marker on a phone is a contradiction no detector accepts.
    for name in ro.kernel.qemu ro.boot.qemu ro.boot.qemu.avd_name; do
        apply_prop_delete "$name"
    done

    log_info "props: $PROPS_FIXED fixed, $PROPS_OK already correct, $PROPS_FAILED failed"
}

# Read-only check used by the status report: how many of the forced properties
# already carry the expected value, and what verified boot currently says.
props_audit() {
    PROPS_FIXED=0
    PROPS_OK=0
    PROPS_FAILED=0
    while read -r name value; do
        [ -n "$name" ] || continue
        if [ "$(prop_get "$name")" = "$value" ]; then
            PROPS_OK=$((PROPS_OK + 1))
        else
            PROPS_FAILED=$((PROPS_FAILED + 1))
        fi
    done <<'AUDIT'
ro.boot.verifiedbootstate green
ro.boot.vbmeta.device_state locked
ro.boot.flash.locked 1
ro.boot.warranty_bit 0
ro.debuggable 0
ro.build.type user
ro.build.tags release-keys
AUDIT
    PROPS_VERIFIEDBOOT=$(prop_get ro.boot.verifiedbootstate)
}
