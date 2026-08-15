#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

surface_lower_priority() {
    command -v renice >/dev/null 2>&1 && renice -n 19 -p $$ >/dev/null 2>&1
    command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1
    return 0
}

surface_index_cleanup() {
    for _asi_cleanup_pid in ${_asi_worker_pids:-}; do
        case "$_asi_cleanup_pid" in
            ''|*[!0-9]*) continue ;;
        esac
        kill -0 "$_asi_cleanup_pid" 2>/dev/null && kill "$_asi_cleanup_pid" 2>/dev/null || true
    done
    for _asi_cleanup_pid in ${_asi_worker_pids:-}; do
        wait "$_asi_cleanup_pid" 2>/dev/null || true
    done
    case "${_asi_worker_dir:-}" in
        "$DATA_DIR"/.surface_workers.*) rm -rf "$_asi_worker_dir" 2>/dev/null ;;
    esac
    aad_surface_cleanup_matchers >/dev/null 2>&1 || true
    rm -f "${AAD_APK_PATH_CACHE:-}" "${AAD_SURFACE_STATE_FILE:-}" "${AAD_SURFACE_ORDER_FILE:-}" \
          "${AAD_SURFACE_PRIORITY_FILE:-}" 2>/dev/null
    if [ -f "$AD_SURFACE_PID_FILE" ] && [ "$(cat "$AD_SURFACE_PID_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$AD_SURFACE_PID_FILE" 2>/dev/null
    fi
    if [ -d "$AD_SURFACE_LOCK_DIR" ] && [ "$(cat "$AD_SURFACE_LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$AD_SURFACE_LOCK_DIR" 2>/dev/null
    fi
}

surface_index_lock() {
    _asi_lock_tries=0
    while ! mkdir "$AD_SURFACE_LOCK_DIR" 2>/dev/null; do
        _asi_lock_owner=$(cat "$AD_SURFACE_LOCK_DIR/pid" 2>/dev/null)
        case "$_asi_lock_owner" in
            ''|*[!0-9]*)
                rm -rf "$AD_SURFACE_LOCK_DIR" 2>/dev/null
                ;;
            *)
                if aad_pid_matches_marker "$_asi_lock_owner" "ad_surface_indexer.sh"; then
                    log "AD-SURFACE-INDEX duplicate skipped owner=$_asi_lock_owner"
                    return 1
                fi
                if kill -0 "$_asi_lock_owner" 2>/dev/null; then
                    _asi_lock_cmd=$(tr '\000' ' ' < "/proc/$_asi_lock_owner/cmdline" 2>/dev/null)
                    log "AD-SURFACE-LOCK stale recycled_pid=$_asi_lock_owner cmdline=${_asi_lock_cmd:-unreadable}; removing"
                else
                    log "AD-SURFACE-LOCK stale dead_pid=$_asi_lock_owner; removing"
                fi
                rm -rf "$AD_SURFACE_LOCK_DIR" 2>/dev/null
                ;;
        esac
        _asi_lock_tries=$((_asi_lock_tries + 1))
        [ "$_asi_lock_tries" -lt 3 ] || return 1
    done
    echo $$ > "$AD_SURFACE_LOCK_DIR/pid" 2>/dev/null
    return 0
}

surface_status_write() {
    _asi_status_state="$1"
    _asi_status_rc="${2:-}"
    _asi_status_reason="${3:-}"
    _asi_status_now=$(aad_now_ms)
    _asi_status_tmp="$AD_SURFACE_STATUS_FILE.tmp.$$"
    {
        printf 'state=%s\n' "$_asi_status_state"
        printf 'pid=%s\n' "$$"
        printf 'processed=%s\n' "${_asi_processed:-0}"
        printf 'total=%s\n' "${_asi_total_count:-0}"
        printf 'priority=%s\n' "${_asi_priority_count:-0}"
        printf 'workers=%s\n' "${_asi_worker_count:-1}"
        printf 'started_ms=%s\n' "${_asi_index_start_ms:-0}"
        printf 'updated_ms=%s\n' "$_asi_status_now"
        [ -n "$_asi_status_rc" ] && printf 'rc=%s\n' "$_asi_status_rc"
        [ -n "$_asi_status_reason" ] && printf 'reason=%s\n' "$_asi_status_reason"
    } > "$_asi_status_tmp" 2>/dev/null || return 0
    chmod 600 "$_asi_status_tmp" 2>/dev/null || true
    mv -f "$_asi_status_tmp" "$AD_SURFACE_STATUS_FILE" 2>/dev/null || rm -f "$_asi_status_tmp" 2>/dev/null
}

