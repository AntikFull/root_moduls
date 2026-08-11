#!/system/bin/sh
# Zapret2 eCubz — runtime-adaptive Android service.
# Builds verified NFQUEUE/QUIC rules, resolves Android package UIDs through
# multiple backends and records enough diagnostics to debug vendor ROMs.

MODDIR="${0%/*}"
SERVICE_ACTION="$1"
CONF_FILE="$MODDIR/zapret2.conf"
APPS_LIST="$MODDIR/apps.list"
EXCLUDE_LIST="$MODDIR/exclude.list"
AUTO_DOMAINS_FILE="$MODDIR/auto_domains.list"
EXCLUDE_DOMAINS_FILE="$MODDIR/exclude_domains.list"
LOG_DIR="/sdcard/eCubz"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
NFQWS_LOG="$LOG_DIR/zapret2_nfqws.log"
BIN_DIR="$MODDIR/bin"
RUN_DIR="$MODDIR/run"
NFQWS_PID_FILE="$RUN_DIR/nfqws2.pid"
WATCHER_PID_FILE="$RUN_DIR/watcher.pid"
VPN_WATCHER_PID_FILE="$RUN_DIR/vpn-watcher.pid"
SERVICE_LOCK="$RUN_DIR/service.lock"
PACKAGE_UID_CACHE="$RUN_DIR/package_uids.cache"
PACKAGE_SOURCE_FILE="$RUN_DIR/package_source"
HEALTH_FILE="$RUN_DIR/health.env"

mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null

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
  {
    echo "HEALTH=$HEALTH"
    printf 'WARNINGS=%s\n' "$HEALTH_WARNINGS"
    printf 'PACKAGE_SOURCE=%s\n' "$(cat "$PACKAGE_SOURCE_FILE" 2>/dev/null)"
    printf 'STRATEGY_EFFECTIVE=%s\n' "${STRATEGY_EFFECTIVE:-${STRATEGY_MODE:-UNKNOWN}}"
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
  } > "$HEALTH_FILE"
}

stop_pid() {
  local pid_file="$1" name="$2" pid n
  [ -f "$pid_file" ] || return 0
  pid=$(cat "$pid_file" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) rm -f "$pid_file"; return 0 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n + 1)); done
    kill -KILL "$pid" 2>/dev/null
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
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n + 1)); done
    kill -KILL "$pid" 2>/dev/null
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
  # Usage: cmd_capture LABEL command args...
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
ipt4_quiet() { [ -n "$IPT" ] && "$IPT" -w 5 "$@" >/dev/null 2>&1; }
ipt6_quiet() { [ -n "$IP6T" ] && "$IP6T" -w 5 "$@" >/dev/null 2>&1; }

