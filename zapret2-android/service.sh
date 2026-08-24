#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
SERVICE_ACTION="$1"
CONF_FILE="$MODDIR/zapret2.conf"
LISTS_DIR="$MODDIR/lists"
[ -d "$LISTS_DIR" ] || LISTS_DIR="$MODDIR"
EXCLUDE_DOMAINS_FILE="$LISTS_DIR/exclude_domains.list"
# Доменные списки в терминологии nfqws2-keenetic.
USER_DOMAINS_FILE="$LISTS_DIR/user.list"
# Подсети (CIDR): аналог ipset.list / ipset_exclude.list из nfqws2-keenetic.
IPSET_FILE="$LISTS_DIR/ipset.list"
IPSET_EXCLUDE_FILE="$LISTS_DIR/ipset_exclude.list"
# auto.list пишет сам nfqws2, поэтому он лежит В STATE, а не в lists: каталог
# lists/ под наблюдением inotify, и запись выученного домена немедленно вызывала
# бы перезапуск службы, который стёр бы ещё не сохранённое состояние обучения.
LEARNED_DOMAINS_FILE="$MODDIR/state/auto.list"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
NFQWS_LOG="$LOG_DIR/zapret2_nfqws.log"
BIN_DIR="$MODDIR/bin"
RUN_DIR="$MODDIR/run"
NFQWS_PID_FILE="$RUN_DIR/nfqws2.pid"
WATCHER_PID_FILE="$RUN_DIR/watcher.pid"
VPN_WATCHER_PID_FILE="$RUN_DIR/vpn-watcher.pid"
HEALTH_WATCHER_PID_FILE="$RUN_DIR/health-watcher.pid"
SERVICE_LOCK="$RUN_DIR/service.lock"
HEALTH_FILE="$RUN_DIR/health.env"
START_STATE_FILE="$RUN_DIR/startup.env"
LATE_START_PID_FILE="$RUN_DIR/late-start.pid"
BOOT_TRACE_FILE="$RUN_DIR/boot-trace.log"
BOOT_ID_FILE="$RUN_DIR/boot.id"
AUTO_RESULT_FILE="$RUN_DIR/auto-current.env"
STRATEGY_DIR="$MODDIR/strategies"
STRATEGY_LIB="$MODDIR/strategy-lib.sh"
[ -f "$STRATEGY_LIB" ] && . "$STRATEGY_LIB"

mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null
chmod 0700 "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true
[ -d "$LISTS_DIR" ] && { chmod 0755 "$LISTS_DIR" 2>/dev/null || true; chmod 0644 "$LISTS_DIR"/* 2>/dev/null || true; }
if ! : >> "$LOG_FILE" 2>/dev/null; then
  printf '[%s] pid=%s fatal: internal log is not writable: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$LOG_FILE" >> "$RUN_DIR/boot-trace.log" 2>/dev/null
  exit 1
fi
chmod 0600 "$LOG_FILE" 2>/dev/null || true

init_boot_epoch() {
  local current previous tmp
  current=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$current" ] || return 0
  previous=$(cat "$BOOT_ID_FILE" 2>/dev/null)
  if [ "$previous" != "$current" ]; then
    rm -f "$NFQWS_PID_FILE" "$WATCHER_PID_FILE" "$VPN_WATCHER_PID_FILE" "$HEALTH_WATCHER_PID_FILE" "$LATE_START_PID_FILE" \
      "$RUN_DIR/auto-probe.pid" "$RUN_DIR/auto-test-nfqws.pid" "$AUTO_RESULT_FILE" \
      "$HEALTH_FILE" "$START_STATE_FILE" "$RUN_DIR/tether-runtime.conf" "$RUN_DIR/tether-downstreams.state" \
      "$RUN_DIR/vpn-routing.state" "$RUN_DIR/vpn-routing.meta" "$RUN_DIR/network-event.flag" "$RUN_DIR/control-write.ts" \
      2>/dev/null
    rm -rf "$SERVICE_LOCK" "$RUN_DIR/app-sync.lock" "$RUN_DIR/vpn-routing.lock" "$RUN_DIR/on_change.lock" "$RUN_DIR/auto-select.lock" 2>/dev/null
    tmp="$BOOT_ID_FILE.tmp.$$"
    printf '%s\n' "$current" > "$tmp" 2>/dev/null && mv -f "$tmp" "$BOOT_ID_FILE" 2>/dev/null
    chmod 0600 "$BOOT_ID_FILE" 2>/dev/null || true
  fi
}
init_boot_epoch

boot_trace() {
  local size ppid pgrp sid
  if [ -f "$BOOT_TRACE_FILE" ]; then
    size=$(wc -c < "$BOOT_TRACE_FILE" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -gt 65536 ] 2>/dev/null && mv -f "$BOOT_TRACE_FILE" "$BOOT_TRACE_FILE.1" 2>/dev/null
  fi
  ppid=$(awk '{print $4}' /proc/$$/stat 2>/dev/null)
  pgrp=$(awk '{print $5}' /proc/$$/stat 2>/dev/null)
  sid=$(awk '{print $6}' /proc/$$/stat 2>/dev/null)
  printf '[%s] pid=%s ppid=%s pgrp=%s sid=%s action=%s boot_completed=%s %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$ppid" "$pgrp" "$sid" \
    "${SERVICE_ACTION:-late_start}" "$(getprop sys.boot_completed 2>/dev/null)" "$*" >> "$BOOT_TRACE_FILE" 2>/dev/null
}
boot_trace "service entry"

write_start_state() {
  local state="$1" phase="$2" progress="$3"
  case "$progress" in ''|*[!0-9]*) progress=0 ;; esac
  [ "$progress" -gt 100 ] 2>/dev/null && progress=100
  [ "$progress" -lt 0 ] 2>/dev/null && progress=0
  phase=$(printf '%s' "$phase" | tr '\r\n' '  ')
  local tmp="$START_STATE_FILE.tmp.$$"
  {
    printf 'STATE=%s\n' "$state"
    printf 'PHASE=%s\n' "$phase"
    printf 'PROGRESS=%s\n' "$progress"
    printf 'UPDATED=%s\n' "$(date +%s 2>/dev/null)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$START_STATE_FILE" 2>/dev/null
  chmod 0600 "$START_STATE_FILE" 2>/dev/null || true
}

rotate_file() {
  local file="$1" max_kb="$2" size
  [ -f "$file" ] || return 0
  size=$(du -k "$file" 2>/dev/null | awk '{print $1}')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -lt "$max_kb" ] && return 0
  mv -f "$file" "$file.1" 2>/dev/null
}
rotate_file "$LOG_FILE" 4096
rotate_file "$NFQWS_LOG" 16384

log() { local level="$1"; shift; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"; }
log_i() { log INFO "$@"; }
log_w() { log WARN "$@"; }
log_e() { log ERROR "$@"; }
log_d() { [ "${LOG_VERBOSE:-1}" = "1" ] && log DEBUG "$@"; }

HEALTH="OK"
HEALTH_WARNINGS=""
COMPAT_STATUS="NATIVE"
COMPAT_NOTES=""
compat_notice() {
  COMPAT_STATUS="FALLBACK"
  COMPAT_NOTES="${COMPAT_NOTES}${COMPAT_NOTES:+; }$*"
  log_w "$*"
}
health_warn() {
  [ "$HEALTH" = "ERROR" ] || HEALTH="DEGRADED"
  HEALTH_WARNINGS="${HEALTH_WARNINGS}${HEALTH_WARNINGS:+; }$*"
  log_w "$*"
}
health_error() {
  HEALTH="ERROR"
  HEALTH_WARNINGS="${HEALTH_WARNINGS}${HEALTH_WARNINGS:+; }$*"
  log_e "$*"
}
# Число непустых строк списка. Отдельной функцией, потому что grep -c при
# отсутствующем файле не печатает ничего, и в health.env попадало пустое значение.
list_count() {
  local n
  n=$(grep -cvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

write_health() {
  local tmp="$HEALTH_FILE.tmp.$$"
  {
    echo "HEALTH=$HEALTH"
    printf 'WARNINGS=%s\n' "$HEALTH_WARNINGS"
    printf 'STRATEGY_EFFECTIVE=%s\n' "${STRATEGY_EFFECTIVE:-${STRATEGY_MODE:-UNKNOWN}}"
    printf 'SMART_ENGINE=%s\n' "${STRATEGY_EFFECTIVE:-UNKNOWN}"
    printf 'IPSET_NETS=%s\n' "$(list_count "$IPSET_FILE")"
    printf 'IPSET_EXCLUDE_NETS=%s\n' "$(list_count "$IPSET_EXCLUDE_FILE")"
    printf 'HOSTLIST_MODE=%s\n' "${HOSTLIST_MODE:-AUTO}"
    printf 'USER_DOMAINS=%s\n' "$(list_count "$USER_DOMAINS_FILE")"
    printf 'LEARNED_DOMAINS=%s\n' "$(list_count "$LEARNED_DOMAINS_FILE")"
    printf 'AUTO_PROFILE=%s\n' "${AUTO_PROFILE:-UNKNOWN}"
    printf 'AUTO_PROFILE_NAME=%s\n' "${AUTO_PROFILE_NAME:-UNKNOWN}"
    printf 'AUTO_STRATEGY_SIGNATURE=%s\n' "${AUTO_STRATEGY_SIGNATURE:-UNKNOWN}"
    printf 'AUTO_STATUS=%s\n' "${AUTO_STATUS:-UNKNOWN}"
    printf 'AUTO_NETWORK_KEY=%s\n' "${AUTO_NETWORK_KEY:-none}"
    printf 'AUTO_NETWORK_IFACE=%s\n' "${AUTO_NETWORK_IFACE:-none}"
    printf 'AUTO_UPDATED=%s\n' "${AUTO_UPDATED:-0}"
    printf 'COMPAT_STATUS=%s\n' "${COMPAT_STATUS:-NATIVE}"
    printf 'COMPAT_NOTES=%s\n' "${COMPAT_NOTES:-}"
    printf 'CONNTRACK_ACCT=%s\n' "${CONNTRACK_ACCT:-0}"
    printf 'CONNBYTES4=%s\n' "${CONNBYTES4:-0}"
    printf 'CONNMARK4=%s\n' "${CONNMARK4:-0}"
    printf 'NFQUEUE4=%s\n' "${NFQ4:-0}"
    printf 'CONNBYTES6=%s\n' "${CONNBYTES6:-0}"
    printf 'CONNMARK6=%s\n' "${CONNMARK6:-0}"
    printf 'NFQUEUE6=%s\n' "${NFQ6:-0}"
  } > "$tmp" && mv -f "$tmp" "$HEALTH_FILE"
  chmod 0600 "$HEALTH_FILE" 2>/dev/null || true
}

# Чтение /proc/PID/cmdline у умирающего процесса способно заблокироваться
# навсегда: ядру нужна блокировка памяти задачи, которую в этот момент уже
# разбирают, и вернуть данные оно не может. Один такой PID (недобитый
# health-watcher) подвесил reload целиком — служба осталась без nfqws2, пока
# процессы не сняли вручную. Отсюда две ступени защиты:
#   1) /proc/PID/stat читается без этой блокировки, зомби видно сразу;
#   2) само чтение уходит в фон с потолком по времени, чтобы даже зависший
#      read не остановил перезапуск.
pid_cmdline() {
  local pid="$1" st tmp child n=0
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  st=$(sed -n 's/.*) //p' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1)
  case "$st" in ''|Z|X|x) return 1 ;; esac
  tmp="$RUN_DIR/.cmdline.$$.$pid"
  ( tr '\000' ' ' < "/proc/$pid/cmdline" >"$tmp" 2>/dev/null ) &
  child=$!
  while kill -0 "$child" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    log_w "Чтение cmdline PID $pid не завершилось за 2 с; процесс считается чужим"
    return 1
  fi
  wait "$child" 2>/dev/null
  cat "$tmp" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}
# Боевой и тестовый (auto-select) nfqws2 имеют одинаковые comm и cwd. Отличает их
# только номер очереди: без этой проверки reload во время probe подхватывал PID
# тестового процесса и убивал его вместе с состоянием подбора.
pid_is_service_nfqws() {
  local pid="$1" comm cwd cmd
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(cat "/proc/$pid/comm" 2>/dev/null)
  [ "$comm" = "nfqws2" ] || return 1
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  [ "$cwd" = "$BIN_DIR" ] || return 1
  cmd=$(pid_cmdline "$pid")
  case " $cmd " in *" --qnum=$QNUM "*) return 0 ;; *) return 1 ;; esac
}
pid_is_owned() {
  local pid="$1" kind="$2" cmd cwd comm
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  case "$kind" in
    nfqws2) pid_is_service_nfqws "$pid" ;;
    config-watch) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/on_change.sh" ;;
    vpn-watch) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/vpn-watch.sh" ;;
    health-watch) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/service-watch.sh" ;;
    service) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/service.sh" ;;
    httpd)
      comm=$(cat "/proc/$pid/comm" 2>/dev/null)
      cmd=$(pid_cmdline "$pid")
      { [ "$comm" = "httpd" ] || printf '%s' "$cmd" | grep -Fq "httpd"; } && printf '%s' "$cmd" | grep -Fq "$MODDIR/webroot"
      ;;
    *) return 1 ;;
  esac
}

find_owned_nfqws_pid() {
  local proc pid best=0
  for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    pid_is_service_nfqws "$pid" || continue
    [ "$pid" -gt "$best" ] 2>/dev/null && best=$pid
  done
  [ "$best" -gt 1 ] 2>/dev/null && printf '%s\n' "$best"
}

proc_session_fields() {
  local pid="$1"
  awk '{printf "ppid=%s pgrp=%s sid=%s",$4,$5,$6}' "/proc/$pid/stat" 2>/dev/null
}

stop_pid() {
  local pid_file="$1" name="$2" kind="$3" pid n
  [ -f "$pid_file" ] || return 0
  pid=$(cat "$pid_file" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) rm -f "$pid_file"; return 0 ;; esac
  if [ "$pid" = "$$" ]; then rm -f "$pid_file" 2>/dev/null; return 0; fi
  if kill -0 "$pid" 2>/dev/null; then
    if ! pid_is_owned "$pid" "$kind"; then
      log_w "Игнорируется stale pidfile $pid_file: PID=$pid больше не принадлежит $name"
      rm -f "$pid_file"
      return 0
    fi
    kill -TERM "$pid" 2>/dev/null
    n=0
    while pid_is_owned "$pid" "$kind" && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
    pid_is_owned "$pid" "$kind" && kill -KILL "$pid" 2>/dev/null
    log_i "Остановлен процесс $name (PID $pid)"
  fi
  rm -f "$pid_file"
}

# Добивает осиротевшие боевые nfqws2. Тестовый процесс auto-select (другой qnum)
# намеренно не трогаем: им владеет auto-select.sh и он снимет его сам.
stop_owned_nfqws() {
  local proc pid n
  for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    pid_is_service_nfqws "$pid" || continue
    kill -TERM "$pid" 2>/dev/null
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    log_i "Остановлен осиротевший nfqws2 (PID $pid)"
  done
}

# ------------------------------------------------------------------------------
# Единая точка запуска nfqws2. Раньше эта команда была скопирована восемь раз
# (четыре ветки в основном пути, три в быстрой смене профиля, одна в auto-select),
# из-за чего ветки успели разойтись по составу аргументов.
# Возвращает PID запущенного процесса в NFQWS_SPAWNED_PID.
# ------------------------------------------------------------------------------
NFQWS_SPAWNED_PID=""
NFQWS_SPAWN_METHOD=""
spawn_nfqws() {
  local launcher
  NFQWS_SPAWNED_PID=""; NFQWS_SPAWN_METHOD=""
  [ -x "$BIN_DIR/nfqws2" ] || return 1
  cd "$BIN_DIR" || return 1
  if command -v setsid >/dev/null 2>&1; then
    NFQWS_SPAWN_METHOD=setsid
    setsid "$BIN_DIR/nfqws2" "$@" >> "$LOG_FILE" 2>&1 &
    launcher=$!
  elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
    NFQWS_SPAWN_METHOD=busybox-setsid
    busybox setsid "$BIN_DIR/nfqws2" "$@" >> "$LOG_FILE" 2>&1 &
    launcher=$!
  elif command -v toybox >/dev/null 2>&1 && toybox setsid true >/dev/null 2>&1; then
    NFQWS_SPAWN_METHOD=toybox-setsid
    toybox setsid "$BIN_DIR/nfqws2" "$@" >> "$LOG_FILE" 2>&1 &
    launcher=$!
  else
    NFQWS_SPAWN_METHOD=nohup-fallback
    nohup "$BIN_DIR/nfqws2" "$@" >> "$LOG_FILE" 2>&1 &
    launcher=$!
  fi
  sleep 1
  # При setsid $! указывает на обёртку, а не на сам nfqws2 — доразрешаем по /proc.
  if pid_is_service_nfqws "$launcher"; then
    NFQWS_SPAWNED_PID="$launcher"
  else
    NFQWS_SPAWNED_PID=$(find_owned_nfqws_pid)
  fi
  pid_is_service_nfqws "$NFQWS_SPAWNED_PID"
}

# ------------------------------------------------------------------------------
# Выбор доменов, к которым применяется обход. Три режима, как в nfqws2-keenetic:
#
#   LIST — только домены из user.list. Обучение выключено.
#   AUTO — user.list + auto.list, который nfqws2 пополняет сам: домен попадает
#          туда, если недоступность зафиксирована HOSTLIST_AUTO_FAIL_THRESHOLD
#          раз за HOSTLIST_AUTO_FAIL_TIME секунд.
#   ALL  — все домены, кроме exclude_domains.list.
#
# exclude_domains.list действует во всех режимах.
# ------------------------------------------------------------------------------
# Исключения действуют во всех режимах и обязаны стоять в КАЖДОМ профиле.
build_exclude_args() {
  local args=""
  [ "$(list_count "$EXCLUDE_DOMAINS_FILE")" -gt 0 ] 2>/dev/null && args="$args --hostlist-exclude=$EXCLUDE_DOMAINS_FILE"
  [ "$(list_count "$IPSET_EXCLUDE_FILE")" -gt 0 ] 2>/dev/null && args="$args --ipset-exclude=$IPSET_EXCLUDE_FILE"
  printf '%s' "${args# }"
}

# $DESYNC_ARGS_* и пользовательские CUSTOM-аргументы содержат собственные --new,
# то есть описывают НЕСКОЛЬКО профилей. Фильтры внутри профиля не наследуются,
# поэтому --hostlist-exclude/--ipset-exclude, указанные один раз, защищали
# только первый из них: домен из exclude_domains.list спокойно попадал под
# десинхронизацию в следующем профиле. Здесь исключения дописываются в начало
# каждого профиля многопрофильной строки, КРОМЕ первого: его голову вызывающий
# формирует сам ($HOST_ARGS исключения уже содержит, дублировать их не нужно).
inject_exclude_args() {
  local excl="$1" out="" word
  shift
  [ "$#" -gt 0 ] || return 0
  [ -n "$excl" ] || { printf '%s' "$*"; return 0; }
  for word in "$@"; do
    if [ "$word" = "--new" ]; then
      out="$out --new $excl"
    else
      out="$out $word"
    fi
  done
  printf '%s' "${out# }"
}

# Первый профиль многопрофильной строки. Нужен там, где строка обязана
# описывать ровно ОДИН профиль (--ipset): внутренний --new иначе создал бы
# ещё один профиль уже без фильтра по подсети, то есть catch-all.
first_profile_args() {
  local out="" word
  for word in "$@"; do
    [ "$word" = "--new" ] && break
    out="$out $word"
  done
  printf '%s' "${out# }"
}

# Отдельный профиль для подсетей из ipset.list.
#
# Он выносится ЗА --new намеренно. И --hostlist, и --ipset — это include-фильтры
# одного профиля, и внутри профиля они складываются по И: пакет должен подойти
# сразу под оба. Нам же нужно ИЛИ — «либо домен из списка, либо адрес из списка».
# Отдельный профиль даёт именно это, без догадок о внутренней логике фильтров.
build_ipset_profile_args() {
  local strategy="$1" excl ports
  # Проверяем именно записи, а не размер: файл-шаблон состоит из комментариев,
  # и -s считал бы его непустым, создавая профиль, который ничего не матчит.
  [ "$(list_count "$IPSET_FILE")" -gt 0 ] 2>/dev/null || return 0
  # Профиль подсетей обязан остаться одним профилем, иначе хвост после
  # внутреннего --new превратится во второй catch-all уже без --ipset.
  strategy=$(first_profile_args $strategy)
  [ -n "$strategy" ] || return 0
  excl=$(build_exclude_args)
  # Свой --filter-tcp ставим, только если стратегия не принесла собственный:
  # два --filter-tcp в одном профиле — это конфликт, и более узкий из них
  # (например, --filter-tcp=443 у стратегии) молча отрезал бы порт 80.
  case " $strategy " in *' --filter-tcp='*) ports="" ;; *) ports="--filter-tcp=$PORTS_TCP " ;; esac
  # --new в КОНЦЕ: профиль подсетей идёт первым, и разделитель нужен после него.
  printf '%s' "${ports}--ipset=$IPSET_FILE${excl:+ $excl} $strategy --new"
}

build_hostlist_args() {
  local args
  args=$(build_exclude_args)
  case "$HOSTLIST_MODE" in
    ALL)
      log_i "Hostlist: режим ALL — обрабатываются все домены, кроме exclude_domains.list"
      ;;
    LIST)
      if [ "$(list_count "$USER_DOMAINS_FILE")" -gt 0 ] 2>/dev/null; then
        args="$args --hostlist=$USER_DOMAINS_FILE"
        log_i "Hostlist: режим LIST — доменов в user.list=$(list_count "$USER_DOMAINS_FILE")"
      else
        health_warn "HOSTLIST_MODE=LIST, но user.list пуст: обход не применится ни к одному домену"
      fi
      ;;
    *)
      # AUTO — режим по умолчанию.
      [ "$(list_count "$USER_DOMAINS_FILE")" -gt 0 ] 2>/dev/null && args="$args --hostlist=$USER_DOMAINS_FILE"
      mkdir -p "${LEARNED_DOMAINS_FILE%/*}" 2>/dev/null
      [ -f "$LEARNED_DOMAINS_FILE" ] || : > "$LEARNED_DOMAINS_FILE" 2>/dev/null
      chmod 0600 "$LEARNED_DOMAINS_FILE" 2>/dev/null || true
      args="$args --hostlist-auto=$LEARNED_DOMAINS_FILE"
      args="$args --hostlist-auto-fail-threshold=${HOSTLIST_AUTO_FAIL_THRESHOLD:-3}"
      args="$args --hostlist-auto-fail-time=${HOSTLIST_AUTO_FAIL_TIME:-60}"
      log_i "Hostlist: режим AUTO — user.list=$(list_count "$USER_DOMAINS_FILE") выучено=$(list_count "$LEARNED_DOMAINS_FILE") порог=${HOSTLIST_AUTO_FAIL_THRESHOLD:-3}/${HOSTLIST_AUTO_FAIL_TIME:-60}с"
      ;;
  esac
  printf '%s' "${args# }"
}

# Постоянная часть командной строки nfqws2 (без стратегии).
nfqws_base_args() {
  printf '%s' "--user=root --qnum=$QNUM --bind-fix4 --bind-fix6"
  printf ' %s' "--lua-init=@$BIN_DIR/zapret-lib.lua" \
               "--lua-init=@$BIN_DIR/zapret-antidpi.lua" \
               "--lua-init=@$BIN_DIR/zapret-auto.lua"
}

# Список подсетей туннеля (lists/warp_bypass_nets.list) читает только
# warp-tunnel.sh: он решает, что заворачивать в туннель. Здесь он больше не
# нужен — трафик, ушедший в awg99, ловится правилом на интерфейс.

# ------------------------------------------------------------------------------
# Подпись применённой конфигурации.
# inotify не видит атомарную замену файла (mv -f) при наблюдении за самим файлом,
# а набор поддерживаемых масок различается между сборками busybox. Поэтому поверх
# inotify работает дешёвая проверка контрольной суммы в health-watcher: раз в
# HEALTH_WATCH_INTERVAL он сверяет подпись и запускает реконсиляцию, если конфиг
# изменился в обход вотчера (правка через adb push, файловый менеджер и т.п.).
# ------------------------------------------------------------------------------
CONFIG_SIG_FILE="$RUN_DIR/config.sig"

command_path() {
  command -v "$1" 2>/dev/null || {
    [ -x "/system/bin/$1" ] && echo "/system/bin/$1"
  }
}

IPT="$(command_path iptables)"
IP6T="$(command_path ip6tables)"

cmd_capture() {
  local label="$1" out rc
  shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    log_e "$label: rc=$rc; cmd=$*; out=${out:-<empty>}"
  else
    log_d "$label: OK; cmd=$*${out:+; out=$out}"
  fi
  return "$rc"
}

ipt4() { cmd_capture "iptables" "$IPT" -w 5 "$@"; }
ipt6() { [ -n "$IP6T" ] || return 1; cmd_capture "ip6tables" "$IP6T" -w 5 "$@"; }
ipt4_quiet() { [ -n "$IPT" ] && "$IPT" -w 1 "$@" >/dev/null 2>&1; }
ipt6_quiet() { [ -n "$IP6T" ] && "$IP6T" -w 1 "$@" >/dev/null 2>&1; }

delete_jump_bounded() {
  local family="$1" table="$2" chain="$3" target="$4" attempt=0
  while [ "$attempt" -lt 8 ]; do
    if [ "$family" = 4 ]; then
      ipt4_quiet -t "$table" -D "$chain" -j "$target" || return 0
    else
      ipt6_quiet -t "$table" -D "$chain" -j "$target" || return 0
    fi
    attempt=$((attempt + 1))
  done
  health_warn "Очистка $family/$table/$chain->$target ограничена восемью повторами"
  return 0
}

cleanup_iptables() {
  [ -n "$IPT" ] && {
    # Переходные цепочки от прежних версий модуля, где правила строились по UID.
    delete_jump_bounded 4 mangle OUTPUT ZAPRET2_MANGLE_NEW
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE_NEW; ipt4_quiet -t mangle -X ZAPRET2_MANGLE_NEW
    delete_jump_bounded 4 filter OUTPUT ZAPRET2_FILTER_NEW
    ipt4_quiet -t filter -F ZAPRET2_FILTER_NEW; ipt4_quiet -t filter -X ZAPRET2_FILTER_NEW
    delete_jump_bounded 4 mangle OUTPUT ZAPRET2_MANGLE
    delete_jump_bounded 4 mangle INPUT ZAPRET2_MANGLE_IN
    delete_jump_bounded 4 mangle FORWARD ZAPRET2_MANGLE_FORWARD
    delete_jump_bounded 4 mangle ZAPRET2_MANGLE ZAPRET2_APPS_BYPASS
    ipt4_quiet -t mangle -F ZAPRET2_APPS_BYPASS; ipt4_quiet -t mangle -X ZAPRET2_APPS_BYPASS
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE; ipt4_quiet -t mangle -X ZAPRET2_MANGLE
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE_IN; ipt4_quiet -t mangle -X ZAPRET2_MANGLE_IN
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE_FORWARD; ipt4_quiet -t mangle -X ZAPRET2_MANGLE_FORWARD
    delete_jump_bounded 4 filter OUTPUT ZAPRET2_FILTER
    delete_jump_bounded 4 filter FORWARD ZAPRET2_FILTER_FORWARD
    ipt4_quiet -t filter -F ZAPRET2_FILTER; ipt4_quiet -t filter -X ZAPRET2_FILTER
    ipt4_quiet -t filter -F ZAPRET2_FILTER_FORWARD; ipt4_quiet -t filter -X ZAPRET2_FILTER_FORWARD
    delete_jump_bounded 4 nat PREROUTING ZAPRET2_NAT_PREROUTING
    ipt4_quiet -t nat -F ZAPRET2_NAT_PREROUTING; ipt4_quiet -t nat -X ZAPRET2_NAT_PREROUTING
  }
  [ -n "$IP6T" ] && {
    delete_jump_bounded 6 mangle OUTPUT ZAPRET2_MANGLE_NEW
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE_NEW; ipt6_quiet -t mangle -X ZAPRET2_MANGLE_NEW
    delete_jump_bounded 6 filter OUTPUT ZAPRET2_FILTER_NEW
    ipt6_quiet -t filter -F ZAPRET2_FILTER_NEW; ipt6_quiet -t filter -X ZAPRET2_FILTER_NEW
    delete_jump_bounded 6 mangle OUTPUT ZAPRET2_MANGLE
    delete_jump_bounded 6 mangle INPUT ZAPRET2_MANGLE_IN
    delete_jump_bounded 6 mangle FORWARD ZAPRET2_MANGLE_FORWARD
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE; ipt6_quiet -t mangle -X ZAPRET2_MANGLE
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE_IN; ipt6_quiet -t mangle -X ZAPRET2_MANGLE_IN
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE_FORWARD; ipt6_quiet -t mangle -X ZAPRET2_MANGLE_FORWARD
    delete_jump_bounded 6 filter OUTPUT ZAPRET2_FILTER
    delete_jump_bounded 6 filter FORWARD ZAPRET2_FILTER_FORWARD
    ipt6_quiet -t filter -F ZAPRET2_FILTER; ipt6_quiet -t filter -X ZAPRET2_FILTER
    ipt6_quiet -t filter -F ZAPRET2_FILTER_FORWARD; ipt6_quiet -t filter -X ZAPRET2_FILTER_FORWARD
    delete_jump_bounded 6 filter OUTPUT ZAPRET2_IPV6_BLOCK
    delete_jump_bounded 6 filter FORWARD ZAPRET2_IPV6_BLOCK
    ipt6_quiet -t filter -F ZAPRET2_IPV6_BLOCK; ipt6_quiet -t filter -X ZAPRET2_IPV6_BLOCK
  }
  ip -4 route flush cache 2>/dev/null || true
  ip -6 route flush cache 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Отбор трафика идёт по ДОМЕНАМ и подсетям, а не по приложениям.
#
# Здесь раньше жило разрешение UID: разбор /data/system/packages.list, опрос
# PackageManager, обход профилей пользователя, кэш и его доверификация — свыше
# двухсот строк. Всё это ушло вместе с режимами INCLUDE/EXCLUDE/GLOBAL.
#
# Причина проста: каталог приложений неизбежно отстаёт от того, что реально
# установлено (на тестовом устройстве из 74 записей совпали 3), и правило по
# UID не помогает, если пользователь поставил другой клиент того же сервиса.
# Домен же заблокирован одинаково для любого приложения, которое к нему ходит.
# ------------------------------------------------------------------------------
probe_firewall() {
  local chain="ZAPRET2_PROBE_$$" out
  [ -n "$IPT" ] || { health_error "iptables не найден"; return 1; }
  log_i "Firewall IPv4: $IPT; $($IPT -V 2>&1)"
  if ! "$IPT" -w 5 -t mangle -N "$chain" >/dev/null 2>&1; then
    health_error "Не удалось создать тестовую IPv4 mangle-цепочку"
    return 1
  fi
  # Проверка xt_owner убрана вместе с правилами по приложениям: отбор идёт по
  # доменам и подсетям внутри nfqws2, netfilter владельца сокета не различает.
  if "$IPT" -w 5 -t mangle -A "$chain" -p tcp -m connbytes --connbytes 1:2 --connbytes-dir reply --connbytes-mode packets -j RETURN >/dev/null 2>&1; then
    CONNBYTES4=1
  else
    CONNBYTES4=0
  fi
  "$IPT" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
  CONNMARK4=0
  if "$IPT" -w 5 -t mangle -A "$chain" -p tcp -j CONNMARK --set-xmark "$FLOW_CONNMARK" >/dev/null 2>&1; then
    "$IPT" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
    if "$IPT" -w 5 -t mangle -A "$chain" -m connmark --mark "$FLOW_CONNMARK" -j RETURN >/dev/null 2>&1; then CONNMARK4=1; fi
  fi
  "$IPT" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
  if "$IPT" -w 5 -t mangle -A "$chain" -p tcp --dport 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass >/dev/null 2>&1; then
    NFQ4=1; QBYPASS4="--queue-bypass"
  else
    "$IPT" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
    if "$IPT" -w 5 -t mangle -A "$chain" -p tcp --dport 443 -j NFQUEUE --queue-num "$QNUM" >/dev/null 2>&1; then
      NFQ4=1; QBYPASS4=""; health_warn "IPv4 NFQUEUE работает без --queue-bypass"
    else
      NFQ4=0; health_error "IPv4 NFQUEUE target недоступен"
    fi
  fi
  "$IPT" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
  "$IPT" -w 5 -t mangle -X "$chain" >/dev/null 2>&1

  NFQ6=0; CONNBYTES6=0; CONNMARK6=0; QBYPASS6=""
  if [ -n "$IP6T" ]; then
    log_i "Firewall IPv6: $IP6T; $($IP6T -V 2>&1)"
    if "$IP6T" -w 5 -t mangle -N "$chain" >/dev/null 2>&1; then
      if "$IP6T" -w 5 -t mangle -A "$chain" -p tcp -m connbytes --connbytes 1:2 --connbytes-dir reply --connbytes-mode packets -j RETURN >/dev/null 2>&1; then CONNBYTES6=1; fi
      "$IP6T" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
      if "$IP6T" -w 5 -t mangle -A "$chain" -p tcp -j CONNMARK --set-xmark "$FLOW_CONNMARK" >/dev/null 2>&1; then
        "$IP6T" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
        if "$IP6T" -w 5 -t mangle -A "$chain" -m connmark --mark "$FLOW_CONNMARK" -j RETURN >/dev/null 2>&1; then CONNMARK6=1; fi
      fi
      "$IP6T" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
      if "$IP6T" -w 5 -t mangle -A "$chain" -p tcp --dport 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass >/dev/null 2>&1; then
        NFQ6=1; QBYPASS6="--queue-bypass"
      else
        "$IP6T" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
        if "$IP6T" -w 5 -t mangle -A "$chain" -p tcp --dport 443 -j NFQUEUE --queue-num "$QNUM" >/dev/null 2>&1; then
          NFQ6=1; QBYPASS6=""
        fi
      fi
      "$IP6T" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
      "$IP6T" -w 5 -t mangle -X "$chain" >/dev/null 2>&1
    fi
    [ "$NFQ6" = "1" ] || health_warn "IPv6 NFQUEUE недоступен — IPv6 обход будет пропущен"
  else
    health_warn "ip6tables не найден — IPv6 правила недоступны"
  fi
  log_i "Firewall capabilities: IPv4 NFQUEUE=$NFQ4  connbytes=$CONNBYTES4 connmark=$CONNMARK4 qBypass=${QBYPASS4:-no}; IPv6 NFQUEUE=$NFQ6  connbytes=$CONNBYTES6 connmark=$CONNMARK6 qBypass=${QBYPASS6:-no}"
  [ "$NFQ4" = "1" ]
}

verify_rules_snapshot() {
  local out
  out=$($IPT -w 5 -t mangle -L ZAPRET2_MANGLE -nvx --line-numbers 2>&1)
  log_i "IPv4 mangle ZAPRET2_MANGLE:\n$out"
  out=$($IPT -w 5 -t filter -L ZAPRET2_FILTER -nvx --line-numbers 2>&1)
  log_i "IPv4 filter ZAPRET2_FILTER:\n$out"
  if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ]; then
    out=$($IPT -w 5 -t mangle -L ZAPRET2_MANGLE_IN -nvx --line-numbers 2>&1)
    log_i "IPv4 mangle ZAPRET2_MANGLE_IN:\n$out"
  fi
  if [ "$ENABLE_HOTSPOT" = "1" ]; then
    out=$($IPT -w 5 -t mangle -L ZAPRET2_MANGLE_FORWARD -nvx --line-numbers 2>&1)
    log_i "IPv4 mangle ZAPRET2_MANGLE_FORWARD:\n$out"
  fi
  if [ -n "$IP6T" ]; then
    out=$($IP6T -w 5 -t mangle -L ZAPRET2_MANGLE -nvx --line-numbers 2>&1)
    log_i "IPv6 mangle ZAPRET2_MANGLE:\n$out"
  fi
}

log_environment() {
  local modver android sdk device model kernel manager="unknown"
  modver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)
  android=$(getprop ro.build.version.release 2>/dev/null)
  sdk=$(getprop ro.build.version.sdk 2>/dev/null)
  device=$(getprop ro.product.device 2>/dev/null)
  model=$(getprop ro.product.model 2>/dev/null)
  kernel=$(uname -r 2>/dev/null)
  [ -d /data/adb/ksu ] && manager="KernelSU/KernelSU Next"
  command -v magisk >/dev/null 2>&1 && manager="Magisk"
  [ -d /data/adb/ap ] && manager="APatch"
  log_i "===== START session=$$ version=$modver reload=${1:-0} ====="
  log_i "Environment: Android=$android SDK=$sdk device=$device model=$model kernel=$kernel manager=$manager SELinux=$(getenforce 2>/dev/null) arch=$(uname -m 2>/dev/null)"
}

log_network_modules() {
  local p id name version
  for p in /data/adb/modules/*/module.prop; do
    [ -f "$p" ] || continue
    [ -f "${p%/module.prop}/disable" ] && continue
    id=$(sed -n 's/^id=//p' "$p" | head -n1)
    name=$(sed -n 's/^name=//p' "$p" | head -n1)
    version=$(sed -n 's/^version=//p' "$p" | head -n1)
    case "$id $name" in
      *[Vv][Pp][Nn]*|*[Tt][Tt][Ll]*|*[Nn][Ff][Qq]*|*[Ff]irewall*|*[Tt]ether*|*[Pp]roxy*|*[Zz]apret*)
        [ "$id" = "zapret2-android" ] || log_w "Другой сетевой модуль активен: id=$id name=$name version=$version (возможен конфликт правил/маршрутов)" ;;
    esac
  done
}

