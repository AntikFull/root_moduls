#!/system/bin/sh

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:${PATH:-/system/bin}"

MODDIR=${0%/*}
DATA_DIR="/data/adb/analytics_ads_disabler"
LOG_DIR="$DATA_DIR/logs"
BOOT_TRACE="$LOG_DIR/boot_trace.log"
mkdir -p "$DATA_DIR" "$LOG_DIR" 2>/dev/null
trace() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$*" >> "$BOOT_TRACE" 2>/dev/null
}

trace "service.sh ENTER pid=$$ module=$MODDIR arg1=${1:-none}"

# Диспетчеризация команд вне полного цикла boot
if [ "$1" = "reconcile-rules" ] || [ "$1" = "reconcile" ]; then
    trace "service.sh RECONCILE-RULES invoked pid=$$"
    if [ -f "$MODDIR/common.sh" ]; then
        . "$MODDIR/common.sh" || exit 1
    else
        exit 1
    fi
    log "RECONCILE-RULES triggered pid=$$"
    ensure_capability_profile >/dev/null 2>&1
    load_capabilities
    reconcile_config_if_changed "service-dispatch:$1"
    _rc_res=$?
    log "RECONCILE-RULES finished rc=$_rc_res"
    exit "$_rc_res"
elif [ "$1" = "status" ]; then
    if [ -f "$MODDIR/common.sh" ]; then
        . "$MODDIR/common.sh" || exit 1
    fi
    printf "Status: %s\n" "${MODULE_VERSION_LABEL:-Active}"
    exit 0
fi

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

early_uint_setting() {
    _eus_key="$1"
    _eus_default="$2"
    _eus_min="$3"
    _eus_max="$4"
    _eus_file="$DATA_DIR/settings.conf"
    [ -f "$_eus_file" ] || _eus_file="$MODDIR/settings.conf"
    _eus_value=$(sed -n "s/^[[:space:]]*${_eus_key}[[:space:]]*=[[:space:]]*//p" "$_eus_file" 2>/dev/null | tail -n 1)
    _eus_value=${_eus_value%%[!0-9]*}
    case "$_eus_value" in
        ''|*[!0-9]*) _eus_value="$_eus_default" ;;
    esac
    [ "$_eus_value" -lt "$_eus_min" ] 2>/dev/null && _eus_value="$_eus_min"
    [ "$_eus_value" -gt "$_eus_max" ] 2>/dev/null && _eus_value="$_eus_max"
    printf '%s\n' "$_eus_value"
}

early_uptime_seconds() {
    _eus_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    case "$_eus_uptime" in
        ''|*[!0-9]*) _eus_uptime=0 ;;
    esac
    printf '%s\n' "$_eus_uptime"
}

early_mem_available_kb() {
    _ema_value=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    [ -n "$_ema_value" ] || _ema_value=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    case "$_ema_value" in
        ''|*[!0-9]*) _ema_value=0 ;;
    esac
    printf '%s\n' "$_ema_value"
}

early_cpu_totals() {
    awk '/^cpu[[:space:]]/ {
        total=0
        for (i=2; i<=NF; i++) total += $i
        idle=$5 + $6
        printf "%.0f %.0f\n", total, idle
        exit
    }' /proc/stat 2>/dev/null
}

early_cpu_idle_percent() {
    _ecp_sample="$1"
    set -- $(early_cpu_totals)
    _ecp_total_before=${1:-0}
    _ecp_idle_before=${2:-0}
    sleep "$_ecp_sample"
    set -- $(early_cpu_totals)
    _ecp_total_after=${1:-0}
    _ecp_idle_after=${2:-0}
    _ecp_total_delta=$((_ecp_total_after - _ecp_total_before))
    _ecp_idle_delta=$((_ecp_idle_after - _ecp_idle_before))
    if [ "$_ecp_total_delta" -gt 0 ] 2>/dev/null && [ "$_ecp_idle_delta" -ge 0 ] 2>/dev/null; then
        printf '%s\n' $((_ecp_idle_delta * 100 / _ecp_total_delta))
    else
        printf '0\n'
    fi
}