surface_worker_count() {
    _swc_requested=$(read_setting AD_SURFACE_WORKERS 4)
    case "$_swc_requested" in
        ''|*[!0-9]*) _swc_requested=4 ;;
    esac
    [ "$_swc_requested" -ge 1 ] 2>/dev/null || _swc_requested=1
    [ "$_swc_requested" -le 4 ] 2>/dev/null || _swc_requested=4

    _swc_cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    case "$_swc_cpu" in
        ''|*[!0-9]*) _swc_cpu=1 ;;
    esac
    if [ "$_swc_cpu" -lt "$_swc_requested" ] 2>/dev/null; then
        _swc_requested="$_swc_cpu"
    fi
    [ "$_swc_requested" -ge 1 ] 2>/dev/null || _swc_requested=1

    _swc_min_kb=$(read_setting AD_SURFACE_MIN_AVAILABLE_KB 1048576)
    case "$_swc_min_kb" in
        ''|*[!0-9]*) _swc_min_kb=1048576 ;;
    esac
    _swc_three_min_kb=$(read_setting AD_SURFACE_THREE_WORKER_MIN_AVAILABLE_KB 2097152)
    case "$_swc_three_min_kb" in
        ''|*[!0-9]*) _swc_three_min_kb=2097152 ;;
    esac
    _swc_four_min_kb=$(read_setting AD_SURFACE_FOUR_WORKER_MIN_AVAILABLE_KB 4194304)
    case "$_swc_four_min_kb" in
        ''|*[!0-9]*) _swc_four_min_kb=4194304 ;;
    esac
    _swc_available_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    case "$_swc_available_kb" in
        ''|*[!0-9]*) _swc_available_kb=0 ;;
    esac
    if [ "$_swc_available_kb" -gt 0 ] 2>/dev/null && \
       [ "$_swc_available_kb" -lt "$_swc_min_kb" ] 2>/dev/null; then
        _swc_requested=1
    elif [ "$_swc_available_kb" -gt 0 ] 2>/dev/null && \
         [ "$_swc_available_kb" -lt "$_swc_three_min_kb" ] 2>/dev/null && \
         [ "$_swc_requested" -gt 2 ] 2>/dev/null; then
        _swc_requested=2
    elif [ "$_swc_available_kb" -gt 0 ] 2>/dev/null && \
         [ "$_swc_available_kb" -lt "$_swc_four_min_kb" ] 2>/dev/null && \
         [ "$_swc_requested" -gt 3 ] 2>/dev/null; then
        _swc_requested=3
    fi

    AAD_SURFACE_AVAILABLE_KB="$_swc_available_kb"
    AAD_SURFACE_CPU_COUNT="$_swc_cpu"
    AAD_SURFACE_WORKER_COUNT="$_swc_requested"
    return 0
}

surface_worker_run() {
    _swr_id="$1"
    _swr_shard="$2"
    _swr_output="$3"
    _swr_progress="$4"
    AD_SURFACE_SCAN_FILE="$_swr_output"
    export AD_SURFACE_SCAN_FILE
    : > "$_swr_output" || return 1
    _swr_processed=0

    while IFS='|' read -r _swr_user _swr_pkg _swr_vc; do
        [ -n "$_swr_pkg" ] || continue
        AAD_CURRENT_VERSION_CODE="$_swr_vc"
        export AAD_CURRENT_VERSION_CODE
        record_ad_surface_scan_package "$_swr_user" "$_swr_pkg"
        _swr_processed=$((_swr_processed + 1))
        printf '%s\n' "$_swr_processed" > "$_swr_progress.tmp" 2>/dev/null || return 1
        mv -f "$_swr_progress.tmp" "$_swr_progress" 2>/dev/null || return 1
    done < "$_swr_shard"

    log "AD-SURFACE-WORKER id=$_swr_id complete processed=$_swr_processed"
    return 0
}

