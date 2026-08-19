#!/system/bin/sh
# ==============================================================================
# warp-tunnel.sh — AmneziaWG v3 (Cloudflare WARP) Tunnel for Android (zapret2)
# ==============================================================================
umask 077

MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
RUN_DIR="$MODDIR/run"
LOG_DIR="$MODDIR/logs"
STATE_DIR="$MODDIR/state"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
WARP_CONF="$STATE_DIR/warp.conf"
WARP_PID_FILE="$RUN_DIR/warp.pid"
LISTS_DIR="$MODDIR/lists"
[ -d "$LISTS_DIR" ] || LISTS_DIR="$MODDIR"
WARP_APPS_LIST="$LISTS_DIR/warp_apps.list"
WARP_APPS_USER_LIST="$LISTS_DIR/warp_apps.user.list"
DNS_LIST="$LISTS_DIR/dns.list"
DNS_USER_LIST="$LISTS_DIR/dns.user.list"
WARP_LOCK="$RUN_DIR/warp.lock"
PREF_BASE="10500"
PREF_DEST="10400"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null
chmod 0700 "$RUN_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"
: "${ENABLE_WARP:=0}"
: "${WARP_DEV:=awg99}"
: "${WARP_ROUTE_TABLE:=11888}"
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

log_i() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] warp: $*" >> "$LOG_FILE"; }
log_w() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] warp: $*" >> "$LOG_FILE"; }
log_e() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] warp: $*" >> "$LOG_FILE"; }

# ------------------------------------------------------------------------------
# Сериализация операций (Locking)
# ------------------------------------------------------------------------------
acquire_warp_lock() {
  local attempts=0
  while ! mkdir "$WARP_LOCK" 2>/dev/null; do
    if [ -d "$WARP_LOCK" ]; then
      local lock_age=""
      lock_age=$(find "$WARP_LOCK" -mmin +2 2>/dev/null)
      if [ -n "$lock_age" ]; then
        rm -rf "$WARP_LOCK" 2>/dev/null
        continue
      fi
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -ge 15 ] && return 1
    sleep 0.2
  done
  return 0
}

release_warp_lock() {
  rm -rf "$WARP_LOCK" 2>/dev/null
}

collect_warp_dns() {
  local dns_list="" list extracted
  for list in "$DNS_LIST" "$DNS_USER_LIST" "$MODDIR/dns.list" "$MODDIR/dns.user.list"; do
    if [ -f "$list" ]; then
      extracted=$(grep -vE '^[[:space:]]*(#|$)' "$list" 2>/dev/null | tr '\r\n' ' ')
      [ -n "$extracted" ] && dns_list="$dns_list $extracted"
    fi
  done
  dns_list=$(echo "$dns_list" | tr -s ' ' | sed 's/^ //;s/ $//')
  if [ -n "$dns_list" ]; then
    echo "$dns_list"
  elif [ -n "$WARP_DNS" ]; then
    echo "$WARP_DNS"
  else
    echo "1.1.1.1 1.0.0.1"
  fi
}