cleanup_iptables() {
  [ -n "$IPT" ] && {
    while ipt4_quiet -t mangle -D OUTPUT -j ZAPRET2_MANGLE; do :; done
    while ipt4_quiet -t mangle -D INPUT -j ZAPRET2_MANGLE_IN; do :; done
    while ipt4_quiet -t mangle -D FORWARD -j ZAPRET2_MANGLE_FORWARD; do :; done
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE; ipt4_quiet -t mangle -X ZAPRET2_MANGLE
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE_IN; ipt4_quiet -t mangle -X ZAPRET2_MANGLE_IN
    ipt4_quiet -t mangle -F ZAPRET2_MANGLE_FORWARD; ipt4_quiet -t mangle -X ZAPRET2_MANGLE_FORWARD
    while ipt4_quiet -t filter -D OUTPUT -j ZAPRET2_FILTER; do :; done
    while ipt4_quiet -t filter -D FORWARD -j ZAPRET2_FILTER_FORWARD; do :; done
    ipt4_quiet -t filter -F ZAPRET2_FILTER; ipt4_quiet -t filter -X ZAPRET2_FILTER
    ipt4_quiet -t filter -F ZAPRET2_FILTER_FORWARD; ipt4_quiet -t filter -X ZAPRET2_FILTER_FORWARD
    while ipt4_quiet -t nat -D PREROUTING -j ZAPRET2_NAT_PREROUTING; do :; done
    ipt4_quiet -t nat -F ZAPRET2_NAT_PREROUTING; ipt4_quiet -t nat -X ZAPRET2_NAT_PREROUTING
  }
  [ -n "$IP6T" ] && {
    while ipt6_quiet -t mangle -D OUTPUT -j ZAPRET2_MANGLE; do :; done
    while ipt6_quiet -t mangle -D INPUT -j ZAPRET2_MANGLE_IN; do :; done
    while ipt6_quiet -t mangle -D FORWARD -j ZAPRET2_MANGLE_FORWARD; do :; done
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE; ipt6_quiet -t mangle -X ZAPRET2_MANGLE
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE_IN; ipt6_quiet -t mangle -X ZAPRET2_MANGLE_IN
    ipt6_quiet -t mangle -F ZAPRET2_MANGLE_FORWARD; ipt6_quiet -t mangle -X ZAPRET2_MANGLE_FORWARD
    while ipt6_quiet -t filter -D OUTPUT -j ZAPRET2_FILTER; do :; done
    while ipt6_quiet -t filter -D FORWARD -j ZAPRET2_FILTER_FORWARD; do :; done
    ipt6_quiet -t filter -F ZAPRET2_FILTER; ipt6_quiet -t filter -X ZAPRET2_FILTER
    ipt6_quiet -t filter -F ZAPRET2_FILTER_FORWARD; ipt6_quiet -t filter -X ZAPRET2_FILTER_FORWARD
  }
}

normalize_pm_output() {
  # $1 raw file, $2 user id, append normalized "package uid user" lines to cache.
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
  [ -n "$users" ] && printf '%s\n' "$users" || echo 0
}

build_package_cache_once() {
  # Merge every source that works instead of trusting the first PackageManager answer.
  # Some vendor ROMs return a valid but incomplete list during early boot.
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

  # Root-accessible packages.list is independent of the PackageManager shell API and
  # is particularly useful while ColorOS/OxygenOS/MIUI are still bringing services up.
  if [ -r /data/system/packages.list ]; then
    awk 'NF>=2 && $2 ~ /^[0-9]+$/ {print $1, $2, 0}' /data/system/packages.list >> "$PACKAGE_UID_CACHE.tmp" 2>/dev/null
    fs_ok=1
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

prepare_package_cache() {
  local elapsed=0 wait_max="${PACKAGE_WAIT_SECONDS:-60}"
  case "$wait_max" in ''|*[!0-9]*) wait_max=60 ;; esac
  while [ "$elapsed" -le "$wait_max" ]; do
    build_package_cache_once && return 0
    [ "$elapsed" -ge "$wait_max" ] && break
    log_w "PackageManager/пакетная база ещё не дают UID; повтор через 2с ($elapsed/$wait_max)"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  if [ -s "$PACKAGE_UID_CACHE" ]; then
    echo "stale-cache" > "$PACKAGE_SOURCE_FILE"
    health_warn "Источники UID недоступны; используется предыдущий UID-кэш"
    return 0
  fi
  echo "none" > "$PACKAGE_SOURCE_FILE"
  health_error "Не удалось получить UID приложений ни одним способом"
  return 1
}

resolve_pkg_direct() {
  # Last-chance per-package lookup. A full PackageManager listing can be incomplete
  # on some vendor ROMs even though a filtered query already sees the package.
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
  local target_list="$1" honor_exclude="${2:-0}" app uid uids="" found missing=0
  [ -f "$target_list" ] || { echo ""; return 0; }
  while IFS= read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$app" in \#*|'') continue ;; esac
    if [ "$honor_exclude" = "1" ] && pkg_is_excluded "$app"; then
      log_d "EXCLUDE имеет приоритет: $app пропущен"
      continue
    fi
    found=$(awk -v p="$app" '$1==p {print $2}' "$PACKAGE_UID_CACHE" 2>/dev/null | sort -nu)
    if [ -z "$found" ]; then
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
  if [ "$STRATEGY_EFFECTIVE" = "AUTO" ]; then
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
    echo 1 > "$f" 2>/dev/null || { log_w "Не удалось включить nf_conntrack_acct; AUTO будет отключён"; return 1; }
    log_i "AUTO: включён net.netfilter.nf_conntrack_acct=1 для connbytes limiter"
  fi
  [ "$(cat "$f" 2>/dev/null)" = "1" ] && CONNTRACK_ACCT=1
  [ "$CONNTRACK_ACCT" = "1" ]
}

