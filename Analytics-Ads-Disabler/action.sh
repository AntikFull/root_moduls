#!/system/bin/sh
# Action button: show compatibility profile and force a complete policy reconciliation.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

ensure_capability_profile >/dev/null 2>&1
load_capabilities

echo "Analytics & Ads Disabler v4.2"
echo "PM disable: $CAP_PM_DISABLE_BACKEND $CAP_PM_DISABLE_VERB (user=$CAP_PM_DISABLE_HAS_USER)"
echo "PM enable : $CAP_PM_ENABLE_BACKEND $CAP_PM_ENABLE_VERB (user=$CAP_PM_ENABLE_HAS_USER)"
echo "PM default: $CAP_PM_DEFAULT_BACKEND $CAP_PM_DEFAULT_VERB (user=$CAP_PM_DEFAULT_HAS_USER)"
echo "Restore DIS: $CAP_PM_STATE_DISABLED_BACKEND $CAP_PM_STATE_DISABLED_VERB (user=$CAP_PM_STATE_DISABLED_HAS_USER exact=$CAP_PM_STATE_DISABLED_EXACT)"
echo "Users      : $CAP_USER_LIST_BACKEND"
echo "Packages   : $CAP_PACKAGE_LIST_BACKEND (user=$CAP_PACKAGE_LIST_HAS_USER versionCode=$CAP_PACKAGE_LIST_HAS_VERSIONCODE)"
echo "Dump       : $CAP_PACKAGE_DUMP_BACKEND"
echo "App watch  : $CAP_APP_WATCH_BACKEND"
echo "Running full rescan..."
full_rescan
status=$?
if [ "$status" -eq 0 ]; then
    echo "Done. Log: $LOGFILE"
else
    echo "Rescan failed or lock timed out. Check: $LOGFILE"
fi
exit "$status"
