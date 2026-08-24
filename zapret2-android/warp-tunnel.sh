#!/system/bin/sh
# ==============================================================================
# warp-tunnel.sh — AmneziaWG v3 (Cloudflare WARP) Tunnel for Android (zapret2)
# ==============================================================================
export PATH=/system/bin:/system/xbin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
umask 077

if [ -n "$MODDIR" ] && [ -f "$MODDIR/module.prop" ]; then
  :
elif [ -f "./module.prop" ]; then
  MODDIR="."
elif [ -n "$BASH_SOURCE" ] && [ -f "${BASH_SOURCE%/*}/module.prop" ]; then
  MODDIR="${BASH_SOURCE%/*}"
elif [ -f "${0%/*}/module.prop" ]; then
  MODDIR="${0%/*}"
elif [ -f "/data/adb/modules/zapret2-android/module.prop" ]; then
  MODDIR="/data/adb/modules/zapret2-android"
else
  MODDIR="${0%/*}"
fi
[ -d "$MODDIR" ] || MODDIR="."
: "${BIN_DIR:=$MODDIR/bin}"
: "${RUN_DIR:=$MODDIR/run}"
: "${LOG_DIR:=$MODDIR/logs}"
: "${STATE_DIR:=$MODDIR/state}"
: "${LOG_FILE:=$LOG_DIR/zapret2_debug.log}"
: "${WARP_CONF:=$STATE_DIR/warp.conf}"
: "${RU_CONF_DIR:=/data/adb/zapret2/ru}"
: "${RU_MOD_DIR:=$MODDIR/ru}"
: "${WARP_PROFILE_TYPE:=$STATE_DIR/warp-profile.type}"
: "${WARP_PID_FILE:=$RUN_DIR/warp.pid}"
: "${WARP_RUNTIME_CONF:=$RUN_DIR/warp-runtime.conf}"
: "${WARP_RULE_STATE:=$RUN_DIR/warp-rules.state}"
: "${WARP_ADAPT_STATE:=$STATE_DIR/warp-adapt.state}"
: "${WARP_DOMAIN_IPS_STATE:=$STATE_DIR/warp-domain-ips.state}"
: "${WARP_UNHEALTHY_SINCE:=$RUN_DIR/warp-unhealthy-since.ts}"

# Конфигурация геоблок-туннеля AWG98 (конфиги из каталога /geo/)
: "${GEO_CONF:=$STATE_DIR/geo_warp.conf}"
: "${GEO_CONF_DIR:=/data/adb/zapret2/geo}"
: "${GEO_MOD_DIR:=$MODDIR/geo}"
: "${GEO_PROFILE_TYPE:=$STATE_DIR/geo-profile.type}"
: "${GEO_PID_FILE:=$RUN_DIR/geo_warp.pid}"
: "${GEO_RUNTIME_CONF:=$RUN_DIR/geo-runtime.conf}"
: "${GEO_DOMAIN_IPS_STATE:=$STATE_DIR/geo-domain-ips.state}"
: "${GEO_UNHEALTHY_SINCE:=$RUN_DIR/geo-unhealthy-since.ts}"

LISTS_DIR="$MODDIR/lists"
[ -d "$LISTS_DIR" ] || LISTS_DIR="$MODDIR"
mkdir -p "$RU_CONF_DIR" "$GEO_CONF_DIR" "$RUN_DIR" "$STATE_DIR" 2>/dev/null || true
chmod 0755 /data/adb/zapret2 "$RU_CONF_DIR" "$GEO_CONF_DIR" 2>/dev/null || true
# ------------------------------------------------------------------------------
# Конфигурация и единый источник правды (SSOT / DRY)
# ------------------------------------------------------------------------------
[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"

: "${ENABLE_WARP:=0}"
: "${WARP_PROFILE_MODE:=auto}"
: "${WARP_DEV:=awg99}"
: "${WARP_ROUTE_TABLE:=11888}"
: "${WARP_PRIORITY:=40}"

: "${ENABLE_GEO_WARP:=1}"
: "${GEO_DEV:=${GEO_WARP_DEV:-awg98}}"
: "${GEO_ROUTE_TABLE:=${GEO_WARP_TABLE:-11887}}"
: "${GEO_WARP_PRIORITY:=30}"

: "${PREF_APPS_GEO:=21}"
: "${PREF_DEST_GEO:=${GEO_WARP_PRIORITY:-30}}"
: "${PREF_APPS_WARP:=22}"
: "${PREF_DEST_WARP:=${WARP_PRIORITY:-35}}"
: "${PREF_BASE:=50}"
: "${PREF_DEST:=$PREF_DEST_WARP}"

# Каноническая маска fwmark для 2-го прохода (vendor bit 18, не конфликтует с NetId и VPN AOSP)
APPS_ROUTING_MARK="0x00040000"
APPS_ROUTING_MASK="0x00040000"

DNS_LIST="$LISTS_DIR/dns.list"
DNS_USER_LIST="$LISTS_DIR/dns.user.list"
GEO_DOMAINS_FILE="$LISTS_DIR/geo_warp.list"
WARP_DOMAINS_FILE="$LISTS_DIR/warp_domains.list"
APPS_BLACK_FILE="$LISTS_DIR/apps_black.list"
APPS_BLACK_RULE_STATE="$STATE_DIR/apps-black-rules.state"
WARP_LOCK="$RUN_DIR/warp.lock"

Z2NETD_BIN="$MODDIR/bin/z2netd"
Z2NETD_PID="$STATE_DIR/z2netd.pid"
Z2NETD_PORT="5353"

TABLE="$WARP_ROUTE_TABLE"
DEV="$WARP_DEV"

: "${WARP_JC:=5}"
: "${WARP_JMIN:=40}"
: "${WARP_JMAX:=70}"
: "${WARP_S1:=0}"
: "${WARP_S2:=0}"
: "${WARP_S3:=0}"
: "${WARP_S4:=0}"
: "${WARP_H1:=1}"
: "${WARP_H2:=2}"
: "${WARP_H3:=3}"
: "${WARP_H4:=4}"
: "${WARP_I1:=}"
: "${WARP_I2:=}"
: "${WARP_I3:=}"
: "${WARP_I4:=}"
: "${WARP_I5:=}"
: "${WARP_PORT:=500}"
: "${WARP_ENDPOINT:=162.159.192.1}"
: "${WARP_DNS:=1.1.1.1 1.0.0.1}"
: "${WARP_DNS_FORCE:=1}"
: "${WARP_ADAPTIVE:=1}"
: "${WARP_SIP_FORCE:=0}"
: "${WARP_STARTUP_TRIES:=40}"
: "${WARP_PROBE_TIMEOUT:=3}"
: "${WARP_DOMAIN_ROUTING:=1}"
: "${WARP_HEALTH_MAX_AGE:=180}"
: "${WARP_HEALTH_PROBE_IP:=1.1.1.1}"
: "${WARP_HEALTH_PROBE_TIMEOUT:=4}"
: "${WARP_HEALTH_PROBE_TRIES:=3}"
: "${WARP_STALL_RESTART_SEC:=600}"
: "${WARP_WATCH_BATCH:=5}"
: "${WARP_ADAPT_RETRY_SEC:=300}"
: "${WARP_AWG_CMD_TIMEOUT:=2}"

# Зомби и умирающие процессы не отдают cmdline: ядро держит блокировку памяти
# задачи, и чтение виснет без таймаута — однажды это подвесило перезапуск целиком.
# /proc/PID/stat читается без этой блокировки, поэтому сначала спрашиваем
# состояние. Полный вариант с потолком по времени — в service.sh.
pid_cmdline() {
  local st
  case "$1" in ''|0|*[!0-9]*) return 1 ;; esac
  st=$(sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)
  case "$st" in ''|Z|X|x) return 1 ;; esac
  tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

log_i() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] warp: $*" >> "$LOG_FILE"; }
log_w() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] warp: $*" >> "$LOG_FILE"; }
log_e() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] warp: $*" >> "$LOG_FILE"; }

# Local UAPI commands must never be able to freeze the adaptive state machine.
# On some Android builds a stale/broken userspace WireGuard socket can make
# `awg show/set/syncconf` wait indefinitely. A candidate is skipped instead.
run_with_timeout() {
  local limit="$1" pid elapsed=0 rc
  shift
  case "$limit" in ''|*[!0-9]*) limit=2 ;; esac
  [ "$limit" -ge 1 ] 2>/dev/null || limit=1
  [ "$limit" -le 10 ] 2>/dev/null || limit=10
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ] 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

mkdir -p "$RUN_DIR" 2>/dev/null || true
export WG_UAPI_DIR="$RUN_DIR"
export AMNEZIAWG_UAPI_DIR="$RUN_DIR"
awg_cmd() {
  WG_UAPI_DIR="$RUN_DIR" AMNEZIAWG_UAPI_DIR="$RUN_DIR" run_with_timeout "${WARP_AWG_CMD_TIMEOUT:-2}" "$BIN_DIR/awg" "$@"
}

# Снятие правила с потолком по числу повторов. Тот же приём, что и
# delete_jump_bounded в service.sh: дублирующихся правил восьми не бывает,
# а `while ...; do :; done` без предела — это заявка на зависший cleanup.
del_bounded() {
  local attempt=0
  while [ "$attempt" -lt 8 ]; do
    "$@" >/dev/null 2>&1 || return 0
    attempt=$((attempt + 1))
  done
  log_w "Очистка правила ограничена восемью повторами: $*"
  return 0
}

# ------------------------------------------------------------------------------
# Сериализация операций (Locking)
# ------------------------------------------------------------------------------
WARP_LOCK_DEPTH=${WARP_LOCK_DEPTH:-0}
GEO_LOCK="$RUN_DIR/geo.lock"
GEO_LOCK_DEPTH=${GEO_LOCK_DEPTH:-0}
acquire_geo_lock() {
  local attempts=0 owner empty_seen=0
  if [ "$GEO_LOCK_DEPTH" -gt 0 ] 2>/dev/null && [ "$(cat "$GEO_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    GEO_LOCK_DEPTH=$((GEO_LOCK_DEPTH + 1))
    return 0
  fi
  while ! mkdir "$GEO_LOCK" 2>/dev/null; do
    owner=$(cat "$GEO_LOCK/pid" 2>/dev/null)
    case "$owner" in
      ''|*[!0-9]*)
        empty_seen=$((empty_seen + 1))
        [ "$empty_seen" -ge 2 ] && { rm -rf "$GEO_LOCK" 2>/dev/null; empty_seen=0; }
        ;;
      *)
        empty_seen=0
        kill -0 "$owner" 2>/dev/null || rm -rf "$GEO_LOCK" 2>/dev/null
        ;;
    esac
    attempts=$((attempts + 1))
    [ "$attempts" -ge 50 ] && return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$GEO_LOCK/pid" || { rm -rf "$GEO_LOCK" 2>/dev/null; return 1; }
  GEO_LOCK_DEPTH=1
  return 0
}

release_geo_lock() {
  [ "$GEO_LOCK_DEPTH" -gt 0 ] 2>/dev/null || return 0
  GEO_LOCK_DEPTH=$((GEO_LOCK_DEPTH - 1))
  if [ "$GEO_LOCK_DEPTH" -eq 0 ] 2>/dev/null && [ "$(cat "$GEO_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$GEO_LOCK" 2>/dev/null
  fi
}

acquire_warp_lock() {
  local attempts=0 owner empty_seen=0
  if [ "$WARP_LOCK_DEPTH" -gt 0 ] 2>/dev/null && [ "$(cat "$WARP_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    WARP_LOCK_DEPTH=$((WARP_LOCK_DEPTH + 1))
    return 0
  fi
  while ! mkdir "$WARP_LOCK" 2>/dev/null; do
    owner=$(cat "$WARP_LOCK/pid" 2>/dev/null)
    case "$owner" in
      # Прежде здесь стоял `continue` ДО инкремента и sleep: если каталог по
      # какой-то причине не удалялся, цикл крутился на 100% CPU без предела.
      # Пустой pid к тому же не означает брошенную блокировку — владелец мог
      # сделать mkdir и ещё не записать себя, поэтому ждём две итерации.
      ''|*[!0-9]*)
        empty_seen=$((empty_seen + 1))
        [ "$empty_seen" -ge 2 ] && { rm -rf "$WARP_LOCK" 2>/dev/null; empty_seen=0; }
        ;;
      *)
        empty_seen=0
        kill -0 "$owner" 2>/dev/null || rm -rf "$WARP_LOCK" 2>/dev/null
        ;;
    esac
    attempts=$((attempts + 1))
    [ "$attempts" -ge 50 ] && return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$WARP_LOCK/pid" || { rm -rf "$WARP_LOCK" 2>/dev/null; return 1; }
  WARP_LOCK_DEPTH=1
  return 0
}

