#!/system/bin/sh
MODDIR=${0%/*}
exec "$MODDIR/config_watch.sh" "$@"
