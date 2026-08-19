#!/system/bin/sh
MODDIR=${0%/*}
DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
export DATA_DIR
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

COMPONENT_STATE="${COMPONENT_STATE:-$DATA_DIR/component_state.list}"
IFW_RULE_FILE="${IFW_RULE_FILE:-/data/system/ifw/analytics_ads_disabler.xml}"
LOG_DIR="$DATA_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOGFILE="$LOG_DIR/uninstall.log"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
DEFERRED_DIR="/data/adb/analytics_ads_disabler_rollback"
HELPER_DIR="/data/adb/modules/analytics_ads_disabler_rollback"

ulog() { echo "[$(date 2>/dev/null)] $*" >> "$LOGFILE" 2>/dev/null; }

echo "=== [$(date 2>/dev/null)] ${MODULE_VERSION_LABEL:-Analytics & Ads Disabler} uninstall rollback ===" > "$LOGFILE"

mirror_log() {
    _lm_on=$(sed -n "s/^[[:space:]]*LOG_MIRROR[[:space:]]*=[[:space:]]*//p" "$DATA_DIR/settings.conf" 2>/dev/null | tail -n 1)
    [ "$_lm_on" = "1" ] || return 0
    mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall.log" 2>/dev/null || true
    else
        cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall.log" 2>/dev/null || true
    fi
}

stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$CONFIG_INOTIFY_PID_FILE" "config_event.sh"
stop_owned_pidfile "$LOG_MIRROR_PID_FILE" "log_mirror.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"
stop_owned_pidfile "$AD_SURFACE_PID_FILE" "ad_surface_indexer.sh"
stop_owned_pidfile "$DATA_DIR/rule_updater.pid" "rule_updater.sh"

_failed_firewall=0
if ! ad_killer_cleanup REMOVED "uninstall" >/dev/null 2>&1; then
    _failed_firewall=1
    ulog "FIREWALL CLEANUP FAILED/incomplete; recovery required"
fi

_failed_webview=0
if [ -f "$DATA_DIR/.webview_command_line_applied.cksum" ]; then
    if ! aad_restore_webview_owned_state "$DATA_DIR"; then
        _failed_webview=1
        ulog "WEBVIEW RESTORE FAILED/incomplete; ownership backup retained"
    fi
fi

_failed_settings=0
if [ -f "$DATA_DIR/.ad_id_backup" ]; then
    if ! aad_restore_owned_settings "$DATA_DIR"; then
        _failed_settings=1
        ulog "AD-ID RESTORE FAILED/incomplete; ownership backup retained"
    fi
fi

_failed_ifw=0
if [ -e "$IFW_RULE_FILE" ]; then
    _ifw_expected=$(cat "$DATA_DIR/.ifw_applied.cksum" 2>/dev/null)
    _ifw_current=$(cksum "$IFW_RULE_FILE" 2>/dev/null | awk '{print $1 ":" $2}')
    if [ -z "$_ifw_expected" ] || [ "$_ifw_current" != "$_ifw_expected" ]; then
        ulog "IFW PRESERVED: current content differs from module snapshot"
    elif rm -f "$IFW_RULE_FILE" 2>/dev/null; then
        ulog "IFW REMOVED $IFW_RULE_FILE"
    else
        _failed_ifw=1
        ulog "IFW REMOVE FAILED $IFW_RULE_FILE"
    fi
fi

_failed_appops=0
if [ -f "$DATA_DIR/.appops_state" ]; then
    if ! aad_restore_appops_state "" ""; then
        _failed_appops=1
        ulog "APPOPS RESTORE FAILED/incomplete; unresolved rows retained"
    fi
fi

boot_state=$(getprop sys.boot_completed 2>/dev/null)
_failed_components=0
if [ -s "$COMPONENT_STATE" ]; then
    if [ "$boot_state" = "1" ]; then
        ensure_capability_profile >/dev/null 2>&1
        load_capabilities
        if ! aad_restore_component_state_db "$COMPONENT_STATE"; then
            _failed_components=1
            ulog "COMPONENT RESTORE FAILED/incomplete; unresolved rows retained"
        fi
    else
        _failed_components=1
        ulog "COMPONENT RESTORE deferred: boot not complete"
    fi
fi

if [ "$_failed_components" -eq 0 ] && [ "$_failed_settings" -eq 0 ] && \
   [ "$_failed_appops" -eq 0 ] && [ "$_failed_webview" -eq 0 ] && \
   [ "$_failed_ifw" -eq 0 ] && [ "$_failed_firewall" -eq 0 ]; then
    ulog "All owned resources restored/preserved terminally; removing module data."
    mirror_log
    rm -rf "$DATA_DIR" "$DEFERRED_DIR" 2>/dev/null
    exit 0
