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
    echo "Scan SYSTEM apps too? (advanced / higher risk)"
    echo "  VOL+ = NO  [SAFE DEFAULT]"
    echo "  VOL- = YES [explicit opt-in]"
    echo "  Current: $( [ "$current" = "1" ] && echo YES || echo NO )"
    if action_volume_select yes 30; then
        echo "  -> NO (safe)"
        return 1
    fi
    echo "  -> YES (explicit opt-in)"
    return 0
}

action_risky_opt_in() {
    prompt="$1"; current="$2"
    echo ""
    echo "$prompt"
    echo "  VOL+ = NO  [SAFE DEFAULT]"
    echo "  VOL- = YES [explicit opt-in]"
    echo "  Current: $( [ "$current" = "1" ] && echo YES || echo NO )"
    if action_volume_select yes 30; then
        echo "  -> NO (safe)"
        return 1
    fi
    echo "  -> YES (explicit opt-in)"
    return 0
}

action_write_settings() {
    tmp=$(aad_mktemp_near "$SETTINGS_FILE")
    [ -n "$tmp" ] || return 1
    awk -v ads="$CFG_ADS" -v analytics="$CFG_ANALYTICS" -v mode="$CFG_MODE" -v backend="$CFG_BACKEND" \
        -v allusers="$CFG_ALL_USERS" -v systemapps="$CFG_SYSTEM_APPS" -v killer="$CFG_KILLER" -v forcetcp="$CFG_KILLER_FORCE_TCP" '
        /^[[:space:]]*BLOCK_ADS[[:space:]]*=/ {print "BLOCK_ADS=" ads; a=1; next}
        /^[[:space:]]*BLOCK_ANALYTICS[[:space:]]*=/ {print "BLOCK_ANALYTICS=" analytics; n=1; next}
        /^[[:space:]]*COMPONENT_MODE[[:space:]]*=/ {print "COMPONENT_MODE=" mode; m=1; next}
        /^[[:space:]]*COMPONENT_BACKEND[[:space:]]*=/ {print "COMPONENT_BACKEND=" backend; b=1; next}
        /^[[:space:]]*SCAN_ALL_USERS[[:space:]]*=/ {print "SCAN_ALL_USERS=" allusers; u=1; next}
        /^[[:space:]]*SCAN_SYSTEM_APPS[[:space:]]*=/ {print "SCAN_SYSTEM_APPS=" systemapps; s=1; next}
        /^[[:space:]]*AD_SURFACE_KILLER[[:space:]]*=/ {print "AD_SURFACE_KILLER=" killer; k=1; next}
        /^[[:space:]]*AD_KILLER_FORCE_TCP[[:space:]]*=/ {print "AD_KILLER_FORCE_TCP=" forcetcp; q=1; next}
        {print}
        END {
            if (!a) print "BLOCK_ADS=" ads
            if (!n) print "BLOCK_ANALYTICS=" analytics
            if (!m) print "COMPONENT_MODE=" mode
            if (!b) print "COMPONENT_BACKEND=" backend
            if (!u) print "SCAN_ALL_USERS=" allusers
            if (!s) print "SCAN_SYSTEM_APPS=" systemapps
            if (!k) print "AD_SURFACE_KILLER=" killer
            if (!q) print "AD_KILLER_FORCE_TCP=" forcetcp
        }
    ' "$SETTINGS_FILE" > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$SETTINGS_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

echo "$MODULE_VERSION_LABEL"
echo "PM disable: $CAP_PM_DISABLE_BACKEND $CAP_PM_DISABLE_VERB (user=$CAP_PM_DISABLE_HAS_USER exec=$CAP_PM_DISABLE_EXEC)"
echo "PM learned: ${CAP_PM_LEARNED_DISABLE_BACKEND:-none} ${CAP_PM_LEARNED_DISABLE_VERB:-disable} (user=${CAP_PM_LEARNED_DISABLE_HAS_USER:-1} exec=${CAP_PM_LEARNED_DISABLE_EXEC:-direct} token=${CAP_PM_LEARNED_DISABLE_USER_TOKEN:-numeric} verified=${CAP_PM_LEARNED_DISABLE_VERIFIED:-0})"
echo "PM enable : $CAP_PM_ENABLE_BACKEND $CAP_PM_ENABLE_VERB (user=$CAP_PM_ENABLE_HAS_USER exec=$CAP_PM_ENABLE_EXEC)"
echo "PM default: $CAP_PM_DEFAULT_BACKEND $CAP_PM_DEFAULT_VERB (user=$CAP_PM_DEFAULT_HAS_USER exec=$CAP_PM_DEFAULT_EXEC)"
echo "Restore DIS: $CAP_PM_STATE_DISABLED_BACKEND $CAP_PM_STATE_DISABLED_VERB (user=$CAP_PM_STATE_DISABLED_HAS_USER exec=$CAP_PM_STATE_DISABLED_EXEC exact=$CAP_PM_STATE_DISABLED_EXACT)"
echo "Users      : $CAP_USER_LIST_BACKEND"
echo "Packages   : $CAP_PACKAGE_LIST_BACKEND (user=$CAP_PACKAGE_LIST_HAS_USER versionCode=$CAP_PACKAGE_LIST_HAS_VERSIONCODE)"
echo "Dump       : $CAP_PACKAGE_DUMP_BACKEND"
echo "Activity scan: resolver + AXML StringPool parser (UTF-8/UTF-16)"
echo "App watch  : $CAP_APP_WATCH_BACKEND"
echo "Mode       : $(read_component_mode)"
echo "Backend    : $(read_component_backend)"
echo "ADS        : $( [ "$(read_bool_setting BLOCK_ADS 1)" = "1" ] && echo ON || echo OFF )"
echo "Analytics  : $( [ "$(read_bool_setting BLOCK_ANALYTICS 1)" = "1" ] && echo ON || echo OFF )"
echo "All users  : $( [ "$(read_bool_setting SCAN_ALL_USERS 1)" = "1" ] && echo ON || echo OFF )"
echo "System apps: $( [ "$(read_bool_setting SCAN_SYSTEM_APPS 0)" = "1" ] && echo ON || echo OFF )"
echo "Ad Killer   : $( [ "$(read_bool_setting AD_SURFACE_KILLER 1)" = "1" ] && echo ON || echo OFF ) (AGGRESSIVE only)"
echo "Killer QUIC : $( [ "$(read_bool_setting AD_KILLER_FORCE_TCP 0)" = "1" ] && echo FORCE-TCP || echo KEEP )"
echo "Killer mode : $(read_setting AD_KILLER_MODE auto) (ip_fallback=$(read_bool_setting AD_KILLER_IP_FALLBACK 0) min_confidence=$(ad_killer_min_confidence))"
echo "Push SDKs   : $( [ "$(read_bool_setting BLOCK_PUSH_SDK 0)" = "1" ] && echo BLOCKED || echo "REPORT-ONLY (notifications preserved)" )"
echo "Xposed      : $(aad_detect_xposed 2>/dev/null || echo "not detected") bridge=$(read_setting XPOSED_BRIDGE auto)$( [ -f "$XPOSED_TARGET_LIST" ] && echo " targets=$(grep -c . "$XPOSED_TARGET_LIST" 2>/dev/null)" )"
echo "Toolchain   : busybox=${AAD_BUSYBOX:-none} awk=$(command -v awk 2>/dev/null || echo MISSING) unzip=$(command -v unzip 2>/dev/null || echo MISSING) od=$(command -v od 2>/dev/null || echo MISSING)"
if [ -f "$AD_KILLER_STATUS_FILE" ]; then
    _act_k_state=$(sed -n 's/^state=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n 1)
    _act_k_targets=$(sed -n 's/^targets=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n 1)
    _act_k_pkgs=$(sed -n 's/^packages_users=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n 1)
    echo "Killer state: ${_act_k_state:-unknown} targets=${_act_k_targets:-0} packages/users=${_act_k_pkgs:-0}"
else
    echo "Killer state: NOT_INITIALIZED"
fi
echo "IFW Activity limit: $(read_ifw_activity_limit)"
echo "IFW rules  : $IFW_RULE_FILE ($(if [ -f "$IFW_RULE_FILE" ]; then echo present; else echo absent; fi))"
echo "Settings   : $SETTINGS_FILE"
echo "Audit      : $COMPONENT_AUDIT_FILE"
echo "SDK scan   : $SDK_FINGERPRINT_FILE"
echo "Manifest   : $MANIFEST_SCAN_FILE"
echo "Ad surfaces: $AD_SURFACE_SCAN_FILE"

echo ""
echo "Action menu:"
echo "  VOL+ within 5s = SETTINGS"
echo "  VOL- / no key  = RESCAN"
CONFIGURE=0
if action_volume_select no 5; then CONFIGURE=1; fi

if [ "$CONFIGURE" -eq 1 ]; then
    CFG_ADS=$(read_bool_setting BLOCK_ADS 1)
    CFG_ANALYTICS=$(read_bool_setting BLOCK_ANALYTICS 1)
    CFG_MODE=$(read_component_mode)
    CFG_BACKEND=$(read_component_backend)
    CFG_ALL_USERS=$(read_bool_setting SCAN_ALL_USERS 1)
    CFG_SYSTEM_APPS=$(read_bool_setting SCAN_SYSTEM_APPS 0)
    CFG_KILLER=$(read_bool_setting AD_SURFACE_KILLER 1)
    CFG_KILLER_FORCE_TCP=$(read_bool_setting AD_KILLER_FORCE_TCP 0)

    action_yes_no "Block ADVERTISING components?" "$CFG_ADS" && CFG_ADS=1 || CFG_ADS=0
    action_yes_no "Block ANALYTICS / tracking components?" "$CFG_ANALYTICS" && CFG_ANALYTICS=1 || CFG_ANALYTICS=0

    current_aggressive=0; [ "$CFG_MODE" = "AGGRESSIVE" ] && current_aggressive=1
    if action_yes_no "Use AGGRESSIVE mode?" "$current_aggressive"; then
        CFG_MODE=AGGRESSIVE
    else
        current_balanced=0; [ "$CFG_MODE" = "BALANCED" ] && current_balanced=1
        if action_yes_no "Use BALANCED mode? (NO = SAFE)" "$current_balanced"; then CFG_MODE=BALANCED; else CFG_MODE=SAFE; fi
    fi

    current_hybrid=0; [ "$CFG_BACKEND" = "HYBRID" ] && current_hybrid=1
    if action_yes_no "Use HYBRID IFW + PM backend?" "$current_hybrid"; then
        if probe_ifw_storage; then
            CFG_BACKEND=HYBRID
        else
            echo "  ! IFW storage unavailable; keeping PM backend."
            CFG_BACKEND=PM
        fi
    else
        CFG_BACKEND=PM
    fi
    action_yes_no "Scan ALL Android users/profiles?" "$CFG_ALL_USERS" && CFG_ALL_USERS=1 || CFG_ALL_USERS=0
    action_system_apps_opt_in "$CFG_SYSTEM_APPS" && CFG_SYSTEM_APPS=1 || CFG_SYSTEM_APPS=0
    action_yes_no "Enable Banner/Native/App-Open network Killer? (AGGRESSIVE only)" "$CFG_KILLER" && CFG_KILLER=1 || CFG_KILLER=0
    action_risky_opt_in "Force targeted apps off QUIC/UDP 443 so TLS hostname blocking cannot be bypassed?" "$CFG_KILLER_FORCE_TCP" && CFG_KILLER_FORCE_TCP=1 || CFG_KILLER_FORCE_TCP=0

    echo ""
    echo "New settings:"
    echo "  ADS=$CFG_ADS ANALYTICS=$CFG_ANALYTICS"
    echo "  MODE=$CFG_MODE BACKEND=$CFG_BACKEND"
    echo "  ALL_USERS=$CFG_ALL_USERS SYSTEM_APPS=$CFG_SYSTEM_APPS"
    echo "  AD_KILLER=$CFG_KILLER FORCE_TCP=$CFG_KILLER_FORCE_TCP"
    echo "  VOL+ = APPLY + RESCAN    VOL- = CANCEL + RESCAN"
    if action_volume_select yes 30; then
        if acquire_lock; then
            if action_write_settings; then
                log "ACTION-SETTINGS applied ads=$CFG_ADS analytics=$CFG_ANALYTICS mode=$CFG_MODE backend=$CFG_BACKEND all_users=$CFG_ALL_USERS system_apps=$CFG_SYSTEM_APPS ad_killer=$CFG_KILLER force_tcp=$CFG_KILLER_FORCE_TCP"
                echo "Settings saved. Applying policy now..."
                AAD_SHOW_PROGRESS=1
                AAD_FAIL_FAST_LIMIT=3
                export AAD_SHOW_PROGRESS AAD_FAIL_FAST_LIMIT
                full_rescan_locked
                status=$?
                [ "$status" -eq 0 ] && refresh_policy_caches
                release_lock
                [ "$status" -eq 0 ] && reconcile_ad_surface_killer "action-settings" >/dev/null 2>&1 || true
                [ "$status" -eq 0 ] && launch_ad_surface_indexer_bg "action-settings" >/dev/null 2>&1 || true
                sync_logs_to_sdcard
                [ "$status" -eq 0 ] && echo "Ad Surface index refresh queued in background."
                [ "$status" -eq 0 ] && echo "Done. Settings applied without reinstall. Log: $LOGFILE"
                exit "$status"
            fi
            release_lock
            echo "Failed to save settings; old settings preserved."
        else
            echo "Could not acquire scan lock; settings were not changed."
        fi
    else
        echo "Settings change cancelled. Running rescan with current settings."
    fi
fi

echo "Execution diagnostics:"
echo "  direct: uid=$(id -u 2>/dev/null) ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\000')"
if command -v su >/dev/null 2>&1; then
    echo "  su 2000: $(su 2000 -c 'printf "uid="; id -u; printf " ctx="; cat /proc/self/attr/current 2>/dev/null' 2>/dev/null | tr '\n' ' ' | tr -d '\000')"
    echo "  su shell: $(su shell -c 'printf "uid="; id -u; printf " ctx="; cat /proc/self/attr/current 2>/dev/null' 2>/dev/null | tr '\n' ' ' | tr -d '\000')"
fi
if cap_runcon_shell_available; then
    echo "  runcon shell uid0: available (u:r:shell:s0 transition verified)"
else
    echo "  runcon shell uid0: unavailable/transition denied"
fi
LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
[ -f "$LOG_DIR/install_diagnostics.log" ] && echo "Install diag: $LOG_DIR/install_diagnostics.log (mirrored: $SDCARD_LOG_DIR/install_diagnostics.log)"
echo "Collecting deep diagnostics..."
collect_deep_diagnostics
sync_logs_to_sdcard
echo "Diagnostics: $DIAGFILE"
echo "Running full rescan..."
AAD_SHOW_PROGRESS=1
AAD_FAIL_FAST_LIMIT=3
export AAD_SHOW_PROGRESS AAD_FAIL_FAST_LIMIT
echo "Fail-fast : stop after $AAD_FAIL_FAST_LIMIT consecutive component failures"
full_rescan
status=$?
[ "$status" -eq 0 ] && reconcile_ad_surface_killer "action-rescan" >/dev/null 2>&1 || true
[ "$status" -eq 0 ] && launch_ad_surface_indexer_bg "action-rescan" >/dev/null 2>&1 || true
sync_logs_to_sdcard
if [ "$status" -eq 0 ]; then
    echo "Ad Surface index refresh queued in background."
    echo "Done. Log: $LOGFILE"
elif [ "$status" -eq 2 ]; then
    echo "Stopped early after $AAD_FAIL_FAST_LIMIT consecutive failures."
    echo "Debug      : $LOGFILE"
    echo "Diagnostics: $DIAGFILE"
else
    echo "Rescan failed or lock timed out. Check: $LOGFILE"
fi
exit "$status"
