#!/system/bin/sh
MODDIR=${0%/*}
DATA_DIR="/data/adb/analytics_ads_disabler"
LOG_DIR="$DATA_DIR/logs"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
INTERVAL=10

while true; do
    mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null
    if [ -d "$SDCARD_LOG_DIR" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 cp "$LOG_DIR"/*.log "$SDCARD_LOG_DIR/" 2>/dev/null || true
        else
            cp "$LOG_DIR"/*.log "$SDCARD_LOG_DIR/" 2>/dev/null || true
        fi
    fi
    sleep "$INTERVAL"
done