fi

ulog "Rollback incomplete; building verified deferred recovery bundle."

copy_verified() {
    _cv_src="$1"; _cv_dst="$2"
    [ -f "$_cv_src" ] || return 1
    cp "$_cv_src" "$_cv_dst" 2>/dev/null || return 1
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$_cv_src" "$_cv_dst" || return 1
    else
        _cv_a=$(cksum "$_cv_src" 2>/dev/null | awk '{print $1 ":" $2}')
        _cv_b=$(cksum "$_cv_dst" 2>/dev/null | awk '{print $1 ":" $2}')
        [ -n "$_cv_a" ] && [ "$_cv_a" = "$_cv_b" ] || return 1
    fi
    return 0
}

_bundle_tmp="${DEFERRED_DIR}.tmp.$$"
_bundle_old="${DEFERRED_DIR}.old.$$"
rm -rf "$_bundle_tmp" "$_bundle_old" 2>/dev/null
mkdir -p "$_bundle_tmp" 2>/dev/null || { ulog "DEFERRED BUNDLE FAILED: mkdir"; mirror_log; exit 1; }
chmod 700 "$_bundle_tmp" 2>/dev/null || true

_bundle_fail=0
copy_verified "$MODDIR/common.sh" "$_bundle_tmp/common.sh" || _bundle_fail=1
copy_verified "$MODDIR/compat.sh" "$_bundle_tmp/compat.sh" || _bundle_fail=1

# Copy every piece of unresolved ownership state that exists. Existing files are mandatory.
for _name in component_state.list capabilities.conf settings.conf .appops_state .ad_id_backup \
             .webview_command_line_backup .webview_command_line_applied.cksum .ifw_applied.cksum; do
    _src="$DATA_DIR/$_name"
    if [ -f "$_src" ]; then
        copy_verified "$_src" "$_bundle_tmp/$_name" || _bundle_fail=1
    fi
done

cat > "$_bundle_tmp/rollback.sh" <<'DEFERRED'
#!/system/bin/sh
DEFERRED_DIR="/data/adb/analytics_ads_disabler_rollback"
HELPER_DIR="/data/adb/modules/analytics_ads_disabler_rollback"
LOGFILE="$DEFERRED_DIR/rollback.log"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
DATA_DIR="$DEFERRED_DIR"
CAPABILITIES_FILE="$DEFERRED_DIR/capabilities.conf"
MODDIR="$DEFERRED_DIR"
AAD_DEFER_CAPABILITY_INIT=1
export DATA_DIR CAPABILITIES_FILE MODDIR AAD_DEFER_CAPABILITY_INIT LOGFILE

rlog() { echo "[$(date 2>/dev/null)] $*" >> "$LOGFILE" 2>/dev/null; }
: > "$LOGFILE" 2>/dev/null
rlog "Deferred rollback worker started pid=$$"

waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    waited=$((waited + 1))
    [ "$waited" -ge 180 ] && { rlog "boot_completed never observed; retaining recovery bundle"; exit 1; }
    sleep 5
done
sleep 20

if [ ! -f "$DEFERRED_DIR/common.sh" ] || [ ! -f "$DEFERRED_DIR/compat.sh" ]; then
    rlog "required recovery helpers missing; retaining bundle"
    exit 1
fi
. "$DEFERRED_DIR/common.sh"
ensure_capability_profile >/dev/null 2>&1
load_capabilities

failed_components=0
if [ -s "$DEFERRED_DIR/component_state.list" ]; then
    aad_restore_component_state_db "$DEFERRED_DIR/component_state.list" || failed_components=1
fi

failed_settings=0
if [ -f "$DEFERRED_DIR/.ad_id_backup" ]; then
    command -v settings >/dev/null 2>&1 && aad_restore_owned_settings "$DEFERRED_DIR" || failed_settings=1
fi

failed_webview=0
if [ -f "$DEFERRED_DIR/.webview_command_line_applied.cksum" ]; then
    command -v cksum >/dev/null 2>&1 && aad_restore_webview_owned_state "$DEFERRED_DIR" || failed_webview=1
fi

failed_appops=0
if [ -f "$DEFERRED_DIR/.appops_state" ]; then
    command -v cmd >/dev/null 2>&1 && aad_restore_appops_state "" "" || failed_appops=1
fi