if [ "$SERVICE_ACTION" != "reload" ]; then
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  sleep 2
fi
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${MODE:=INCLUDE}" "${STRATEGY_MODE:=AUTO}" "${FORCE_TCP:=1}" "${QUIC_MODE:=SELECTED}" "${PORTS_TCP:=80,443}" "${QNUM:=200}" "${ENABLE_HOTSPOT:=1}" "${DNS_FORWARD_HOTSPOT:=0}" "${DNS_FORWARD_SERVER:=1.1.1.1}"
: "${FORCE_TCP_HOTSPOT:=1}" "${VPN_FALLBACK_MODE:=ANTIDPI}" "${NFQWS_DEBUG:=0}" "${LOG_VERBOSE:=1}" "${PACKAGE_WAIT_SECONDS:=60}"
: "${TETHER_IFACES:=ap+ swlan+ softap+ ap_br_wlan+ ap_br_softap+ rndis+ usb+ ncm+ bnep+ bt-pan+ pan+ tether+ wlan1 wlan2 wlan3 wlan4 wifi1 wifi2 wifi3 wifi4}" "${VPN_WATCH_INTERVAL:=2}" "${VPN_RETRY_INTERVAL:=1}" "${VPN_STATE_RECHECK:=10}"
: "${AUTO_REPLY_PACKETS:=12}" "${FLOW_CONNMARK:=0x10000000/0x10000000}"

log_environment "$SERVICE_ACTION"
log_network_modules

acquire_lock() {
  local lock_attempt=0 lock_pid
  while ! mkdir "$SERVICE_LOCK" 2>/dev/null; do
    lock_pid=$(cat "$SERVICE_LOCK/pid" 2>/dev/null)
    case "$lock_pid" in
      ''|0|*[!0-9]*) rm -rf "$SERVICE_LOCK" 2>/dev/null ;;
      *) ! kill -0 "$lock_pid" 2>/dev/null && rm -rf "$SERVICE_LOCK" 2>/dev/null ;;
    esac
    lock_attempt=$((lock_attempt + 1))
    if [ "$lock_attempt" -ge 10 ]; then
      log_w "Пропуск перезапуска: другая перезагрузка службы уже выполняется (PID ${lock_pid:-unknown})"
      return 1
    fi
    sleep 1
  done
  echo $$ > "$SERVICE_LOCK/pid"
}
release_service_lock() {
  [ "$(cat "$SERVICE_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$SERVICE_LOCK" 2>/dev/null
}
acquire_lock || exit 0
trap 'release_service_lock; exit 1' HUP INT TERM
trap release_service_lock EXIT

prepare_package_cache || true

stop_pid "$NFQWS_PID_FILE" "nfqws2"
# Restart the network watcher on every reload so changed VPN/tether settings take effect.
stop_pid "$VPN_WATCHER_PID_FILE" "VPN/tether watcher"
stop_owned_nfqws
cleanup_iptables
# Remove policy/NAT state from previous releases even if VPN Hotspot is now disabled.
"$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true

CONNTRACK_ACCT=0
[ "$STRATEGY_MODE" = "AUTO" ] && ensure_conntrack_accounting || true
probe_firewall || { write_health; exit 1; }

STRATEGY_EFFECTIVE="$STRATEGY_MODE"
if [ "$STRATEGY_MODE" = "AUTO" ] && { [ "$CONNTRACK_ACCT" != "1" ] || [ "$CONNBYTES4" != "1" ] || [ "$CONNMARK4" != "1" ]; }; then
  STRATEGY_EFFECTIVE="SIMPLE"
  missing=""
  [ "$CONNTRACK_ACCT" = "1" ] || missing="${missing}${missing:+, }nf_conntrack_acct"
  [ "$CONNMARK4" = "1" ] || missing="${missing}${missing:+, }CONNMARK"
  [ "$CONNBYTES4" = "1" ] || missing="${missing}${missing:+, }xt_connbytes"
  compat_notice "AUTO → SIMPLE: compatibility fallback; отсутствует ${missing:-неизвестная capability}. Это не ошибка работы модуля"
fi
log_i "AUTO capabilities: acct=$CONNTRACK_ACCT connmark=$CONNMARK4 connbytes=$CONNBYTES4; requested=$STRATEGY_MODE effective=$STRATEGY_EFFECTIVE compat=$COMPAT_STATUS"
case "$STRATEGY_EFFECTIVE" in
  AUTO) DESYNC_ARGS="$DESYNC_ARGS_AUTO" ;;
  CUSTOM) DESYNC_ARGS="$DESYNC_ARGS_CUSTOM" ;;
  *) DESYNC_ARGS="$DESYNC_ARGS_SIMPLE" ;;
