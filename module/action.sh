#!/system/bin/sh
# shellcheck disable=SC1090,SC1091
# Module action button and the WebUI backend.
#
#   action.sh                     apply, then print the report
#   action.sh apply [profile]     apply and store a profile (`auto` clears it)
#   action.sh status              read-only report
#   action.sh json                read-only report as one JSON line
#   action.sh keybox <base64>     validate and install an uploaded keybox.xml
#   action.sh log [lines]         tail of the module log
#   action.sh purge               delete the logs, status and cached state
#   action.sh reset               restore the default config
#
# The manager runs the script with no argument, which is why the default is a
# full apply: one tap on the module's action button should fix a device, not
# just describe it.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$MODDIR/common/module.sh"

# Every run reports success — a failed apply is a report, not a crash — but
# the keybox upload is a request whose refusal the WebUI shows, so its
# verdict is the one exit code that propagates.
keybox_status=0

case "${1:-apply}" in
    apply)
        apply_all "${2:-}"
        report_text
        ;;
    status)
        collect_live
        report_text
        ;;
    json)
        collect_live
        report_json
        ;;
    keybox)
        keybox_install "${2:-}" || keybox_status=1
        ;;
    log)
        lines=${2:-60}
        case "$lines" in
            ''|*[!0-9]*) lines=60 ;;
        esac
        if [ -f "$LOG_FILE" ]; then
            tail -n "$lines" "$LOG_FILE"
        else
            printf 'no log yet: %s\n' "$LOG_FILE"
        fi
        ;;
    purge)
        rm -f "$LOG_FILE" "$LOG_FILE.1" "$STATUS_FILE" "$STATE_FILE" "$COMPANIONS_FILE" \
            "$CONFLICTS_FILE" \
            "$DATA_DIR/bootconfig.orig" "$DATA_DIR/bootconfig.fake" \
            "$DATA_DIR/maps.list" "$DATA_DIR/target.txt.keep" "$DATA_DIR/target.txt.tmp"
        disabled_list_prune
        printf 'module traces removed from %s (config kept)\n' "$DATA_DIR"
        ;;
    reset)
        rm -f "$CONFIG_FILE"
        cfg_defaults
        cfg_write_default
        printf 'config reset to defaults: %s\n' "$CONFIG_FILE"
        ;;
    *)
        printf 'usage: action.sh [apply [auto|off|light|balanced|aggressive]|status|json|log [lines]|purge|reset|keybox <base64>]\n'
        exit 2
        ;;
esac

exit "$keybox_status"
