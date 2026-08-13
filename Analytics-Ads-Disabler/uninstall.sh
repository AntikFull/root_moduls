#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
COMPONENT_STATE="${COMPONENT_STATE:-$DATA_DIR/component_state.list}"
IFW_RULE_FILE="${IFW_RULE_FILE:-/data/system/ifw/analytics_ads_disabler.xml}"
LOG_DIR="$DATA_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
LOGFILE="$LOG_DIR/uninstall.log"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
DEFERRED_DIR="/data/adb/analytics_ads_disabler_rollback"

ulog() {
    echo "[$(date 2>/dev/null)] $*" >> "$LOGFILE" 2>/dev/null
}

echo "=== [$(date 2>/dev/null)] ${MODULE_VERSION_LABEL:-Analytics & Ads Disabler} uninstall rollback ===" > "$LOGFILE"

stop_owned_pidfile "$WATCH_PID_FILE" "config_watch.sh"
stop_owned_pidfile "$INOTIFY_PID_FILE" "on_app_installed.sh"
stop_owned_pidfile "$CONFIG_INOTIFY_PID_FILE" "config_event.sh"
stop_owned_pidfile "$LOG_MIRROR_PID_FILE" "log_mirror.sh"
stop_owned_pidfile "$DATA_DIR/category_watch.pid" "category_watch.sh"
stop_owned_pidfile "$AD_SURFACE_PID_FILE" "ad_surface_indexer.sh"

ad_killer_cleanup >/dev/null 2>&1 || true

# РЈРґР°Р»СЏРµС‚СЃСЏ С‚РѕР»СЊРєРѕ СЃРѕР±СЃС‚РІРµРЅРЅС‹Р№ IFW-С„Р°Р№Р»; РїСЂР°РІРёР»Р° App Manager, Blocker Рё РґСЂСѓРіРёС… РїСЂРѕРіСЂР°РјРј РЅРµ Р·Р°С‚СЂР°РіРёРІР°СЋС‚СЃСЏ.
if [ -e "$IFW_RULE_FILE" ]; then
    if rm -f "$IFW_RULE_FILE" 2>/dev/null; then
        ulog "IFW REMOVED $IFW_RULE_FILE"
    else
        ulog "IFW REMOVE FAILED $IFW_RULE_FILE"
    fi
fi

mirror_log() {
    mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall.log" 2>/dev/null || true
    else
        cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall.log" 2>/dev/null || true
    fi
}

boot_state=$(getprop sys.boot_completed 2>/dev/null)

if [ ! -s "$COMPONENT_STATE" ]; then
    ulog "No saved component states; nothing to restore."
    mirror_log
    rm -rf "$DATA_DIR" 2>/dev/null
    exit 0
fi

if [ "$boot_state" = "1" ]; then
    ensure_capability_profile >/dev/null 2>&1
    load_capabilities
    failed=0
    total=0
    cp "$COMPONENT_STATE" "$COMPONENT_STATE.uninstall_work" 2>/dev/null
    while IFS='|' read -r user comp original; do
        [ -z "$comp" ] && continue
        total=$((total + 1))
        if set_component_state_smart "$user" "$comp" "${original:-default}"; then
            ulog "RESTORED u$user $comp -> ${original:-default}"
        else
            failed=$((failed + 1))
            ulog "FAILED u$user $comp -> ${original:-default}"
        fi
    done < "$COMPONENT_STATE.uninstall_work"
    ulog "Rollback finished inline: total=$total failed=$failed"

    if [ "$failed" -eq 0 ]; then
        mirror_log
        rm -rf "$DATA_DIR" "$DEFERRED_DIR" 2>/dev/null
        exit 0
    fi
    ulog "Some components could not be restored; scheduling a deferred retry instead of deleting state."
fi

