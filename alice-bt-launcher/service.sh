#!/system/bin/sh
MODDIR=${0%/*}

LOG_DIR="/sdcard/eCubz"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/alice_bt_launcher_debug.log"
exec 2>&1 >> "$LOG_FILE"

echo "=========================================="
echo "$(date '+%Y-%m-%d %H:%M:%S'): Запуск службы Alice AI Bluetooth Auto-Launcher v1.0.2"
echo "MODDIR=$MODDIR"

CONF_FILE="$MODDIR/config.conf"
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Конфигурация успешно загружена из $CONF_FILE"
else
    TARGET_MAC="60:3D:61:B6:8B:00"
    TARGET_PKG="com.yandex.aliceapp"
    TARGET_ACTIVITY="com.yandex.aliceapp/.ui.MainActivity"
    DISCONNECT_DELAY=5
    KEEP_ALIVE_INTERVAL=10
    MINIMIZE_TO_BACKGROUND=1
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Файл конфигурации не найден, использованы значения по умолчанию"
fi

MAC_LOWER=$(echo "$TARGET_MAC" | tr '[:upper:]' '[:lower:]')
MAC_UPPER=$(echo "$TARGET_MAC" | tr '[:lower:]' '[:upper:]')

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done

echo "$(date '+%Y-%m-%d %H:%M:%S'): Система загружена, служба переходит в режим мониторинга"

# Точная функция проверки фактического подключения Bluetooth-устройства
is_bt_connected() {
    local status
    status=$(dumpsys bluetooth_manager 2>/dev/null)

# 1. Проверка строки состояния уровня громкости/подключения (должно содержать ": Connected" и НЕ содержать "NotConnected")
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

# Функция запуска приложения Алиса AI с надежным сворачиванием в фон
launch_alice() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Запуск $TARGET_PKG ($TARGET_ACTIVITY)..."
# Флаг -W заставляет am start дождаться полного отрисовывания окна
    am start -W -n "$TARGET_ACTIVITY" >/dev/null 2>&1
    if [ "$MINIMIZE_TO_BACKGROUND" -eq 1 ]; then
        sleep 0.5
        input keyevent 3

# Подстраховка: если окно Алисы все еще находится в фокусе, отправляем повторный сигнал HOME
        sleep 0.5
        if dumpsys window 2>/dev/null | grep -i "mCurrentFocus" | grep -q "$TARGET_PKG"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Приложение все еще на переднем плане, отправляем повторный HOME..."
            input keyevent 3
        fi
    fi
}

stop_alice() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Остановка приложения $TARGET_PKG..."
    am force-stop "$TARGET_PKG" >/dev/null 2>&1
}

CONNECTED=0

while true; do
    if is_bt_connected; then
        if [ "$CONNECTED" -eq 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Подключены наушники $TARGET_MAC! Инициализация запуска..."
            CONNECTED=1
            launch_alice
        else
# Пока наушники подключены, проверяем работает ли процесс (Keep-Alive)
            if ! pidof "$TARGET_PKG" >/dev/null 2>&1; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Процесс $TARGET_PKG был выгружен из памяти! Автоматический перезапуск..."
                launch_alice
            fi
        fi
        sleep "$KEEP_ALIVE_INTERVAL"
    else
        if [ "$CONNECTED" -eq 1 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Зафиксировано отключение наушников. Ожидание $DISCONNECT_DELAY сек для проверки..."
            sleep "$DISCONNECT_DELAY"

# Повторная проверка подстраховки от кратковременных сбоев
            if ! is_bt_connected; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Отключение подтверждено. Завершение работы $TARGET_PKG..."
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
