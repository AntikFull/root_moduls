#!/system/bin/sh
# zapret2 background service script with Zero-Battery Inotify Kernel Watcher for Android

MODDIR="${0%/*}"
CONF_FILE="$MODDIR/zapret2.conf"
APPS_LIST="$MODDIR/apps.list"
EXCLUDE_LIST="$MODDIR/exclude.list"
AUTO_DOMAINS_FILE="$MODDIR/auto_domains.list"
EXCLUDE_DOMAINS_FILE="$MODDIR/exclude_domains.list"
FORCE_TCP_APPS_LIST="$MODDIR/force_tcp_apps.list"
LOG_FILE="$MODDIR/zapret2.log"
BIN_DIR="$MODDIR/system/bin"
ON_CHANGE_SCRIPT="$MODDIR/on_change.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Ожидание полной загрузки системы
if [ "$1" != "reload" ]; then
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
  done
  sleep 2
fi

log "=== Запуск службы zapret2 ==="

# Загрузка конфигурации
if [ -f "$CONF_FILE" ]; then
  . "$CONF_FILE"
else
  MODE="EXCLUDE"
  STRATEGY_MODE="AUTO"
  FORCE_TCP="1"
  PORTS_TCP="80,443"
  QNUM="200"
  DESYNC_ARGS_SIMPLE="--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit --payload=http_req --lua-desync=fake:blob=fake_default_http:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit"
  DESYNC_ARGS_AUTO="--filter-tcp=443,80 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=circular:fails=2:time=300:retrans=3:nld=2 --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up:strategy=1 --lua-desync=multisplit:strategy=1 --lua-desync=fake:blob=fake_default_tls:repeats=2:tcp_seq=1000:strategy=2 --lua-desync=multisplit:pos=1,midsld:seqovl=1:strategy=2 --lua-desync=fake:blob=0x00000000:repeats=1:strategy=3 --lua-desync=multisplit:strategy=3 --payload=http_req --lua-desync=circular:fails=2:time=300:retrans=3:nld=2 --lua-desync=fake:blob=fake_default_http:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up:strategy=1 --lua-desync=multisplit:strategy=1 --lua-desync=fake:blob=fake_default_http:repeats=2:tcp_seq=1000:strategy=2 --lua-desync=multisplit:strategy=2"
fi

# Выбор стратегии десинка на основе STRATEGY_MODE
if [ "$STRATEGY_MODE" = "AUTO" ]; then
  DESYNC_ARGS="$DESYNC_ARGS_AUTO"
  log "Режим стратегии: AUTO (circular мультистратегия с per-host автопереключением)"
else
  DESYNC_ARGS="$DESYNC_ARGS_SIMPLE"
  log "Режим стратегии: SIMPLE (одна проверенная стратегия ALT4)"
fi

# Остановка старых процессов nfqws2
pkill -9 -f nfqws2 2>/dev/null

# Функция очистки правил iptables
cleanup_iptables() {
  iptables -w 5 -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null
  iptables -w 5 -t mangle -F ZAPRET2_MANGLE 2>/dev/null
  iptables -w 5 -t mangle -X ZAPRET2_MANGLE 2>/dev/null

  iptables -w 5 -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null
  iptables -w 5 -t filter -F ZAPRET2_FILTER 2>/dev/null
  iptables -w 5 -t filter -X ZAPRET2_FILTER 2>/dev/null

  ip6tables -w 5 -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null
  ip6tables -w 5 -t mangle -F ZAPRET2_MANGLE 2>/dev/null
  ip6tables -w 5 -t mangle -X ZAPRET2_MANGLE 2>/dev/null

  ip6tables -w 5 -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null
  ip6tables -w 5 -t filter -F ZAPRET2_FILTER 2>/dev/null
  ip6tables -w 5 -t filter -X ZAPRET2_FILTER 2>/dev/null
}

cleanup_iptables

# Определение UIDs приложений из указанного файла списка ($1)
get_app_uids() {
  local target_list="$1"
  local uids=""
  local app
  local uid
  if [ -f "$target_list" ]; then
    while read -r app || [ -n "$app" ]; do
      app=$(echo "$app" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      case "$app" in
        "#"*|"") continue ;;
      esac
      uid=$(cmd package list packages -U "$app" 2>/dev/null | grep -F "$app" | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -n1)
      if [ -z "$uid" ]; then
        uid=$(pm list packages -U 2>/dev/null | grep -F "$app" | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -n1)
      fi
      if [ -z "$uid" ] && [ -f /data/system/packages.xml ]; then
        uid=$(grep -E "name=\"$app\"" /data/system/packages.xml 2>/dev/null | sed -n 's/.*userId="\([0-9]*\)".*/\1/p' | head -n1)
      fi
      if [ -n "$uid" ]; then
        uids="$uids $uid"
        log "Пакет: $app -> UID: $uid"
      else
        log "Пакет не найден в системе: $app"
      fi
    done < "$target_list"
  fi
  echo "$uids"
}

# Создание цепей iptables
iptables -w 5 -t mangle -N ZAPRET2_MANGLE
iptables -w 5 -t filter -N ZAPRET2_FILTER

