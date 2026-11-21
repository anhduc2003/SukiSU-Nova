# shellcheck shell=sh disable=SC2034
# The hiding modules that are installed alongside this one.
#
# NovaHide does not bundle anyone else's binaries: it detects the modules the
# user already has, writes the settings each of them exposes as plain text,
# and reports what is missing. Detection is by documented data directory, not
# by module id, because forks rename the id but keep the directory.
#
# The three settings that need a secret (a keybox, a device fingerprint, an
# app-list template) are reported and never invented. Shamiko's whitelist mode
# is reported and never switched on: it hides root from every app that is not
# on its list, which would break the phone for a user who did not ask for it.

TS_PRESENT=0
KEYBOX_PRESENT=0
PIF_PRESENT=0

# mode is `write` during a boot pass and `read` for a status query; only the
# write pass touches another module's files.
collect_companions() {
    mode=$1
    : > "$COMPANIONS_FILE"
    TS_PRESENT=0
    KEYBOX_PRESENT=0
    PIF_PRESENT=0

    tricky_store_row "$mode"
    pif_row
    shamiko_row
    zygisk_next_row
    builtin_zygisk_row
    lsposed_row
    hma_row
    susfs_module_row
    susfs_manager_row
    other_root_row

    log_info "companions: $(companions_text | tr '\n' ';')"
    conflicts_scan "$mode"
    log_info "conflicts: $(conflicts_count) detected"
}

add_companion() {
    # name|state|note; a note must not contain a pipe.
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$COMPANIONS_FILE"
}

tricky_store_row() {
    mode=$1
    if [ ! -d /data/adb/tricky_store ]; then
        add_companion TrickyStore absent "needed for STRONG integrity; it also needs a keybox.xml"
        return 0
    fi
    TS_PRESENT=1
    if [ -s /data/adb/tricky_store/keybox.xml ]; then
        KEYBOX_PRESENT=1
        keybox="keybox present"
    else
        keybox="no keybox.xml"
    fi
    if [ "$mode" = write ]; then
        added=$(ts_sync_targets)
        if [ "${added:-0}" -gt 0 ]; then
            note="added $added attestation target(s), $keybox"
        else
            note="attestation targets ok, $keybox"
        fi
    else
        missing=$(ts_targets_missing)
        if [ "${missing:-0}" -gt 0 ]; then
            note="$missing attestation target(s) missing, $keybox"
        else
            note="attestation targets ok, $keybox"
        fi
    fi
    add_companion TrickyStore present "$note"
}

# Count the attestation packages target.txt does not list yet, without
# writing anything.
ts_targets_missing() {
    target=/data/adb/tricky_store/target.txt
    missing=0
    for package in com.google.android.gms com.android.vending; do
        if [ -f "$target" ] && awk -v want="$package" '
            {
                line = $0
                sub(/[!?][ \t]*$/, "", line)
                gsub(/[ \t]/, "", line)
                if (line == want) found = 1
            }
            END { exit(found ? 0 : 1) }
        ' "$target"; then
            continue
        fi
        missing=$((missing + 1))
    done
    printf '%s' "$missing"
}

# Make sure the two Play Integrity packages are in TrickyStore's target.txt.
#
# Only lines that are missing are appended, and a package that already carries
# a `!`/`?` suffix counts as present: appending a second bare line would
# override the mode the user picked for it. An unreadable file is left alone
# instead of being replaced by a two-line version.
ts_sync_targets() {
    dir=/data/adb/tricky_store
    target=$dir/target.txt
    tmp=$DATA_DIR/target.txt.tmp
    if [ -f "$target" ] && [ ! -r "$target" ]; then
        log_warn "tricky_store: target.txt is unreadable, leaving it alone"
        printf '0'
        return 0
    fi
    : > "$tmp"
    if [ -f "$target" ]; then
        cat "$target" >> "$tmp"
    fi
    added=0
    for package in com.google.android.gms com.android.vending; do
        if awk -v want="$package" '
            BEGIN { found = 0 }
            {
                line = $0
                sub(/[!?][ \t]*$/, "", line)
                gsub(/[ \t]/, "", line)
                if (line == want) found = 1
            }
            END { exit(found ? 0 : 1) }
        ' "$tmp"; then
            continue
        fi
        printf '%s\n' "$package" >> "$tmp"
        added=$((added + 1))
    done
    if [ "$added" -gt 0 ]; then
        mkdir -p "$dir" 2>/dev/null
        if cp -f "$tmp" "$target.new" && mv -f "$target.new" "$target"; then
            chmod 0644 "$target" 2>/dev/null
            chown 0:0 "$target" 2>/dev/null
            log_info "tricky_store: added $added attestation target(s)"
        else
            log_warn "tricky_store: could not write target.txt"
            rm -f "$target.new"
            added=0
        fi
    fi
    rm -f "$tmp"
    printf '%s' "$added"
}

