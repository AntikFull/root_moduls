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
AI_APPS_LIST="$LISTS_DIR/ai_apps.list"
AI_APPS_USER_LIST="$LISTS_DIR/ai_apps.user.list"
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

: "${WARP_JC:=10}"
: "${WARP_JMIN:=800}"
: "${WARP_JMAX:=1400}"
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
    # Fallback генератор ключей через /dev/urandom и base64
    privkey=$(head -c 32 /dev/urandom | base64 2>/dev/null | tr -d '\r\n')
    pubkey=$(echo -n "$privkey" | base64 2>/dev/null | tr -d '\r\n')
  fi

  # Попытка онлайн-регистрации через Cloudflare Client API
  local reg_success=0 reg_resp=""
  if command -v curl >/dev/null 2>&1; then
    local now_iso
    now_iso=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || echo "2026-08-15T00:00:00.000Z")
    local payload
    payload="{\"key\":\"$pubkey\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$now_iso\",\"model\":\"Android\",\"serial_number\":\"\",\"locale\":\"en_US\"}"
    
    reg_resp=$(curl -4 -s -k -m 10 -X POST -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -d "$payload" https://api.cloudflareclient.com/v0a2158/reg 2>/dev/null)
    
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
        curl -4 -s -k -m 10 -X PATCH -H "Content-Type: application/json" -H "Authorization: Bearer $token" -H "User-Agent: okhttp/3.12.1" -d '{"warp_enabled":true}' "https://api.cloudflareclient.com/v0a2158/reg/$reg_id" >/dev/null 2>&1 || true
        log_i "Успешная регистрация и активация WARP аккаунта (id=$reg_id, client_v4=$client_v4, peer=$peer_pubkey)"
      else
        log_i "Успешная регистрация WARP аккаунта (client_v4=$client_v4, peer=$peer_pubkey)"
      fi
      reg_success=1
    fi
  fi

  if [ "$reg_success" -eq 0 ]; then
    log_w "Онлайн регистрация через API не ответила; используется локальный fallback адрес ($client_v4)"
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
PersistentKeepalive = 25
EOF

  chmod 0600 "$tmp_conf"
  mv -f "$tmp_conf" "$WARP_CONF"
  log_i "Конфигурация AmneziaWG v3 сохранена в $WARP_CONF"
}

# ------------------------------------------------------------------------------
# Сбор UID приложений из списков
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
        uid=$(awk -v p="$pkg" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null)
        case "$uid" in
          ''|0|*[!0-9]*) ;;
          *) uids="$uids $uid" ;;
        esac
      done < "$f"
    done
  fi

  # Дополнительно через pm list packages если packages.list недоступен
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
# Движок AIUnblock Native Router (Go TLS SNI Router)
# ------------------------------------------------------------------------------
AI_ROUTER_BIN="$BIN_DIR/ai-router"
AI_ROUTER_PID_FILE="$RUN_DIR/ai-router.pid"
GATEWAYS_DIR="$MODDIR/gateways"
SNI_ROUTES="$MODDIR/sni_routes.conf"
PROXIES_CONF="$MODDIR/proxies.conf"
ROUTER_PORT=15359

start_ai_router() {
  [ -x "$AI_ROUTER_BIN" ] || return 1
  [ -f "$SNI_ROUTES" ] || return 1

  mkdir -p "$GATEWAYS_DIR" "$RUN_DIR" 2>/dev/null

  local candidates="95.182.120.241 45.155.204.190 37.230.192.51 87.228.47.204 185.246.223.127 103.27.157.38"
  [ -f "$PROXIES_CONF" ] && . "$PROXIES_CONF"
  [ -n "$PUBLIC_AI_PROXIES" ] && candidates="$PUBLIC_AI_PROXIES"

  # Быстрый параллельный подбор лучшего шлюза через нативный движок AIUnblock
  local best_default
  best_default=$("$AI_ROUTER_BIN" probe -candidates "$candidates" -domains "grok.com claude.ai chatgpt.com gemini.google.com" -timeout 2 2>/dev/null)
  [ -n "$best_default" ] || best_default="95.182.120.241"

  for g in default chatgpt claude gemini grok notebook copilot spotify deepl notion; do
    echo "$best_default" > "$GATEWAYS_DIR/$g.current" 2>/dev/null
  done

  # Проверка работающего процесса
  local pid
  pid=$(cat "$AI_ROUTER_PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log_i "AI Router уже запущен (PID=$pid, активный шлюз=$best_default)"
    return 0
  fi

  "$AI_ROUTER_BIN" router -listen "127.0.0.1:$ROUTER_PORT" -routes "$SNI_ROUTES" -gateway-dir "$GATEWAYS_DIR" -max-connections 1024 -dial-timeout 4s -hello-timeout 4s >> "$LOG_FILE" 2>&1 &
  echo $! > "$AI_ROUTER_PID_FILE"
  log_i "AI Router успешно запущен на 127.0.0.1:$ROUTER_PORT (PID=$!, шлюз=$best_default)"
  return 0
}

stop_ai_router() {
  local pid
  pid=$(cat "$AI_ROUTER_PID_FILE" 2>/dev/null)
  case "$pid" in
    ''|0|*[!0-9]*) ;;
    *)
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      ;;
  esac
  rm -f "$AI_ROUTER_PID_FILE" 2>/dev/null
}

