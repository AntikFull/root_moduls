#!/system/bin/sh
MODDIR=${0%/*}
events=${1:-?}
watched=${2:-?}
child=${3:-}

case "$child" in
    settings.conf|rules.user.conf|rules.vendor.conf|whitelist.list|white_ads.list|white_analytics.list|smart_reward.list|qa_targets.list) ;;
    *) exit 0 ;;
esac

. "$MODDIR/common.sh"

log "CONFIG-FS event=$events file=$child"
sleep 1
reconcile_config_if_changed "inotify:$events:$child"
exit $?
