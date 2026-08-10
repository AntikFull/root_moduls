#!/system/bin/sh
# Exact-state rollback; runtime version is read from module.prop.
MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
LOG_DIR="$DATA_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOGFILE="$LOG_DIR/uninstall.log"
echo "=== [$(date)] $MODULE_VERSION_LABEL uninstall rollback ===" > "$LOGFILE"
ensure_capability_profile >/dev/null 2>&1
load_capabilities

stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$CONFIG_INOTIFY_PID_FILE" "config_event.sh"
stop_owned_pidfile "$LOG_MIRROR_PID_FILE" "log_mirror.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"

# Удаляется только собственный IFW-файл; правила App Manager, Blocker и других программ не затрагиваются.
if [ -e "$IFW_RULE_FILE" ]; then
    if rm -f "$IFW_RULE_FILE" 2>/dev/null; then
        echo "[$(date)] IFW REMOVED $IFW_RULE_FILE" >> "$LOGFILE"
    else
        echo "[$(date)] IFW REMOVE FAILED $IFW_RULE_FILE" >> "$LOGFILE"
    fi
fi

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

# Preserve the final rollback report outside DATA_DIR before removing persistent state.
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null || true
if command -v timeout >/dev/null 2>&1; then
    timeout 3 cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall.log" 2>/dev/null || true
else
    cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall.log" 2>/dev/null || true
fi
rm -rf "$DATA_DIR"
