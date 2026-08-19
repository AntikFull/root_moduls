#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

ensure_capability_profile >/dev/null 2>&1
load_capabilities

action_volume_select() {
    default_answer="$1"
    timeout_s="${2:-30}"
    if ! command -v getevent >/dev/null 2>&1; then
        [ "$default_answer" = "yes" ] && return 0
        return 1
    fi
    tries=0
    while [ "$tries" -lt 40 ]; do
        tries=$((tries + 1))
        if command -v timeout >/dev/null 2>&1; then
            event=$(timeout "$timeout_s" getevent -qlc 1 2>/dev/null)
            if [ -z "$event" ]; then
                [ "$default_answer" = "yes" ] && return 0
                return 1
            fi
        else
            event=$(getevent -qlc 1 2>/dev/null)
            [ -n "$event" ] || { [ "$default_answer" = "yes" ] && return 0; return 1; }
        fi
        echo "$event" | grep -q "KEY_VOLUMEUP.*DOWN" && return 0
        echo "$event" | grep -q "KEY_VOLUMEDOWN.*DOWN" && return 1
    done
    [ "$default_answer" = "yes" ] && return 0
    return 1
}

action_yes_no() {
    prompt="$1"; current="$2"
    echo ""
    echo "$prompt"
    echo "  VOL+ = YES    VOL- = NO"
    echo "  Current: $( [ "$current" = "1" ] && echo YES || echo NO )"
    if action_volume_select "$( [ "$current" = "1" ] && echo yes || echo no )" 30; then
        echo "  -> YES"
        return 0
    fi
    echo "  -> NO"
    return 1
}

action_system_apps_opt_in() {
    current="$1"
    echo ""
    echo "Process SYSTEM applications too? (advanced / higher risk)"
    echo "  VOL+ = NO  [RECOMMENDED]"
    echo "  VOL- = YES [explicit opt-in]"
    echo "  Current: $( [ "$current" = "1" ] && echo YES || echo NO )"
    if action_volume_select yes 30; then
        echo "  -> NO (system apps excluded)"
        return 1
    fi
    echo "  -> YES (system apps included)"
    return 0
}

