# shellcheck shell=sh disable=SC2034
# Device and kernel capability detection.
#
# Everything here is read-only. The device pack decides the default profile,
# so the same module lands on aggressive for a ColorOS phone and on balanced
# for anything else, without asking the user to pick a level first.

DEVICE_CODENAME=
DEVICE_MODEL=
DEVICE_LABEL=
DEVICE_PACK=generic
DEVICE_PROFILE=balanced

# Property names a device reports its codename under, most specific first.
# A rebranded twin shares the codename (the OnePlus 13R is a giulia), so the
# codename, not the model, is what selects a pack.
DEVICE_PROPS="ro.product.device ro.product.vendor.device ro.product.odm.device ro.product.product.device"

detect_device() {
    DEVICE_CODENAME=
    for name in $DEVICE_PROPS; do
        value=$(prop_get "$name")
        if [ -n "$value" ]; then
            DEVICE_CODENAME=$value
            break
        fi
    done
    DEVICE_MODEL=$(prop_get ro.product.model)

    DEVICE_PACK=generic
    DEVICE_PROFILE=balanced
    DEVICE_LABEL=${DEVICE_CODENAME:-unknown}
    case "$DEVICE_CODENAME" in
        giulia|giuliac)
            # ColorOS runs its own security centre and keeps state under
            # /data/oplus, so this device starts at the strongest level.
            DEVICE_PACK=oneplus-ace5
            DEVICE_PROFILE=aggressive
            DEVICE_LABEL="OnePlus Ace 5"
            ;;
        *)
            case "$DEVICE_MODEL" in
                PKG110|CPH2645)
                    DEVICE_PACK=oneplus-ace5
                    DEVICE_PROFILE=aggressive
                    DEVICE_LABEL="OnePlus Ace 5"
                    ;;
            esac
            ;;
    esac
}

SUSFS_AVAILABLE=0
SUSFS_VERSION=unknown
SUSFS_VARIANT=unknown
SUSFS_IMPLEMENTATION=unknown
SUSFS_FEATURES=

detect_susfs() {
    SUSFS_AVAILABLE=0
    SUSFS_VERSION=unknown
    SUSFS_VARIANT=unknown
    SUSFS_IMPLEMENTATION=unknown
    SUSFS_FEATURES=
    if [ "$("$KSUD" susfs status 2>/dev/null)" != "true" ]; then
        return 0
    fi
    SUSFS_AVAILABLE=1
    SUSFS_VERSION=$("$KSUD" susfs version 2>/dev/null | head -n 1)
    SUSFS_VARIANT=$("$KSUD" susfs variant 2>/dev/null | head -n 1)
    SUSFS_IMPLEMENTATION=$("$KSUD" susfs implementation 2>/dev/null | head -n 1)
    SUSFS_FEATURES=$("$KSUD" susfs features 2>/dev/null | head -n 1)
    [ -n "$SUSFS_VERSION" ] || SUSFS_VERSION=unknown
    [ -n "$SUSFS_VARIANT" ] || SUSFS_VARIANT=unknown
    [ -n "$SUSFS_IMPLEMENTATION" ] || SUSFS_IMPLEMENTATION=unknown
}

# The kernel reports its SUSFS features as one comma-separated line.
susfs_has_feature() {
    [ -n "$SUSFS_FEATURES" ] || return 1
    printf '%s\n' "$SUSFS_FEATURES" | tr ',' '\n' | grep -qix "$1"
}

# Whether this ksud build carries the built-in hide packs at all. A manager
# older than the feature answers with a clap usage error, which is what the
# installer turns into an upgrade message.
ksud_hide_supported() {
    "$KSUD" hide status >/dev/null 2>&1
}

KERNEL_VERSION=unknown
KERNEL_UAPI=unknown

detect_kernel() {
    KERNEL_VERSION=${KSU_VER:-}
    KERNEL_UAPI=${KSU_UAPI_VER:-}
    # A module script gets both from ksud's environment; a root shell started by
    # the WebUI gets neither, and `ksud --version` prints them on one line.
    if [ -z "$KERNEL_VERSION" ]; then
        KERNEL_VERSION=$("$KSUD" --version 2>/dev/null | head -n 1)
        [ -n "$KERNEL_VERSION" ] || KERNEL_VERSION=unknown
    fi
    [ -n "$KERNEL_UAPI" ] || KERNEL_UAPI=unknown
}

ZYGISK_STATE=unknown

detect_zygisk() {
    ZYGISK_STATE=none
    info=$("$KSUD" zygisk info 2>/dev/null | head -n 1)
    if [ -n "$info" ]; then
        state=$(printf '%s' "$info" | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')
        [ -n "$state" ] && ZYGISK_STATE=$state
    fi
}

detect_all() {
    detect_device
    detect_kernel
    detect_susfs
    detect_zygisk
}
