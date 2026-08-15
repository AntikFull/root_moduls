#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
SERVICE_ACTION="$1"
CONF_FILE="$MODDIR/zapret2.conf"
LISTS_DIR="$MODDIR/lists"
[ -d "$LISTS_DIR" ] || LISTS_DIR="$MODDIR"
APPS_LIST="$LISTS_DIR/apps.list"
APPS_USER_LIST="$LISTS_DIR/apps.user.list"
AUTO_APPS_LIST="$LISTS_DIR/auto_apps.list"
EXCLUDE_LIST="$LISTS_DIR/exclude.list"
SMART_YOUTUBE_FILE="$LISTS_DIR/smart_youtube.list"
AUTO_DOMAINS_FILE="$LISTS_DIR/auto_domains.list" # legacy/user compatibility; SMART uses built-in service profiles
EXCLUDE_DOMAINS_FILE="$LISTS_DIR/exclude_domains.list"
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
PACKAGE_UID_CACHE="$RUN_DIR/package_uids.cache"
PACKAGE_SOURCE_FILE="$RUN_DIR/package_source"
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
      "$PACKAGE_UID_CACHE" "$PACKAGE_SOURCE_FILE" 2>/dev/null
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
write_health() {
  local tmp="$HEALTH_FILE.tmp.$$"
  {
    echo "HEALTH=$HEALTH"
    printf 'WARNINGS=%s\n' "$HEALTH_WARNINGS"
    printf 'PACKAGE_SOURCE=%s\n' "$(cat "$PACKAGE_SOURCE_FILE" 2>/dev/null)"
    printf 'STRATEGY_EFFECTIVE=%s\n' "${STRATEGY_EFFECTIVE:-${STRATEGY_MODE:-UNKNOWN}}"
    printf 'SMART_ENGINE=%s\n' "${STRATEGY_EFFECTIVE:-UNKNOWN}"
    printf 'AUTO_APPS_ENABLED=%s\n' "${AUTO_APPS_ENABLED:-1}"
    printf 'AUTO_APP_UIDS=%s\n' "${AUTO_APP_UID_COUNT:-0}"
    printf 'MANUAL_APP_UIDS=%s\n' "${MANUAL_APP_UID_COUNT:-0}"
    printf 'SMART_YOUTUBE_DOMAINS=%s\n' "$(grep -cvE '^[[:space:]]*(#|$)' "$SMART_YOUTUBE_FILE" 2>/dev/null || echo 0)"
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
    printf 'OWNER4=%s\n' "${OWNER4:-0}"
    printf 'CONNBYTES6=%s\n' "${CONNBYTES6:-0}"
    printf 'CONNMARK6=%s\n' "${CONNMARK6:-0}"
    printf 'NFQUEUE6=%s\n' "${NFQ6:-0}"
    printf 'OWNER6=%s\n' "${OWNER6:-0}"
  } > "$tmp" && mv -f "$tmp" "$HEALTH_FILE"
  chmod 0600 "$HEALTH_FILE" 2>/dev/null || true
}

pid_cmdline() { tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
pid_is_owned() {
  local pid="$1" kind="$2" cmd cwd comm
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  case "$kind" in
    nfqws2)
      comm=$(cat "/proc/$pid/comm" 2>/dev/null)
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
      [ "$comm" = "nfqws2" ] && [ "$cwd" = "$BIN_DIR" ]
      ;;
    config-watch) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/on_change.sh" ;;
    vpn-watch) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/vpn-watch.sh" ;;
    health-watch) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/service-watch.sh" ;;
    service) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/service.sh" ;;
    *) return 1 ;;
  esac
}

