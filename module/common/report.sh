# shellcheck shell=sh disable=SC2034
# Reporting: the text status, the JSON the WebUI reads, the verdict, and the
# one-line summary written back into module.prop.
#
# The verdict is a local readiness check, not a Play Integrity result. Google
# decides that server-side from signals no module can read, so claiming "green"
# here would be a promise the device cannot keep.

RUN_MODE=apply
PROFILE_USED=auto
PROFILE_SOURCE=config
HIDE_SUMMARY=
HIDE_APPLIED=0
HIDE_SKIPPED=0
MAPS_HIDDEN=0
MOUNT_HIDING=
BOOTCONFIG_STATE=skipped
PROPS_VERIFIEDBOOT=

json_escape() {
    # Values are single-line and ASCII by construction; escape the two
    # characters that would otherwise end the string.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

yes_no() {
    if [ "$1" = 1 ]; then
        printf 'ok'
    else
        printf '-'
    fi
}

profile_from_status() {
    line=$("$KSUD" hide status 2>/dev/null | head -n 1)
    printf '%s' "$line" | sed -n 's/^profile: \([a-z]*\).*/\1/p'
}

entries_from_status() {
    "$KSUD" hide status 2>/dev/null | sed -n 's/^entries: //p' | head -n 1
}

verdict_basic() {
    if [ "$SUSFS_AVAILABLE" != 1 ]; then
        printf 'unavailable: this kernel has no SuSFS'
        return 0
    fi
    if [ "${HIDE_APPLIED:-0}" = 0 ]; then
        printf 'not applied: run the action button'
        return 0
    fi
    if [ "$PROPS_VERIFIEDBOOT" != green ]; then
        printf 'props: verified boot reads %s' "${PROPS_VERIFIEDBOOT:-unknown}"
        return 0
    fi
    printf 'ready'
}

verdict_device() {
    basic=$(verdict_basic)
    if [ "$basic" != ready ]; then
        printf '%s' "$basic"
        return 0
    fi
    if [ "$PIF_PRESENT" = 1 ]; then
        printf 'ready: PlayIntegrityFix supplies the fingerprint'
    else
        printf 'needs a passing fingerprint (PlayIntegrityFix)'
    fi
}

verdict_strong() {
    device=$(verdict_device)
    case "$device" in
        ready*)
            if [ "$KEYBOX_PRESENT" = 1 ]; then
                printf 'ready: keybox present'
            elif [ "$TS_PRESENT" = 1 ]; then
                printf 'needs a keybox in TrickyStore'
            else
                printf 'needs TrickyStore and a keybox'
            fi
            ;;
        *)
            printf '%s' "$device"
            ;;
    esac
}

hide_line() {
    if [ "$RUN_MODE" = apply ]; then
        printf '%s applied, %s skipped' "$HIDE_APPLIED" "$HIDE_SKIPPED"
    else
        printf '%s entries for this profile, not re-applied now' "${HIDE_APPLIED:-0}"
    fi
}

maps_line() {
    if [ "$RUN_MODE" = apply ]; then
        printf '%s payload(s) hidden' "$MAPS_HIDDEN"
    else
        printf '%s payload(s) configured' "$MAPS_HIDDEN"
    fi
}

props_line() {
    if [ "$RUN_MODE" = apply ]; then
        printf '%s fixed, %s already correct, %s failed' "$PROPS_FIXED" "$PROPS_OK" "$PROPS_FAILED"
    else
        printf '%s/%s forced properties already correct' "$PROPS_OK" "$((PROPS_OK + PROPS_FAILED))"
    fi
}

report_text() {
    printf 'NovaHide %s - %s [%s %s]\n' \
        "$(module_version)" "$DEVICE_LABEL" "${DEVICE_CODENAME:-?}" "${DEVICE_MODEL:-?}"
    printf '%-12s %s\n' "profile" "$PROFILE_USED ($PROFILE_SOURCE)"
    if [ "$SUSFS_AVAILABLE" = 1 ]; then
        printf '%-12s %s %s %s\n' "susfs" "$SUSFS_VERSION" "$SUSFS_IMPLEMENTATION" "$SUSFS_VARIANT"
    else
        printf '%-12s %s\n' "susfs" "unavailable"
    fi
    if [ "$KERNEL_UAPI" = unknown ]; then
        printf '%-12s %s\n' "kernel" "$KERNEL_VERSION"
    else
        printf '%-12s %s uapi %s\n' "kernel" "$KERNEL_VERSION" "$KERNEL_UAPI"
    fi
    printf '%-12s %s\n' "features" "${FEATURE_SUMMARY:-unknown}"
    printf '%-12s %s\n' "hide" "$(hide_line)"
    printf '%-12s %s\n' "props" "$(props_line)"
    case "$MOUNT_HIDING" in
        1) printf '%-12s %s\n' "mounts" "hidden from non-su processes" ;;
        0) printf '%-12s %s\n' "mounts" "not hidden" ;;
        *) printf '%-12s %s\n' "mounts" "not queryable in a status run" ;;
    esac
    printf '%-12s %s\n' "maps" "$(maps_line)"
    printf '%-12s %s\n' "bootconfig" "$BOOTCONFIG_STATE"
    printf '%-12s %s\n' "zygisk" "$ZYGISK_STATE"
    printf '%s\n' "companions"
    companions_text
    printf '%s\n' "verdict"
    printf '  %-7s %s\n' "BASIC" "$(verdict_basic)"
    printf '  %-7s %s\n' "DEVICE" "$(verdict_device)"
    printf '  %-7s %s\n' "STRONG" "$(verdict_strong)"
    printf '%-12s %s\n' "note" "local readiness only; Google decides the verdict server-side"
}

