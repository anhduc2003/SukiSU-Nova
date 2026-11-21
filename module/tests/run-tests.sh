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
                printf 'hide: %s — 12 applied, 1 skipped\n' "${1:-aggressive}"
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
            add-sus-path|add-sus-map|set-cmdline-or-bootconfig|hide-sus-mnts-for-non-su-procs)
                [ -n "${NOVAHIDE_TEST_FAIL_SUSFS:-}" ] && exit 1
                ;;
        esac
        ;;
    feature)
        sub=$1
        case "$sub" in
            check) printf 'supported\n' ;;
            set) [ -n "${NOVAHIDE_TEST_FAIL_FEATURE:-}" ] && exit 1 ;;
            get) printf '1\n' ;;
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

chmod 0755 "$STUB_BIN/getprop" /data/adb/ksud

# Companion modules: TrickyStore with one target and one mode suffix, a
# PlayIntegrityFix install, and a Zygisk Next install that conflicts with the
# built-in Zygisk.
mkdir -p /data/adb/tricky_store /data/adb/modules/playintegrityfix /data/adb/zygisksu
printf 'com.example.bank\ncom.example.game!\n' > /data/adb/tricky_store/target.txt
mkdir -p /data/adb/ksu/zygisk/lib64
: > /data/adb/ksu/.builtin_zygisk
: > /data/adb/ksu/zygisk/lib64/libzygisk.so

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

echo "== service"
run_script service.sh service
assert_eq "service exits 0" "$?" "0"
assert_contains "the module state is hidden explicitly" "$CALLS" "susfs add-sus-path /data/adb/novahide"
assert_contains "SUS mounts are hidden per process" "$CALLS" "susfs hide-sus-mnts-for-non-su-procs 1"
assert_contains "the zygisk payload map is hidden" "$CALLS" "susfs add-sus-map /data/adb/ksu/zygisk/lib64/libzygisk.so"
assert_contains "TrickyStore gets the attestation targets" /data/adb/tricky_store/target.txt "com.google.android.gms"
assert_contains "TrickyStore gets the Play Store target" /data/adb/tricky_store/target.txt "com.android.vending"
assert_contains "the user's own target survives" /data/adb/tricky_store/target.txt "com.example.bank"
assert_contains "a per-target mode suffix survives" /data/adb/tricky_store/target.txt "com.example.game!"
assert_ok test -f /data/adb/novahide/status.txt
assert_contains "the report has a verdict" /data/adb/novahide/status.txt "BASIC"
assert_contains "the report names the device" /data/adb/novahide/status.txt "OnePlus Ace 5"
assert_contains "the description carries the summary" "$MODDIR/module.prop" "description=NovaHide v1.0.0 | aggressive | 12 hidden"
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
run_script action.sh action-status status
assert_eq "action status exits 0" "$?" "0"
assert_contains "status prints the verdict" "$OUT/action-status.log" "STRONG"
run_script action.sh action-log log 5
assert_eq "action log exits 0" "$?" "0"

echo "== profile"
: > "$CALLS"
run_script action.sh action-profile apply aggressive
assert_contains "an explicit profile is stored" "$CALLS" "susfs config set hide_profile aggressive"
: > "$CALLS"
run_script action.sh action-auto apply auto
assert_contains "auto clears the stored profile" "$CALLS" "susfs config remove hide_profile"
assert_contains "auto falls back to the device profile" "$OUT/action-auto.log" "aggressive (device)"

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

echo "== uninstall"
run_script uninstall.sh uninstall
assert_eq "uninstall exits 0" "$?" "0"
assert_ok test ! -d /data/adb/novahide
assert_contains "feature ownership is released" "$CALLS" "module config delete manage.selinux_hide"

printf '\n%d checks, %d failed\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
