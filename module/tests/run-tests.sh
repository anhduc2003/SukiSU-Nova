#!/bin/sh
# shellcheck disable=SC1091,SC2269,SC2317,SC2329
# Behavioural test for NovaHide.
#
# The module addresses /data/adb by absolute path, so the only honest way to
# exercise it is to give it a /data of its own: this script runs inside a mount
# namespace, puts a tmpfs on /data, installs the module there, and replaces
# every external tool it calls with a stub that records its arguments.
#
#   sudo unshare -m sh module/tests/run-tests.sh
#
# Nothing outside the namespace is touched. Every assertion is about the calls
# the module makes and the files it leaves behind, which is what a real boot
# would produce.

set -u

[ "$(id -u)" = 0 ] || {
    echo "run-tests: needs root, use: sudo unshare -m sh $0" >&2
    exit 1
}

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MODDIR=/data/adb/modules/novahide
STUB_BIN=/data/adb/testbin
CALLS=/data/adb/ksud.calls
PROPS=/data/adb/props
OUT=/data/adb/test-output

failures=0
checks=0

pass() {
    checks=$((checks + 1))
    printf '  ok   %s\n' "$1"
}

fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf '  FAIL %s\n' "$1"
}

assert_ok() {
    if "$@" >/dev/null 2>&1; then pass "$*"; else fail "$*"; fi
}

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1: expected '$3', got '$2'"; fi
}

assert_contains() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        pass "$1"
    else
        fail "$1: '$3' not found in $2"
    fi
}

assert_count() {
    actual=$(grep -cF -- "$3" "$2" 2>/dev/null || true)
    if [ "${actual:-0}" = "$4" ]; then
        pass "$1 ($4)"
    else
        fail "$1: expected $4 occurrences of '$3' in $2, got ${actual:-0}"
    fi
}

# --- sandbox ---------------------------------------------------------------

# The namespace protects the host, but a /data with real content in it means
# this is not the sandbox it looks like: refuse rather than shadow it.
if [ -d /data/adb ] && [ -n "$(ls -A /data/adb 2>/dev/null)" ] && [ ! -f /data/adb/.novahide-test ]; then
    echo "run-tests: /data/adb already has content; refusing to shadow it" >&2
    exit 1
fi

mkdir -p /data
if ! grep -q ' /data ' /proc/mounts; then
    mount -t tmpfs tmpfs /data || {
        echo "run-tests: cannot mount a tmpfs on /data" >&2
        exit 1
    }
fi
mkdir -p /data/adb
: > /data/adb/.novahide-test
rm -rf "$OUT"
mkdir -p "$OUT" "$STUB_BIN"