surface_worker_entry() {
    _swe_id="$1"
    _swe_shard="$2"
    _swe_output="$3"
    _swe_progress="$4"
    _swe_done="$5"
    _swe_rc=0
    surface_worker_run "$_swe_id" "$_swe_shard" "$_swe_output" "$_swe_progress" || _swe_rc=$?
    printf '%s\n' "$_swe_rc" > "$_swe_done.tmp" 2>/dev/null \
        && mv -f "$_swe_done.tmp" "$_swe_done" 2>/dev/null
    rm -f "$_swe_done.tmp" 2>/dev/null
    return "$_swe_rc"
}

surface_progress_sum() {
    _sps_total=0
    for _sps_file in "$_asi_worker_dir"/progress.*; do
        [ -f "$_sps_file" ] || continue
        _sps_value=$(cat "$_sps_file" 2>/dev/null)
        case "$_sps_value" in ''|*[!0-9]*) _sps_value=0 ;; esac
        _sps_total=$((_sps_total + _sps_value))
    done
    printf '%s\n' "$_sps_total"
}

surface_workers_done() {
    _swd_id=1
    while [ "$_swd_id" -le "${_asi_worker_count:-1}" ]; do
        [ -f "$_asi_worker_dir/done.$_swd_id" ] || return 1
        _swd_id=$((_swd_id + 1))
    done
    return 0
}

surface_append_terminal_record() {
    _asi_record="$1"
    _asi_record_state="$2"
    _asi_record_text="$3"
    _asi_record_elapsed="${4:-0}"
    [ -f "$AD_SURFACE_SCAN_FILE" ] || return 0
    _asi_record_stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
    printf '%s|%s|-|-|-|%s|-|-|-|%s|%s|-|%s\n' \
        "$_asi_record_stamp" "$_asi_record" "$_asi_record" "$_asi_record_text" "$_asi_record_state" "$_asi_record_elapsed" \
        >> "$AD_SURFACE_SCAN_FILE" 2>/dev/null || true
}

surface_index_on_exit() {
    _asi_exit_rc="$1"
    if [ "${_asi_terminal_state:-RUNNING}" = "RUNNING" ]; then
        _asi_exit_now=$(aad_now_ms)
        _asi_exit_elapsed=$(aad_elapsed_ms "${_asi_index_start_ms:-$_asi_exit_now}" "$_asi_exit_now")
        _asi_exit_reason_final="${_asi_exit_reason:-unexpected_exit}"
        surface_status_write FAILED "$_asi_exit_rc" "$_asi_exit_reason_final"
        surface_append_terminal_record STATUS FAILED \
            "AD-SURFACE-STATUS state=FAILED rc=$_asi_exit_rc reason=$_asi_exit_reason_final processed=${_asi_processed:-0} total=${_asi_total_count:-0}" \
            "$_asi_exit_elapsed"
        log "AD-SURFACE-INDEX terminal state=FAILED rc=$_asi_exit_rc reason=$_asi_exit_reason_final processed=${_asi_processed:-0} total=${_asi_total_count:-0} elapsed_ms=$_asi_exit_elapsed"
        if [ -n "${_asi_work_surface_file:-}" ] && [ -f "$_asi_work_surface_file" ] && [ -n "${_asi_final_surface_file:-}" ]; then
            rm -f "${_asi_final_surface_file}.failed" 2>/dev/null || true
            mv -f "$_asi_work_surface_file" "${_asi_final_surface_file}.failed" 2>/dev/null || true
        fi
    fi
    surface_index_cleanup
}