find_owned_nfqws_pid() {
  local proc pid best=0 comm cwd
  for proc in /proc/[0-9]*; do
    comm=$(cat "$proc/comm" 2>/dev/null)
    [ "$comm" = "nfqws2" ] || continue
    cwd=$(readlink "$proc/cwd" 2>/dev/null)
    [ "$cwd" = "$BIN_DIR" ] || continue
    pid=${proc##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
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

stop_owned_nfqws() {
  local proc pid cwd n
  for proc in /proc/[0-9]*; do
    [ "$(cat "$proc/comm" 2>/dev/null)" = "nfqws2" ] || continue
    cwd=$(readlink "$proc/cwd" 2>/dev/null)
    [ "$cwd" = "$BIN_DIR" ] || continue
    pid=${proc##*/}
    kill -TERM "$pid" 2>/dev/null
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    log_i "Остановлен осиротевший nfqws2 (PID $pid)"
  done
}

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
    delete_jump_bounded 4 mangle OUTPUT ZAPRET2_MANGLE
    delete_jump_bounded 4 mangle INPUT ZAPRET2_MANGLE_IN
    delete_jump_bounded 4 mangle FORWARD ZAPRET2_MANGLE_FORWARD
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
  }
}

normalize_pm_output() {
  local raw="$1" user="$2" line body pkg uid
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in package:*) ;; *) continue ;; esac
    body=${line#package:}
    case "$body" in *" uid:"*) ;; *) continue ;; esac
    uid=${body##* uid:}; uid=${uid%%[!0-9]*}
    pkg=${body%% uid:*}; pkg=${pkg##*=}; pkg=${pkg%%[[:space:]]*}
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$pkg" ] || continue
    printf '%s %s %s\n' "$pkg" "$uid" "$user" >> "$PACKAGE_UID_CACHE.tmp"
  done < "$raw"
}

list_users() {
  local users
  users=$(cmd user list 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -nu)
  if [ -z "$users" ] && [ -d /data/system/users ]; then
    users=$(find /data/system/users -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#.*/##' | grep -E '^[0-9]+$' | sort -nu)
  fi
  [ -n "$users" ] && printf '%s\n' "$users" || echo 0
}

append_packages_list_all_users() {
  local dest="$1" user pkg uid usr
  [ -r /data/system/packages.list ] || return 1
  for user in $(list_users); do
    if [ "$user" = "0" ]; then
      awk -v u="$user" 'NF>=2 && $2 ~ /^[0-9]+$/ {appid=$2%100000; uid=u*100000+appid; print $1,uid,u}' /data/system/packages.list >> "$dest" 2>/dev/null
      continue
    fi
    # packages.list — общесистемный файл; он не говорит, в каких профилях пакет
    # реально установлен. Без этой проверки во вторичном/клон-профиле (ColorOS
    # MultiApp = user 999, рабочий профиль = 10 и т.п.) генерировались правила
    # для несуществующих UID вида 99910447. Каталог данных профиля есть только
    # у реально установленных там пакетов и читается root на любой прошивке.
    [ -d "/data/user/$user" ] || continue
    awk -v u="$user" 'NF>=2 && $2 ~ /^[0-9]+$/ {appid=$2%100000; uid=u*100000+appid; print $1,uid,u}' /data/system/packages.list 2>/dev/null | \
    while read -r pkg uid usr; do
      [ -d "/data/user/$usr/$pkg" ] && printf '%s %s %s\n' "$pkg" "$uid" "$usr"
    done >> "$dest" 2>/dev/null
  done
}

build_package_cache_once() {
  local tmp_raw="$RUN_DIR/pm_raw.$$" user pm_ok=0 cmd_ok=0 fs_ok=0 count=0 source=""
  : > "$PACKAGE_UID_CACHE.tmp"
  for user in $(list_users); do
    : > "$tmp_raw"
    if pm list packages -U --user "$user" > "$tmp_raw" 2>&1 && grep -q '^package:' "$tmp_raw"; then
      normalize_pm_output "$tmp_raw" "$user"; pm_ok=1
    fi
    : > "$tmp_raw"
    if cmd package list packages -U --user "$user" > "$tmp_raw" 2>&1 && grep -q '^package:' "$tmp_raw"; then
      normalize_pm_output "$tmp_raw" "$user"; cmd_ok=1
    fi
  done
  rm -f "$tmp_raw"

  if [ -r /data/system/packages.list ]; then
    append_packages_list_all_users "$PACKAGE_UID_CACHE.tmp" && fs_ok=1
  fi

  if [ -s "$PACKAGE_UID_CACHE.tmp" ]; then
    sort -u "$PACKAGE_UID_CACHE.tmp" > "$PACKAGE_UID_CACHE"
    rm -f "$PACKAGE_UID_CACHE.tmp"
    count=$(wc -l < "$PACKAGE_UID_CACHE" 2>/dev/null | tr -d ' ')
    [ "$pm_ok" = 1 ] && source="pm"
    [ "$cmd_ok" = 1 ] && source="${source}${source:+}+cmd"
    [ "$fs_ok" = 1 ] && source="${source}${source:+}+packages.list"
    [ -n "$source" ] || source="unknown"
    echo "$source" > "$PACKAGE_SOURCE_FILE"
    log_i "Package UID cache: sources=$source, UID-записей=$count"
    return 0
  fi
  rm -f "$PACKAGE_UID_CACHE.tmp"
  return 1
}

seed_package_cache_fast() {
  if [ -r /data/system/packages.list ]; then
    : > "$PACKAGE_UID_CACHE.fast"
    append_packages_list_all_users "$PACKAGE_UID_CACHE.fast"
    sort -u "$PACKAGE_UID_CACHE.fast" > "$PACKAGE_UID_CACHE.fast.sorted" 2>/dev/null || true
    if [ -s "$PACKAGE_UID_CACHE.fast.sorted" ]; then
      mv -f "$PACKAGE_UID_CACHE.fast.sorted" "$PACKAGE_UID_CACHE"
      rm -f "$PACKAGE_UID_CACHE.fast" 2>/dev/null
      echo "packages.list-fast" > "$PACKAGE_SOURCE_FILE"
      log_i "Package UID cache: быстрый boot source=packages.list, UID-записей=$(wc -l < "$PACKAGE_UID_CACHE" 2>/dev/null | tr -d ' ')"
      return 0
    fi
    rm -f "$PACKAGE_UID_CACHE.fast" "$PACKAGE_UID_CACHE.fast.sorted" 2>/dev/null
  fi
  return 1
}

prepare_package_cache() {
  local elapsed=0 wait_max="${PACKAGE_WAIT_SECONDS:-60}"
  seed_package_cache_fast && return 0
  case "$wait_max" in ''|*[!0-9]*) wait_max=60 ;; esac
  while [ "$elapsed" -le "$wait_max" ]; do
    build_package_cache_once && return 0
    [ "$elapsed" -ge "$wait_max" ] && break
    log_w "PackageManager/пакетная база ещ не дают UID; повтор через 2с ($elapsed/$wait_max)"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  if [ -s "$PACKAGE_UID_CACHE" ]; then
    echo "stale-cache" > "$PACKAGE_SOURCE_FILE"
    health_warn "Источники UID недоступны; используется предыдущий UID-кэш"
    return 0
  fi
  echo "none" > "$PACKAGE_SOURCE_FILE"
  health_warn "Не удалось получить UID приложений ни одним способом"
  return 1
}

resolve_pkg_direct() {
  local pkg="$1" user raw="$RUN_DIR/pkg_direct.$$" before after
  [ -n "$pkg" ] || return 1
  before=$(wc -l < "$PACKAGE_UID_CACHE" 2>/dev/null | tr -d ' ')
  case "$before" in ''|*[!0-9]*) before=0 ;; esac
  : > "$PACKAGE_UID_CACHE.tmp"
  for user in $(list_users); do
    : > "$raw"
    if pm list packages -U --user "$user" "$pkg" > "$raw" 2>/dev/null && grep -q '^package:' "$raw"; then
      normalize_pm_output "$raw" "$user"
    fi
    : > "$raw"
    if cmd package list packages -U --user "$user" "$pkg" > "$raw" 2>/dev/null && grep -q '^package:' "$raw"; then
      normalize_pm_output "$raw" "$user"
    fi
  done
  rm -f "$raw"
  if [ -s "$PACKAGE_UID_CACHE.tmp" ]; then
    cat "$PACKAGE_UID_CACHE.tmp" >> "$PACKAGE_UID_CACHE"
    sort -u "$PACKAGE_UID_CACHE" > "$PACKAGE_UID_CACHE.sorted" 2>/dev/null && mv -f "$PACKAGE_UID_CACHE.sorted" "$PACKAGE_UID_CACHE"
    rm -f "$PACKAGE_UID_CACHE.tmp" "$PACKAGE_UID_CACHE.sorted"
  fi
  after=$(wc -l < "$PACKAGE_UID_CACHE" 2>/dev/null | tr -d ' ')
  case "$after" in ''|*[!0-9]*) after=0 ;; esac
  [ "$after" -gt "$before" ]
}