reprobe_ai_gateways() {
  [ -x "$AI_ROUTER_BIN" ] || return 0
  local candidates="95.182.120.241 45.155.204.190 37.230.192.51 87.228.47.204 185.246.223.127 103.27.157.38"
  [ -f "$PROXIES_CONF" ] && . "$PROXIES_CONF"
  [ -n "$PUBLIC_AI_PROXIES" ] && candidates="$PUBLIC_AI_PROXIES"

  local new_best
  new_best=$("$AI_ROUTER_BIN" probe -candidates "$candidates" -domains "grok.com claude.ai chatgpt.com gemini.google.com" -timeout 2 2>/dev/null)
  if [ -n "$new_best" ]; then
    local old_best
    old_best=$(cat "$GATEWAYS_DIR/default.current" 2>/dev/null)
    if [ "$new_best" != "$old_best" ]; then
      log_i "AI Router failover: переключение шлюза с $old_best на $new_best"
      for g in default chatgpt claude gemini grok notebook copilot spotify deepl notion; do
        echo "$new_best" > "$GATEWAYS_DIR/$g.current" 2>/dev/null
      done
    fi
  fi
}

# ------------------------------------------------------------------------------
# Разделение UIDs: Telegram (в WARP) и ИИ-приложения (в AI Router)
# ------------------------------------------------------------------------------
collect_ai_uids() {
  local uids="" pkg="" uid=""
  local list_files=""
  [ -f "$AI_APPS_LIST" ] && list_files="$list_files $AI_APPS_LIST"
  [ -f "$AI_APPS_USER_LIST" ] && list_files="$list_files $AI_APPS_USER_LIST"

  if [ -z "$list_files" ]; then
    echo ""
    return 0
  fi

  if [ -r /data/system/packages.list ]; then
    for f in $list_files; do
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        pkg=$(echo "$line" | awk '{print $1}')
        [ -n "$pkg" ] || continue
        uid=$(awk -v p="$pkg" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null)
        case "$uid" in
          ''|0|*[!0-9]*) ;;
          *) uids="$uids $uid" ;;
        esac
      done < "$f"
    done
  fi

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

  echo "$uids" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# ------------------------------------------------------------------------------