surface_index_lock || exit 0
surface_lower_priority
_asi_terminal_state=RUNNING
_asi_exit_reason=""
_asi_processed=0
_asi_total_count=0
_asi_priority_count=0
_asi_worker_count=1
_asi_worker_pids=""
_asi_worker_dir=""
_asi_index_start_ms=$(aad_now_ms)
trap '_asi_exit_rc=$?; surface_index_on_exit "$_asi_exit_rc"' EXIT
trap '_asi_exit_reason=signal_INT; exit 130' INT
trap '_asi_exit_reason=signal_TERM; exit 143' TERM
trap '_asi_exit_reason=signal_HUP; exit 129' HUP

echo $$ > "$AD_SURFACE_PID_FILE" 2>/dev/null
surface_status_write RUNNING
rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null

if [ "$(read_bool_setting BLOCK_ADS 1)" != "1" ]; then
    _asi_terminal_state=SKIPPED
    surface_status_write SKIPPED 0 BLOCK_ADS_0
    log "AD-SURFACE-INDEX skipped BLOCK_ADS=0"
    exit 0
fi

AAD_SURFACE_FINGERPRINT_FILE="$DATA_DIR/.surface_index.fingerprint"
_asi_state_probe="$DATA_DIR/.surface_probe.$$"
list_all_package_state > "$_asi_state_probe" 2>/dev/null
_asi_fingerprint=$( { cat "$_asi_state_probe" 2>/dev/null; echo "rules=$(aad_surface_rules_hash)"; } | cksum 2>/dev/null | awk '{print $1 ":" $2}')
rm -f "$_asi_state_probe" 2>/dev/null
if [ -n "$_asi_fingerprint" ] && [ "$(cat "$AAD_SURFACE_FINGERPRINT_FILE" 2>/dev/null)" = "$_asi_fingerprint" ]    && [ -s "$AD_SURFACE_SCAN_FILE" ] && grep -q '|SUMMARY|.*|COMPLETE|' "$AD_SURFACE_SCAN_FILE" 2>/dev/null    && [ "${AAD_SURFACE_FORCE:-0}" != "1" ]; then
    _asi_terminal_state=SKIPPED
    surface_status_write SKIPPED 0 unchanged_inputs
    log "AD-SURFACE-INDEX skipped: package set and surface rules unchanged since the last completed index (fingerprint=$_asi_fingerprint)"
    exit 0
fi

_asi_final_surface_file="$AD_SURFACE_SCAN_FILE"
for _asi_stale in "$LOG_DIR"/.ad_surface_scan.running.*; do
    [ -f "$_asi_stale" ] || continue
    log "AD-SURFACE-INDEX removing stale work file $_asi_stale"
    rm -f "$_asi_stale" 2>/dev/null
done
_asi_work_surface_file="$LOG_DIR/.ad_surface_scan.running.$$"
AD_SURFACE_SCAN_FILE="$_asi_work_surface_file"
export AD_SURFACE_SCAN_FILE
printf 'timestamp|record|user|package|apk|source|surface|sdk|strategy|evidence|confidence|cache|elapsed_ms\n' > "$AD_SURFACE_SCAN_FILE" 2>/dev/null
chmod 600 "$AD_SURFACE_SCAN_FILE" 2>/dev/null || true

AAD_MANIFEST_CACHE_ENABLED=1
AAD_SURFACE_RULES_HASH=$(aad_surface_rules_hash)
AAD_AD_SURFACE_SCAN_ACTIVE=1
export AAD_MANIFEST_CACHE_ENABLED AAD_SURFACE_RULES_HASH AAD_AD_SURFACE_SCAN_ACTIVE

mkdir -p "$MANIFEST_CACHE_DIR" 2>/dev/null
chmod 700 "$MANIFEST_CACHE_DIR" 2>/dev/null || true
aad_surface_legacy_cache_gc