pkg_is_excluded() {
  local pkg="$1"
  [ -f "$EXCLUDE_LIST" ] && grep -qxF "$pkg" "$EXCLUDE_LIST" 2>/dev/null
}

get_app_uids() {
  local target_list="$1" honor_exclude="${2:-0}" app uid uids="" found missing=0 matched="$RUN_DIR/uids-matched.$$"
  [ -f "$target_list" ] || { echo ""; return 0; }
  if [ "${PACKAGE_DIRECT_LOOKUP:-0}" != "1" ]; then
    awk -v list="$target_list" -v exclude="$EXCLUDE_LIST" -v honor="$honor_exclude" '
      BEGIN {
        if (honor == 1) while ((getline line < exclude) > 0) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line != "" && line !~ /^#/) excluded[line]=1
        }
        close(exclude)
        while ((getline line < list) > 0) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line != "" && line !~ /^#/ && !(honor == 1 && line in excluded)) wanted[line]=1
        }
        close(list)
      }
      ($1 in wanted) && $2 ~ /^[0-9]+$/ {print $1, $2; seen[$1]=1}
      END {for (pkg in wanted) if (!(pkg in seen)) missing++}
    ' "$PACKAGE_UID_CACHE" > "$matched" 2>/dev/null
    uids=$(awk '$2 ~ /^[0-9]+$/ {print $2}' "$matched" 2>/dev/null | sort -nu | tr '\n' ' ')
    missing=$(awk -v list="$target_list" -v matched="$matched" -v exclude="$EXCLUDE_LIST" -v honor="$honor_exclude" '
      BEGIN {
        if (honor == 1) while ((getline line < exclude) > 0) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); if(line!="" && line !~ /^#/) x[line]=1}
        while ((getline line < matched) > 0) {split(line,a," "); ok[a[1]]=1}
        while ((getline line < list) > 0) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); if(line!="" && line !~ /^#/ && !(honor==1 && line in x) && !(line in ok)) n++}
        print n+0
      }
    ' /dev/null 2>/dev/null)
    rm -f "$matched" 2>/dev/null
    [ "$missing" -gt 0 ] 2>/dev/null && log_i "UID resolver: отсутствующих записей в $(basename "$target_list")=$missing"
    echo "$uids"
    return 0
  fi
  while IFS= read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$app" in \#*|'') continue ;; esac
    if [ "$honor_exclude" = "1" ] && pkg_is_excluded "$app"; then
      log_d "EXCLUDE имеет приоритет: $app пропущен"
      continue
    fi
    found=$(awk -v p="$app" '$1==p {print $2}' "$PACKAGE_UID_CACHE" 2>/dev/null | sort -nu)
    if [ -z "$found" ] && [ "${PACKAGE_DIRECT_LOOKUP:-0}" = "1" ]; then
      resolve_pkg_direct "$app" >/dev/null 2>&1 || true
      found=$(awk -v p="$app" '$1==p {print $2}' "$PACKAGE_UID_CACHE" 2>/dev/null | sort -nu)
      [ -n "$found" ] && log_i "UID resolver direct fallback: $app -> $(echo $found | tr '\n' ',')"
    fi
    if [ -n "$found" ]; then
      for uid in $found; do uids="$uids $uid"; log_d "UID: $app -> $uid"; done
    else
      missing=$((missing + 1))
      log_d "Пакет из списка не установлен/UID не найден: $app"
    fi
  done < "$target_list"
  [ "$missing" -gt 0 ] && log_i "UID resolver: отсутствующих записей в $(basename "$target_list")=$missing"
  echo "$uids"
}

