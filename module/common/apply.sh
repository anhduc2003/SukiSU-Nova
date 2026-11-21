# shellcheck shell=sh disable=SC2034
# The orchestrator: one function that brings every layer to its target state.
#
# apply_early() is what post-fs-data runs, before zygote starts: the kernel
# features and the properties are what an app process sees when it is born, so
# they have to be in place first. apply_all() adds the parts that can wait for
# the system to be up (SuSFS packs, maps, bootconfig, companion modules) and
# then writes the report.

apply_early() {
    if [ "$CFG_MANAGE_FEATURES" = 1 ]; then
        declare_features
        enable_features
    else
        audit_features
    fi

    if [ "$CFG_HARDEN_PROPS" = 1 ]; then
        apply_props
    else
        props_audit
    fi
}

apply_all() {
    requested_profile=${1:-}
    RUN_MODE=apply

    log_init
    cfg_load
    detect_all
    log_info "apply: start ($(module_version), $DEVICE_LABEL)"

    apply_early

    # Hide first, then the rest: a detector that starts while this runs should
    # already see the paths gone.
    apply_hide "$requested_profile"
    apply_extra_paths
    apply_mount_hiding

    if [ "$CFG_HIDE_MAPS" = 1 ]; then
        apply_maps
    fi
    if [ "$CFG_SPOOF_BOOTCONFIG" = 1 ]; then
        spoof_bootconfig
    fi
    if [ "$CFG_CONFIGURE_COMPANIONS" = 1 ]; then
        collect_companions write
    else
        collect_companions read
    fi

    # Read back rather than assume: the verdict is built from what the device
    # actually reports after the writes, not from what was requested.
    PROPS_VERIFIEDBOOT=$(prop_get ro.boot.verifiedbootstate)

    write_status
    update_description
    log_info "apply: done ($PROFILE_USED, $HIDE_APPLIED hidden, verifiedboot=$PROPS_VERIFIEDBOOT)"
}

apply_hide() {
    requested=$1
    HIDE_APPLIED=0
    HIDE_SKIPPED=0
    HIDE_SUMMARY=

    if ! ksud_hide_supported; then
        HIDE_SUMMARY="unsupported: this ksud has no hide command"
        log_warn "hide: this ksud build has no built-in hide packs"
        return 0
    fi

    # `auto` hands the decision back to ksud's device detection; anything else
    # is stored, so the profile picked in the WebUI survives the next reboot.
    if [ "$requested" = auto ]; then
        "$KSUD" susfs config remove hide_profile >/dev/null 2>&1
        requested=
    elif [ -n "$requested" ]; then
        "$KSUD" susfs config set hide_profile "$requested" >/dev/null 2>&1 ||
            log_warn "hide: could not store profile '$requested'"
    fi

    if [ -n "$requested" ]; then
        output=$("$KSUD" hide apply "$requested" 2>&1)
        status=$?
        PROFILE_USED=$requested
        PROFILE_SOURCE=argument
    else
        output=$("$KSUD" hide apply 2>&1)
        status=$?
        PROFILE_USED=$(profile_from_status)
        case "$CFG_PROFILE" in
            auto) PROFILE_SOURCE=device ;;
            *) PROFILE_SOURCE=config ;;
        esac
    fi

    HIDE_SUMMARY=$(printf '%s\n' "$output" | head -n 1)
    HIDE_APPLIED=$(printf '%s\n' "$output" | grep -o '[0-9][0-9]* applied' | head -n 1 | cut -d' ' -f1)
    HIDE_SKIPPED=$(printf '%s\n' "$output" | grep -o '[0-9][0-9]* skipped' | head -n 1 | cut -d' ' -f1)
    [ -n "$HIDE_APPLIED" ] || HIDE_APPLIED=0
    [ -n "$HIDE_SKIPPED" ] || HIDE_SKIPPED=0
    [ -n "$PROFILE_USED" ] || PROFILE_USED=$CFG_PROFILE
    [ "$status" -eq 0 ] || log_warn "hide: apply exited $status ($HIDE_SUMMARY)"
    log_raw "$output"
    log_info "hide: $HIDE_APPLIED applied, $HIDE_SKIPPED skipped"
}

# The catalog covers /data/adb at the aggressive level only, so the module's
# own state is registered explicitly and stays hidden at every level.
apply_extra_paths() {
    EXTRA_PATHS=0
    if [ -e "$DATA_DIR" ]; then
        if "$KSUD" susfs add-sus-path "$DATA_DIR" >/dev/null 2>&1; then
            EXTRA_PATHS=1
        else
            log_warn "susfs: could not register $DATA_DIR"
        fi
    fi
    log_info "susfs: $EXTRA_PATHS extra path(s) registered"
}

apply_mount_hiding() {
    MOUNT_HIDING=0
    if ! susfs_has_feature SUSFS_SUS_MOUNT; then
        log_warn "susfs: kernel does not advertise SUSFS_SUS_MOUNT; trying anyway"
    fi
    if "$KSUD" susfs hide-sus-mnts-for-non-su-procs 1 >/dev/null 2>&1; then
        MOUNT_HIDING=1
    else
        log_warn "susfs: this kernel does not support hiding SUS mounts per process"
    fi
}

