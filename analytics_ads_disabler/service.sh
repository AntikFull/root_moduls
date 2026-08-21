#!/system/bin/sh
#
# Analytics & Ads Disabler v7 — загрузочный скрипт.
#
# Вся работа модуля при загрузке сводится к одному действию: привести
# engine.policy в соответствие с настройками. Никаких сканирований, опроса
# состояния и фоновых циклов здесь нет и быть не должно — блокировкой
# занимается Zygisk-движок внутри процессов приложений.
#
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

aad_log_rotate
aad_log "=== service.sh старт pid=$$ ==="

# Ожидание готовности системы. Таймаут обязателен: на части прошивок
# sys.boot_completed не выставляется вовсе, и бесконечное ожидание оставило бы
# висящий процесс на всё время работы устройства.
waited=0
timeout=180
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 3
    waited=$((waited + 3))
    if [ "$waited" -ge "$timeout" ]; then
        aad_log "BOOT-WAIT таймаут ${timeout}s; продолжаем без sys.boot_completed"
        break
    fi
done

# PackageManager поднимается позже sys.boot_completed. Перечисление системных
# пакетов нужно только при INCLUDE_SYSTEM_APPS=0, поэтому ждём его отдельно и
# недолго.
if [ "$(aad_read_bool INCLUDE_SYSTEM_APPS 0)" = "0" ]; then
    pm_waited=0
    while [ "$pm_waited" -lt 60 ]; do
        if aad_system_packages 2>/dev/null | head -n1 | grep -q .; then
            break
        fi
        sleep 3
        pm_waited=$((pm_waited + 3))
    done
    aad_log "PM-WAIT ${pm_waited}s"
fi

aad_sync_policy "boot"
sync_rc=$?
aad_log "BOOT-SYNC rc=$sync_rc"

# Событийное отслеживание настроек. inotifyd блокируется в ядре и не
# просыпается, пока файл не изменён, поэтому постоянной нагрузки не создаёт.
# Это единственный фоновый процесс модуля.
WATCH_PID_FILE="$DATA_DIR/config_watch.pid"
old_pid=$(cat "$WATCH_PID_FILE" 2>/dev/null)
case "$old_pid" in
    ''|*[!0-9]*) ;;
    *)
        if kill -0 "$old_pid" 2>/dev/null; then
            cmdline=$(tr '\000' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)
            case "$cmdline" in
                *config_event.sh*) kill "$old_pid" 2>/dev/null ;;
            esac
        fi
        ;;
esac
rm -f "$WATCH_PID_FILE" 2>/dev/null

if command -v inotifyd >/dev/null 2>&1; then
    inotifyd "$MODDIR/config_event.sh" "$DATA_DIR:w" >/dev/null 2>&1 &
    watch_pid=$!
    printf '%s\n' "$watch_pid" > "$WATCH_PID_FILE" 2>/dev/null
    aad_log "CONFIG-WATCH запущен pid=$watch_pid"
else
    aad_log "CONFIG-WATCH недоступен: нет inotifyd; настройки применяются кнопкой Action"
fi

aad_log "=== service.sh завершён ==="