pif_row() {
    found=
    disabled=
    for dir in /data/adb/modules/playintegrityfix /data/adb/modules/pif /data/adb/modules/pif-next; do
        if [ -d "$dir" ]; then
            # ksud skips a module marked disable or remove, so its directory
            # being there says nothing about whether a fingerprint is served.
            if [ -f "$dir/disable" ] || [ -f "$dir/remove" ]; then
                disabled=$dir
                continue
            fi
            found=$dir
            break
        fi
    done
    if [ -n "$found" ]; then
        PIF_PRESENT=1
        add_companion PlayIntegrityFix present "supplies the fingerprint; its own settings are left alone"
    elif [ -n "$disabled" ]; then
        add_companion PlayIntegrityFix disabled "installed but switched off; no fingerprint is served"
    elif [ -f /data/adb/pif.json ]; then
        add_companion PlayIntegrityFix config-only "pif.json present but no active module serves it"
    else
        add_companion PlayIntegrityFix absent "needed for DEVICE integrity: it supplies the fingerprint"
    fi
}

shamiko_row() {
    if [ ! -d /data/adb/shamiko ]; then
        add_companion Shamiko absent "optional: mount_hide and the SuSFS packs already cover its job"
        return 0
    fi
    if [ -f /data/adb/shamiko/whitelist ]; then
        add_companion Shamiko present "whitelist mode: root is hidden from every app not on its list"
    else
        add_companion Shamiko present "blacklist mode (denylist apps only)"
    fi
}

zygisk_next_row() {
    if [ ! -d /data/adb/zygisksu ]; then
        add_companion ZygiskNext absent "not needed: this fork ships its own Zygisk"
        return 0
    fi
    if [ -f /data/adb/ksu/.builtin_zygisk ]; then
        add_companion ZygiskNext present "conflict: built-in Zygisk is enabled too; keep one"
        log_warn "companions: Zygisk Next and built-in Zygisk are both enabled"
    else
        add_companion ZygiskNext present "serving Zygisk modules"
    fi
}

builtin_zygisk_row() {
    if [ "$ZYGISK_STATE" = running ]; then
        add_companion BuiltinZygisk running "payloads staged under /data/adb/ksu/zygisk"
    else
        add_companion BuiltinZygisk "$ZYGISK_STATE" "turn it on in the manager to serve Zygisk modules"
    fi
}

lsposed_row() {
    if [ -d /data/adb/lspd ]; then
        add_companion LSPosed present "scope is per app: set it in the LSPosed manager"
    fi
}

hma_row() {
    found=
    for dir in /data/adb/modules/hide_my_applist /data/adb/modules/hma /data/data/com.tsng.hidemyapplist; do
        if [ -d "$dir" ]; then
            found=$dir
            break
        fi
    done
    if [ -n "$found" ]; then
        add_companion HideMyApplist present "hide the manager and root apps from the target app's list"
    fi
}

susfs_module_row() {
    if [ -d /data/adb/modules/susfs4ksu ] || [ -d /data/adb/modules/susfs ]; then
        add_companion SUSFS4KSU present "redundant: this kernel already has SuSFS built in"
    fi
}

susfs_manager_row() {
    if [ -d /data/adb/modules/susfs_manager ]; then
        add_companion SuSFSManager present "also applies a hide pack at boot; its level can win over this one"
        log_warn "companions: susfs_manager also applies a hide pack"
    fi
}

other_root_row() {
    if [ -d /data/adb/magisk ]; then
        add_companion Magisk present "a second root implementation is installed"
    fi
    if [ -d /data/adb/ap ]; then
        add_companion APatch present "a second root implementation is installed"
    fi
}

# A module the manager would skip: its directory is there but carries a
# disable or remove marker.
module_dir_active() {
    [ -d "$1" ] || return 1
    [ -f "$1/disable" ] && return 1
    [ -f "$1/remove" ] && return 1
    return 0
}

module_disable() {
    dir=$1
    if : > "$dir/disable" 2>/dev/null; then
        chmod 0644 "$dir/disable" 2>/dev/null
        chown 0:0 "$dir/disable" 2>/dev/null
        log_warn "conflicts: disabled $dir (delete the disable marker to undo)"
        return 0
    fi
    log_warn "conflicts: could not write the disable marker in $dir"
    return 1
}