if ! aad_surface_prepare_matchers; then
    _asi_exit_reason=matcher_setup_failed
    log "AD-SURFACE-INDEX matcher setup failed"
    exit 1
fi
log "AD-SURFACE-MATCHER dex_backend=${AAD_SURFACE_DEX_BACKEND:-raw_exact} selftest=${AAD_SURFACE_SELFTEST_MATCHED:-0}/${AAD_SURFACE_SELFTEST_EXPECTED:-0} strings_system_ms=${AAD_SURFACE_STRINGS_SYSTEM_MS:--1} strings_busybox_ms=${AAD_SURFACE_STRINGS_BUSYBOX_MS:--1} grep_backend=${AAD_SURFACE_GREP_BACKEND:-grep} grep_system_ms=${AAD_SURFACE_GREP_SYSTEM_MS:--1} grep_busybox_ms=${AAD_SURFACE_GREP_BUSYBOX_MS:--1} rules_hash=$AAD_SURFACE_RULES_HASH"

AAD_APK_PATH_CACHE="$DATA_DIR/.surface_apk_paths.$$"
export AAD_APK_PATH_CACHE
if build_apk_path_inventory "$AAD_APK_PATH_CACHE"; then
    _asi_inventory_count=$(grep -c '|' "$AAD_APK_PATH_CACHE" 2>/dev/null)
    [ -n "$_asi_inventory_count" ] || _asi_inventory_count=0
else
    : > "$AAD_APK_PATH_CACHE" 2>/dev/null
    _asi_inventory_count=0
fi

AAD_SURFACE_STATE_FILE="$DATA_DIR/.surface_state.$$"
AAD_SURFACE_ORDER_FILE="$DATA_DIR/.surface_order.$$"
AAD_SURFACE_PRIORITY_FILE="$DATA_DIR/.surface_priority.$$"
export AAD_SURFACE_STATE_FILE AAD_SURFACE_ORDER_FILE AAD_SURFACE_PRIORITY_FILE
list_all_package_state > "$AAD_SURFACE_STATE_FILE"

{
    awk -F'|' 'NR>1 && $4=="ADS" && $2!="" && $3!="" {print $2 "|" $3}' "$COMPONENT_AUDIT_FILE" 2>/dev/null
    awk -F'|' 'NR>1 && $2!="" && $3!="" {print $2 "|" $3}' "$SDK_FINGERPRINT_FILE" 2>/dev/null
} | sort -u > "$AAD_SURFACE_PRIORITY_FILE"

awk -F'|' -v pf="$AAD_SURFACE_PRIORITY_FILE" '
    BEGIN {while ((getline line < pf)>0) p[line]=1; close(pf)}
    (($1 "|" $2) in p) {print}
' "$AAD_SURFACE_STATE_FILE" > "$AAD_SURFACE_ORDER_FILE"
awk -F'|' -v pf="$AAD_SURFACE_PRIORITY_FILE" '
    BEGIN {while ((getline line < pf)>0) p[line]=1; close(pf)}
    !(($1 "|" $2) in p) {print}
' "$AAD_SURFACE_STATE_FILE" >> "$AAD_SURFACE_ORDER_FILE"

_asi_priority_count=$(awk -F'|' -v pf="$AAD_SURFACE_PRIORITY_FILE" '
    BEGIN {while ((getline line < pf)>0) p[line]=1; close(pf)}
    (($1 "|" $2) in p) {n++}
    END{print n+0}
' "$AAD_SURFACE_STATE_FILE" 2>/dev/null)
_asi_total_count=$(grep -c '|' "$AAD_SURFACE_ORDER_FILE" 2>/dev/null)
[ -n "$_asi_priority_count" ] || _asi_priority_count=0
[ -n "$_asi_total_count" ] || _asi_total_count=0
surface_worker_count
_asi_worker_count="$AAD_SURFACE_WORKER_COUNT"
case "$_asi_worker_count" in ''|*[!0-9]*) _asi_worker_count=1 ;; esac
if [ "$_asi_total_count" -gt 0 ] 2>/dev/null && \
   [ "$_asi_total_count" -lt "$_asi_worker_count" ] 2>/dev/null; then
    _asi_worker_count="$_asi_total_count"