release_warp_lock() {
  [ "$WARP_LOCK_DEPTH" -gt 0 ] 2>/dev/null || return 0
  WARP_LOCK_DEPTH=$((WARP_LOCK_DEPTH - 1))
  if [ "$WARP_LOCK_DEPTH" -eq 0 ] 2>/dev/null && [ "$(cat "$WARP_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$WARP_LOCK" 2>/dev/null
  fi
}


# ------------------------------------------------------------------------------
# Проверка наличия и парсинг профилей (/ru/ для AWG99, /geo/ для AWG98, Free WARP)
# ------------------------------------------------------------------------------
is_valid_wg_conf() {
  local file="$1"
  [ -n "$file" ] && [ -s "$file" ] || return 1
  grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=' "$file" 2>/dev/null || return 1
  grep -Eq '^[[:space:]]*Address[[:space:]]*=' "$file" 2>/dev/null || return 1
  return 0
}

find_sorted_conf_in_dirs() {
  local exclude_pattern="$1"
  shift
  local dir file fnames="" fname
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*.conf; do
      [ -f "$file" ] || continue
      fname=$(basename "$file")
      if [ -n "$exclude_pattern" ] && [ "$fname" = "$exclude_pattern" ]; then
        continue
      fi
      fnames="$fnames $file"
    done
  done

  if [ -n "$fnames" ]; then
    for file in $(printf '%s\n' $fnames | LC_ALL=C sort); do
      if is_valid_wg_conf "$file"; then
        printf '%s\n' "$file"
        return 0
      fi
    done
  fi
  return 1
}

# --- AWG99 (RU / Main): Приоритет №1 Пользовательские конфиги (по алфавиту) -> Приоритет №2 ecubz_warp.conf ---
get_warp99_profile_path() {
  local psrc
  # 1. Сначала пользовательские конфиги по алфавиту (исключая ecubz_warp.conf)
  psrc=$(find_sorted_conf_in_dirs "ecubz_warp.conf" "$RU_CONF_DIR" "$RU_MOD_DIR" "/data/adb/zapret2/ru")
  if [ -n "$psrc" ] && [ -s "$psrc" ]; then
    printf '%s\n' "$psrc"
    return 0
  fi

  # 2. Затем ecubz_warp.conf при его наличии
  if [ -s "$RU_CONF_DIR/ecubz_warp.conf" ] && is_valid_wg_conf "$RU_CONF_DIR/ecubz_warp.conf"; then
    printf '%s\n' "$RU_CONF_DIR/ecubz_warp.conf"
    return 0
  fi
  if [ -s "$RU_MOD_DIR/ecubz_warp.conf" ] && is_valid_wg_conf "$RU_MOD_DIR/ecubz_warp.conf"; then
    printf '%s\n' "$RU_MOD_DIR/ecubz_warp.conf"
    return 0
  fi
  if [ -s "$STATE_DIR/ecubz_warp.conf" ] && is_valid_wg_conf "$STATE_DIR/ecubz_warp.conf"; then
    printf '%s\n' "$STATE_DIR/ecubz_warp.conf"
    return 0
  fi
  if [ -s "$WARP_CONF" ] && is_valid_wg_conf "$WARP_CONF"; then
    printf '%s\n' "$WARP_CONF"
    return 0
  fi
  return 1
}

detect_warp99_profile_type() {
  local psrc
  psrc=$(get_warp99_profile_path)
  if [ -n "$psrc" ] && [ -s "$psrc" ]; then
    printf 'custom_ru\n'
    return 0
  fi
  printf '\n'
  return 1
}

# --- AWG98 (Geo): Все конфиги из /geo/ с поддержкой ротации и отказоустойчивости ---
get_geo98_all_confs() {
  local dir file fnames=""
  for dir in "$GEO_CONF_DIR" "$GEO_MOD_DIR" "/data/adb/zapret2/geo"; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*.conf; do
      [ -f "$file" ] || continue
      is_valid_wg_conf "$file" || continue
      fnames="$fnames $file"
    done
  done
  [ -n "$fnames" ] && printf '%s\n' $fnames | LC_ALL=C sort -u || true
}

get_geo98_profile_path() {
  local active
  active=$(cat "$STATE_DIR/geo-active.file" 2>/dev/null | tr -d '\r\n')
  if [ -n "$active" ] && [ -s "$active" ] && is_valid_wg_conf "$active"; then
    printf '%s\n' "$active"
    return 0
  fi
  local all
  all=$(get_geo98_all_confs)
  local first
  first=$(printf '%s\n' "$all" | head -n1)
  if [ -n "$first" ] && [ -s "$first" ]; then
    printf '%s\n' "$first" > "$STATE_DIR/geo-active.file" 2>/dev/null
    printf '%s\n' "$first"
    return 0
  fi
  return 1
}

rotate_geo98_profile() {
  local all cur next="" found=0
  all=$(get_geo98_all_confs)
  [ -n "$all" ] || return 1
  cur=$(cat "$STATE_DIR/geo-active.file" 2>/dev/null | tr -d '\r\n')
  
  local first=""
  for f in $all; do
    [ -z "$first" ] && first="$f"
    if [ "$found" -eq 1 ]; then
      next="$f"
      break
    fi
    if [ "$f" = "$cur" ]; then
      found=1
    fi
  done
  
  [ -z "$next" ] && next="$first"
  printf '%s\n' "$next" > "$STATE_DIR/geo-active.file" 2>/dev/null
  log_i "AWG98: переключение на следующий профиль $(basename "$next")"
  return 0
}

detect_geo98_profile_type() {
  local psrc
  psrc=$(get_geo98_profile_path)
  if [ -n "$psrc" ] && [ -s "$psrc" ]; then
    printf 'custom_geo\n'
    return 0
  fi
  printf '\n'
  return 1
}

# Обратная совместимость


build_conf_from_file() {
  local src="$1" kind="$2" dst_conf="$3" type_file="$4" type_label="$5"
  [ -n "$src" ] && [ -s "$src" ] || return 1

  local privkey address dns peer_pubkey allowed_ips endpoint keepalive reserved preshared_key
  local c_jc c_jmin c_jmax c_s1 c_s2 c_s3 c_s4 c_h1 c_h2 c_h3 c_h4 c_i1 c_i2 c_i3 c_i4 c_i5 c_mtu

  privkey=$(grep -E '^[[:space:]]*PrivateKey[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d ' 	
')
  address=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d '
' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  dns=$(grep -E '^[[:space:]]*DNS[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d '
' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  reserved=$(grep -E '^[[:space:]]*Reserved[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d '
' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  c_mtu=$(grep -E '^[[:space:]]*MTU[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d ' 	
')

  peer_pubkey=$(grep -E '^[[:space:]]*PublicKey[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d ' 	
')
  allowed_ips=$(grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d '
' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  endpoint=$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d ' 	
')
  keepalive=$(grep -E '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d ' 	
')
  preshared_key=$(grep -E '^[[:space:]]*PresharedKey[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | tr -d ' 	
')

  # AmneziaWG параметры обфускации (если указан диапазон A-B, берем начальное значение A)
  c_jc=$(grep -E '^[[:space:]]*Jc[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')
  c_jmin=$(grep -E '^[[:space:]]*Jmin[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')
  c_jmax=$(grep -E '^[[:space:]]*Jmax[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')
  c_s1=$(grep -E '^[[:space:]]*S1[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')
  c_s2=$(grep -E '^[[:space:]]*S2[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')
  c_s3=$(grep -E '^[[:space:]]*S3[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')
  c_s4=$(grep -E '^[[:space:]]*S4[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | awk -F'-' '{print $1}' | tr -cd '0-9')

  c_h1=$(grep -E '^[[:space:]]*H1[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_h2=$(grep -E '^[[:space:]]*H2[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_h3=$(grep -E '^[[:space:]]*H3[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_h4=$(grep -E '^[[:space:]]*H4[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')

  c_i1=$(grep -E '^[[:space:]]*I1[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_i2=$(grep -E '^[[:space:]]*I2[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_i3=$(grep -E '^[[:space:]]*I3[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_i4=$(grep -E '^[[:space:]]*I4[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
  c_i5=$(grep -E '^[[:space:]]*I5[[:space:]]*=' "$src" | head -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')

  [ -n "$privkey" ] && [ -n "$address" ] || return 1
  [ -n "$peer_pubkey" ] || peer_pubkey="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
  [ -n "$allowed_ips" ] || allowed_ips="0.0.0.0/0, ::/0"
  [ -n "$endpoint" ] || endpoint="${WARP_ENDPOINT:-162.159.192.1}:${WARP_PORT:-500}"
  [ -n "$dns" ] || dns="1.1.1.1, 1.0.0.1"
  [ -n "$keepalive" ] || keepalive="25"

  [ -n "$c_jc" ] || c_jc="0"
  [ -n "$c_jmin" ] || c_jmin="0"
  [ -n "$c_jmax" ] || c_jmax="0"
  [ -n "$c_s1" ] || c_s1="0"
  [ -n "$c_s2" ] || c_s2="0"
  [ -n "$c_h1" ] || c_h1="1"
  [ -n "$c_h2" ] || c_h2="2"
  [ -n "$c_h3" ] || c_h3="3"
  [ -n "$c_h4" ] || c_h4="4"

  [ -n "$type_label" ] || type_label="$(basename "$src")"

  local tmp_conf="$dst_conf.tmp.$$"
  {
    echo "[Interface]"
    echo "PrivateKey = $privkey"
    echo "Address = $address"
    echo "DNS = $dns"
    [ -n "$c_mtu" ] && echo "MTU = $c_mtu"
    [ -n "$reserved" ] && echo "Reserved = $reserved"
    echo "Jc = $c_jc"
    echo "Jmin = $c_jmin"
    echo "Jmax = $c_jmax"
    echo "S1 = $c_s1"
    echo "S2 = $c_s2"
    [ -n "$c_s3" ] && echo "S3 = $c_s3"
    [ -n "$c_s4" ] && echo "S4 = $c_s4"
    echo "H1 = $c_h1"
    echo "H2 = $c_h2"
    echo "H3 = $c_h3"
    echo "H4 = $c_h4"
    [ -n "$c_i1" ] && echo "I1 = $c_i1"
    [ -n "$c_i2" ] && echo "I2 = $c_i2"
    [ -n "$c_i3" ] && echo "I3 = $c_i3"
    [ -n "$c_i4" ] && echo "I4 = $c_i4"
    [ -n "$c_i5" ] && echo "I5 = $c_i5"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $peer_pubkey"
    [ -n "$preshared_key" ] && echo "PresharedKey = $preshared_key"
    echo "AllowedIPs = $allowed_ips"
    echo "Endpoint = $endpoint"
    echo "PersistentKeepalive = $keepalive"
  } > "$tmp_conf" || { rm -f "$tmp_conf"; return 1; }

  chmod 0600 "$tmp_conf" || { rm -f "$tmp_conf"; return 1; }
  mv -f "$tmp_conf" "$dst_conf" || { rm -f "$tmp_conf"; return 1; }
  [ -n "$type_file" ] && echo "$type_label" > "$type_file" 2>/dev/null
  log_i "Профиль $type_label успешно сконфигурирован: $dst_conf"
  return 0
}

# --- Генерация конфига AWG98 (Geo) ---
generate_geo98_config() {
  local psrc fname
  psrc=$(get_geo98_profile_path)
  [ -n "$psrc" ] && [ -s "$psrc" ] || return 1
  fname=$(basename "$psrc")
  build_conf_from_file "$psrc" "custom_geo" "$GEO_CONF" "$GEO_PROFILE_TYPE" "$fname"
}

# --- Генерация конфига AWG99 (RU / WARP) ---
generate_warp_config() {
  if [ "${WARP_PROFILE_MODE:-auto}" != "free" ]; then
    local psrc fname
    psrc=$(get_warp99_profile_path)
    if [ -n "$psrc" ] && [ -s "$psrc" ]; then
      fname=$(basename "$psrc")
      log_i "AWG99: обнаружен кастомный профиль из /ru/: $psrc"
      if build_conf_from_file "$psrc" "custom_ru" "$WARP_CONF" "$WARP_PROFILE_TYPE" "$fname"; then
        return 0
      fi
    fi
  fi

  if [ "${WARP_PROFILE_MODE:-auto}" = "custom" ]; then
    log_e "Режим WARP_PROFILE_MODE=custom, но валидный конфиг в /ru/ не найден"
    return 1
  fi

  # 2. Если уже есть существующий рабочий конфиг
  if [ -s "$WARP_CONF" ]; then
    [ -f "$WARP_PROFILE_TYPE" ] || echo "Free WARP" > "$WARP_PROFILE_TYPE" 2>/dev/null
    return 0
  fi

  log_i "Генерация нового персонального WARP-профиля на этом устройстве..."
  local privkey="" pubkey="" client_v4="" client_v6="" peer_pubkey="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

  if [ -x "$BIN_DIR/awg" ]; then
    privkey=$("$BIN_DIR/awg" genkey 2>/dev/null)
    pubkey=$(printf '%s\n' "$privkey" | "$BIN_DIR/awg" pubkey 2>/dev/null)
  fi

  if [ -z "$privkey" ] || [ -z "$pubkey" ]; then
    log_e "Не удалось сгенерировать криптографические ключи через $BIN_DIR/awg"
    return 1
  fi

  # Персональные значения создаются на устройстве. Никаких install_id/fcm_token
  # из прошитой статики в модуле нет.
  random_alnum() {
    local n="$1" out=""
    out=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n")
    [ "${#out}" -eq "$n" ] 2>/dev/null || return 1
    printf '%s' "$out"
  }

  # Cloudflare Client API не является частью AWG. Он нужен только для того,
  # чтобы сервер WARP узнал public key этого конкретного телефона и выдал
  # адреса/peer key. Если регистрация не состоялась, фальшивый warp.conf не создаём.
  local reg_success=0 reg_resp="" reg_endpoint="" reg_id="" token="" warp_enabled=""
  local install_id="" fcm_suffix="" fcm_token="" now_iso="" payload=""
  if command -v curl >/dev/null 2>&1; then
    install_id=$(random_alnum 22 2>/dev/null)
    fcm_suffix=$(random_alnum 134 2>/dev/null)
    if [ -n "$install_id" ] && [ -n "$fcm_suffix" ]; then
      fcm_token="${install_id}:APA91b${fcm_suffix}"
      now_iso=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null)
      [ -n "$now_iso" ] || now_iso="2026-01-01T00:00:00.000Z"
      payload="{\"key\":\"$pubkey\",\"install_id\":\"$install_id\",\"fcm_token\":\"$fcm_token\",\"tos\":\"$now_iso\",\"model\":\"Android\",\"serial_number\":\"$install_id\",\"locale\":\"en_US\"}"

      for cf_endpoint in \
        "https://api.cloudflareclient.com/v0a2158/reg" \
        "https://api.cloudflareclient.com/v0a2405/reg" \
        "https://api.cloudflareclient.com/v0a3121/reg"
      do
        reg_resp=$(curl -4 -fsS -m 8 -X POST \
          -H "CF-Client-Version: a-6.10-2158" \
          -H "Content-Type: application/json; charset=UTF-8" \
          -H "User-Agent: okhttp/3.12.1" \
          -d "$payload" "$cf_endpoint" 2>/dev/null) || reg_resp=""
        if printf '%s' "$reg_resp" | grep -q '"id"'; then
          reg_endpoint="$cf_endpoint"
          break
        fi

        # DNS самого API тоже может быть недоступен. --resolve сохраняет TLS/SNI
        # и проверку сертификата, меняется только способ достижения адреса.
        for cf_ip in 162.159.192.1 162.159.193.1 104.16.124.96 104.16.123.96 188.114.97.1; do
          reg_resp=$(curl -4 -fsS -m 8 \
            --resolve "api.cloudflareclient.com:443:$cf_ip" \
            -X POST \
            -H "CF-Client-Version: a-6.10-2158" \
            -H "Content-Type: application/json; charset=UTF-8" \
            -H "User-Agent: okhttp/3.12.1" \
            -d "$payload" "$cf_endpoint" 2>/dev/null) || reg_resp=""
          if printf '%s' "$reg_resp" | grep -q '"id"'; then
            reg_endpoint="$cf_endpoint"
            break 2
          fi
        done
      done
    fi
  fi

  if [ -n "$reg_endpoint" ] && printf '%s' "$reg_resp" | grep -q '"id"'; then
    reg_id=$(printf '%s' "$reg_resp" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    token=$(printf '%s' "$reg_resp" | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    client_v4=$(printf '%s' "$reg_resp" | grep -o '"v4"[[:space:]]*:[[:space:]]*"172\.[^"]*"' | tail -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    client_v6=$(printf '%s' "$reg_resp" | grep -o '"v6"[[:space:]]*:[[:space:]]*"2606:4700:[^"]*"' | tail -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    # В ответе API может быть несколько public_key. Нужен ключ именно WARP peer,
    # а не клиентский/account key. Берём первый public_key после секции peers;
    # если формат API изменился, оставляем общеизвестный consumer WARP peer key.
    local peer_blob parsed_peer
    peer_blob=${reg_resp#*\"peers\"}
    if [ "$peer_blob" != "$reg_resp" ]; then
      parsed_peer=$(printf '%s' "$peer_blob" | grep -o '"public_key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
      [ -n "$parsed_peer" ] && peer_pubkey="$parsed_peer"
    fi
    warp_enabled=$(printf '%s' "$reg_resp" | grep -o '"warp_enabled"[[:space:]]*:[[:space:]]*[^,}]*' | head -n1 | cut -d: -f2 | tr -d '[:space:]')

    if [ "$warp_enabled" != "true" ]; then
      local patch_success=0
      if [ -n "$reg_id" ] && [ -n "$token" ]; then
        if curl -4 -fsS -m 8 -X PATCH \
          -H "CF-Client-Version: a-6.10-2158" \
          -H "Content-Type: application/json; charset=UTF-8" \
          -H "Authorization: Bearer $token" \
          -H "User-Agent: okhttp/3.12.1" \
          -d '{"warp_enabled":true}' "$reg_endpoint/$reg_id" >/dev/null 2>&1; then
          patch_success=1
        else
          for cf_ip in 162.159.192.1 162.159.193.1 104.16.124.96 104.16.123.96 188.114.97.1; do
            if curl -4 -fsS -m 8 \
              --resolve "api.cloudflareclient.com:443:$cf_ip" \
              -X PATCH \
              -H "CF-Client-Version: a-6.10-2158" \
              -H "Content-Type: application/json; charset=UTF-8" \
              -H "Authorization: Bearer $token" \
              -H "User-Agent: okhttp/3.12.1" \
              -d '{"warp_enabled":true}' "$reg_endpoint/$reg_id" >/dev/null 2>&1; then
              patch_success=1
              break
            fi
          done
        fi
      fi
      if [ "$patch_success" -eq 1 ]; then
        warp_enabled=true
      else
        log_e "WARP registration получена, но warp_enabled не удалось активировать"
      fi
    fi

    if [ -n "$client_v4" ] && [ -n "$peer_pubkey" ] && [ "$warp_enabled" = "true" ]; then
      reg_success=1
    fi
  fi

  if [ "$reg_success" -ne 1 ]; then
    log_e "Не удалось зарегистрировать новый WARP public key. warp.conf не создаётся, чтобы не оставлять заведомо нерабочий профиль"
    return 1
  fi

  # Стартовый профиль совместим с обычным WireGuard peer Cloudflare:
  # S1-S4=0 и H1-H4=1..4 не меняем автоматически. Клиентские J-параметры
  # адаптируются отдельно. I1-I5 добавляются только после неудач BASIC-режима.
  local tmp_conf="$WARP_CONF.tmp.$$"
  cat <<EOF > "$tmp_conf"
[Interface]
PrivateKey = $privkey
Address = ${client_v4}/32${client_v6:+, $client_v6/128}
DNS = 1.1.1.1, 1.0.0.1
Jc = $WARP_JC
Jmin = $WARP_JMIN
Jmax = $WARP_JMAX
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = $peer_pubkey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${WARP_ENDPOINT}:${WARP_PORT}
PersistentKeepalive = 15
EOF

  chmod 0600 "$tmp_conf" || { rm -f "$tmp_conf"; return 1; }
  mkdir -p "$RU_CONF_DIR" 2>/dev/null || true
  cp -f "$tmp_conf" "$RU_CONF_DIR/ecubz_warp.conf" 2>/dev/null || true
  chmod 0600 "$RU_CONF_DIR/ecubz_warp.conf" 2>/dev/null || true
  mv -f "$tmp_conf" "$WARP_CONF" || { rm -f "$tmp_conf"; return 1; }
  rm -f "$WARP_ADAPT_STATE" 2>/dev/null
  echo "ecubz_warp.conf" > "$WARP_PROFILE_TYPE" 2>/dev/null
  log_i "Новый персональный Free WARP-профиль зарегистрирован и сохранён: $RU_CONF_DIR/ecubz_warp.conf"
  return 0
}

# ------------------------------------------------------------------------------
# Сбор UID приложений из списков (Multi-User aware)
# ------------------------------------------------------------------------------
# Список приложений для туннеля удалён: маршрутизация идёт по доменам и
# подсетям (warp_domains.list, warp_bypass_nets.list), а не по UID.

# ------------------------------------------------------------------------------
# Управление правилами маршрутизации (Policy Routing & Dedicated Chains)
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# Разрешение имени в адреса для маршрутизации домена в туннель.
#
# ОГРАНИЧЕНИЕ, о котором нужно помнить: маршрутизация идёт по IP назначения, а у
# сайтов за CDN адреса меняются и делятся с другими сайтами. Поэтому список
# перечитывается при каждой синхронизации и при смене сети, а сюда стоит вносить
# только то, что иначе не работает вовсе.
# ------------------------------------------------------------------------------
resolve_domain_addrs() {
  local host="$1" family="${2:-4}" query answer out="" server dns_servers dev_src provider provider_ip provider_host
  case "$host" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac

  query="$RUN_DIR/warp-dns-${family}-$$.q"
  answer="$RUN_DIR/warp-dns-${family}-$$.a"

  # Шаг 1. Пытаемся разрешить через mdig и надёжные DNS самого туннеля
  if [ -x "$BIN_DIR/mdig" ]; then
    if [ "$family" = 6 ] && ! ip -6 route show default >/dev/null 2>&1; then
      return 1
    fi
    if "$BIN_DIR/mdig" --family="$family" --dns-make-query="$host" > "$query" 2>/dev/null; then
      dns_servers="1.1.1.1 8.8.8.8"
      [ "$family" = 6 ] && dns_servers="2606:4700:4700::1111 2001:4860:4860::8888"

      for server in $dns_servers; do
        : > "$answer"
        if [ "$family" = 6 ]; then
          if timeout 1 nc -6 -u -q 1 -W 1 "$server" 53 < "$query" > "$answer" 2>/dev/null; then
            out=$("$BIN_DIR/mdig" --dns-parse-query < "$answer" 2>/dev/null | sed -n '/:/p' | sort -u | head -n4)
            [ -n "$out" ] && break
          fi
        else
          if timeout 1 nc -u -q 1 -W 1 "$server" 53 < "$query" > "$answer" 2>/dev/null; then
            out=$("$BIN_DIR/mdig" --dns-parse-query < "$answer" 2>/dev/null | sed -n '/^[0-9][0-9.]*$/p' | sort -u | head -n8)
            [ -n "$out" ] && break
          fi
        fi
      done
      rm -f "$query" "$answer" 2>/dev/null
    fi
  fi

  # Шаг 2. Fallback на системный ping/ping6, если mdig/DoH недоступен
  if [ -z "$out" ]; then
    if [ "$family" = 6 ]; then
      out=$(ping6 -c1 -w2 "$host" 2>/dev/null | sed -n 's/^PING [^(]*(\([0-9a-fA-F:]*\)).*/\1/p' | head -n1)
    else
      out=$(ping -c1 -w2 "$host" 2>/dev/null | sed -n 's/^PING [^(]*(\([0-9.]*\)).*/\1/p' | head -n1)
    fi
  fi

  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Домены, которые уводятся в туннель: заданные вручную плюс добавленные
# автоматически (не поддались ни одной стратегии обхода).
# ------------------------------------------------------------------------------
# Сбор доменов и подсетей для AWG98 (Geo) и AWG99 (WARP)
# ------------------------------------------------------------------------------
collect_geo_domains() {
  local list line
  for list in "$GEO_DOMAINS_FILE" "$LISTS_DIR/geo_warp.user.list" "$STATE_DIR/geo_auto_domains.list"; do
    [ -f "$list" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '\r')
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      case "$line" in *[!A-Za-z0-9.-]*) continue ;; esac
      printf '%s\n' "$line"
    done < "$list"
  done | awk 'NF && !seen[$0]++'
}

collect_warp_domains() {
  local list line
  for list in "$WARP_DOMAINS_FILE" "$STATE_DIR/warp_auto_domains.list"; do
    [ -f "$list" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '\r')
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      case "$line" in *[!A-Za-z0-9.-]*) continue ;; esac
      printf '%s\n' "$line"
    done < "$list"
  done | awk 'NF && !seen[$0]++'
}

# Подсети из общего файла.
collect_warp_bypass_nets() {
  local family="$1" line file="$LISTS_DIR/warp_bypass_nets.list"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    case "$line" in *[!0-9A-Fa-f.:/]*) continue ;; esac
    if [ "$family" = 6 ]; then
      case "$line" in *:*) printf '%s\n' "$line" ;; esac
    else
      case "$line" in *:*) ;; *) printf '%s\n' "$line" ;; esac
    fi
  done < "$file"
}

# ==============================================================================
# Живость туннеля
# ==============================================================================
warp_data_flows() {
  local target="${WARP_HEALTH_PROBE_IP:-1.1.1.1}" timeout="${WARP_HEALTH_PROBE_TIMEOUT:-4}" tries="${WARP_HEALTH_PROBE_TRIES:-3}" n=0
  command -v ping >/dev/null 2>&1 || return 0
  case "$timeout" in ''|*[!0-9]*) timeout=4 ;; esac
  case "$tries" in ''|*[!0-9]*) tries=3 ;; esac
  [ "$tries" -ge 1 ] 2>/dev/null || tries=1
  while [ "$n" -lt "$tries" ]; do
    if ping -c1 -W"$timeout" -I "$DEV" "$target" >/dev/null 2>&1; then
      return 0
    fi
    n=$((n + 1))
    [ "$n" -lt "$tries" ] && sleep 0.2 2>/dev/null || true
  done
  return 1
}

underlay_available() {
  local dev
  dev=$(ip -4 route get "${WARP_ENDPOINT:-162.159.192.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$dev" ] || return 1
  [ "$dev" != "$DEV" ] || return 1
  return 0
}

warp_tunnel_healthy() {
  local hs now diff
  WARP_HEALTH_REASON=""
  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    WARP_HEALTH_REASON="интерфейс $DEV отсутствует"; return 1
  fi
  hs=$(get_latest_handshake_epoch)
  case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
  if [ "$hs" -le 0 ] 2>/dev/null; then
    WARP_HEALTH_REASON="handshake отсутствует"; return 1
  fi
  now=$(date +%s 2>/dev/null || echo 0)
  diff=$((now - hs))
  if [ "$diff" -lt 0 ] 2>/dev/null || [ "$diff" -ge "${WARP_HEALTH_MAX_AGE:-180}" ] 2>/dev/null; then
    if warp_data_flows; then
      return 0
    fi
    WARP_HEALTH_REASON="handshake устарел на ${diff}с, и данные сквозь туннель не проходят"
    return 1
  fi

  if ! warp_data_flows; then
    WARP_HEALTH_REASON="рукопожатие есть, но данные сквозь туннель не проходят"
    return 1
  fi
  return 0
}

geo_tunnel_healthy() {
  local hs now diff rx
  GEO_HEALTH_REASON=""
  if ! ip link show dev "$GEO_DEV" >/dev/null 2>&1; then
    GEO_HEALTH_REASON="интерфейс $GEO_DEV отсутствует"
    return 1
  fi
  local raw
  raw=$(awg_cmd show "$GEO_DEV" 2>/dev/null) || raw=""
  hs=$(printf '%s\n' "$raw" | sed -n 's/^last_handshake_time_sec=//p' | head -n1)
  rx=$(printf '%s\n' "$raw" | sed -n 's/^rx_bytes=//p' | head -n1)
  case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
  case "$rx" in ''|*[!0-9]*) rx=0 ;; esac

  if [ "$hs" -le 0 ] 2>/dev/null; then
    GEO_HEALTH_REASON="handshake отсутствует"
    return 1
  fi
  now=$(date +%s 2>/dev/null || echo 0)
  diff=$((now - hs))
  if [ "$diff" -lt 0 ] 2>/dev/null || [ "$diff" -ge "${WARP_HEALTH_MAX_AGE:-180}" ] 2>/dev/null; then
    if ping -c 1 -W 2 -I "$GEO_DEV" 1.1.1.1 >/dev/null 2>&1; then
      return 0
    fi
    GEO_HEALTH_REASON="handshake устарел на ${diff}с"
    return 1
  fi
  if [ "$rx" -le 0 ] 2>/dev/null; then
    if ! ping -c 1 -W 2 -I "$GEO_DEV" 1.1.1.1 >/dev/null 2>&1; then
      GEO_HEALTH_REASON="нет входящего трафика (rx_bytes=0)"
      return 1
    fi
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Маршрутизация приложений из apps_black.list строго через туннель AWG98 + Killswitch
# ------------------------------------------------------------------------------
collect_apps_black() {
  local f="$APPS_BLACK_FILE"
  [ -f "$f" ] || f="$MODDIR/lists/apps_black.list"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sort -u
}

get_apps_black_uids() {
  local uids="" item pkg uid udir all_pkgs=""

  for item in $(collect_apps_black); do
    [ -n "$item" ] || continue
    case "$item" in
      ''|'#'*) continue ;;
      *[!0-9]*)
        all_pkgs="$all_pkgs $item"
        ;;
      *)
        uids="$uids $item"
        ;;
    esac
  done

  if [ -n "$all_pkgs" ]; then
    for pkg in $all_pkgs; do
      uid=""
      # 1. Поиск в /data/system/packages.list
      if [ -f /data/system/packages.list ]; then
        uid=$(awk -v p="$pkg" '$1 == p { print $2; exit }' /data/system/packages.list 2>/dev/null)
      fi
      # 2. Поиск по stat директории пакета
      if [ -z "$uid" ] && [ -d "/data/data/$pkg" ]; then
        uid=$(stat -c %u "/data/data/$pkg" 2>/dev/null)
      fi
      if [ -z "$uid" ]; then
        for udir in /data/user/*/"$pkg"; do
          if [ -d "$udir" ]; then
            uid=$(stat -c %u "$udir" 2>/dev/null)
            [ -n "$uid" ] && break
          fi
        done
      fi
      # 3. Индивидуальный fallback через pm list packages -U
      if [ -z "$uid" ] && command -v pm >/dev/null 2>&1; then
        uid=$(pm list packages -U 2>/dev/null | awk -v p="package:$pkg" '$1 == p { split($2, a, ":"); print a[2]; exit }')
      fi
      case "$uid" in [0-9]*) uids="$uids $uid" ;; esac
    done
  fi

  printf '%s\n' $uids | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}

start_z2netd() {
  local iface="${1:-}"
  stop_z2netd
  [ -x "$Z2NETD_BIN" ] || return 0

  if [ -n "$iface" ]; then
    "$Z2NETD_BIN" -d -4 -p "$Z2NETD_PORT" -u 1.1.1.1 -P 53 -i "$iface" >/dev/null 2>&1
  else
    "$Z2NETD_BIN" -d -4 -p "$Z2NETD_PORT" -u 1.1.1.1 -P 53 >/dev/null 2>&1
  fi
  sleep 0.2
  local actual_pid=$(pgrep z2netd 2>/dev/null | head -n1)
  [ -n "$actual_pid" ] || actual_pid=$(pidof z2netd 2>/dev/null | awk '{print $1}')
  if [ -n "$actual_pid" ]; then
    echo "$actual_pid" > "$Z2NETD_PID" 2>/dev/null || true
    log_i "z2netd started (PID: $actual_pid, port: $Z2NETD_PORT, iface: ${iface:-default}, filter-aaaa: ON)"
  fi
}

stop_z2netd() {
  if [ -f "$Z2NETD_PID" ]; then
    local p=$(cat "$Z2NETD_PID" 2>/dev/null)
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    rm -f "$Z2NETD_PID" 2>/dev/null || true
  fi
  pkill -9 z2netd 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Симметричные функции управления сетевыми правилами (DRY / SSOT)
# ------------------------------------------------------------------------------

# 1. Исключение UID приложений apps_black из AntiDPI через подцепочку ZAPRET2_APPS_BYPASS
antidpi_bypass_uid() {
  local op="$1" uid="$2"
  case "$op" in
    add)
      iptables -w 5 -t mangle -A ZAPRET2_APPS_BYPASS -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
      ;;
    del)
      iptables -w 5 -t mangle -D ZAPRET2_APPS_BYPASS -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
      ;;
  esac
}

# 2. Killswitch для UID приложений apps_black (RAW + FILTER + DoT block)
apps_killswitch_rule() {
  local op="$1" uid="$2"
  case "$op" in
    add)
      # Блокировка DoT (порт 853), форсирующая fallback на стандартный DNS (порт 53)
      iptables -w 5 -t filter -A ZAPRET2_APPS_KILL -p tcp --dport 853 -m owner --uid-owner "$uid" -j REJECT --reject-with tcp-reset 2>/dev/null || true
      iptables -w 5 -t filter -A ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || \
        iptables -w 5 -t filter -A ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j DROP 2>/dev/null || true
      ip6tables -w 5 -t raw -A ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j DROP 2>/dev/null || true
      ip6tables -w 5 -t filter -A ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || \
        ip6tables -w 5 -t filter -A ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j DROP 2>/dev/null || true
      ;;
    del)
      iptables -w 5 -t filter -D ZAPRET2_APPS_KILL -p tcp --dport 853 -m owner --uid-owner "$uid" -j REJECT --reject-with tcp-reset 2>/dev/null || true
      iptables -w 5 -t filter -D ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || \
        iptables -w 5 -t filter -D ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j DROP 2>/dev/null || true
      ip6tables -w 5 -t raw -D ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j DROP 2>/dev/null || true
      ip6tables -w 5 -t filter -D ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || \
        ip6tables -w 5 -t filter -D ZAPRET2_APPS_KILL -m owner --uid-owner "$uid" -j DROP 2>/dev/null || true
      ;;
  esac
}

# 5. Маршрутизация по адресу назначения (IPv4 / IPv6)
dest_rule_op() {
  local op="$1" fam="$2" addr="$3" table="$4" pref="$5"
  case "$op" in
    add)
      local err
      err=$(ip -"$fam" rule add to "$addr" lookup "$table" pref "$pref" 2>&1) && return 0
      case "$err" in *"File exists"*) return 0 ;; esac
      return 1
      ;;
    del)
      ip -"$fam" rule del to "$addr" lookup "$table" pref "$pref" 2>/dev/null || true
      ;;
  esac
}

add_dest_rule() {
  dest_rule_op add "$1" "$2" "$3" "$4"
}

del_dest_rule() {
  dest_rule_op del "$1" "$2" "$3" "$4"
}

remove_apps_black_rules() {
  local fam pref target table
  if [ -f "$APPS_BLACK_RULE_STATE" ]; then
    while IFS='|' read -r fam pref target table; do
      [ -n "$fam" ] && [ -n "$pref" ] || continue
      case "$target" in
        fwmark:*)
          local mark="${target#fwmark:}"
          [ "$fam" = 4 ] && ip -4 rule del pref "$pref" fwmark "$mark" lookup "$table" 2>/dev/null || true
          [ "$fam" = 6 ] && ip -6 rule del pref "$pref" fwmark "$mark" lookup "$table" 2>/dev/null || true
          ;;
        uid:*)
          local uid="${target#uid:}"
          [ "$fam" = 4 ] && ip -4 rule del pref "$pref" uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true
          [ "$fam" = 6 ] && ip -6 rule del pref "$pref" uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true
          ;;
        *)
          if [ -n "$target" ] && [ "$target" -eq "$target" ] 2>/dev/null; then
            [ "$fam" = 4 ] && ip -4 rule del pref "$pref" uidrange "$target-$target" lookup "$table" 2>/dev/null || true
            [ "$fam" = 6 ] && ip -6 rule del pref "$pref" uidrange "$target-$target" lookup "$table" 2>/dev/null || true
          fi
          ;;
      esac
    done < "$APPS_BLACK_RULE_STATE"
    rm -f "$APPS_BLACK_RULE_STATE" 2>/dev/null
  fi

  # Очистка и удаление подцепочки AntiDPI bypass
  del_bounded iptables -w 5 -t mangle -D ZAPRET2_MANGLE -j ZAPRET2_APPS_BYPASS
  iptables -w 5 -t mangle -F ZAPRET2_APPS_BYPASS 2>/dev/null || true
  iptables -w 5 -t mangle -X ZAPRET2_APPS_BYPASS 2>/dev/null || true

  # Очистка и удаление цепочки Mangle-маркировки
  del_bounded iptables -w 5 -t mangle -D OUTPUT -j ZAPRET2_APPS_MARK
  iptables -w 5 -t mangle -F ZAPRET2_APPS_MARK 2>/dev/null || true
  iptables -w 5 -t mangle -X ZAPRET2_APPS_MARK 2>/dev/null || true

  # Снятие DNS-перенаправления
  del_bounded iptables -w 5 -t nat -D OUTPUT -j ZAPRET2_APPS_DNS
  iptables -w 5 -t nat -F ZAPRET2_APPS_DNS 2>/dev/null || true
  iptables -w 5 -t nat -X ZAPRET2_APPS_DNS 2>/dev/null || true

  del_bounded ip6tables -w 5 -t nat -D OUTPUT -j ZAPRET2_APPS_DNS
  ip6tables -w 5 -t nat -F ZAPRET2_APPS_DNS 2>/dev/null || true
  ip6tables -w 5 -t nat -X ZAPRET2_APPS_DNS 2>/dev/null || true

  # Очистка и удаление Killswitch цепочек (filter + raw)
  del_bounded iptables -w 5 -t filter -D OUTPUT -j ZAPRET2_APPS_KILL
  iptables -w 5 -t filter -F ZAPRET2_APPS_KILL 2>/dev/null || true
  iptables -w 5 -t filter -X ZAPRET2_APPS_KILL 2>/dev/null || true

  del_bounded ip6tables -w 5 -t filter -D OUTPUT -j ZAPRET2_APPS_KILL
  ip6tables -w 5 -t filter -F ZAPRET2_APPS_KILL 2>/dev/null || true
  ip6tables -w 5 -t filter -X ZAPRET2_APPS_KILL 2>/dev/null || true

  del_bounded ip6tables -w 5 -t raw -D OUTPUT -j ZAPRET2_APPS_KILL
  ip6tables -w 5 -t raw -F ZAPRET2_APPS_KILL 2>/dev/null || true
  ip6tables -w 5 -t raw -X ZAPRET2_APPS_KILL 2>/dev/null || true

  stop_z2netd
}

apply_apps_black_rules() {
  local target_table target_pref target_dev uid count=0 uids
  remove_apps_black_rules

  uids=$(get_apps_black_uids)
  [ -n "$uids" ] || return 0

  target_table="$GEO_ROUTE_TABLE"
  target_pref="$PREF_APPS_GEO"
  target_dev="$GEO_DEV"

  : > "$APPS_BLACK_RULE_STATE.tmp.$$" 2>/dev/null || true

  # 1. Mangle цепочка 2-го прохода (маркировка сокетов целевых UID):
  iptables -w 5 -t mangle -N ZAPRET2_APPS_MARK 2>/dev/null || true
  iptables -w 5 -t mangle -F ZAPRET2_APPS_MARK 2>/dev/null || true
  iptables -w 5 -t mangle -C OUTPUT -j ZAPRET2_APPS_MARK 2>/dev/null || \
    iptables -w 5 -t mangle -I OUTPUT 1 -j ZAPRET2_APPS_MARK 2>/dev/null || true

  # 2. Подцепочка AntiDPI bypass для целевых UID:
  iptables -w 5 -t mangle -N ZAPRET2_APPS_BYPASS 2>/dev/null || true
  iptables -w 5 -t mangle -F ZAPRET2_APPS_BYPASS 2>/dev/null || true
  iptables -w 5 -t mangle -C ZAPRET2_MANGLE -j ZAPRET2_APPS_BYPASS 2>/dev/null || \
    iptables -w 5 -t mangle -I ZAPRET2_MANGLE 1 -j ZAPRET2_APPS_BYPASS 2>/dev/null || true

  # 3. Killswitch в iptables (filter):
  # Разрешен выход на lo (DNS к netd/IPC) и строго в интерфейс $GEO_DEV (awg98).
  iptables -w 5 -t filter -N ZAPRET2_APPS_KILL 2>/dev/null || true
  iptables -w 5 -t filter -F ZAPRET2_APPS_KILL 2>/dev/null || true
  iptables -w 5 -t filter -C OUTPUT -j ZAPRET2_APPS_KILL 2>/dev/null || \
    iptables -w 5 -t filter -I OUTPUT 1 -j ZAPRET2_APPS_KILL 2>/dev/null || true

  iptables -w 5 -t filter -A ZAPRET2_APPS_KILL -o lo -j RETURN 2>/dev/null || true
  iptables -w 5 -t filter -A ZAPRET2_APPS_KILL -o "$target_dev" -j RETURN 2>/dev/null || true

  # Исключаем awg98 из AntiDPI mangle
  iptables -w 5 -t mangle -C ZAPRET2_MANGLE -o "$target_dev" -j RETURN 2>/dev/null || \
    iptables -w 5 -t mangle -I ZAPRET2_MANGLE 1 -o "$target_dev" -j RETURN 2>/dev/null || true

  # IPv6 Killswitch (RAW + FILTER): блокировка IPv6 трафика приложений apps_black
  ip6tables -w 5 -t raw -N ZAPRET2_APPS_KILL 2>/dev/null || true
  ip6tables -w 5 -t raw -F ZAPRET2_APPS_KILL 2>/dev/null || true
  ip6tables -w 5 -t raw -C OUTPUT -j ZAPRET2_APPS_KILL 2>/dev/null || \
    ip6tables -w 5 -t raw -I OUTPUT 1 -j ZAPRET2_APPS_KILL 2>/dev/null || true

  ip6tables -w 5 -t filter -N ZAPRET2_APPS_KILL 2>/dev/null || true
  ip6tables -w 5 -t filter -F ZAPRET2_APPS_KILL 2>/dev/null || true
  ip6tables -w 5 -t filter -C OUTPUT -j ZAPRET2_APPS_KILL 2>/dev/null || \
    ip6tables -w 5 -t filter -I OUTPUT 1 -j ZAPRET2_APPS_KILL 2>/dev/null || true

  local geo_is_up=0
  if ip link show dev "$target_dev" >/dev/null 2>&1 && [ "${ENABLE_GEO_WARP:-1}" = "1" ]; then
    geo_is_up=1
  fi

  for uid in $uids; do
    [ -n "$uid" ] || continue

    # 1. Прямой policy routing для сокетов UID (pref 21 -> lookup 11887)
    ip -4 rule add pref "$target_pref" uidrange "$uid-$uid" lookup "$target_table" 2>/dev/null || true
    ip -6 rule add pref "$target_pref" uidrange "$uid-$uid" lookup "$target_table" 2>/dev/null || true
    printf '4|%s|uid:%s|%s\n' "$target_pref" "$uid" "$target_table" >> "$APPS_BLACK_RULE_STATE.tmp.$$" 2>/dev/null
    printf '6|%s|uid:%s|%s\n' "$target_pref" "$uid" "$target_table" >> "$APPS_BLACK_RULE_STATE.tmp.$$" 2>/dev/null

    # 2. Исключение UID из AntiDPI через подцепочку
    antidpi_bypass_uid add "$uid"

    # 3. Killswitch для UID
    apps_killswitch_rule add "$uid"

    count=$((count + 1))
  done

  # 4. DNS перенаправление UDP/53 на локальный демон z2netd (порт 5353) для приложений apps_black:
  if [ "$count" -gt 0 ]; then
    if [ "$geo_is_up" = "1" ] && [ -x "$Z2NETD_BIN" ]; then
      start_z2netd "$target_dev"
      iptables -w 5 -t nat -N ZAPRET2_APPS_DNS 2>/dev/null || true
      iptables -w 5 -t nat -F ZAPRET2_APPS_DNS 2>/dev/null || true
      iptables -w 5 -t nat -C OUTPUT -j ZAPRET2_APPS_DNS 2>/dev/null || \
        iptables -w 5 -t nat -I OUTPUT 1 -j ZAPRET2_APPS_DNS 2>/dev/null || true

      for uid in $uids; do
        [ -n "$uid" ] || continue
        # Только UDP/53 перенаправляется на UDP-демон z2netd (TCP/53 не трогаем во избежание RST)
        iptables -w 5 -t nat -A ZAPRET2_APPS_DNS -p udp --dport 53 -m owner --uid-owner "$uid" -j REDIRECT --to-ports "$Z2NETD_PORT" 2>/dev/null || true
      done
    fi
  fi

  mv -f "$APPS_BLACK_RULE_STATE.tmp.$$" "$APPS_BLACK_RULE_STATE" 2>/dev/null || rm -f "$APPS_BLACK_RULE_STATE.tmp.$$" 2>/dev/null
  chmod 0600 "$APPS_BLACK_RULE_STATE" 2>/dev/null || true

  if [ "$count" -gt 0 ]; then
    if [ "$geo_is_up" = "1" ]; then
      log_i "Apps black 2-pass routing: $count UID(s) -> fwmark=$APPS_ROUTING_MARK/$APPS_ROUTING_MASK pref=$target_pref table=$target_table (Killswitch: ACTIVE, DNS: z2netd, NetId: PRESERVED)"
    else
      log_w "Apps black 2-pass routing: $count UID(s) protected by KILLSWITCH (AWG98 dev=$target_dev is DOWN; traffic strictly blocked)"
    fi
  fi
}

remove_geo_dest_rules() {
  local fam domain addr
  remove_apps_black_rules
  if [ -f "$GEO_DOMAIN_IPS_STATE" ]; then
    while IFS='|' read -r fam domain addr; do
      [ -n "$addr" ] || continue
      case "$addr" in *[!0-9A-Fa-f.:]*) continue ;; esac
      del_dest_rule "$fam" "$addr" "$GEO_ROUTE_TABLE" "$PREF_DEST_GEO"
    done < "$GEO_DOMAIN_IPS_STATE"
    rm -f "$GEO_DOMAIN_IPS_STATE" 2>/dev/null
  fi
}

remove_dest_rules() {
  local subnet fam domain addr
  remove_geo_dest_rules
  remove_apps_black_rules
  for subnet in $(collect_warp_bypass_nets 4); do
    del_dest_rule 4 "$subnet" "$TABLE" "$PREF_DEST_WARP"
  done
  for subnet in $(collect_warp_bypass_nets 6); do
    del_dest_rule 6 "$subnet" "$TABLE" "$PREF_DEST_WARP"
  done
  if [ -f "$WARP_DOMAIN_IPS_STATE" ]; then
    while IFS='|' read -r fam domain addr; do
      [ -n "$addr" ] || continue
      case "$addr" in *[!0-9A-Fa-f.:]*) continue ;; esac
      del_dest_rule "$fam" "$addr" "$TABLE" "$PREF_DEST_WARP"
    done < "$WARP_DOMAIN_IPS_STATE"
    rm -f "$WARP_DOMAIN_IPS_STATE" 2>/dev/null
  fi
}

prune_stale_dest_rules() {
  local old="$1" new="$2" dev="$3" table="$4" pref="$5" wanted="$6"
  local fam domain addr
  [ -f "$old" ] || return 0
  [ -f "$new" ] || return 0
  while IFS='|' read -r fam domain addr; do
    [ -n "$addr" ] || continue
    case "$addr" in *[!0-9A-Fa-f.:]*) continue ;; esac
    awk -F'|' -v f="$fam" -v a="$addr" '$1==f && $3==a {found=1} END{exit !found}' "$new" && continue
    if echo "$wanted" | grep -qxF "$domain" 2>/dev/null; then
      awk -F'|' -v d="$domain" '$2==d {found=1} END{exit !found}' "$new" || continue
    fi
    del_dest_rule "$fam" "$addr" "$table" "$pref"
    if [ "$fam" = 6 ]; then
      ip -6 route del "$addr" dev "$dev" table "$table" 2>/dev/null || true
    else
      ip -4 route del "$addr" dev "$dev" table "$table" 2>/dev/null || true
    fi
  done < "$old"
}

# --- Установка правил маршрутизации AWG98 (Geo) ---
install_geo_dest_rules() {
  local domain addr domain_count=0 addrs
  [ "${ENABLE_GEO_WARP:-1}" = "1" ] || return 0
  ip link show dev "$GEO_DEV" >/dev/null 2>&1 || return 0

  # Принудительная маршрутизация приложений из apps_black.list (включая 4PDA)
  apply_apps_black_rules

  local has_geo_ipv6=0
  if awg_cmd show "$GEO_DEV" allowed-ips 2>/dev/null | grep -qE '::/0|2000::/3'; then
    has_geo_ipv6=1
  fi

  local geo_client_ip
  geo_client_ip=$(ip -4 addr show dev "$GEO_DEV" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)

  # Базовые диапазоны Cloudflare & 4PDA для гарантированного перехвата любых POP в IPv4
  for net in 8.47.0.0/16 8.6.0.0/16 104.16.0.0/12 172.64.0.0/13 108.181.60.0/24 185.165.123.0/24 188.114.96.0/20 190.93.240.0/20 197.234.240.0/22 198.41.128.0/17 31.131.253.250/32 94.130.71.180/32; do
    ip -4 route replace "$net" dev "$GEO_DEV" ${geo_client_ip:+src $geo_client_ip} table "$GEO_ROUTE_TABLE" 2>/dev/null || true
    add_dest_rule 4 "$net" "$GEO_ROUTE_TABLE" "$PREF_DEST_GEO"
  done

  # IPv6 диапазоны Cloudflare направляем в unreachable (полная блокировка утечек IPv6)
  for net in 2a06:98c1::/32 2606:4700::/32 2a06:98c0::/29; do
    ip -6 route replace unreachable "$net" table "$GEO_ROUTE_TABLE" 2>/dev/null || true
    add_dest_rule 6 "$net" "$GEO_ROUTE_TABLE" "$PREF_DEST_GEO"
  done

  find "$STATE_DIR" -maxdepth 1 -name "*-domain-ips.state.tmp.*" -mmin +10 -delete 2>/dev/null || true
  : > "$GEO_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null || true
  for domain in $(collect_geo_domains); do
    addrs=$(resolve_domain_addrs "$domain" 4)
    if [ -n "$addrs" ]; then
      for addr in $addrs; do
        ip -4 route replace "$addr" dev "$GEO_DEV" ${geo_client_ip:+src $geo_client_ip} table "$GEO_ROUTE_TABLE" 2>/dev/null || true
        if add_dest_rule 4 "$addr" "$GEO_ROUTE_TABLE" "$PREF_DEST_GEO"; then
          printf '4|%s|%s\n' "$domain" "$addr" >> "$GEO_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
          domain_count=$((domain_count + 1))
        fi
      done
    fi
  done
  prune_stale_dest_rules "$GEO_DOMAIN_IPS_STATE" "$GEO_DOMAIN_IPS_STATE.tmp.$$" "$GEO_DEV" "$GEO_ROUTE_TABLE" "$PREF_DEST_GEO" "$(collect_geo_domains)"
  mv -f "$GEO_DOMAIN_IPS_STATE.tmp.$$" "$GEO_DOMAIN_IPS_STATE" 2>/dev/null || rm -f "$GEO_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
  chmod 0600 "$GEO_DOMAIN_IPS_STATE" 2>/dev/null || true
  if [ "$domain_count" -gt 0 ]; then
    log_i "AWG98 (Geo) destination routing: доменов=$domain_count"
  fi
  return 0
}

# --- Установка правил маршрутизации AWG99 (WARP) ---
install_dest_rules() {
  local subnet net_count=0 domain addr domain_count=0 addrs

  # Всегда синхронизируем геоблок-правила AWG98
  install_geo_dest_rules || true

  if ! warp_tunnel_healthy; then
    if dest_rules_present; then
      log_w "WARP health probe не прошла при синхронизации (${WARP_HEALTH_REASON:-?}); сохраняю существующие маршруты"
      return 0
    fi
    remove_dest_rules
    log_w "Туннель нерабочий (${WARP_HEALTH_REASON:-?}): маршруты по адресу назначения сняты"
    return 1
  fi

  for subnet in $(collect_warp_bypass_nets 4); do
    ip -4 route replace "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    add_dest_rule 4 "$subnet" "$TABLE" "$PREF_DEST_WARP"
    net_count=$((net_count + 1))
  done
  for subnet in $(collect_warp_bypass_nets 6); do
    ip -6 route replace "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    add_dest_rule 6 "$subnet" "$TABLE" "$PREF_DEST_WARP"
    net_count=$((net_count + 1))
  done

  if [ "${WARP_DOMAIN_ROUTING:-1}" = "1" ]; then
    : > "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null || true
    for domain in $(collect_warp_domains); do
      addrs=$(resolve_domain_addrs "$domain" 4)
      if [ -n "$addrs" ]; then
        for addr in $addrs; do
          ip -4 route replace "$addr" dev "$DEV" table "$TABLE" 2>/dev/null || true
          if add_dest_rule 4 "$addr" "$TABLE" "$PREF_DEST_WARP"; then
            printf '4|%s|%s\n' "$domain" "$addr" >> "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
            domain_count=$((domain_count + 1))
          fi
        done
      else
        log_w "WARP-домен $domain не резолвится, пропущен"
      fi
      addrs=$(resolve_domain_addrs "$domain" 6)
      if [ -n "$addrs" ]; then
        for addr in $addrs; do
          ip -6 route replace "$addr" dev "$DEV" table "$TABLE" 2>/dev/null || true
          if add_dest_rule 6 "$addr" "$TABLE" "$PREF_DEST_WARP"; then
            printf '6|%s|%s\n' "$domain" "$addr" >> "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
          fi
        done
      fi
    done
    prune_stale_dest_rules "$WARP_DOMAIN_IPS_STATE" "$WARP_DOMAIN_IPS_STATE.tmp.$$" "$DEV" "$TABLE" "$PREF_DEST_WARP" "$(collect_warp_domains)"
    mv -f "$WARP_DOMAIN_IPS_STATE.tmp.$$" "$WARP_DOMAIN_IPS_STATE" 2>/dev/null || rm -f "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
    chmod 0600 "$WARP_DOMAIN_IPS_STATE" 2>/dev/null || true
  fi
  if [ "$net_count" -gt 0 ] || [ "$domain_count" -gt 0 ]; then
    log_i "WARP destination routing: подсетей=$net_count доменов=$domain_count"
  fi
  return 0
}

apply_routing_rules() {
  log_i "Применение маршрутизации WARP: домены и подсети в туннель ($DEV)..."

  ip -4 route replace default dev "$DEV" table "$TABLE" 2>/dev/null || { log_e "Не удалось создать IPv4 default route table=$TABLE"; return 1; }
  if ip -6 addr show dev "$DEV" 2>/dev/null | grep -q 'inet6 '; then
    ip -6 route replace default dev "$DEV" table "$TABLE" 2>/dev/null || { log_e "Не удалось создать IPv6 default route table=$TABLE"; return 1; }
  else
    # Fail closed: трафик, направленный в туннель, не должен уходить
    # по системному IPv6-маршруту, если у туннеля IPv6 нет.
    ip -6 route replace unreachable default table "$TABLE" 2>/dev/null || { log_e "Не удалось создать IPv6 fail-closed route table=$TABLE"; return 1; }
  fi

  # Правила по адресу назначения (домены + подсети) ставятся отдельной функцией:
  # они зависят от живости туннеля и переустанавливаются watchdog'ом.
  install_dest_rules || true

  iptables -t mangle -N ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || \
    iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
  iptables -t mangle -C OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -I OUTPUT 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -C POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o "$DEV" -j MASQUERADE 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t mangle -N ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
    ip6tables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
    ip6tables -t mangle -C OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -I OUTPUT 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
    ip6tables -t mangle -C POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -I POSTROUTING 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  fi

  ip -4 route flush cache 2>/dev/null || true
  ip -6 route flush cache 2>/dev/null || true
  return 0
}

cleanup_routing_rules() {
  local fam pref uid table n subnet domain addr
  remove_apps_black_rules
  # Подсети берём из того же файла, что и при установке. Дополнительно снимаем
  # исторический захардкоженный набор: он мог остаться от прежних версий модуля,
  # и без этого его правила пережили бы обновление.
  for subnet in $(collect_warp_bypass_nets 4) 91.108.0.0/16 149.154.160.0/20 185.76.151.0/24 95.161.64.0/20; do
    ip -4 rule del to "$subnet" 2>/dev/null || true
    ip -4 route del "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
  done
  for subnet in $(collect_warp_bypass_nets 6) 2001:b28:f23d::/48 2001:67c:4e8::/48; do
    ip -6 rule del to "$subnet" 2>/dev/null || true
    ip -6 route del "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
  done

  # Адреса доменных правил снимаем по сохранённому состоянию: пересчитать их
  # заново нельзя, DNS мог вернуть уже другие IP, и правило осталось бы висеть.
  if [ -f "$WARP_DOMAIN_IPS_STATE" ]; then
    while IFS='|' read -r fam domain addr; do
      [ -n "$addr" ] || continue
      case "$addr" in *[!0-9A-Fa-f.:]*) continue ;; esac
      if [ "$fam" = 6 ]; then
        ip -6 rule del to "$addr" 2>/dev/null || true
        ip -6 route del "$addr" dev "$DEV" table "$TABLE" 2>/dev/null || true
      else
        ip -4 rule del to "$addr" 2>/dev/null || true
        ip -4 route del "$addr" dev "$DEV" table "$TABLE" 2>/dev/null || true
      fi
    done < "$WARP_DOMAIN_IPS_STATE"
    rm -f "$WARP_DOMAIN_IPS_STATE" 2>/dev/null
  fi

  # Правила по UID остались от версий, где туннель отбирал трафик по приложениям.
  # Файл состояния переживает обновление модуля, поэтому снимаем их по нему —
  # иначе такие правила висели бы вечно.
  if [ -f "$WARP_RULE_STATE" ]; then
    while IFS='|' read -r fam pref uid table; do
      case "$fam:$pref:$uid:$table" in *[!0-9:]*|'') continue ;; esac
      [ "$fam" = 4 ] && ip -4 rule del pref "$pref" uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true
      [ "$fam" = 6 ] && ip -6 rule del pref "$pref" uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true
    done < "$WARP_RULE_STATE"
  fi
  rm -f "$WARP_RULE_STATE" 2>/dev/null

  del_bounded iptables -t nat -D OUTPUT -j ZAPRET2_WARP_DNS
  del_bounded iptables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE
  iptables -t nat -F ZAPRET2_WARP_DNS 2>/dev/null || true
  iptables -t nat -X ZAPRET2_WARP_DNS 2>/dev/null || true

  del_bounded iptables -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE
  del_bounded iptables -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE
  iptables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    del_bounded ip6tables -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE
    del_bounded ip6tables -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE
    ip6tables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
    ip6tables -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null || true

    del_bounded ip6tables -t filter -D OUTPUT -j ZAPRET2_WARP_FILTER
    ip6tables -t filter -F ZAPRET2_WARP_FILTER 2>/dev/null || true
    ip6tables -t filter -X ZAPRET2_WARP_FILTER 2>/dev/null || true
  fi

  ip -4 route flush cache 2>/dev/null || true
  ip -6 route flush cache 2>/dev/null || true

  if ip -4 route show table "$TABLE" default 2>/dev/null | grep -q "dev $DEV"; then
    for pref in "$PREF_BASE" "$PREF_DEST"; do
      n=0
      while ip -4 rule show 2>/dev/null | grep -E "^${pref}:.*lookup ${TABLE}([[:space:]]|$)" >/dev/null && [ "$n" -lt 80 ]; do
        ip -4 rule del pref "$pref" lookup "$TABLE" 2>/dev/null || break; n=$((n+1))
      done
      n=0
      while ip -6 rule show 2>/dev/null | grep -E "^${pref}:.*lookup ${TABLE}([[:space:]]|$)" >/dev/null && [ "$n" -lt 80 ]; do
        ip -6 rule del pref "$pref" lookup "$TABLE" 2>/dev/null || break; n=$((n+1))
      done
    done
  fi
  ip -4 route flush table "$TABLE" 2>/dev/null || true
  ip -6 route flush table "$TABLE" 2>/dev/null || true
}

build_runtime_conf() {
  [ -n "$WARP_RUNTIME_CONF" ] || { log_e "WARP_RUNTIME_CONF пуст"; return 1; }
  grep -vE '^[[:space:]]*(Address|DNS)[[:space:]]*=' "$WARP_CONF" > "$WARP_RUNTIME_CONF" || return 1
  chmod 0600 "$WARP_RUNTIME_CONF" 2>/dev/null || true
}


get_latest_handshake_epoch() {
  local hs raw rc
  [ -x "$BIN_DIR/awg" ] || { echo 0; return 0; }
  raw=$(awg_cmd show "$DEV" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] 2>/dev/null; then
    [ "$rc" -eq 124 ] 2>/dev/null && log_w "awg show: UAPI timeout ${WARP_AWG_CMD_TIMEOUT:-2}s"
    echo 0
    return 0
  fi
  hs=$(printf '%s\n' "$raw" | sed -n 's/^last_handshake_time_sec=//p' | head -n1)
  case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
  printf '%s\n' "$hs"
}

get_active_endpoint() {
  local ep raw
  raw=$(awg_cmd show "$DEV" 2>/dev/null) || raw=""
  ep=$(printf '%s\n' "$raw" | sed -n 's/^endpoint=//p' | head -n1)
  [ -n "$ep" ] || ep=$(grep '^Endpoint[[:space:]]*=' "$WARP_CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]')
  printf '%s\n' "$ep"
}

get_rx_bytes() {
  local rx raw
  raw=$(awg_cmd show "$DEV" 2>/dev/null) || raw=""
  rx=$(printf '%s\n' "$raw" | sed -n 's/^rx_bytes=//p' | head -n1)
  case "$rx" in ''|*[!0-9]*) rx=0 ;; esac
  printf '%s\n' "$rx"
}

adapt_state_step() {
  local v
  v=$(sed -n 's/^step=//p' "$WARP_ADAPT_STATE" 2>/dev/null | head -n1)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  [ "$v" -le 999 ] 2>/dev/null || v=0
  printf '%s\n' "$v"
}

write_adapt_state() {
  local step="$1" result="${2:-pending}" now tmp="$WARP_ADAPT_STATE.tmp.$$"
  now=$(date +%s 2>/dev/null || echo 0)
  case "$step" in ''|*[!0-9]*) step=0 ;; esac
  case "$result" in pending|ok|failed) ;; *) result=pending ;; esac
  {
    printf 'step=%s\n' "$step"
    printf 'result=%s\n' "$result"
    printf 'updated=%s\n' "$now"
  } > "$tmp" || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$WARP_ADAPT_STATE"
}

# Возвращает один из воспроизводимых client-side J-профилей.
# По документации AmneziaWG Jc/Jmin/Jmax не обязаны совпадать с сервером:
# junk-пакеты отправляются инициатором перед handshake. Профиль 0 — ручной baseline.
adapt_state_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$WARP_ADAPT_STATE" 2>/dev/null | head -n1
}


adaptive_total_steps() { echo 40; }

get_underlay_mtu() {
  local route dev mtu
  route=$(ip -4 route get "${WARP_ENDPOINT:-162.159.192.1}" 2>/dev/null | head -n1)
  dev=$(printf '%s\n' "$route" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  [ -n "$dev" ] || { echo 1500; return 0; }
  mtu=$(ip link show dev "$dev" 2>/dev/null | sed -n 's/.* mtu \([0-9][0-9]*\).*/\1/p' | head -n1)
  case "$mtu" in ''|*[!0-9]*) mtu=1500 ;; esac
  echo "$mtu"
}

get_j_profile() {
  local base_jc="$WARP_JC" base_min="$WARP_JMIN" base_max="$WARP_JMAX" mtu legacy_max legacy_min strong_max
  case "$base_jc" in ''|*[!0-9]*) base_jc=5 ;; esac
  case "$base_min" in ''|*[!0-9]*) base_min=40 ;; esac
  case "$base_max" in ''|*[!0-9]*) base_max=70 ;; esac
  [ "$base_jc" -ge 1 ] 2>/dev/null && [ "$base_jc" -le 128 ] 2>/dev/null || base_jc=5
  if ! { [ "$base_min" -ge 1 ] 2>/dev/null && [ "$base_min" -lt "$base_max" ] 2>/dev/null && [ "$base_max" -le 4096 ] 2>/dev/null; }; then
    base_min=40; base_max=70
  fi

  mtu=$(get_underlay_mtu)
  # Ограничение сверху для Jmax для предотвращения фрагментации UDP на мобильных данных (MTU 1420)
  legacy_max=1280
  if [ "$mtu" -le 1420 ] 2>/dev/null; then legacy_max=$((mtu - 100)); fi
  [ "$legacy_max" -ge 320 ] 2>/dev/null || legacy_max=320
  [ "$legacy_max" -le 1280 ] 2>/dev/null || legacy_max=1280
  legacy_min=$((legacy_max / 2))
  [ "$legacy_min" -lt "$legacy_max" ] 2>/dev/null || legacy_min=$((legacy_max - 64))
  [ "$legacy_min" -ge 8 ] 2>/dev/null || legacy_min=8

  strong_max=900
  if [ "$mtu" -le 1080 ] 2>/dev/null; then strong_max=$((mtu - 100)); fi
  [ "$strong_max" -ge 320 ] 2>/dev/null || strong_max=320

  case "$1" in
    0) printf '%s %s %s\n' "$base_jc" "$base_min" "$base_max" ;;
    1) printf '10 %s %s\n' "$legacy_min" "$legacy_max" ;;
    2) echo '6 64 320' ;;
    3) echo '4 8 80' ;;
    *) printf '12 256 %s\n' "$strong_max" ;;
  esac
}

# Consumer WARP endpoints: перебор проверенных рабочих IP-адресов Cloudflare и портов.
# Если пользовательский IP (например 162.159.192.1) заблокирован у провайдера,
# адаптивный режим пробует 188.114.97.1, 188.114.96.1, 162.159.193.1 и другие пулы.
get_adaptive_endpoint() {
  local idx="$1" base="${WARP_ENDPOINT:-162.159.192.1}" port="${WARP_PORT:-500}"
  case "$idx" in
    0)
      # 1-й приоритет: сохраненный пользовательский endpoint и порт
      printf '%s:%s\n' "$base" "$port"
      ;;
    1)
      # 2-й приоритет: основной рабочий европейский пул Cloudflare в РФ (порт 2408)
      if [ "$base" = "188.114.97.1" ]; then
        printf '188.114.96.1:2408\n'
      else
        printf '188.114.97.1:2408\n'
      fi
      ;;
    2)
      # 3-й приоритет: IPsec порт 500 на пуле 188.114.96.1
      if [ "$base" = "188.114.96.1" ]; then
        printf '188.114.97.1:500\n'
      else
        printf '188.114.96.1:500\n'
      fi
      ;;
    *)
      # 4-й приоритет: резервный пул на порту 4500
      if [ "$base" = "162.159.193.1" ]; then
        printf '188.114.98.1:4500\n'
      else
        printf '162.159.193.1:4500\n'
      fi
      ;;
  esac
}

replace_conf_kv() {
  local key="$1" value="$2" tmp="$WARP_CONF.tmp.$$"
  awk -v k="$key" -v v="$value" '
    BEGIN{done=0}
    $0 ~ "^" k "[[:space:]]*=" { print k " = " v; done=1; next }
    /^\[Peer\]/ && !done { print k " = " v; done=1 }
    { print }
  ' "$WARP_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$WARP_CONF" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$WARP_CONF" 2>/dev/null || true
}

replace_peer_endpoint() {
  local value="$1" tmp="$WARP_CONF.tmp.$$"
  awk -v v="$value" '
    BEGIN{inpeer=0;done=0}
    /^\[Peer\]/ { inpeer=1; print; next }
    /^\[/ && $0 !~ /^\[Peer\]/ { inpeer=0 }
    inpeer && /^Endpoint[[:space:]]*=/ { print "Endpoint = " v; done=1; next }
    { print }
    END{ if(!done) exit 7 }
  ' "$WARP_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$WARP_CONF" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$WARP_CONF" 2>/dev/null || true
}

set_signature_mode_internal() {
  local mode="$1" tmp="$WARP_CONF.tmp.$$" i1 i2 i3 i4 i5
  [ -f "$WARP_CONF" ] || return 1
  if [ "$mode" = basic ]; then
    grep -vE '^(I1|I2|I3|I4|I5)[[:space:]]*=' "$WARP_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$WARP_CONF" || { rm -f "$tmp"; return 1; }
  else
    i1="${WARP_I1:-$SIP_I1}"; i2="${WARP_I2:-$SIP_I2}"
    i3="${WARP_I3:-}"; i4="${WARP_I4:-}"; i5="${WARP_I5:-}"
    [ -n "$i1" ] || return 1
    awk -v i1="$i1" -v i2="$i2" -v i3="$i3" -v i4="$i4" -v i5="$i5" '
      /^(I1|I2|I3|I4|I5)[[:space:]]*=/ { next }
      /^\[Peer\]/ && !added {
        print "I1 = " i1
        if(i2!="") print "I2 = " i2
        if(i3!="") print "I3 = " i3
        if(i4!="") print "I4 = " i4
        if(i5!="") print "I5 = " i5
        added=1
      }
      { print }
    ' "$WARP_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$WARP_CONF" || { rm -f "$tmp"; return 1; }
  fi
  chmod 0600 "$WARP_CONF" 2>/dev/null || true
  return 0
}

# Strict two-stage search:
#   0..19  BASIC only: 5 J profiles x 4 official WARP ports
#  20..39  SIP I1/I2: the same matrix, only after every BASIC candidate failed
# This preserves the intended fallback semantics: I1/I2 are never injected while
# there is still an untested BASIC combination.
candidate_meta() {
  local step="$1" x mode ep_idx prof_idx
  case "$step" in ''|*[!0-9]*) step=0 ;; esac
  [ "$step" -ge 0 ] 2>/dev/null || step=0
  [ "$step" -le 39 ] 2>/dev/null || step=39
  if [ "$step" -lt 20 ]; then
    mode=basic; x=$step
  else
    mode=sip; x=$((step - 20))
  fi
  # Перебираем все эндпоинты на базовом профиле в первую очередь (шаги 0..3)
  ep_idx=$((x % 4))
  prof_idx=$(( (x / 4) % 5 ))
  printf '%s %s %s\n' "$mode" "$ep_idx" "$prof_idx"
}

apply_candidate() {
  local step="$1" mode ep_idx prof_idx ep peer jc jmin jmax
  set -- $(candidate_meta "$step")
  mode="$1"; ep_idx="$2"; prof_idx="$3"
  set -- $(get_j_profile "$prof_idx")
  jc="$1"; jmin="$2"; jmax="$3"
  ep=$(get_adaptive_endpoint "$ep_idx")

  replace_conf_kv Jc "$jc" || return 1
  replace_conf_kv Jmin "$jmin" || return 1
  replace_conf_kv Jmax "$jmax" || return 1
  replace_conf_kv S1 0 || return 1
  replace_conf_kv S2 0 || return 1
  local tmp="$WARP_CONF.tmp.$$"
  grep -vE '^(S3|S4)[[:space:]]*=' "$WARP_CONF" > "$tmp" && mv -f "$tmp" "$WARP_CONF" || { rm -f "$tmp"; return 1; }
  replace_conf_kv H1 1 || return 1
  replace_conf_kv H2 2 || return 1
  replace_conf_kv H3 3 || return 1
  replace_conf_kv H4 4 || return 1
  set_signature_mode_internal "$mode" || return 1
  replace_peer_endpoint "$ep" || return 1

  if ip link show dev "$DEV" >/dev/null 2>&1; then
    build_runtime_conf || return 1
    awg_cmd setconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE" || return 1
  fi

  write_adapt_state "$step" pending || true
  log_i "WARP adaptive: step=$step/39 mode=$mode Jc/Jmin/Jmax=$jc/$jmin/$jmax endpoint=$ep"
  return 0
}

prepare_manual_profile() {
  local mode=basic
  [ "${WARP_SIP_FORCE:-0}" = 1 ] && mode=sip
  replace_conf_kv Jc "$WARP_JC" || return 1
  replace_conf_kv Jmin "$WARP_JMIN" || return 1
  replace_conf_kv Jmax "$WARP_JMAX" || return 1
  replace_conf_kv S1 0 || return 1
  replace_conf_kv S2 0 || return 1
  local tmp="$WARP_CONF.tmp.$$"
  grep -vE '^(S3|S4)[[:space:]]*=' "$WARP_CONF" > "$tmp" && mv -f "$tmp" "$WARP_CONF" || { rm -f "$tmp"; return 1; }
  replace_conf_kv H1 1 || return 1
  replace_conf_kv H2 2 || return 1
  replace_conf_kv H3 3 || return 1
  replace_conf_kv H4 4 || return 1
  set_signature_mode_internal "$mode" || return 1
  replace_peer_endpoint "${WARP_ENDPOINT}:${WARP_PORT}" || return 1
  write_adapt_state 0 pending || true
}

probe_handshake() {
  local timeout="${1:-$WARP_PROBE_TIMEOUT}" before hs now start rx_before rx_now
  case "$timeout" in ''|*[!0-9]*) timeout=2 ;; esac
  [ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
  [ "$timeout" -le 10 ] 2>/dev/null || timeout=10
  before=$(get_latest_handshake_epoch)
  rx_before=$(get_rx_bytes)

  # Отправляем активный пакет через интерфейс туннеля для мгновенного триггера Handshake Initiation
  ping -c 1 -W 1 -I "$DEV" 1.1.1.1 >/dev/null 2>&1 &

  start=$(date +%s 2>/dev/null || echo 0)
  while :; do
    sleep 1
    hs=$(get_latest_handshake_epoch)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$hs" -gt 0 ] 2>/dev/null; then
      if [ "$before" -eq 0 ] 2>/dev/null || [ "$hs" -gt "$before" ] 2>/dev/null; then
        # Проверяем реальную передачу L7 HTTPS данных через туннель
        if curl --interface "$DEV" -4 -sS -o /dev/null --connect-timeout 2 https://1.1.1.1/ 2>/dev/null || \
           curl --interface "$DEV" -4 -sS -o /dev/null --connect-timeout 2 https://1.0.0.1/ 2>/dev/null; then
          return 0
        fi
      fi
    fi
    rx_now=$(get_rx_bytes)
    if [ "$rx_now" -gt "$((rx_before + 500))" ] 2>/dev/null && [ "$hs" -gt 0 ] 2>/dev/null; then
      if curl --interface "$DEV" -4 -sS -o /dev/null --connect-timeout 2 https://1.1.1.1/ 2>/dev/null; then
        return 0
      fi
    fi
    [ $((now - start)) -ge "$timeout" ] 2>/dev/null && break
  done
  return 1
}

next_adapt_step() {
  local cur="$1"
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  if [ "$cur" -lt 39 ] 2>/dev/null; then echo $((cur + 1)); else echo 0; fi
}

adapt_retry_due() {
  local result updated now age retry="${WARP_ADAPT_RETRY_SEC:-300}"
  result=$(adapt_state_value result)
  [ "$result" = failed ] || return 0
  updated=$(adapt_state_value updated); now=$(date +%s 2>/dev/null || echo 0)
  case "$updated:$now:$retry" in *[!0-9:]*) return 0 ;; esac
  age=$((now - updated))
  [ "$age" -ge "$retry" ] 2>/dev/null
}