mkdir -p "$DEFERRED_DIR" 2>/dev/null
chmod 700 "$DEFERRED_DIR" 2>/dev/null
cp "$COMPONENT_STATE" "$DEFERRED_DIR/component_state.list" 2>/dev/null
[ -f "$MODDIR/compat.sh" ] && cp "$MODDIR/compat.sh" "$DEFERRED_DIR/compat.sh" 2>/dev/null
[ -f "$DATA_DIR/capabilities.conf" ] && cp "$DATA_DIR/capabilities.conf" "$DEFERRED_DIR/capabilities.conf" 2>/dev/null

cat > "$DEFERRED_DIR/rollback.sh" <<'DEFERRED'
DEFERRED_DIR="/data/adb/analytics_ads_disabler_rollback"
LOGFILE="$DEFERRED_DIR/rollback.log"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
STATE="$DEFERRED_DIR/component_state.list"

DATA_DIR="$DEFERRED_DIR"
CAPABILITIES_FILE="$DEFERRED_DIR/capabilities.conf"
export DATA_DIR CAPABILITIES_FILE

log() { echo "[$(date 2>/dev/null)] $*" >> "$LOGFILE" 2>/dev/null; }

: > "$LOGFILE" 2>/dev/null
log "Deferred rollback worker started pid=$$"

waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    waited=$((waited + 1))
    [ "$waited" -ge 180 ] && { log "boot_completed never observed; giving up for this boot."; exit 1; }
    sleep 5
done
sleep 20

if [ ! -f "$DEFERRED_DIR/compat.sh" ] || [ ! -s "$STATE" ]; then
    log "Missing compat.sh or saved state; nothing to do."
    exit 1
fi
. "$DEFERRED_DIR/compat.sh"
ensure_capability_profile >/dev/null 2>&1
load_capabilities

total=0; failed=0
while IFS='|' read -r user comp original; do
    [ -z "$comp" ] && continue
    total=$((total + 1))
    if cap_set_component_state "$user" "$comp" "${original:-default}" >/dev/null 2>&1; then
        log "RESTORED u$user $comp -> ${original:-default}"
    else
        failed=$((failed + 1))
        log "FAILED u$user $comp -> ${original:-default}"
    fi
done < "$STATE"
log "Deferred rollback finished: total=$total failed=$failed"

mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null
cp "$LOGFILE" "$SDCARD_LOG_DIR/uninstall_deferred.log" 2>/dev/null || true

if [ "$failed" -eq 0 ]; then
    rm -rf "$DEFERRED_DIR"
else
    log "Retaining $DEFERRED_DIR for a retry on next boot."
fi
DEFERRED
chmod 755 "$DEFERRED_DIR/rollback.sh" 2>/dev/null

mkdir -p /data/adb/modules/analytics_ads_disabler_rollback 2>/dev/null
cat > /data/adb/modules/analytics_ads_disabler_rollback/module.prop <<'PROP'
id=analytics_ads_disabler_rollback
name=Analytics & Ads Disabler - pending rollback
version=1
versionCode=1
author=eCubz
description=Temporary helper: restores component states saved by Analytics & Ads Disabler, then removes itself.
PROP
cat > /data/adb/modules/analytics_ads_disabler_rollback/service.sh <<'SVC'
DEFERRED_DIR="/data/adb/analytics_ads_disabler_rollback"
if [ -x "$DEFERRED_DIR/rollback.sh" ]; then
    "$DEFERRED_DIR/rollback.sh"
fi
if [ ! -d "$DEFERRED_DIR" ]; then
    touch /data/adb/modules/analytics_ads_disabler_rollback/remove 2>/dev/null
fi
SVC
chmod 755 /data/adb/modules/analytics_ads_disabler_rollback/service.sh 2>/dev/null

ulog "Deferred rollback armed at $DEFERRED_DIR (boot_completed=${boot_state:-0})."
ulog "Component states are preserved there and will be restored on the next boot."
mirror_log

"$DEFERRED_DIR/rollback.sh" >/dev/null 2>&1 &

rm -rf "$DATA_DIR" 2>/dev/null
