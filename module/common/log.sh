# shellcheck shell=sh disable=SC2034
# Logging.
#
# Boot scripts have no stdout anyone reads, so every line lands in
# /data/adb/novahide/novahide.log. The file is rotated once it passes 256 KiB:
# a module that logs on every boot must not grow without bound on a device
# nobody logs into.

NOVAHIDE_LOG_READY=
NOVAHIDE_ECHO=

log_init() {
    mkdir -p "$DATA_DIR" 2>/dev/null
    if [ -f "$LOG_FILE" ]; then
        size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        if [ "${size:-0}" -gt 262144 ]; then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
        fi
    fi
    NOVAHIDE_LOG_READY=1
}

log_line() {
    [ -n "$NOVAHIDE_LOG_READY" ] || log_init
    printf '%s %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
    if [ -n "$NOVAHIDE_ECHO" ]; then
        printf '%s\n' "$2"
    fi
}

log_info() {
    log_line INFO "$1"
}

log_warn() {
    log_line WARN "$1"
}

log_error() {
    log_line ERROR "$1"
}

# Echo a line into the log without the timestamp prefix, for captured tool
# output that already carries its own formatting.
log_raw() {
    [ -n "$NOVAHIDE_LOG_READY" ] || log_init
    printf '%s\n' "$1" >> "$LOG_FILE"
}