ensure_conntrack_accounting() {
  local f=/proc/sys/net/netfilter/nf_conntrack_acct cur
  CONNTRACK_ACCT=0
  [ -r "$f" ] || { log_w "nf_conntrack_acct sysctl отсутствует"; return 1; }
  cur=$(cat "$f" 2>/dev/null)
  if [ "$cur" != "1" ]; then
    echo 1 > "$f" 2>/dev/null || { log_w "Не удалось включить nf_conntrack_acct; SMART_NATIVE недоступен"; return 1; }
    log_i "SMART: включён net.netfilter.nf_conntrack_acct=1 для bounded reply-feed"
  fi
  [ "$(cat "$f" 2>/dev/null)" = "1" ] && CONNTRACK_ACCT=1
  [ "$CONNTRACK_ACCT" = "1" ]
}

tune_kernel_network() {
  log_i "Kernel network tuning: оптимизация сетевого стека ядра..."
  # 1. Снижение таймаута conntrack с 5 дней до 2 часов (экономия RAM ядра и ускорение Netfilter)
  for f in /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established /proc/sys/net/ipv4/netfilter/ip_conntrack_tcp_timeout_established; do
    [ -w "$f" ] && echo 7200 > "$f" 2>/dev/null || true
  done
  # 2. Отключение сброса CWND после простоя (мгновенная скорость при открытии видео/страниц)
  [ -w /proc/sys/net/ipv4/tcp_slow_start_after_idle ] && echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null || true
  # 3. Полный TCP Fast Open (клиент + сервер)
  [ -w /proc/sys/net/ipv4/tcp_fastopen ] && echo 3 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || true
  # 4. Устранение Bufferbloat в сокетах отправки
  [ -w /proc/sys/net/ipv4/tcp_notsent_lowat ] && echo 16384 > /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null || true
  # 5. Быстрое переиспользование сокетов TIME_WAIT
  [ -w /proc/sys/net/ipv4/tcp_tw_reuse ] && echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || true
  [ -w /proc/sys/net/ipv4/tcp_fin_timeout ] && echo 15 > /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null || true
  # 6. Защита от сброса сессий DPI
  [ -w /proc/sys/net/ipv4/tcp_rfc1337 ] && echo 1 > /proc/sys/net/ipv4/tcp_rfc1337 2>/dev/null || true
  # 7. Path MTU Discovery Blackhole detection
  [ -w /proc/sys/net/ipv4/tcp_mtu_probing ] && echo 1 > /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || true
  # 8. Оптимизация очереди пакетов qdisc (fq_codel / fq для снижения пинга и джиттера)
  if [ -w /proc/sys/net/core/default_qdisc ]; then
    echo fq_codel > /proc/sys/net/core/default_qdisc 2>/dev/null || echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || true
  fi
}