probe_firewall() {
  local chain="ZAPRET2_PROBE_$$" out
  [ -n "$IPT" ] || { health_error "iptables не найден"; return 1; }
  log_i "Firewall IPv4: $IPT; $($IPT -V 2>&1)"
  if ! "$IPT" -w 5 -t mangle -N "$chain" >/dev/null 2>&1; then
    health_error "Не удалось создать тестовую IPv4 mangle-цепочку"
    return 1
  fi
  if "$IPT" -w 5 -t mangle -A "$chain" -m owner --uid-owner 0 -j RETURN >/dev/null 2>&1; then
    OWNER4=1
  else
    OWNER4=0; health_warn "IPv4 xt_owner/owner match недоступен"
  fi
  "$IPT" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
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

  OWNER6=0; NFQ6=0; CONNBYTES6=0; CONNMARK6=0; QBYPASS6=""
  if [ -n "$IP6T" ]; then
    log_i "Firewall IPv6: $IP6T; $($IP6T -V 2>&1)"
    if "$IP6T" -w 5 -t mangle -N "$chain" >/dev/null 2>&1; then
      "$IP6T" -w 5 -t mangle -A "$chain" -m owner --uid-owner 0 -j RETURN >/dev/null 2>&1 && OWNER6=1
      "$IP6T" -w 5 -t mangle -F "$chain" >/dev/null 2>&1
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
    [ "$OWNER6" = "1" ] || health_warn "IPv6 owner match недоступен — per-app IPv6 правила будут пропущены"
  else
    health_warn "ip6tables не найден — IPv6 правила недоступны"
  fi
  log_i "Firewall capabilities: IPv4 NFQUEUE=$NFQ4 owner=$OWNER4 connbytes=$CONNBYTES4 connmark=$CONNMARK4 qBypass=${QBYPASS4:-no}; IPv6 NFQUEUE=$NFQ6 owner=$OWNER6 connbytes=$CONNBYTES6 connmark=$CONNMARK6 qBypass=${QBYPASS6:-no}"
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

if [ "$SERVICE_ACTION" != "reload" ] && [ "$SERVICE_ACTION" != "boot" ] && [ "$SERVICE_ACTION" != "reload-apps" ] && [ "$SERVICE_ACTION" != "reload-profile" ]; then
  write_start_state "WAITING" "Ожидание sys.boot_completed" 5
  until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 2; done
  SERVICE_ACTION="boot"; write_start_state "STARTING" "Android загружен · подготовка службы" 10; sleep 1
fi
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${MODE:=INCLUDE}" "${STRATEGY_MODE:=SMART}" "${AUTO_APPS_ENABLED:=1}" "${FORCE_TCP:=1}" "${QUIC_MODE:=SELECTED}" "${PORTS_TCP:=80,443}" "${QNUM:=200}" "${ENABLE_HOTSPOT:=1}" "${DNS_FORWARD_HOTSPOT:=0}" "${DNS_FORWARD_SERVER:=1.1.1.1}"
: "${FORCE_TCP_HOTSPOT:=1}" "${VPN_FALLBACK_MODE:=ANTIDPI}" "${NFQWS_DEBUG:=0}" "${LOG_VERBOSE:=1}" "${PACKAGE_WAIT_SECONDS:=60}" "${PACKAGE_DIRECT_LOOKUP:=0}"
: "${TETHER_IFACES:=ap+ swlan+ softap+ ap_br_wlan+ ap_br_softap+ rndis+ usb+ ncm+ bnep+ bt-pan+ pan+ tether+ wlan1 wlan2 wlan3 wlan4 wifi1 wifi2 wifi3 wifi4}" "${VPN_WATCH_INTERVAL:=2}" "${VPN_RETRY_INTERVAL:=1}" "${VPN_ROLE_RECHECK:=30}" "${VPN_EVENT_DEBOUNCE:=2}" "${VPN_NETLINK_MONITOR:=1}"
: "${AUTO_REPLY_PACKETS:=12}" "${FLOW_CONNMARK:=0x10000000/0x10000000}"
case "$AUTO_APPS_ENABLED" in 0|1) ;; *) AUTO_APPS_ENABLED=1 ;; esac
case "$STRATEGY_MODE" in SIMPLE|AUTO|'') STRATEGY_MODE=SMART ;; SMART|CUSTOM) ;; *) STRATEGY_MODE=SMART ;; esac

if [ "$SERVICE_ACTION" = "reload-apps" ]; then
  boot_trace "fast app-only sync requested"
  exec sh "$MODDIR/app-sync.sh" apply
fi

acquire_lock() {
  local lock_attempt=0 lock_pid lock_started now lock_age n
  [ "$(cat "$SERVICE_LOCK/pid" 2>/dev/null)" = "$$" ] && return 0
  while ! mkdir "$SERVICE_LOCK" 2>/dev/null; do
    lock_pid=$(cat "$SERVICE_LOCK/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && return 0
    case "$lock_pid" in
      ''|0|*[!0-9]*) rm -rf "$SERVICE_LOCK" 2>/dev/null ;;
      *)
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
if ! acquire_lock; then
  boot_trace "service lock busy; another trigger owns startup"
  exit 0
