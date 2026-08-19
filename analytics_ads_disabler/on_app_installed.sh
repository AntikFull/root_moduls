#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

log "APP-FS event=${1:-?} path=${2:-?} child=${3:-?}"

APP_EVENT_MARKER="$DATA_DIR/.app_event.pending"
APP_EVENT_LOCK="$DATA_DIR/.app_event.lock"
APP_EVENT_SETTLE=6

: > "$APP_EVENT_MARKER" 2>/dev/null

if ! mkdir "$APP_EVENT_LOCK" 2>/dev/null; then
    if aad_lock_owner_alive "$APP_EVENT_LOCK"; then
        owner=$(cat "$APP_EVENT_LOCK/pid" 2>/dev/null)
        log "APP-FS coalesced into pending rescan owner=$owner"
        exit 0
    fi
    rm -rf "$APP_EVENT_LOCK" 2>/dev/null
    mkdir "$APP_EVENT_LOCK" 2>/dev/null || exit 0
fi
aad_lock_write_owner "$APP_EVENT_LOCK"

cleanup_app_event() {
    rm -rf "$APP_EVENT_LOCK" 2>/dev/null
}
trap cleanup_app_event EXIT

rounds=0
while [ "$rounds" -lt 10 ]; do
    rm -f "$APP_EVENT_MARKER" 2>/dev/null
    sleep "$APP_EVENT_SETTLE"
    [ -f "$APP_EVENT_MARKER" ] || break
    rounds=$((rounds + 1))
done

log "APP-FS settled after ${rounds} extra burst round(s); reconciling packages."
# A package filesystem event while system apps are excluded may represent an
# updated/new system package that the third-party delta inventory cannot see.
# Conservatively downgrade ALL coverage so a later SYSTEM=ON performs a
# system-only expansion instead of trusting stale system discovery.
if [ "$(read_include_system_apps)" != "1" ] && [ "$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)" = "ALL" ]; then
    echo USER > "$CANDIDATE_SCOPE_FILE" 2>/dev/null || true
    log "CANDIDATE-SCOPE downgraded ALL->USER after package fs event while system scope is OFF"
fi
rescan_changed_packages