esac
log_i "Config: MODE=$MODE strategy=$STRATEGY_MODE effective=$STRATEGY_EFFECTIVE QUIC_MODE=$QUIC_MODE FORCE_TCP=$FORCE_TCP HOTSPOT=$ENABLE_HOTSPOT VPN_HOTSPOT=${ENABLE_VPN_HOTSPOT:-0} VPN_FALLBACK=${VPN_FALLBACK_MODE:-ANTIDPI} QNUM=$QNUM TCP_PORTS=$PORTS_TCP NFQWS_DEBUG=$NFQWS_DEBUG"

APP_UIDS=$(get_app_uids "$APPS_LIST" 1)
EXCLUDE_UIDS=$(get_app_uids "$EXCLUDE_LIST" 0)
APP_UID_COUNT=$(echo "$APP_UIDS" | wc -w | tr -d ' ')
EXCLUDE_UID_COUNT=$(echo "$EXCLUDE_UIDS" | wc -w | tr -d ' ')
log_i "Resolved UIDs: apps.list=$APP_UID_COUNT exclude.list=$EXCLUDE_UID_COUNT source=$(cat "$PACKAGE_SOURCE_FILE" 2>/dev/null)"
[ "$MODE" = "INCLUDE" ] && [ "$APP_UID_COUNT" -eq 0 ] 2>/dev/null && health_warn "INCLUDE активен, но ни один UID из apps.list не разрешён"

ipt4 -t mangle -N ZAPRET2_MANGLE || health_error "Не удалось создать IPv4 mangle chain"
ipt4 -t filter -N ZAPRET2_FILTER || health_error "Не удалось создать IPv4 filter chain"
[ "$NFQ6" = "1" ] && ipt6 -t mangle -N ZAPRET2_MANGLE || true
[ -n "$IP6T" ] && ipt6 -t filter -N ZAPRET2_FILTER || true