fi
trap 'release_service_lock; exit 1' HUP INT TERM
trap release_service_lock EXIT

reload_active_profile() {
  local profile profile_name profile_signature youtube_args special host debug_arg launcher pid tmp
  [ -f "$AUTO_RESULT_FILE" ] && . "$AUTO_RESULT_FILE"
  profile=${AUTO_PROFILE:-$AUTO_PROFILE_DEFAULT}
  strategy_read "$profile" || { log_w "Быстрый reload отклонён: невалидный AUTO_PROFILE=$profile"; return 1; }
  profile_name=$STRATEGY_FILE_NAME
  profile_signature=$(strategy_catalog_signature)
  # Переход в DIRECT или из него меняет сам состав netfilter-правил, а быстрый
  [ "$STRATEGY_FILE_MODE" = DIRECT ] && return 1
  [ -f "$RUN_DIR/direct.flag" ] && return 1
  youtube_args=$STRATEGY_FILE_ARGS
  host=""
  [ -s "$EXCLUDE_DOMAINS_FILE" ] && host="--hostlist-exclude=$EXCLUDE_DOMAINS_FILE"
  special="$host $youtube_args --new"
  debug_arg=""; [ "$NFQWS_DEBUG" = 1 ] && debug_arg="--debug=@$NFQWS_LOG"
  [ -x "$BIN_DIR/nfqws2" ] || return 1
  stop_pid "$NFQWS_PID_FILE" "nfqws2 для смены AUTO-профиля" nfqws2
  cd "$BIN_DIR" || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $debug_arg \
      --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
      $special $host $DESYNC_ARGS_SMART_COMPAT_GENERAL >> "$LOG_FILE" 2>&1 &
  elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
    busybox setsid "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $debug_arg \
      --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
      $special $host $DESYNC_ARGS_SMART_COMPAT_GENERAL >> "$LOG_FILE" 2>&1 &
  else
    nohup "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $debug_arg \
      --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
      $special $host $DESYNC_ARGS_SMART_COMPAT_GENERAL >> "$LOG_FILE" 2>&1 &
  fi
  launcher=$!; sleep 1; pid=$launcher
  pid_is_owned "$pid" nfqws2 || pid=$(find_owned_nfqws_pid)
  if ! pid_is_owned "$pid" nfqws2; then
    log_e "Быстрая смена AUTO-профиля не запустила nfqws2"
    return 1
  fi
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
write_start_state "STARTING" "Чтение списка приложений и UID" 22
package_cache_ok=1
prepare_package_cache || package_cache_ok=0
if [ "$package_cache_ok" != "1" ] && [ "${MODE:-INCLUDE}" != "GLOBAL" ]; then
  health_error "Для MODE=${MODE:-INCLUDE} нет рабочего UID-кэша; per-app правила нельзя применить безопасно"
fi

stop_pid "$NFQWS_PID_FILE" "nfqws2" nfqws2
stop_pid "$VPN_WATCHER_PID_FILE" "VPN/tether watcher" vpn-watch
stop_pid "$HEALTH_WATCHER_PID_FILE" "health watcher" health-watch
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

if [ "$STRATEGY_MODE" = "CUSTOM" ]; then
  STRATEGY_EFFECTIVE="CUSTOM"
  DESYNC_ARGS="$DESYNC_ARGS_CUSTOM"
else
  STRATEGY_MODE="SMART"
  if [ "$CONNTRACK_ACCT" = "1" ] && [ "$CONNBYTES4" = "1" ] && [ "$CONNMARK4" = "1" ]; then
    STRATEGY_EFFECTIVE="SMART_NATIVE"
    DESYNC_ARGS="$DESYNC_ARGS_SMART_NATIVE_GENERAL"
    SMART_YOUTUBE_ARGS="$DESYNC_ARGS_SMART_NATIVE_YOUTUBE"
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
      SMART_YOUTUBE_ARGS="$DESYNC_ARGS_SMART_COMPAT_YOUTUBE"
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
        SMART_YOUTUBE_ARGS=""
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
log_i "Config: MODE=$MODE auto_apps=$AUTO_APPS_ENABLED strategy=$STRATEGY_MODE engine=$STRATEGY_EFFECTIVE QUIC_MODE=$QUIC_MODE FORCE_TCP=$FORCE_TCP HOTSPOT=$ENABLE_HOTSPOT VPN_HOTSPOT=${ENABLE_VPN_HOTSPOT:-0} VPN_FALLBACK=${VPN_FALLBACK_MODE:-ANTIDPI} QNUM=$QNUM TCP_PORTS=$PORTS_TCP NFQWS_DEBUG=$NFQWS_DEBUG"
cat > "$RUN_DIR/tether-runtime.conf.tmp.$$" <<EOF
STRATEGY_EFFECTIVE="$STRATEGY_EFFECTIVE"
NFQ6="$NFQ6"
OWNER4="$OWNER4"
OWNER6="$OWNER6"
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
MANUAL_APP_UIDS=$(printf '%s\n%s\n' "$(get_app_uids "$APPS_LIST" 1)" "$(get_app_uids "$APPS_USER_LIST" 1)" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ')
AUTO_APP_UIDS=""
[ "$AUTO_APPS_ENABLED" = "1" ] && AUTO_APP_UIDS=$(get_app_uids "$AUTO_APPS_LIST" 1)
APP_UIDS=$(printf '%s\n%s\n' "$AUTO_APP_UIDS" "$MANUAL_APP_UIDS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ')
EXCLUDE_UIDS=$(get_app_uids "$EXCLUDE_LIST" 0)
AUTO_APP_UID_COUNT=$(echo "$AUTO_APP_UIDS" | wc -w | tr -d ' ')
MANUAL_APP_UID_COUNT=$(echo "$MANUAL_APP_UIDS" | wc -w | tr -d ' ')
APP_UID_COUNT=$(echo "$APP_UIDS" | wc -w | tr -d ' ')
EXCLUDE_UID_COUNT=$(echo "$EXCLUDE_UIDS" | wc -w | tr -d ' ')
log_i "Resolved UIDs: SMART effective=$APP_UID_COUNT auto=$AUTO_APP_UID_COUNT manual=$MANUAL_APP_UID_COUNT exclude=$EXCLUDE_UID_COUNT source=$(cat "$PACKAGE_SOURCE_FILE" 2>/dev/null)"
[ "$MODE" = "INCLUDE" ] && [ "$APP_UID_COUNT" -eq 0 ] 2>/dev/null && health_warn "INCLUDE активен, но ни один UID из AUTO/ручных приложений не разрешн"

DIRECT_MODE_FILE="$RUN_DIR/direct.flag"
rm -f "$DIRECT_MODE_FILE" 2>/dev/null
if [ "$SMART_DIRECT" = "1" ]; then
  # Ни одной записи в netfilter и ни одного userspace-процесса: на этой сети
  # обход не нужен. Флаг direct.flag говорит health-watcher, что отсутствие
  # nfqws2 — это штатное состояние, а не сбой.
  : > "$DIRECT_MODE_FILE" 2>/dev/null
  chmod 0600 "$DIRECT_MODE_FILE" 2>/dev/null || true
  write_start_state "STARTING" "DIRECT: обход на этой сети не требуется" 90
  log_i "DIRECT: NFQUEUE/QUIC правила и nfqws2 не устанавливаются"
else
write_start_state "STARTING" "Установка AntiDPI/NFQUEUE правил" 62
ipt4 -t mangle -N ZAPRET2_MANGLE || health_error "Не удалось создать IPv4 mangle chain"
ipt4 -t filter -N ZAPRET2_FILTER || health_error "Не удалось создать IPv4 filter chain"
[ "$NFQ6" = "1" ] && ipt6 -t mangle -N ZAPRET2_MANGLE || true
[ -n "$IP6T" ] && ipt6 -t filter -N ZAPRET2_FILTER || true

case "$MODE" in
  GLOBAL)
    if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ]; then ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || health_error "SMART_NATIVE IPv4 GLOBAL CONNMARK rule failed"; fi
    ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 GLOBAL NFQUEUE"
    if [ "$NFQ6" = "1" ]; then
      [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    fi ;;
  EXCLUDE)
    if [ "$OWNER4" = "1" ]; then
      for uid in $EXCLUDE_UIDS; do ipt4 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN || health_error "Не удалось исключить IPv4 UID=$uid"; done
      if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ]; then ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || health_error "SMART_NATIVE IPv4 EXCLUDE CONNMARK rule failed"; fi
      ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 EXCLUDE NFQUEUE"
    else
      health_error "EXCLUDE не применён: owner match недоступен, иначе исключённые приложения попали бы в NFQUEUE"
    fi
    if [ "$OWNER6" = "1" ] && [ "$NFQ6" = "1" ]; then
      for uid in $EXCLUDE_UIDS; do ipt6 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN || true; done
      [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    fi ;;
  INCLUDE)
    if [ "$OWNER4" = "1" ]; then
      for uid in $APP_UIDS; do
        if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ]; then ipt4 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || health_error "SMART_NATIVE IPv4 INCLUDE CONNMARK UID=$uid failed"; fi
        ipt4 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 INCLUDE UID=$uid"
      done
    else
      health_error "INCLUDE требует owner match, но он недоступен"
    fi
    if [ "$OWNER6" = "1" ] && [ "$NFQ6" = "1" ]; then
      for uid in $APP_UIDS; do
        [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
        ipt6 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
      done
    fi ;;
  *) health_error "Недопустимый MODE=$MODE" ;;
