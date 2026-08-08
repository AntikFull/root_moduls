#!/system/bin/sh
# Boot service for Analytics & Ads Disabler v4.2 Runtime Adaptive Edition.

MODDIR=${0%/*}
. "$MODDIR/common.sh"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null
touch "$DISABLED_LIST" "$COMPONENT_STATE"
chmod 600 "$DISABLED_LIST" "$COMPONENT_STATE" 2>/dev/null

# Initialize missing files only. Never overwrite user edits on module updates.
for f in settings.conf rules.conf whitelist.list white_ads.list white_analytics.list; do
    if [ ! -f "$DATA_DIR/$f" ] && [ -f "$MODDIR/$f" ]; then
        cp "$MODDIR/$f" "$DATA_DIR/$f"
    fi
done

: > "$LOGFILE"
log "=== Analytics & Ads Disabler v4.2 Runtime Adaptive starting ==="

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done
sleep 3

# Re-probe only if profile is absent/outdated or ROM fingerprint changed.
if ! cap_profile_valid; then
    log "CAPABILITY profile missing/stale -> probing device"
    probe_capabilities
fi
load_capabilities
log "CAPABILITY pm-disable=${CAP_PM_DISABLE_BACKEND}:${CAP_PM_DISABLE_VERB} user=${CAP_PM_DISABLE_HAS_USER}"
log "CAPABILITY pm-enable=${CAP_PM_ENABLE_BACKEND}:${CAP_PM_ENABLE_VERB} default=${CAP_PM_DEFAULT_BACKEND}:${CAP_PM_DEFAULT_VERB} restore-disabled=${CAP_PM_STATE_DISABLED_BACKEND}:${CAP_PM_STATE_DISABLED_VERB} exact=${CAP_PM_STATE_DISABLED_EXACT}"
log "CAPABILITY users=${CAP_USER_LIST_BACKEND} packages=${CAP_PACKAGE_LIST_BACKEND} versionCode=${CAP_PACKAGE_LIST_HAS_VERSIONCODE} dump=${CAP_PACKAGE_DUMP_BACKEND} watch=${CAP_APP_WATCH_BACKEND}"

log "Boot completed. Users: $(list_user_ids | tr '\n' ' ')"
full_rescan

# Seed watcher caches after the initial reconciliation.
read_category_list ADS > "$CACHE_ADS"
read_category_list ANALYTICS > "$CACHE_ANALYTICS"
read_global_list > "$CACHE_GLOBAL"
compute_config_hash > "$CONFIG_HASH_FILE"

# Stop only this module's previous watcher PIDs; never killall inotifyd.
stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"

if [ "$(read_bool_setting REALTIME_MONITOR 1)" = "1" ] && [ "$CAP_APP_WATCH_BACKEND" = "inotifyd" ]; then
    log "Launching /data/app inotify watcher (create/delete/move)."
    inotifyd "$MODDIR/on_app_installed.sh" /data/app:ndmy >> "$LOGFILE" 2>&1 &
    echo $! > "$INOTIFY_PID_FILE"
else
    log "Using package polling monitor (no supported inotifyd or realtime disabled)."
fi

stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
"$MODDIR/config_watch.sh" >> "$LOGFILE" 2>&1 &
echo $! > "$WATCH_PID_FILE"
log "Config/package watcher started pid=$! config_interval=$(read_poll_interval)s"