is_ksu_or_apatch=0
if [ "${KSU:-}" = "true" ] || [ -n "${KSU_VER:-}" ] || [ -d /data/adb/ksu ] || [ -n "${APATCH:-}" ] || [ -d /data/adb/ap ]; then
  is_ksu_or_apatch=1
fi
if [ -z "$SERVICE_ACTION" ]; then
  write_start_state "WAITING" "Ожидание завершения загрузки Android" 5
  boot_trace "late_start lifecycle entry manager_async=$is_ksu_or_apatch"
  if [ "$is_ksu_or_apatch" = "1" ]; then
    rm -f "$LATE_START_PID_FILE" 2>/dev/null
    exit 0
  fi
  echo $$ > "$LATE_START_PID_FILE" 2>/dev/null
  trap 'rm -f "$LATE_START_PID_FILE" 2>/dev/null' EXIT HUP INT TERM
  if command -v resetprop >/dev/null 2>&1; then
    resetprop -w sys.boot_completed 0 >/dev/null 2>&1 || true
  fi
  wait_ticks=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 2; wait_ticks=$((wait_ticks + 1))
    [ "$wait_ticks" -lt 180 ] || { boot_trace "Magisk wait timeout"; write_start_state "ERROR" "Android не завершил загрузку за 6 минут" 100; exit 1; }
  done
  rm -f "$LATE_START_PID_FILE" 2>/dev/null; trap - EXIT HUP INT TERM
  SERVICE_ACTION="boot"
  write_start_state "STARTING" "Android загружен · подготовка службы" 10
  sleep 2
fi

if [ "$SERVICE_ACTION" = "stop" ] || [ "$SERVICE_ACTION" = "service-stop" ]; then
  boot_trace "service stop requested"
  log_i "Остановка службы Zapret2 по запросу пользователя..."
  touch "$RUN_DIR/service_stopped.flag" 2>/dev/null || true
  stop_pid "$NFQWS_PID_FILE" "nfqws2" nfqws2
  stop_owned_nfqws
  stop_pid "$VPN_WATCHER_PID_FILE" "сетевой watcher" vpn-watch
  stop_pid "$HEALTH_WATCHER_PID_FILE" "health watcher" health-watch
  stop_pid "$WATCHER_PID_FILE" "config watcher" config-watch
  stop_pid "$RUN_DIR/auto-probe.pid" "auto-probe" auto
  stop_pid "$RUN_DIR/httpd.pid" "webui-httpd" httpd
  cleanup_iptables
  "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
  [ -f "$MODDIR/warp-tunnel.sh" ] && sh "$MODDIR/warp-tunnel.sh" stop >/dev/null 2>&1 || true
  rm -f "$NFQWS_PID_FILE" "$WATCHER_PID_FILE" "$VPN_WATCHER_PID_FILE" "$HEALTH_WATCHER_PID_FILE" "$RUN_DIR/direct.flag" 2>/dev/null || true
  HEALTH="STOPPED"
  write_health
  write_start_state "STOPPED" "Служба остановлена" 0
  log_i "Служба Zapret2 полностью остановлена"
  exit 0
fi

rm -f "$RUN_DIR/service_stopped.flag" 2>/dev/null || true

if [ "$SERVICE_ACTION" != "reload" ] && [ "$SERVICE_ACTION" != "boot" ] && [ "$SERVICE_ACTION" != "reload-profile" ]; then
  write_start_state "WAITING" "Ожидание sys.boot_completed" 5
  until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 2; done
  SERVICE_ACTION="boot"; write_start_state "STARTING" "Android загружен · подготовка службы" 10; sleep 1
fi
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${STRATEGY_MODE:=SMART}" "${FORCE_TCP:=1}" "${QUIC_MODE:=ON}" "${PORTS_TCP:=80,443}" "${QNUM:=200}" "${ENABLE_HOTSPOT:=1}" "${DNS_FORWARD_HOTSPOT:=0}" "${DNS_FORWARD_SERVER:=1.1.1.1}"
: "${FORCE_TCP_HOTSPOT:=1}" "${VPN_FALLBACK_MODE:=ANTIDPI}" "${NFQWS_DEBUG:=0}" "${LOG_VERBOSE:=1}"
: "${ENABLE_WARP:=0}" "${ENABLE_HTTP_API:=0}" "${LOG_EXPORT_ON_BOOT:=0}" "${AUTO_SELECT_ENABLED:=1}" "${HEALTH_WATCH_INTERVAL:=60}"
: "${HOSTLIST_MODE:=AUTO}" "${HOSTLIST_AUTO_FAIL_THRESHOLD:=3}" "${HOSTLIST_AUTO_FAIL_TIME:=60}"
case "$HOSTLIST_MODE" in LIST|AUTO|ALL) ;; *) HOSTLIST_MODE=AUTO ;; esac
# Прежние версии знали QUIC_MODE=SELECTED/GLOBAL: выборочность зависела от
# списка приложений. Теперь имя хоста в UDP/443 недоступно, поэтому режимов
# два. Любое старое значение, кроме OFF, означало «блокировать».
case "$QUIC_MODE" in
  OFF|off) QUIC_MODE=OFF ;;
  *) QUIC_MODE=ON ;;
