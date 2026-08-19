#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
RUN_DIR="$MODDIR/run"
CONTROL_WRITE_MARK="$RUN_DIR/control-write.ts"
PENDING_FILE="$RUN_DIR/pending_changes.list"
LOCKDIR="$RUN_DIR/on_change.lock"

mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null
chmod 0700 "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true

case "$1" in
  *.tmp*|*.bak*|*.swp*|*.pid*|*.lock*|*.cache*|*.env*|*.log*|*.list.*) exit 0 ;;
esac

# Подавление эха от собственной записи WebUI/CLI
marker_ts=$(cat "$CONTROL_WRITE_MARK" 2>/dev/null)
now=$(date +%s 2>/dev/null)
case "$marker_ts:$now" in
  *[!0-9:]*|:*) ;;
  *)
    age=$((now - marker_ts))
    if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le 6 ] 2>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] inotify: WebUI/CLI write suppressed ($1)" >> "$LOG_FILE"
      exit 0
    fi
    rm -f "$CONTROL_WRITE_MARK" 2>/dev/null
    ;;
esac

# Фиксация события в очереди отложенных изменений
echo "$1" >> "$PENDING_FILE" 2>/dev/null

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lp=$(cat "$LOCKDIR/pid" 2>/dev/null)
  case "$lp" in
    ''|0|*[!0-9]*) rm -rf "$LOCKDIR" 2>/dev/null ;;
    *)
      if kill -0 "$lp" 2>/dev/null; then
        # Другой обработчик уже работает и обработает запись из $PENDING_FILE
        exit 0
      fi
      rm -rf "$LOCKDIR" 2>/dev/null
      ;;
  esac
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi

echo $$ > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT HUP INT TERM

# Debounce интервал для группировки быстрых сохранений
sleep 2

events=$(cat "$PENDING_FILE" 2>/dev/null)
rm -f "$PENDING_FILE" 2>/dev/null

need_service_reload=0
need_app_sync=0
need_warp_sync=0

for ev in $events; do
  case "$ev" in
    *zapret2.conf|*strategies*|*probe_hosts*|*smart_youtube*|*exclude_domains*)
      need_service_reload=1
      ;;
    *warp_apps*.list|*dns*.list)
      need_warp_sync=1
      ;;
    *apps.list|*auto_apps.list|*exclude.list)
      need_app_sync=1
      ;;
    *)
      need_service_reload=1
      ;;
  esac
done

if [ "$need_service_reload" = "1" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: Перезагрузка службы zapret2 по изменению конфигурации" >> "$LOG_FILE"
  sh "$MODDIR/service.sh" reload
elif [ "$need_app_sync" = "1" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: Быстрая синхронизация AntiDPI списков приложений" >> "$LOG_FILE"
  sh "$MODDIR/app-sync.sh" apply >/dev/null 2>&1 || sh "$MODDIR/service.sh" reload
fi

if [ "$need_warp_sync" = "1" ] && [ -f "$MODDIR/warp-tunnel.sh" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] inotify: Синхронизация списков WARP" >> "$LOG_FILE"
  sh "$MODDIR/warp-tunnel.sh" sync >/dev/null 2>&1 || true
fi

rm -rf "$LOCKDIR" 2>/dev/null
trap - EXIT HUP INT TERM