fi
surface_status_write RUNNING
log "AD-SURFACE-INDEX started pid=$$ packages/users=$_asi_total_count priority=$_asi_priority_count apk_inventory=$_asi_inventory_count workers=$_asi_worker_count cpu=${AAD_SURFACE_CPU_COUNT:-unknown} mem_available_kb=${AAD_SURFACE_AVAILABLE_KB:-unknown}"

_asi_worker_dir="$DATA_DIR/.surface_workers.$$"
mkdir -p "$_asi_worker_dir" 2>/dev/null || {
    _asi_exit_reason=worker_directory_failed
    exit 1
}
chmod 700 "$_asi_worker_dir" 2>/dev/null || true
_asi_worker_id=1
while [ "$_asi_worker_id" -le "$_asi_worker_count" ]; do
    : > "$_asi_worker_dir/shard.$_asi_worker_id"
    : > "$_asi_worker_dir/result.$_asi_worker_id"
    printf '0\n' > "$_asi_worker_dir/progress.$_asi_worker_id"
    rm -f "$_asi_worker_dir/done.$_asi_worker_id" "$_asi_worker_dir/done.$_asi_worker_id.tmp" 2>/dev/null
    chmod 600 "$_asi_worker_dir/shard.$_asi_worker_id" \
        "$_asi_worker_dir/result.$_asi_worker_id" \
        "$_asi_worker_dir/progress.$_asi_worker_id" 2>/dev/null || true
    _asi_worker_id=$((_asi_worker_id + 1))
done
awk -F'|' -v dir="$_asi_worker_dir" -v workers="$_asi_worker_count" '
    NF >= 2 {
        shard=((NR - 1) % workers) + 1
        print $0 >> (dir "/shard." shard)
    }
' "$AAD_SURFACE_ORDER_FILE" 2>/dev/null || {
    _asi_exit_reason=worker_sharding_failed
    exit 1
}
chmod 600 "$_asi_worker_dir"/shard.* 2>/dev/null || true

_asi_worker_id=1
while [ "$_asi_worker_id" -le "$_asi_worker_count" ]; do
    surface_worker_entry "$_asi_worker_id" \
        "$_asi_worker_dir/shard.$_asi_worker_id" \
        "$_asi_worker_dir/result.$_asi_worker_id" \
        "$_asi_worker_dir/progress.$_asi_worker_id" \
        "$_asi_worker_dir/done.$_asi_worker_id" &
    _asi_worker_pid=$!
    _asi_worker_pids="$_asi_worker_pids $_asi_worker_pid"
    log "AD-SURFACE-WORKER id=$_asi_worker_id started pid=$_asi_worker_pid"
    _asi_worker_id=$((_asi_worker_id + 1))
done

_asi_last_reported=0
_asi_max_runtime_sec=$(read_setting AD_SURFACE_MAX_RUNTIME_SEC 1800)
case "$_asi_max_runtime_sec" in ''|*[!0-9]*) _asi_max_runtime_sec=1800 ;; esac
[ "$_asi_max_runtime_sec" -ge 60 ] 2>/dev/null || _asi_max_runtime_sec=60
[ "$_asi_max_runtime_sec" -le 86400 ] 2>/dev/null || _asi_max_runtime_sec=86400
_asi_max_runtime_ms=$((_asi_max_runtime_sec * 1000))
while ! surface_workers_done; do
    _asi_processed=$(surface_progress_sum)
    if [ $((_asi_processed - _asi_last_reported)) -ge 10 ] || \
       { [ "$_asi_processed" -eq "$_asi_total_count" ] && [ "$_asi_last_reported" -ne "$_asi_total_count" ]; }; then
        _asi_progress_now=$(aad_now_ms)
        _asi_progress_elapsed=$(aad_elapsed_ms "$_asi_index_start_ms" "$_asi_progress_now")
        surface_status_write RUNNING
        log "AD-SURFACE-PROGRESS processed=$_asi_processed total=$_asi_total_count workers=$_asi_worker_count elapsed_ms=$_asi_progress_elapsed"
        _asi_last_reported="$_asi_processed"
    fi
    _asi_watchdog_now=$(aad_now_ms)
    _asi_watchdog_elapsed=$(aad_elapsed_ms "$_asi_index_start_ms" "$_asi_watchdog_now")
    if [ "$_asi_watchdog_elapsed" -ge "$_asi_max_runtime_ms" ] 2>/dev/null; then
        _asi_exit_reason="worker_timeout max_runtime_sec=$_asi_max_runtime_sec processed=$_asi_processed expected=$_asi_total_count"
        log "AD-SURFACE-WATCHDOG timeout max_runtime_sec=$_asi_max_runtime_sec processed=$_asi_processed total=$_asi_total_count"
        exit 1
    fi
    sleep 2
