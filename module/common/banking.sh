# shellcheck shell=sh disable=SC2034
# Vietnamese banking apps, and the checks their Android apps run on top of Play
# Integrity.
#
# The list is for reporting, not for hiding. SuSFS already hides from every
# non-su process, so a bank that is not listed here is covered all the same;
# what the list buys is a readiness line that names the app and what is still
# visible to it. Every package below was checked against its Play Store
# listing, and EXTRA_BANKING_APPS adds the ones that are missing.
#
# Nothing here is changed on the user's behalf. Turning off their developer
# options or debugging is their call, and a module that flips those behind
# their back breaks their tooling to satisfy a check that may not even be the
# one failing.

BANKING_APPS="com.vcb vn.com.techcombank.bb.app com.mbmobile vn.com.bidv.direct vn.com.bidv.softotp com.vietinbank.ipay com.vnpay.vpbankonline com.tpb.mb.gprsandroid"

BANKING_COUNT=0
BANKING_NAMES=
BANKING_RISKS=
BANKING_MANAGER=

banking_label() {
    case "$1" in
        com.vcb) printf 'Vietcombank' ;;
        vn.com.techcombank.bb.app) printf 'Techcombank' ;;
        com.mbmobile) printf 'MB Bank' ;;
        vn.com.bidv.direct) printf 'BIDV Direct' ;;
        vn.com.bidv.softotp) printf 'BIDV Smart OTP' ;;
        com.vietinbank.ipay) printf 'VietinBank iPay' ;;
        com.vnpay.vpbankonline) printf 'VPBank NEO' ;;
        com.tpb.mb.gprsandroid) printf 'TPBank Mobile' ;;
        *) printf '%s' "$1" ;;
    esac
}

banking_all() {
    printf '%s %s\n' "$BANKING_APPS" "${CFG_EXTRA_BANKING_APPS:-}"
}

# One package manager call serves both the bank list and the manager check.
# `pm` is authoritative; the data directories are the fallback for a context
# where the package manager is not answering yet.
list_packages() {
    packages=$(pm list packages 2>/dev/null | sed -n 's/^package://p')
    if [ -z "$packages" ]; then
        packages=$(ls -1 /data/data 2>/dev/null)
    fi
    printf '%s\n' "$packages"
}

banking_audit() {
    BANKING_COUNT=0
    BANKING_NAMES=
    BANKING_RISKS=
    BANKING_MANAGER=

    installed=$(list_packages)
    [ -n "$installed" ] || return 0

    for package in $(banking_all); do
        printf '%s\n' "$installed" | grep -qix -- "$package" || continue
        BANKING_COUNT=$((BANKING_COUNT + 1))
        BANKING_NAMES="${BANKING_NAMES:+$BANKING_NAMES|}$(banking_label "$package")"
    done
    [ "$BANKING_COUNT" -gt 0 ] || return 0

    if [ "$(settings get global development_settings_enabled 2>/dev/null)" = 1 ]; then
        banking_risk 'developer options on'
    fi
    if [ "$(settings get global adb_enabled 2>/dev/null)" = 1 ]; then
        banking_risk 'USB debugging on'
    fi
    if [ "$(settings get global adb_wifi_enabled 2>/dev/null)" = 1 ]; then
        banking_risk 'wireless debugging on'
    fi
    if [ "$(settings get secure mock_location 2>/dev/null)" = 1 ]; then
        banking_risk 'mock location allowed'
    fi
    if [ "$(getenforce 2>/dev/null)" = Permissive ]; then
        banking_risk 'SELinux permissive'
    fi
    for artifact in /data/local/tmp/frida-server /data/local/tmp/re.frida.server /data/local/tmp/frida; do
        if [ -e "$artifact" ]; then
            banking_risk "hooking tool at $artifact"
        fi
    done
    if [ -d /data/data/de.robv.android.xposed.installer ]; then
        banking_risk 'legacy Xposed installed'
    fi

    # PackageManager lists the manager like any other app, which no amount of
    # root hiding changes. Repackaging it under a random name is the fix.
    BANKING_MANAGER=$(printf '%s\n' "$installed" |
        grep -iE 'sukisu|kernelsu|magisk|apatch|lsposed|shamiko' | tr '\n' ' ')
    BANKING_MANAGER=$(printf '%s' "$BANKING_MANAGER" | sed 's/ *$//')
    if [ -n "$BANKING_MANAGER" ]; then
        banking_risk "manager app visible ($BANKING_MANAGER)"
    fi

    log_info "banking: $BANKING_COUNT app(s)${BANKING_RISKS:+; visible: $BANKING_RISKS}"
}

banking_risk() {
    BANKING_RISKS="${BANKING_RISKS:+$BANKING_RISKS; }$1"
}

banking_text() {
    if [ "$BANKING_COUNT" = 0 ]; then
        printf '  %-16s %s\n' "installed" "no known Vietnamese banking app"
        return 0
    fi
    printf '  %-16s %s\n' "installed" "$(printf '%s' "$BANKING_NAMES" | sed 's/|/, /g')"
    if [ -n "$BANKING_RISKS" ]; then
        printf '  %-16s %s\n' "still visible" "$BANKING_RISKS"
    else
        printf '  %-16s %s\n' "still visible" "nothing beyond the app's own checks"
    fi
}

banking_json() {
    printf '{"count":%s,"apps":[' "$BANKING_COUNT"
    first=1
    old_ifs=$IFS
    IFS='|'
    for name in $BANKING_NAMES; do
        [ -n "$name" ] || continue
        if [ "$first" = 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '"%s"' "$(json_escape "$name")"
    done
    IFS=$old_ifs
    printf '],"risks":"%s","manager":"%s"}' \
        "$(json_escape "$BANKING_RISKS")" "$(json_escape "$BANKING_MANAGER")"
}
