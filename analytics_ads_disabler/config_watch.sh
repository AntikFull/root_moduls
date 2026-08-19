#!/system/bin/sh
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
verify_elapsed=0
while true; do
    interval=$(read_poll_interval)

    current_hash=$(compute_config_hash)
    previous_hash=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)
    if [ "$current_hash" != "$previous_hash" ]; then
        reconcile_config_if_changed "hash-poll"
        package_elapsed=0
    fi

    package_elapsed=$((package_elapsed + interval))
    verify_elapsed=$((verify_elapsed + interval))
    if [ "${CAP_APP_WATCH_BACKEND:-polling}" = "inotifyd" ]; then
        package_due=$(read_package_safety_poll_interval)
    else
        package_due=$(read_package_poll_interval)
    fi

    if [ -f "$PACKAGE_RESCAN_PENDING" ]; then
        log "PACKAGE-RETRY: consuming deferred rescan request."
        rm -f "$PACKAGE_RESCAN_PENDING" 2>/dev/null
        rescan_changed_packages
        package_elapsed=0
    fi

    if [ -f "$DATA_DIR/.side_effects.pending" ]; then
        reconcile_side_effects "pending-retry" >/dev/null 2>&1 || true
    fi

    if [ -f "$COMPONENT_VERIFY_PENDING" ] && [ "$verify_elapsed" -ge 60 ] 2>/dev/null; then
        aad_verify_owned_components "pending-retry" >/dev/null 2>&1 || true
        verify_elapsed=0
    fi

    if [ "$package_elapsed" -ge "$package_due" ] 2>/dev/null; then
        log "PACKAGE-POLL backend=${CAP_APP_WATCH_BACKEND:-polling} interval=${package_due}s"
        rescan_changed_packages
        aad_verify_owned_components "safety-poll" >/dev/null 2>&1 || true
        reconcile_ad_surface_killer "package-poll" >/dev/null 2>&1 || true
        package_elapsed=0
        verify_elapsed=0
    fi

    if ad_killer_enabled && [ "$(sed -n 's/^state=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n1)" = "ACTIVE" ]; then
        if ! ad_killer_chain_alive; then
            log "AD-KILLER chain missing from OUTPUT (netd rebuild?); re-applying."
            reconcile_ad_surface_killer "chain-lost" >/dev/null 2>&1 || true
        fi
    fi

    sleep "$interval"
done
