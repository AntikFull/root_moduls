#!/system/bin/sh
umask 077
MODDIR=${0%/*}
mkdir -p "$MODDIR/run" 2>/dev/null
chmod 0700 "$MODDIR/run" 2>/dev/null || true
: > "$MODDIR/run/network-event.flag"
exit 0