done

_asi_worker_failed=0
_asi_worker_id=1
while [ "$_asi_worker_id" -le "$_asi_worker_count" ]; do
    _asi_done_rc=$(cat "$_asi_worker_dir/done.$_asi_worker_id" 2>/dev/null)
    case "$_asi_done_rc" in
        0) ;;
        *) _asi_worker_failed=1 ;;
    esac
    _asi_worker_id=$((_asi_worker_id + 1))
done
for _asi_worker_pid in $_asi_worker_pids; do
    wait "$_asi_worker_pid" || _asi_worker_failed=1
done
_asi_worker_pids=""
_asi_processed=$(surface_progress_sum)
if [ "$_asi_worker_failed" -ne 0 ] || [ "$_asi_processed" -ne "$_asi_total_count" ]; then
    _asi_exit_reason="worker_failed processed=$_asi_processed expected=$_asi_total_count"
    exit 1
fi

_asi_worker_id=1
while [ "$_asi_worker_id" -le "$_asi_worker_count" ]; do
    cat "$_asi_worker_dir/result.$_asi_worker_id" >> "$AD_SURFACE_SCAN_FILE" 2>/dev/null || {
        _asi_exit_reason=worker_merge_failed
        exit 1
    }
    _asi_worker_id=$((_asi_worker_id + 1))
done
surface_status_write RUNNING

_asi_traversal_now=$(aad_now_ms)
_asi_traversal_elapsed=$(aad_elapsed_ms "$_asi_index_start_ms" "$_asi_traversal_now")
log "AD-SURFACE-TRAVERSAL-COMPLETE processed=$_asi_processed total=$_asi_total_count workers=$_asi_worker_count elapsed_ms=$_asi_traversal_elapsed"
surface_append_terminal_record STATUS RUNNING \
    "AD-SURFACE-TRAVERSAL-COMPLETE processed=$_asi_processed total=$_asi_total_count workers=$_asi_worker_count" \
    "$_asi_traversal_elapsed"

