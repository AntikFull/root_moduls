#!/system/bin/sh

MODDIR=${0%/*}

case "$1" in
  --signal-refresh) touch "$MODDIR/.force_refresh" 2>/dev/null; exit 0 ;;
  --signal-reload) touch "$MODDIR/.reload" 2>/dev/null; exit 0 ;;
esac

MODULE_ID="AIUnblock"
DATA_DIR="/data/adb/$MODULE_ID"
LOG_DIR="$DATA_DIR/logs"
LOG="$LOG_DIR/AIUnblock_debug.log"
LOG_OLD="$LOG_DIR/AIUnblock_debug.log.1"
ROUTER_LOG="$LOG_DIR/AIUnblock_router_debug.log"
ROUTER_LOG_OLD="$LOG_DIR/AIUnblock_router_debug.log.1"
PUBLIC_LOG_DIR="/sdcard/eCubz/AIUnblock/logs"
AUTO_DIAG_MARKER="$DATA_DIR/.last_auto_diag"
LOCKDIR="$MODDIR/.daemon.lock"
ROUTER_PID_FILE="$MODDIR/.router.pid"
CORE_BIN="$MODDIR/bin/aiunblock-native"
SNI_ROUTES="$MODDIR/sni_routes.conf"
GATEWAY_DIR="$MODDIR/gateways"
PROXY_OVERRIDE="$MODDIR/proxies.override"
SMARTDNS_CONF="$MODDIR/smartdns.conf"
SMARTDNS_USER_CONF="$MODDIR/smartdns.user.conf"
PROXIES_CONF="$MODDIR/proxies.conf"
ROUTER_PORT=15359
PACKAGES_LIST="/data/system/packages.list"

# Не все root-менеджеры дают одинаковый PATH. Гарантируем системные бинарники.
case ":$PATH:" in
  *":/system/bin:"*) ;;
  *) PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"; export PATH ;;
esac

CHECK_INTERVAL=1800
NO_APP_CHECK_INTERVAL=900
# Аварийные повторы идут с нарастающей паузой, чтобы не будить CPU каждые 30с часами.
FAST_RETRY_MIN=30
FAST_RETRY_MAX=900
# Сторожевой цикл: 15с только пока что-то не в порядке, иначе редкие пробуждения.
WATCHDOG_BUSY=15
WATCHDOG_IDLE=120
LOG_MAX_BYTES=524288
LOG_ROTATE_EVERY=20
PROBE_MAX_TIME=4
DOH_MAX_TIME=6
MAX_PROXY_CANDIDATES=8
XTABLES_WAIT=10
INIT_RETRIES=5
INIT_RETRY_DELAY=2
AUTH_RETRIES=2
AUTH_RETRY_DELAY=2
PUBLIC_MIRROR_INTERVAL=600
FIREWALL_SCAN_INTERVAL=3600
DEP_RETRY_DELAY=60
DEP_RETRIES=10
AUTO_DIAG_FAILURES=3
AUTO_DIAG_COOLDOWN=21600

IPV6_SUPPORTED=1
IPTABLES_WAIT_SUPPORTED=0
IP6TABLES_WAIT_SUPPORTED=0
IPTABLES_RESTORE_WAIT_SUPPORTED=0
IP6TABLES_RESTORE_WAIT_SUPPORTED=0
COMMENT_SUPPORTED=1
REJECT4_TARGET="REJECT --reject-with icmp-port-unreachable"
REJECT4_TCP_TARGET="REJECT --reject-with tcp-reset"
REJECT6_TARGET="REJECT --reject-with icmp6-port-unreachable"
TIMEOUT_SUPPORTED=1
NOW=0
BOOT_COMPLETED=0
PUBLIC_STORAGE_READY=0
NATIVE_SELFTEST_LINE=""
LAST_FIREWALL_SCAN=0
LAST_PACKAGES_STAMP=""
LOOP_TICK=0
BACKOFF_INTERVAL=$FAST_RETRY_MIN

CURRENT_GEMINI=""
CURRENT_NOTEBOOK=""
GEMINI_ROUTER_READY=0
NOTEBOOK_ROUTER_READY=0
CURRENT_CHATGPT=""
CURRENT_CLAUDE=""
CURRENT_GROK=""
WAITING_FOR_NETWORK=0
RETRY_SOON=0
NETWORK_WAIT_LOGGED=0
PM_WAIT_LOGGED=0
DOH_RESOLVERS=""
AUTH_DNS=""
PROXIES=""
AI_PROXIES=""
LAST_PUBLIC_MIRROR=0
HEALTH_FAILURE_STREAK=0
LAST_HEALTH="starting"
LAST_MIRRORED_HEALTH=""
LAST_ROUTER_UP=-1
FIREWALL_OVERLAP_UIDS=""
LAST_FIREWALL_OVERLAP=""
ROUTER_PID_CACHE=""
SMARTDNS_USER_DNS=""
AUTH_DNS_BASE=""
BLOCKED_LOC=RU
# Обычный резолвер: его ответ = сам сервис, а не обход. Кандидаты, совпавшие
# с этим ответом, отбраковываются при выборе gateway.
PUBLIC_DNS_CHECK=8.8.8.8
CMT="-m comment --comment AIUNBLOCK"
CMT_FAIL="-m comment --comment AIUNBLOCK_FAIL"
NEXT_INTERVAL=$CHECK_INTERVAL
NEXT_REFRESH=0

[ -f "$MODDIR/lib/module_meta.sh" ] && . "$MODDIR/lib/module_meta.sh"
load_module_metadata "$MODDIR/module.prop"

LOG_VERSION_MARKER="$DATA_DIR/.log_version"
PUBLIC_LOG_VERSION_MARKER="$DATA_DIR/.public_log_version"
previous_log_version=$(cat "$LOG_VERSION_MARKER" 2>/dev/null)
if [ "$previous_log_version" != "$MODULE_VERSION_LABEL" ]; then
  rm -rf "$LOG_DIR" "$DATA_DIR/diagnostics" 2>/dev/null
  rm -f "$AUTO_DIAG_MARKER" 2>/dev/null
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '%s\n' "$MODULE_VERSION_LABEL" > "$LOG_VERSION_MARKER" 2>/dev/null
  rm -f "$PUBLIC_LOG_VERSION_MARKER" 2>/dev/null
fi

mkdir -p "$LOG_DIR" "$GATEWAY_DIR" 2>/dev/null

[ -f "$MODDIR/lib/config.sh" ] && . "$MODDIR/lib/config.sh"
[ -f "$MODDIR/lib/apps.sh" ] && . "$MODDIR/lib/apps.sh"

log() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$LOG"
}

# Монотонные секунды из /proc/uptime: без fork и без скачков при коррекции часов
# (NTP на раннем этапе загрузки раньше мог увести next_refresh далеко в будущее).
clock_now() {
  local up rest
  if read -r up rest 2>/dev/null < /proc/uptime; then
    NOW=${up%%.*}
    case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
    [ "$NOW" -gt 0 ] && return 0
  fi
  NOW=$(date +%s 2>/dev/null)
  case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
}

# sys.boot_completed больше никогда не сбрасывается в 0 — спрашиваем getprop только до первой единицы.
boot_completed() {
  [ "$BOOT_COMPLETED" -eq 1 ] && return 0
  [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || return 1
  BOOT_COMPLETED=1
  return 0
}

# timeout есть не во всех прошивках; без него просто выполняем команду напрямую.
run_timeout() {
  local secs="$1"; shift
  if [ "$TIMEOUT_SUPPORTED" -eq 1 ]; then timeout "$secs" "$@"; else "$@"; fi
}

# Метка изменения списка пакетов: установка/удаление приложения видна без запуска pm.
packages_stamp() {
  stat -c '%Y.%s' "$PACKAGES_LIST" 2>/dev/null
}

rotate_file_copytruncate() {
  local file="$1" old="$2" size
  [ -f "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null)
  [ -n "$size" ] || return 0
  if [ "$size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
    cp -f "$file" "$old" 2>/dev/null || return 0
    : > "$file"
    chmod 0600 "$file" "$old" 2>/dev/null
  fi
}

rotate_logs() {
  rotate_file_copytruncate "$LOG" "$LOG_OLD"
  rotate_file_copytruncate "$ROUTER_LOG" "$ROUTER_LOG_OLD"
}

public_storage_ready() {
  local public_version
  boot_completed || return 1
  [ -d /sdcard ] && [ -w /sdcard ] || return 1
  # Версионную чистку публичной папки делаем один раз за запуск.
  [ "$PUBLIC_STORAGE_READY" -eq 1 ] && { mkdir -p "$PUBLIC_LOG_DIR" 2>/dev/null || return 1; return 0; }

  public_version=$(cat "$PUBLIC_LOG_VERSION_MARKER" 2>/dev/null)
  if [ "$public_version" != "$MODULE_VERSION_LABEL" ]; then
    rm -rf "$PUBLIC_LOG_DIR" 2>/dev/null
    mkdir -p "$PUBLIC_LOG_DIR" 2>/dev/null || return 1
    printf '%s\n' "$MODULE_VERSION_LABEL" > "$PUBLIC_LOG_VERSION_MARKER" 2>/dev/null
    chmod 0600 "$PUBLIC_LOG_VERSION_MARKER" 2>/dev/null
  else
    mkdir -p "$PUBLIC_LOG_DIR" 2>/dev/null || return 1
  fi
  PUBLIC_STORAGE_READY=1
  return 0
}

copy_if_changed() {
  local src="$1" dst="$2" src_size dst_size
  [ -f "$src" ] || return 0
  if [ -f "$dst" ]; then
    if command -v cmp >/dev/null 2>&1 && cmp -s "$src" "$dst" 2>/dev/null; then return 0; fi
    src_size=$(wc -c < "$src" 2>/dev/null); dst_size=$(wc -c < "$dst" 2>/dev/null)
    [ -n "$src_size" ] && [ "$src_size" = "$dst_size" ] && return 0
  fi
  cp -f "$src" "$dst" 2>/dev/null && chmod 0644 "$dst" 2>/dev/null
}

human_health() {
  case "$LAST_HEALTH" in
    ok) echo "Работает" ;;
    noapps) echo "Поддерживаемые приложения не найдены" ;;
    offline) echo "Ожидание подключения к интернету" ;;
    problem) echo "Обнаружена проблема, модуль пробует восстановиться" ;;
    *) echo "Запуск / проверка" ;;
  esac
}

write_public_report() {
  local tmp target_count router_text hosts_status
  public_storage_ready || return 1
  tmp="$PUBLIC_LOG_DIR/.AIUnblock_report.$$.tmp"
  target_count=$(all_target_uids 2>/dev/null | wc -w 2>/dev/null)
  router_text="не запущен"; router_running && router_text="работает"
  hosts_status=$(cat "$MODDIR/.hosts_status" 2>/dev/null); [ -n "$hosts_status" ] || hosts_status="выключены / не требуются"
  {
    echo "AI Unblock RU $MODULE_VERSION_LABEL"
    echo "Обновлено: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    echo "Статус: $(human_health)"
    echo "Router: $router_text"
    echo "ABI core: $(cat "$MODDIR/.native_abi" 2>/dev/null || echo unknown)"
    echo "Native: ${NATIVE_SELFTEST_LINE:-отсутствует}"
    echo "Найдено UID поддерживаемых приложений: ${target_count:-0}"
    if [ -n "$FIREWALL_OVERLAP_UIDS" ]; then
      echo "Совместимость firewall: ВНИМАНИЕ — сторонние правила для UID:$FIREWALL_OVERLAP_UIDS"
    else
      echo "Совместимость firewall: явных пересечений не обнаружено"
    fi
    echo "Hosts: $hosts_status"
    echo ""
    echo "Сервисы:"
    [ -n "$GEMINI_UIDS" ] && { [ -n "$CURRENT_GEMINI" ] && [ "$GEMINI_ROUTER_READY" -eq 1 ] && echo "- Gemini (приложение): OK, TLS через router проверен" || echo "- Gemini (приложение): router/TLS не прошёл проверку"; }
    [ -n "$GEMINI_SNI_UIDS" ] && { [ -n "$CURRENT_GEMINI" ] && [ "$GEMINI_ROUTER_READY" -eq 1 ] && echo "- Gemini в Google: OK, TLS через router проверен" || echo "- Gemini в Google: router/TLS не прошёл проверку"; }
    [ -n "$NOTEBOOK_UIDS" ] && { [ -n "$CURRENT_NOTEBOOK" ] && [ "$NOTEBOOK_ROUTER_READY" -eq 1 ] && echo "- NotebookLM: OK, TLS через router проверен" || echo "- NotebookLM: router/TLS не прошёл проверку"; }
    [ -n "$CHATGPT_UIDS" ] && { [ -n "$CURRENT_CHATGPT" ] && echo "- ChatGPT: OK" || echo "- ChatGPT: нет рабочего маршрута"; }
    [ -n "$CLAUDE_UIDS" ] && { [ -n "$CURRENT_CLAUDE" ] && echo "- Claude: OK" || echo "- Claude: нет рабочего маршрута"; }
    [ -n "$GROK_UIDS" ] && { [ -n "$CURRENT_GROK" ] && echo "- Grok: OK" || echo "- Grok: нет рабочего маршрута"; }
    echo ""
    echo "Если есть проблема — отправьте в поддержку всю папку:"
    echo "$PUBLIC_LOG_DIR"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$PUBLIC_LOG_DIR/AIUnblock_report.txt" 2>/dev/null
  chmod 0644 "$PUBLIC_LOG_DIR/AIUnblock_report.txt" 2>/dev/null
}

mirror_public_logs() {
  clock_now
  if [ "$LAST_HEALTH" = "$LAST_MIRRORED_HEALTH" ] &&
     [ "$LAST_PUBLIC_MIRROR" -gt 0 ] 2>/dev/null &&
     [ $((NOW - LAST_PUBLIC_MIRROR)) -lt "$PUBLIC_MIRROR_INTERVAL" ] 2>/dev/null; then
    return 0
  fi
  # Отметку времени ставим ТОЛЬКО когда память реально доступна. Иначе первая же
  public_storage_ready || return 0
  LAST_PUBLIC_MIRROR="$NOW"
  LAST_MIRRORED_HEALTH="$LAST_HEALTH"
  copy_if_changed "$LOG" "$PUBLIC_LOG_DIR/AIUnblock_debug.log"
  copy_if_changed "$LOG_OLD" "$PUBLIC_LOG_DIR/AIUnblock_debug.log.1"
  copy_if_changed "$ROUTER_LOG" "$PUBLIC_LOG_DIR/AIUnblock_router_debug.log"
  copy_if_changed "$ROUTER_LOG_OLD" "$PUBLIC_LOG_DIR/AIUnblock_router_debug.log.1"
  write_public_report || true
}

maybe_auto_diag() {
  # Здесь нужны именно настенные часы: кулдаун переживает перезагрузку.
  local now last=0
  if [ "$LAST_HEALTH" = problem ] && boot_completed; then
    HEALTH_FAILURE_STREAK=$((HEALTH_FAILURE_STREAK + 1))
  else
    HEALTH_FAILURE_STREAK=0
    return 0
  fi
  [ "$HEALTH_FAILURE_STREAK" -ge "$AUTO_DIAG_FAILURES" ] || return 0
  public_storage_ready || return 0
  now=$(date +%s 2>/dev/null); [ -n "$now" ] || return 0
  last=$(cat "$AUTO_DIAG_MARKER" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$AUTO_DIAG_COOLDOWN" ] 2>/dev/null || return 0
  echo "$now" > "$AUTO_DIAG_MARKER" 2>/dev/null
  chmod 0600 "$AUTO_DIAG_MARKER" 2>/dev/null
  log "Повторяющаяся ошибка: автоматически собирается диагностика в $PUBLIC_LOG_DIR"
  ("$MODDIR/bin/aiunblockctl" diag auto >/dev/null 2>&1) &
  HEALTH_FAILURE_STREAK=0
}

is_ipv4() {
  echo "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
    }
  '
}

append_unique() {
  local current="$1" value="$2"
  case " $current " in *" $value "*) echo "$current" ;; *) echo "$current $value" ;; esac
}

sanitize_ipv4_list() {
  local input="$1" out="" ip
  for ip in $input; do
    is_ipv4 "$ip" || continue
    out=$(append_unique "$out" "$ip")
  done
  echo "$out"
}

# AUTH_DNS собирается из базового списка + пользовательских DNS из smartdns.
# Раньше load_proxy_config затирал AUTH_DNS и пользовательские DNS терялись
# после первого же refresh_all — до следующего reload.
compose_auth_dns() {
  local ip out=""
  for ip in $AUTH_DNS_BASE $SMARTDNS_USER_DNS; do
    is_ipv4 "$ip" || continue
    out=$(append_unique "$out" "$ip")
  done
  AUTH_DNS="$out"
}

load_proxy_config() {
  PUBLIC_PROXIES="62.133.62.97 103.27.157.38 103.27.157.100 45.155.204.190 37.230.192.51 95.182.120.241 95.216.204.218 80.253.249.40 185.246.223.127 87.228.47.204"
  PUBLIC_AI_PROXIES="87.228.47.204 185.246.223.127 103.27.157.38 103.27.157.100 62.133.62.97 45.155.204.190 37.230.192.51 95.182.120.241 95.216.204.218 80.253.249.40"
  AUTH_DNS_BASE="80.253.249.40 103.27.157.38 103.27.157.100 95.216.204.218 111.88.96.50 111.88.96.51"

  if [ -r "$PROXIES_CONF" ]; then
    local value
    value=$(sed -n 's/^PUBLIC_PROXIES="\(.*\)"$/\1/p' "$PROXIES_CONF" | tail -n 1)
    [ -n "$value" ] && PUBLIC_PROXIES=$(sanitize_ipv4_list "$value")
    value=$(sed -n 's/^PUBLIC_AI_PROXIES="\(.*\)"$/\1/p' "$PROXIES_CONF" | tail -n 1)
    [ -n "$value" ] && PUBLIC_AI_PROXIES=$(sanitize_ipv4_list "$value")
    value=$(sed -n 's/^AUTH_DNS="\(.*\)"$/\1/p' "$PROXIES_CONF" | tail -n 1)
    [ -n "$value" ] && AUTH_DNS_BASE=$(sanitize_ipv4_list "$value")
  fi

  PROXIES="$PUBLIC_PROXIES"
  AI_PROXIES="$PUBLIC_AI_PROXIES"
  compose_auth_dns

  if [ -r "$PROXY_OVERRIDE" ]; then
    local override
    override=$(awk -F. '
      NF == 4 {
        valid=1
        for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) valid=0
        if (valid && !seen[$0]++) print $0
      }
    ' "$PROXY_OVERRIDE" | tr '\n' ' ')
    if [ -n "$override" ]; then
      PROXIES="$override $PROXIES"
      AI_PROXIES="$override $AI_PROXIES"
      log "Загружен proxies.override (значения скрыты из лога)"
    fi
  fi
}

load_smartdns_file() {
  local file="$1" protocol address extra
  [ -r "$file" ] || return 0
  while read -r protocol address extra; do
    case "$protocol" in ""|'#'*) continue ;; esac
    [ -n "$address" ] || continue
    [ -z "$extra" ] || { log "Smart DNS: пропущена некорректная строка в ${file##*/}"; continue; }
    case "$protocol" in
      DOH)
        case "$address" in https://*) DOH_RESOLVERS=$(append_unique "$DOH_RESOLVERS" "$address") ;; *) log "Smart DNS: DoH должен использовать https://" ;; esac
        ;;
      DNS)
        if is_ipv4 "$address"; then SMARTDNS_USER_DNS=$(append_unique "$SMARTDNS_USER_DNS" "$address"); else log "Smart DNS: некорректный DNS IPv4 $address"; fi
        ;;
      DOT) log "Smart DNS: DoT '$address' игнорируется — DoT-клиент отсутствует; используйте DOH/DNS" ;;
      *) log "Smart DNS: неизвестный протокол $protocol" ;;
    esac
  done < "$file"
}

