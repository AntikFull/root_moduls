#!/system/bin/sh
# Handler for inotifyd file change events (Zero CPU & Battery Impact)

MODDIR="${0%/*}"
LOG_FILE="$MODDIR/zapret2.log"

# Защита от дребезга при быстрых повторных сохранениях
LOCKFILE="/tmp/zapret2_reload.lock"
if [ -f "$LOCKFILE" ]; then
  exit 0
fi

touch "$LOCKFILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Событие inotify: Изменение файла ($1 $2). Мгновенное автоприменение..." >> "$LOG_FILE"

sleep 1
sh "$MODDIR/service.sh" reload
rm -f "$LOCKFILE" 2>/dev/null
