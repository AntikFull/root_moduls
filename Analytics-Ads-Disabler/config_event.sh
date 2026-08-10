#!/system/bin/sh
# BusyBox inotifyd callback: EVENTS WATCHED_PATH [CHILD]
# Watches only user-editable policy/config files inside DATA_DIR.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

events=${1:-?}
watched=${2:-?}
child=${3:-}

case "$child" in
    settings.conf|rules.conf|whitelist.list|white_ads.list|white_analytics.list) ;;
    *) exit 0 ;;
esac

log "CONFIG-FS event=$events file=$child"
# Editors may emit several events for a single save (write + rename).  A tiny
# settle delay lets the final file land; reconcile_config_if_changed re-checks
# the hash under the global operation lock and deduplicates the event burst.
sleep 1
reconcile_config_if_changed "inotify:$events:$child"
exit $?
