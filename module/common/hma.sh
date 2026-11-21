# shellcheck shell=sh disable=SC2034
# HMA-OSS (frknkrc44's Hide My Applist fork) integration.
#
# HMA hides apps from other apps' PackageManager queries; on its own it
# needs every target app configured by hand in its manager. Its daemon,
# since the oss-164 release, watches its config.json and reloads it when
# something rewrites the file, so NovaHide can keep it current: it builds a
# template that hides the root manager and hooking apps, and applies that
# template to the apps that check root - the installed banks and the extra
# packages in HMA_TARGET_APPS.
#
# The config is a single compact JSON line written by kotlinx.serialization
# (encodeDefaults, ignoreUnknownKeys). The merge is string surgery with hard
# guards: anything that does not look exactly like that format is left alone
# and reported, because a file the daemon cannot parse after a reboot costs
# the user every HMA rule they made. A backup of the first edit stays beside
# the file for manual recovery.

HMA_TEMPLATE=NovaHide
HMA_PRESENT=0
HMA_CONFIGURED=0
HMA_NOTE=

hma_data_dir() {
    dir=$(find /data/misc -maxdepth 1 -name 'hide_my_applist_*' 2>/dev/null | head -n 1)
    printf '%s' "${dir:-}"
}

# Everything the target apps must not see: the manager and hooking apps,
# found with the same pattern the banking audit uses.
hma_hidden_packages() {
    list_packages | grep -iE 'sukisu|kernelsu|magisk|apatch|lsposed|shamiko|frida|xposed' |
        tr '\n' ' ' | sed 's/ *$//'
}

hma_targets() {
    installed=$(list_packages)
    printf '%s %s\n' "$(banking_all)" "${CFG_HMA_TARGET_APPS:-}" |
        tr ' ' '\n' | sed '/^$/d' | sort -u |
        while IFS= read -r package; do
            [ -n "$installed" ] || continue
            printf '%s\n' "$installed" | grep -qix -- "$package" && printf '%s\n' "$package"
        done
}

# A JSON string array from a newline list; the inputs are already sanitized
# to package-name characters.
hma_json_array() {
    first=1
    printf '['
    for item in "$@"; do
        [ -n "$item" ] || continue
        if [ "$first" = 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '"%s"' "$(json_escape "$item")"
    done
    printf ']'
}

hma_scope_entry() {
    printf '{"useWhitelist":false,"excludeSystemApps":true,"applyTemplates":["%s"]}' "$HMA_TEMPLATE"
}

# Merge the NovaHide template and the target scope entries into the config.
# Every step is guarded; the first surprise stops the merge with a reason.
hma_merge() {
    file=$1
    config=$(cat "$file") || return 1

    case "$config" in
        '{'*'}') ;;
        *)
            HMA_NOTE="its config is not a JSON object"
            return 1
            ;;
    esac
    case "$config" in
        *'"templates":{'*) ;;
        *)
            HMA_NOTE="no templates section"
            return 1
            ;;
    esac
    case "$config" in
        *'"scope":{'*) ;;
        *)
            HMA_NOTE="no scope section"
            return 1
            ;;
    esac

    hidden=$(hma_hidden_packages)
    # shellcheck disable=SC2086
    hidden_json=$(hma_json_array $hidden)

    # Replace our own template if a previous pass wrote it, else add it. A
    # template value holds no nested braces, so the pattern cannot overrun.
    # An empty map must not gain a trailing comma, so the insert differs by
    # whether anything is already in it.
    template_json="\"$HMA_TEMPLATE\":{\"isWhitelist\":false,\"appList\":$hidden_json}"
    case "$config" in
        *"\"$HMA_TEMPLATE\":{"*)
            config=$(printf '%s' "$config" |
                sed "s/\"$HMA_TEMPLATE\":{\"isWhitelist\":[a-z]*,\"appList\":\[[^]]*\]}/$template_json/")
            ;;
        *'"templates":{}}'*|*'"templates":{},'*)
            config=$(printf '%s' "$config" |
                sed "s/\"templates\":{}/\"templates\":{$template_json}/")
            ;;
        *)
            config=$(printf '%s' "$config" |
                sed "s/\"templates\":{/\"templates\":{$template_json,/")
            ;;
    esac

    # Only apps that are actually installed, so HMA never holds rules for
    # banks the user does not have. Each unscoped one takes a minimal entry;
    # one the user configured themselves is kept exactly as they set it.
    for package in $(hma_targets); do
        case "$config" in
            *"\"$package\":{"*) continue ;;
        esac
        entry="{\"useWhitelist\":false,\"excludeSystemApps\":true,\"applyTemplates\":[\"$HMA_TEMPLATE\"]}"
        case "$config" in
            *'"scope":{}'*)
                config=$(printf '%s' "$config" |
                    sed "s/\"scope\":{}/\"scope\":{\"$package\":$entry}/")
                ;;
            *)
                config=$(printf '%s' "$config" |
                    sed "s/}}\$/,\"$package\":$entry}}/")
                ;;
        esac
    done

    # The count that matters is how many of the installed targets the merged
    # config now covers, not how many this pass happened to add.
    HMA_CONFIGURED=0
    for package in $(hma_targets); do
        case "$config" in
            *"\"$package\":{"*) HMA_CONFIGURED=$((HMA_CONFIGURED + 1)) ;;
        esac
    done

    printf '%s\n' "$config"
}