case "$MODE" in
  GLOBAL)
    [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
    ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 GLOBAL NFQUEUE"
    if [ "$NFQ6" = "1" ]; then
      [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    fi ;;
  EXCLUDE)
    if [ "$OWNER4" = "1" ]; then
      for uid in $EXCLUDE_UIDS; do ipt4 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN || health_warn "Не удалось исключить IPv4 UID=$uid"; done
      [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      ipt4 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_error "Не удалось добавить IPv4 EXCLUDE NFQUEUE"
    else
      health_error "EXCLUDE не применён: owner match недоступен, иначе исключённые приложения попали бы в NFQUEUE"
    fi
    if [ "$OWNER6" = "1" ] && [ "$NFQ6" = "1" ]; then
      for uid in $EXCLUDE_UIDS; do ipt6 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN || true; done
      [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      ipt6 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    fi ;;
  INCLUDE)
    if [ "$OWNER4" = "1" ]; then
      for uid in $APP_UIDS; do
        [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && ipt4 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
        ipt4 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_warn "Не удалось добавить IPv4 INCLUDE UID=$uid"
      done
    else
      health_error "INCLUDE требует owner match, но он недоступен"
    fi
    if [ "$OWNER6" = "1" ] && [ "$NFQ6" = "1" ]; then
      for uid in $APP_UIDS; do
        [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && [ "$CONNMARK6" = "1" ] && ipt6 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
        ipt6 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
      done
    fi ;;
  *) health_error "Недопустимый MODE=$MODE" ;;
esac
ipt4 -t mangle -A OUTPUT -j ZAPRET2_MANGLE || health_error "Не удалось подключить ZAPRET2_MANGLE к OUTPUT"
[ "$NFQ6" = "1" ] && ipt6 -t mangle -A OUTPUT -j ZAPRET2_MANGLE || true

# circular/AUTO keeps per-connection state and must see server replies too.
# Queue only the first reply packets to avoid sending bulk downloads to userspace.
if [ "$STRATEGY_EFFECTIVE" = "AUTO" ]; then
  ipt4 -t mangle -N ZAPRET2_MANGLE_IN || health_warn "Не удалось создать IPv4 INPUT reply chain"
  ipt4 -t mangle -A ZAPRET2_MANGLE_IN -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || health_warn "AUTO IPv4 reply NFQUEUE rule failed"
  ipt4 -t mangle -I INPUT 1 -j ZAPRET2_MANGLE_IN || health_warn "Не удалось подключить AUTO IPv4 INPUT reply chain"
  if [ "$NFQ6" = "1" ] && [ "$CONNBYTES6" = "1" ]; then
    ipt6 -t mangle -N ZAPRET2_MANGLE_IN || true
    ipt6 -t mangle -A ZAPRET2_MANGLE_IN -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    ipt6 -t mangle -I INPUT 1 -j ZAPRET2_MANGLE_IN || true
  fi
  log_i "AUTO conntrack feed: server replies 1..$AUTO_REPLY_PACKETS queued on INPUT/FORWARD"
fi

# Hotspot/Tethering is scoped to interfaces Android is currently using as
# downstream. v2.6.12 resolves the role strictly/dynamically instead of assuming wlan2,
# tun0 or a fixed vendor naming scheme.
if [ "$ENABLE_HOTSPOT" = "1" ]; then
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || health_warn "Не удалось включить IPv4 forwarding"
  log_i "Tether scope: dynamic role detection (Android tether state/config + network fallback)"

  ipt4 -t mangle -N ZAPRET2_MANGLE_FORWARD || health_warn "Не удалось создать IPv4 FORWARD chain"
  [ "$NFQ6" = "1" ] && ipt6 -t mangle -N ZAPRET2_MANGLE_FORWARD || true
  ipt4 -t mangle -I FORWARD 1 -j ZAPRET2_MANGLE_FORWARD || health_warn "Не удалось подключить IPv4 Hotspot chain"
  [ "$NFQ6" = "1" ] && ipt6 -t mangle -I FORWARD 1 -j ZAPRET2_MANGLE_FORWARD || true

  if [ "$DNS_FORWARD_HOTSPOT" = "1" ]; then
    ipt4 -t nat -N ZAPRET2_NAT_PREROUTING || health_warn "Не удалось создать DNS DNAT chain"
    ipt4 -t nat -I PREROUTING 1 -j ZAPRET2_NAT_PREROUTING || health_warn "Не удалось подключить DNS DNAT chain"
  fi

  if [ "$FORCE_TCP_HOTSPOT" = "1" ]; then
    ipt4 -t filter -N ZAPRET2_FILTER_FORWARD || health_warn "Не удалось создать Hotspot QUIC chain"
    ipt4 -t filter -I FORWARD 1 -j ZAPRET2_FILTER_FORWARD || health_warn "Не удалось подключить Hotspot QUIC IPv4 chain"
    if [ -n "$IP6T" ]; then
      ipt6 -t filter -N ZAPRET2_FILTER_FORWARD || true
      ipt6 -t filter -I FORWARD 1 -j ZAPRET2_FILTER_FORWARD || true
    fi
  fi

  # Runtime capability probe results are needed when tether-sync rebuilds rules
  # later without restarting nfqws2.
  cat > "$RUN_DIR/tether-runtime.conf" <<EOF
STRATEGY_EFFECTIVE="$STRATEGY_EFFECTIVE"
NFQ6="$NFQ6"
CONNBYTES4="$CONNBYTES4"
CONNBYTES6="$CONNBYTES6"
CONNMARK4="$CONNMARK4"
CONNMARK6="$CONNMARK6"
QBYPASS4="$QBYPASS4"
QBYPASS6="$QBYPASS6"
EOF
  chmod 0600 "$RUN_DIR/tether-runtime.conf" 2>/dev/null || true

  "$MODDIR/tether-sync.sh" apply >/dev/null 2>&1 || health_warn "Не удалось синхронизировать динамические tether AntiDPI правила"

  # Clean legacy/old VPN policy first, then apply routing for whichever interface
  # is currently the VPN role. AntiDPI remains the default fallback.
  "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
  [ "${ENABLE_VPN_HOTSPOT:-0}" = "1" ] && "$MODDIR/vpn-routing.sh" apply

  ACTIVE_TETHER_IFACES=$(cat "$RUN_DIR/tether-downstreams.state" 2>/dev/null)
  log_i "Tether active downstream: ${ACTIVE_TETHER_IFACES:-none}"
  [ "$FORCE_TCP_HOTSPOT" = "1" ] && log_i "QUIC для Hotspot/USB: UDP/443 блокируется на динамически определённых downstream"
fi

if [ "$FORCE_TCP" = "1" ]; then
  case "$QUIC_MODE" in
    GLOBAL)
      ipt4 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || health_warn "Не удалось блокировать GLOBAL QUIC IPv4"
      [ -n "$IP6T" ] && ipt6 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT || true ;;
    SELECTED)
      if [ "$OWNER4" = "1" ]; then
        for uid in $APP_UIDS; do ipt4 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT || health_warn "QUIC IPv4 UID=$uid rule failed"; done
      fi
      if [ "$OWNER6" = "1" ]; then
        for uid in $APP_UIDS; do ipt6 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT || true; done
      fi ;;
  esac
fi
ipt4 -t filter -A OUTPUT -j ZAPRET2_FILTER || health_warn "Не удалось подключить ZAPRET2_FILTER к OUTPUT"
[ -n "$IP6T" ] && ipt6 -t filter -A OUTPUT -j ZAPRET2_FILTER || true

HOST_ARGS=""
[ -s "$EXCLUDE_DOMAINS_FILE" ] && HOST_ARGS="$HOST_ARGS --hostlist-exclude=$EXCLUDE_DOMAINS_FILE"
ALT_ARGS=""
[ -s "$AUTO_DOMAINS_FILE" ] && [ -n "$DESYNC_ARGS_ALT" ] && ALT_ARGS="--new --hostlist=$AUTO_DOMAINS_FILE $DESYNC_ARGS_ALT"
NFQWS_DEBUG_ARG=""
[ "$NFQWS_DEBUG" = "1" ] && NFQWS_DEBUG_ARG="--debug=@$NFQWS_LOG"

cd "$BIN_DIR" || { health_error "BIN_DIR недоступен: $BIN_DIR"; write_health; exit 1; }
[ -x ./nfqws2 ] || { health_error "nfqws2 отсутствует/не исполняемый: $BIN_DIR/nfqws2"; write_health; exit 1; }
log_i "nfqws2 command: qnum=$QNUM debug=$NFQWS_DEBUG hostlist=$([ -s "$AUTO_DOMAINS_FILE" ] && echo yes || echo no) exclude-hostlist=$([ -s "$EXCLUDE_DOMAINS_FILE" ] && echo yes || echo no)"
if command -v nohup >/dev/null 2>&1; then
  nohup ./nfqws2 --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $NFQWS_DEBUG_ARG \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $HOST_ARGS $DESYNC_ARGS $ALT_ARGS >> "$LOG_FILE" 2>&1 &
else
  ./nfqws2 --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 $NFQWS_DEBUG_ARG \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $HOST_ARGS $DESYNC_ARGS $ALT_ARGS >> "$LOG_FILE" 2>&1 &
fi
echo $! > "$NFQWS_PID_FILE"
sleep 1
nfqws_pid=$(cat "$NFQWS_PID_FILE" 2>/dev/null)
if ! kill -0 "$nfqws_pid" 2>/dev/null; then
  health_error "nfqws2 завершился сразу после запуска"
  rm -f "$NFQWS_PID_FILE"
  write_health
  exit 1
fi

verify_rules_snapshot
if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
  NFQ_STATE=$(cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null)
  log_i "NFQUEUE state:\n$NFQ_STATE"
  echo "$NFQ_STATE" | awk -v q="$QNUM" '$1==q {found=1} END {exit !found}' || health_error "nfqws2 запущен, но очередь NFQUEUE $QNUM не видна в ядре"
else
  health_warn "/proc/net/netfilter/nfnetlink_queue недоступен: привязку очереди нельзя проверить"
fi
ipt4_quiet -t mangle -C OUTPUT -j ZAPRET2_MANGLE || health_error "Проверка hook: ZAPRET2_MANGLE не подключена к IPv4 OUTPUT"
ipt4_quiet -t filter -C OUTPUT -j ZAPRET2_FILTER || health_warn "Проверка hook: ZAPRET2_FILTER не подключена к IPv4 OUTPUT"
[ "$ENABLE_HOTSPOT" != "1" ] || ipt4_quiet -t mangle -C FORWARD -j ZAPRET2_MANGLE_FORWARD || health_warn "Проверка hook: Hotspot NFQUEUE не подключён к IPv4 FORWARD"
[ "$STRATEGY_EFFECTIVE" != "AUTO" ] || ipt4_quiet -t mangle -C INPUT -j ZAPRET2_MANGLE_IN || health_warn "Проверка hook: AUTO reply feed не подключён к IPv4 INPUT"
write_health

if [ "$SERVICE_ACTION" != "reload" ]; then
  stop_pid "$WATCHER_PID_FILE" "inotifyd"
  stop_pid "$VPN_WATCHER_PID_FILE" "inotifyd VPN"
  WATCH_TARGETS="$CONF_FILE:w $APPS_LIST:w $EXCLUDE_LIST:w $AUTO_DOMAINS_FILE:w $EXCLUDE_DOMAINS_FILE:w"
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

# Hybrid watcher: /data/misc/net events for fast netd/VPN changes plus a lightweight
# interface signature and a periodic strict role recheck for vendor VPN implementations.
if [ "${ENABLE_HOTSPOT:-0}" = "1" ]; then
  vpn_wpid=$(cat "$VPN_WATCHER_PID_FILE" 2>/dev/null)
  if [ -z "$vpn_wpid" ] || ! kill -0 "$vpn_wpid" 2>/dev/null; then
    sh "$MODDIR/vpn-watch.sh" >/dev/null 2>&1 &
    echo $! > "$VPN_WATCHER_PID_FILE"
    log_i "VPN watcher запущен: inotify /data/misc/net + polling ${VPN_WATCH_INTERVAL:-2} сек + role recheck ${VPN_STATE_RECHECK:-10} сек"
  fi
else
  stop_pid "$VPN_WATCHER_PID_FILE" "VPN/tether watcher"
fi
log_i "Служба запущена: nfqws2 PID=$nfqws_pid health=$HEALTH"