failed_ifw=0
IFW_RULE_FILE="/data/system/ifw/analytics_ads_disabler.xml"
if [ -e "$IFW_RULE_FILE" ] && [ -f "$DEFERRED_DIR/.ifw_applied.cksum" ]; then
    _iexp=$(cat "$DEFERRED_DIR/.ifw_applied.cksum" 2>/dev/null)
    _icur=$(cksum "$IFW_RULE_FILE" 2>/dev/null | awk '{print $1 ":" $2}')
    if [ -n "$_iexp" ] && [ "$_icur" = "$_iexp" ]; then
        rm -f "$IFW_RULE_FILE" 2>/dev/null || failed_ifw=1
    fi
fi

failed_firewall=0
ad_killer_cleanup REMOVED "deferred-uninstall" >/dev/null 2>&1 || failed_firewall=1

rlog "Deferred rollback result comp=$failed_components settings=$failed_settings appops=$failed_appops webview=$failed_webview ifw=$failed_ifw firewall=$failed_firewall"

_lm_on=$(sed -n "s/^[[:space:]]*LOG_MIRROR[[:space:]]*=[[:space:]]*//p" "$DEFERRED_DIR/settings.conf" 2>/dev/null | tail -n 1)
if [ "$_lm_on" = "1" ]; then
    mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null
    cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall_deferred.log" 2>/dev/null || true
fi

if [ "$failed_components" -eq 0 ] && [ "$failed_settings" -eq 0 ] && [ "$failed_appops" -eq 0 ] && \
   [ "$failed_webview" -eq 0 ] && [ "$failed_ifw" -eq 0 ] && [ "$failed_firewall" -eq 0 ]; then
    rm -rf "$DEFERRED_DIR" 2>/dev/null
    touch "$HELPER_DIR/remove" 2>/dev/null || true
    exit 0
fi
rlog "Recovery remains pending; bundle retained for next boot."
exit 1
DEFERRED
chmod 755 "$_bundle_tmp/rollback.sh" 2>/dev/null || _bundle_fail=1
sh -n "$_bundle_tmp/rollback.sh" >/dev/null 2>&1 || _bundle_fail=1

if [ "$_bundle_fail" -ne 0 ]; then
    ulog "DEFERRED BUNDLE FAILED verification; original DATA_DIR retained"
    rm -rf "$_bundle_tmp" 2>/dev/null
    mirror_log
    exit 1
fi

# Publish recovery bundle atomically without destroying a previous valid bundle on failure.
[ -d "$DEFERRED_DIR" ] && mv "$DEFERRED_DIR" "$_bundle_old" 2>/dev/null || true
if ! mv "$_bundle_tmp" "$DEFERRED_DIR" 2>/dev/null; then
    [ -d "$_bundle_old" ] && mv "$_bundle_old" "$DEFERRED_DIR" 2>/dev/null || true
    ulog "DEFERRED BUNDLE PUBLISH FAILED; original DATA_DIR retained"
    mirror_log
    exit 1
fi
rm -rf "$_bundle_old" 2>/dev/null

# Publish the helper module only after the recovery bundle is complete.
mkdir -p "$HELPER_DIR" 2>/dev/null || { ulog "ROLLBACK HELPER CREATE FAILED; source state retained"; mirror_log; exit 1; }
cat > "$HELPER_DIR/module.prop.tmp.$$" <<'PROP'
id=analytics_ads_disabler_rollback
name=Analytics & Ads Disabler - pending rollback
version=2
versionCode=2
author=eCubz
description=Temporary helper: transactionally restores Analytics & Ads Disabler owned state, then removes itself.
PROP
cat > "$HELPER_DIR/service.sh.tmp.$$" <<'SVC'
#!/system/bin/sh
DEFERRED_DIR="/data/adb/analytics_ads_disabler_rollback"
if [ -x "$DEFERRED_DIR/rollback.sh" ]; then
    "$DEFERRED_DIR/rollback.sh"
fi
if [ ! -d "$DEFERRED_DIR" ]; then
    touch /data/adb/modules/analytics_ads_disabler_rollback/remove 2>/dev/null
fi
SVC
if ! mv -f "$HELPER_DIR/module.prop.tmp.$$" "$HELPER_DIR/module.prop" 2>/dev/null || \
   ! mv -f "$HELPER_DIR/service.sh.tmp.$$" "$HELPER_DIR/service.sh" 2>/dev/null || \
   ! chmod 755 "$HELPER_DIR/service.sh" 2>/dev/null; then
    ulog "ROLLBACK HELPER PUBLISH FAILED; source DATA_DIR retained"
    mirror_log
    exit 1
fi

ulog "Verified deferred rollback armed at $DEFERRED_DIR."
mirror_log
"$DEFERRED_DIR/rollback.sh" >/dev/null 2>&1 &

# Safe only now: either rollback completed above, or a verified self-contained recovery bundle+helper exists.
rm -rf "$DATA_DIR" 2>/dev/null
exit 0