mkdir -p "$MODDIR"
cp -a "$ROOT/module/." "$MODDIR"
rm -rf "$MODDIR/tests"
chmod 0755 "$MODDIR/post-fs-data.sh" "$MODDIR/service.sh" "$MODDIR/boot-completed.sh" \
    "$MODDIR/action.sh" "$MODDIR/uninstall.sh" "$MODDIR"/common/*.sh

# Property store the stubs share. These are the values an unlocked OnePlus Ace 5
# with root reports before the module runs.
cat > "$PROPS" <<'EOF'
ro.product.device=giulia
ro.product.model=PKG110
ro.boot.verifiedbootstate=orange
ro.boot.vbmeta.device_state=unlocked
ro.boot.flash.locked=0
ro.boot.veritymode=enforcing
ro.boot.warranty_bit=1
ro.warranty_bit=1
ro.debuggable=1
ro.secure=1
ro.adb.secure=1
ro.build.type=user
ro.build.tags=release-keys
ro.crypto.state=encrypted
EOF

cat > "$STUB_BIN/getprop" <<'EOF'
#!/bin/sh
value=$(grep "^$1=" /data/adb/props 2>/dev/null | tail -n 1 | cut -d= -f2-)
[ -n "$value" ] && printf '%s\n' "$value"
exit 0
EOF

cat > "$STUB_BIN/pm" <<'EOF'
#!/bin/sh
[ "$1" = list ] || exit 0
printf 'package:com.vcb\npackage:com.mbmobile\npackage:com.example.extra\npackage:com.example.extra2\npackage:com.sukisu.nova\npackage:com.android.settings\n'
EOF

cat > "$STUB_BIN/settings" <<'EOF'
#!/bin/sh
case "$2 $3" in
    'global development_settings_enabled') printf '1\n' ;;
    'global adb_enabled') printf '0\n' ;;
    *) printf 'null\n' ;;
esac
EOF

cat > "$STUB_BIN/getenforce" <<'EOF'
#!/bin/sh
printf 'Enforcing\n'
EOF

cat > /data/adb/ksud <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> /data/adb/ksud.calls
props=/data/adb/props
cmd=$1
[ $# -gt 0 ] && shift

case "$cmd" in
    hide)
        sub=$1
        case "$sub" in
            status)
                if [ -n "${NOVAHIDE_TEST_NO_SUSFS:-}" ]; then
                    printf 'susfs: unavailable\n'
                else
                    printf 'profile: %s (automatic)\n' "${NOVAHIDE_TEST_PROFILE:-aggressive}"
                    printf 'device: OnePlus Ace 5 (giulia)\n'
                    printf 'susfs: available\n'
                    printf 'entries: 12\n'
                fi
                ;;
            apply)
                if [ -n "${NOVAHIDE_TEST_FAIL_HIDE:-}" ]; then
                    printf 'hide: no SuSFS on this kernel\n'
                    exit 1
                fi
                profile=${1:-aggressive}
                if [ "$profile" = off ]; then
                    printf 'hide: off — 0 applied, 0 skipped\n'
                    exit 0
                fi
                if [ -n "${NOVAHIDE_TEST_KSUD_INTEGRATES:-}" ] && [ -f /data/adb/tricky_store/target.txt ]; then
                    grep -qx 'com.google.android.gms' /data/adb/tricky_store/target.txt ||
                        printf 'com.google.android.gms\ncom.android.vending\n' >> /data/adb/tricky_store/target.txt
                fi
                printf 'hide: %s — 12 applied, 1 skipped\n' "$profile"
                printf '  skipped /data/adb/zygisksu: not present\n'
                printf 'TrickyStore: target.txt already lists the attestation packages\n'
                ;;
        esac
        ;;
    susfs)
        sub=$1
        shift
        case "$sub" in
            status) [ -n "${NOVAHIDE_TEST_NO_SUSFS:-}" ] && printf 'false\n' || printf 'true\n' ;;
            version) printf 'v2.0.0\n' ;;
            variant) printf 'gki\n' ;;
            implementation) printf 'builtin\n' ;;
            features) printf 'SUSFS_SUS_PATH,SUSFS_SUS_MAP,SUSFS_SUS_MOUNT\n' ;;
            add-sus-path|add-sus-map|set-cmdline-or-bootconfig|hide-sus-mnts-for-non-su-procs|set-uname)
                [ -n "${NOVAHIDE_TEST_FAIL_SUSFS:-}" ] && exit 1
                ;;
        esac
        ;;
    feature)
        sub=$1
        case "$sub" in
            check) printf 'supported\n' ;;
            set) [ -n "${NOVAHIDE_TEST_FAIL_FEATURE:-}" ] && exit 1 ;;
            get)
                printf 'Feature: %s (4)\n' "$2"
                printf 'Description: test feature\n'
                printf 'Value: 1\n'
                ;;
        esac
        ;;
    zygisk) printf '{"state":"running","id":"builtin","name":"NyaZygisk","version":"1.0"}\n' ;;
    resetprop)
        flag=$1
        case "$flag" in
            -n)
                name=$2
                value=$3
                grep -v "^$name=" "$props" > "$props.tmp" 2>/dev/null
                printf '%s=%s\n' "$name" "$value" >> "$props.tmp"
                mv -f "$props.tmp" "$props"
                ;;
            -d)
                name=$2
                grep -v "^$name=" "$props" > "$props.tmp" 2>/dev/null
                mv -f "$props.tmp" "$props"
                ;;
            *)
                grep "^$1=" "$props" 2>/dev/null | tail -n 1 | cut -d= -f2-
                ;;
        esac
        ;;
esac
exit 0
EOF

chmod 0755 "$STUB_BIN/getprop" "$STUB_BIN/pm" "$STUB_BIN/settings" "$STUB_BIN/getenforce" /data/adb/ksud

# Companion modules: TrickyStore with one target and one mode suffix, a
# PlayIntegrityFix install, and a Zygisk Next install that conflicts with the
# built-in Zygisk.
mkdir -p /data/adb/tricky_store /data/adb/modules/playintegrityfix /data/adb/zygisksu
printf 'com.example.bank\ncom.example.game!\n' > /data/adb/tricky_store/target.txt
mkdir -p /data/adb/ksu/zygisk/lib64 /data/system/nyazygisk/lib64
: > /data/adb/ksu/.builtin_zygisk
: > /data/adb/ksu/zygisk/lib64/libzygisk.so
: > /data/system/nyazygisk/lib64/libzygisk.so

# A captured bootconfig with the values an unlocked device reports.
cat > /data/adb/test-bootconfig <<'EOF'
androidboot.hardware = qcom
androidboot.verifiedbootstate = orange
androidboot.vbmeta.device_state = unlocked
androidboot.flash.locked = 0
androidboot.veritymode = enforcing
EOF

run_script() {
    name=$1
    out=$2
    shift 2
    PATH=$STUB_BIN:$PATH KSU_VER=3.5.0 KSU_UAPI_VER=2 KSU=true \
        sh "$MODDIR/$name" "$@" > "$OUT/$out.log" 2>&1
}

echo "== install"
(
    MODPATH=$MODDIR
    BOOTMODE=true
    KSU=true
    export MODPATH BOOTMODE KSU
    ui_print() { printf '%s\n' "$1"; }
    abort() { printf 'ABORT: %s\n' "$1"; }
    . "$MODDIR/customize.sh"
) > "$OUT/customize.log" 2>&1
assert_contains "customize reports the device" "$OUT/customize.log" "OnePlus Ace 5 (giulia)"
assert_contains "customize reports the profile" "$OUT/customize.log" "aggressive"
assert_contains "customize writes the config" "$OUT/customize.log" "/data/adb/novahide/config.conf"
assert_ok test -f /data/adb/novahide/config.conf
assert_contains "customize declares feature ownership" "$CALLS" "module config set manage.selinux_hide true"
assert_contains "customize lists the companion modules" "$OUT/customize.log" "TrickyStore"

echo "== post-fs-data"
run_script post-fs-data.sh post-fs-data
assert_eq "post-fs-data exits 0" "$?" "0"
assert_contains "verified boot is green" "$PROPS" "ro.boot.verifiedbootstate=green"
assert_contains "vbmeta is locked" "$PROPS" "ro.boot.vbmeta.device_state=locked"
assert_contains "warranty bit is cleared" "$PROPS" "ro.boot.warranty_bit=0"
assert_contains "debuggable is off" "$PROPS" "ro.debuggable=0"
assert_contains "the hide pack is applied early" "$CALLS" "hide apply"
assert_contains "kernel features are enabled" "$CALLS" "feature set selinux_hide 1"
assert_contains "module mounts are unmounted for apps" "$CALLS" "feature set kernel_umount 1"

echo "== service"
run_script service.sh service
assert_eq "service exits 0" "$?" "0"
assert_contains "the module state is hidden explicitly" "$CALLS" "susfs add-sus-path /data/adb/novahide"
assert_contains "the module directory is hidden explicitly" "$CALLS" "susfs add-sus-path /data/adb/modules/novahide"
assert_not_contains "the zygisk runtime dir stays readable" "$CALLS" "add-sus-path /data/system/nyazygisk"
assert_contains "the SUSFS kernel log is turned off" "$CALLS" "susfs enable-log 0"
assert_contains "SUS mounts are hidden per process" "$CALLS" "susfs hide-sus-mnts-for-non-su-procs 1"
assert_contains "the staged payload map is hidden" "$CALLS" "susfs add-sus-map /data/adb/ksu/zygisk/lib64/libzygisk.so"
assert_contains "the runtime payload map is hidden" "$CALLS" "susfs add-sus-map /data/system/nyazygisk/lib64/libzygisk.so"
assert_contains "TrickyStore gets the attestation targets" /data/adb/tricky_store/target.txt "com.google.android.gms"
assert_contains "TrickyStore gets the Play Store target" /data/adb/tricky_store/target.txt "com.android.vending"
assert_contains "the user's own target survives" /data/adb/tricky_store/target.txt "com.example.bank"
assert_contains "a per-target mode suffix survives" /data/adb/tricky_store/target.txt "com.example.game!"
assert_ok test -f /data/adb/novahide/status.txt
assert_contains "the report has a verdict" /data/adb/novahide/status.txt "BASIC"
assert_contains "the report names the device" /data/adb/novahide/status.txt "OnePlus Ace 5"
version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)
assert_contains "the description carries the summary" "$MODDIR/module.prop" "description=NovaHide $version | aggressive | 12 hidden"
assert_contains "the report names an installed bank" /data/adb/novahide/status.txt "Vietcombank"
assert_contains "the report names the second bank" /data/adb/novahide/status.txt "MB Bank"
assert_contains "developer options are reported" /data/adb/novahide/status.txt "developer options on"
assert_contains "the manager package is reported" /data/adb/novahide/status.txt "manager app visible"
assert_contains "the report says mounts are hidden" /data/adb/novahide/status.txt "hidden from non-su processes"

echo "== bootconfig"
(
    . "$MODDIR/common/module.sh"
    log_init
    cfg_load
    BOOTCONFIG_SRC=/data/adb/test-bootconfig
    export BOOTCONFIG_SRC
    spoof_bootconfig
    printf 'state=%s\n' "$BOOTCONFIG_STATE"
) > "$OUT/bootconfig.log" 2>&1
assert_contains "the spoof is applied" "$OUT/bootconfig.log" "state=spoofed"
assert_contains "verified boot is flipped" /data/adb/novahide/bootconfig.fake "androidboot.verifiedbootstate = green"
assert_contains "vbmeta is flipped" /data/adb/novahide/bootconfig.fake "androidboot.vbmeta.device_state = locked"
assert_count "the bootconfig keeps its line count" /data/adb/novahide/bootconfig.fake "=" 5

echo "== boot-completed"
run_script boot-completed.sh boot-completed
assert_eq "boot-completed exits 0" "$?" "0"
assert_count "the second pass does not duplicate targets" /data/adb/tricky_store/target.txt "com.google.android.gms" 1

echo "== action"
run_script action.sh action-json json
assert_eq "action json exits 0" "$?" "0"
json=$(tail -n 1 "$OUT/action-json.log")
if printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "action json is valid JSON"
else
    fail "action json is not valid JSON: $json"
fi
assert_contains "the JSON reports the profile" "$OUT/action-json.log" '"profile":"aggressive"'
assert_contains "the JSON reports SuSFS" "$OUT/action-json.log" '"available":true'
assert_contains "the JSON carries the recorded apply" "$OUT/action-json.log" '"recorded":true'
assert_contains "the JSON carries the catalog size" "$OUT/action-json.log" '"entries":12'
assert_contains "the JSON carries the banking section" "$OUT/action-json.log" '"banking":{"count":2'
assert_contains "the JSON carries the manager package" "$OUT/action-json.log" 'com.sukisu.nova'
run_script action.sh action-status status
assert_eq "action status exits 0" "$?" "0"
assert_contains "status prints the verdict" "$OUT/action-status.log" "STRONG"
run_script action.sh action-log log 5
assert_eq "action log exits 0" "$?" "0"

echo "== profile"
: > "$CALLS"
run_script action.sh action-profile apply aggressive
assert_contains "an explicit profile is stored" "$CALLS" "susfs config set hide_profile aggressive"
assert_contains "the choice is written to the config" /data/adb/novahide/config.conf "PROFILE=aggressive"
: > "$CALLS"
run_script action.sh action-auto apply auto
assert_contains "auto clears the stored profile" "$CALLS" "susfs config remove hide_profile"
assert_contains "auto falls back to the device profile" "$OUT/action-auto.log" "aggressive (device)"
assert_contains "auto is written to the config" /data/adb/novahide/config.conf "PROFILE=auto"
: > "$CALLS"
sed -i 's/^PROFILE=auto$/PROFILE=light/' /data/adb/novahide/config.conf
run_script service.sh service-light
assert_contains "a configured profile is applied at boot" "$CALLS" "hide apply light"
sed -i 's/^PROFILE=light$/PROFILE=auto/' /data/adb/novahide/config.conf

echo "== profile off"
: > "$CALLS"
sed -i 's/^PROFILE=auto$/PROFILE=off/' /data/adb/novahide/config.conf
run_script service.sh service-off
assert_eq "off exits 0" "$?" "0"
assert_contains "off applies the empty pack" "$CALLS" "hide apply off"
assert_not_contains "off registers no extra paths" "$CALLS" "add-sus-path"
assert_not_contains "off hides no maps" "$CALLS" "add-sus-map"
assert_not_contains "off leaves the kernel log alone" "$CALLS" "enable-log"
sed -i 's/^PROFILE=off$/PROFILE=auto/' /data/adb/novahide/config.conf

echo "== companions opt-out"
printf 'com.example.bank\n' > /data/adb/tricky_store/target.txt
cp -f /data/adb/novahide/config.conf /data/adb/novahide/config.conf.keep
sed -i 's/^CONFIGURE_COMPANIONS=1$/CONFIGURE_COMPANIONS=0/' /data/adb/novahide/config.conf
NOVAHIDE_TEST_KSUD_INTEGRATES=1 run_script action.sh action-optout apply balanced
assert_eq "the opt-out run exits 0" "$?" "0"
assert_not_contains "the opt-out keeps target.txt untouched" /data/adb/tricky_store/target.txt "com.google.android.gms"
mv -f /data/adb/novahide/config.conf.keep /data/adb/novahide/config.conf

echo "== banking extras"
cp -f /data/adb/novahide/config.conf /data/adb/novahide/config.conf.keep
sed -i 's/^EXTRA_BANKING_APPS=.*$/EXTRA_BANKING_APPS=com.example.extra com.example.extra2/' /data/adb/novahide/config.conf
run_script action.sh action-banking status
assert_contains "an extra banking package is reported" "$OUT/action-banking.log" "com.example.extra"
assert_contains "a second space-separated extra is reported" "$OUT/action-banking.log" "com.example.extra2"
sed -i 's/^EXTRA_BANKING_APPS=.*$/EXTRA_BANKING_APPS=com.example.extra,com.example.extra2/' /data/adb/novahide/config.conf
run_script action.sh action-banking status
assert_contains "a comma-separated extra is reported" "$OUT/action-banking.log" "com.example.extra"
assert_contains "the second comma-separated extra is reported" "$OUT/action-banking.log" "com.example.extra2"
mv -f /data/adb/novahide/config.conf.keep /data/adb/novahide/config.conf

echo "== module conflicts"
run_script action.sh action-conflicts json
assert_contains "the double zygisk conflict is reported" "$OUT/action-conflicts.log" '{"severity":"high","name":"Zygisk twice"'
run_script action.sh action-conflicts-text status
assert_contains "the status text lists the conflict" "$OUT/action-conflicts-text.log" "Zygisk twice"
mkdir -p /data/adb/modules/pif /data/adb/modules/zygisknext
run_script action.sh action-conflicts-multi json
assert_contains "two active fingerprint modules conflict" "$OUT/action-conflicts-multi.log" '"name":"PIF twice"'
assert_ok test ! -f /data/adb/modules/zygisknext/disable
sed -i 's/^AUTO_DISABLE_CONFLICTS=0$/AUTO_DISABLE_CONFLICTS=1/' /data/adb/novahide/config.conf
run_script action.sh action-conflicts-fix apply balanced
assert_eq "the remediation run exits 0" "$?" "0"
assert_ok test -f /data/adb/modules/zygisknext/disable
assert_contains "the disabled module is logged" /data/adb/novahide/novahide.log "disabled /data/adb/modules/zygisknext"
run_script action.sh action-conflicts-pending json
assert_contains "the conflict stays reported while the module still runs" "$OUT/action-conflicts-pending.log" '"name":"Zygisk twice"'
assert_contains "the pending disable says so" "$OUT/action-conflicts-pending.log" "still runs this boot"
run_script action.sh action-conflicts-purge purge
assert_ok test -f /data/adb/novahide/disabled.list
run_script action.sh action-conflicts-kept json
assert_contains "the pending conflict survives purge" "$OUT/action-conflicts-kept.log" "still runs this boot"
rm -f /data/adb/modules/zygisknext/disable
run_script action.sh action-conflicts-undo apply balanced
assert_ok test ! -f /data/adb/modules/zygisknext/disable
assert_contains "the undo stands down to report-only" "$OUT/action-conflicts-undo.log" "keep one"
rm -f /data/adb/novahide/disabled.list
rm -rf /data/adb/modules/pif /data/adb/modules/zygisknext
sed -i 's/^AUTO_DISABLE_CONFLICTS=1$/AUTO_DISABLE_CONFLICTS=0/' /data/adb/novahide/config.conf

echo "== uname spoof"
: > "$CALLS"
run_script action.sh action-uname0 apply aggressive
assert_not_contains "an unconfigured kernel string is left alone" "$CALLS" "set-uname"
sed -i 's/^UNAME_RELEASE=$/UNAME_RELEASE=6.1.115-android14/' /data/adb/novahide/config.conf
: > "$CALLS"
run_script action.sh action-uname1 apply aggressive
assert_not_contains "a half-set kernel string does nothing" "$CALLS" "set-uname"
assert_contains "the half-set warning is logged" "$OUT/action-uname1.log" "set both UNAME_RELEASE and UNAME_VERSION"
sed -i 's/^UNAME_VERSION=$/UNAME_VERSION=#1 SMP PREEMPT Thu Jan 1 00:00:00 UTC 1970/' /data/adb/novahide/config.conf
: > "$CALLS"
run_script action.sh action-uname2 apply aggressive
assert_contains "the kernel string is spoofed with both values" "$CALLS" "susfs set-uname 6.1.115-android14 #1 SMP PREEMPT Thu Jan 1 00:00:00 UTC 1970"
assert_contains "the apply reports the spoof" "$OUT/action-uname2.log" "spoofed for non-su processes"
sed -i 's/^UNAME_RELEASE=6.1.115-android14$/UNAME_RELEASE=4.14.117-perf+/' /data/adb/novahide/config.conf
sed -i 's/^UNAME_VERSION=.*$/UNAME_VERSION=#1 SMP PREEMPT/' /data/adb/novahide/config.conf
: > "$CALLS"
run_script action.sh action-uname3 apply aggressive
assert_contains "a plus-signed release reaches the kernel" "$CALLS" "susfs set-uname 4.14.117-perf+ #1 SMP PREEMPT"
sed -i 's/^UNAME_RELEASE=4.14.117-perf+$/UNAME_RELEASE=4.14.117-perf+ (dropped)/' /data/adb/novahide/config.conf
: > "$CALLS"
run_script action.sh action-uname4 apply aggressive
assert_contains "a mangled release is logged" /data/adb/novahide/novahide.log "UNAME_RELEASE had characters removed"
sed -i 's/^UNAME_RELEASE=.*$/UNAME_RELEASE=/' /data/adb/novahide/config.conf
sed -i 's/^UNAME_VERSION=.*$/UNAME_VERSION=/' /data/adb/novahide/config.conf
run_script action.sh action-uname5 status
assert_contains "a cleared kernel string says it survives" "$OUT/action-uname5.log" "serves the last spoofed string until reboot"
run_script action.sh action-uname6 apply aggressive
assert_contains "an apply after clearing still reports the stale string" "$OUT/action-uname6.log" "serves the last spoofed string until reboot"
run_script action.sh action-uname6b apply aggressive
assert_contains "a second apply keeps the stale warning" "$OUT/action-uname6b.log" "serves the last spoofed string until reboot"
sed -i 's/^PROFILE=auto$/PROFILE=off/' /data/adb/novahide/config.conf
run_script action.sh action-uname-off apply off
if grep -q '^uname=stale:' /data/adb/novahide/last-apply; then
    pass "a profile-off pass preserves the stale record"
else
    fail "a profile-off pass erased the stale record"
fi
sed -i 's/^PROFILE=off$/PROFILE=auto/' /data/adb/novahide/config.conf
sed -i "s/^uname=.*/uname=stale:00000000-0000-0000-0000-000000000000/" /data/adb/novahide/last-apply
run_script action.sh action-uname6c status
assert_contains "a stale claim from an older boot is dropped" "$OUT/action-uname6c.log" "not configured"
assert_not_contains "no stale wording remains" "$OUT/action-uname6c.log" "serves the last spoofed string"
run_script action.sh action-uname7 status
assert_contains "the cleared config reports nothing held" "$OUT/action-uname7.log" "not configured"
sed -i 's/^UNAME_RELEASE=$/UNAME_RELEASE=6.1.115-android14/' /data/adb/novahide/config.conf
sed -i 's/^UNAME_VERSION=$/UNAME_VERSION=#1 SMP PREEMPT/' /data/adb/novahide/config.conf
: > "$CALLS"
NOVAHIDE_TEST_FAIL_SUSFS=1 run_script action.sh action-uname8 apply aggressive
assert_contains "a refused string is reported" "$OUT/action-uname8.log" "the kernel refused the string"
run_script action.sh action-uname8b status
assert_contains "the refusal is remembered in the status" "$OUT/action-uname8b.log" "configured; the kernel refused the string"
sed -i 's/^UNAME_RELEASE=.*$/UNAME_RELEASE=/' /data/adb/novahide/config.conf
sed -i 's/^UNAME_VERSION=.*$/UNAME_VERSION=/' /data/adb/novahide/config.conf