load_smartdns_resolvers() {
  DOH_RESOLVERS=""
  SMARTDNS_USER_DNS=""
  load_smartdns_file "$SMARTDNS_CONF"
  load_smartdns_file "$SMARTDNS_USER_CONF"
  compose_auth_dns
  if [ -z "$DOH_RESOLVERS" ]; then
    DOH_RESOLVERS="https://dns.malw.link/dns-query https://xbox-dns.ru/dns-query"
    log "Smart DNS: включён встроенный DoH fallback"
  fi
  log "Smart DNS: DoH=$(echo $DOH_RESOLVERS | wc -w), DNS-auth=$(echo $AUTH_DNS | wc -w)"
}

reload_runtime_config() {
  AIUNBLOCK_CONFIG_FILE="$MODDIR/install.conf"
  config_load "$AIUNBLOCK_CONFIG_FILE"
  load_proxy_config
  load_smartdns_resolvers
}

configure_xtables_wait() {
  iptables -w 2 -t filter -S OUTPUT >/dev/null 2>&1 && IPTABLES_WAIT_SUPPORTED=1
  [ "$IPV6_SUPPORTED" -eq 1 ] && ip6tables -w 2 -t filter -S OUTPUT >/dev/null 2>&1 && IP6TABLES_WAIT_SUPPORTED=1
  iptables-restore -w 1 --help >/dev/null 2>&1 && IPTABLES_RESTORE_WAIT_SUPPORTED=1
  [ "$IPV6_SUPPORTED" -eq 1 ] && ip6tables-restore -w 1 --help >/dev/null 2>&1 && IP6TABLES_RESTORE_WAIT_SUPPORTED=1
}