# ------------------------------------------------------------------------------
# Регистрация / генерация конфигурации WARP
# ------------------------------------------------------------------------------
generate_warp_config() {
  if [ -s "$WARP_CONF" ]; then
    return 0
  fi

  log_i "Генерация нового AmneziaWG v3 профиля для Cloudflare WARP..."
  local privkey="" pubkey="" client_v4="172.16.0.2" client_v6="" peer_pubkey="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

  if [ -x "$BIN_DIR/awg" ]; then
    privkey=$("$BIN_DIR/awg" genkey 2>/dev/null)
    pubkey=$(echo "$privkey" | "$BIN_DIR/awg" pubkey 2>/dev/null)
  fi

  if [ -z "$privkey" ] || [ -z "$pubkey" ]; then
    log_e "Не удалось сгенерировать криптографические ключи Curve25519 через $BIN_DIR/awg"
    return 1
  fi

  # Попытка онлайн-регистрации через Cloudflare Client API с валидацией TLS
  local reg_success=0 reg_resp=""
  if command -v curl >/dev/null 2>&1; then
    local now_iso
    now_iso=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || echo "2026-08-15T00:00:00.000Z")
    local payload
    payload="{\"key\":\"$pubkey\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$now_iso\",\"model\":\"Android\",\"serial_number\":\"\",\"locale\":\"en_US\"}"

    # Перебор API-эндпоинтов Cloudflare
    for cf_endpoint in \
      "https://api.cloudflareclient.com/v0a2158/reg" \
      "https://api.cloudflareclient.com/v0a2405/reg" \
      "https://api.cloudflareclient.com/v0a3121/reg"
    do
      # 1. Прямой запрос через системный DNS
      reg_resp=$(curl -4 -s -m 6 -X POST -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -d "$payload" "$cf_endpoint" 2>/dev/null)
      echo "$reg_resp" | grep -q '"id"' && break

      # 2. Запрос через прямые Anycast IP Cloudflare с поддержкой TLS SNI (--resolve)
      for cf_ip in 162.159.192.1 162.159.193.1 104.16.124.96 104.16.123.96 188.114.97.1; do
        reg_resp=$(curl -4 -s -m 6 --resolve "api.cloudflareclient.com:443:$cf_ip" -X POST -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -d "$payload" "$cf_endpoint" 2>/dev/null)
        echo "$reg_resp" | grep -q '"id"' && break 2
      done
    done

    if echo "$reg_resp" | grep -q '"id"'; then
      local reg_id token v6 peer
      reg_id=$(echo "$reg_resp" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
      token=$(echo "$reg_resp" | grep -o '"token":"[^"]*"' | head -n 1 | cut -d'"' -f4)
      client_v4="172.16.0.2"
      v6=$(echo "$reg_resp" | grep -o '2606:4700:[^"]*' | head -n 1 | sed -e 's/\]:.*//' -e 's/\/.*//' | cut -d'"' -f1)
      peer=$(echo "$reg_resp" | grep -o '"public_key":"[^"]*"' | head -n 1 | cut -d'"' -f4)
      [ -n "$v6" ] && client_v6="$v6"
      [ -n "$peer" ] && peer_pubkey="$peer"

      # Активация маршрутизации WARP через PATCH API
      if [ -n "$reg_id" ] && [ -n "$token" ]; then
        curl -4 -s -m 6 -X PATCH -H "Content-Type: application/json" -H "Authorization: Bearer $token" -H "User-Agent: okhttp/3.12.1" -d '{"warp_enabled":true}' "https://api.cloudflareclient.com/v0a2158/reg/$reg_id" >/dev/null 2>&1 || true
        log_i "Успешная регистрация и активация WARP аккаунта в Cloudflare API (id=$reg_id, client_v4=$client_v4, peer=$peer_pubkey)"
      else
        log_i "Успешная регистрация WARP аккаунта (client_v4=$client_v4, peer=$peer_pubkey)"
      fi
      reg_success=1
    fi
  fi

  if [ "$reg_success" -eq 0 ]; then
    log_w "Онлайн регистрация через Cloudflare API не ответила; используется локальный адрес ($client_v4)"
  fi

  # Генерация AmneziaWG v3 ini-файла
  local tmp_conf="$WARP_CONF.tmp.$$"
  cat <<EOF > "$tmp_conf"
[Interface]
PrivateKey = $privkey
Address = ${client_v4}/32${client_v6:+, $client_v6/128}
DNS = 1.1.1.1, 1.0.0.1
Jc = $WARP_JC
Jmin = $WARP_JMIN
Jmax = $WARP_JMAX
S1 = $WARP_S1
S2 = $WARP_S2
EOF
  [ "$WARP_S3" -gt 0 ] 2>/dev/null && echo "S3 = $WARP_S3" >> "$tmp_conf"
  [ "$WARP_S4" -gt 0 ] 2>/dev/null && echo "S4 = $WARP_S4" >> "$tmp_conf"
  cat <<EOF >> "$tmp_conf"
H1 = $WARP_H1
H2 = $WARP_H2
H3 = $WARP_H3
H4 = $WARP_H4
EOF
  [ -n "$WARP_I1" ] && echo "I1 = $WARP_I1" >> "$tmp_conf"
  [ -n "$WARP_I2" ] && echo "I2 = $WARP_I2" >> "$tmp_conf"
  [ -n "$WARP_I3" ] && echo "I3 = $WARP_I3" >> "$tmp_conf"
  [ -n "$WARP_I4" ] && echo "I4 = $WARP_I4" >> "$tmp_conf"
  [ -n "$WARP_I5" ] && echo "I5 = $WARP_I5" >> "$tmp_conf"
  cat <<EOF >> "$tmp_conf"

[Peer]
PublicKey = $peer_pubkey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${WARP_ENDPOINT}:${WARP_PORT}
PersistentKeepalive = 15
EOF

  chmod 0600 "$tmp_conf"
  mv -f "$tmp_conf" "$WARP_CONF"
  log_i "Конфигурация AmneziaWG v3 сохранена в $WARP_CONF (Keepalive=15s)"
  return 0
}