# Hide the injected Zygisk payloads from /proc/<pid>/maps. The path itself is
# already hidden by the packs; a map is a second, separate view.
apply_maps() {
    MAPS_HIDDEN=0
    if ! susfs_has_feature SUSFS_SUS_MAP; then
        log_warn "susfs: kernel does not advertise SUSFS_SUS_MAP; trying anyway"
    fi
    list=$DATA_DIR/maps.list
    : > "$list"
    for library in /data/adb/ksu/zygisk/lib64/libzygisk.so /data/adb/ksu/zygisk/lib/libzygisk.so; do
        [ -f "$library" ] && printf '%s\n' "$library" >> "$list"
    done
    if [ -d /data/adb/zygisksu ]; then
        find /data/adb/zygisksu -type f -name 'libzygisk*.so' 2>/dev/null >> "$list"
    fi
    sort -u "$list" > "$list.tmp" 2>/dev/null && mv -f "$list.tmp" "$list"
    while read -r library; do
        [ -n "$library" ] || continue
        if "$KSUD" susfs add-sus-map "$library" >/dev/null 2>&1; then
            MAPS_HIDDEN=$((MAPS_HIDDEN + 1))
        else
            log_warn "susfs: could not hide map $library"
        fi
    done < "$list"
    log_info "maps: $MAPS_HIDDEN payload(s) hidden"
}

# Serve a sanitised /proc/bootconfig through SuSFS.
#
# Only the value of a key that already exists is replaced, and the result is
# rejected unless every line still parses as `key = value` and the line count
# is unchanged. A detector reading bootconfig then sees the stock values while
# everything else stays exactly as the bootloader wrote it.
spoof_bootconfig() {
    BOOTCONFIG_STATE=skipped
    # BOOTCONFIG_SRC lets the test harness feed a captured file; a boot leaves
    # it unset and reads the real one.
    bootconfig_src=${BOOTCONFIG_SRC:-/proc/bootconfig}
    if [ ! -r "$bootconfig_src" ]; then
        BOOTCONFIG_STATE="no $bootconfig_src"
        return 0
    fi

    fake=$DATA_DIR/bootconfig.fake
    [ -f "$DATA_DIR/bootconfig.orig" ] || cp -f "$bootconfig_src" "$DATA_DIR/bootconfig.orig" 2>/dev/null
    if ! susfs_has_feature SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG; then
        log_warn "susfs: kernel does not advertise cmdline/bootconfig spoofing; trying anyway"
    fi

    sed \
        -e 's/^\(androidboot\.verifiedbootstate[ \t]*=\)[ \t]*.*/\1 green/' \
        -e 's/^\(androidboot\.vbmeta\.device_state[ \t]*=\)[ \t]*.*/\1 locked/' \
        -e 's/^\(androidboot\.flash\.locked[ \t]*=\)[ \t]*.*/\1 1/' \
        -e 's/^\(androidboot\.veritymode[ \t]*=\)[ \t]*.*/\1 enforcing/' \
        -e 's/^\(androidboot\.warranty_bit[ \t]*=\)[ \t]*.*/\1 0/' \
        -e 's/^\(androidboot\.vbmeta\.invalidate_on_error[ \t]*=\)[ \t]*.*/\1 yes/' \
        "$bootconfig_src" > "$fake.tmp" 2>/dev/null

    if cmp -s "$bootconfig_src" "$fake.tmp"; then
        BOOTCONFIG_STATE="nothing to spoof"
        rm -f "$fake.tmp"
        log_info "bootconfig: no spoofable key found"
        return 0
    fi

    bad=$(awk 'NF && $0 !~ /^[A-Za-z0-9_.-]+[ \t]*=/ { count++ } END { print count + 0 }' "$fake.tmp")
    lines_before=$(wc -l < "$bootconfig_src" | tr -d ' ')
    lines_after=$(wc -l < "$fake.tmp" | tr -d ' ')
    if [ "${bad:-1}" != 0 ] || [ "$lines_before" != "$lines_after" ]; then
        BOOTCONFIG_STATE="rejected: transform did not validate"
        rm -f "$fake.tmp"
        log_warn "bootconfig: refusing a transform that changed the file structure"
        return 0
    fi

    mv -f "$fake.tmp" "$fake"
    chmod 0644 "$fake" 2>/dev/null
    if "$KSUD" susfs set-cmdline-or-bootconfig "$fake" >/dev/null 2>&1; then
        BOOTCONFIG_STATE=spoofed
        log_info "bootconfig: spoofing verified boot state from $fake"
    else
        BOOTCONFIG_STATE="failed: kernel refused the file"
        log_warn "bootconfig: kernel refused $fake"
    fi
}

# Read-only state for the status report. Nothing is written except the log.
collect_live() {
    RUN_MODE=status
    cfg_load
    detect_all

    PROFILE_USED=$(profile_from_status)
    if [ -z "$PROFILE_USED" ]; then
        case "$CFG_PROFILE" in
            auto) PROFILE_USED=$DEVICE_PROFILE ;;
            *) PROFILE_USED=$CFG_PROFILE ;;
        esac
    fi
    case "$CFG_PROFILE" in
        auto) PROFILE_SOURCE=device ;;
        *) PROFILE_SOURCE=config ;;
    esac

    HIDE_APPLIED=$(entries_from_status)
    [ -n "$HIDE_APPLIED" ] || HIDE_APPLIED=0
    HIDE_SUMMARY="not re-applied"

    props_audit
    audit_features
    MAPS_HIDDEN=0
    [ -f "$DATA_DIR/maps.list" ] && MAPS_HIDDEN=$(grep -c . "$DATA_DIR/maps.list" 2>/dev/null)
    [ -n "$MAPS_HIDDEN" ] || MAPS_HIDDEN=0
    if [ -f "$DATA_DIR/bootconfig.fake" ]; then
        BOOTCONFIG_STATE=configured
    else
        BOOTCONFIG_STATE="not configured"
    fi
    collect_companions read
}
