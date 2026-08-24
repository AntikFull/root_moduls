#!/system/bin/sh
MODDIR=${0%/*}

CONF_FILE="$MODDIR/config.conf"
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    TARGET_MAC="60:3D:61:B6:8B:00"
    TARGET_PKG="com.yandex.aliceapp"
    TARGET_ACTIVITY="com.yandex.aliceapp/.ui.MainActivity"
    MINIMIZE_MODE=1
    CHECK_INTERVAL=3
    DISCONNECT_DELAY=5
    ENABLE_LOGGING=1
fi

LOG_FILE="$MODDIR/debug.log"

log() {
    [ "$ENABLE_LOGGING" = "1" ] || return 0
    local msg="$(date '+%Y-%m-%d %H:%M:%S'): $1"
    echo "$msg" >> "$LOG_FILE"
    
    # Ротация лога при превышении 100 КБ
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt 102400 ]; then
            tail -n 100 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
}

log "=========================================="
log "Запуск службы Alice AI Bluetooth Auto-Launcher v1.1.0"
log "MODDIR=$MODDIR, TARGET_MAC=$TARGET_MAC, MINIMIZE_MODE=$MINIMIZE_MODE"

MAC_LOWER=$(echo "$TARGET_MAC" | tr '[:upper:]' '[:lower:]')
MAC_UPPER=$(echo "$TARGET_MAC" | tr '[:lower:]' '[:upper:]')

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done

log "Система загружена, переход в режим мониторинга Bluetooth"

# Точная функция проверки фактического подключения Bluetooth-устройства
is_bt_connected() {
    local status
    status=$(dumpsys bluetooth_manager 2>/dev/null)

    # 1. Проверка строки состояния уровня громкости/подключения
    if echo "$status" | grep -iE "$MAC_UPPER|$MAC_LOWER" | grep -v "NotConnected" | grep -q ": Connected"; then
        return 0
    fi

    # 2. Проверка активного устройства в mCurrentDevice в dumpsys bluetooth_manager
    if echo "$status" | grep -i "mCurrentDevice" | grep -iE "$MAC_UPPER|$MAC_LOWER" >/dev/null 2>&1; then
        return 0
    fi

    # 3. Проверка активных аудиовыходов через dumpsys audio
    local audio_status
    audio_status=$(dumpsys audio 2>/dev/null)
    if echo "$audio_status" | grep -i "Connected devices:" -A 10 | grep -iE "$MAC_UPPER|$MAC_LOWER" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Функция запуска приложения Алиса AI
launch_alice() {
    log "Подключено целевое устройство $TARGET_MAC. Запуск $TARGET_PKG ($TARGET_ACTIVITY)..."
    am start -W -n "$TARGET_ACTIVITY" >/dev/null 2>&1

    if [ "$MINIMIZE_MODE" = "1" ]; then
        # Возврат в предыдущее приложение через KEYCODE_BACK
        sleep 0.4
        input keyevent 4
        sleep 0.4
        if dumpsys window 2>/dev/null | grep -i "mCurrentFocus" | grep -q "$TARGET_PKG"; then
            log "Окно приложения все еще в фокусе, повторный возврат назад..."
            input keyevent 4
        fi
    elif [ "$MINIMIZE_MODE" = "2" ]; then
        # Сворачивание на рабочий стол через KEYCODE_HOME
        sleep 0.4
        input keyevent 3
        sleep 0.4
        if dumpsys window 2>/dev/null | grep -i "mCurrentFocus" | grep -q "$TARGET_PKG"; then
            log "Окно приложения все еще в фокусе, повторный HOME..."
            input keyevent 3
        fi
    fi
}

stop_alice() {
    log "Остановка приложения $TARGET_PKG..."
    am force-stop "$TARGET_PKG" >/dev/null 2>&1
}

CONNECTED=0

while true; do
    if is_bt_connected; then
        if [ "$CONNECTED" -eq 0 ]; then
            CONNECTED=1
            launch_alice
        fi
        sleep "$CHECK_INTERVAL"
    else
        if [ "$CONNECTED" -eq 1 ]; then
            log "Зафиксировано отключение Bluetooth. Ожидание $DISCONNECT_DELAY сек для подтверждения..."
            sleep "$DISCONNECT_DELAY"

            if ! is_bt_connected; then
                log "Отключение подтверждено. Остановка $TARGET_PKG..."
                stop_alice
                CONNECTED=0
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Связь с наушниками восстановилась за $DISCONNECT_DELAY сек. Отмена выгрузки."
            fi
        else
# В отсоединенном состоянии - легкая пауза без постоянных запусков
            sleep 4
        fi
    fi
done
