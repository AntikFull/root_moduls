#!/system/bin/sh
# Action button: show compatibility profile and force a complete policy reconciliation.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

ensure_capability_profile >/dev/null 2>&1
load_capabilities

echo "$MODULE_VERSION_LABEL"
echo "PM disable: $CAP_PM_DISABLE_BACKEND $CAP_PM_DISABLE_VERB (user=$CAP_PM_DISABLE_HAS_USER exec=$CAP_PM_DISABLE_EXEC)"
echo "PM learned: ${CAP_PM_LEARNED_DISABLE_BACKEND:-none} ${CAP_PM_LEARNED_DISABLE_VERB:-disable} (user=${CAP_PM_LEARNED_DISABLE_HAS_USER:-1} exec=${CAP_PM_LEARNED_DISABLE_EXEC:-direct} token=${CAP_PM_LEARNED_DISABLE_USER_TOKEN:-numeric} verified=${CAP_PM_LEARNED_DISABLE_VERIFIED:-0})"
echo "PM enable : $CAP_PM_ENABLE_BACKEND $CAP_PM_ENABLE_VERB (user=$CAP_PM_ENABLE_HAS_USER exec=$CAP_PM_ENABLE_EXEC)"
echo "PM default: $CAP_PM_DEFAULT_BACKEND $CAP_PM_DEFAULT_VERB (user=$CAP_PM_DEFAULT_HAS_USER exec=$CAP_PM_DEFAULT_EXEC)"
echo "Restore DIS: $CAP_PM_STATE_DISABLED_BACKEND $CAP_PM_STATE_DISABLED_VERB (user=$CAP_PM_STATE_DISABLED_HAS_USER exec=$CAP_PM_STATE_DISABLED_EXEC exact=$CAP_PM_STATE_DISABLED_EXACT)"
echo "Users      : $CAP_USER_LIST_BACKEND"
echo "Packages   : $CAP_PACKAGE_LIST_BACKEND (user=$CAP_PACKAGE_LIST_HAS_USER versionCode=$CAP_PACKAGE_LIST_HAS_VERSIONCODE)"
echo "Dump       : $CAP_PACKAGE_DUMP_BACKEND"
echo "App watch  : $CAP_APP_WATCH_BACKEND"
echo "Mode       : $(read_component_mode)"
echo "Backend    : $(read_component_backend)"
echo "IFW rules  : $IFW_RULE_FILE ($(if [ -f "$IFW_RULE_FILE" ]; then echo present; else echo absent; fi))"
echo "Audit      : $COMPONENT_AUDIT_FILE"
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
sync_logs_to_sdcard
if [ "$status" -eq 0 ]; then
    echo "Done. Log: $LOGFILE"
elif [ "$status" -eq 2 ]; then
    echo "Stopped early after $AAD_FAIL_FAST_LIMIT consecutive failures."
    echo "Debug      : $LOGFILE"
    echo "Diagnostics: $DIAGFILE"
else
    echo "Rescan failed or lock timed out. Check: $LOGFILE"
fi
exit "$status"