esac
case "$HOSTLIST_AUTO_FAIL_THRESHOLD" in ''|*[!0-9]*) HOSTLIST_AUTO_FAIL_THRESHOLD=3 ;; esac
case "$HOSTLIST_AUTO_FAIL_TIME" in ''|*[!0-9]*) HOSTLIST_AUTO_FAIL_TIME=60 ;; esac
: "${TETHER_IFACES:=ap+ swlan+ softap+ ap_br_wlan+ ap_br_softap+ rndis+ usb+ ncm+ bnep+ bt-pan+ pan+ tether+ wlan1 wlan2 wlan3 wlan4 wifi1 wifi2 wifi3 wifi4}" "${VPN_WATCH_INTERVAL:=2}" "${VPN_RETRY_INTERVAL:=1}" "${VPN_ROLE_RECHECK:=30}" "${VPN_EVENT_DEBOUNCE:=2}" "${VPN_NETLINK_MONITOR:=1}"
: "${AUTO_REPLY_PACKETS:=12}" "${FLOW_CONNMARK:=0x10000000/0x10000000}"
case "$STRATEGY_MODE" in SIMPLE|AUTO|'') STRATEGY_MODE=SMART ;; SMART|CUSTOM) ;; *) STRATEGY_MODE=SMART ;; esac