# Управление правилами маршрутизации (Policy Routing)
# ------------------------------------------------------------------------------
apply_routing_rules() {
  local all_uids="$1"
  local ai_uids tg_uids=""
  ai_uids=$(collect_ai_uids)

  for u in $all_uids; do
    case " $ai_uids " in
      *" $u "*) ;;
      *) tg_uids="$tg_uids $u" ;;
    esac
  done

  log_i "Применение Policy Routing: Telegram в WARP awg99, ИИ через нативный AI Router..."

  # Очистка старых правил
  cleanup_routing_rules

  # Запуск AI Router демона
  start_ai_router

  # Таблица маршрутизации для awg0
  ip -4 route add default dev "$DEV" table "$TABLE" 2>/dev/null || true
  ip -6 route add default dev "$DEV" table "$TABLE" 2>/dev/null || true

  # Резервные прямые маршруты и правила на диапазоны Telegram в таблицу 11888
  for subnet in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 185.76.151.0/24; do
    ip -4 route add "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip -4 rule add to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
  done

  # Добавление ip rule ТОЛЬКО для клиентов Telegram в таблицу WARP awg99
  local tg_count=0
  for uid in $tg_uids; do
    case "$uid" in ''|0|*[!0-9]*) continue ;; esac
    ip -4 rule add uidrange "$uid-$uid" lookup "$TABLE" pref "$PREF_BASE" 2>/dev/null || true
    ip -6 rule add uidrange "$uid-$uid" lookup "$TABLE" pref "$PREF_BASE" 2>/dev/null || true
    tg_count=$((tg_count + 1))
  done

  # Принудительный сброс UDP MTProto для мгновенного TCP fallback (0.05 сек)
  for subnet in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 185.76.151.0/24; do
    iptables -t filter -I OUTPUT -d "$subnet" -p udp -m multiport --dports 80,443,5222,8443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
  done
  for uid in $tg_uids; do
    case "$uid" in ''|0|*[!0-9]*) continue ;; esac
    iptables -t filter -I OUTPUT -m owner --uid-owner "$uid" -p udp -m multiport --dports 80,443,5222,8443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
  done

  # TCP MSS Clamping для awg0 (MTU 1280/1420)
  iptables -t mangle -A POSTROUTING -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  ip6tables -t mangle -A POSTROUTING -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

  # NAT Masquerade для awg0
  iptables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true
  ip6tables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true

  # Принудительное перенаправление DNS (Smart DNS forcing)
  local warp_dns primary_dns
  warp_dns=$(collect_warp_dns)
  primary_dns=$(echo "$warp_dns" | awk '{print $1}')
  [ -n "$primary_dns" ] || primary_dns="103.27.157.38"
  if [ "$WARP_DNS_FORCE" = "1" ] && [ -n "$primary_dns" ]; then
    for uid in $all_uids; do
      case "$uid" in ''|0|*[!0-9]*) continue ;; esac
      iptables -t nat -I OUTPUT -m owner --uid-owner "$uid" -p udp --dport 53 -j DNAT --to-destination "$primary_dns:53" 2>/dev/null || true
      iptables -t nat -I OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 53 -j DNAT --to-destination "$primary_dns:53" 2>/dev/null || true
    done
    log_i "Smart DNS Forcing активирован на $primary_dns (UDP/TCP 53, DNS пул: $warp_dns)"
  fi

  # Направление ИИ-приложений в локальный нативный AI Router (127.0.0.1:15359)
  # и сброс QUIC (UDP 443) для гарантированного перехода на TLS TCP 443
  local ai_count=0
  for uid in $ai_uids; do
    case "$uid" in ''|0|*[!0-9]*) continue ;; esac
    iptables -t nat -I OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j REDIRECT --to-ports "$ROUTER_PORT" 2>/dev/null || true
    iptables -t filter -I OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    ai_count=$((ai_count + 1))
  done

  # Обход языкового детекта региона для Gemini / Bard через Android 13+ Per-App Language
  if command -v cmd >/dev/null 2>&1 && cmd locale help 2>/dev/null | grep -q "set-app-locales"; then
    for lpkg in com.google.android.apps.bard com.google.android.apps.labs.language.tailwind com.openai.chatgpt com.anthropic.claude ai.x.grok; do
      if pm list packages 2>/dev/null | grep -q "^package:$lpkg$"; then
        local cur_loc
        cur_loc=$(cmd locale get-app-locales "$lpkg" --user 0 2>/dev/null | sed -n 's/.*are \[\(.*\)\].*/\1/p')
        if [ "$cur_loc" != "en-US" ]; then
          cmd locale set-app-locales "$lpkg" --user 0 --locales en-US >/dev/null 2>&1 || true
          log_i "Установлен en-US per-app locale для $lpkg (обход детекта региона)"
        fi
      fi
    done
  fi

  # Маркировка для обхода zapret2 NFQUEUE
  iptables -t mangle -I OUTPUT -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
  ip6tables -t mangle -I OUTPUT -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true

  log_i "Policy Routing успешно настроен: $tg_count Telegram приложений в WARP, $ai_count ИИ-приложений через AI Router (порт $ROUTER_PORT)"
}

cleanup_routing_rules() {
  iptables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true
  ip6tables -t nat -D POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || true
  # Очистка UDP reject, DNS forcing и REDIRECT правил
  for subnet in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 185.76.151.0/24; do
    while iptables -t filter -D OUTPUT -d "$subnet" -p udp -m multiport --dports 80,443,5222,8443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
  done
  local primary_dns
  primary_dns=$(collect_warp_dns | awk '{print $1}')
  [ -n "$primary_dns" ] || primary_dns="1.1.1.1"
  local uid
  for uid in $(collect_warp_uids) $(collect_ai_uids); do
    case "$uid" in ''|0|*[!0-9]*) continue ;; esac
    while iptables -t filter -D OUTPUT -m owner --uid-owner "$uid" -p udp -m multiport --dports 80,443,5222,8443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    while iptables -t filter -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 53 -j DNAT --to-destination "$primary_dns:53" 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 53 -j DNAT --to-destination "$primary_dns:53" 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j REDIRECT --to-ports "$ROUTER_PORT" 2>/dev/null; do :; done
    for old_ip in 87.228.47.204 45.155.204.190 95.182.120.241 37.230.192.51 185.246.223.127 103.27.157.38; do
      while iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j DNAT --to-destination "$old_ip:443" 2>/dev/null; do :; done
      for old_sub in 8.6.112.0/24 160.79.104.0/23 8.47.69.0/24; do
        while iptables -t nat -D OUTPUT -d "$old_sub" -p tcp -m owner --uid-owner "$uid" -m tcp --dport 443 -j DNAT --to-destination "$old_ip:443" 2>/dev/null; do :; done
      done
    done
  done
  stop_ai_router
  # Удаление ip rules по префиксу
  local n=0
  while [ "$n" -lt 50 ]; do
    ip -4 rule del pref "$PREF_BASE" 2>/dev/null || break
    n=$((n + 1))
  done
  n=0
  while [ "$n" -lt 50 ]; do
    ip -4 rule del pref "$PREF_DEST" 2>/dev/null || break
    n=$((n + 1))
  done
  n=0
  while [ "$n" -lt 50 ]; do
    ip -6 rule del pref "$PREF_BASE" 2>/dev/null || break
    n=$((n + 1))
  done

  # Очистка таблицы
  ip -4 route flush table "$TABLE" 2>/dev/null || true
  ip -6 route flush table "$TABLE" 2>/dev/null || true

  # Удаление iptables правил
  iptables -t mangle -D POSTROUTING -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  ip6tables -t mangle -D POSTROUTING -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -D OUTPUT -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
  ip6tables -t mangle -D OUTPUT -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Запуск / Остановка туннеля