# Разные прошивки/ядра собирают netfilter по-разному: где-то нет xt_comment,
# где-то нет REJECT. Проверяем один раз на живой временной цепочке и подстраиваемся,
# вместо того чтобы падать на install_hooks.
configure_xtables_features() {
  ipt -t filter -N AIUNBLOCK_PROBE 2>/dev/null
  ipt -t filter -F AIUNBLOCK_PROBE 2>/dev/null
  if ipt -t filter -A AIUNBLOCK_PROBE -m comment --comment AIUNBLOCK -j RETURN 2>/dev/null; then
    COMMENT_SUPPORTED=1
  else
    COMMENT_SUPPORTED=0
    log "ПРЕДУПРЕЖДЕНИЕ: xt_comment недоступен; правила ставятся без меток"
  fi
  ipt -t filter -F AIUNBLOCK_PROBE 2>/dev/null
  if ! ipt -t filter -A AIUNBLOCK_PROBE -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
    REJECT4_TARGET="DROP"
    log "ПРЕДУПРЕЖДЕНИЕ: REJECT (icmp-port-unreachable) недоступен; используется DROP"
  fi
  ipt -t filter -F AIUNBLOCK_PROBE 2>/dev/null
  if ! ipt -t filter -A AIUNBLOCK_PROBE -p tcp --dport 443 -j REJECT --reject-with tcp-reset 2>/dev/null; then
    REJECT4_TCP_TARGET="DROP"
    log "ПРЕДУПРЕЖДЕНИЕ: REJECT (tcp-reset) недоступен; используется DROP"
  fi
  ipt -t filter -F AIUNBLOCK_PROBE 2>/dev/null
  ipt -t filter -X AIUNBLOCK_PROBE 2>/dev/null

  if [ "$IPV6_SUPPORTED" -eq 1 ]; then
    ip6t -t filter -N AIUNBLOCK_PROBE 2>/dev/null
    ip6t -t filter -F AIUNBLOCK_PROBE 2>/dev/null
    if ! ip6t -t filter -A AIUNBLOCK_PROBE -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null; then
      REJECT6_TARGET="DROP"
      log "ПРЕДУПРЕЖДЕНИЕ: REJECT6 недоступен; используется DROP"
    fi
    ip6t -t filter -F AIUNBLOCK_PROBE 2>/dev/null
    ip6t -t filter -X AIUNBLOCK_PROBE 2>/dev/null
  fi

  if [ "$COMMENT_SUPPORTED" -eq 1 ]; then
    CMT="-m comment --comment AIUNBLOCK"
    CMT_FAIL="-m comment --comment AIUNBLOCK_FAIL"
  else
    CMT=""
    CMT_FAIL=""
  fi
}

ipt() { if [ "$IPTABLES_WAIT_SUPPORTED" -eq 1 ]; then iptables -w "$XTABLES_WAIT" "$@"; else iptables "$@"; fi; }
ip6t() { if [ "$IP6TABLES_WAIT_SUPPORTED" -eq 1 ]; then ip6tables -w "$XTABLES_WAIT" "$@"; else ip6tables "$@"; fi; }
ipt_restore() { if [ "$IPTABLES_RESTORE_WAIT_SUPPORTED" -eq 1 ]; then iptables-restore -w "$XTABLES_WAIT" "$@"; else iptables-restore "$@"; fi; }
ip6t_restore() { if [ "$IP6TABLES_RESTORE_WAIT_SUPPORTED" -eq 1 ]; then ip6tables-restore -w "$XTABLES_WAIT" "$@"; else ip6tables-restore "$@"; fi; }

