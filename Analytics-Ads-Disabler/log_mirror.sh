#!/system/bin/sh
# Best-effort mirror of module logs to user-accessible storage.
# Never blocks or influences the core runtime.
MODDIR=${0%/*}
DATA_DIR="/data/adb/analytics_ads_disabler"
LOG_DIR="$DATA_DIR/logs"
SETTINGS_FILE="$DATA_DIR/settings.conf"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
STAMP_FILE="$DATA_DIR/.log_mirror.stamp"

read_conf() {
    key="$1"; def="$2"; val=""
    if [ -f "$SETTINGS_FILE" ]; then
        val=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$SETTINGS_FILE" 2>/dev/null | head -n1 | tr -d '\r')
    fi
    [ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$def"
}

# Emulated storage is world-readable, so package-level inventories are mirrored
# only when the user opts in. Runtime/diagnostic logs are always mirrored
# because they are what support requests actually need.
BASE_LOGS="debug.log debug.previous.log boot_trace.log diagnostics.log install_diagnostics.log uninstall.log"
FULL_LOGS="component_audit.log sdk_fingerprint.log manifest_scan.log ad_surface_scan.log ad_killer.log ad_killer.previous.log"

copy_one() {
    src="$LOG_DIR/$1"
    [ -f "$src" ] || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 cp "$src" "$SDCARD_LOG_DIR/" 2>/dev/null || true
    else
        cp "$src" "$SDCARD_LOG_DIR/" 2>/dev/null || true
    fi
}

while true; do
    interval=$(read_conf LOG_MIRROR_INTERVAL 60)
    case "$interval" in
        ''|*[!0-9]*) interval=60 ;;
        *)
            [ "$interval" -lt 10 ] 2>/dev/null && interval=10
            [ "$interval" -gt 3600 ] 2>/dev/null && interval=3600
            ;;
    esac

    if [ "$(read_conf LOG_MIRROR 1)" = "1" ]; then
        # Skip the whole pass when nothing changed: this worker used to copy
        # every log unconditionally every 10 seconds, around the clock.
        newest=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -n1)
        changed=1
        if [ -n "$newest" ] && [ -f "$STAMP_FILE" ] && [ ! "$newest" -nt "$STAMP_FILE" ]; then
            changed=0
        fi
        if [ "$changed" = "1" ] && mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null; then
            for f in $BASE_LOGS; do copy_one "$f"; done
            if [ "$(read_conf LOG_MIRROR_FULL 0)" = "1" ]; then
                for f in $FULL_LOGS; do copy_one "$f"; done
            fi
            : > "$STAMP_FILE" 2>/dev/null
        fi
    fi

    sleep "$interval"
done