# ------------------------------------------------------------------------------
start_tunnel() {
  [ "$ENABLE_WARP" = "1" ] || { log_i "WARP отключен в zapret2.conf (ENABLE_WARP=0)"; return 0; }

  generate_warp_config
  [ -s "$WARP_CONF" ] || { log_e "Отсутствует конфигурация $WARP_CONF"; return 1; }

  stop_tunnel

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
    echo $! > "$WARP_PID_FILE"
    sleep 0.5
  fi

  # Fallback на kernel wireguard если amneziawg-go не создал интерфейс
  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    ip link add dev "$DEV" type wireguard 2>/dev/null || true
  fi

  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    log_e "Не удалось создать сетевой интерфейс $DEV (ядро/TUN недоступны)"
    return 1
  fi

  # Конфигурация интерфейса awg0
  if [ -x "$BIN_DIR/awg" ]; then
    "$BIN_DIR/awg" setconf "$DEV" "$WARP_CONF" 2>>"$LOG_FILE" || log_w "Ошибка awg setconf"
  fi

  # Считывание адреса из конфига
  local client_addr
  client_addr=$(grep '^Address' "$WARP_CONF" | cut -d= -f2 | awk '{print $1}' | tr -d ' ,')
  [ -n "$client_addr" ] || client_addr="172.16.0.2/32"

  ip -4 addr add "$client_addr" dev "$DEV" 2>/dev/null || true
  ip link set up dev "$DEV" 2>/dev/null || true
  ip link set mtu 1280 dev "$DEV" 2>/dev/null || true

  # Маршрутизация приложений
  local uids
  uids=$(collect_warp_uids)
  apply_routing_rules "$uids"

  log_i "AmneziaWG v3 туннель $DEV успешно запущен (клиент=$client_addr, эндпоинт=$WARP_ENDPOINT:$WARP_PORT)"
}

stop_tunnel() {
  log_i "Остановка туннеля $DEV..."
  cleanup_routing_rules

  ip link set down dev "$DEV" 2>/dev/null || true
  ip link delete dev "$DEV" 2>/dev/null || true

  local pid
  pid=$(cat "$WARP_PID_FILE" 2>/dev/null)
  case "$pid" in
    ''|0|*[!0-9]*) ;;
    *)
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      ;;
  esac
  rm -f "$WARP_PID_FILE" 2>/dev/null
  killall amneziawg-go 2>/dev/null || true
}

sync_apps() {
  local uids
  uids=$(collect_warp_uids)
  apply_routing_rules "$uids"
}

status_tunnel() {
  if ip link show dev "$DEV" >/dev/null 2>&1; then
    echo "WARP_STATUS=RUNNING"
    echo "WARP_DEV=$DEV"
    [ -x "$BIN_DIR/awg" ] && "$BIN_DIR/awg" show "$DEV"
  else
    echo "WARP_STATUS=STOPPED"
  fi
}

healthcheck_ai() {
  if [ -x "$AI_ROUTER_BIN" ]; then
    reprobe_ai_gateways
  else
    log_i "AI Router бинарник отсутствует, пропуск healthcheck"
  fi
}

case "$1" in
  start) start_tunnel ;;
  stop) stop_tunnel ;;
  restart|reload) start_tunnel ;;
  sync) sync_apps ;;
  status) status_tunnel ;;
  healthcheck-ai|check-ai) healthcheck_ai ;;
  rekey)
    log_i "Перегенерация профиля WARP по запросу..."
    stop_tunnel
    rm -f "$WARP_CONF" 2>/dev/null
    generate_warp_config
    [ "$ENABLE_WARP" = "1" ] && start_tunnel || true
    ;;
esac
