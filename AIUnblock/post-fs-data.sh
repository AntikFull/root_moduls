#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/lib/hosts.sh" ] || exit 0
. "$MODDIR/lib/hosts.sh"
prepare_hosts_tree "$MODDIR" || rm -rf "$MODDIR/system" 2>/dev/null
exit 0
