#!/system/bin/sh
# inotifyd event handler: EVENTS WATCHED_PATH [CHILD]
MODDIR=${0%/*}
. "$MODDIR/common.sh"

log "APP-FS event=${1:-?} path=${2:-?} child=${3:-?}"

# Installing or updating a single APK produces a burst of /data/app events
# (temp dir, split APKs, rename, oat files). Without a debounce each one spawned
# a full package rescan that then serialised on the global lock, so the queue
# could keep the device busy long after the install finished. Coalesce the burst
# into a single reconciliation: the first handler claims the window and rescans,
# later handlers within the window just refresh the request marker and exit.
APP_EVENT_MARKER="$DATA_DIR/.app_event.pending"
APP_EVENT_LOCK="$DATA_DIR/.app_event.lock"
APP_EVENT_SETTLE=6

: > "$APP_EVENT_MARKER" 2>/dev/null

if ! mkdir "$APP_EVENT_LOCK" 2>/dev/null; then
    owner=$(cat "$APP_EVENT_LOCK/pid" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        log "APP-FS coalesced into pending rescan owner=$owner"
        exit 0
    fi
    rm -rf "$APP_EVENT_LOCK" 2>/dev/null
    mkdir "$APP_EVENT_LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$APP_EVENT_LOCK/pid" 2>/dev/null

cleanup_app_event() {
    rm -rf "$APP_EVENT_LOCK" 2>/dev/null
}
trap cleanup_app_event EXIT

# Drain the burst: keep waiting while new events keep arriving, then rescan once.
rounds=0
while [ "$rounds" -lt 10 ]; do
    rm -f "$APP_EVENT_MARKER" 2>/dev/null
    sleep "$APP_EVENT_SETTLE"
    [ -f "$APP_EVENT_MARKER" ] || break
    rounds=$((rounds + 1))
done

log "APP-FS settled after ${rounds} extra burst round(s); reconciling packages."
rescan_changed_packages
