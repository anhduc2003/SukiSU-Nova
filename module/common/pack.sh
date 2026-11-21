# shellcheck shell=sh disable=SC2034
# The path pack NovaHide registers itself.
#
# A ksud build older than the fork's hide packs has no `hide` command, and a
# module that insists on it cannot install at all. SuSFS still exposes
# `susfs add-sus-path`, so this table is the same catalogue the fork's ksud
# ships, kept here as the fallback: the module registers the paths itself,
# one call each, and reports how many the kernel accepted.
#
# Keep the levels in step with userspace/ksud/src/hide/catalog.rs and
# device.rs; a path added there belongs here too. The ColorOS rows of the
# Ace 5 pack are added below only on the devices that pack names, the same
# way ksud selects it.

# The Ace 5 pack: ColorOS state under /data/oplus and /data/oppo, hidden from
# `balanced` up, on giulia/giuliac only.
PACK_TABLE_ACE5='
2 /data/oplus
2 /data/oppo
'

PACK_TABLE='
1 /data/adb/ksu
1 /data/adb/ksud
1 /data/adb/modules
1 /data/adb/modules_update
1 /data/adb/magisk
1 /debug_ramdisk
1 /sbin/.magisk
1 /system/bin/su
1 /system/xbin/su
1 /vendor/bin/su
1 /sbin/su
2 /data/adb/kpm
2 /data/adb/nyazygisk
2 /data/adb/lspd
2 /data/adb/zygisksu
2 /data/adb/riru
2 /data/adb/ap
2 /data/adb/apd
2 /data/adb/post-fs-data.d
2 /data/adb/service.d
2 /init.magisk.rc
2 /cache/magisk.log
2 /dev/.magisk.unblock
3 /data/adb
'

# light=1, balanced=2, aggressive=3. `auto` and an unknown profile take the
# device default, which is the strongest level on the pack devices.
pack_level() {
    case "$1" in
        light) printf '1' ;;
        balanced) printf '2' ;;
        aggressive) printf '3' ;;
        *) printf '3' ;;
    esac
}

# Resolve the profile the way apply_hide does: argument, then config, then
# the device default.
pack_resolve_profile() {
    argument=${1:-}
    [ "$argument" = auto ] && argument=
    requested=$argument
    if [ -z "$requested" ]; then
        case "$CFG_PROFILE" in
            auto|'') requested=${DEVICE_PROFILE:-aggressive} ;;
            *) requested=$CFG_PROFILE ;;
        esac
    fi
    [ -n "$requested" ] || requested=aggressive
    printf '%s' "$requested"
}

apply_own_pack() {
    profile=$(pack_resolve_profile "${1:-}")
    PROFILE_USED=$profile
    [ -n "${1:-}" ] && PROFILE_SOURCE=argument
    HIDE_APPLIED=0
    HIDE_SKIPPED=0
    HIDE_ENTRIES=0
    HIDE_SUMMARY=

    if [ "$profile" = off ]; then
        HIDE_SUMMARY="own pack: profile off, nothing registered"
        log_info "hide: profile off, own pack registers nothing"
        return 0
    fi
    if [ "$SUSFS_AVAILABLE" != 1 ]; then
        HIDE_SUMMARY="own pack unavailable: this kernel has no SuSFS"
        log_warn "hide: no SuSFS on this kernel, so no path can be registered"
        return 0
    fi

    level=$(pack_level "$profile")
    table=$PACK_TABLE
    [ "$DEVICE_PACK" = oneplus-ace5 ] && table="$PACK_TABLE$PACK_TABLE_ACE5"
    # The table is read line by line so a level can be skipped without a
    # second copy of the list.
    while read -r min path; do
        [ -n "$path" ] || continue
        [ "$min" -le "$level" ] || continue
        HIDE_ENTRIES=$((HIDE_ENTRIES + 1))
        if "$KSUD" susfs add-sus-path "$path" >/dev/null 2>&1; then
            HIDE_APPLIED=$((HIDE_APPLIED + 1))
        else
            HIDE_SKIPPED=$((HIDE_SKIPPED + 1))
        fi
    done <<PACK
$table
PACK

    PACK_MODE=own
    HIDE_SUMMARY="own pack ($profile): $HIDE_APPLIED registered, $HIDE_SKIPPED skipped"
    log_info "hide: $HIDE_SUMMARY"
}