# mkdir атомарен, а запись pid внутрь — уже нет. Пустой pid означает одно из
# двух: блокировка брошена, или её владелец только что сделал mkdir и ещё не
# успел записать себя. Прежний код сносил её сразу — и оба процесса уходили
# работать одновременно. Теперь пустой pid должен продержаться две итерации
# (секунду): владелец пишет pid в следующей же команде, за микросекунды.
acquire_lock() {
  local lock_attempt=0 lock_pid lock_started now lock_age n empty_seen=0
  [ "$(cat "$SERVICE_LOCK/pid" 2>/dev/null)" = "$$" ] && return 0
  while ! mkdir "$SERVICE_LOCK" 2>/dev/null; do
    lock_pid=$(cat "$SERVICE_LOCK/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && return 0
    case "$lock_pid" in
      ''|0|*[!0-9]*)
        empty_seen=$((empty_seen + 1))
        [ "$empty_seen" -ge 2 ] && { rm -rf "$SERVICE_LOCK" 2>/dev/null; empty_seen=0; }
        ;;
      *)
        empty_seen=0
        if ! kill -0 "$lock_pid" 2>/dev/null || ! pid_is_owned "$lock_pid" service; then
          rm -rf "$SERVICE_LOCK" 2>/dev/null
        else
          lock_started=$(cat "$SERVICE_LOCK/started" 2>/dev/null)
          now=$(date +%s 2>/dev/null)
          case "$lock_started:$now" in
            *[!0-9:]*|:*) ;;
            *)
              lock_age=$((now - lock_started))
              if [ "$lock_age" -ge 120 ] 2>/dev/null; then
                log_w "Прерывается зависший reload PID=$lock_pid age=${lock_age}s"
                kill -TERM "$lock_pid" 2>/dev/null
                n=0
                while pid_is_owned "$lock_pid" service && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
                pid_is_owned "$lock_pid" service && kill -KILL "$lock_pid" 2>/dev/null
                rm -rf "$SERVICE_LOCK" 2>/dev/null
              fi
              ;;
          esac
        fi
        ;;
    esac
    lock_attempt=$((lock_attempt + 1))
    if [ "$lock_attempt" -ge 10 ]; then
      log_w "Пропуск перезапуска: другая перезагрузка службы уже выполняется (PID ${lock_pid:-unknown})"
      return 1
    fi
    sleep 1
  done
  echo $$ > "$SERVICE_LOCK/pid"
  date +%s > "$SERVICE_LOCK/started" 2>/dev/null
}
release_service_lock() {
  [ "$(cat "$SERVICE_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$SERVICE_LOCK" 2>/dev/null
}
# ------------------------------------------------------------------------------
# Подъём сторожевых процессов.
#
# Вынесено в функцию и вызывается из ловушки EXIT, а не только по успешному
# пути. Раньше watcher-ы гасились в начале реконсиляции, а поднимались в самом
# конце — и все аварийные выходы между этими точками (нет NFQUEUE, nfqws2 не
# стартовал, критическая ошибка правил) оставляли модуль вообще без надзора:
# ни самовосстановления, ни реакции на смену сети до перезагрузки телефона.
# Функция идемпотентна: живой процесс не трогается.
# ------------------------------------------------------------------------------
ensure_watchers() {
  local watch_pid vpn_wpid health_wpid
  watch_pid=$(cat "$WATCHER_PID_FILE" 2>/dev/null)
  if [ -z "$watch_pid" ] || ! pid_is_owned "$watch_pid" config-watch; then
    rm -f "$WATCHER_PID_FILE" 2>/dev/null
    # Наблюдаем за КАТАЛОГАМИ, а не за отдельными файлами: все писатели модуля
    # заменяют файлы атомарно (mv -f tmp file), после чего watch на файле
    # остаётся висеть на удалённом иноде и больше никогда не срабатывает.
    # Маска wnd = close_write | create | delete; события чтения не подписываем,
    # иначе каждый разбор списка самим модулем поднимал бы реконсиляцию.
    WATCH_TARGETS="$MODDIR:wnd $LISTS_DIR:wnd $STRATEGY_DIR:wnd"
    if command -v inotifyd >/dev/null 2>&1; then
      inotifyd "$MODDIR/on_change.sh" $WATCH_TARGETS 2>/dev/null &
      echo $! > "$WATCHER_PID_FILE"
    elif command -v busybox >/dev/null 2>&1; then
      busybox inotifyd "$MODDIR/on_change.sh" $WATCH_TARGETS 2>/dev/null &
      echo $! > "$WATCHER_PID_FILE"
    else
      health_warn "inotifyd не найден: изменения списков подхватит health-watcher (до ${HEALTH_WATCH_INTERVAL:-60} сек)"
      write_health
    fi
  fi

  # Сетевой watcher отвечает не только за раздачу: именно он будит автоподбор
  # при смене Wi-Fi/соты и синхронизирует WARP и Geo туннели.
  if [ "${ENABLE_HOTSPOT:-0}" = "1" ] || [ "${AUTO_SELECT_ENABLED:-1}" = "1" ] || [ "${ENABLE_WARP:-0}" = "1" ] || [ "${ENABLE_GEO_WARP:-1}" = "1" ]; then
    vpn_wpid=$(cat "$VPN_WATCHER_PID_FILE" 2>/dev/null)
    if [ -z "$vpn_wpid" ] || ! pid_is_owned "$vpn_wpid" vpn-watch; then
      sh "$MODDIR/vpn-watch.sh" >/dev/null 2>&1 &
      echo $! > "$VPN_WATCHER_PID_FILE"
      log_i "Сетевой watcher запущен: netlink/inotify event-driven, hotspot=${ENABLE_HOTSPOT:-0} auto_select=${AUTO_SELECT_ENABLED:-1} warp=${ENABLE_WARP:-0} geo=${ENABLE_GEO_WARP:-1}"
    fi
  else
    stop_pid "$VPN_WATCHER_PID_FILE" "VPN/tether watcher" vpn-watch
  fi

  health_wpid=$(cat "$HEALTH_WATCHER_PID_FILE" 2>/dev/null)
  if [ -z "$health_wpid" ] || ! pid_is_owned "$health_wpid" health-watch; then
    sh "$MODDIR/service-watch.sh" >/dev/null 2>&1 &
    echo $! > "$HEALTH_WATCHER_PID_FILE"
  fi
}

if ! acquire_lock; then
  boot_trace "service lock busy; another trigger owns startup"
  exit 0
fi
trap 'release_service_lock; exit 1' HUP INT TERM
trap 'ensure_watchers; release_service_lock' EXIT

# Горячая смена AUTO-профиля без пересборки firewall и UID-правил.
# Возврат 1 означает "быстрый путь неприменим" — вызывающий делает полный reload.
reload_active_profile() {
  local profile profile_name profile_signature special host excl general ipset_args debug_arg pid tmp runtime_engine
  # Движок определяется probe_firewall, который быстрый путь намеренно пропускает,
  # поэтому берём его из снимка, оставленного последним полным стартом.
  runtime_engine=""
  [ -f "$RUN_DIR/tether-runtime.conf" ] && runtime_engine=$(sed -n 's/^STRATEGY_EFFECTIVE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$RUN_DIR/tether-runtime.conf" | head -n1)

  # Per-network профили существуют только в SMART_ACTIVE. В CUSTOM у пользователя
  # свои аргументы, в SMART_NATIVE стратегию выбирает circular внутри nfqws2 —
  # подменять их результатом probe нельзя.
  if [ "$STRATEGY_MODE" != "SMART" ]; then
    log_w "Быстрая смена профиля отклонена: STRATEGY_MODE=$STRATEGY_MODE (профиль пользователя не подменяется)"
    return 1
  fi
  if [ -n "$runtime_engine" ] && [ "$runtime_engine" != "SMART_ACTIVE" ]; then
    log_w "Быстрая смена профиля отклонена: активен движок $runtime_engine, per-network профиль не применяется"
    return 1
  fi

  [ -f "$AUTO_RESULT_FILE" ] && . "$AUTO_RESULT_FILE"
  profile=${AUTO_PROFILE:-$AUTO_PROFILE_DEFAULT}
  strategy_read "$profile" || { log_w "Быстрый reload отклонён: невалидный AUTO_PROFILE=$profile"; return 1; }
  profile_name=$STRATEGY_FILE_NAME
  profile_signature=$(strategy_catalog_signature)
  # Переход в DIRECT или из него меняет сам состав netfilter-правил (снимаются
  # NFQUEUE-хуки), поэтому он требует полного reload, а не подмены процесса.
  [ "$STRATEGY_FILE_MODE" = DIRECT ] && return 1
  [ -f "$RUN_DIR/direct.flag" ] && return 1

  # Тот же состав аргументов, что и в полном старте ветки SMART_ACTIVE,
  # включая выбор доменов (--hostlist / --hostlist-auto), исключения в каждом
  # профиле и профиль подсетей: без последнего быстрая смена профиля тихо
  # теряла ipset.list до следующего полного reload.
  host=$(build_hostlist_args)
  excl=$(build_exclude_args)
  special="$host $STRATEGY_FILE_ARGS --new"
  general="$host $(inject_exclude_args "$excl" $DESYNC_ARGS_SMART_COMPAT_GENERAL)"
  ipset_args=$(build_ipset_profile_args "$STRATEGY_FILE_ARGS")
  debug_arg=""; [ "$NFQWS_DEBUG" = 1 ] && debug_arg="--debug=@$NFQWS_LOG"
  [ -x "$BIN_DIR/nfqws2" ] || return 1
  stop_pid "$NFQWS_PID_FILE" "nfqws2 для смены AUTO-профиля" nfqws2
  if ! spawn_nfqws $(nfqws_base_args) $debug_arg $ipset_args $special $general; then
    log_e "Быстрая смена AUTO-профиля не запустила nfqws2 (метод ${NFQWS_SPAWN_METHOD:-none})"
    return 1
  fi
  pid="$NFQWS_SPAWNED_PID"
  echo "$pid" > "$NFQWS_PID_FILE"; chmod 0600 "$NFQWS_PID_FILE" 2>/dev/null || true
  if [ -f "$HEALTH_FILE" ]; then
    tmp="$HEALTH_FILE.tmp.$$"
    awk -v p="$profile" -v pn="$profile_name" -v ps="$profile_signature" -v s="${AUTO_STATUS:-SELECTED}" -v k="${AUTO_NETWORK_KEY:-none}" -v i="${AUTO_NETWORK_IFACE:-none}" -v u="${AUTO_UPDATED:-0}" '
      BEGIN { seen_p=seen_pn=seen_ps=seen_s=seen_k=seen_i=seen_u=seen_n=0; note="SMART_ACTIVE: активный профиль " p " / " pn " (" s ")" }
      /^AUTO_PROFILE=/ {print "AUTO_PROFILE=" p; seen_p=1; next}
      /^AUTO_PROFILE_NAME=/ {print "AUTO_PROFILE_NAME=" pn; seen_pn=1; next}
      /^AUTO_STRATEGY_SIGNATURE=/ {print "AUTO_STRATEGY_SIGNATURE=" ps; seen_ps=1; next}
      /^AUTO_STATUS=/ {print "AUTO_STATUS=" s; seen_s=1; next}
      /^AUTO_NETWORK_KEY=/ {print "AUTO_NETWORK_KEY=" k; seen_k=1; next}
      /^AUTO_NETWORK_IFACE=/ {print "AUTO_NETWORK_IFACE=" i; seen_i=1; next}
      /^AUTO_UPDATED=/ {print "AUTO_UPDATED=" u; seen_u=1; next}
      /^COMPAT_NOTES=/ {print "COMPAT_NOTES=" note; seen_n=1; next}
      {print}
      END {if(!seen_p)print "AUTO_PROFILE=" p; if(!seen_pn)print "AUTO_PROFILE_NAME=" pn; if(!seen_ps)print "AUTO_STRATEGY_SIGNATURE=" ps; if(!seen_s)print "AUTO_STATUS=" s; if(!seen_k)print "AUTO_NETWORK_KEY=" k; if(!seen_i)print "AUTO_NETWORK_IFACE=" i; if(!seen_u)print "AUTO_UPDATED=" u; if(!seen_n)print "COMPAT_NOTES=" note}
    ' "$HEALTH_FILE" > "$tmp" && mv -f "$tmp" "$HEALTH_FILE"
  fi
  log_i "AUTO-профиль переключён без пересборки firewall/UID: profile=$profile name=$profile_name pid=$pid"
  return 0
}

if [ "$SERVICE_ACTION" = "reload-profile" ]; then
  boot_trace "fast AUTO profile reload"
  if reload_active_profile; then exit 0; fi
  log_w "Быстрый reload не удался; выполняется полный безопасный reload"
  SERVICE_ACTION=reload
fi

boot_trace "service lock acquired"
log_environment "$SERVICE_ACTION"
log_network_modules
write_start_state "STARTING" "$([ "$SERVICE_ACTION" = "reload" ] && echo "Перезапуск службы" || echo "Подготовка после загрузки Android")" 12
write_start_state "STARTING" "Чтение списков доменов и подсетей" 22
stop_pid "$NFQWS_PID_FILE" "nfqws2" nfqws2
stop_pid "$VPN_WATCHER_PID_FILE" "сетевой watcher" vpn-watch
stop_pid "$HEALTH_WATCHER_PID_FILE" "health watcher" health-watch
# httpd намеренно НЕ трогаем: он не участвует в перестройке правил, а его
# перезапуск здесь убивал сервер, обслуживающий запрос, который этот reload и
# запросил (см. ensure_httpd в конце файла).
stop_owned_nfqws
[ -x "$MODDIR/warp-tunnel.sh" ] && sh "$MODDIR/warp-tunnel.sh" stop >/dev/null 2>&1 || true
write_start_state "STARTING" "Очистка предыдущих netfilter-правил" 30
boot_trace "firewall cleanup start"
cleanup_iptables
boot_trace "firewall cleanup complete"
"$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true

write_start_state "STARTING" "Проверка netfilter и возможностей ядра" 38
CONNTRACK_ACCT=0
probe_firewall || { write_health; write_start_state "ERROR" "Netfilter/NFQUEUE недоступен" 100; exit 1; }
if [ "$STRATEGY_MODE" = "SMART" ] && [ "$CONNBYTES4" = "1" ] && [ "$CONNMARK4" = "1" ]; then
  ensure_conntrack_accounting || true
elif [ -r /proc/sys/net/netfilter/nf_conntrack_acct ] && [ "$(cat /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null)" = "1" ]; then
  CONNTRACK_ACCT=1
fi
tune_kernel_network || true

if [ "$STRATEGY_MODE" = "CUSTOM" ]; then
  STRATEGY_EFFECTIVE="CUSTOM"
  DESYNC_ARGS="$DESYNC_ARGS_CUSTOM"
else
  STRATEGY_MODE="SMART"
  if [ "$CONNTRACK_ACCT" = "1" ] && [ "$CONNBYTES4" = "1" ] && [ "$CONNMARK4" = "1" ]; then
    STRATEGY_EFFECTIVE="SMART_NATIVE"
    DESYNC_ARGS="$DESYNC_ARGS_SMART_NATIVE_GENERAL"
    COMPAT_STATUS="NATIVE"
    COMPAT_NOTES="SMART_NATIVE: circular получает ограниченный reply-feed"
  else
    STRATEGY_EFFECTIVE="SMART_ACTIVE"
    DESYNC_ARGS="$DESYNC_ARGS_SMART_COMPAT_GENERAL"
    AUTO_PROFILE="${AUTO_PROFILE_DEFAULT:-strategy_2}"
    AUTO_PROFILE_NAME="UNKNOWN"
    AUTO_STRATEGY_SIGNATURE="UNKNOWN"
    AUTO_STATUS="DEFAULT"
    AUTO_NETWORK_KEY="none"
    AUTO_NETWORK_IFACE="none"
    AUTO_UPDATED="0"
    if [ -x "$MODDIR/auto-select.sh" ]; then
      AUTO_PROFILE=$(sh "$MODDIR/auto-select.sh" current 2>/dev/null | tail -n1)
      [ -f "$AUTO_RESULT_FILE" ] && . "$AUTO_RESULT_FILE"
    fi
    if ! strategy_read "$AUTO_PROFILE"; then
      AUTO_PROFILE=$(strategy_first_valid)
      strategy_read "$AUTO_PROFILE" || AUTO_PROFILE_NAME="INVALID"
    fi
    if [ "$AUTO_PROFILE_NAME" = "INVALID" ]; then
      AUTO_PROFILE="${AUTO_PROFILE_DEFAULT:-strategy_2}"
      SMART_AUTO_ARGS=""
      health_warn "Каталог стратегий пуст или невалиден; используется встроенный SMART_COMPAT профиль"
    else
      AUTO_PROFILE_NAME=$STRATEGY_FILE_NAME
      AUTO_STRATEGY_SIGNATURE=$(strategy_catalog_signature)
      if [ "$STRATEGY_FILE_MODE" = DIRECT ]; then
        SMART_DIRECT=1
      else
        # Стратегия, прошедшая probe, обслуживает ВЕСЬ TLS/443 трафик, а не только
        # подхватывает то, что не попало под первый фильтр (в первую очередь HTTP/80).
        SMART_AUTO_ARGS=$STRATEGY_FILE_ARGS
      fi
    fi
    missing=""
    [ "$CONNTRACK_ACCT" = "1" ] || missing="${missing}${missing:+, }nf_conntrack_acct"
    [ "$CONNMARK4" = "1" ] || missing="${missing}${missing:+, }CONNMARK"
    [ "$CONNBYTES4" = "1" ] || missing="${missing}${missing:+, }xt_connbytes"
    compat_notice "SMART_ACTIVE: ядро без полного bounded reply-feed (${missing:-capability}); активный профиль $AUTO_PROFILE / $AUTO_PROFILE_NAME (${AUTO_STATUS:-DEFAULT})"
  fi
fi

# DIRECT — сеть прошла probe без обхода. Не поднимаем ни NFQUEUE-правила, ни
# nfqws2: нулевая нагрузка на CPU и батарею, пока сеть не сменится. Watcher-ы
# остаются живыми и перезапустят подбор при смене Wi-Fi/сотовой сети.
: "${SMART_DIRECT:=0}"
[ "${AUTO_ALLOW_DIRECT:-1}" = "1" ] || SMART_DIRECT=0
if [ "$SMART_DIRECT" = "1" ]; then
  AUTO_STATUS="DIRECT"
  COMPAT_STATUS="DIRECT"
  COMPAT_NOTES="DIRECT: сеть ${AUTO_NETWORK_IFACE:-?} не фильтруется, обход отключён"
  log_i "SMART_ACTIVE DIRECT: правила и nfqws2 не устанавливаются (профиль $AUTO_PROFILE / $AUTO_PROFILE_NAME)"
fi
log_i "SMART capabilities: acct=$CONNTRACK_ACCT connmark=$CONNMARK4 connbytes=$CONNBYTES4; requested=$STRATEGY_MODE engine=$STRATEGY_EFFECTIVE compat=$COMPAT_STATUS"
log_i "SMART active selection: profile=${AUTO_PROFILE:-native} status=${AUTO_STATUS:-native} network=${AUTO_NETWORK_KEY:-none} iface=${AUTO_NETWORK_IFACE:-none}"
log_i "Config: hostlist=$HOSTLIST_MODE strategy=$STRATEGY_MODE engine=$STRATEGY_EFFECTIVE QUIC_MODE=$QUIC_MODE FORCE_TCP=$FORCE_TCP HOTSPOT=$ENABLE_HOTSPOT VPN_HOTSPOT=${ENABLE_VPN_HOTSPOT:-0} VPN_FALLBACK=${VPN_FALLBACK_MODE:-ANTIDPI} QNUM=$QNUM TCP_PORTS=$PORTS_TCP NFQWS_DEBUG=$NFQWS_DEBUG"
cat > "$RUN_DIR/tether-runtime.conf.tmp.$$" <<EOF
STRATEGY_EFFECTIVE="$STRATEGY_EFFECTIVE"
NFQ6="$NFQ6"
CONNBYTES4="$CONNBYTES4"
CONNBYTES6="$CONNBYTES6"
CONNMARK4="$CONNMARK4"
CONNMARK6="$CONNMARK6"
QBYPASS4="$QBYPASS4"
QBYPASS6="$QBYPASS6"
EOF
mv -f "$RUN_DIR/tether-runtime.conf.tmp.$$" "$RUN_DIR/tether-runtime.conf" 2>/dev/null
chmod 0600 "$RUN_DIR/tether-runtime.conf" 2>/dev/null || true

write_start_state "STARTING" "Подготовка правил приложений" 50
write_start_state "STARTING" "Установка AntiDPI/NFQUEUE правил" 50
DIRECT_MODE_FILE="$RUN_DIR/direct.flag"
rm -f "$DIRECT_MODE_FILE" 2>/dev/null
if [ "$SMART_DIRECT" = "1" ]; then
  # Ни одной записи в netfilter и ни одного процесса nfqws2: на этой сети обход
  # не нужен. Флаг говорит health-watcher, что отсутствие nfqws2 — норма.
  : > "$DIRECT_MODE_FILE" 2>/dev/null
  chmod 0600 "$DIRECT_MODE_FILE" 2>/dev/null || true
  write_start_state "STARTING" "DIRECT: обход на этой сети не требуется" 90
  log_i "DIRECT: AntiDPI правила и nfqws2 не устанавливаются"
else
  write_start_state "STARTING" "Установка AntiDPI/NFQUEUE правил" 62
  ipt4 -t mangle -N ZAPRET2_MANGLE || health_error "Не удалось создать IPv4 mangle chain"
  ipt4 -t filter -N ZAPRET2_FILTER || health_error "Не удалось создать IPv4 filter chain"
  [ "$NFQ6" = "1" ] && ipt6 -t mangle -N ZAPRET2_MANGLE || true
  [ -n "$IP6T" ] && ipt6 -t filter -N ZAPRET2_FILTER || true

  # Трафик, уже ушедший в интерфейсы туннелей (AWG99 / AWG98), повторно не обрабатываем AntiDPI.
  for tdev in "${WARP_DEV:-awg99}" "${GEO_DEV:-awg98}"; do
    ipt4 -t mangle -A ZAPRET2_MANGLE -o "$tdev" -j RETURN 2>/dev/null || true
    ipt4 -t filter -A ZAPRET2_FILTER -o "$tdev" -j RETURN 2>/dev/null || true
    [ "$NFQ6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -o "$tdev" -j RETURN 2>/dev/null || true
    [ -n "$IP6T" ] && ipt6 -t filter -A ZAPRET2_FILTER -o "$tdev" -j RETURN 2>/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # Одно правило на весь исходящий трафик указанных портов.
  #
  # Отбор «что именно трогать» целиком внутри nfqws2: домены через --hostlist,
  # подсети через --ipset. Netfilter больше не различает приложения, поэтому
  # здесь нет ни owner match, ни режимов INCLUDE/EXCLUDE/GLOBAL.
  # ---------------------------------------------------------------------------
  if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ]; then
    ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || health_error "SMART_NATIVE IPv4 CONNMARK rule failed"
  fi
  # Flow Offloading: перехватываем только первые 1..8 пакетов сессии для рукопожатия / ClientHello
  if [ "$CONNBYTES4" = "1" ]; then
    ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m connbytes --connbytes 1:8 --connbytes-dir original --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 NFQUEUE (connbytes)"
    log_i "Flow Offloading IPv4: NFQUEUE ограничен 1..8 пакетами сессии (аппаратная разгрузка потоковых данных)"
  else
    ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 NFQUEUE"
  fi
  if [ "$NFQ6" = "1" ]; then
    [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
    if [ "$CONNBYTES6" = "1" ]; then
      ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m connbytes --connbytes 1:8 --connbytes-dir original --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    else
      ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    fi
  fi
  ipt4 -t mangle -A OUTPUT -j ZAPRET2_MANGLE || health_error "Не удалось подключить ZAPRET2_MANGLE к OUTPUT"
  [ "$NFQ6" = "1" ] && ipt6 -t mangle -A OUTPUT -j ZAPRET2_MANGLE || true

  # TCP MSS Clamping: автоматическое согласование размера MSS под реальный MTU туннелей/сотовой сети
  ipt4_quiet -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  [ "$NFQ6" = "1" ] && ipt6_quiet -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

  if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ]; then
    ipt4 -t mangle -N ZAPRET2_MANGLE_IN || health_error "Не удалось создать IPv4 INPUT reply chain"
    ipt4 -t mangle -A ZAPRET2_MANGLE_IN -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "SMART_NATIVE IPv4 reply NFQUEUE rule failed"
    ipt4 -t mangle -I INPUT 1 -j ZAPRET2_MANGLE_IN || health_error "Не удалось подключить SMART_NATIVE IPv4 INPUT reply chain"
    if [ "$NFQ6" = "1" ] && [ "$CONNBYTES6" = "1" ] && [ "$CONNMARK6" = "1" ]; then
      ipt6 -t mangle -N ZAPRET2_MANGLE_IN || health_warn "IPv6 SMART_NATIVE reply chain недоступна"
      ipt6 -t mangle -A ZAPRET2_MANGLE_IN -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || health_warn "IPv6 SMART_NATIVE reply NFQUEUE rule недоступно"
      ipt6 -t mangle -I INPUT 1 -j ZAPRET2_MANGLE_IN || health_warn "IPv6 SMART_NATIVE INPUT hook недоступен"
    fi
    log_i "SMART_NATIVE conntrack feed: server replies 1..$AUTO_REPLY_PACKETS queued on INPUT/FORWARD"
  fi

  # Блокировка QUIC. Приложения больше не различаются, поэтому режим сводится к
  # «блокировать или нет»: QUIC_MODE=OFF выключает, любое другое значение
  # блокирует UDP/443 целиком. Домены и подсети, которые трогать нельзя, и так
  # выведены из-под обхода на уровне nfqws2 (--hostlist-exclude / --ipset-exclude),
  # но QUIC они не спасают: имя хоста в UDP/443 модулю недоступно.
  if [ "$FORCE_TCP" = "1" ] && [ "${QUIC_MODE:-ON}" != "OFF" ]; then
    ipt4 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || health_error "Не удалось блокировать QUIC IPv4"
    [ -n "$IP6T" ] && ipt6 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || true
    ipt4 -t filter -A OUTPUT -j ZAPRET2_FILTER || health_error "Не удалось подключить ZAPRET2_FILTER к OUTPUT"
    [ -n "$IP6T" ] && ipt6 -t filter -A OUTPUT -j ZAPRET2_FILTER || true
    log_i "QUIC: UDP/443 блокируется для всей системы (QUIC_MODE=${QUIC_MODE:-ON})"
  fi
fi

# Глобальная блокировка внешнего IPv6 трафика (чистый IPv4-стек)
if [ -n "$IP6T" ]; then
  ipt6_quiet -t filter -N ZAPRET2_IPV6_BLOCK 2>/dev/null || true
  ipt6_quiet -t filter -F ZAPRET2_IPV6_BLOCK 2>/dev/null || true
  ipt6_quiet -t filter -A ZAPRET2_IPV6_BLOCK -o lo -j RETURN 2>/dev/null || true
  ipt6_quiet -t filter -A ZAPRET2_IPV6_BLOCK -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || \
    ipt6_quiet -t filter -A ZAPRET2_IPV6_BLOCK -j DROP 2>/dev/null || true
  delete_jump_bounded 6 filter OUTPUT ZAPRET2_IPV6_BLOCK
  ipt6_quiet -t filter -I OUTPUT 1 -j ZAPRET2_IPV6_BLOCK 2>/dev/null || true
  delete_jump_bounded 6 filter FORWARD ZAPRET2_IPV6_BLOCK
  ipt6_quiet -t filter -I FORWARD 1 -j ZAPRET2_IPV6_BLOCK 2>/dev/null || true
  log_i "IPv6: внешний трафик заблокирован (форсирование чистого IPv4 стека без задержек Happy Eyeballs)"
fi

# Настройка раздачи и VPN-маршрутизации (работает ВСЕГДА, включая режим DIRECT!)
write_start_state "STARTING" "Настройка раздачи и VPN-маршрутизации" 74
if [ "$ENABLE_HOTSPOT" = "1" ]; then
  log_i "Tether scope: dynamic role detection (Android tether state/config + network fallback)"

  ipt4 -t mangle -N ZAPRET2_MANGLE_FORWARD || health_error "Не удалось создать IPv4 Hotspot NFQUEUE chain"
  [ "$NFQ6" = "1" ] && ipt6 -t mangle -N ZAPRET2_MANGLE_FORWARD || true
  ipt4 -t mangle -I FORWARD 1 -j ZAPRET2_MANGLE_FORWARD || health_error "Не удалось подключить IPv4 Hotspot NFQUEUE chain"
  [ "$NFQ6" = "1" ] && ipt6 -t mangle -I FORWARD 1 -j ZAPRET2_MANGLE_FORWARD || true

  if [ "$DNS_FORWARD_HOTSPOT" = "1" ]; then
    ipt4 -t nat -N ZAPRET2_NAT_PREROUTING || health_error "Не удалось создать DNS DNAT chain"
    ipt4 -t nat -I PREROUTING 1 -j ZAPRET2_NAT_PREROUTING || health_error "Не удалось подключить DNS DNAT chain"
  fi

  if [ "$FORCE_TCP_HOTSPOT" = "1" ]; then
    ipt4 -t filter -N ZAPRET2_FILTER_FORWARD || health_error "Не удалось создать Hotspot QUIC chain"
    ipt4 -t filter -I FORWARD 1 -j ZAPRET2_FILTER_FORWARD || health_error "Не удалось подключить Hotspot QUIC IPv4 chain"
    if [ -n "$IP6T" ]; then
      ipt6 -t filter -N ZAPRET2_FILTER_FORWARD || true
      ipt6 -t filter -I FORWARD 1 -j ZAPRET2_FILTER_FORWARD || true
    fi
  fi

  if [ "$SMART_DIRECT" = "1" ]; then
    "$MODDIR/tether-sync.sh" cleanup >/dev/null 2>&1 || true
    log_i "DIRECT: tether AntiDPI/NFQUEUE rules отключены; VPN routing остаётся независимым"
  else
    "$MODDIR/tether-sync.sh" apply >/dev/null 2>&1 || health_error "Не удалось синхронизировать динамические tether AntiDPI правила"
  fi

  "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
  if [ "${ENABLE_VPN_HOTSPOT:-0}" = "1" ]; then
    vpn_apply_rc=0
    "$MODDIR/vpn-routing.sh" apply || vpn_apply_rc=$?
    case "$vpn_apply_rc" in
      0) : ;;
      3) health_warn "VPN/tether находится в переходном состоянии; watcher повторит настройку автоматически" ;;
      *) health_error "Не удалось применить VPN→tether routing (rc=$vpn_apply_rc)" ;;
    esac
  fi

  ACTIVE_TETHER_IFACES=$(cat "$RUN_DIR/tether-downstreams.state" 2>/dev/null)
  log_i "Tether active downstream: ${ACTIVE_TETHER_IFACES:-none}"
  [ "$FORCE_TCP_HOTSPOT" = "1" ] && log_i "QUIC для Hotspot/USB: UDP/443 блокируется на динамически определённых downstream"
