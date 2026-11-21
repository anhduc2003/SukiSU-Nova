#!/system/bin/sh
# shellcheck disable=SC1090,SC1091
# NovaHide installer.
#
# This file is sourced by ksud's install_module(), not executed, so it must
# never call exit: abort() is the only way out and it also cleans up the
# staging directory.

MODDIR=$MODPATH
. "$MODDIR/common/module.sh"

ui_print " "
ui_print "- NovaHide $(module_version)"

if [ ! -x /data/adb/ksud ]; then
    abort "! NovaHide needs SukiSU Nova's ksud at /data/adb/ksud"
fi
if ! /data/adb/ksud hide status >/dev/null 2>&1; then
    abort "! This ksud has no built-in hide packs. Update SukiSU Nova, then flash again."
fi

log_init
detect_all

ui_print "- Device: $DEVICE_LABEL (${DEVICE_CODENAME:-unknown})"
ui_print "- Default profile: $DEVICE_PROFILE"
if [ "$SUSFS_AVAILABLE" = 1 ]; then
    ui_print "- SuSFS: $SUSFS_VERSION ($SUSFS_IMPLEMENTATION, $SUSFS_VARIANT)"
else
    ui_print "! No SuSFS in the running kernel: path hiding will not work."
    ui_print "! Flash a kernel with SuSFS, or this module can only fix props and features."
fi

cfg_write_default
ui_print "- Config: $CONFIG_FILE"

declare_features
ui_print "- Owning kernel features: $FEATURES"

collect_companions read
ui_print "- Hiding modules found:"
companions_text | while read -r line; do
    ui_print "  $line"
done

# Nothing in this module is ever mounted: an unmounted module has no mount to
# filter out of /proc/mounts in the first place.
: > "$MODPATH/skip_mount"

for script in post-fs-data.sh service.sh boot-completed.sh action.sh uninstall.sh; do
    [ -f "$MODPATH/$script" ] && chmod 0755 "$MODPATH/$script"
done
chmod 0755 "$MODPATH/common/"*.sh 2>/dev/null
chmod 0755 "$MODPATH"

ui_print " "
ui_print "- The first pass runs at the next boot."
ui_print "- Or tap this module's action button now to apply it immediately."
ui_print " "
