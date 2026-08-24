#!/system/bin/sh
# ==============================================================================
# on_change.sh — обработчик событий inotifyd для конфигурации и списков.
#
# КОНТРАКТ inotifyd (busybox): PROG <МАСКА> <ПУТЬ> [ИМЯ_В_КАТАЛОГЕ]
#   $1 — буквы сработавших событий (w = close_write, n = create, d = delete)
#   $2 — путь, за которым установлено наблюдение (у нас это ВСЕГДА каталог)
#   $3 — имя файла внутри каталога
# Наблюдение ставится на каталоги, а не на файлы: все писатели модуля меняют
# файлы атомарно (mv -f tmp file), из-за чего watch на файле остаётся висеть
# на удалённом иноде и перестаёт срабатывать после первой же правки.
# ==============================================================================
umask 077
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
LOG_DIR="$MODDIR/logs"; LOG_FILE="$LOG_DIR/zapret2_debug.log"; RUN_DIR="$MODDIR/run"
CONTROL_WRITE_MARK="$RUN_DIR/control-write.ts"
PENDING_FILE="$RUN_DIR/pending_changes.list"
LOCKDIR="$RUN_DIR/on_change.lock"
STRATEGY_DIR="$MODDIR/strategies"
STRATEGY_LIB="$MODDIR/strategy-lib.sh"
[ -f "$STRATEGY_LIB" ] && . "$STRATEGY_LIB"
mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null; chmod 0700 "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] inotify: $2" >> "$LOG_FILE"; }

EVENTS="$1"
WATCH_PATH="$2"
CHILD="$3"

# Имя изменившегося файла. При наблюдении за каталогом оно приходит третьим
# аргументом; запасной вариант (наблюдение за файлом) оставлен для совместимости.
if [ -n "$CHILD" ]; then
  CHANGED="$CHILD"
else
  CHANGED="${WATCH_PATH##*/}"
fi

# Служебные и временные файлы игнорируем: их создают сами скрипты модуля.
case "$CHANGED" in
  ''|.*|*.tmp|*.tmp.*|*.bak|*.swp|*.swx|*~|*.pid|*.lock|*.cache|*.env|*.log|*.log.*|\
  *.state|*.ts|*.snapshot|*.sorted|*.norm|*.norm.*|*.merge.*|*.fast|*.fast.*|*.previous)
    exit 0 ;;
esac
# Реагируем только на завершение записи, создание и удаление.
case "$EVENTS" in *w*|*n*|*d*|*c*) ;; *) exit 0 ;; esac
# Каталог run/ и logs/ не должны вызывать реконсиляцию ни при каких обстоятельствах.
case "$WATCH_PATH" in "$RUN_DIR"|"$LOG_DIR") exit 0 ;; esac

# Запись, сделанная самим контроллером, уже применена им синхронно.
marker_ts=$(cat "$CONTROL_WRITE_MARK" 2>/dev/null); now=$(date +%s 2>/dev/null)
case "$marker_ts:$now" in
  *[!0-9:]*|:*) ;;
  *) age=$((now-marker_ts))
     if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le 6 ] 2>/dev/null; then
       log DEBUG "запись контроллера уже применена ($CHANGED)"; exit 0
     fi
     rm -f "$CONTROL_WRITE_MARK" 2>/dev/null ;;
esac

printf '%s\n' "$CHANGED" >> "$PENDING_FILE" 2>/dev/null
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lp=$(cat "$LOCKDIR/pid" 2>/dev/null)
  case "$lp" in
    ''|0|*[!0-9]*) rm -rf "$LOCKDIR" 2>/dev/null ;;
    *) kill -0 "$lp" 2>/dev/null && exit 0; rm -rf "$LOCKDIR" 2>/dev/null ;;
  esac
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT HUP INT TERM

# Схлопываем пачку событий одной правки в одну реконсиляцию.
sleep 2
while [ -s "$PENDING_FILE" ]; do
  SNAP="$RUN_DIR/pending_changes.$$.snapshot"
  mv -f "$PENDING_FILE" "$SNAP" 2>/dev/null || { sleep 1; continue; }
  need_service_reload=0; need_warp_sync=0; seen=""
  while IFS= read -r ev || [ -n "$ev" ]; do
    [ -n "$ev" ] || continue
    seen="${seen}${seen:+,}$ev"
    case "$ev" in
      # Меняют состав netfilter-правил или аргументы nfqws2 -> полный reload.
      # ВНИМАНИЕ при добавлении файлов: шаблоны сопоставляются с именем целиком,
      # поэтому "bypass_nets*.list" НЕ покрывает "warp_bypass_nets.list".
      # Имя, не попавшее ни в одну ветку, молча не вызовет ничего.
      # ipset.list и ipset_exclude.list с v4.0.0 — основной способ отбора по
      # подсетям, но их тут не было: правка через файловый менеджер или
      # adb push не вызывала вообще ничего. Удалённые в v4.0.0 имена
      # (smart_youtube.list, auto_domains.list, warp_apps*.list) убраны.
      zapret2.conf|strategy_*|probe_hosts.list|wifi_direct_ssids.list|\
      exclude_domains.list|user.list|ipset.list|ipset_exclude.list|\
      warp_bypass_nets.list)
        need_service_reload=1 ;;
      # Меняют только маршрутизацию/DNS туннелей (WARP AWG99 и Geo AWG98).
      warp_domains.list|warp_domains.user.list|geo_warp.list|geo_warp.user.list|\
      apps_black.list|dns.list|dns.user.list)
        need_warp_sync=1 ;;
      *) ;;
    esac
  done < "$SNAP"
  rm -f "$SNAP" 2>/dev/null

  if [ "$need_service_reload" = 1 ]; then
    log INFO "полная реконсиляция службы (изменено: $seen)"
    sh "$MODDIR/service.sh" reload
  fi
  if [ "$need_warp_sync" = 1 ] && [ -f "$MODDIR/warp-tunnel.sh" ]; then
    log INFO "реконсиляция туннелей WARP / GEO / Apps (изменено: $seen)"
    sh "$MODDIR/warp-tunnel.sh" sync >/dev/null 2>&1 || true
  fi
  # Изменение уже применено лёгким путём. Подпись надо освежить, иначе
  # health-watcher через минуту увидит расхождение и выполнит ПОЛНЫЙ перезапуск
  # поверх того, что уже сделано. Полный reload запишет подпись сам.
  if [ "$need_service_reload" != 1 ] && command -v write_config_signature >/dev/null 2>&1; then
    write_config_signature
  fi
  # Даём конкурентным писателям окно; если появилось новое — крутим ещё раз.
  sleep 1
done
rm -rf "$LOCKDIR" 2>/dev/null
trap - EXIT HUP INT TERM