fi

if [ "$SMART_DIRECT" != "1" ]; then
  EXCLUDE_ARGS=$(build_exclude_args)
  HOST_ARGS=$(build_hostlist_args)
  SPECIAL_ARGS=""
  # Общий профиль получает исключения в каждом своём подпрофиле: без этого
  # exclude_domains.list действовал только на первый из них.
  GENERAL_ARGS=$(inject_exclude_args "$EXCLUDE_ARGS" $DESYNC_ARGS)
  # HOSTLIST_MODE навешивается на ПЕРВЫЙ профиль общей стратегии — тот, что
  # работает с ClientHello и http-запросом, где имя хоста известно. Без этого
  # режимы LIST и AUTO были неотличимы от ALL: общий профиль ловил всё подряд,
  # и выбор доменов не значил ничего. Хвостовой подпрофиль общей стратегии
  # (--payload=all,empty, synack/ipfrag) остаётся без --hostlist сознательно:
  # он действует на этапе рукопожатия, когда имени хоста ещё не существует,
  # и доменные ворота просто выключили бы его.
  GENERAL_ARGS="$HOST_ARGS $GENERAL_ARGS"
  if [ "$STRATEGY_MODE" = "SMART" ] && [ -n "${SMART_AUTO_ARGS:-}" ]; then
    SPECIAL_ARGS="$HOST_ARGS $SMART_AUTO_ARGS --new"
    log_i "SMART profile: AUTO=$AUTO_PROFILE/$AUTO_PROFILE_NAME применён к доменам из списков; fallback profile=SMART_COMPAT_GENERAL (hostlist=$HOSTLIST_MODE)"
  else
    log_i "Per-network профиль недоступен ($STRATEGY_EFFECTIVE): общая стратегия работает по доменам (hostlist=$HOSTLIST_MODE)"
  fi
  # Профиль по подсетям из ipset.list. Идёт ПЕРВЫМ, как в nfqws-keenetic:
  # адрес назначения известен раньше имени хоста из ClientHello, поэтому
  # совпадение по подсети должно решаться до доменных профилей.
  IPSET_ARGS=$(build_ipset_profile_args "${SMART_AUTO_ARGS:-$DESYNC_ARGS}")
  [ -n "$IPSET_ARGS" ] && log_i "IPSET profile: подсетей=$(list_count "$IPSET_FILE") обрабатываются отдельным профилем"
  NFQWS_DEBUG_ARG=""
  [ "$NFQWS_DEBUG" = "1" ] && NFQWS_DEBUG_ARG="--debug=@$NFQWS_LOG"

  if [ "$HEALTH" = "ERROR" ]; then
    write_health
    write_start_state "ERROR" "Критическая ошибка установки правил" 100
    boot_trace "abort before nfqws due to critical rule failure"
    cleanup_iptables
    "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
    exit 1
  fi
  write_start_state "STARTING" "Запуск nfqws2" 86
  if ! cd "$BIN_DIR"; then
    health_error "BIN_DIR недоступен: $BIN_DIR"; write_health; write_start_state "ERROR" "Не удалось открыть каталог nfqws2" 100
    cleanup_iptables; "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true; exit 1
  fi
  if [ ! -x ./nfqws2 ]; then
    health_error "nfqws2 отсутствует/не исполняемый: $BIN_DIR/nfqws2"; write_health; write_start_state "ERROR" "nfqws2 отсутствует или не исполняемый" 100
    cleanup_iptables; "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true; exit 1
  fi
  log_i "nfqws2 command: qnum=$QNUM debug=$NFQWS_DEBUG smart_engine=$STRATEGY_EFFECTIVE service_profile=$([ -n "$SPECIAL_ARGS" ] && echo yes || echo no) hostlist=$HOSTLIST_MODE user-domains=$(list_count "$USER_DOMAINS_FILE") exclude-hostlist=$(list_count "$EXCLUDE_DOMAINS_FILE") ipset=$(list_count "$IPSET_FILE")"
  # $HOST_ARGS уже входит либо в $SPECIAL_ARGS, либо в $GENERAL_ARGS — второй
  # раз не подставляем, иначе --hostlist-exclude дублируется в командной строке.
  spawn_nfqws $(nfqws_base_args) $NFQWS_DEBUG_ARG $IPSET_ARGS $SPECIAL_ARGS $GENERAL_ARGS
  nfqws_spawn_rc=$?
  [ "$NFQWS_SPAWN_METHOD" = "nohup-fallback" ] && health_warn "setsid недоступен: nfqws2 запущен через nohup compatibility fallback"
  boot_trace "nfqws2 launch method=${NFQWS_SPAWN_METHOD:-none} pid=${NFQWS_SPAWNED_PID:-none}"
  nfqws_pid="$NFQWS_SPAWNED_PID"
  write_start_state "STARTING" "Проверка процесса и NFQUEUE" 94
  if [ "$nfqws_spawn_rc" -ne 0 ] || ! pid_is_owned "$nfqws_pid" nfqws2; then
    health_error "nfqws2 не запустился или завершился сразу; см. внутренний лог $LOG_FILE"
    rm -f "$NFQWS_PID_FILE"
    write_health
    write_start_state "ERROR" "nfqws2 не запустился или завершился сразу" 100
    boot_trace "nfqws2 launch failed method=${NFQWS_SPAWN_METHOD:-none}"
    cleanup_iptables
    "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
    exit 1
  fi
  printf '%s\n' "$nfqws_pid" > "$NFQWS_PID_FILE"
  chmod 0600 "$NFQWS_PID_FILE" 2>/dev/null || true
  boot_trace "nfqws2 alive pid=$nfqws_pid $(proc_session_fields "$nfqws_pid")"

  verify_rules_snapshot
  if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    NFQ_STATE=$(cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null)
    log_i "NFQUEUE state:\n$NFQ_STATE"
    echo "$NFQ_STATE" | awk -v q="$QNUM" '$1==q {found=1} END {exit !found}' || health_error "nfqws2 запущен, но очередь NFQUEUE $QNUM не видна в ядре"
  else
    health_warn "/proc/net/netfilter/nfnetlink_queue недоступен: привязку очереди нельзя проверить"
  fi
  ipt4_quiet -t mangle -C OUTPUT -j ZAPRET2_MANGLE || health_error "Проверка hook: ZAPRET2_MANGLE не подключена к IPv4 OUTPUT"
  [ "$FORCE_TCP" != "1" ] || ipt4_quiet -t filter -C OUTPUT -j ZAPRET2_FILTER || health_error "Проверка hook: ZAPRET2_FILTER не подключена к IPv4 OUTPUT"
  [ "$ENABLE_HOTSPOT" != "1" ] || ipt4_quiet -t mangle -C FORWARD -j ZAPRET2_MANGLE_FORWARD || health_error "Проверка hook: Hotspot NFQUEUE не подключён к IPv4 FORWARD"
  [ "$STRATEGY_EFFECTIVE" != "SMART_NATIVE" ] || ipt4_quiet -t mangle -C INPUT -j ZAPRET2_MANGLE_IN || health_error "Проверка hook: SMART_NATIVE reply feed не подключён к IPv4 INPUT"
