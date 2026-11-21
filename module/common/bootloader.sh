# shellcheck shell=sh disable=SC2034
# Bootloader unlock hiding.
#
# A detector does not need root to learn the bootloader is unlocked: the
# properties, the bootconfig and (on older kernels) /proc/cmdline all say so.
# One table drives all three, so they cannot disagree with each other, and a
# read-back reports what the device actually serves after the pass.
#
# Every value here is what a stock locked device reports. Nothing is
# invented for a key that is not in the table: a missing vbmeta digest stays
# missing rather than becoming a fake one that no stock device would show.

# name value — applied as properties and mirrored into the bootconfig under
# androidboot.<name> where the name has that prefix.
BOOTLOADER_TABLE='
ro.boot.verifiedbootstate green
ro.boot.vbmeta.device_state locked
ro.boot.flash.locked 1
ro.boot.veritymode enforcing
ro.boot.warranty_bit 0
ro.vendor.boot.warranty_bit 0
ro.warranty_bit 0
ro.vendor.warranty_bit 0
vendor.boot.verifiedbootstate green
vendor.boot.vbmeta.device_state locked
ro.secureboot.lockstate locked
ro.boot.vbmeta.invalidate_on_error yes
ro.boot.vbmeta.avb_version 1.2
ro.boot.vbmeta.hash_alg sha256
sys.oem_unlock_allowed 0
'

# The bootconfig spelling: androidboot.<key> = <value>.
bootconfig_key() {
    case "$1" in
        ro.boot.*) printf 'androidboot.%s' "${1#ro.boot.}" ;;
        ro.vendor.boot.*) printf 'androidboot.%s' "${1#ro.vendor.boot.}" ;;
        vendor.boot.*) printf 'androidboot.%s' "${1#vendor.boot.}" ;;
        *) return 1 ;;
    esac
}

# Read every vector back from the property area. Sets BOOT_* and BOOT_VERDICT.
bootloader_readback() {
    BOOT_STATE=$(prop_get ro.boot.verifiedbootstate)
    BOOT_LOCKED=$(prop_get ro.boot.flash.locked)
    BOOT_DEVICE=$(prop_get ro.boot.vbmeta.device_state)
    BOOT_VERITY=$(prop_get ro.boot.veritymode)
    BOOT_WARRANTY=$(prop_get ro.boot.warranty_bit)
    BOOT_LOCKSTATE=$(prop_get ro.secureboot.lockstate)
    BOOT_VERDICT=
    for pair in \
        "verifiedboot:$BOOT_STATE:green" \
        "flash.locked:$BOOT_LOCKED:1" \
        "vbmeta.device_state:$BOOT_DEVICE:locked" \
        "veritymode:$BOOT_VERITY:enforcing" \
        "warranty_bit:$BOOT_WARRANTY:0" \
        "lockstate:$BOOT_LOCKSTATE:locked"; do
        name=${pair%%:*}
        rest=${pair#*:}
        actual=${rest%:*}
        want=${rest##*:}
        [ "$actual" = "$want" ] && continue
        BOOT_VERDICT="${BOOT_VERDICT:+$BOOT_VERDICT; }$name=${actual:-unset}"
    done
}

bootloader_text() {
    bootloader_readback
    printf '  %-17s %s\n' "verifiedboot" "${BOOT_STATE:-unset} (want green)"
    printf '  %-17s %s\n' "flash.locked" "${BOOT_LOCKED:-unset} (want 1)"
    printf '  %-17s %s\n' "device_state" "${BOOT_DEVICE:-unset} (want locked)"
    printf '  %-17s %s\n' "veritymode" "${BOOT_VERITY:-unset} (want enforcing)"
    printf '  %-17s %s\n' "warranty_bit" "${BOOT_WARRANTY:-unset} (want 0)"
    printf '  %-17s %s\n' "lockstate" "${BOOT_LOCKSTATE:-unset} (want locked)"
    if [ -n "$BOOT_VERDICT" ]; then
        printf '  %-17s %s\n' "verdict" "still unlocked: $BOOT_VERDICT"
    else
        printf '  %-17s %s\n' "verdict" "every property reads a locked device"
    fi
}

bootloader_json() {
    bootloader_readback
    printf '{"verifiedboot":"%s","locked":"%s","deviceState":"%s","verity":"%s","warranty":"%s","lockstate":"%s","verdict":"%s"}' \
        "$(json_escape "${BOOT_STATE:-}")" "$(json_escape "${BOOT_LOCKED:-}")" \
        "$(json_escape "${BOOT_DEVICE:-}")" "$(json_escape "${BOOT_VERITY:-}")" \
        "$(json_escape "${BOOT_WARRANTY:-}")" "$(json_escape "${BOOT_LOCKSTATE:-}")" \
        "$(json_escape "${BOOT_VERDICT:-locked}")"
}