echo "== keybox upload"
cat > /data/adb/novahide/kb-test.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<keybox DeviceID="test-device">
  <Key algorithm="ecdsa">
    <PrivateKey format="pem">
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIIabc
-----END EC PRIVATE KEY-----
    </PrivateKey>
    <CertificateChain>
      <Certificate format="pem">
-----BEGIN CERTIFICATE-----
MIIBhTCCASsC
-----END CERTIFICATE-----
      </Certificate>
    </CertificateChain>
  </Key>
</keybox>
EOF
b64_valid=$(base64 -w0 /data/adb/novahide/kb-test.xml)
run_script action.sh action-keybox keybox "$b64_valid"
assert_eq "the keybox upload exits 0" "$?" "0"
assert_contains "the install is reported" "$OUT/action-keybox.log" "installed for TrickyStore"
assert_ok test -f /data/adb/tricky_store/keybox.xml
assert_eq "the file survives the round trip" \
    "$(wc -c < /data/adb/tricky_store/keybox.xml)" "$(wc -c < /data/adb/novahide/kb-test.xml)"
assert_eq "the installed keybox is mode 0600" "$(stat -c %a /data/adb/tricky_store/keybox.xml)" "600"
b64_bad=$(head -c 300 /dev/zero | base64 -w0)
run_script action.sh action-keybox-bad keybox "$b64_bad"
assert_eq "the invalid upload is refused" "$?" "1"
assert_contains "the refusal says why" "$OUT/action-keybox-bad.log" "no <keybox> root element"
assert_contains "the old keybox survives a refusal" /data/adb/tricky_store/keybox.xml "test-device"
mv /data/adb/tricky_store /data/adb/tricky_store.keep
run_script action.sh action-keybox-nostore keybox "$b64_valid"
assert_eq "the upload without TrickyStore is refused" "$?" "1"
assert_contains "the refusal names TrickyStore" "$OUT/action-keybox-nostore.log" "install TrickyStore first"
mv /data/adb/tricky_store.keep /data/adb/tricky_store
run_script action.sh action-keybox-status status
assert_contains "the status shows the keybox present" "$OUT/action-keybox-status.log" "keybox present"