fi
write_health

# Сторожа поднимает ensure_watchers из ловушки EXIT — в том числе на аварийных
# путях выше. Здесь вызываем явно, чтобы на успешном старте они были живы ещё
# до записи READY, а не в момент завершения процесса.
ensure_watchers
if [ "$HEALTH" = "ERROR" ]; then
  write_health
  write_start_state "ERROR" "Критическая ошибка правил; см. диагностику" 100
  boot_trace "service ERROR after validation"
  stop_pid "$NFQWS_PID_FILE" "nfqws2" nfqws2
  cleanup_iptables
  "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
  exit 1
fi
write_config_signature
write_start_state "READY" "Служба работает" 100
boot_trace "service READY nfqws2_pid=$nfqws_pid health=$HEALTH"
log_i "Служба запущена: nfqws2 PID=$nfqws_pid health=$HEALTH"

# Запуск AmneziaWG v3 туннелей (WARP AWG99 и Geo AWG98)
if { [ "${ENABLE_WARP:-0}" = "1" ] || [ "${ENABLE_GEO_WARP:-1}" = "1" ]; } && [ -f "$MODDIR/warp-tunnel.sh" ]; then
  log_i "Запуск туннелей AmneziaWG v3 (WARP / GEO)..."
  sh "$MODDIR/warp-tunnel.sh" start >> "$LOG_FILE" 2>&1 &
fi

# ------------------------------------------------------------------------------
# HTTP-мост WebUI.
#
# KernelSU / APatch / MMRL вызывают webroot/api.sh напрямую через argv — им
# TCP-сокет не нужен вообще. HTTP-сервер нужен только для Magisk без WebUI-моста
# и для доступа из браузера, поэтому он вынесен в явную опцию: слушающий
# 127.0.0.1 сокет доступен ЛЮБОМУ приложению на устройстве без единого
# разрешения, и включать его вслепую неправильно.
#
# Сервер идемпотентен: если он уже жив с прошлого reload, мы его не трогаем.
# Раньше reload безусловно убивал httpd в самом начале — в том числе тот, что
# обслуживал вызвавший этот reload запрос, — а затем поднимал заново, из-за чего
# порт мог смениться с 8080 на 8088 и WebUI терял бэкенд.
# ------------------------------------------------------------------------------
ensure_httpd() {
  local b hpid cmd comm port
  [ -d "$MODDIR/webroot" ] || return 0
  if [ "${ENABLE_HTTP_API:-0}" != "1" ]; then
    stop_pid "$RUN_DIR/httpd.pid" "webui-httpd" "httpd"
    rm -f "$RUN_DIR/webui.port" 2>/dev/null
    log_d "HTTP API выключен (ENABLE_HTTP_API=0); используется нативный мост менеджера root"
    return 0
  fi
  hpid=$(cat "$RUN_DIR/httpd.pid" 2>/dev/null)
  if pid_is_owned "$hpid" httpd; then
    log_d "WebUI HTTPD уже работает (PID $hpid), перезапуск не требуется"
    return 0
  fi
  rm -f "$RUN_DIR/httpd.pid" 2>/dev/null
  BB_BIN=""
  for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox /system/bin/busybox $(command -v busybox 2>/dev/null); do
    if [ -x "$b" ] && "$b" httpd --help >/dev/null 2>&1; then BB_BIN="$b"; break; fi
  done
  [ -n "$BB_BIN" ] || { log_w "busybox httpd не найден: HTTP API недоступен"; return 1; }
  chmod 0755 "$MODDIR/webroot/api.sh" 2>/dev/null || true
  chmod 0644 "$MODDIR/webroot/index.html" "$MODDIR/webroot/httpd.conf" 2>/dev/null || true
  # Здесь генерировался run/webui.token с комментарием «второй барьер поверх
  # проверки заголовка WebUI». Барьером он не был: его никто никогда не
  # проверял — ни api.sh, ни страница. Реализовать проверку тоже нечем: сервер
  # отдаёт index.html без авторизации, поэтому встроенный в страницу токен
  # прочитало бы любое приложение тем же запросом. Настоящая защита — это
  # ENABLE_HTTP_API="0" по умолчанию, о чём написано в api.sh.
  rm -f "$RUN_DIR/webui.token" 2>/dev/null
  port=""
  if "$BB_BIN" httpd -p 127.0.0.1:8080 -h "$MODDIR/webroot" -c "$MODDIR/webroot/httpd.conf" 2>/dev/null; then
    port=8080
  elif "$BB_BIN" httpd -p 127.0.0.1:8088 -h "$MODDIR/webroot" -c "$MODDIR/webroot/httpd.conf" 2>/dev/null; then
    port=8088
  fi
  if [ -z "$port" ]; then log_w "Не удалось запустить WebUI HTTPD сервер"; return 1; fi
  # Сначала дешёвое чтение comm, и только для похожих процессов — cmdline.
  # Прежний вариант звал pid_cmdline для КАЖДОГО процесса в системе, а тот
  # форкает фоновую подоболочку с ожиданием: на обычном Android это 700-900
  # форков на один reload.
  hpid=""
  for proc in /proc/[0-9]*; do
    comm=$(cat "$proc/comm" 2>/dev/null)
    case "$comm" in *httpd*|*busybox*) ;; *) continue ;; esac
    cmd=$(pid_cmdline "${proc##*/}")
    printf '%s' "$cmd" | grep -Fq "$MODDIR/webroot" || continue
    hpid=${proc##*/}; break
  done
  [ -n "$hpid" ] && { echo "$hpid" > "$RUN_DIR/httpd.pid"; chmod 0600 "$RUN_DIR/httpd.pid" 2>/dev/null || true; }
  printf '%s\n' "$port" > "$RUN_DIR/webui.port" 2>/dev/null
  chmod 0644 "$RUN_DIR/webui.port" 2>/dev/null || true
  log_i "WebUI HTTPD слушает 127.0.0.1:$port (PID ${hpid:-unknown})"
}
ensure_httpd

# Активный подбор не блокирует загрузку. Сначала всегда работает кэшированный
# профиль, затем фоновый probe меняет его только после полного успешного набора.
if [ "$STRATEGY_EFFECTIVE" = "SMART_ACTIVE" ] && [ "${AUTO_SELECT_ENABLED:-1}" = 1 ] && [ -x "$MODDIR/auto-select.sh" ]; then
  sh "$MODDIR/auto-select.sh" schedule >/dev/null 2>&1 || true
fi

# Автоматический экспорт логов в общее хранилище отключён по умолчанию:
# /sdcard читает любое приложение с доступом к хранилищу, а в логах есть SSID,
# оператор, полный список пакетов и UID. Кнопка «Экспорт логов» в WebUI и
# `zapret2-control export-logs` работают всегда, независимо от этого флага.
if [ "${LOG_EXPORT_ON_BOOT:-0}" = "1" ] && [ -x "$MODDIR/log-export.sh" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/log-export.sh" once >/dev/null 2>&1 &
  elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
    busybox setsid sh "$MODDIR/log-export.sh" once >/dev/null 2>&1 &
  else
    sh "$MODDIR/log-export.sh" once >/dev/null 2>&1 &
  fi
fi
