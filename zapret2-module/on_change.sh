#!/system/bin/sh
# Handler for manual edits. WebUI/CLI writes are reloaded synchronously by control
# and are suppressed here to avoid a second delayed restart.

MODDIR="${0%/*}"
LOG_FILE="/sdcard/eCubz/zapret2_debug.log"
RUN_DIR="$MODDIR/run"
CONTROL_WRITE_MARK="$RUN_DIR/control-write.ts"

case "$1" in
  *.tmp|*.bak|*.swp|*.pid|*.lock) exit 0 ;;
esac

marker_ts=$(cat "$CONTROL_WRITE_MARK" 2>/dev/null)
now=$(date +%s 2>/dev/null)
case "$marker_ts:$now" in
  *[!0-9:]*|:*) ;;
  *)
    age=$((now - marker_ts))
    if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le 10 ] 2>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] inotify: WebUI/CLI write suppressed ($1 $2)" >> "$LOG_FILE"
      exit 0
    fi
    rm -f "$CONTROL_WRITE_MARK" 2>/dev/null
    ;;
esac

LOCKFILE="$RUN_DIR/on_change.lock"
mkdir -p "$RUN_DIR" 2>/dev/null
[ -f "$LOCKFILE" ] && exit 0

touch "$LOCKFILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: ручное изменение ($1 $2), перезагрузка через 2с" >> "$LOG_FILE"
sleep 2
sh "$MODDIR/service.sh" reload
rm -f "$LOCKFILE" 2>/dev/null
