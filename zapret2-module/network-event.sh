#!/system/bin/sh
MODDIR=${0%/*}
mkdir -p "$MODDIR/run" 2>/dev/null
: > "$MODDIR/run/network-event.flag"
exit 0