hma_configure() {
    HMA_PRESENT=0
    HMA_CONFIGURED=0
    HMA_NOTE=

    dir=$(hma_data_dir)
    if [ -z "$dir" ]; then
        HMA_NOTE="installed but its daemon has not created data yet; open HMA once"
        return 0
    fi
    HMA_PRESENT=1
    file=$dir/config.json

    if [ ! -f "$file" ]; then
        # A fresh install: write a minimal config, which HMA parses with its
        # own defaults for everything else.
        hidden=$(hma_hidden_packages)
        # shellcheck disable=SC2086
    hidden_json=$(hma_json_array $hidden)
        printf '{"templates":{"%s":{"isWhitelist":false,"appList":%s}},"scope":{}}\n' \
            "$HMA_TEMPLATE" "$hidden_json" > "$file"
        HMA_NOTE="created a fresh config; reopen the HMA app to see it"
        log_info "hma: wrote a fresh config into $dir"
        return 0
    fi

    if [ "$(wc -l < "$file" | tr -d ' ')" -gt 1 ]; then
        HMA_NOTE="its config is not a single compact line; open HMA once and retry"
        log_warn "hma: $file is not the expected compact JSON, leaving it alone"
        return 0
    fi

    # The backup is the user's pre-NovaHide config: taken once, never
    # replaced, so a manual recovery can always go back to it.
    [ -f "$file.novahide-bak" ] || cp -f "$file" "$file.novahide-bak" 2>/dev/null
    if ! hma_merge "$file" > "$file.tmp"; then
        rm -f "$file.tmp"
        log_warn "hma: could not merge safely: $HMA_NOTE"
        return 0
    fi
    if ! mv -f "$file.tmp" "$file"; then
        rm -f "$file.tmp"
        HMA_NOTE="could not write the config"
        log_warn "hma: could not write $file"
        return 0
    fi
    chmod 0644 "$file" 2>/dev/null
    chown 0:0 "$file" 2>/dev/null
    HMA_NOTE="the NovaHide template is applied"
    log_info "hma: template covers $HMA_CONFIGURED installed app(s); the daemon reloads it live"
}

# Read-only peek for the status report.
hma_audit() {
    HMA_PRESENT=0
    HMA_CONFIGURED=0
    HMA_NOTE=

    dir=$(hma_data_dir)
    [ -n "$dir" ] || return 0
    HMA_PRESENT=1
    file=$dir/config.json
    [ -f "$file" ] || return 0
    if grep -q "\"$HMA_TEMPLATE\":{" "$file" 2>/dev/null; then
        for package in $(hma_targets); do
            case $(cat "$file" 2>/dev/null) in
                *"\"$package\":{"*) HMA_CONFIGURED=$((HMA_CONFIGURED + 1)) ;;
            esac
        done
        HMA_NOTE="the NovaHide template is applied"
    else
        HMA_NOTE="present; NovaHide has not configured it"
    fi
}

hma_text() {
    if [ "$CFG_AUTO_CONFIGURE_HMA" != 1 ]; then
        printf '  %-17s %s\n' "hma-oss" "auto-setup off; enable it in the WebUI"
        return 0
    fi
    if [ "$HMA_PRESENT" != 1 ]; then
        printf '  %-17s %s\n' "hma-oss" "not installed; nothing to configure"
        return 0
    fi
    printf '  %-17s %s\n' "hma-oss" "$HMA_NOTE ($HMA_CONFIGURED target app(s))"
}

hma_json() {
    present=false
    [ "$HMA_PRESENT" = 1 ] && present=true
    printf '{"auto":%s,"present":%s,"configured":%s,"note":"%s"}' \
        "$( [ "$CFG_AUTO_CONFIGURE_HMA" = 1 ] && printf true || printf false )" \
        "$present" "$HMA_CONFIGURED" "$(json_escape "$HMA_NOTE")"
}
