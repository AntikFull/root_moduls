#!/system/bin/sh
# ADB WiFi On-Demand Fixed Port (5555)
# eCubz (https://t.me/module_ecubz)

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

sleep 3

LAST_STATE=""

while true; do
    STATE=$(settings get global adb_wifi_enabled 2>/dev/null)
    
    if [ "$STATE" != "$LAST_STATE" ]; then
        if [ "$STATE" = "1" ]; then
            # Тумблер ВКЛЮЧЕН -> открываем фиксированный порт 5555
            CURRENT_PORT=$(getprop service.adb.tcp.port)
            if [ "$CURRENT_PORT" != "5555" ]; then
                setprop service.adb.tcp.port 5555
                stop adbd
                start adbd
            fi
        elif [ "$STATE" = "0" ]; then
            # Тумблер ВЫКЛЮЧЕН -> наглухо закрываем порт 5555
            CURRENT_PORT=$(getprop service.adb.tcp.port)
            if [ "$CURRENT_PORT" != "-1" ] && [ -n "$CURRENT_PORT" ]; then
                setprop service.adb.tcp.port -1
                stop adbd
                start adbd
            fi
        fi
        LAST_STATE="$STATE"
    fi
    
    sleep 1.5
done &