ip6tables -w 5 -t mangle -N ZAPRET2_MANGLE 2>/dev/null
ip6tables -w 5 -t filter -N ZAPRET2_FILTER 2>/dev/null

log "Режим фильтрации: $MODE"

# Исключение IP-адресов прокси-серверов AIUnblock из мангла zapret2
AI_PROXIES="62.133.62.97 103.27.157.38 103.27.157.100 45.155.204.190 37.230.192.51 95.182.120.241 95.216.204.218 80.253.249.40 185.246.223.127 87.228.47.204"
for ip in $AI_PROXIES; do
  iptables -w 5 -t mangle -A ZAPRET2_MANGLE -d "$ip" -j RETURN 2>/dev/null
done

# Настройка правил iptables mangle в зависимости от MODE
if [ "$MODE" = "GLOBAL" ]; then
  iptables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports $PORTS_TCP -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num $QNUM --queue-bypass
  ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports $PORTS_TCP -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num $QNUM --queue-bypass 2>/dev/null
elif [ "$MODE" = "EXCLUDE" ]; then
  LIST_TO_USE="$EXCLUDE_LIST"
  if [ ! -f "$LIST_TO_USE" ]; then
    LIST_TO_USE="$APPS_LIST"
  fi
  UIDS=$(get_app_uids "$LIST_TO_USE")
  for uid in $UIDS; do
    iptables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner $uid -j RETURN
    ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner $uid -j RETURN 2>/dev/null
  done
  iptables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports $PORTS_TCP -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num $QNUM --queue-bypass
  ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports $PORTS_TCP -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num $QNUM --queue-bypass 2>/dev/null
else
  # INCLUDE mode
  UIDS=$(get_app_uids "$APPS_LIST")
  for uid in $UIDS; do
    iptables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner $uid -p tcp -m multiport --dports $PORTS_TCP -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num $QNUM --queue-bypass
    ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner $uid -p tcp -m multiport --dports $PORTS_TCP -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num $QNUM --queue-bypass 2>/dev/null
  done
fi

iptables -w 5 -t mangle -A OUTPUT -j ZAPRET2_MANGLE
ip6tables -w 5 -t mangle -A OUTPUT -j ZAPRET2_MANGLE 2>/dev/null

# Блокировка QUIC (UDP 443) для мгновенного фоллбэка YouTube на TCP HTTPS
iptables -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
ip6tables -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null

# Настройка принудительного перевода на TCP (FORCE_TCP)
if [ "$FORCE_TCP" = "1" ]; then
  log "Принудительный перевод на TCP включен"
  FORCE_TCP_UIDS=$(get_app_uids "$FORCE_TCP_APPS_LIST")
  for uid in $FORCE_TCP_UIDS; do
    iptables -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner $uid -p udp -j REJECT --reject-with icmp-port-unreachable
    ip6tables -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner $uid -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null
    log "FORCE TCP применен для UID: $uid"
  done
fi

iptables -w 5 -t filter -A OUTPUT -j ZAPRET2_FILTER
ip6tables -w 5 -t filter -A OUTPUT -j ZAPRET2_FILTER 2>/dev/null

# Формирование доменных фильтров (--hostlist-exclude и --hostlist)
EXTRA_HOST_ARGS=""
if [ -f "$EXCLUDE_DOMAINS_FILE" ]; then
  EXTRA_HOST_ARGS="$EXTRA_HOST_ARGS --hostlist-exclude=$EXCLUDE_DOMAINS_FILE"
  log "Исключение доменов: подключен $EXCLUDE_DOMAINS_FILE"
fi

# Запуск nfqws2 демона
log "Запуск демона nfqws2..."
cd "$BIN_DIR" || exit 1
./nfqws2 --user=root --qnum=$QNUM --bind-fix4 --bind-fix6 \
  --lua-init="@$BIN_DIR/zapret-lib.lua" \
  --lua-init="@$BIN_DIR/zapret-antidpi.lua" \
  --lua-init="@$BIN_DIR/zapret-auto.lua" \
  $EXTRA_HOST_ARGS \
  $DESYNC_ARGS >> "$LOG_FILE" 2>&1 &

PID=$!
log "Демон nfqws2 запущен с PID: $PID"

# Мгновенный отслеживатель изменений файлов через событие ядра Linux inotify (0% расхода батареи)
if [ "$1" != "reload" ]; then
  pkill -9 -f "inotifyd" 2>/dev/null
  chmod 0755 "$ON_CHANGE_SCRIPT" 2>/dev/null
  if command -v inotifyd >/dev/null 2>&1 || command -v busybox >/dev/null 2>&1; then
    INOTIFY_BIN=$(command -v inotifyd 2>/dev/null || echo "busybox inotifyd")
    $INOTIFY_BIN "$ON_CHANGE_SCRIPT" \
      "$CONF_FILE:w" \
      "$APPS_LIST:w" \
      "$EXCLUDE_LIST:w" \
      "$AUTO_DOMAINS_FILE:w" \
      "$EXCLUDE_DOMAINS_FILE:w" \
      "$FORCE_TCP_APPS_LIST:w" 2>/dev/null &
    log "Ядерный вотчер inotifyd запущен (0.00% CPU, 0% расхода батареи)"
  fi
fi

log "Служба zapret2 успешно запущена"