early_boot_animation_ready() {
    _eba_exit=$(/system/bin/getprop service.bootanim.exit 2>/dev/null)
    _eba_state=$(/system/bin/getprop init.svc.bootanim 2>/dev/null)
    [ "$_eba_exit" = "1" ] && return 0
    [ "$_eba_state" = "stopped" ] && return 0
    [ -z "$_eba_exit$_eba_state" ] && return 0
    return 1
}

early_package_manager_ready() {
    /system/bin/cmd package list users >/dev/null 2>&1 && return 0
    command -v pm >/dev/null 2>&1 && pm list users >/dev/null 2>&1
}

wait_for_os_stability() {
    _wos_enabled=$(early_uint_setting BOOT_STABILIZATION 1 0 1)
    _wos_min_uptime=$(early_uint_setting BOOT_STABILIZATION_MIN_UPTIME_SEC 120 0 900)
    _wos_max_wait=$(early_uint_setting BOOT_STABILIZATION_MAX_WAIT_SEC 300 15 1800)
    _wos_sample=$(early_uint_setting BOOT_STABILIZATION_SAMPLE_SEC 5 2 30)
    _wos_required=$(early_uint_setting BOOT_STABILIZATION_REQUIRED_SAMPLES 3 1 12)
    _wos_min_idle=$(early_uint_setting BOOT_STABILIZATION_MIN_IDLE_PERCENT 60 10 95)
    _wos_min_mem=$(early_uint_setting BOOT_STABILIZATION_MIN_AVAILABLE_KB 1048576 131072 16777216)

    AAD_BOOT_STABILIZATION_RESULT=disabled
    AAD_BOOT_STABILIZATION_WAIT_SEC=0
    AAD_BOOT_STABILIZATION_IDLE_PERCENT=0
    AAD_BOOT_STABILIZATION_MEM_AVAILABLE_KB=$(early_mem_available_kb)
    AAD_BOOT_STABILIZATION_STABLE_SAMPLES=0
    [ "$_wos_enabled" = "1" ] || {
        trace "BOOT-STABILIZATION disabled"
        return 0
    }

    _wos_started=$(early_uptime_seconds)
    _wos_stable=0
    _wos_last_log=-30
    trace "BOOT-STABILIZATION begin min_uptime=${_wos_min_uptime}s max_wait=${_wos_max_wait}s sample=${_wos_sample}s required=$_wos_required min_idle=${_wos_min_idle}% min_mem_kb=$_wos_min_mem"

    while :; do
        _wos_now=$(early_uptime_seconds)
        _wos_elapsed=$((_wos_now - _wos_started))
        [ "$_wos_elapsed" -lt 0 ] 2>/dev/null && _wos_elapsed=0
        if [ "$_wos_elapsed" -ge "$_wos_max_wait" ] 2>/dev/null; then
            AAD_BOOT_STABILIZATION_RESULT=timeout
            break
        fi

        _wos_mem=$(early_mem_available_kb)
        _wos_bootanim=0
        early_boot_animation_ready && _wos_bootanim=1
        _wos_pm=0
        _wos_idle=0

        if [ "$_wos_now" -ge "$_wos_min_uptime" ] 2>/dev/null && [ "$_wos_bootanim" = "1" ]; then
            _wos_idle=$(early_cpu_idle_percent "$_wos_sample")
            early_package_manager_ready && _wos_pm=1
        else
            sleep "$_wos_sample"
        fi

        if [ "$_wos_now" -ge "$_wos_min_uptime" ] 2>/dev/null \
           && [ "$_wos_bootanim" = "1" ] \
           && [ "$_wos_pm" = "1" ] \
           && [ "$_wos_idle" -ge "$_wos_min_idle" ] 2>/dev/null \
           && [ "$_wos_mem" -ge "$_wos_min_mem" ] 2>/dev/null; then
            _wos_stable=$((_wos_stable + 1))
        else
            _wos_stable=0
        fi

        _wos_after=$(early_uptime_seconds)
        _wos_elapsed=$((_wos_after - _wos_started))
        if [ $((_wos_elapsed - _wos_last_log)) -ge 30 ] 2>/dev/null || [ "$_wos_stable" -gt 0 ]; then
            trace "BOOT-STABILIZATION sample elapsed=${_wos_elapsed}s uptime=${_wos_after}s idle=${_wos_idle}% mem_kb=$_wos_mem bootanim=$_wos_bootanim pm=$_wos_pm stable=${_wos_stable}/${_wos_required}"
            _wos_last_log=$_wos_elapsed
        fi

        if [ "$_wos_stable" -ge "$_wos_required" ] 2>/dev/null; then
            AAD_BOOT_STABILIZATION_RESULT=stable
            break
        fi
    done

    AAD_BOOT_STABILIZATION_WAIT_SEC=$_wos_elapsed
    AAD_BOOT_STABILIZATION_IDLE_PERCENT=$_wos_idle
    AAD_BOOT_STABILIZATION_MEM_AVAILABLE_KB=$_wos_mem
    AAD_BOOT_STABILIZATION_STABLE_SAMPLES=$_wos_stable
    trace "BOOT-STABILIZATION end result=$AAD_BOOT_STABILIZATION_RESULT wait_s=$AAD_BOOT_STABILIZATION_WAIT_SEC idle=${AAD_BOOT_STABILIZATION_IDLE_PERCENT}% mem_kb=$AAD_BOOT_STABILIZATION_MEM_AVAILABLE_KB stable=$AAD_BOOT_STABILIZATION_STABLE_SAMPLES/$_wos_required"
}