action_write_settings() {
    tmp=$(aad_mktemp_near "$SETTINGS_FILE")
    [ -n "$tmp" ] || return 1
    awk -v ads="$CFG_ADS" -v analytics="$CFG_ANALYTICS" -v systemapps="$CFG_SYSTEM_APPS" '
        /^[[:space:]]*BLOCK_ADS[[:space:]]*=/ {print "BLOCK_ADS=" ads; a=1; next}
        /^[[:space:]]*BLOCK_ANALYTICS[[:space:]]*=/ {print "BLOCK_ANALYTICS=" analytics; n=1; next}
        /^[[:space:]]*INCLUDE_SYSTEM_APPS[[:space:]]*=/ {print "INCLUDE_SYSTEM_APPS=" systemapps; s=1; next}
        /^[[:space:]]*SCAN_SYSTEM_APPS[[:space:]]*=/ {next}
        {print}
        END {
            if (!a) print "BLOCK_ADS=" ads
            if (!n) print "BLOCK_ANALYTICS=" analytics
            if (!s) print "INCLUDE_SYSTEM_APPS=" systemapps
        }
    ' "$SETTINGS_FILE" > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$SETTINGS_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

action_running_surface_pid() {
    _arsp_pid=$(cat "$AD_SURFACE_PID_FILE" 2>/dev/null)
    case "$_arsp_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_arsp_pid" 2>/dev/null || return 1
    aad_pid_matches_marker "$_arsp_pid" "ad_surface_indexer.sh" || return 1
    printf '%s\n' "$_arsp_pid"
}

echo "==============================================="
echo " $MODULE_VERSION_LABEL"
echo " Author: eCubz (https://t.me/eCubz)"
echo "==============================================="
echo "Backend    : PM per-user (isolated multi-user)"
echo "ADS        : $( [ "$(read_bool_setting BLOCK_ADS 0)" = "1" ] && echo ON || echo OFF )"
echo "Analytics  : $( [ "$(read_bool_setting BLOCK_ANALYTICS 0)" = "1" ] && echo ON || echo OFF )"
echo "System apps: $( [ "$(read_include_system_apps)" = "1" ] && echo ON || echo OFF )"
echo "Ad Killer  : $( [ "$(read_bool_setting AD_SURFACE_KILLER 1)" = "1" ] && echo ON || echo OFF )"
echo "Toolchain  : busybox=${AAD_BUSYBOX:-none} awk=$(command -v awk 2>/dev/null || echo MISSING)"

if [ -f "$AD_KILLER_STATUS_FILE" ]; then
    _act_k_state=$(sed -n 's/^state=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n 1)
    _act_k_targets=$(sed -n 's/^targets=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n 1)
    echo "Killer net : ${_act_k_state:-unknown} targets=${_act_k_targets:-0}"
fi
echo "Settings   : $SETTINGS_FILE"
echo "Audit Log  : $COMPONENT_AUDIT_FILE"

echo ""
echo "Action menu:"
echo "  VOL+ within 5s = SETTINGS (reconfigure)"
echo "  VOL- / no key  = RESCAN (apply current)"
CONFIGURE=0
if action_volume_select no 5; then CONFIGURE=1; fi

ACTIVE_SURFACE_PID=$(action_running_surface_pid 2>/dev/null)
if [ -n "$ACTIVE_SURFACE_PID" ]; then
    _act_surface_state=$(sed -n 's/^state=//p' "$AD_SURFACE_STATUS_FILE" 2>/dev/null | head -n 1)
    echo ""
    echo "Ad Surface Indexer is already running: pid=$ACTIVE_SURFACE_PID state=${_act_surface_state:-RUNNING}."
    echo "Action stopped safely to prevent concurrent indexer collision."
    exit 3
fi

if [ "$CONFIGURE" -eq 1 ]; then
    CFG_ADS=$(read_bool_setting BLOCK_ADS 0)
    CFG_ANALYTICS=$(read_bool_setting BLOCK_ANALYTICS 0)
    CFG_SYSTEM_APPS=$(read_include_system_apps)

    action_yes_no "1. Block ADVERTISING components & banners?" "$CFG_ADS" && CFG_ADS=1 || CFG_ADS=0
    action_yes_no "2. Block ANALYTICS & tracking components?" "$CFG_ANALYTICS" && CFG_ANALYTICS=1 || CFG_ANALYTICS=0
    action_system_apps_opt_in "$CFG_SYSTEM_APPS" && CFG_SYSTEM_APPS=1 || CFG_SYSTEM_APPS=0

    echo ""
    echo "New configuration:"
    echo "  BLOCK_ADS=$CFG_ADS"
    echo "  BLOCK_ANALYTICS=$CFG_ANALYTICS"
    echo "  INCLUDE_SYSTEM_APPS=$CFG_SYSTEM_APPS"
    echo ""
    echo "  VOL+ = APPLY NOW    VOL- = CANCEL"
    if action_volume_select yes 30; then
        if action_write_settings; then
            log "ACTION-SETTINGS applied ads=$CFG_ADS analytics=$CFG_ANALYTICS include_system_apps=$CFG_SYSTEM_APPS"
            echo "Settings saved. Applying policy reconciliation..."
            AAD_SHOW_PROGRESS=1
            AAD_FAIL_FAST_LIMIT=3
            export AAD_SHOW_PROGRESS AAD_FAIL_FAST_LIMIT
            reconcile_config_if_changed "action-settings"
            status=$?
            echo "Done. Status rc=$status. Log: $LOGFILE"
            exit "$status"
        else
            echo "Failed to save settings; existing configuration preserved."
        fi
    else
        echo "Settings change cancelled."
    fi
fi

echo "Running full reconciliation with current settings..."
AAD_SHOW_PROGRESS=1
AAD_FAIL_FAST_LIMIT=3
export AAD_SHOW_PROGRESS AAD_FAIL_FAST_LIMIT
full_rescan
status=$?
if [ "$status" -eq 0 ]; then
    echo "Done. Rescan completed successfully. Log: $LOGFILE"
elif [ "$status" -eq 2 ]; then
    echo "Stopped early after consecutive component failures. Log: $LOGFILE"
else
    echo "Rescan failed. Check log: $LOGFILE"
fi
exit "$status"