# ------------------------------------------------------------------------------
# Сбор UID приложений из списков (Multi-User aware)
# ------------------------------------------------------------------------------
collect_warp_uids() {
  local uids="" pkg="" uid=""
  local list_files=""
  [ -f "$WARP_APPS_LIST" ] && list_files="$list_files $WARP_APPS_LIST"
  [ -f "$WARP_APPS_USER_LIST" ] && list_files="$list_files $WARP_APPS_USER_LIST"

  if [ -z "$list_files" ]; then
    echo ""
    return 0
  fi

  # Считывание из /data/system/packages.list (быстро)
  if [ -r /data/system/packages.list ]; then
    for f in $list_files; do
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        pkg=$(echo "$line" | awk '{print $1}')
        [ -n "$pkg" ] || continue
        # Базовый UID для user 0
        uid=$(awk -v p="$pkg" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null)
        case "$uid" in
          ''|0|*[!0-9]*) ;;
          *)
            uids="$uids $uid"
            # Поддержка дополнительных Android пользователей (work profiles: user 10, 11, 12...)
            local sub_uid
            for uidx in 10 11 12 13 14 15; do
              sub_uid=$((uidx * 100000 + uid))
              uids="$uids $sub_uid"
            done
            ;;
        esac
      done < "$f"
    done
  fi

  # Fallback через pm list packages
  if [ -z "$uids" ] && command -v pm >/dev/null 2>&1; then
    for f in $list_files; do
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        pkg=$(echo "$line" | awk '{print $1}')
        [ -n "$pkg" ] || continue
        uid=$(pm list packages -U 2>/dev/null | grep "package:$pkg " | awk -F'uid:' '{print $2}' | cut -d' ' -f1 | tr -d '\r\n')
        case "$uid" in
          ''|0|*[!0-9]*) ;;
          *) uids="$uids $uid" ;;
        esac
      done < "$f"
    done
  fi

  # Удаление дубликатов
  echo "$uids" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# ------------------------------------------------------------------------------