esac
ipt4 -t mangle -A OUTPUT -j ZAPRET2_MANGLE || health_error "Не удалось подключить ZAPRET2_MANGLE к OUTPUT"
[ "$NFQ6" = "1" ] && ipt6 -t mangle -A OUTPUT -j ZAPRET2_MANGLE || true

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

  "$MODDIR/tether-sync.sh" apply >/dev/null 2>&1 || health_error "Не удалось синхронизировать динамические tether AntiDPI правила"

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
  [ "$FORCE_TCP_HOTSPOT" = "1" ] && log_i "QUIC для Hotspot/USB: UDP/443 блокируется на динамически определнных downstream"
fi

if [ "$FORCE_TCP" = "1" ]; then
  case "$QUIC_MODE:$MODE" in
    GLOBAL:*|SELECTED:GLOBAL)
      ipt4 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || health_error "Не удалось блокировать QUIC IPv4"
      [ -n "$IP6T" ] && ipt6 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || true ;;
    SELECTED:INCLUDE)
      if [ "$OWNER4" = "1" ]; then
        for uid in $APP_UIDS; do ipt4 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT || health_error "QUIC IPv4 UID=$uid rule failed"; done
      else health_error "INCLUDE QUIC требует owner match"; fi
      if [ "$OWNER6" = "1" ]; then for uid in $APP_UIDS; do ipt6 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT || true; done; fi ;;
    SELECTED:EXCLUDE)
      if [ "$OWNER4" = "1" ]; then
        for uid in $EXCLUDE_UIDS; do ipt4 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -j RETURN || health_error "QUIC exclude IPv4 UID=$uid failed"; done
        ipt4 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || health_error "EXCLUDE QUIC global fallback failed"
      else health_error "EXCLUDE QUIC требует owner match"; fi
      if [ "$OWNER6" = "1" ]; then
        for uid in $EXCLUDE_UIDS; do ipt6 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -j RETURN || true; done
        ipt6 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || true
      fi ;;
    OFF:*) : ;;
  esac
