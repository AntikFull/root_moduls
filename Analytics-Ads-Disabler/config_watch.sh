#!/system/bin/sh
# Hash polling safety net for config changes + package polling fallback.
# Realtime config events are handled by config_event.sh when inotifyd exists.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

ensure_capability_profile >/dev/null 2>&1
load_capabilities
log "config_watch started pid=$$ app_watch=${CAP_APP_WATCH_BACKEND:-polling} config_inotify=$([ -f "$CONFIG_INOTIFY_PID_FILE" ] && echo yes || echo no)"
[ -f "$CACHE_ADS" ] || read_category_list ADS > "$CACHE_ADS"
[ -f "$CACHE_ANALYTICS" ] || read_category_list ANALYTICS > "$CACHE_ANALYTICS"
[ -f "$CACHE_GLOBAL" ] || read_global_list > "$CACHE_GLOBAL"
[ -f "$CONFIG_HASH_FILE" ] || compute_config_hash > "$CONFIG_HASH_FILE"
[ -f "$BASE_POLICY_HASH_FILE" ] || compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"

package_elapsed=0
while true; do
    interval=$(read_poll_interval)

    # Safety net: catches missed/overflowed inotify events and works on devices
    # without inotifyd. The helper re-checks under lock, so this cannot duplicate
    # a reconciliation already completed by the realtime watcher.
    current_hash=$(compute_config_hash)
    previous_hash=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)
    if [ "$current_hash" != "$previous_hash" ]; then
        reconcile_config_if_changed "hash-poll"
        package_elapsed=0
    fi

    package_elapsed=$((package_elapsed + interval))
    if [ "${CAP_APP_WATCH_BACKEND:-polling}" = "inotifyd" ]; then
        package_due=$(read_package_safety_poll_interval)
    else
        package_due=$(read_package_poll_interval)
    fi

    if [ "$package_elapsed" -ge "$package_due" ] 2>/dev/null; then
        log "PACKAGE-POLL backend=${CAP_APP_WATCH_BACKEND:-polling} interval=${package_due}s"
        rescan_changed_packages
        package_elapsed=0
    fi

    sleep "$interval"
done