# Conflicts between the modules installed here leak root on their own: two
# Zygisk stacks inject the same processes, two fingerprint modules fight over
# the same props, a second hide pack undoes this one's registrations.
#
# The scan is a report. It only disables a module when the user switched
# AUTO_DISABLE_CONFLICTS on, only in a write pass, and only for the two
# conflicts with an unambiguous loser; nothing is ever re-enabled, and the
# disable marker is the user's to delete.
conflicts_scan() {
    mode=$1
    : > "$CONFLICTS_FILE"

    # One Zygisk at a time. Zygisk Next is installed when its data directory
    # exists; if no module directory of a known name is found, treat it as
    # active and report-only, since there is nothing safe to disable.
    zn_module=
    for dir in /data/adb/modules/zygisksu /data/adb/modules/zygisknext \
        /data/adb/modules/zygisk_next /data/adb/modules/zygisk-next; do
        if [ -d "$dir" ]; then
            zn_module=$dir
            break
        fi
    done
    zn_active=0
    if [ -d /data/adb/zygisksu ]; then
        if [ -z "$zn_module" ] || module_dir_active "$zn_module"; then
            zn_active=1
        fi
    fi
    if [ "$ZYGISK_STATE" = running ] && [ "$zn_active" = 1 ]; then
        if [ "$mode" = write ] && [ "$CFG_AUTO_DISABLE_CONFLICTS" = 1 ] &&
            [ -n "$zn_module" ] && module_disable "$zn_module"; then
            add_conflict high "Zygisk twice" \
                "built-in Zygisk and Zygisk Next both inject; Zygisk Next was disabled, back at the next boot if the marker is deleted"
        else
            add_conflict high "Zygisk twice" \
                "built-in Zygisk and Zygisk Next both inject; keep one, the other is the leak"
        fi
    fi

    # Fingerprint modules overwrite each other's props; which one to keep is
    # the user's call, so this one is never auto-fixed.
    pif_active=0
    for dir in /data/adb/modules/playintegrityfix /data/adb/modules/pif \
        /data/adb/modules/pif-next /data/adb/modules/playintegrity; do
        module_dir_active "$dir" && pif_active=$((pif_active + 1))
    done
    if [ "$pif_active" -gt 1 ]; then
        add_conflict high "PIF twice" \
            "$pif_active fingerprint modules are active; they fight over the same props, keep one"
    fi

    if module_dir_active /data/adb/modules/susfs_manager; then
        if [ "$mode" = write ] && [ "$CFG_AUTO_DISABLE_CONFLICTS" = 1 ] &&
            module_disable /data/adb/modules/susfs_manager; then
            add_conflict medium "SuSFS pack twice" \
                "susfs_manager also applies a hide pack; it was disabled, back at the next boot if the marker is deleted"
        else
            add_conflict medium "SuSFS pack twice" \
                "susfs_manager also applies a hide pack; the two packs can disagree on what stays mounted"
        fi
    fi

    if [ -d /data/adb/magisk ]; then
        add_conflict high "second root" \
            "Magisk is installed as well; two root stacks fight over mounts and denials"
    fi
    if [ -d /data/adb/ap ]; then
        add_conflict high "second root" \
            "APatch is installed as well; two root stacks fight over mounts and denials"
    fi

    # Not leaks, but compatibility facts: these modules need a Zygisk to hook.
    if [ "$ZYGISK_STATE" != running ] && [ "$zn_active" = 0 ]; then
        if [ -d /data/adb/shamiko ]; then
            add_conflict info "Shamiko idle" \
                "Shamiko needs a Zygisk to hook; with none running it does nothing"
        fi
        if [ -d /data/adb/modules/hide_my_applist ] || [ -d /data/adb/modules/hma ] ||
            [ -d /data/data/com.tsng.hidemyapplist ]; then
            add_conflict info "HMA idle" \
                "Hide My Applist needs a Zygisk to hook; with none running it does nothing"
        fi
    fi
}

add_conflict() {
    # severity|name|note; a note must not contain a pipe.
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CONFLICTS_FILE"
}

conflicts_count() {
    count=0
    if [ -f "$CONFLICTS_FILE" ]; then
        count=$(grep -c . "$CONFLICTS_FILE" 2>/dev/null)
        [ -n "$count" ] || count=0
    fi
    printf '%s' "$count"
}

companions_text() {
    [ -f "$COMPANIONS_FILE" ] || return 0
    while IFS='|' read -r name state note; do
        [ -n "$name" ] || continue
        printf '  %-17s %-9s %s\n' "$name" "$state" "$note"
    done < "$COMPANIONS_FILE"
}

conflicts_text() {
    if [ ! -f "$CONFLICTS_FILE" ] || [ "$(conflicts_count)" = 0 ]; then
        printf '  %-17s %s\n' "none" "no conflict detected between the installed modules"
        return 0
    fi
    while IFS='|' read -r severity name note; do
        [ -n "$name" ] || continue
        printf '  %-17s %-9s %s\n' "$name" "$severity" "$note"
    done < "$CONFLICTS_FILE"
}

conflicts_json() {
    printf '['
    first=1
    if [ -f "$CONFLICTS_FILE" ]; then
        while IFS='|' read -r severity name note; do
            [ -n "$name" ] || continue
            if [ "$first" = 1 ]; then
                first=0
            else
                printf ','
            fi
            printf '{"severity":"%s","name":"%s","note":"%s"}' \
                "$(json_escape "$severity")" "$(json_escape "$name")" "$(json_escape "$note")"
        done < "$CONFLICTS_FILE"
    fi
    printf ']'
}

companions_json() {
    printf '['
    first=1
    if [ -f "$COMPANIONS_FILE" ]; then
        while IFS='|' read -r name state note; do
            [ -n "$name" ] || continue
            if [ "$first" = 1 ]; then
                first=0
            else
                printf ','
            fi
            printf '{"name":"%s","state":"%s","note":"%s"}' \
                "$(json_escape "$name")" "$(json_escape "$state")" "$(json_escape "$note")"
        done < "$COMPANIONS_FILE"
    fi
    printf ']'
}