echo "== hma-oss"
run_script action.sh action-hma0 status
assert_contains "an off HMA setup is reported" "$OUT/action-hma0.log" "auto-setup off"
sed -i 's/^AUTO_CONFIGURE_HMA=0$/AUTO_CONFIGURE_HMA=1/' /data/adb/novahide/config.conf
run_script action.sh action-hma0b status
assert_contains "an absent HMA is reported" "$OUT/action-hma0b.log" "not installed; nothing to configure"
sed -i 's/^AUTO_CONFIGURE_HMA=1$/AUTO_CONFIGURE_HMA=0/' /data/adb/novahide/config.conf
mkdir -p /data/misc/hide_my_applist_abcdefghijklmnop
printf '{"configVersion":5,"detailLog":false,"templates":{},"scope":{}}\n' > /data/misc/hide_my_applist_abcdefghijklmnop/config.json
: > "$CALLS"
sed -i 's/^AUTO_CONFIGURE_HMA=0$/AUTO_CONFIGURE_HMA=1/' /data/adb/novahide/config.conf
run_script action.sh action-hma1 apply aggressive
assert_contains "the boot pass configures HMA" "$CALLS" "hide apply aggressive"
if grep -q '"NovaHide":{"isWhitelist":false,"appList":\["com.sukisu.nova"\]}' \
    /data/misc/hide_my_applist_abcdefghijklmnop/config.json; then
    pass "the NovaHide template carries the manager package"