adaptive_bootstrap() {
  local total step tries n=0 result ptype is_custom_ru=0
  total=$(adaptive_total_steps)
  ptype=$(cat "$WARP_PROFILE_TYPE" 2>/dev/null | tr -d '\r\n')
  case "$ptype" in
    ""|"Free WARP"|"ecubz_warp.conf") is_custom_ru=0 ;;
    *) is_custom_ru=1 ;;
  esac

  if [ "$is_custom_ru" -eq 1 ] || [ "${WARP_ADAPTIVE:-1}" != 1 ]; then
    if probe_handshake "$WARP_PROBE_TIMEOUT"; then write_adapt_state 0 ok || true; return 0; fi
    write_adapt_state 0 failed || true
    return 2
  fi

  # Без несущей сети матрицу не проходим: сорок кандидатов гарантированно
  # провалятся, а состояние уедет в failed и утащит за собой backoff.
  if ! underlay_available; then
    log_i "WARP adaptive: нет несущей сети, перебор профилей отложен"
    return 1
  fi
  result=$(adapt_state_value result)
  if [ "$result" = failed ] && ! adapt_retry_due; then return 2; fi
  if [ "$result" = failed ]; then step=0; else step=$(adapt_state_step); fi
  # Initial/restart search is already launched in background by service/WebUI.
  # Finish the whole matrix here so the state can become explicitly "failed"
  # instead of depending on a watcher that may be stale or delayed.
  tries="${WARP_STARTUP_TRIES:-40}"
  case "$tries" in ''|*[!0-9]*) tries="$total" ;; esac
  # Нижняя граница — 1, а не $total: две проверки против $total подряд
  # всегда давали ровно $total, и настройка не действовала вовсе.
  [ "$tries" -ge 1 ] 2>/dev/null || tries="$total"
  [ "$tries" -le "$total" ] 2>/dev/null || tries="$total"

  while [ "$n" -lt "$tries" ]; do
    # Publish progress before touching UAPI, so even a rejected candidate cannot
    # leave WebUI frozen forever on the previous step.
    write_adapt_state "$step" pending || true
    if apply_candidate "$step"; then
      if probe_handshake "$WARP_PROBE_TIMEOUT"; then
        write_adapt_state "$step" ok || true
        log_i "WARP adaptive: handshake OK на step=$step"
        return 0
      fi
      log_w "WARP adaptive: handshake не получен на step=$step"
    else
      # A malformed/rejected candidate is a failed candidate, not a reason to
      # abort the whole matrix and leave result=pending forever.
      log_w "WARP adaptive: step=$step не удалось применить; пропускаем кандидат"
    fi
    if [ "$step" -eq 39 ] 2>/dev/null; then
      write_adapt_state "$step" failed || true
      log_e "WARP adaptive: проверены все 40 профилей, handshake не найден; повтор после ${WARP_ADAPT_RETRY_SEC:-300}с или после ручного сохранения/rekey"
      return 2
    fi
    step=$(next_adapt_step "$step")
    n=$((n + 1))
  done

  # Подготавливаем следующий профиль, но не называем поиск успешным.
  apply_candidate "$step" || true
  return 1
}

