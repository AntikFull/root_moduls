#!/system/bin/sh
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
sleep 1
reconcile_config_if_changed "inotify:$events:$child"
exit $?
