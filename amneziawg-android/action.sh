#!/system/bin/sh
# action.sh — Кнопка Действие в менеджере root: перезапуск демонов и вывод статуса
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
LOG_DIR="/data/adb/amneziawg/logs"
RUN_DIR="/data/adb/amneziawg/run"

mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null # глушение-обосновано: каталоги создаются в post-fs-data и обычно уже существуют

# shellcheck disable=SC1090
. "$BIN_DIR/awg-daemons.sh"

echo "=== AWG eCubz ==="

if restart_monitors; then
  echo "Мониторы перезапущены: awg-netmon, awg-appmon"
else
  echo "Мониторы НЕ запущены: watchdog не работает до перезагрузки."
fi

# Явный вызов пользователем снимает блокировку watchdog со всех профилей
"$BIN_DIR/awg-controller" reset-failures all >/dev/null 2>&1 || \
  echo "Сброс счетчиков сбоев не выполнен."

active_cnt="$(ls -1 "$RUN_DIR"/*.iface 2>/dev/null | wc -l)" # глушение-обосновано: отсутствие файлов означает ноль активных профилей
if [ "$active_cnt" -gt 0 ]; then
  echo "Активных профилей: $active_cnt. Синхронизация правил..."
  "$BIN_DIR/awg-controller" sync-rules >/dev/null 2>&1 || echo "Синхронизация завершилась с ошибкой."
else
  echo "Активных профилей нет. Запуск включенных..."
  "$BIN_DIR/awg-controller" start all >/dev/null 2>&1 || echo "Запуск профилей завершился с ошибкой."
fi

echo ""
"$BIN_DIR/awg" status
echo "================="

# Открытие WebUI для пользователей Magisk через ksuwebui / MMRL.
# Отсутствие обоих менеджеров - не сбой: WebUI открывается из самого
# менеджера root, поэтому пользователю сообщается об этом текстом.
if am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "amneziawg-android" >/dev/null 2>&1; then # глушение-обосновано: отсутствие пакета ksuwebui обрабатывается следующей веткой
  :
elif am start -n "com.dergoogler.mmrl/.ui.activity.webui.WebUIActivity" -e id "amneziawg-android" >/dev/null 2>&1; then # глушение-обосновано: отсутствие пакета MMRL обрабатывается следующей веткой
  :
else
  echo "WebUI не открыт автоматически: откройте его в менеджере root вручную."
fi