report_json() {
    if [ "$SUSFS_AVAILABLE" = 1 ]; then
        susfs_flag=true
    else
        susfs_flag=false
    fi
    printf '{"mode":"%s","version":"%s","device":{"codename":"%s","model":"%s","label":"%s","pack":"%s"},' \
        "$RUN_MODE" "$(json_escape "$(module_version)")" \
        "$(json_escape "${DEVICE_CODENAME:-}")" "$(json_escape "${DEVICE_MODEL:-}")" \
        "$(json_escape "$DEVICE_LABEL")" "$(json_escape "$DEVICE_PACK")"
    printf '"profile":"%s","profileSource":"%s",' \
        "$(json_escape "$PROFILE_USED")" "$(json_escape "$PROFILE_SOURCE")"
    printf '"susfs":{"available":%s,"version":"%s","variant":"%s","implementation":"%s","features":"%s"},' \
        "$susfs_flag" "$(json_escape "$SUSFS_VERSION")" \
        "$(json_escape "$SUSFS_VARIANT")" "$(json_escape "$SUSFS_IMPLEMENTATION")" \
        "$(json_escape "$SUSFS_FEATURES")"
    printf '"kernel":{"version":"%s","uapi":"%s"},' \
        "$(json_escape "$KERNEL_VERSION")" "$(json_escape "$KERNEL_UAPI")"
    printf '"features":"%s",' "$(json_escape "${FEATURE_SUMMARY:-}")"
    printf '"hide":{"applied":%s,"skipped":%s,"summary":"%s"},' \
        "${HIDE_APPLIED:-0}" "${HIDE_SKIPPED:-0}" "$(json_escape "$HIDE_SUMMARY")"
    printf '"props":{"fixed":%s,"ok":%s,"failed":%s,"verifiedBoot":"%s"},' \
        "${PROPS_FIXED:-0}" "${PROPS_OK:-0}" "${PROPS_FAILED:-0}" \
        "$(json_escape "${PROPS_VERIFIEDBOOT:-}")"
    case "$MOUNT_HIDING" in
        1) mount_flag=true ;;
        0) mount_flag=false ;;
        *) mount_flag=null ;;
    esac
    printf '"mountHiding":%s,"maps":%s,"bootconfig":"%s","zygisk":"%s",' \
        "$mount_flag" "${MAPS_HIDDEN:-0}" "$(json_escape "$BOOTCONFIG_STATE")" "$(json_escape "$ZYGISK_STATE")"
    printf '"companions":%s,' "$(companions_json)"
    printf '"verdict":{"basic":"%s","device":"%s","strong":"%s"},' \
        "$(json_escape "$(verdict_basic)")" "$(json_escape "$(verdict_device)")" \
        "$(json_escape "$(verdict_strong)")"
    printf '"log":"%s"}' "$(json_escape "$LOG_FILE")"
    printf '\n'
}

write_status() {
    report_text > "$STATUS_FILE.tmp" 2>/dev/null || return 0
    mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null
    chmod 0644 "$STATUS_FILE" 2>/dev/null
    chown 0:0 "$STATUS_FILE" 2>/dev/null
}

# The one-line summary the manager shows under the module name.
description_line() {
    printf 'NovaHide %s | %s | %s hidden | TS:%s PIF:%s KB:%s' \
        "$(module_version)" "$PROFILE_USED" "${HIDE_APPLIED:-0}" \
        "$(yes_no "$TS_PRESENT")" "$(yes_no "$PIF_PRESENT")" "$(yes_no "$KEYBOX_PRESENT")"
}

# Rewrite only the description key, leaving every other line untouched. The
# write goes through a temporary file so a crash cannot leave a truncated
# module.prop, which would make the module unreadable to the manager.
update_description() {
    [ "$CFG_STATUS_IN_DESCRIPTION" = 1 ] || return 0
    [ -f "$MODULE_PROP" ] || return 0
    line=$(description_line)
    current=$(sed -n 's/^description=//p' "$MODULE_PROP" 2>/dev/null | head -n 1)
    [ "$current" = "$line" ] && return 0
    if awk -v line="$line" '
        BEGIN { done = 0 }
        /^description=/ {
            if (!done) {
                print "description=" line
                done = 1
                next
            }
        }
        { print }
        END { if (!done) print "description=" line }
    ' "$MODULE_PROP" > "$MODULE_PROP.tmp" 2>/dev/null; then
        mv -f "$MODULE_PROP.tmp" "$MODULE_PROP" 2>/dev/null
        chmod 0644 "$MODULE_PROP" 2>/dev/null
        chown 0:0 "$MODULE_PROP" 2>/dev/null
    else
        rm -f "$MODULE_PROP.tmp" 2>/dev/null
        log_warn "could not update module.prop description"
    fi
}
