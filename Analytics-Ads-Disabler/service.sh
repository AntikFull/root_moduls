#!/system/bin/sh
# Boot service for Analytics & Ads Disabler; runtime version is read from module.prop.

MODDIR=${0%/*}
DATA_DIR="/data/adb/analytics_ads_disabler"
LOG_DIR="$DATA_DIR/logs"
BOOT_TRACE="$LOG_DIR/boot_trace.log"
mkdir -p "$DATA_DIR" "$LOG_DIR" 2>/dev/null
trace() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$*" >> "$BOOT_TRACE" 2>/dev/null
}

trace "service.sh ENTER pid=$$ module=$MODDIR"
trace "EARLY-WAIT begin"
wait_loops=0
while [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    wait_loops=$((wait_loops + 1))
    [ $((wait_loops % 12)) -eq 0 ] && trace "EARLY-WAIT loops=$wait_loops boot=$(/system/bin/getprop sys.boot_completed 2>/dev/null)"
    sleep 5
done
trace "BOOT-COMPLETE observed loops=$wait_loops"
sleep 3
trace "COMMON-SOURCE begin"

# Only now touch shared code/logging that may use /sdcard or Binder-facing helpers.
AAD_DEFER_CAPABILITY_INIT=1
export AAD_DEFER_CAPABILITY_INIT
. "$MODDIR/common.sh"
common_rc=$?
unset AAD_DEFER_CAPABILITY_INIT
trace "COMMON-SOURCE end rc=$common_rc"
[ "$common_rc" -eq 0 ] || { trace "FATAL common.sh rc=$common_rc"; exit "$common_rc"; }

trace "POST-COMMON state-dir begin"
mkdir -p "$DATA_DIR" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null
touch "$DISABLED_LIST" "$COMPONENT_STATE" 2>/dev/null
chmod 600 "$DISABLED_LIST" "$COMPONENT_STATE" 2>/dev/null
trace "POST-COMMON state-dir end"

# Runtime must never depend on /sdcard availability. Keep authoritative
# live logs in /data/adb/analytics_ads_disabler/logs; /sdcard/eCubz/logs/Analytics_Ads_Disabler is mirrored best-effort.
RUNTIME_LOG="$LOG_DIR/debug.log"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
SDCARD_LOG="$SDCARD_LOG_DIR/debug.log"
LOGFILE="$RUNTIME_LOG"
export LOGFILE LOG_DIR
[ -s "$LOGFILE" ] && cp "$LOGFILE" "$LOG_DIR/debug.previous.log" 2>/dev/null || true
: > "$LOGFILE" 2>/dev/null
trace "RUNTIME-LOG initialized path=$LOGFILE previous=$LOG_DIR/debug.previous.log"

# Initialize missing files only. Never overwrite user edits on module updates.
for f in settings.conf rules.conf whitelist.list white_ads.list white_analytics.list; do
    if [ ! -f "$DATA_DIR/$f" ] && [ -f "$MODDIR/$f" ]; then
        cp "$MODDIR/$f" "$DATA_DIR/$f"
    fi
done

# Keep module-directory config paths as aliases to the persistent watched files.
# Repair them on every boot in case a root file manager replaced a symlink.
for f in settings.conf rules.conf whitelist.list white_ads.list white_analytics.list; do
    [ -f "$DATA_DIR/$f" ] || continue
    if [ ! -L "$MODDIR/$f" ]; then
        rm -f "$MODDIR/$f" 2>/dev/null
        ln -s "$DATA_DIR/$f" "$MODDIR/$f" 2>/dev/null
    fi
done
trace "CONFIG-ALIASES checked"
log "CONFIG-PATH runtime=$DATA_DIR module_alias=$MODDIR"
log "=== $MODULE_VERSION_LABEL starting pid=$$ ==="
log "BOOT-TRACE: service entry recorded at $BOOT_TRACE"
log "BOOT-READY: sys.boot_completed=1 (observed before common.sh)"
trace "DEBUG-LOG initialized path=$LOGFILE"

# Capability work is safe only now.
trace "CAPABILITY ensure begin"
ensure_capability_profile >/dev/null 2>&1
trace "CAPABILITY ensure end"
if ! cap_profile_valid; then
    log "CAPABILITY profile invalid after boot-time probe; aborting runtime start"
    exit 1
fi
load_capabilities
log "CAPABILITY pm-disable=${CAP_PM_DISABLE_BACKEND}:${CAP_PM_DISABLE_VERB} user=${CAP_PM_DISABLE_HAS_USER} learned=${CAP_PM_LEARNED_DISABLE_BACKEND:-none}/${CAP_PM_LEARNED_DISABLE_EXEC:-direct} verified=${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}"
log "CAPABILITY pm-enable=${CAP_PM_ENABLE_BACKEND}:${CAP_PM_ENABLE_VERB} default=${CAP_PM_DEFAULT_BACKEND}:${CAP_PM_DEFAULT_VERB} restore-disabled=${CAP_PM_STATE_DISABLED_BACKEND}:${CAP_PM_STATE_DISABLED_VERB} exact=${CAP_PM_STATE_DISABLED_EXACT}"
log "CAPABILITY users=${CAP_USER_LIST_BACKEND} packages=${CAP_PACKAGE_LIST_BACKEND} versionCode=${CAP_PACKAGE_LIST_HAS_VERSIONCODE} dump=${CAP_PACKAGE_DUMP_BACKEND} watch=${CAP_APP_WATCH_BACKEND}"
log "POLICY component-mode=$(read_component_mode) backend=$(read_component_backend) activity-ifw=exact-rules provider-balanced=pm-only"

trace "BOOT-SCAN begin"
log "BOOT-SCAN: starting full policy reconciliation. Users: $(list_user_ids | tr '\n' ' ')"
full_rescan
boot_scan_rc=$?
log "BOOT-SCAN: finished rc=$boot_scan_rc"
trace "BOOT-SCAN end rc=$boot_scan_rc"

# Seed watcher caches only after boot reconciliation attempt.
refresh_policy_caches
if [ "$boot_scan_rc" -eq 0 ]; then
    compute_config_hash > "$CONFIG_HASH_FILE"
    compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"
fi

# Stop only this module's previous watcher PIDs; never killall inotifyd.
stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"
stop_owned_pidfile "$CONFIG_INOTIFY_PID_FILE" "config_event.sh"
stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$LOG_MIRROR_PID_FILE" "log_mirror.sh"

start_and_verify_bg() {
    label="$1"; pidfile="$2"; shift 2
    "$@" >> "$LOGFILE" 2>&1 &
    child=$!
    echo "$child" > "$pidfile"
    sleep 1
    if kill -0 "$child" 2>/dev/null; then
        log "$label RUNNING pid=$child"
        return 0
    fi
    log "$label FAILED-TO-STAY-RUNNING pid=$child"
    rm -f "$pidfile" 2>/dev/null
    return 1
}

if [ "$(read_bool_setting REALTIME_MONITOR 1)" = "1" ] && [ "$CAP_APP_WATCH_BACKEND" = "inotifyd" ]; then
    log "Launching /data/app inotify watcher (create/delete/move)."
    start_and_verify_bg "APP-WATCH" "$INOTIFY_PID_FILE" inotifyd "$MODDIR/on_app_installed.sh" /data/app:ndmy
else
    log "APP-WATCH realtime unavailable/disabled; polling fallback active."
fi

if [ "$(read_bool_setting REALTIME_MONITOR 1)" = "1" ] && command -v inotifyd >/dev/null 2>&1; then
    log "Launching realtime config inotify watcher on $DATA_DIR."
    start_and_verify_bg "CONFIG-INOTIFY" "$CONFIG_INOTIFY_PID_FILE" inotifyd "$MODDIR/config_event.sh" "$DATA_DIR:wnmyd"
else
    rm -f "$CONFIG_INOTIFY_PID_FILE" 2>/dev/null
    log "CONFIG-INOTIFY unavailable/disabled; hash polling remains active."
fi

start_and_verify_bg "CONFIG-POLL" "$WATCH_PID_FILE" "$MODDIR/config_watch.sh"
start_and_verify_bg "LOG-MIRROR" "$LOG_MIRROR_PID_FILE" "$MODDIR/log_mirror.sh"
log "RUNTIME-READY: app_watch=$([ -f "$INOTIFY_PID_FILE" ] && echo yes || echo no) config_inotify=$([ -f "$CONFIG_INOTIFY_PID_FILE" ] && echo yes || echo no) config_poll=$([ -f "$WATCH_PID_FILE" ] && echo yes || echo no) log_mirror=$([ -f "$LOG_MIRROR_PID_FILE" ] && echo yes || echo no) interval=$(read_poll_interval)s"
trace "service.sh RUNTIME_READY pid=$$"
