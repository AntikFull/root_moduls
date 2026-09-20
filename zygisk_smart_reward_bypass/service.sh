#!/system/bin/sh
export PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
MODDIR=${0%/*}
DATA_DIR="/data/adb/zygisk_smart_reward_bypass"
LOG_DIR="$DATA_DIR/logs"
MIRROR_DIR="/sdcard/eCubz/logs/zygisk_smart_reward_bypass"
PID_FILE="$DATA_DIR/logcat.pid"

# 1. Инициализация директорий логов и установка прав доступа
mkdir -p "$LOG_DIR" "$MIRROR_DIR" 2>/dev/null # глушение-обосновано: sdcard может быть не смонтирована при ранней загрузке
chmod 755 "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true # глушение-обосновано: права выставляются наилучшим образом при наличии папок
chmod 644 "$DATA_DIR"/*.conf "$DATA_DIR"/*.list 2>/dev/null || true # глушение-обосновано: файлы конфигурации могут отсутствовать

# 2. Безопасная остановка старого экземпляра logcat при перезапуске
if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null)" # глушение-обосновано: файл может быть удален параллельно
    if [ -n "$OLD_PID" ] && [ -d "/proc/$OLD_PID" ]; then
        CMD="$(cat "/proc/$OLD_PID/cmdline" 2>/dev/null | tr '\0' ' ')" # глушение-обосновано: процесс мог завершиться до чтения cmdline
        echo "$CMD" | grep -q "logcat" && kill "$OLD_PID" 2>/dev/null || true # глушение-обосновано: процесс мог завершиться самостоятельно
    fi
    rm -f "$PID_FILE" 2>/dev/null || true # глушение-обосновано: удаление временного PID файла
fi

# 3. Проверка флага отладки (по умолчанию выключено для экономии батареи и UFS)
DEBUG_TRIGGER="$DATA_DIR/debug"
ENABLE_LOGCAT=0

if [ -f "$DEBUG_TRIGGER" ]; then
    ENABLE_LOGCAT=1
elif [ -f "$DATA_DIR/reporting.conf" ]; then
    grep -Eq '^[[:space:]]*ENABLE_LOGCAT=1' "$DATA_DIR/reporting.conf" 2>/dev/null && ENABLE_LOGCAT=1 # глушение-обосновано: проверка опционального флага в конфиге
fi

# 4. Запуск изолированного logcat демона только при активной отладке (нативная ротация 5MB x 2 файла)
if [ "$ENABLE_LOGCAT" -eq 1 ]; then
    (
        exec logcat -v threadtime -s 'SmartReward-Engine:I' 'SmartReward-Java:I' '*:S' \
            -f "$LOG_DIR/runtime.log" -r 5120 -n 2 >/dev/null 2>&1 # глушение-обосновано: фоновый вывод системного демона logcat
    ) &
    echo $! > "$PID_FILE" 2>/dev/null # глушение-обосновано: запись PID демона отладки

    # 5. Разовая синхронизация зеркала логов на sdcard без циклической нагрузки на процессор
    (
        sleep 20
        if [ -f "$LOG_DIR/runtime.log" ]; then
            cp -f "$LOG_DIR/runtime.log" "$MIRROR_DIR/runtime.log" 2>/dev/null || true # глушение-обосновано: sdcard может быть недоступна для записи
        fi
    ) &
fi

exit 0