# Управление правилами маршрутизации (Policy Routing & Dedicated Chains)
# ------------------------------------------------------------------------------
apply_routing_rules() {
  local warp_uids="$1"

  log_i "Применение Policy Routing: приложения из списка в WARP ($DEV)..."

  # Очистка старых правил
  cleanup_routing_rules

  # Таблица маршрутизации для awg99
  ip -4 route add default dev "$DEV" table "$TABLE" 2>/dev/null || true
  ip -6 route add default dev "$DEV" table "$TABLE" 2>/dev/null || true

  TG_SUBNETS="91.108.0.0/16 149.154.160.0/20 185.76.151.0/24 95.161.64.0/20"
  TG_SUBNETS_V6="2001:b28:f23d::/48 2001:67c:4e8::/48"

  for subnet in $TG_SUBNETS; do
    ip -4 route add "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip -4 rule add to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
  done
  for subnet in $TG_SUBNETS_V6; do
    ip -6 route add "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip -6 rule add to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
  done

  # Добавление ip rule для приложений из warp_apps.list
  local app_count=0
  for uid in $warp_uids; do
    case "$uid" in ''|0|*[!0-9]*) continue ;; esac
    ip -4 rule add uidrange "$uid-$uid" lookup "$TABLE" pref "$PREF_BASE" 2>/dev/null || true
    ip -6 rule add uidrange "$uid-$uid" lookup "$TABLE" pref "$PREF_BASE" 2>/dev/null || true
    app_count=$((app_count + 1))
  done

  # Создание и подключение изолированной цепочки ZAPRET2_WARP_MANGLE
  iptables -t mangle -N ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  ip6tables -t mangle -N ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true

  # TCP MSS Clamping для $DEV (устраняет зависание медиа и картинок)
  iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  ip6tables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

  # Маркировка для обхода zapret2 NFQUEUE
  iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
  ip6tables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true

  # Подключение цепочки к POSTROUTING и OUTPUT
  iptables -t mangle -C OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -I OUTPUT 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  ip6tables -t mangle -C OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -I OUTPUT 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -C POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  ip6tables -t mangle -C POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -I POSTROUTING 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true

  # NAT Masquerade для $DEV
  iptables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true
  ip6tables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true

  log_i "Policy Routing успешно настроен: $app_count UID направлены в WARP ($DEV)"
}

