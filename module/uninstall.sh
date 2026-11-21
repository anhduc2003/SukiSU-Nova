#!/system/bin/sh
# Runs before ksud deletes the module directory.
#
# The properties and SuSFS paths this module set are kernel state and vanish on
# the next reboot, so nothing has to be undone there. What does have to go is
# the feature ownership: leaving `manage.*` behind would keep the kernel hiding
# features pinned with no module left to maintain them.

KSUD=/data/adb/ksud

for feature in selinux_hide avc_spoof mount_hide; do
    KSU_MODULE=novahide "$KSUD" module config delete "manage.$feature" >/dev/null 2>&1
done

rm -rf /data/adb/novahide

echo "NovaHide removed. Reboot to drop the properties and SuSFS paths it set."
