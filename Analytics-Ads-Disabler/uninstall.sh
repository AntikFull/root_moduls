#!/system/bin/sh
# Exact-state rollback for Analytics & Ads Disabler v4.2.
MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
LOGFILE="$DATA_DIR/uninstall.log"
mkdir -p "$DATA_DIR" 2>/dev/null
echo "=== [$(date)] v4.2 uninstall rollback ===" > "$LOGFILE"
ensure_capability_profile >/dev/null 2>&1
load_capabilities

stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"

# Restore each component exactly to the override state captured before the module first touched it.
if [ -f "$COMPONENT_STATE" ]; then
    cp "$COMPONENT_STATE" "$COMPONENT_STATE.uninstall_work" 2>/dev/null
    while IFS='|' read -r user comp original; do
        [ -z "$comp" ] && continue
        if set_component_state_smart "$user" "$comp" "${original:-default}"; then
            echo "[$(date)] RESTORED u$user $comp -> ${original:-default}" >> "$LOGFILE"
        else
            echo "[$(date)] FAILED u$user $comp -> ${original:-default}" >> "$LOGFILE"
        fi
    done < "$COMPONENT_STATE.uninstall_work"
fi

# Keep uninstall log briefly impossible once data dir is removed; module data itself should not linger.
rm -rf "$DATA_DIR"