cleanup_routing_rules() {
  iptables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true
  ip6tables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true

  # Очистка и удаление цепочки ZAPRET2_WARP_MANGLE
  while iptables -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
  while ip6tables -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
  while iptables -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
  while ip6tables -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
  iptables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null || true
  ip6tables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  ip6tables -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null || true

  # Очистка устаревших правил AI Router (если остались от прошлых версий)
  while iptables -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j REDIRECT --to-ports 15359 2>/dev/null; do :; done

  # Удаление ip rule по префиксу и таблице
  local n=0
  while [ "$n" -lt 60 ]; do
    ip -4 rule del pref "$PREF_BASE" 2>/dev/null || break
    n=$((n + 1))
  done
  n=0
  while [ "$n" -lt 60 ]; do
    ip -4 rule del pref "$PREF_DEST" 2>/dev/null || break
    n=$((n + 1))
  done
  n=0
  while [ "$n" -lt 60 ]; do
    ip -6 rule del pref "$PREF_BASE" 2>/dev/null || break
    n=$((n + 1))
  done
  n=0
  while [ "$n" -lt 60 ]; do
    ip -6 rule del pref "$PREF_DEST" 2>/dev/null || break
    n=$((n + 1))
  done

  # Очистка таблицы маршрутов
  ip -4 route flush table "$TABLE" 2>/dev/null || true
  ip -6 route flush table "$TABLE" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Запуск / Остановка туннеля
# ------------------------------------------------------------------------------
start_tunnel() {
  if [ "${ENABLE_WARP:-0}" != "1" ]; then
    log_i "WARP отключен в zapret2.conf (ENABLE_WARP=0)"
    stop_tunnel
    return 0
  fi

  acquire_warp_lock || { log_w "Не удалось захватить warp.lock (операция занята)"; return 1; }

  generate_warp_config || { release_warp_lock; return 1; }
  [ -s "$WARP_CONF" ] || { log_e "Отсутствует конфигурация $WARP_CONF"; release_warp_lock; return 1; }

  # Предварительная остановка старого интерфейса
  stop_tunnel_internal

  log_i "Запуск интерфейса $DEV через amneziawg-go (AmneziaWG v3)..."

  # Подготовка UAPI каталога на Android
  mkdir -p "$RUN_DIR/wireguard" 2>/dev/null || true
  if [ ! -d /var/run/wireguard ]; then
    mount -t tmpfs tmpfs /var 2>/dev/null || true
    mkdir -p /var/run/wireguard 2>/dev/null || true
  fi

  # Запуск amneziawg-go
  if [ -x "$BIN_DIR/amneziawg-go" ]; then
    "$BIN_DIR/amneziawg-go" "$DEV" >> "$LOG_FILE" 2>&1 &
    local awg_pid=$!
    echo "$awg_pid" > "$WARP_PID_FILE"
    sleep 0.5
  fi

  # Fallback на kernel wireguard если amneziawg-go не создал интерфейс
  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    ip link add dev "$DEV" type wireguard 2>/dev/null || true
  fi

  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    log_e "Не удалось создать сетевой интерфейс $DEV (ядро/TUN недоступны)"
    release_warp_lock
    return 1
  fi

  # Конфигурация интерфейса awg0
  if [ -x "$BIN_DIR/awg" ]; then
    if ! "$BIN_DIR/awg" setconf "$DEV" "$WARP_CONF" 2>>"$LOG_FILE"; then
      log_e "Ошибка awg setconf для $DEV"
      stop_tunnel_internal
      release_warp_lock
      return 1
    fi
  else
    log_e "Бинарник awg отсутствует в $BIN_DIR/awg"
    stop_tunnel_internal
    release_warp_lock
    return 1
  fi

  # Считывание адресов IPv4 и IPv6 из конфига
  local client_addr_v4 client_addr_v6
  client_addr_v4=$(grep '^Address' "$WARP_CONF" | cut -d= -f2 | awk -F',' '{print $1}' | tr -d ' ')
  client_addr_v6=$(grep '^Address' "$WARP_CONF" | cut -d= -f2 | awk -F',' '{print $2}' | tr -d ' ')
  [ -n "$client_addr_v4" ] || client_addr_v4="172.16.0.2/32"

  if ! ip -4 addr add "$client_addr_v4" dev "$DEV" 2>/dev/null; then
    log_w "Не удалось назначить IPv4 адрес $client_addr_v4 на $DEV"
  fi
  if [ -n "$client_addr_v6" ]; then
    ip -6 addr add "$client_addr_v6" dev "$DEV" 2>/dev/null || true
  fi
  ip link set up dev "$DEV" 2>/dev/null || true
  ip link set mtu 1280 dev "$DEV" 2>/dev/null || true

  # Маршрутизация приложений
  local uids
  uids=$(collect_warp_uids)
  apply_routing_rules "$uids"

  release_warp_lock
  log_i "AmneziaWG v3 туннель $DEV успешно запущен (клиент=$client_addr_v4, эндпоинт=$WARP_ENDPOINT:$WARP_PORT)"
  return 0
}

stop_tunnel_internal() {
  log_i "Остановка туннеля $DEV..."
  cleanup_routing_rules

  ip link set down dev "$DEV" 2>/dev/null || true
  ip link delete dev "$DEV" 2>/dev/null || true

  local pid
  pid=$(cat "$WARP_PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    local comm cmd
    comm=$(cat "/proc/$pid/comm" 2>/dev/null)
    cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    if [ "$comm" = "amneziawg-go" ] || printf '%s' "$cmd" | grep -Fq "amneziawg-go"; then
      kill -TERM "$pid" 2>/dev/null || true
      local n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$WARP_PID_FILE" 2>/dev/null

  # Остановка только осиротевших процессов amneziawg-go для нашего интерфейса
  for proc in /proc/[0-9]*; do
    cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null)
    if printf '%s' "$cmd" | grep -Fq "$DEV" && printf '%s' "$cmd" | grep -Fq "amneziawg-go"; then
      kill -KILL "${proc##*/}" 2>/dev/null || true
    fi
  done
}

stop_tunnel() {
  acquire_warp_lock || return 1
  stop_tunnel_internal
  release_warp_lock
}

sync_apps() {
  if [ "${ENABLE_WARP:-0}" != "1" ]; then
    stop_tunnel
    return 0
  fi
  acquire_warp_lock || return 1
  local uids
  uids=$(collect_warp_uids)
  apply_routing_rules "$uids"
  release_warp_lock
}

status_tunnel() {
  if ip link show dev "$DEV" >/dev/null 2>&1; then
    local dump last_hs=0
    if [ -x "$BIN_DIR/awg" ]; then
      dump=$("$BIN_DIR/awg" show "$DEV" 2>/dev/null)
      last_hs=$(echo "$dump" | grep -m1 'latest handshake:' | awk '{print $NF}')
    fi
    if [ -n "$last_hs" ] && [ "$last_hs" != "0" ]; then
      echo "WARP_STATUS=HANDSHAKE_OK"
    else
      echo "WARP_STATUS=INTERFACE_UP"
    fi
    echo "WARP_DEV=$DEV"
    [ -n "$dump" ] && echo "$dump"
  else
    echo "WARP_STATUS=STOPPED"
  fi
}

SIP_I1="<b 0x5349502f322e302031303020547279696e670d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
SIP_I2="<b 0x494e56495445207369703a626f624062696c6f78692e636f6d205349502f322e300d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a4d61782d466f7277617264733a2037300d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"

enable_sip_mode() {
  [ -f "$WARP_CONF" ] || return 0
  grep -q '^I1 =' "$WARP_CONF" && return 0
  log_w "Активация AmneziaWG SIP I1/I2 обхода (резервный режим DPI)..."
  local tmp_conf="$WARP_CONF.tmp.$$"
  awk -v i1="$SIP_I1" -v i2="$SIP_I2" '
    /^\[Peer\]/ && !added { print "I1 = " i1; print "I2 = " i2; added=1 }
    { print }
  ' "$WARP_CONF" > "$tmp_conf" && mv -f "$tmp_conf" "$WARP_CONF"
  chmod 0600 "$WARP_CONF" 2>/dev/null || true
  if ip link show dev "$DEV" >/dev/null 2>&1 && [ -x "$BIN_DIR/awg" ]; then
    "$BIN_DIR/awg" setconf "$DEV" "$WARP_CONF" 2>/dev/null || true
    ping -c 1 -W 2 -I "$DEV" 1.1.1.1 >/dev/null 2>&1 || true
  fi
}

disable_sip_mode() {
  [ -f "$WARP_CONF" ] || return 0
  grep -q '^I1 =' "$WARP_CONF" || return 0
  log_i "Возврат в стандартный чистый AmneziaWG режим (без I1/I2)..."
  local tmp_conf="$WARP_CONF.tmp.$$"
  grep -vE '^(I1|I2|I3|I4|I5) =' "$WARP_CONF" > "$tmp_conf" && mv -f "$tmp_conf" "$WARP_CONF"
  chmod 0600 "$WARP_CONF" 2>/dev/null || true
  if ip link show dev "$DEV" >/dev/null 2>&1 && [ -x "$BIN_DIR/awg" ]; then
    "$BIN_DIR/awg" setconf "$DEV" "$WARP_CONF" 2>/dev/null || true
    ping -c 1 -W 2 -I "$DEV" 1.1.1.1 >/dev/null 2>&1 || true
  fi
}

check_and_heal_warp() {
  [ "${ENABLE_WARP:-0}" = "1" ] || return 0
  [ -x "$BIN_DIR/awg" ] || return 0
  ip link show dev "$DEV" >/dev/null 2>&1 || return 0

  local dump last_hs=0 now diff
  dump=$("$BIN_DIR/awg" show "$DEV" 2>/dev/null)
  last_hs=$(echo "$dump" | grep -m1 '^last_handshake_time_sec=' | cut -d= -f2)
  [ -n "$last_hs" ] || last_hs=$(echo "$dump" | grep -m1 'latest handshake:' | awk '{print $NF}')
  case "$last_hs" in ''|*[!0-9]*) last_hs=0 ;; esac

  now=$(date +%s 2>/dev/null || echo 0)
  if [ "$last_hs" -gt 0 ]; then
    diff=$((now - last_hs))
  else
    diff=999
  fi

  # Если туннель активен, но трафик простаивает >60 сек — посылаем keepalive-пинг для удержания NAT
  if [ "$last_hs" -gt 0 ] && [ "$diff" -ge 60 ] && [ "$diff" -lt 180 ]; then
    ping -c 1 -W 2 -I "$DEV" 1.1.1.1 >/dev/null 2>&1 || true
    return 0
  fi

  # Если хендшейка нет вообще или он протух (>180 сек):
  # Переключаем эндпоинт на следующий из пула Anycast
  if [ "$diff" -ge 180 ] || [ "$last_hs" -eq 0 ]; then
    local pool="162.159.192.1:500 162.159.193.1:500 162.159.192.1:4500 162.159.195.1:1701 188.114.97.1:500 188.114.96.1:4500 162.159.192.1:854 162.159.193.1:2408"
    local cur_ep next_ep="" found=0
    cur_ep=$(echo "$dump" | grep -m1 '^endpoint=' | cut -d= -f2)
    [ -n "$cur_ep" ] || cur_ep=$(echo "$dump" | grep -m1 'endpoint:' | awk '{print $NF}')
    for ep in $pool; do
      if [ "$found" -eq 1 ]; then
        next_ep="$ep"
        break
      fi
      [ "$ep" = "$cur_ep" ] && found=1
    done
    [ -n "$next_ep" ] || next_ep="162.159.192.1:500"

    if [ "$next_ep" != "$cur_ep" ]; then
      log_w "WARP хендшейк устарел (${diff}с, last_hs=$last_hs, now=$now), переключение эндпоинта на $next_ep..."
      local peer_pk
      peer_pk=$(grep '^PublicKey' "$WARP_CONF" 2>/dev/null | cut -d= -f2 | tr -d ' ')
      [ -n "$peer_pk" ] || peer_pk="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
      "$BIN_DIR/awg" set "$DEV" peer "$peer_pk" endpoint "$next_ep" 2>/dev/null || true
      ping -c 1 -W 2 -I "$DEV" 1.1.1.1 >/dev/null 2>&1 || true
    else
      # Если все эндпоинты уже перепробованы и связи нет:
      # Адаптивно переключаем режим SIP I1/I2
      if grep -q '^I1 =' "$WARP_CONF"; then
        log_w "Связь отсутствует в SIP-режиме, пробуем вернуться в чистый режим..."
        disable_sip_mode
      else
        log_w "Связь отсутствует в чистом режиме, пробуем аварийный SIP I1/I2 режим..."
        enable_sip_mode
      fi
    fi
  fi
}

case "$1" in
  start) start_tunnel ;;
  stop) stop_tunnel ;;
  restart|reload) start_tunnel ;;
  sync) sync_apps ;;
  status) status_tunnel ;;
  watchdog|heal) check_and_heal_warp ;;
  sip-on) enable_sip_mode ;;
  sip-off) disable_sip_mode ;;
  rekey)
    log_i "Перегенерация профиля WARP по запросу..."
    stop_tunnel
    rm -f "$WARP_CONF" 2>/dev/null
    generate_warp_config
    [ "$ENABLE_WARP" = "1" ] && start_tunnel || true
    ;;
esac