check_dependencies() {
  local missing=0 c selftest_rc=0
  for c in getprop ip iptables iptables-restore awk sed grep date; do
    command -v "$c" >/dev/null 2>&1 || { log "ОШИБКА: нет обязательной команды $c"; missing=1; }
  done
  # Необязательное: деградируем, но не умираем.
  command -v timeout >/dev/null 2>&1 || {
    TIMEOUT_SUPPORTED=0
    log "ПРЕДУПРЕЖДЕНИЕ: нет timeout; сетевые проверки идут со своими внутренними таймаутами"
  }
  for c in pm cmd sort wc stat; do
    command -v "$c" >/dev/null 2>&1 || log "ПРЕДУПРЕЖДЕНИЕ: нет команды $c; используется запасной путь"
  done
  if ! command -v ip6tables >/dev/null 2>&1 || ! command -v ip6tables-restore >/dev/null 2>&1; then
    IPV6_SUPPORTED=0
    log "ПРЕДУПРЕЖДЕНИЕ: ip6tables недоступен; IPv6 guard выключен"
  fi
  [ -x "$CORE_BIN" ] || { log "ОШИБКА: отсутствует aiunblock-native"; missing=1; }
  if [ -x "$CORE_BIN" ]; then
    # запускал self-test заново каждые две минуты.
    NATIVE_SELFTEST_LINE=$("$CORE_BIN" self-test 2>&1)
    selftest_rc=$?
    NATIVE_SELFTEST_LINE=$(echo "$NATIVE_SELFTEST_LINE" | head -n 1)
    if [ "$selftest_rc" -ne 0 ]; then
      log "ОШИБКА: aiunblock-native self-test не пройден: $NATIVE_SELFTEST_LINE"
      missing=1
    fi
  fi
  [ -s "$SNI_ROUTES" ] || { log "ОШИБКА: отсутствует sni_routes.conf"; missing=1; }
  # есть таблица nat (важно для урезанных/GKI-сборок).
  if ! iptables -t nat -S OUTPUT >/dev/null 2>&1; then
    log "ПРЕДУПРЕЖДЕНИЕ: таблица nat пока недоступна (ядро/netd не готовы); ждм в init_chains"
  fi
  [ "$missing" -eq 0 ]
}

# убивал супервизор до перезагрузки. Теперь пробуем несколько раз.
check_dependencies_with_retry() {
  local n=1
  while [ "$n" -le "$DEP_RETRIES" ]; do
    check_dependencies && return 0
    log "Зависимости не готовы (попытка $n/$DEP_RETRIES); повтор через ${DEP_RETRY_DELAY}с"
    sleep "$DEP_RETRY_DELAY"
    n=$((n + 1))
  done
  return 1
}