else
    fail "the NovaHide template is missing the manager package"
fi
if grep -q '"com.vcb":{"useWhitelist":false,"excludeSystemApps":true,"applyTemplates":\["NovaHide"\]}' \
    /data/misc/hide_my_applist_abcdefghijklmnop/config.json; then
    pass "the bank gets a scope entry"
else
    fail "the bank has no scope entry"
fi
if grep -q '"com.mbmobile"' /data/misc/hide_my_applist_abcdefghijklmnop/config.json; then
    pass "the second bank gets a scope entry"
else
    fail "the second bank has no scope entry"
fi
assert_contains "the status reports the setup" "$OUT/action-hma1.log" "the NovaHide template is applied"
printf '{"configVersion":5,"templates":{"Mine":{"isWhitelist":true,"appList":["com.a"]}},"scope":{"com.vcb":{"useWhitelist":true,"applyTemplates":["Mine"]}}}\n' > /data/misc/hide_my_applist_abcdefghijklmnop/config.json
run_script action.sh action-hma2 apply aggressive
if grep -q '"Mine":{"isWhitelist":true,"appList":\["com.a"\]}' \
    /data/misc/hide_my_applist_abcdefghijklmnop/config.json; then
    pass "the user's own template survives"
else
    fail "the user's own template was destroyed"
