# shellcheck shell=sh disable=SC2034
# Paths shared by every entry script.
#
# Everything NovaHide keeps lives under /data/adb/novahide, so the aggressive
# hide profile covers the module's own state along with the rest of the root
# artifacts and there is nothing extra for a detector to find here.

NOVAHIDE_ID=novahide
KSUD=/data/adb/ksud
ADB_DIR=/data/adb
DATA_DIR=$ADB_DIR/novahide
CONFIG_FILE=$DATA_DIR/config.conf
LOG_FILE=$DATA_DIR/novahide.log
STATUS_FILE=$DATA_DIR/status.txt
STATE_FILE=$DATA_DIR/last-apply
COMPANIONS_FILE=$DATA_DIR/companions.txt
CONFLICTS_FILE=$DATA_DIR/conflicts.txt
DISABLED_LIST=$DATA_DIR/disabled.list
MODULE_PROP=$MODDIR/module.prop

# Version from module.prop, so the scripts never carry a second copy of it.
module_version() {
    version=$(sed -n 's/^version=//p' "$MODULE_PROP" 2>/dev/null | head -n 1)
    printf '%s' "${version:-unknown}"
}
