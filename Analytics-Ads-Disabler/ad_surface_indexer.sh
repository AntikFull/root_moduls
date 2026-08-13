#!/system/bin/sh
# Background, read-only Ad Surface indexer.
# Runs after policy reconciliation so DEX/resource discovery never delays PM/IFW readiness.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

surface_index_cleanup() {
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
        printf 'started_ms=%s\n' "${_asi_index_start_ms:-0}"
        printf 'updated_ms=%s\n' "$_asi_status_now"
        [ -n "$_asi_status_rc" ] && printf 'rc=%s\n' "$_asi_status_rc"
        [ -n "$_asi_status_reason" ] && printf 'reason=%s\n' "$_asi_status_reason"
    } > "$_asi_status_tmp" 2>/dev/null || return 0
    chmod 600 "$_asi_status_tmp" 2>/dev/null || true
    mv -f "$_asi_status_tmp" "$AD_SURFACE_STATUS_FILE" 2>/dev/null || rm -f "$_asi_status_tmp" 2>/dev/null
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
_asi_terminal_state=RUNNING
_asi_exit_reason=""
_asi_processed=0
_asi_total_count=0
_asi_priority_count=0
_asi_index_start_ms=$(aad_now_ms)
trap '_asi_exit_rc=$?; surface_index_on_exit "$_asi_exit_rc"' EXIT
trap '_asi_exit_reason=signal_INT; exit 130' INT
trap '_asi_exit_reason=signal_TERM; exit 143' TERM
trap '_asi_exit_reason=signal_HUP; exit 129' HUP

echo $$ > "$AD_SURFACE_PID_FILE" 2>/dev/null
surface_status_write RUNNING
# A stale request from a previous crashed worker is satisfied by this run.
rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null

if [ "$(read_bool_setting BLOCK_ADS 1)" != "1" ]; then
    _asi_terminal_state=SKIPPED
    surface_status_write SKIPPED 0 BLOCK_ADS_0
    log "AD-SURFACE-INDEX skipped BLOCK_ADS=0"
    exit 0
fi

# Keep the last completed surface index intact while a new traversal runs.
# The running file is atomically committed only after SUMMARY is written.
_asi_final_surface_file="$AD_SURFACE_SCAN_FILE"
# The index lock is already held, so no other indexer can own a running file:
# anything left here is debris from a worker that was SIGKILLed before its EXIT
# trap could run (observed accumulating at ~200 KiB per killed run).
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

# Priority set: packages already known to carry ADS components/SDKs are indexed first.
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
surface_status_write RUNNING
log "AD-SURFACE-INDEX started pid=$$ packages/users=$_asi_total_count priority=$_asi_priority_count apk_inventory=$_asi_inventory_count"

while IFS='|' read -r _asi_user _asi_pkg _asi_vc; do
    [ -n "$_asi_pkg" ] || continue
    _asi_processed=$((_asi_processed + 1))
    AAD_CURRENT_VERSION_CODE="$_asi_vc"
    export AAD_CURRENT_VERSION_CODE
    record_ad_surface_scan_package "$_asi_user" "$_asi_pkg"
    if [ $((_asi_processed % 10)) -eq 0 ] || [ "$_asi_processed" -eq "$_asi_total_count" ]; then
        _asi_progress_now=$(aad_now_ms)
        _asi_progress_elapsed=$(aad_elapsed_ms "$_asi_index_start_ms" "$_asi_progress_now")
        surface_status_write RUNNING
        log "AD-SURFACE-PROGRESS processed=$_asi_processed total=$_asi_total_count elapsed_ms=$_asi_progress_elapsed"
    fi
done < "$AAD_SURFACE_ORDER_FILE"

_asi_traversal_now=$(aad_now_ms)
_asi_traversal_elapsed=$(aad_elapsed_ms "$_asi_index_start_ms" "$_asi_traversal_now")
log "AD-SURFACE-TRAVERSAL-COMPLETE processed=$_asi_processed total=$_asi_total_count elapsed_ms=$_asi_traversal_elapsed"
surface_append_terminal_record STATUS RUNNING \
    "AD-SURFACE-TRAVERSAL-COMPLETE processed=$_asi_processed total=$_asi_total_count" \
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

# Atomic last-known-good commit. Until this succeeds, the previous completed
# ad_surface_scan.log remains available to the Killer and diagnostics.
if ! mv -f "$_asi_work_surface_file" "$_asi_final_surface_file" 2>/dev/null; then
    _asi_exit_reason=surface_log_commit_failed
    log "AD-SURFACE-INDEX surface log commit failed work=$_asi_work_surface_file final=$_asi_final_surface_file"
    exit 1
fi
AD_SURFACE_SCAN_FILE="$_asi_final_surface_file"
export AD_SURFACE_SCAN_FILE
_asi_work_surface_file=""

_asi_terminal_state=COMPLETE
surface_status_write COMPLETE 0 normal
log "AD-SURFACE-SUMMARY $_asi_surface_summary priority_packages/users=$_asi_priority_count index_ms=$_asi_elapsed file=$AD_SURFACE_SCAN_FILE"
log "AD-SURFACE-INDEX finished packages/users=$_asi_processed elapsed_ms=$_asi_elapsed"

# Commit Banner/Native/App-Open network targets only from the atomically
# completed traversal. A partial/crashed surface index never replaces targets.
# Publish evidence for a companion Xposed module when such a framework exists.
# Purely informational: no hooking happens here and policy is unaffected.
aad_export_xposed_targets >/dev/null 2>&1 || true

if ad_killer_build_targets_from_surface; then
    _asi_killer_targets=$(grep -c . "$AD_KILLER_TARGET_FILE" 2>/dev/null); [ -n "$_asi_killer_targets" ] || _asi_killer_targets=0
    log "AD-KILLER targets committed=$_asi_killer_targets from=surface-index"
    reconcile_ad_surface_killer "surface-complete" || true
else
    log "AD-KILLER target build failed; preserving previous target set"
fi

if [ -f "$DATA_DIR/.surface_index.rerun" ]; then
    rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null
    log "AD-SURFACE-INDEX queued rerun starting"
    surface_index_cleanup
    trap - EXIT
    launch_ad_surface_indexer_bg "queued-rerun" >/dev/null 2>&1 || true
fi
exit 0
