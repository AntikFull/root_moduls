#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
RUN_DIR="$MODDIR/run"
CONTROL_WRITE_MARK="$RUN_DIR/control-write.ts"
mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null
chmod 0700 "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true

case "$1" in
  *.tmp*|*.bak*|*.swp*|*.pid*|*.lock*|*.cache*|*.env*|*.log*) exit 0 ;;
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

LOCKDIR="$RUN_DIR/on_change.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lp=$(cat "$LOCKDIR/pid" 2>/dev/null)
  case "$lp" in
    ''|0|*[!0-9]*) rm -rf "$LOCKDIR" 2>/dev/null ;;
    *)
      if kill -0 "$lp" 2>/dev/null; then
        exit 0
      fi
      rm -rf "$LOCKDIR" 2>/dev/null
      ;;
  esac
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT HUP INT TERM

sleep 2

case "$1" in
  *warp_apps*.list|*ai_apps*.list|*dns*.list)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: Изменён список WARP/AI/DNS ($1), запуск warp sync" >> "$LOG_FILE"
    sh "$MODDIR/warp-tunnel.sh" sync >/dev/null 2>&1 || true
    ;;
  *apps.list|*auto_apps.list|*exclude.list)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: Изменён список приложений ($1), запуск app-sync" >> "$LOG_FILE"
    sh "$MODDIR/app-sync.sh" apply >/dev/null 2>&1 || sh "$MODDIR/service.sh" reload
    ;;
  *)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: Изменён файл конфигурации ($1), запуск перезагрузки" >> "$LOG_FILE"
    sh "$MODDIR/service.sh" reload
    ;;
esac
rm -rf "$LOCKDIR" 2>/dev/null
trap - EXIT HUP INT TERM
