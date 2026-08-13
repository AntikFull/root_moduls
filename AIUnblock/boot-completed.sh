#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/lib/locales.sh" ] && . "$MODDIR/lib/locales.sh"
command -v apply_configured_locales >/dev/null 2>&1 && apply_configured_locales "$MODDIR"
[ -f "$MODDIR/lib/hosts.sh" ] && . "$MODDIR/lib/hosts.sh"
command -v verify_hosts_overlay >/dev/null 2>&1 && verify_hosts_overlay "$MODDIR"
touch "$MODDIR/.force_refresh" 2>/dev/null
exit 0
