#!/system/bin/sh
# inotifyd event handler: EVENTS WATCHED_PATH [CHILD]
MODDIR=${0%/*}
. "$MODDIR/common.sh"

log "APP-FS event=${1:-?} path=${2:-?} child=${3:-?}"
# PackageManager registration can lag behind /data/app filesystem changes.
sleep 2
rescan_changed_packages
