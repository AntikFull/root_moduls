#!/system/bin/sh

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
wait_max=180
while [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    wait_loops=$((wait_loops + 1))
    [ $((wait_loops % 12)) -eq 0 ] && trace "EARLY-WAIT loops=$wait_loops boot=$(/system/bin/getprop sys.boot_completed 2>/dev/null)"
    if [ "$wait_loops" -ge "$wait_max" ]; then
        trace "EARLY-WAIT TIMEOUT after $((wait_max * 5))s; continuing without sys.boot_completed=1"
        break
    fi
    sleep 5
done
trace "BOOT-COMPLETE observed loops=$wait_loops"
sleep 3
trace "COMMON-SOURCE begin"

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

RUNTIME_LOG="$LOG_DIR/debug.log"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
SDCARD_LOG="$SDCARD_LOG_DIR/debug.log"
LOGFILE="$RUNTIME_LOG"
export LOGFILE LOG_DIR
[ -s "$LOGFILE" ] && cp "$LOGFILE" "$LOG_DIR/debug.previous.log" 2>/dev/null || true
: > "$LOGFILE" 2>/dev/null
trace "RUNTIME-LOG initialized path=$LOGFILE previous=$LOG_DIR/debug.previous.log"

for f in settings.conf rules.conf whitelist.list white_ads.list white_analytics.list; do
    if [ ! -f "$DATA_DIR/$f" ] && [ -f "$MODDIR/$f" ]; then
        cp "$MODDIR/$f" "$DATA_DIR/$f"
    fi
done

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
log "BOOT-READY: sys.boot_completed=$(/system/bin/getprop sys.boot_completed 2>/dev/null) (observed before common.sh)"
log "TOOLCHAIN busybox=${AAD_BUSYBOX:-none} applet_dir=$AAD_APPLET_DIR awk=$(command -v awk 2>/dev/null || echo missing) unzip=$(command -v unzip 2>/dev/null || echo missing) od=$(command -v od 2>/dev/null || echo missing) inotifyd=$(command -v inotifyd 2>/dev/null || echo missing)"
trace "DEBUG-LOG initialized path=$LOGFILE"

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
log "POLICY component-mode=$(read_component_mode) backend=$(read_component_backend) activity-ifw=exact-rules provider-balanced=pm-only aggressive=exact-ad-providers-activities"

for stale_lock in "$DATA_DIR/.operation.lock" "$DATA_DIR/.state_db.lock"                   "$DATA_DIR/.membership_db.lock" "$DATA_DIR/.surface_index.lock"                   "$DATA_DIR/.ad_killer.lock" "$DATA_DIR/.app_event.lock"; do
    if [ -d "$stale_lock" ]; then
        log "BOOT-LOCK-CLEANUP removing $stale_lock (owner pid=$(cat "$stale_lock/pid" 2>/dev/null))"
        rm -rf "$stale_lock" 2>/dev/null
    fi
done
rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null

aad_lower_priority() {
    command -v renice >/dev/null 2>&1 && renice -n 19 -p $$ >/dev/null 2>&1
    command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1
    return 0
}
aad_lower_priority
log "PRIORITY lowered for boot reconciliation (nice=19, ionice=idle)"

trace "BOOT-SCAN begin"
log "BOOT-SCAN: starting full policy reconciliation. Users: $(list_user_ids | tr '\n' ' ')"
full_rescan
boot_scan_rc=$?
log "BOOT-SCAN: finished rc=$boot_scan_rc"
trace "BOOT-SCAN end rc=$boot_scan_rc"

if [ "$boot_scan_rc" -eq 0 ]; then
    trace "POST-BOOT-DELTA begin"
    rescan_changed_packages
    trace "POST-BOOT-DELTA end rc=$?"
fi

refresh_policy_caches
if [ "$boot_scan_rc" -eq 0 ]; then
    compute_config_hash > "$CONFIG_HASH_FILE"
    compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"
fi

stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"
stop_owned_pidfile "$CONFIG_INOTIFY_PID_FILE" "config_event.sh"
stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$LOG_MIRROR_PID_FILE" "log_mirror.sh"
stop_owned_pidfile "$AD_SURFACE_PID_FILE" "ad_surface_indexer.sh"

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
reconcile_ad_surface_killer "boot" >/dev/null 2>&1 || true
launch_ad_surface_indexer_bg "boot" >/dev/null 2>&1 || true