# ------------------------------------------------------------------------------
# Запуск / Остановка туннеля
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Управление геоблок-туннелем AWG98 (Zero Trust / Proton VPN)
# ------------------------------------------------------------------------------
build_generic_runtime_conf() {
  local in_conf="$1" out_conf="$2"
  [ -f "$in_conf" ] || return 1
  awk '
    BEGIN { in_interface=0; in_peer=0 }
    /^\[Interface\]/ { in_interface=1; in_peer=0; print; next }
    /^\[Peer\]/ { in_interface=0; in_peer=1; print; next }
    /^\[/ { in_interface=0; in_peer=0; next }
    in_interface {
      if ($0 ~ /^[[:space:]]*(Address|DNS|MTU)[[:space:]]*=/) next
      print
      next
    }
    in_peer { print; next }
  ' "$in_conf" > "$out_conf" 2>/dev/null || return 1
  chmod 0600 "$out_conf" 2>/dev/null || true
  return 0
}

start_geo_tunnel() {
  if [ "${ENABLE_GEO_WARP:-1}" != "1" ]; then
    stop_geo_tunnel_internal
    return 0
  fi

  local psrc
  psrc=$(get_geo98_profile_path)
  if [ -z "$psrc" ]; then
    log_i "AWG98 (Geo): конфигурация в /geo/ не обнаружена, туннель awg98 отключен"
    stop_geo_tunnel_internal
    return 0
  fi

  generate_geo98_config || { log_w "Не удалось подготовить geo_warp.conf"; return 1; }
  [ -s "$GEO_CONF" ] || return 1

  stop_geo_tunnel_internal

  log_i "Запуск интерфейса $GEO_DEV через amneziawg-go (AmneziaWG v3)..."
  mkdir -p "$RUN_DIR" 2>/dev/null || true

  if [ -x "$BIN_DIR/amneziawg-go" ]; then
    WG_UAPI_DIR="$RUN_DIR" AMNEZIAWG_UAPI_DIR="$RUN_DIR" "$BIN_DIR/amneziawg-go" -f "$GEO_DEV" >> "$LOG_FILE" 2>&1 &
    echo "$!" > "$GEO_PID_FILE"
    local w=0
    while [ ! -S "$RUN_DIR/$GEO_DEV.sock" ] && [ "$w" -lt 25 ]; do
      sleep 0.1
      w=$((w + 1))
    done
  fi

  if ! ip link show dev "$GEO_DEV" >/dev/null 2>&1; then
    log_e "amneziawg-go не создал $GEO_DEV"
    stop_geo_tunnel_internal
    return 1
  fi

  build_generic_runtime_conf "$GEO_CONF" "$GEO_RUNTIME_CONF" || { stop_geo_tunnel_internal; return 1; }
  if [ -x "$BIN_DIR/awg" ]; then
    if ! awg_cmd setconf "$GEO_DEV" "$GEO_RUNTIME_CONF" 2>>"$LOG_FILE"; then
      log_e "Ошибка awg setconf для $GEO_DEV"
      stop_geo_tunnel_internal
      return 1
    fi
  fi

  local client_addr_v4 client_addr_v6
  client_addr_v4=$(grep '^Address' "$GEO_CONF" | cut -d= -f2 | awk -F',' '{print $1}' | tr -d ' ')
  client_addr_v6=$(grep '^Address' "$GEO_CONF" | cut -d= -f2 | awk -F',' '{print $2}' | tr -d ' ')
  [ -n "$client_addr_v4" ] || client_addr_v4="172.16.0.3/32"

  ip -4 addr replace "$client_addr_v4" dev "$GEO_DEV" 2>/dev/null || true
  echo 1 > "/proc/sys/net/ipv6/conf/$GEO_DEV/disable_ipv6" 2>/dev/null || true
  ip link set up dev "$GEO_DEV" 2>/dev/null || true
  ip link set mtu 1280 dev "$GEO_DEV" 2>/dev/null || true

  # Настройка таблицы 11887 для AWG98 (IPv4 dev awg98, IPv6 ПОЛНОСТЬЮ ЗАБЛОКИРОВАН unreachable)
  local geo_client_ip
  geo_client_ip=$(ip -4 addr show dev "$GEO_DEV" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
  ip -4 route replace default dev "$GEO_DEV" ${geo_client_ip:+src $geo_client_ip} table "$GEO_ROUTE_TABLE" 2>/dev/null || true
  echo 1 > "/proc/sys/net/ipv6/conf/$GEO_DEV/disable_ipv6" 2>/dev/null || true
  ip -6 route flush table "$GEO_ROUTE_TABLE" 2>/dev/null || true
  ip -6 route replace unreachable default table "$GEO_ROUTE_TABLE" 2>/dev/null || true

  iptables -t nat -C POSTROUTING -o "$GEO_DEV" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 -o "$GEO_DEV" -j MASQUERADE 2>/dev/null || true
  iptables -t mangle -C POSTROUTING -o "$GEO_DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -I POSTROUTING 1 -o "$GEO_DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

  install_geo_dest_rules || true
  ping -c 1 -W 2 -I "$GEO_DEV" 1.1.1.1 >/dev/null 2>&1 &
  log_i "AWG98 (Geo) успешно запущен на $GEO_DEV"
  return 0
}

stop_geo_tunnel_internal() {
  remove_geo_dest_rules
  del_bounded iptables -t nat -D POSTROUTING -o "$GEO_DEV" -j MASQUERADE
  del_bounded iptables -t mangle -D POSTROUTING -o "$GEO_DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ip link set down dev "$GEO_DEV" 2>/dev/null || true
  ip link delete dev "$GEO_DEV" 2>/dev/null || true
  local pid cmd exe
  pid=$(cat "$GEO_PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cmd=$(pid_cmdline "$pid")
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if { [ "$exe" = "$BIN_DIR/amneziawg-go" ] || printf '%s' "$cmd" | grep -Fq "$BIN_DIR/amneziawg-go"; } && printf '%s' "$cmd" | grep -Fq "$GEO_DEV"; then
      kill -TERM "$pid" 2>/dev/null || true
      local n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$GEO_PID_FILE" "$GEO_RUNTIME_CONF" 2>/dev/null
  ip -4 route flush table "$GEO_ROUTE_TABLE" 2>/dev/null || true
  ip -6 route flush table "$GEO_ROUTE_TABLE" 2>/dev/null || true
  ip -4 route flush cache 2>/dev/null || true
  ip -6 route flush cache 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Запуск / Остановка туннелей (AWG99 + AWG98)
# ------------------------------------------------------------------------------
start_warp99_internal() {
  generate_warp_config || return 1
  [ -s "$WARP_CONF" ] || { log_e "Отсутствует конфигурация $WARP_CONF"; return 1; }

  stop_warp99_internal

  local ptype is_custom_ru=0
  ptype=$(cat "$WARP_PROFILE_TYPE" 2>/dev/null | tr -d '\r\n')
  case "$ptype" in
    ""|"Free WARP"|"ecubz_warp.conf") is_custom_ru=0 ;;
    *) is_custom_ru=1 ;;
  esac

  if [ "$is_custom_ru" -eq 0 ] && [ "${WARP_ADAPTIVE:-1}" = 1 ]; then
    [ -f "$WARP_ADAPT_STATE" ] || write_adapt_state 0 pending || true
    apply_candidate 0 || log_w "WARP adaptive recovery: step=0 не применился; продолжим матрицу"
  else
    prepare_manual_profile || return 1
  fi

  log_i "Запуск интерфейса $DEV через amneziawg-go (AmneziaWG v3)..."

  mkdir -p "$RUN_DIR" 2>/dev/null || true

  if [ -x "$BIN_DIR/amneziawg-go" ]; then
    WG_UAPI_DIR="$RUN_DIR" AMNEZIAWG_UAPI_DIR="$RUN_DIR" "$BIN_DIR/amneziawg-go" -f "$DEV" >> "$LOG_FILE" 2>&1 &
    local awg_pid=$!
    echo "$awg_pid" > "$WARP_PID_FILE"
    local w=0
    while [ ! -S "$RUN_DIR/$DEV.sock" ] && [ "$w" -lt 25 ]; do
      sleep 0.1
      w=$((w + 1))
    done
  fi

  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    log_e "amneziawg-go не создал $DEV"
    stop_warp99_internal
    return 1
  fi

  build_runtime_conf || { stop_warp99_internal; return 1; }
  if [ -x "$BIN_DIR/awg" ]; then
    if ! awg_cmd setconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE"; then
      log_e "Ошибка awg setconf для $DEV"
      stop_warp99_internal
      return 1
    fi
  else
    log_e "Бинарник awg отсутствует в $BIN_DIR/awg"
    stop_warp99_internal
    return 1
  fi

  local client_addr_v4 client_addr_v6
  client_addr_v4=$(grep '^Address' "$WARP_CONF" | cut -d= -f2 | awk -F',' '{print $1}' | tr -d ' ')
  client_addr_v6=$(grep '^Address' "$WARP_CONF" | cut -d= -f2 | awk -F',' '{print $2}' | tr -d ' ')
  [ -n "$client_addr_v4" ] || client_addr_v4="172.16.0.2/32"

  ip -4 addr replace "$client_addr_v4" dev "$DEV" 2>/dev/null || { log_e "Не удалось назначить IPv4 $client_addr_v4"; stop_warp99_internal; return 1; }
  echo 1 > "/proc/sys/net/ipv6/conf/$DEV/disable_ipv6" 2>/dev/null || true
  ip link set up dev "$DEV" 2>/dev/null || { log_e "Не удалось поднять $DEV"; stop_warp99_internal; return 1; }
  ip link set mtu 1280 dev "$DEV" 2>/dev/null || log_w "Не удалось установить MTU=1280"

  apply_routing_rules || { stop_warp99_internal; return 1; }

  local adapt_rc=0
  adaptive_bootstrap || adapt_rc=$?
  if [ "$adapt_rc" -eq 0 ]; then
    local active_ep active_step
    active_ep=$(get_active_endpoint)
    active_step=$(adapt_state_step)
    warp_clear_unhealthy
    rm -f "$RUN_DIR/warp-fail.count" 2>/dev/null
    log_i "WARP $DEV запущен: routing OK, handshake OK, adaptive step=$active_step endpoint=$active_ep"
    return 0
  fi

  local pending_step pending_result
  pending_step=$(adapt_state_step); pending_result=$(adapt_state_value result)
  if [ "$adapt_rc" -eq 2 ] || [ "$pending_result" = failed ]; then
    log_e "WARP $DEV поднят fail-closed, но рабочий handshake не найден (step=$pending_step)"
  else
    log_w "WARP $DEV поднят, handshake пока нет; adaptive recovery продолжит с step=$pending_step"
  fi
  return 0
}

start_tunnel() {
  if [ "${ENABLE_WARP:-0}" != "1" ] && [ "${ENABLE_GEO_WARP:-1}" != "1" ]; then
    log_i "WARP и GEO_WARP отключены в zapret2.conf"
    stop_tunnel
    return 0
  fi

  acquire_warp_lock || { log_w "Не удалось захватить warp.lock (операция занята)"; return 1; }

  if [ "${ENABLE_WARP:-0}" = "1" ]; then
    start_warp99_internal || log_w "Не удалось запустить основной туннель $DEV"
  else
    stop_warp99_internal
  fi

  if [ "${ENABLE_GEO_WARP:-1}" = "1" ]; then
    start_geo_tunnel || log_w "Не удалось запустить геоблок-туннель $GEO_DEV"
  else
    stop_geo_tunnel_internal
  fi

  release_warp_lock
  return 0
}

stop_warp99_internal() {
  log_i "Остановка основного туннеля $DEV..."
  cleanup_routing_rules

  ip link set down dev "$DEV" 2>/dev/null || true
  ip link delete dev "$DEV" 2>/dev/null || true

  local pid cmd exe
  pid=$(cat "$WARP_PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cmd=$(pid_cmdline "$pid")
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if { [ "$exe" = "$BIN_DIR/amneziawg-go" ] || printf '%s' "$cmd" | grep -Fq "$BIN_DIR/amneziawg-go"; } && printf '%s' "$cmd" | grep -Fq "$DEV"; then
      kill -TERM "$pid" 2>/dev/null || true
      local n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$WARP_PID_FILE" "$WARP_RUNTIME_CONF" 2>/dev/null
}

stop_tunnel_internal() {
  stop_warp99_internal
  stop_geo_tunnel_internal
}

stop_tunnel() {
  acquire_warp_lock || return 1
  stop_tunnel_internal
  release_warp_lock
}

sync_apps() {
  if [ "${ENABLE_WARP:-0}" != "1" ] && [ "${ENABLE_GEO_WARP:-1}" != "1" ]; then
    stop_tunnel
    return 0
  fi
  acquire_warp_lock || return 1
  local rc=0
  if [ "${ENABLE_WARP:-0}" = "1" ]; then
    if ! ip link show dev "$DEV" >/dev/null 2>&1; then
      start_warp99_internal || rc=$?
    else
      apply_routing_rules || rc=$?
    fi
  else
    stop_warp99_internal
  fi

  if [ "${ENABLE_GEO_WARP:-1}" = "1" ]; then
    if ! ip link show dev "$GEO_DEV" >/dev/null 2>&1; then
      start_geo_tunnel || rc=$?
    else
      install_geo_dest_rules || rc=$?
    fi
  else
    stop_geo_tunnel_internal
  fi

  release_warp_lock
  return "$rc"
}

status_tunnel() {
  if ip link show dev "$DEV" >/dev/null 2>&1; then
    local dump hs
    hs=$(get_latest_handshake_epoch)
    if [ "$hs" -gt 0 ] 2>/dev/null; then
      echo "WARP_STATUS=HANDSHAKE_OK"
    else
      echo "WARP_STATUS=INTERFACE_UP_NO_HANDSHAKE"
    fi
    echo "WARP_DEV=$DEV"
    echo "WARP_ADAPT_STEP=$(adapt_state_step)"
    [ -x "$BIN_DIR/awg" ] && awg_cmd show "$DEV" 2>/dev/null || true
  else
    echo "WARP_STATUS=STOPPED"
  fi
}

SIP_I1="<b 0x5349502f322e302031303020547279696e670d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
SIP_I2="<b 0x494e56495445207369703a626f624062696c6f78692e636f6d205349502f322e300d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a4d61782d466f7277617264733a2037300d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"

sync_current_runtime_profile() {
  # Применяем текущий профиль через setconf
  ip link show dev "$DEV" >/dev/null 2>&1 || return 0
  build_runtime_conf || return 1
  awg_cmd setconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE" || return 1
  return 0
}

enable_sip_mode() {
  acquire_warp_lock || return 1
  [ -f "$WARP_CONF" ] || { release_warp_lock; return 1; }
  log_w "Ручная активация SIP I1/I2 для текущего J/endpoint"
  set_signature_mode_internal sip && sync_current_runtime_profile
  local rc=$?
  [ "$rc" -eq 0 ] && write_adapt_state "$(adapt_state_step)" pending || true
  release_warp_lock
  return "$rc"
}

disable_sip_mode() {
  acquire_warp_lock || return 1
  [ -f "$WARP_CONF" ] || { release_warp_lock; return 1; }
  log_i "Ручной возврат текущего профиля в BASIC без I1/I2"
  set_signature_mode_internal basic && sync_current_runtime_profile
  local rc=$?
  [ "$rc" -eq 0 ] && write_adapt_state "$(adapt_state_step)" pending || true
  release_warp_lock
  return "$rc"
}

# Отметка «туннель нездоров с такого-то момента». По ней решается, пора ли
# перестать перебирать шаги и перезапустить туннель целиком.
warp_mark_unhealthy() {
  [ -s "$WARP_UNHEALTHY_SINCE" ] || date +%s > "$WARP_UNHEALTHY_SINCE" 2>/dev/null
  chmod 0600 "$WARP_UNHEALTHY_SINCE" 2>/dev/null || true
}
warp_clear_unhealthy() { rm -f "$WARP_UNHEALTHY_SINCE" 2>/dev/null; }
warp_unhealthy_age() {
  local since now
  since=$(cat "$WARP_UNHEALTHY_SINCE" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  now=$(date +%s 2>/dev/null || echo 0)
  [ "$now" -ge "$since" ] 2>/dev/null && echo $((now - since)) || echo 0
}

check_and_heal_warp() {
  [ "${ENABLE_WARP:-0}" = "1" ] || return 0
  # Стартовый перебор держит блокировку минутами (до WARP_STARTUP_TRIES шагов
  # по несколько секунд каждый). Раньше watchdog в это время молча возвращал
  # ошибку, и со стороны это выглядело как зависший на одном шаге туннель:
  # ни движения, ни строчки в логе. Теперь причина хотя бы видна.
  if ! acquire_warp_lock; then
    log_w "WARP watchdog: операция с туннелем уже выполняется (перебор профилей), проверка пропущена"
    return 1
  fi
  [ -x "$BIN_DIR/awg" ] || { release_warp_lock; return 1; }
  ip link show dev "$DEV" >/dev/null 2>&1 || { release_warp_lock; return 1; }

  local hs now diff step next result batch stall fails i=0

  # Единая проверка живости: свежий handshake И реально идущие данные.
  # Раньше здесь смотрели только на возраст handshake, поэтому состояние
  # «рукопожатие обновляется, а полезный трафик не ходит» считалось нормой:
  # туннель формально жив, а весь трафик, направленный в него, пропадает.
  if warp_tunnel_healthy; then
    step=$(adapt_state_step)
    write_adapt_state "$step" ok || true
    warp_clear_unhealthy
    rm -f "$RUN_DIR/warp-fail.count" 2>/dev/null
    # Туннель работает. Если маршруты по адресу назначения были сняты на
    # прошлой итерации — возвращаем их. Проверяем именно наличие правил с нашим
    # приоритетом, а не файл состояния: он пуст и в штатной ситуации, когда
    # доменов в списке нет, и по нему нельзя отличить «сняли» от «нечего ставить».
    if dest_rules_wanted && ! dest_rules_present; then
      log_i "WARP watchdog: туннель восстановился, возвращаю маршруты по адресу назначения"
      install_dest_rules || true
    fi
    release_warp_lock
    return 0
  fi

  # Туннель нерабочий. Первым делом убираем маршруты по адресу назначения, чтобы
  # трафик не пропадал, пока идёт восстановление: подсети и домены вернутся на
  # обычный маршрут, где действует обход DPI. Снимаем один раз, а не каждый тик:
  # прежде эта ветка на каждой проверке заново обходила 15 подсетей и писала
  # строку в журнал, даже когда снимать уже было нечего.
  # Гистерезис. Один неудачный опрос — ещё не повод рвать маршруты: клиент,
  # у которого соединение выдернули посреди сессии, переустанавливает его
  # заметно дольше, чем длится случайный сбой опроса.
  fails=$(cat "$RUN_DIR/warp-fail.count" 2>/dev/null)
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1))
  printf '%s
' "$fails" > "$RUN_DIR/warp-fail.count" 2>/dev/null
  chmod 0600 "$RUN_DIR/warp-fail.count" 2>/dev/null || true
  if [ "$fails" -lt "${WARP_FAIL_CONFIRM:-2}" ] 2>/dev/null; then
    log_i "WARP watchdog: ${WARP_HEALTH_REASON:-туннель не отвечает}; подтверждение $fails/${WARP_FAIL_CONFIRM:-2}, маршруты пока не трогаю"
    release_warp_lock
    return 1
  fi
  if dest_rules_present; then
    log_w "WARP watchdog: ${WARP_HEALTH_REASON:-туннель не отвечает}; снимаю маршруты по адресу назначения на время восстановления"
    remove_dest_rules
  fi
  warp_mark_unhealthy

  # Нет несущей сети — засыпаем. Ни перебора кандидатов, ни полного перезапуска:
  # чинить нечего, пока чинить не через что. Возвращение сети поднимет обычную
  # логику, а отметка «нездоров с такого-то момента» продолжает идти, поэтому
  # после длинного обрыва туннель будет поднят с нуля — это и нужно, состояние
  # интерфейса за время отсутствия несущей сети всё равно устарело.
  if ! underlay_available; then
    if [ ! -f "$RUN_DIR/warp-nolink.flag" ]; then
      : > "$RUN_DIR/warp-nolink.flag" 2>/dev/null
      chmod 0600 "$RUN_DIR/warp-nolink.flag" 2>/dev/null || true
      log_i "WARP watchdog: нет несущей сети, перебор профилей приостановлен до её появления"
    fi
    release_warp_lock
    return 1
  fi
  if [ -f "$RUN_DIR/warp-nolink.flag" ]; then
    rm -f "$RUN_DIR/warp-nolink.flag" 2>/dev/null
    log_i "WARP watchdog: несущая сеть вернулась, восстановление продолжается"
  fi

  # Если туннель не оживает слишком долго, пошаговый перебор уже не помогает:
  # состояние интерфейса или процесса могло испортиться так, что его не чинит
  # смена профиля. Поднимаем всё заново с нуля вместо бесконечного перебора.
  stall=$(warp_unhealthy_age)
  if [ "$stall" -ge "${WARP_STALL_RESTART_SEC:-600}" ] 2>/dev/null; then
    log_w "WARP watchdog: туннель не работает ${stall}с — полный перезапуск с нуля"
    stop_tunnel_internal
    rm -f "$WARP_ADAPT_STATE" 2>/dev/null
    warp_clear_unhealthy
    release_warp_lock
    start_tunnel >/dev/null 2>&1 &
    return 0
  fi

  hs=$(get_latest_handshake_epoch)
  now=$(date +%s 2>/dev/null || echo 0)
  if [ "$hs" -gt 0 ] 2>/dev/null; then diff=$((now - hs)); else diff=999999; fi

  # Чёрная дыра при свежем рукопожатии ожиданием не лечится: пересогласование
  # не поможет, нужен другой профиль или endpoint. Поэтому идём в адаптивный
  # перебор ниже наравне со случаем «рукопожатие не проходит вовсе».

  if [ "${WARP_ADAPTIVE:-1}" != 1 ]; then
    if probe_handshake "$WARP_PROBE_TIMEOUT"; then write_adapt_state 0 ok || true; release_warp_lock; return 0; fi
    write_adapt_state 0 failed || true
    release_warp_lock
    return 1
  fi

  result=$(adapt_state_value result)
  if [ "$result" = failed ]; then
    if ! adapt_retry_due; then release_warp_lock; return 1; fi
    log_w "WARP adaptive: истёк backoff после полного неуспеха, начинаем новый цикл"
    apply_candidate 0 || { release_warp_lock; return 1; }
  fi

  step=$(adapt_state_step)
  batch="${WARP_WATCH_BATCH:-5}"
  case "$batch" in ''|*[!0-9]*) batch=5 ;; esac
  [ "$batch" -ge 1 ] 2>/dev/null || batch=1
  [ "$batch" -le 10 ] 2>/dev/null || batch=10

  while [ "$i" -lt "$batch" ]; do
    log_w "WARP handshake отсутствует/устарел (${diff}s), проверяем adaptive step=$step"
    if probe_handshake "$WARP_PROBE_TIMEOUT"; then
      write_adapt_state "$step" ok || true
      log_i "WARP adaptive recovery: восстановлен step=$step"
      release_warp_lock
      return 0
    fi
    if [ "$step" -eq 39 ] 2>/dev/null; then
      write_adapt_state "$step" failed || true
      log_e "WARP adaptive recovery: все 40 профилей проверены, рабочего handshake нет"
      release_warp_lock
      return 1
    fi
    next=$(next_adapt_step "$step")
    write_adapt_state "$next" pending || true
    if ! apply_candidate "$next"; then
      log_w "WARP adaptive recovery: step=$next не применился; кандидат пропущен"
    fi
    step="$next"
    i=$((i + 1))
  done
  release_warp_lock
  return 1
}

check_and_heal_geo() {
  [ "${ENABLE_GEO_WARP:-1}" = "1" ] || return 0
  local conf_path
  conf_path=$(get_geo98_profile_path)
  [ -n "$conf_path" ] || return 0

  if geo_tunnel_healthy; then
    rm -f "$RUN_DIR/geo-fail.count" 2>/dev/null
    return 0
  fi

  local fails
  fails=$(cat "$RUN_DIR/geo-fail.count" 2>/dev/null)
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1))
  printf '%s\n' "$fails" > "$RUN_DIR/geo-fail.count" 2>/dev/null
  chmod 0600 "$RUN_DIR/geo-fail.count" 2>/dev/null || true

  if [ "$fails" -lt 5 ]; then
    log_i "AWG98 watchdog: ${GEO_HEALTH_REASON:-туннель не отвечает}; попытка $fails/5"
    return 1
  fi

  log_w "AWG98 watchdog: 5 неудачных проверок подряд (${GEO_HEALTH_REASON:-?}); автоматический перезапуск и ротация профиля..."
  rm -f "$RUN_DIR/geo-fail.count" 2>/dev/null
  rotate_geo98_profile
  acquire_warp_lock || return 1
  stop_geo_tunnel_internal
  start_geo_tunnel
  release_warp_lock
  return 0
}