wait_for_os_stability
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

for f in settings.conf rules.vendor.conf rules.user.conf whitelist.list white_ads.list white_analytics.list smart_reward.list qa_targets.list il2cpp_hooks.conf; do
    if [ ! -f "$DATA_DIR/$f" ] && [ -f "$MODDIR/$f" ]; then
        cp "$MODDIR/$f" "$DATA_DIR/$f"
    fi
done

if ! rebuild_composite_rules; then
    log "BOOT-CONFIG-FAILED: rules composite commit failed; aborting runtime start rather than using stale rules.conf"
    trace "BOOT-CONFIG failed composite"
    exit 1
fi

for f in settings.conf rules.vendor.conf rules.user.conf rules.conf whitelist.list white_ads.list white_analytics.list smart_reward.list qa_targets.list il2cpp_hooks.conf integrity.manifest; do
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
log "BOOT-STABILIZATION result=${AAD_BOOT_STABILIZATION_RESULT:-unknown} wait_s=${AAD_BOOT_STABILIZATION_WAIT_SEC:-0} idle=${AAD_BOOT_STABILIZATION_IDLE_PERCENT:-0}% mem_available_kb=${AAD_BOOT_STABILIZATION_MEM_AVAILABLE_KB:-0} stable_samples=${AAD_BOOT_STABILIZATION_STABLE_SAMPLES:-0}"
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
log "POLICY component-mode=UNIVERSAL backend=PM per-user"

clean_stale_lock() {
    _csl_dir="$1"
    [ -d "$_csl_dir" ] || return 0
    if ! aad_lock_owner_alive "$_csl_dir"; then
        log "BOOT-LOCK-CLEANUP removing stale $_csl_dir (dead or recycled pid)"
        rm -rf "$_csl_dir" 2>/dev/null
    else
        log "BOOT-LOCK-PRESERVE keeping active $_csl_dir"
    fi
}

for stale_lock in "$DATA_DIR/.operation.lock" "$DATA_DIR/.state_db.lock" \
                  "$DATA_DIR/.membership_db.lock" "$DATA_DIR/.surface_index.lock" \
                  "$DATA_DIR/.ad_killer.lock" "$DATA_DIR/.app_event.lock"; do
    clean_stale_lock "$stale_lock"
done
rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null
find "$DATA_DIR" -maxdepth 1 -name ".*.tmp.*" -mtime +1 -delete 2>/dev/null || true
find "$LOG_DIR" -maxdepth 1 -name ".*.running.*" -mtime +1 -delete 2>/dev/null || true