secure_permissions() {
  mkdir -p "$LOG_DIR" "$GATEWAY_DIR" 2>/dev/null
  touch "$LOG" "$ROUTER_LOG" 2>/dev/null
  chmod 0600 "$LOG" "$ROUTER_LOG" "$LOG_OLD" "$ROUTER_LOG_OLD" 2>/dev/null
  chmod 0700 "$GATEWAY_DIR" 2>/dev/null
  chmod 0600 "$GATEWAY_DIR"/*.current 2>/dev/null
  chmod 0700 "$CORE_BIN" 2>/dev/null
  chmod 0755 "$MODDIR/service.sh" "$MODDIR/bin/aiunblockctl" 2>/dev/null
  chmod 0600 "$SNI_ROUTES" 2>/dev/null
  chmod 0600 "$MODDIR/app_locales.state" "$MODDIR/proxies.override" "$MODDIR/smartdns.user.conf" "$MODDIR/apps.user.list" 2>/dev/null
}

router_pid() {
  local pid
  pid=$(cat "$ROUTER_PID_FILE" 2>/dev/null)
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  echo "$pid"
}

# Вызывается на каждом пробуждении, поэтому без подстановок команд:
# read из файла и kill -0 — встроенные в шелл, процессы не порождаются.
# Полную сверку /proc/PID/cmdline делаем только при смене PID.
router_running() {
  local pid cmdline
  # 2>/dev/null обязан идти ПЕРЕД чтением: иначе сообщение об отсутствующем файле
  # печатает сам шелл, до применения перенаправления.
  read -r pid 2>/dev/null < "$ROUTER_PID_FILE" || return 1
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$pid" = "$ROUTER_PID_CACHE" ] && return 0
  cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case "$cmdline" in *"$CORE_BIN"*) ROUTER_PID_CACHE="$pid"; return 0 ;; esac
  return 1
}

stop_router() {
  local pid
  ROUTER_PID_CACHE=""
  pid=$(router_pid) || { rm -f "$ROUTER_PID_FILE"; return 0; }
  if router_running; then
    kill "$pid" 2>/dev/null
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$ROUTER_PID_FILE"
}

start_router() {
  local pid attempt
  router_running && return 0
  stop_router
  [ -x "$CORE_BIN" ] || return 1
  [ -s "$SNI_ROUTES" ] || return 1
  "$CORE_BIN" router -listen "127.0.0.1:$ROUTER_PORT" -routes "$SNI_ROUTES" -gateway-dir "$GATEWAY_DIR" >> "$ROUTER_LOG" 2>&1 &
  pid=$!
  echo "$pid" > "$ROUTER_PID_FILE"
  chmod 0600 "$ROUTER_PID_FILE" 2>/dev/null
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    router_running && { log "SNI-router запущен PID=$pid 127.0.0.1:$ROUTER_PORT"; return 0; }
    sleep 0.1
    attempt=$((attempt + 1))
  done
  log "ОШИБКА: SNI-router не запустился"
  rm -f "$ROUTER_PID_FILE"
  return 1
}

maintain_router() {
  router_running && return 0
  rotate_file_copytruncate "$ROUTER_LOG" "$ROUTER_LOG_OLD"
  start_router
}

cleanup_stale_temp() {
  rm -rf "$GATEWAY_DIR"/.select.* "$GATEWAY_DIR"/.probe.* 2>/dev/null
  rm -f "$GATEWAY_DIR"/.doh.* "$DATA_DIR"/.firewall_scan.* 2>/dev/null
}

acquire_lock() {
  local old_pid cmdline
  if mkdir "$LOCKDIR" 2>/dev/null; then echo "$$" > "$LOCKDIR/pid"; return 0; fi
  old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
  case "$old_pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$old_pid" 2>/dev/null; then
        cmdline=$(tr '\000' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)
        case "$cmdline" in
          *"$MODDIR/service.sh"*) log "Повторный supervisor отклонн: PID $old_pid"; return 1 ;;
        esac
        log "Найден stale lock с переиспользованным PID $old_pid; lock пересоздан"
      fi
      ;;
  esac
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  echo "$$" > "$LOCKDIR/pid"
}

release_lock() { rm -rf "$LOCKDIR"; }
shutdown_service() { stop_router; release_lock; }

ensure_chain() {
  local family="$1" table="$2" chain="$3"
  if [ "$family" = 4 ]; then
    ipt -t "$table" -N "$chain" 2>/dev/null || true
    ipt -t "$table" -S "$chain" >/dev/null 2>&1
  else
    ip6t -t "$table" -N "$chain" 2>/dev/null || true
    ip6t -t "$table" -S "$chain" >/dev/null 2>&1
  fi
}

init_chains() {
  local chain
  for chain in AIUNBLOCK_OUT AIUNBLOCK_SNI GEMINI_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
    ensure_chain 4 nat "$chain" || return 1
  done
  ensure_chain 4 filter AIUNBLOCK_QUIC || return 1
  ensure_chain 4 filter AIUNBLOCK_FAIL || return 1
  if [ "$IPV6_SUPPORTED" -eq 1 ]; then ensure_chain 6 filter AIUNBLOCK_V6 || return 1; fi
  return 0
}

init_chains_with_retry() {
  local n=1
  while [ "$n" -le "$INIT_RETRIES" ]; do
    init_chains && return 0
    [ "$n" -lt "$INIT_RETRIES" ] && sleep "$INIT_RETRY_DELAY"
    n=$((n + 1))
  done
  return 1
}

remove_old_hook_rules() {
  while ipt -C OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_GUARD 2>/dev/null; do
    ipt -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_GUARD 2>/dev/null || break
  done
  while ipt -C OUTPUT -p tcp --dport 443 -j AIUNBLOCK_GUARD 2>/dev/null; do
    ipt -D OUTPUT -p tcp --dport 443 -j AIUNBLOCK_GUARD 2>/dev/null || break
  done
  ipt -F AIUNBLOCK_GUARD 2>/dev/null; ipt -X AIUNBLOCK_GUARD 2>/dev/null
  ipt -t nat -F GOOGLE_APP_DNAT 2>/dev/null; ipt -t nat -X GOOGLE_APP_DNAT 2>/dev/null
  if [ "$IPV6_SUPPORTED" -eq 1 ]; then
    while ip6t -C OUTPUT -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6 2>/dev/null; do
      ip6t -D OUTPUT -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6 2>/dev/null || break
    done
  fi
}

install_hooks() {
  ipt -C OUTPUT -p udp --dport 443 $CMT -j AIUNBLOCK_QUIC 2>/dev/null ||
    ipt -I OUTPUT 1 -p udp --dport 443 $CMT -j AIUNBLOCK_QUIC || return 1

  ipt -t nat -C OUTPUT -p tcp --dport 443 $CMT -j AIUNBLOCK_OUT 2>/dev/null ||
    ipt -t nat -I OUTPUT 1 -p tcp --dport 443 $CMT -j AIUNBLOCK_OUT || return 1

  while ipt -C OUTPUT -p tcp --dport 443 $CMT_FAIL -j AIUNBLOCK_FAIL 2>/dev/null; do
    [ "$FAIL_MODE" = 1 ] && break
    ipt -D OUTPUT -p tcp --dport 443 $CMT_FAIL -j AIUNBLOCK_FAIL 2>/dev/null || break
  done
  if [ "$FAIL_MODE" = 1 ]; then
    ipt -C OUTPUT -p tcp --dport 443 $CMT_FAIL -j AIUNBLOCK_FAIL 2>/dev/null ||
      ipt -I OUTPUT 1 -p tcp --dport 443 $CMT_FAIL -j AIUNBLOCK_FAIL || return 1
  fi

  if [ "$IPV6_SUPPORTED" -eq 1 ]; then
    ip6t -C OUTPUT -p tcp --dport 443 $CMT -j AIUNBLOCK_V6 2>/dev/null ||
      ip6t -I OUTPUT 1 -p tcp --dport 443 $CMT -j AIUNBLOCK_V6 || return 1
    ip6t -C OUTPUT -p udp --dport 443 $CMT -j AIUNBLOCK_V6 2>/dev/null ||
      ip6t -I OUTPUT 1 -p udp --dport 443 $CMT -j AIUNBLOCK_V6 || return 1
  fi
  return 0
}

apply_uid_rules() {
  local uid router_ok=0
  router_running && router_ok=1

  {
    echo "*nat"
    echo ":AIUNBLOCK_OUT - [0:0]"
    echo ":AIUNBLOCK_SNI - [0:0]"
    echo "-F AIUNBLOCK_SNI"
    echo "-A AIUNBLOCK_SNI -p tcp --dport 443 -j REDIRECT --to-ports $ROUTER_PORT"
    echo "-A AIUNBLOCK_SNI -j RETURN"
    echo "-F AIUNBLOCK_OUT"
    if [ "$router_ok" -eq 1 ] && [ -n "$CURRENT_GEMINI" ] && [ "$GEMINI_ROUTER_READY" -eq 1 ]; then
      for uid in $GEMINI_SNI_UIDS; do echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j AIUNBLOCK_SNI"; done
      for uid in $GEMINI_UIDS; do echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j AIUNBLOCK_SNI"; done
    fi
    if [ "$router_ok" -eq 1 ] && [ -n "$CURRENT_NOTEBOOK" ] && [ "$NOTEBOOK_ROUTER_READY" -eq 1 ]; then
      for uid in $NOTEBOOK_UIDS; do echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j AIUNBLOCK_SNI"; done
    fi
    if [ -n "$CURRENT_CHATGPT" ]; then for uid in $CHATGPT_UIDS; do echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j CHATGPT_DNAT"; done; fi
    if [ -n "$CURRENT_CLAUDE" ]; then for uid in $CLAUDE_UIDS; do echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j CLAUDE_DNAT"; done; fi
    if [ -n "$CURRENT_GROK" ]; then for uid in $GROK_UIDS; do echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j GROK_DNAT"; done; fi
    echo "-A AIUNBLOCK_OUT -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush || return 1

  {
    echo "*filter"
    echo ":AIUNBLOCK_QUIC - [0:0]"
    echo ":AIUNBLOCK_FAIL - [0:0]"
    echo "-F AIUNBLOCK_QUIC"
    if [ -n "$CURRENT_GEMINI" ] && [ "$router_ok" -eq 1 ] && [ "$GEMINI_ROUTER_READY" -eq 1 ]; then
      for uid in $GEMINI_SNI_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done
      for uid in $GEMINI_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done
    elif [ "$FAIL_MODE" = 1 ]; then
      for uid in $GEMINI_SNI_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done
      for uid in $GEMINI_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done
    fi
    if [ -n "$CURRENT_NOTEBOOK" ] && [ "$router_ok" -eq 1 ] && [ "$NOTEBOOK_ROUTER_READY" -eq 1 ]; then
      for uid in $NOTEBOOK_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done
    elif [ "$FAIL_MODE" = 1 ]; then
      for uid in $NOTEBOOK_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done
    fi
    if [ -n "$CURRENT_CHATGPT" ] || [ "$FAIL_MODE" = 1 ]; then for uid in $CHATGPT_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done; fi
    if [ -n "$CURRENT_CLAUDE" ] || [ "$FAIL_MODE" = 1 ]; then for uid in $CLAUDE_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done; fi
    if [ -n "$CURRENT_GROK" ] || [ "$FAIL_MODE" = 1 ]; then for uid in $GROK_UIDS; do echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j $REJECT4_TARGET"; done; fi
    echo "-A AIUNBLOCK_QUIC -j RETURN"

    echo "-F AIUNBLOCK_FAIL"
    if [ "$FAIL_MODE" = 1 ]; then
      if [ -z "$CURRENT_GEMINI" ] || [ "$router_ok" -eq 0 ] || [ "$GEMINI_ROUTER_READY" -eq 0 ]; then
        for uid in $GEMINI_SNI_UIDS $GEMINI_UIDS; do echo "-A AIUNBLOCK_FAIL -m owner --uid-owner $uid -j $REJECT4_TCP_TARGET"; done
      fi
      if [ -z "$CURRENT_NOTEBOOK" ] || [ "$router_ok" -eq 0 ] || [ "$NOTEBOOK_ROUTER_READY" -eq 0 ]; then for uid in $NOTEBOOK_UIDS; do echo "-A AIUNBLOCK_FAIL -m owner --uid-owner $uid -j $REJECT4_TCP_TARGET"; done; fi
      [ -n "$CURRENT_CHATGPT" ] || for uid in $CHATGPT_UIDS; do echo "-A AIUNBLOCK_FAIL -m owner --uid-owner $uid -j $REJECT4_TCP_TARGET"; done
      [ -n "$CURRENT_CLAUDE" ] || for uid in $CLAUDE_UIDS; do echo "-A AIUNBLOCK_FAIL -m owner --uid-owner $uid -j $REJECT4_TCP_TARGET"; done
      [ -n "$CURRENT_GROK" ] || for uid in $GROK_UIDS; do echo "-A AIUNBLOCK_FAIL -m owner --uid-owner $uid -j $REJECT4_TCP_TARGET"; done
    fi
    echo "-A AIUNBLOCK_FAIL -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush || return 1

  if [ "$IPV6_SUPPORTED" -eq 1 ]; then
    {
      echo "*filter"
      echo ":AIUNBLOCK_V6 - [0:0]"
      echo "-F AIUNBLOCK_V6"
      if [ -n "$CURRENT_GEMINI" ] && [ "$router_ok" -eq 1 ] && [ "$GEMINI_ROUTER_READY" -eq 1 ]; then
        for uid in $GEMINI_SNI_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done
        for uid in $GEMINI_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done
      elif [ "$FAIL_MODE" = 1 ]; then
        for uid in $GEMINI_SNI_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done
        for uid in $GEMINI_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done
      fi
      if [ -n "$CURRENT_NOTEBOOK" ] && [ "$router_ok" -eq 1 ] && [ "$NOTEBOOK_ROUTER_READY" -eq 1 ]; then
        for uid in $NOTEBOOK_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done
      elif [ "$FAIL_MODE" = 1 ]; then
        for uid in $NOTEBOOK_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done
      fi
      if [ -n "$CURRENT_CHATGPT" ] || [ "$FAIL_MODE" = 1 ]; then for uid in $CHATGPT_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done; fi
      if [ -n "$CURRENT_CLAUDE" ] || [ "$FAIL_MODE" = 1 ]; then for uid in $CLAUDE_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done; fi
      if [ -n "$CURRENT_GROK" ] || [ "$FAIL_MODE" = 1 ]; then for uid in $GROK_UIDS; do echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j $REJECT6_TARGET"; done; fi
      echo "-A AIUNBLOCK_V6 -j RETURN"
      echo "COMMIT"
    } | ip6t_restore --noflush || return 1
  fi
  clean_vpnhide_rules
  return 0
}

clean_vpnhide_rules() {
  local uid uids
  uids=$(all_target_uids)
  [ -n "$uids" ] || return 0
  if iptables -t filter -S vpnhide_out >/dev/null 2>&1; then
    for uid in $uids; do
      iptables -t filter -D vpnhide_out -d 127.0.0.0/8 -p tcp -m owner --uid-owner "$uid" -j REJECT --reject-with tcp-reset >/dev/null 2>&1 || true
      iptables -t filter -D vpnhide_out -d 127.0.0.0/8 -p udp -m owner --uid-owner "$uid" -j REJECT --reject-with icmp-port-unreachable >/dev/null 2>&1 || true
    done
  fi
  if ip6tables -t filter -S vpnhide_out6 >/dev/null 2>&1; then
    for uid in $uids; do
      ip6tables -t filter -D vpnhide_out6 -d ::1/128 -p tcp -m owner --uid-owner "$uid" -j REJECT --reject-with tcp-reset >/dev/null 2>&1 || true
      ip6tables -t filter -D vpnhide_out6 -d ::1/128 -p udp -m owner --uid-owner "$uid" -j REJECT --reject-with icmp6-port-unreachable >/dev/null 2>&1 || true
    done
  fi
}

apply_service_rules() {
  local chain="$1" ip="$2"
  is_ipv4 "$ip" || return 1
  {
    echo "*nat"
    echo "-F $chain"
    echo "-A $chain -d $ip -j RETURN"
    echo "-A $chain -p tcp --dport 443 -j DNAT --to-destination $ip:443"
    echo "-A $chain -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush
}

gateway_path() { echo "$GATEWAY_DIR/$1.current"; }
read_gateway() { local v; v=$(cat "$(gateway_path "$1")" 2>/dev/null); is_ipv4 "$v" && echo "$v"; }
publish_gateway() {
  local group="$1" ip="$2" path tmp
  is_ipv4 "$ip" || return 1
  path=$(gateway_path "$group"); tmp="$path.tmp.$$"
  printf '%s\n' "$ip" > "$tmp" || return 1
  chmod 0600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$path"
}

# внутри нативного ядра, обычный DNS используется только если DoH не ответил.
# на каждый DNS-сервер в запасном пути.
discover_doh_gateways() {
  local domain="$1" token="$2" ip source discovered=""
  while read -r ip source; do
    is_ipv4 "$ip" || continue
    case " $discovered " in *" $ip "*) continue ;; esac
    discovered="$discovered $ip"
    log "Resolve[$token]: получен gateway $ip через $source"
  done <<EOF
$(run_timeout $((DOH_MAX_TIME + 6)) "$CORE_BIN" resolve -domain "$domain" \
    -resolvers "$DOH_RESOLVERS" -dns "$AUTH_DNS" -bootstrap "$AUTH_DNS" \
    -timeout "$DOH_MAX_TIME" 2>/dev/null)
EOF
  echo "$discovered"
}

# Все кандидаты проверяются параллельно внутри одного процесса нативного ядра.
# Раньше это был отдельный процесс на каждую пару (IP, домен) — до ~60 стартов
# Go-рантайма на один неудачный подбор gateway.
# Правило выбора прежнее: побеждает первый по порядку кандидат, прошедший ВСЕ домены.
probe_candidates_parallel() {
  local candidates="$1" domains="$2" selected
  [ -n "$candidates" ] || return 1
  selected=$(run_timeout $((PROBE_MAX_TIME * 5 + 4)) "$CORE_BIN" probe \
    -candidates "$candidates" -domains "$domains" \
    -timeout "$PROBE_MAX_TIME" -max "$MAX_PROXY_CANDIDATES" \
    -reject-loc "$BLOCKED_LOC" -public-dns "$PUBLIC_DNS_CHECK" 2>/dev/null | head -n 1)
  is_ipv4 "$selected" || return 1
  echo "$selected"
}

select_proxy() {
  local current="$1" domains="$2" candidates="$3" discovery_domain="$4" token="$5" discovered dedup="" ip selected
  # Проверка текущего gateway тоже уходит в один процесс вместо одного на домен.
  if [ -n "$current" ] && probe_candidates_parallel "$current" "$domains" >/dev/null 2>&1; then
    echo "$current"; return 0
  fi
  discovered=$(discover_doh_gateways "$discovery_domain" "$token")
  for ip in $discovered $candidates; do
    is_ipv4 "$ip" || continue
    [ "$ip" = "$current" ] && continue
    dedup=$(append_unique "$dedup" "$ip")
  done
  selected=$(probe_candidates_parallel "$dedup" "$domains") || return 1
  [ -n "$selected" ] && echo "$selected"
}

send_udp_dns_probe() {
  local dns="$1"
  run_timeout 4 "$CORE_BIN" dns -server "$dns" -domain chatgpt.com -timeout 3 >/dev/null 2>&1
}

authorize_ips() {
  local dns pid pids="" success=0
  for dns in $AUTH_DNS; do (send_udp_dns_probe "$dns") & pids="$pids $!"; done
  for pid in $pids; do wait "$pid" 2>/dev/null && success=$((success + 1)); done
  log "DNS-auth: получен валидный DNS-ответ от $success серверов"
  [ "$success" -gt 0 ]
}

authorize_ips_with_retry() {
  local n=1
  while [ "$n" -le "$AUTH_RETRIES" ]; do
    authorize_ips && return 0
    [ "$n" -lt "$AUTH_RETRIES" ] && sleep "$AUTH_RETRY_DELAY"
    n=$((n + 1))
  done
  return 1
}
# Вызывается на каждом пробуждении, поэтому без пайпов в grep:
# раньше это было 3 процесса, теперь один.
ipv4_network_ready() {
  local route
  route=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 1
  case "$route" in
    *" dev lo "*|*" dev lo") return 1 ;;
    *" dev "*) return 0 ;;
  esac
  return 1
}

refresh_uids() {
  apps_load "$MODDIR"
  log "UID: GeminiSNI=[$GEMINI_SNI_UIDS] Gemini=[$GEMINI_UIDS] Notebook=[$NOTEBOOK_UIDS] ChatGPT=[$CHATGPT_UIDS] Claude=[$CLAUDE_UIDS] Grok=[$GROK_UIDS]"
}

detect_external_firewall_overlap() {
  local tmp uids found=""
  uids=$(all_target_uids)
  [ -n "$uids" ] || { FIREWALL_OVERLAP_UIDS=""; return 0; }
  command -v iptables-save >/dev/null 2>&1 || return 0
  tmp="$DATA_DIR/.firewall_scan.$$"
  run_timeout 4 iptables-save > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  if command -v ip6tables-save >/dev/null 2>&1; then
    run_timeout 4 ip6tables-save >> "$tmp" 2>/dev/null || true
  fi
  # Один проход awk вместо двух grep на каждый UID.
  found=$(awk -v list="$uids" '
    BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) want["uid-owner " a[i]] = a[i] }
    /AIUNBLOCK/ { next }
    !/NFQUEUE|TPROXY|REDIRECT|DNAT|REJECT|DROP|zapret|nfqws/ { next }
    {
      for (key in want) {
        idx = index($0, key)
        if (idx == 0) continue
        rest = substr($0, idx + length(key), 1)
        if (rest == "" || rest == " ") hit[want[key]] = 1
      }
    }
    END { for (i = 1; i <= n; i++) if (hit[a[i]]) printf " %s", a[i] }
  ' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  FIREWALL_OVERLAP_UIDS="$found"
  if [ "$FIREWALL_OVERLAP_UIDS" != "$LAST_FIREWALL_OVERLAP" ]; then
    if [ -n "$FIREWALL_OVERLAP_UIDS" ]; then
      log "ПРЕДУПРЕЖДЕНИЕ: найдены сторонние firewall/NFQUEUE правила для target UID:$FIREWALL_OVERLAP_UIDS; автоматическое вмешательство отключено, см. diagnostic bundle"
    elif [ -n "$LAST_FIREWALL_OVERLAP" ]; then
      log "Стороннее пересечение firewall для target UID больше не обнаружено"
    fi
    LAST_FIREWALL_OVERLAP="$FIREWALL_OVERLAP_UIDS"
  fi
}

cleanup_legacy_owner_rules() {
  # Старые версии ставили правила прямо в OUTPUT. Удаляем только правила для UID из наших списков
  # и только с уникальными chain/QUIC сигнатурами AIUnblock.
  local uid chain
  for uid in $(all_target_uids); do
    for chain in GEMINI_DNAT GOOGLE_APP_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
      while ipt -t nat -C OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j "$chain" 2>/dev/null; do
        ipt -t nat -D OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j "$chain" 2>/dev/null || break
      done
    done
    while ipt -C OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j DROP 2>/dev/null; do
      ipt -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j DROP 2>/dev/null || break
    done
    while ipt -C OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do
      ipt -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || break
    done
    if [ "$IPV6_SUPPORTED" -eq 1 ]; then
      while ip6t -C OUTPUT -m owner --uid-owner "$uid" -j DROP 2>/dev/null; do
        ip6t -D OUTPUT -m owner --uid-owner "$uid" -j DROP 2>/dev/null || break
      done
      while ip6t -C OUTPUT -m owner --uid-owner "$uid" -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null; do
        ip6t -D OUTPUT -m owner --uid-owner "$uid" -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || break
      done
    fi
  done
}

apply_failure_rules() {
  local sg="$CURRENT_GEMINI" sn="$CURRENT_NOTEBOOK" sc="$CURRENT_CHATGPT" scl="$CURRENT_CLAUDE" sgr="$CURRENT_GROK" sgrr="$GEMINI_ROUTER_READY" snrr="$NOTEBOOK_ROUTER_READY"
  CURRENT_GEMINI=""; CURRENT_NOTEBOOK=""; CURRENT_CHATGPT=""; CURRENT_CLAUDE=""; CURRENT_GROK=""
  GEMINI_ROUTER_READY=0; NOTEBOOK_ROUTER_READY=0
  apply_uid_rules && install_hooks
  local rc=$?
  CURRENT_GEMINI="$sg"; CURRENT_NOTEBOOK="$sn"; CURRENT_CHATGPT="$sc"; CURRENT_CLAUDE="$scl"; CURRENT_GROK="$sgr"
  GEMINI_ROUTER_READY="$sgrr"; NOTEBOOK_ROUTER_READY="$snrr"
  return "$rc"
}

router_tls_probe() {
  local domain
  router_running || return 1
  for domain in $1; do
    run_timeout 7 "$CORE_BIN" tls-probe -ip 127.0.0.1 -port "$ROUTER_PORT" -domain "$domain" -timeout 5 >/dev/null 2>&1 || return 1
  done
  return 0
}

selector_start() {
  local name="$1" current="$2" domains="$3" candidates="$4" discovery="$5" outdir="$6"
  (
    local selected
    selected=$(select_proxy "$current" "$domains" "$candidates" "$discovery" "$name") || exit 1
    is_ipv4 "$selected" || exit 1
    printf '%s\n' "$selected" > "$outdir/$name"
  ) &
  SELECTOR_PIDS="$SELECTOR_PIDS $!"
}

refresh_proxy_rules() {
  local dir="$GATEWAY_DIR/.select.$$" old selected gemini_probe_domains
  SELECTOR_PIDS=""
  rm -rf "$dir"; mkdir -p "$dir" || return 1

  gemini_probe_domains="gemini.google.com robinfrontend-pa.googleapis.com proactivebackend-pa.googleapis.com"
  [ -n "$GEMINI_SNI_UIDS$GEMINI_UIDS" ] && selector_start gemini "$CURRENT_GEMINI" "$gemini_probe_domains" "$PROXIES" gemini.google.com "$dir"
  [ -n "$NOTEBOOK_UIDS" ] && selector_start notebook "$CURRENT_NOTEBOOK" "notebooklm-pa.googleapis.com" "$PROXIES" notebooklm-pa.googleapis.com "$dir"
  [ -n "$CHATGPT_UIDS" ] && selector_start chatgpt "$CURRENT_CHATGPT" "chatgpt.com" "$AI_PROXIES" chatgpt.com "$dir"
  [ -n "$CLAUDE_UIDS" ] && selector_start claude "$CURRENT_CLAUDE" "claude.ai" "$AI_PROXIES" claude.ai "$dir"
  [ -n "$GROK_UIDS" ] && selector_start grok "$CURRENT_GROK" "grok.com" "$AI_PROXIES" grok.com "$dir"

  for selected in $SELECTOR_PIDS; do wait "$selected" 2>/dev/null; done

  if [ -n "$GEMINI_SNI_UIDS$GEMINI_UIDS" ]; then
    old="$CURRENT_GEMINI"; selected=$(cat "$dir/gemini" 2>/dev/null)
    if is_ipv4 "$selected" && publish_gateway gemini "$selected"; then
      CURRENT_GEMINI="$selected"; [ "$old" = "$selected" ] || log "Gateway Gemini: $selected"
      GEMINI_ROUTER_READY=1
      if ! router_tls_probe "gemini.google.com robinfrontend-pa.googleapis.com proactivebackend-pa.googleapis.com generativelanguage.googleapis.com"; then
        GEMINI_ROUTER_READY=0; RETRY_SOON=1; log "Gateway Gemini найден, но сквозная TLS-проверка SNI-router не пройдена"
      fi
    else
      CURRENT_GEMINI=""; GEMINI_ROUTER_READY=0; RETRY_SOON=1; log "Gateway Gemini не найден"
    fi
  fi
  if [ -n "$NOTEBOOK_UIDS" ]; then
    old="$CURRENT_NOTEBOOK"; selected=$(cat "$dir/notebook" 2>/dev/null)
    if is_ipv4 "$selected" && publish_gateway notebook "$selected"; then
      CURRENT_NOTEBOOK="$selected"; [ "$old" = "$selected" ] || log "Gateway NotebookLM: $selected"
      if router_tls_probe "notebooklm-pa.googleapis.com"; then NOTEBOOK_ROUTER_READY=1; else NOTEBOOK_ROUTER_READY=0; RETRY_SOON=1; log "Gateway NotebookLM найден, но сквозная TLS-проверка SNI-router не пройдена"; fi
    else
      CURRENT_NOTEBOOK=""; NOTEBOOK_ROUTER_READY=0; RETRY_SOON=1; log "Gateway NotebookLM не найден"
    fi
  fi
  if [ -n "$CHATGPT_UIDS" ]; then
    old="$CURRENT_CHATGPT"; selected=$(cat "$dir/chatgpt" 2>/dev/null)
    if is_ipv4 "$selected" && apply_service_rules CHATGPT_DNAT "$selected" && publish_gateway chatgpt "$selected"; then CURRENT_CHATGPT="$selected"; [ "$old" = "$selected" ] || log "Gateway ChatGPT: $selected"; else CURRENT_CHATGPT=""; RETRY_SOON=1; log "Gateway ChatGPT не найден"; fi
  fi
  if [ -n "$CLAUDE_UIDS" ]; then
    old="$CURRENT_CLAUDE"; selected=$(cat "$dir/claude" 2>/dev/null)
    if is_ipv4 "$selected" && apply_service_rules CLAUDE_DNAT "$selected" && publish_gateway claude "$selected"; then CURRENT_CLAUDE="$selected"; [ "$old" = "$selected" ] || log "Gateway Claude: $selected"; else CURRENT_CLAUDE=""; RETRY_SOON=1; log "Gateway Claude не найден"; fi
  fi
  if [ -n "$GROK_UIDS" ]; then
    old="$CURRENT_GROK"; selected=$(cat "$dir/grok" 2>/dev/null)
    if is_ipv4 "$selected" && apply_service_rules GROK_DNAT "$selected" && publish_gateway grok "$selected"; then CURRENT_GROK="$selected"; [ "$old" = "$selected" ] || log "Gateway Grok: $selected"; else CURRENT_GROK=""; RETRY_SOON=1; log "Gateway Grok не найден"; fi
  fi
  rm -rf "$dir"
}

refresh_all() {
  local alluids
  LAST_HEALTH="checking"
  rotate_logs
  AIUNBLOCK_CONFIG_FILE="$MODDIR/install.conf"; config_load "$AIUNBLOCK_CONFIG_FILE"
  load_proxy_config
  refresh_uids
  LAST_PACKAGES_STAMP=$(packages_stamp)
  # Сканирование чужих правил — это два дампа iptables целиком, поэтому не чаще раза в час.
  clock_now
  if [ $((NOW - LAST_FIREWALL_SCAN)) -ge "$FIREWALL_SCAN_INTERVAL" ] 2>/dev/null; then
    LAST_FIREWALL_SCAN="$NOW"
    detect_external_firewall_overlap
  fi
  alluids=$(all_target_uids)

  if [ -z "$alluids" ] && ! boot_completed; then
    RETRY_SOON=1
    if [ "$PM_WAIT_LOGGED" -eq 0 ]; then log "PackageManager ещ не готов/UID не видны; быстрый повтор"; PM_WAIT_LOGGED=1; fi
  else
    PM_WAIT_LOGGED=0
  fi

  if ! ipv4_network_ready; then
    WAITING_FOR_NETWORK=1; RETRY_SOON=1
    if [ "$NETWORK_WAIT_LOGGED" -eq 0 ]; then log "IPv4-сеть недоступна; применён fail-mode=$FAIL_MODE"; NETWORK_WAIT_LOGGED=1; fi
    apply_failure_rules || log "ОШИБКА: не удалось применить failure rules"
    LAST_HEALTH="offline"
    return 0
  fi

  [ "$WAITING_FOR_NETWORK" -eq 1 ] && log "IPv4-сеть появилась"
  WAITING_FOR_NETWORK=0; NETWORK_WAIT_LOGGED=0; RETRY_SOON=0

  if ! authorize_ips_with_retry; then
    RETRY_SOON=1
    log "DNS-auth не подтверждён; применён fail-mode=$FAIL_MODE"
    apply_failure_rules || log "ОШИБКА: failure rules после DNS-auth"
    LAST_HEALTH="problem"
    return 0
  fi

  refresh_proxy_rules
  if apply_uid_rules && install_hooks; then
    log "Firewall обновлён: только UID из apps.list/apps.user.list; fail=$FAIL_MODE"
  else
    RETRY_SOON=1
    log "ОШИБКА: firewall update failed"
  fi

  if [ -z "$alluids" ] && boot_completed; then
    LAST_HEALTH="noapps"
  elif [ "$RETRY_SOON" -eq 1 ] || needs_fast_retry || ! router_running; then
    LAST_HEALTH="problem"
  else
    LAST_HEALTH="ok"
  fi
}

needs_fast_retry() {
  [ -n "$GEMINI_SNI_UIDS$GEMINI_UIDS" ] && [ -z "$CURRENT_GEMINI" ] && return 0
  [ -n "$GEMINI_SNI_UIDS" ] && [ "$GEMINI_ROUTER_READY" -ne 1 ] && return 0
  [ -n "$NOTEBOOK_UIDS" ] && { [ -z "$CURRENT_NOTEBOOK" ] || [ "$NOTEBOOK_ROUTER_READY" -ne 1 ]; } && return 0
  [ -n "$CHATGPT_UIDS" ] && [ -z "$CURRENT_CHATGPT" ] && return 0
  [ -n "$CLAUDE_UIDS" ] && [ -z "$CURRENT_CLAUDE" ] && return 0
  [ -n "$GROK_UIDS" ] && [ -z "$CURRENT_GROK" ] && return 0
  return 1
}

# Устанавливает NEXT_INTERVAL (глобально: раньше вызов в $( ) терял состояние отката).
next_check_interval() {
  if [ "$WAITING_FOR_NETWORK" -eq 1 ] || [ "$RETRY_SOON" -eq 1 ] || needs_fast_retry; then
    # Экспоненциальный откат 30 → 60 → … → 900с. Плоские 30с на устройстве,
    # где gateway недоступен в принципе, раньше грели CPU часами подряд.
    NEXT_INTERVAL="$BACKOFF_INTERVAL"
    BACKOFF_INTERVAL=$((BACKOFF_INTERVAL * 2))
    [ "$BACKOFF_INTERVAL" -gt "$FAST_RETRY_MAX" ] && BACKOFF_INTERVAL="$FAST_RETRY_MAX"
  else
    BACKOFF_INTERVAL="$FAST_RETRY_MIN"
    if [ -z "$GEMINI_SNI_UIDS$GEMINI_UIDS$NOTEBOOK_UIDS$CHATGPT_UIDS$CLAUDE_UIDS$GROK_UIDS" ]; then
      # Новое целевое приложение отследит вотчер packages.list, это лишь страховка.
      NEXT_INTERVAL="$NO_APP_CHECK_INTERVAL"
    else
      NEXT_INTERVAL="$CHECK_INTERVAL"
    fi
  fi
}

# Полный цикл обслуживания: обновление + диагностика + планирование следующего запуска.
run_cycle() {
  refresh_all
  maybe_auto_diag
  mirror_public_logs
  next_check_interval
  clock_now
  NEXT_REFRESH=$((NOW + NEXT_INTERVAL))
}

case "$1" in
  --stop-router) stop_router; exit 0 ;;
  --apply-locales)
    [ -f "$MODDIR/lib/locales.sh" ] && . "$MODDIR/lib/locales.sh"
    command -v apply_configured_locales >/dev/null 2>&1 && apply_configured_locales "$MODDIR"
    exit 0
    ;;
esac

main_loop() {
  local network_available prev_network=-1 router_up stamp sleep_secs
  secure_permissions
  rotate_logs
  acquire_lock || return 0
  trap shutdown_service EXIT
  trap 'exit 0' HUP INT TERM
  log "AI Unblock $MODULE_VERSION_LABEL (versionCode=$MODULE_VERSION_CODE): supervisor PID=$$"

  check_dependencies_with_retry || { log "КРИТИЧЕСКАЯ ОШИБКА: отсутствуют зависимости"; return 1; }
  configure_xtables_wait
  cleanup_stale_temp
  reload_runtime_config

  while ! init_chains_with_retry; do
    log "Firewall backend ещ не готов; повтор через 30с"
    sleep 30
  done
  configure_xtables_features
  remove_old_hook_rules
  # Чистка правил старых версий нужна ровно один раз за запуск, а не каждый refresh:
  # это десятки вызовов iptables впустую.
  cleanup_legacy_owner_rules

  CURRENT_GEMINI=$(read_gateway gemini)
  CURRENT_NOTEBOOK=$(read_gateway notebook)
  CURRENT_CHATGPT=$(read_gateway chatgpt)
  CURRENT_CLAUDE=$(read_gateway claude)
  CURRENT_GROK=$(read_gateway grok)

  maintain_router || log "ПРЕДУПРЕЖДЕНИЕ: SNI-router пока не запущен; DNAT-сервисы могут работать независимо"
  LAST_ROUTER_UP=0; router_running && LAST_ROUTER_UP=1
  run_cycle

  while true; do
    LOOP_TICK=$((LOOP_TICK + 1))
    [ $((LOOP_TICK % LOG_ROTATE_EVERY)) -eq 0 ] && rotate_logs

    maintain_router || true

    router_up=0; router_running && router_up=1
    if [ "$LAST_ROUTER_UP" -ne -1 ] && [ "$router_up" -ne "$LAST_ROUTER_UP" ]; then
      if [ "$router_up" -eq 0 ]; then
        log "SNI-router потерян: немедленно применяем аварийный режим FAIL_MODE=$FAIL_MODE"
      else
        log "SNI-router восстановлен: немедленно возвращаем штатные per-UID правила"
      fi
      LAST_ROUTER_UP="$router_up"
      run_cycle
    fi
    LAST_ROUTER_UP="$router_up"

    if [ -f "$MODDIR/.reload" ]; then
      rm -f "$MODDIR/.reload"
      reload_runtime_config
      run_cycle
    elif [ -f "$MODDIR/.force_refresh" ]; then
      rm -f "$MODDIR/.force_refresh"
      run_cycle
    else
      network_available=0; ipv4_network_ready && network_available=1
      stamp=$(packages_stamp)
      if [ "$prev_network" -ne -1 ] && [ "$network_available" -ne "$prev_network" ]; then
        prev_network="$network_available"
        run_cycle
      elif [ -n "$stamp" ] && [ -n "$LAST_PACKAGES_STAMP" ] && [ "$stamp" != "$LAST_PACKAGES_STAMP" ]; then
        # Установили/удалили приложение — реагируем сразу, без опроса pm по таймеру.
        log "Список пакетов изменился; перепроверяем UID"
        prev_network="$network_available"
        run_cycle
      else
        prev_network="$network_available"
        clock_now
        if [ "$NOW" -ge "$NEXT_REFRESH" ] 2>/dev/null; then
          run_cycle
        else
          mirror_public_logs
        fi
      fi
    fi

    # Частый сторожевой цикл только пока что-то не в порядке; в штатном режиме
    # просыпаемся редко и не мешаем устройству уходить в глубокий сон.
    if [ "$LAST_HEALTH" = ok ] || [ "$LAST_HEALTH" = noapps ]; then
      sleep_secs="$WATCHDOG_IDLE"
    else
      sleep_secs="$WATCHDOG_BUSY"
    fi
    clock_now
    if [ "$NEXT_REFRESH" -gt "$NOW" ] 2>/dev/null && [ $((NEXT_REFRESH - NOW)) -lt "$sleep_secs" ]; then
      sleep_secs=$((NEXT_REFRESH - NOW))
      [ "$sleep_secs" -lt 5 ] && sleep_secs=5
    fi
    sleep "$sleep_secs"
  done
}

main_loop