case "$1" in
  start)
    rm -f "$RUN_DIR/warp_stopped.flag" "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    start_tunnel
    ;;
  stop)
    touch "$RUN_DIR/warp_stopped.flag" "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    stop_tunnel
    ;;
  restart|reload)
    rm -f "$RUN_DIR/warp_stopped.flag" "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    start_tunnel
    ;;
  force-restart)
    acquire_warp_lock || { log_w "Перезапуск отложен: операция с туннелем уже выполняется"; exit 1; }
    log_i "Полный перезапуск туннеля по запросу пользователя"
    stop_tunnel_internal
    rm -f "$WARP_ADAPT_STATE" "$WARP_UNHEALTHY_SINCE" "$RUN_DIR/warp_stopped.flag" "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    release_warp_lock
    start_tunnel
    ;;
  sync) sync_apps ;;
  status) status_tunnel ;;
  watchdog|heal)
    check_and_heal_warp
    check_and_heal_geo
    ;;
  rotate-geo)
    acquire_geo_lock || exit 1
    rm -f "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    rotate_geo98_profile
    stop_geo_tunnel_internal
    start_geo_tunnel
    release_geo_lock
    ;;
  sip-on) enable_sip_mode ;;
  sip-off) disable_sip_mode ;;
  start-ru|start-awg99)
    acquire_warp_lock || exit 1
    rm -f "$RUN_DIR/warp_stopped.flag" 2>/dev/null
    start_warp99_internal
    release_warp_lock
    ;;
  stop-ru|stop-awg99)
    acquire_warp_lock || exit 1
    touch "$RUN_DIR/warp_stopped.flag" 2>/dev/null
    stop_warp99_internal
    release_warp_lock
    ;;
  restart-ru|restart-awg99)
    acquire_warp_lock || exit 1
    rm -f "$RUN_DIR/warp_stopped.flag" 2>/dev/null
    log_i "Перезапуск основного туннеля AWG99 (/ru/)..."
    stop_warp99_internal
    rm -f "$WARP_ADAPT_STATE" "$WARP_UNHEALTHY_SINCE" 2>/dev/null
    start_warp99_internal
    release_warp_lock
    ;;
  start-geo|start-awg98)
    acquire_geo_lock || exit 1
    rm -f "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    start_geo_tunnel
    release_geo_lock
    ;;
  stop-geo|stop-awg98)
    acquire_geo_lock || exit 1
    touch "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    stop_geo_tunnel_internal
    release_geo_lock
    ;;
  restart-geo|restart-awg98)
    acquire_geo_lock || exit 1
    rm -f "$RUN_DIR/geo_stopped.flag" 2>/dev/null
    log_i "Перезапуск геоблок-туннеля AWG98 (/geo/)..."
    stop_geo_tunnel_internal
    start_geo_tunnel
    release_geo_lock
    ;;
  profile-status)
    ptype=$(cat "$WARP_PROFILE_TYPE" 2>/dev/null || echo "Free WARP")
    pkind=$(detect_warp99_profile_type)
    ppath=""
    [ -n "$pkind" ] && ppath=$(get_warp99_profile_path)

    geotype=$(cat "$GEO_PROFILE_TYPE" 2>/dev/null || echo "None")
    geokind=$(detect_geo98_profile_type)
    geopath=""
    [ -n "$geokind" ] && geopath=$(get_geo98_profile_path)

    printf '{"profile_type":"%s","detected_kind":"%s","detected_path":"%s","geo_type":"%s","geo_kind":"%s","geo_path":"%s"}\n' \
      "$ptype" "$pkind" "$ppath" "$geotype" "$geokind" "$geopath"
    ;;
  sync-dest-rules)
    install_dest_rules
    ;;
  apply-custom|reload)
    acquire_warp_lock || exit 1
    log_i "Применение конфигураций из /ru/ и /geo/..."
    stop_tunnel_internal
    rm -f "$WARP_CONF" "$WARP_ADAPT_STATE" "$GEO_CONF" 2>/dev/null
    generate_warp_config || log_w "Не удалось собрать конфиг AWG99"
    [ "${ENABLE_GEO_WARP:-1}" = "1" ] && generate_geo98_config 2>/dev/null || true
    start_tunnel
    release_warp_lock
    ;;
  rekey)
    acquire_warp_lock || exit 1
    local ptype
    ptype=$(cat "$WARP_PROFILE_TYPE" 2>/dev/null || echo "ecubz_warp.conf")
    if [ "$ptype" != "Free WARP" ] && [ "$ptype" != "ecubz_warp.conf" ]; then
      log_i "Перезапуск профиля $ptype по запросу..."
      stop_warp99_internal
      rm -f "$WARP_CONF" "$WARP_ADAPT_STATE" 2>/dev/null
      generate_warp_config
      if [ "$ENABLE_WARP" = "1" ]; then start_warp99_internal || { release_warp_lock; exit 1; }; fi
      release_warp_lock
      exit 0
    fi
    log_i "Перегенерация профиля ecubz_warp.conf по запросу..."
    stop_warp99_internal
    rm -f "$WARP_CONF" "$RU_CONF_DIR/ecubz_warp.conf" "$WARP_ADAPT_STATE" "$WARP_PROFILE_TYPE" 2>/dev/null
    if ! generate_warp_config; then
      release_warp_lock
      exit 1
    fi
    if [ "$ENABLE_WARP" = "1" ]; then start_warp99_internal || { release_warp_lock; exit 1; }; fi
    release_warp_lock
    ;;
  get-apps-uids)
    get_apps_black_uids
    ;;
esac
