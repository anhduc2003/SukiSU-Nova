#!/usr/bin/env bash
# Builds the flashable NovaHide module zip.
#
# The zip is the deliverable: module.prop at the root, every boot script, the
# WebUI, and the recovery shim. The build validates the metadata, parses every
# shell script with the strictest `sh` available, runs ShellCheck when it is
# installed, and then checks the archive layout it just produced.

set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)
module=module
out=out

if [ ! -f "$module/module.prop" ]; then
    echo "build-module: $module/module.prop is missing" >&2
    exit 1
fi

prop() {
    sed -n "s/^$1=//p" "$module/module.prop" | head -n 1
}

id=$(prop id)
version=$(prop version)
code=$(prop versionCode)

case "$id" in
    ''|*[!a-zA-Z0-9._-]*)
        echo "build-module: invalid module id '$id'" >&2
        exit 1
        ;;
esac
if [ -z "$version" ]; then
    echo "build-module: module.prop has no version" >&2
    exit 1
fi
case "$code" in
    ''|*[!0-9]*)
        echo "build-module: versionCode must be numeric, got '$code'" >&2
        exit 1
        ;;
esac

mapfile -t scripts < <(find "$module" -type f -name '*.sh' | sort)
for file in "${scripts[@]}"; do
    sh -n "$file" || {
        echo "build-module: syntax error in $file" >&2
        exit 1
    }
done

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${scripts[@]}"
fi

mkdir -p "$out"
zipfile="$out/$id-$version.zip"
rm -f "$zipfile"
(
    cd "$module"
    zip -rXq "$root/$zipfile" . -x 'tests/*' -x '*.DS_Store' -x '*/.DS_Store'
)

for required in module.prop customize.sh post-fs-data.sh service.sh action.sh uninstall.sh \
    webroot/index.html META-INF/com/google/android/update-binary; do
    if ! unzip -Z1 "$zipfile" | grep -qx "$required"; then
        echo "build-module: $required is not at the root of $zipfile" >&2
        exit 1
    fi
done
if unzip -Z1 "$zipfile" | grep -q '^tests/'; then
    echo "build-module: the archive contains the test harness" >&2
    exit 1
fi

size=$(wc -c < "$zipfile" | tr -d ' ')
echo "build-module: $zipfile ($size bytes)"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$zipfile"
fi
