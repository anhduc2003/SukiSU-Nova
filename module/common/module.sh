# shellcheck shell=sh disable=SC1090,SC1091,SC2034
# Every helper, in dependency order.
#
# The entry scripts set MODDIR from their own path and then source this one
# file, so a helper never has to guess where the module lives.

. "$MODDIR/common/paths.sh"
. "$MODDIR/common/log.sh"
. "$MODDIR/common/config.sh"
. "$MODDIR/common/props.sh"
. "$MODDIR/common/detect.sh"
. "$MODDIR/common/features.sh"
. "$MODDIR/common/companions.sh"
. "$MODDIR/common/report.sh"
. "$MODDIR/common/apply.sh"
