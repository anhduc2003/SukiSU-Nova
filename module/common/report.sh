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
HIDE_ENTRIES=0
HIDE_RECORDED=0
MAPS_HIDDEN=0
MOUNT_HIDING=
BOOTCONFIG_STATE=skipped
UNAME_STATE=off
HMA_PRESENT=0
HMA_CONFIGURED=0
HMA_NOTE=
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

# `hide status` prints `profile: <name> (automatic)` when ksud picked the level
# itself, and `profile: <name>` when it came from its stored setting.
profile_source_from_status() {
    line=$("$KSUD" hide status 2>/dev/null | head -n 1)
    case "$line" in
        *"(automatic)"*) printf 'device' ;;
        '') printf 'unknown' ;;
        *) printf 'stored' ;;
    esac
}

# What the last apply actually registered, so a status run can report a
# verified number instead of the catalogue size. The uname record carries
# the boot id: the kernel string resets at boot, so a stale claim from an
# older boot says nothing about the kernel now.
state_write() {
    uname_record=${UNAME_STATE:-off}
    if [ "$uname_record" = off ]; then
        # spoof_uname was skipped this pass (profile off): the kernel keeps
        # serving an earlier string from this boot, so keep that record.
        if uname_record_boot_matches "$(state_get uname)"; then
            uname_record=$(state_get uname)
        fi
    elif [ "$uname_record" = spoofed ] || [ "$uname_record" = stale ]; then
        uname_record="$uname_record:$(current_boot_id)"
    fi
    {
        printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'profile=%s\n' "$PROFILE_USED"
        printf 'applied=%s\n' "${HIDE_APPLIED:-0}"
        printf 'skipped=%s\n' "${HIDE_SKIPPED:-0}"
        printf 'verifiedboot=%s\n' "${PROPS_VERIFIEDBOOT:-}"
        printf 'uname=%s\n' "${uname_record:-off}"
    } > "$STATE_FILE.tmp" 2>/dev/null &&
        mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
    chmod 0644 "$STATE_FILE" 2>/dev/null
}

state_get() {
    sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1
}

verdict_basic() {
    if [ "$SUSFS_AVAILABLE" != 1 ]; then
        printf 'unavailable: this kernel has no SuSFS'
        return 0
    fi
    if [ "$RUN_MODE" = status ] && [ "$HIDE_RECORDED" != 1 ]; then
        printf 'not verified: run the action button'
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
        if [ "$PROFILE_USED" = off ]; then
            printf 'off: nothing registered this pass (earlier hides clear at the next reboot)'
            return 0
        fi
        printf '%s applied, %s skipped' "$HIDE_APPLIED" "$HIDE_SKIPPED"
        return 0
    fi
    if [ "$HIDE_RECORDED" != 1 ]; then
        printf 'no apply recorded; run the action button'
        return 0
    fi
    printf '%s applied at %s (%s in the catalog)' \
        "$HIDE_APPLIED" "$(state_get time)" "$HIDE_ENTRIES"
}

# Which catalogue did the hiding: the ksud built-in one, or NovaHide's own
# copy for a ksud too old to have the `hide` command.
pack_line() {
    if ksud_hide_supported; then
        printf 'ksud built-in catalogue'
    else
        printf "NovaHide's own list (this ksud has no hide command)"
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

# The state of a spoof lives and dies with one boot: after a reboot the
# kernel string is the real one again until the boot pass re-applies it, so
# the record carries the boot id and a stale claim only stands while the
# same boot is running.
current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null
}

uname_record_boot_matches() {
    recorded=$1
    case "$recorded" in
        'spoofed:'*|'stale:'*)
            [ "${recorded#*:}" = "$(current_boot_id)" ]
            ;;
        *) return 1 ;;
    esac
}