aad_lower_priority() {
    command -v renice >/dev/null 2>&1 && renice -n 19 -p $$ >/dev/null 2>&1
    command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1
    return 0
}
aad_lower_priority
log "PRIORITY lowered for boot reconciliation (nice=19, ionice=idle)"

reconcile_side_effects "boot"

# v6.0.5: normal boot reuses the persistent discovery cache. A multi-minute
# deep scan is reserved for missing/stale discovery data or rule-schema changes.
aad_candidate_cache_bootstrap_from_audit >/dev/null 2>&1 || true
trace "BOOT-RECONCILE begin"
if aad_candidate_cache_structural_valid; then
    _boot_scope=$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)
    log "BOOT-RECONCILE: warm candidate cache valid scope=${_boot_scope:-unknown}."
    if [ "$(read_include_system_apps)" = "1" ] && [ "$_boot_scope" != "ALL" ]; then
        log "BOOT-RECONCILE: SYSTEM scope requested but candidate coverage is USER-only; expanding scope before package delta."
        reconcile_config_if_changed "boot-scope-expand"
        boot_scan_rc=$?
        if [ "$boot_scan_rc" -eq 0 ]; then
            rescan_changed_packages
            boot_delta_rc=$?
            [ "$boot_delta_rc" -eq 0 ] || boot_scan_rc=$boot_delta_rc
        fi
    else
        log "BOOT-RECONCILE: running package delta + config generation check."
        rescan_changed_packages
        boot_delta_rc=$?
        reconcile_config_if_changed "boot"
        boot_scan_rc=$?
        [ "$boot_delta_rc" -eq 0 ] || boot_scan_rc=$boot_delta_rc
    fi
else
    log "BOOT-RECONCILE: candidate cache missing/stale; one deep discovery is required. Users: $(list_user_ids | tr '\n' ' ')"
    full_rescan
    boot_scan_rc=$?
fi
log "BOOT-RECONCILE: finished rc=$boot_scan_rc mode=$(sed -n 's/^mode=//p' "$RECONCILE_STATUS_FILE" 2>/dev/null | head -n1)"
trace "BOOT-RECONCILE end rc=$boot_scan_rc"

refresh_policy_caches

stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"
stop_owned_pidfile "$CONFIG_INOTIFY_PID_FILE" "config_event.sh"
stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$LOG_MIRROR_PID_FILE" "log_mirror.sh"
stop_owned_pidfile "$AD_SURFACE_PID_FILE" "ad_surface_indexer.sh"
stop_owned_pidfile "$DATA_DIR/rule_updater.pid" "rule_updater.sh"

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
if [ "$(read_bool_setting LOG_MIRROR 0)" = "1" ]; then
    start_and_verify_bg "LOG-MIRROR" "$LOG_MIRROR_PID_FILE" "$MODDIR/log_mirror.sh"
else
    rm -f "$LOG_MIRROR_PID_FILE" 2>/dev/null
fi
if [ "$(read_bool_setting AUTO_UPDATE_RULES 0)" = "1" ] && [ -f "$MODDIR/rule_updater.sh" ]; then
    start_and_verify_bg "RULE-UPDATER" "$DATA_DIR/rule_updater.pid" "$MODDIR/rule_updater.sh"
fi
log "RUNTIME-READY: app_watch=$([ -f "$INOTIFY_PID_FILE" ] && echo yes || echo no) config_inotify=$([ -f "$CONFIG_INOTIFY_PID_FILE" ] && echo yes || echo no) config_poll=$([ -f "$WATCH_PID_FILE" ] && echo yes || echo no) log_mirror=$([ -f "$LOG_MIRROR_PID_FILE" ] && echo yes || echo no) rule_updater=$([ -f "$DATA_DIR/rule_updater.pid" ] && echo yes || echo no) interval=$(read_poll_interval)s"
trace "service.sh RUNTIME_READY pid=$$"
launch_ad_surface_indexer_bg "boot" >/dev/null 2>&1 || true