fi
if [ "$FORCE_TCP" = "1" ]; then
  ipt4 -t filter -A OUTPUT -j ZAPRET2_FILTER || health_error "Не удалось подключить ZAPRET2_FILTER к OUTPUT"
  [ -n "$IP6T" ] && ipt6 -t filter -A OUTPUT -j ZAPRET2_FILTER || true
fi

HOST_ARGS=""
[ -s "$EXCLUDE_DOMAINS_FILE" ] && HOST_ARGS="$HOST_ARGS --hostlist-exclude=$EXCLUDE_DOMAINS_FILE"
SPECIAL_ARGS=""
if [ "$STRATEGY_MODE" = "SMART" ] && [ -n "${SMART_AUTO_ARGS:-}" ]; then
  # Профиль, прошедший активный probe, обслуживает весь TLS/443, а не только
  SPECIAL_ARGS="$HOST_ARGS $SMART_AUTO_ARGS --new"
  log_i "SMART profile: AUTO=$AUTO_PROFILE/$AUTO_PROFILE_NAME применён ко всему TLS/443 (не только YouTube); fallback profile=SMART_COMPAT_GENERAL"
elif [ "$STRATEGY_MODE" = "SMART" ] && [ -s "$SMART_YOUTUBE_FILE" ] && [ -n "$SMART_YOUTUBE_ARGS" ]; then
  SPECIAL_ARGS="--hostlist=$SMART_YOUTUBE_FILE $HOST_ARGS $SMART_YOUTUBE_ARGS --new"
  log_i "SMART profile: YouTube=$(grep -cvE '^[[:space:]]*(#|$)' "$SMART_YOUTUBE_FILE" 2>/dev/null || echo 0) domains engine=$STRATEGY_EFFECTIVE; fallback profile=GENERAL"
else
  log_i "SMART service profile unavailable or CUSTOM selected; using general profile only"
fi
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
log_i "nfqws2 command: qnum=$QNUM debug=$NFQWS_DEBUG smart_engine=$STRATEGY_EFFECTIVE youtube_profile=$([ -n "$SPECIAL_ARGS" ] && echo yes || echo no) exclude-hostlist=$([ -s "$EXCLUDE_DOMAINS_FILE" ] && echo yes || echo no)"
nfqws_launcher_pid=""
if command -v setsid >/dev/null 2>&1; then
  setsid "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $NFQWS_DEBUG_ARG \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $SPECIAL_ARGS $HOST_ARGS $DESYNC_ARGS >> "$LOG_FILE" 2>&1 &
  nfqws_launcher_pid=$!
  boot_trace "nfqws2 launch method=setsid launcher_pid=$nfqws_launcher_pid"
elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
  busybox setsid "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $NFQWS_DEBUG_ARG \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $SPECIAL_ARGS $HOST_ARGS $DESYNC_ARGS >> "$LOG_FILE" 2>&1 &
  nfqws_launcher_pid=$!
  boot_trace "nfqws2 launch method=busybox-setsid launcher_pid=$nfqws_launcher_pid"
elif command -v toybox >/dev/null 2>&1 && toybox setsid true >/dev/null 2>&1; then
  toybox setsid "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $NFQWS_DEBUG_ARG \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $SPECIAL_ARGS $HOST_ARGS $DESYNC_ARGS >> "$LOG_FILE" 2>&1 &
  nfqws_launcher_pid=$!
  boot_trace "nfqws2 launch method=toybox-setsid launcher_pid=$nfqws_launcher_pid"
else
  health_warn "setsid недоступен: nfqws2 запущен через nohup compatibility fallback"
  nohup "$BIN_DIR/nfqws2" --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $NFQWS_DEBUG_ARG \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $SPECIAL_ARGS $HOST_ARGS $DESYNC_ARGS >> "$LOG_FILE" 2>&1 &
  nfqws_launcher_pid=$!
  boot_trace "nfqws2 launch method=nohup-fallback launcher_pid=$nfqws_launcher_pid"
fi
sleep 1
nfqws_pid="$nfqws_launcher_pid"
if ! pid_is_owned "$nfqws_pid" nfqws2; then
  nfqws_pid=$(find_owned_nfqws_pid)