fi
if grep -q '"com.vcb":{"useWhitelist":true,"applyTemplates":\["Mine"\]}' \
    /data/misc/hide_my_applist_abcdefghijklmnop/config.json; then
    pass "the user's own scope entry survives"
else
    fail "the user's own scope entry was rewritten"
fi
sed -i 's/^AUTO_CONFIGURE_HMA=1$/AUTO_CONFIGURE_HMA=0/' /data/adb/novahide/config.conf
printf '{"configVersion":5,"templates":{},"scope":{}}\n' > /data/misc/hide_my_applist_abcdefghijklmnop/config.json
printf '{\n  "configVersion": 5\n}\n' > /data/misc/hide_my_applist_abcdefghijklmnop/config.json
sed -i 's/^AUTO_CONFIGURE_HMA=0$/AUTO_CONFIGURE_HMA=1/' /data/adb/novahide/config.conf
run_script action.sh action-hma3 apply aggressive
if grep -q '"NovaHide"' /data/misc/hide_my_applist_abcdefghijklmnop/config.json; then
    fail "a pretty-printed config was rewritten"
else
    pass "a pretty-printed config is left alone"
fi
assert_contains "the refusal is explained" "$OUT/action-hma3.log" "not a single compact line"
sed -i 's/^AUTO_CONFIGURE_HMA=1$/AUTO_CONFIGURE_HMA=0/' /data/adb/novahide/config.conf
rm -rf /data/misc/hide_my_applist_abcdefghijklmnop

