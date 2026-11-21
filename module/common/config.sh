# shellcheck shell=sh disable=SC2034
# Configuration: defaults, the on-disk file, and validation.
#
# The file is plain `KEY=value` so it can be edited with any text editor and
# read by a shell without a parser. Only the keys below are understood; an
# unknown key is ignored rather than treated as an error, so a config written
# by a newer version still boots an older one.

cfg_defaults() {
    CFG_PROFILE=auto
    CFG_MANAGE_FEATURES=1
    CFG_HARDEN_PROPS=1
    CFG_CONFIGURE_COMPANIONS=1
    CFG_HIDE_MAPS=1
    CFG_SPOOF_BOOTCONFIG=1
    CFG_STATUS_IN_DESCRIPTION=1
    CFG_SUSFS_KERNEL_LOG=0
    CFG_EXTRA_BANKING_APPS=
}

cfg_load() {
    cfg_defaults
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            key=$(printf '%s' "$key" | tr -d ' \t\r')
            value=$(printf '%s' "$value" | tr -d ' \t\r')
            case "$key" in
                ''|'#'*) continue ;;
                PROFILE) CFG_PROFILE=$value ;;
                MANAGE_FEATURES) CFG_MANAGE_FEATURES=$value ;;
                HARDEN_PROPS) CFG_HARDEN_PROPS=$value ;;
                CONFIGURE_COMPANIONS) CFG_CONFIGURE_COMPANIONS=$value ;;
                HIDE_MAPS) CFG_HIDE_MAPS=$value ;;
                SPOOF_BOOTCONFIG) CFG_SPOOF_BOOTCONFIG=$value ;;
                STATUS_IN_DESCRIPTION) CFG_STATUS_IN_DESCRIPTION=$value ;;
                SUSFS_KERNEL_LOG) CFG_SUSFS_KERNEL_LOG=$value ;;
                EXTRA_BANKING_APPS) CFG_EXTRA_BANKING_APPS=$value ;;
            esac
        done < "$CONFIG_FILE"
    fi
    cfg_validate
}

# Coerce anything unexpected back to the default instead of letting a typo
# turn a hiding feature off silently. Each rejected value is logged once.
cfg_validate() {
    case "$CFG_PROFILE" in
        auto|off|light|balanced|aggressive) ;;
        *)
            log_warn "config: unknown PROFILE '$CFG_PROFILE', using auto"
            CFG_PROFILE=auto
            ;;
    esac
    CFG_MANAGE_FEATURES=$(cfg_flag "$CFG_MANAGE_FEATURES" MANAGE_FEATURES)
    CFG_HARDEN_PROPS=$(cfg_flag "$CFG_HARDEN_PROPS" HARDEN_PROPS)
    CFG_CONFIGURE_COMPANIONS=$(cfg_flag "$CFG_CONFIGURE_COMPANIONS" CONFIGURE_COMPANIONS)
    CFG_HIDE_MAPS=$(cfg_flag "$CFG_HIDE_MAPS" HIDE_MAPS)
    CFG_SPOOF_BOOTCONFIG=$(cfg_flag "$CFG_SPOOF_BOOTCONFIG" SPOOF_BOOTCONFIG)
    CFG_STATUS_IN_DESCRIPTION=$(cfg_flag "$CFG_STATUS_IN_DESCRIPTION" STATUS_IN_DESCRIPTION)
    CFG_SUSFS_KERNEL_LOG=$(cfg_flag "$CFG_SUSFS_KERNEL_LOG" SUSFS_KERNEL_LOG)
    # Only package-name characters survive, so a stray quote in the file
    # cannot turn into an argument to anything.
    CFG_EXTRA_BANKING_APPS=$(printf '%s' "$CFG_EXTRA_BANKING_APPS" | tr ',' ' ' | tr -cd 'A-Za-z0-9._ \n')
}

cfg_flag() {
    case "$1" in
        0|1) printf '%s' "$1" ;;
        *)
            log_warn "config: $2 must be 0 or 1, using 1"
            printf '1'
            ;;
    esac
}

# Write the documented default file. Existing files are never overwritten, so
# upgrading the module keeps the user's choices.
cfg_write_default() {
    [ -f "$CONFIG_FILE" ] && return 0
    mkdir -p "$DATA_DIR" 2>/dev/null
    cat > "$CONFIG_FILE" <<'EOF'
# NovaHide configuration.
#
# PROFILE picks the SuSFS hide pack applied at boot:
#   auto       follow the detected device (OnePlus Ace 5 -> aggressive)
#   off        apply nothing
#   light      KernelSU working dir, module stores, classic su paths
#   balanced   light + other root implementations and injection daemons
#   aggressive balanced + the whole /data/adb tree
# It controls path hiding only. Props, kernel features and companion modules
# are switched on by the flags below.
PROFILE=auto

# Own the kernel hiding features and enable them: selinux_hide, avc_spoof,
# mount_hide. Declaring them stops ksud's own feature init from resetting them.
MANAGE_FEATURES=1

# Sanitise the bootloader/verified-boot properties detectors read.
HARDEN_PROPS=1

# Configure the hiding modules that are installed (TrickyStore targets,
# PlayIntegrityFix and keybox detection, Shamiko mode, Zygisk conflicts).
CONFIGURE_COMPANIONS=1

# Hide the Zygisk payloads from /proc/<pid>/maps with sus_map.
HIDE_MAPS=1

# Serve a sanitised /proc/bootconfig through SuSFS. Off only if a detector on
# this ROM trusts the real file more than it trusts the properties.
SPOOF_BOOTCONFIG=1

# Rewrite module.prop's description with the last run's summary, so the
# manager's module list shows the state without opening anything.
STATUS_IN_DESCRIPTION=1

# SuSFS logs every operation to the kernel log, where a process that can read
# dmesg sees the hides being registered. 1 turns the log back on for debugging.
SUSFS_KERNEL_LOG=0

# Banking apps this module does not know, space or comma separated. The list is
# only used by the report: hiding applies to every app either way.
EXTRA_BANKING_APPS=
EOF
    chmod 0644 "$CONFIG_FILE"
    chown 0:0 "$CONFIG_FILE" 2>/dev/null
}

# Rewrite one key in place, keeping comments and ordering; a key that is not
# present is appended. Used when a profile is picked from the action or the
# WebUI, so the config stays the file that describes the boot behaviour.
cfg_set() {
    key=$1
    value=$2
    [ -f "$CONFIG_FILE" ] || cfg_write_default
    tmp=$CONFIG_FILE.tmp
    if awk -v key="$key" -v value="$value" '
        BEGIN { done = 0 }
        $0 ~ "^" key "=" {
            if (!done) {
                print key "=" value
                done = 1
                next
            }
        }
        { print }
        END { if (!done) print key "=" value }
    ' "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CONFIG_FILE"
        chmod 0644 "$CONFIG_FILE" 2>/dev/null
        chown 0:0 "$CONFIG_FILE" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
        log_warn "config: could not write $key"
    fi
}