fi
write_start_state "STARTING" "Проверка процесса и NFQUEUE" 94
if ! pid_is_owned "$nfqws_pid" nfqws2; then
  health_error "nfqws2 не запустился или завершился сразу; см. внутренний лог $LOG_FILE"
  rm -f "$NFQWS_PID_FILE"
  write_health
  write_start_state "ERROR" "nfqws2 не запустился или завершился сразу" 100
  boot_trace "nfqws2 launch failed launcher_pid=${nfqws_launcher_pid:-none}"
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
[ "$ENABLE_HOTSPOT" != "1" ] || ipt4_quiet -t mangle -C FORWARD -j ZAPRET2_MANGLE_FORWARD || health_error "Проверка hook: Hotspot NFQUEUE не подключн к IPv4 FORWARD"
[ "$STRATEGY_EFFECTIVE" != "SMART_NATIVE" ] || ipt4_quiet -t mangle -C INPUT -j ZAPRET2_MANGLE_IN || health_error "Проверка hook: SMART_NATIVE reply feed не подключн к IPv4 INPUT"
fi
write_health

watch_pid=$(cat "$WATCHER_PID_FILE" 2>/dev/null)
if [ -z "$watch_pid" ] || ! pid_is_owned "$watch_pid" config-watch; then
  rm -f "$WATCHER_PID_FILE" 2>/dev/null
  WATCH_TARGETS="$CONF_FILE:w $APPS_LIST:w $AUTO_APPS_LIST:w $LISTS_DIR/warp_apps.list:w $LISTS_DIR/warp_apps.user.list:w $LISTS_DIR/ai_apps.list:w $LISTS_DIR/ai_apps.user.list:w $LISTS_DIR/dns.list:w $LISTS_DIR/dns.user.list:w $EXCLUDE_LIST:w $SMART_YOUTUBE_FILE:w $EXCLUDE_DOMAINS_FILE:w"
  if command -v inotifyd >/dev/null 2>&1; then
    inotifyd "$MODDIR/on_change.sh" $WATCH_TARGETS 2>/dev/null &
    echo $! > "$WATCHER_PID_FILE"
  elif command -v busybox >/dev/null 2>&1; then
    busybox inotifyd "$MODDIR/on_change.sh" $WATCH_TARGETS 2>/dev/null &
    echo $! > "$WATCHER_PID_FILE"
  else
    health_warn "inotifyd не найден: автоматическая перезагрузка списков недоступна"
    write_health
  fi
fi

if [ "${ENABLE_HOTSPOT:-0}" = "1" ]; then
  vpn_wpid=$(cat "$VPN_WATCHER_PID_FILE" 2>/dev/null)
  if [ -z "$vpn_wpid" ] || ! pid_is_owned "$vpn_wpid" vpn-watch; then
    sh "$MODDIR/vpn-watch.sh" >/dev/null 2>&1 &
    echo $! > "$VPN_WATCHER_PID_FILE"
    log_i "VPN watcher запущен: netlink/inotify event-driven + control loop ${VPN_WATCH_INTERVAL:-2} сек + safety role recheck ${VPN_ROLE_RECHECK:-30} сек"
  fi
else
  stop_pid "$VPN_WATCHER_PID_FILE" "VPN/tether watcher" vpn-watch
fi
if [ "$HEALTH" = "ERROR" ]; then
  write_health
  write_start_state "ERROR" "Критическая ошибка правил; см. диагностику" 100
  boot_trace "service ERROR after validation"
  stop_pid "$NFQWS_PID_FILE" "nfqws2" nfqws2
  cleanup_iptables
  "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
  exit 1
fi
health_wpid=$(cat "$HEALTH_WATCHER_PID_FILE" 2>/dev/null)
if [ -z "$health_wpid" ] || ! pid_is_owned "$health_wpid" health-watch; then
  sh "$MODDIR/service-watch.sh" >/dev/null 2>&1 &
  echo $! > "$HEALTH_WATCHER_PID_FILE"
fi
write_start_state "READY" "Служба работает" 100
boot_trace "service READY nfqws2_pid=$nfqws_pid health=$HEALTH"
log_i "Служба запущена: nfqws2 PID=$nfqws_pid health=$HEALTH"

# Запуск AmneziaWG v3 Cloudflare WARP туннеля для списка приложений
if [ "${ENABLE_WARP:-1}" = "1" ] && [ -f "$MODDIR/warp-tunnel.sh" ]; then
  log_i "Запуск точечного туннеля AmneziaWG v3 (WARP)..."
  sh "$MODDIR/warp-tunnel.sh" start >> "$LOG_FILE" 2>&1 &
fi

# Активный подбор не блокирует загрузку. Сначала всегда работает кэшированный
# профиль, затем фоновый probe меняет его только после полного успешного набора.
if [ "$STRATEGY_EFFECTIVE" = "SMART_ACTIVE" ] && [ "${AUTO_SELECT_ENABLED:-1}" = 1 ] && [ -x "$MODDIR/auto-select.sh" ]; then
  sh "$MODDIR/auto-select.sh" schedule >/dev/null 2>&1 || true
fi
if [ -x "$MODDIR/log-export.sh" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/log-export.sh" once >/dev/null 2>&1 &
  elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
    busybox setsid sh "$MODDIR/log-export.sh" once >/dev/null 2>&1 &
  else
    sh "$MODDIR/log-export.sh" once >/dev/null 2>&1 &
  fi
fi
