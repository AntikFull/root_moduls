#!/system/bin/sh
# Watches configuration changes and provides package polling fallback/safety net.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

ensure_capability_profile >/dev/null 2>&1
load_capabilities
log "config_watch started pid=$$ app_watch=${CAP_APP_WATCH_BACKEND:-polling}"
[ -f "$CACHE_ADS" ] || read_category_list ADS > "$CACHE_ADS"
[ -f "$CACHE_ANALYTICS" ] || read_category_list ANALYTICS > "$CACHE_ANALYTICS"
[ -f "$CACHE_GLOBAL" ] || read_global_list > "$CACHE_GLOBAL"
[ -f "$CONFIG_HASH_FILE" ] || compute_config_hash > "$CONFIG_HASH_FILE"

package_elapsed=0
while true; do
    interval=$(read_poll_interval)
    current_hash=$(compute_config_hash)
    previous_hash=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)

    if [ "$current_hash" != "$previous_hash" ]; then
        log "CONFIG changed -> full policy reconciliation"
        full_rescan
        read_category_list ADS > "$CACHE_ADS"
        read_category_list ANALYTICS > "$CACHE_ANALYTICS"
        read_global_list > "$CACHE_GLOBAL"
        compute_config_hash > "$CONFIG_HASH_FILE"
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