echo "== disabled fingerprint"
: > /data/adb/modules/playintegrityfix/disable
run_script action.sh action-disabled status
assert_contains "a disabled provider is reported as off" "$OUT/action-disabled.log" "installed but switched off"
assert_not_contains "a disabled provider does not make DEVICE ready" "$OUT/action-disabled.log" "DEVICE  ready"
rm -f /data/adb/modules/playintegrityfix/disable

echo "== unverified status"
mv -f /data/adb/novahide/last-apply /data/adb/novahide/last-apply.keep
run_script action.sh action-unverified status
assert_contains "status without an apply says so" "$OUT/action-unverified.log" "no apply recorded"
assert_contains "the verdict does not claim readiness" "$OUT/action-unverified.log" "not verified"
mv -f /data/adb/novahide/last-apply.keep /data/adb/novahide/last-apply

echo "== failure paths"
: > "$CALLS"
NOVAHIDE_TEST_FAIL_SUSFS=1 run_script action.sh apply-balanced apply balanced
assert_eq "a refusing kernel still exits 0" "$?" "0"
assert_contains "the failure is logged" /data/adb/novahide/novahide.log "could not register"
assert_contains "a refused mount hide is reported" /data/adb/novahide/status.txt "not hidden"
NOVAHIDE_TEST_NO_SUSFS=1 run_script action.sh action-nosusfs status
assert_eq "a kernel without SuSFS still reports" "$?" "0"
assert_contains "the report says SuSFS is unavailable" "$OUT/action-nosusfs.log" "unavailable"

echo "== report"
cat /data/adb/novahide/status.txt
printf '\n'
tail -n 1 "$OUT/action-json.log"
printf '\n'

echo "== purge"
run_script action.sh action-purge purge
assert_eq "purge exits 0" "$?" "0"
assert_ok test ! -f /data/adb/novahide/novahide.log
assert_ok test ! -f /data/adb/novahide/status.txt
assert_ok test -f /data/adb/novahide/config.conf
assert_ok test -f /data/adb/tricky_store/keybox.xml

echo "== uninstall"
run_script uninstall.sh uninstall
assert_eq "uninstall exits 0" "$?" "0"
assert_ok test ! -d /data/adb/novahide
assert_contains "feature ownership is released" "$CALLS" "module config delete manage.selinux_hide"

printf '\n%d checks, %d failed\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