# The kernel string is held in kernel memory, and SuSFS cannot report it
# back. A status run says what the config asks for and what the last apply
# recorded; when the values are cleared, the last spoofed string stays
# served until the next reboot, and the report keeps saying so.
uname_line() {
    configured=0
    if [ -n "$CFG_UNAME_RELEASE" ] && [ -n "$CFG_UNAME_VERSION" ]; then
        configured=1
    fi
    case "$UNAME_STATE" in
        spoofed) printf 'spoofed for non-su processes' ; return 0 ;;
        refused) printf 'the kernel refused the string' ; return 0 ;;
        unavailable) printf 'no SuSFS on this kernel' ; return 0 ;;
        partial) printf 'set both UNAME_RELEASE and UNAME_VERSION' ; return 0 ;;
        stale) printf 'not configured; the kernel serves the last spoofed string until reboot' ; return 0 ;;
    esac
    if [ "$configured" != 1 ]; then
        # The kernel serves whatever string it was last given until the next
        # boot; the record says so only while that boot is still running.
        if uname_record_boot_matches "$(state_get uname)"; then
            printf 'not configured; the kernel serves the last spoofed string until reboot'
        else
            printf 'not configured'
        fi
        return 0
    fi
    if [ "$RUN_MODE" = apply ]; then
        # spoof_uname only skips the pass when the profile is off.
        printf 'configured but not applied this pass (profile off)'
        return 0
    fi
    if [ "$PROFILE_USED" = off ]; then
        printf 'configured but not applied this pass (profile off)'
        return 0
    fi
    # A status run cannot ask the kernel, so the last apply's outcome answers.
    case "$(state_get uname)" in
        'spoofed:'*) printf 'configured; applied by the last apply pass' ;;
        'refused') printf 'configured; the kernel refused the string' ;;
        'unavailable') printf 'configured; no SuSFS on this kernel' ;;
        'partial') printf 'configured; set both values in the config' ;;
        *) printf 'configured; not applied yet' ;;
    esac
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
    printf '%-12s %s\n' "pack" "$(pack_line)"
    printf '%-12s %s\n' "props" "$(props_line)"
    case "$MOUNT_HIDING" in
        1) printf '%-12s %s\n' "mounts" "hidden from non-su processes" ;;
        0) printf '%-12s %s\n' "mounts" "not hidden" ;;
        *) printf '%-12s %s\n' "mounts" "not queryable in a status run" ;;
    esac
    printf '%-12s %s\n' "maps" "$(maps_line)"
    printf '%-12s %s\n' "bootconfig" "$BOOTCONFIG_STATE"
    printf '%-12s %s\n' "uname" "$(uname_line)"
    printf '%-12s %s\n' "zygisk" "$ZYGISK_STATE"
    printf '%s\n' "hma-oss"
    hma_text
    printf '%s\n' "bootloader"
    bootloader_text
    printf '%s\n' "companions"
    companions_text
    printf '%s\n' "module conflicts"
    conflicts_text
    printf '%s\n' "banking"
    banking_text
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
    if [ "$HIDE_RECORDED" = 1 ]; then
        recorded=true
    else
        recorded=false
    fi
    printf '"packSource":"%s",' "$(json_escape "$(pack_line)")"
    printf '"hide":{"applied":%s,"skipped":%s,"entries":%s,"recorded":%s,"at":"%s","summary":"%s"},' \
        "${HIDE_APPLIED:-0}" "${HIDE_SKIPPED:-0}" "${HIDE_ENTRIES:-0}" "$recorded" \
        "$(json_escape "$(state_get time)")" "$(json_escape "$HIDE_SUMMARY")"
    printf '"props":{"fixed":%s,"ok":%s,"failed":%s,"verifiedBoot":"%s"},' \
        "${PROPS_FIXED:-0}" "${PROPS_OK:-0}" "${PROPS_FAILED:-0}" \
        "$(json_escape "${PROPS_VERIFIEDBOOT:-}")"
    case "$MOUNT_HIDING" in
        1) mount_flag=true ;;
        0) mount_flag=false ;;
        *) mount_flag=null ;;
    esac
    printf '"mountHiding":%s,"maps":%s,"bootconfig":"%s","uname":"%s","zygisk":"%s",' \
        "$mount_flag" "${MAPS_HIDDEN:-0}" "$(json_escape "$BOOTCONFIG_STATE")" \
        "$(json_escape "$(uname_line)")" "$(json_escape "$ZYGISK_STATE")"
    printf '"companions":%s,' "$(companions_json)"
    printf '"conflicts":%s,' "$(conflicts_json)"
    printf '"banking":%s,' "$(banking_json)"
    printf '"hma":%s,' "$(hma_json)"
    printf '"bootloader":%s,' "$(bootloader_json)"
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