_asi_end_ms=$(aad_now_ms)
_asi_elapsed=$(aad_elapsed_ms "$_asi_index_start_ms" "$_asi_end_ms")
_asi_surface_summary=$(awk -F'|' '
    NR>1 && $2=="APK" {
        apks++; packages[$3 "|" $4]=1; cache[$12]++; scanms+=$13; next
    }
    NR>1 && $2=="HIT" {
        hits++; hitpackages[$3 "|" $4]=1; source[$6]++; surface[$7]++; confidence[$11]++
    }
    END {
        pc=0; hpc=0
        for (k in packages) pc++
        for (k in hitpackages) hpc++
        printf "packages/users=%d hit_packages/users=%d apks=%d hits=%d dex_hits=%d resource_hits=%d capability=%d layout_confirmed=%d multi_evidence=%d banner=%d banner_mrec=%d mrec=%d native=%d app_open=%d interstitial=%d rewarded=%d rewarded_interstitial=%d splash=%d video=%d cache_full_hit=%d cache_rule_rescan=%d cache_miss=%d scan_ms=%d", \
            pc,hpc,apks+0,hits+0,source["DEX"]+0,source["RESOURCE"]+0,confidence["CAPABILITY"]+0,confidence["LAYOUT_CONFIRMED"]+0,confidence["MULTI_EVIDENCE"]+0, \
            surface["BANNER"]+0,surface["BANNER_MREC"]+0,surface["MREC"]+0,surface["NATIVE"]+0,surface["APP_OPEN"]+0,surface["INTERSTITIAL"]+0,surface["REWARDED"]+0,surface["REWARDED_INTERSTITIAL"]+0,surface["SPLASH"]+0,surface["VIDEO"]+0, \
            cache["FULL_HIT"]+0,cache["RULE_RESCAN"]+0,cache["MISS"]+0,scanms+0
    }
' "$AD_SURFACE_SCAN_FILE" 2>/dev/null)

surface_append_terminal_record SUMMARY COMPLETE \
    "AD-SURFACE-SUMMARY $_asi_surface_summary priority_packages/users=$_asi_priority_count index_ms=$_asi_elapsed" \
    "$_asi_elapsed"

if ! mv -f "$_asi_work_surface_file" "$_asi_final_surface_file" 2>/dev/null; then
    _asi_exit_reason=surface_log_commit_failed
    log "AD-SURFACE-INDEX surface log commit failed work=$_asi_work_surface_file final=$_asi_final_surface_file"
    exit 1
fi
AD_SURFACE_SCAN_FILE="$_asi_final_surface_file"
export AD_SURFACE_SCAN_FILE
_asi_work_surface_file=""

_asi_terminal_state=COMPLETE
printf '%s\n' "$_asi_fingerprint" > "$AAD_SURFACE_FINGERPRINT_FILE" 2>/dev/null || true
surface_status_write COMPLETE 0 normal
log "AD-SURFACE-SUMMARY $_asi_surface_summary priority_packages/users=$_asi_priority_count index_ms=$_asi_elapsed file=$AD_SURFACE_SCAN_FILE"
log "AD-SURFACE-INDEX finished packages/users=$_asi_processed elapsed_ms=$_asi_elapsed"

aad_export_xposed_targets >/dev/null 2>&1 || true

if ad_killer_build_targets_from_surface; then
    _asi_killer_targets=$(grep -c . "$AD_KILLER_TARGET_FILE" 2>/dev/null); [ -n "$_asi_killer_targets" ] || _asi_killer_targets=0
    log "AD-KILLER targets committed=$_asi_killer_targets from=surface-index"
    reconcile_ad_surface_killer "surface-complete" || true
else
    log "AD-KILLER target build failed; preserving previous target set"
fi

if [ -f "$DATA_DIR/.surface_index.rerun" ]; then
    _asi_rerun_reason=$(sed -n '1p' "$DATA_DIR/.surface_index.rerun" 2>/dev/null)
    rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null
    _asi_rerun_delay=$(read_setting AD_SURFACE_RERUN_DELAY_SEC 60)
    case "$_asi_rerun_delay" in ''|*[!0-9]*) _asi_rerun_delay=60 ;; esac
    [ "$_asi_rerun_delay" -ge 15 ] 2>/dev/null || _asi_rerun_delay=15
    [ "$_asi_rerun_delay" -le 900 ] 2>/dev/null || _asi_rerun_delay=900
    log "AD-SURFACE-INDEX queued rerun coalesced reason=${_asi_rerun_reason:-unknown} delay_sec=$_asi_rerun_delay"
    # Во время cooldown сохраняем PID и lock: новые события лишь обновляют один
    # rerun-маркер и не могут запустить параллельный индексатор.
    sleep "$_asi_rerun_delay"
    surface_index_cleanup
    trap - EXIT
    launch_ad_surface_indexer_bg "queued-rerun:${_asi_rerun_reason:-unknown}" >/dev/null 2>&1 || true
fi
exit 0
