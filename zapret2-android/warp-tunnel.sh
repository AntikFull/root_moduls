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
WARP_RUNTIME_CONF="$RUN_DIR/warp-runtime.conf"
WARP_RULE_STATE="$RUN_DIR/warp-rules.state"
WARP_ADAPT_STATE="$STATE_DIR/warp-adapt.state"
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
: "${WARP_ADAPTIVE:=1}"
: "${WARP_STARTUP_TRIES:=7}"
: "${WARP_PROBE_TIMEOUT:=3}"

log_i() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] warp: $*" >> "$LOG_FILE"; }
log_w() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] warp: $*" >> "$LOG_FILE"; }
log_e() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] warp: $*" >> "$LOG_FILE"; }
validate_ipv4() {
  local ip="$1" a b c d extra o
  IFS=. read -r a b c d extra <<EOV
$ip
EOV
  [ -z "$extra" ] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

# ------------------------------------------------------------------------------
# Сериализация операций (Locking)
# ------------------------------------------------------------------------------
WARP_LOCK_DEPTH=${WARP_LOCK_DEPTH:-0}
acquire_warp_lock() {
  local attempts=0 owner
  if [ "$WARP_LOCK_DEPTH" -gt 0 ] 2>/dev/null && [ "$(cat "$WARP_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    WARP_LOCK_DEPTH=$((WARP_LOCK_DEPTH + 1))
    return 0
  fi
  while ! mkdir "$WARP_LOCK" 2>/dev/null; do
    owner=$(cat "$WARP_LOCK/pid" 2>/dev/null)
    case "$owner" in
      ''|*[!0-9]*) rm -rf "$WARP_LOCK" 2>/dev/null; continue ;;
      *) if ! kill -0 "$owner" 2>/dev/null; then rm -rf "$WARP_LOCK" 2>/dev/null; continue; fi ;;
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

collect_warp_dns() {
  local dns_list="" list line
  for list in "$DNS_LIST" "$DNS_USER_LIST" "$MODDIR/dns.list" "$MODDIR/dns.user.list"; do
    [ -f "$list" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      case "$line" in ''|\#*) continue ;; esac
      validate_ipv4 "$line" && dns_list="$dns_list $line"
    done < "$list"
  done
  if [ -z "$dns_list" ]; then
    for line in $WARP_DNS; do validate_ipv4 "$line" && dns_list="$dns_list $line"; done
  fi
  [ -n "$dns_list" ] || dns_list=" 1.1.1.1 1.0.0.1"
  printf '%s\n' "$dns_list" | tr -s ' ' | sed 's/^ //;s/ $//'
}

# ------------------------------------------------------------------------------
# Регистрация / генерация конфигурации WARP
# ------------------------------------------------------------------------------
generate_warp_config() {
  if [ -s "$WARP_CONF" ]; then
    return 0
  fi

  log_i "Генерация нового персонального WARP-профиля на этом устройстве..."
  local privkey="" pubkey="" client_v4="" client_v6="" peer_pubkey=""

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
    peer_pubkey=$(printf '%s' "$reg_resp" | grep -o '"public_key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    warp_enabled=$(printf '%s' "$reg_resp" | grep -o '"warp_enabled"[[:space:]]*:[[:space:]]*[^,}]*' | head -n1 | cut -d: -f2 | tr -d '[:space:]')

    if [ "$warp_enabled" != "true" ]; then
      if [ -n "$reg_id" ] && [ -n "$token" ] && curl -4 -fsS -m 8 -X PATCH \
        -H "CF-Client-Version: a-6.10-2158" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -H "Authorization: Bearer $token" \
        -H "User-Agent: okhttp/3.12.1" \
        -d '{"warp_enabled":true}' "$reg_endpoint/$reg_id" >/dev/null 2>&1; then
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
  mv -f "$tmp_conf" "$WARP_CONF" || { rm -f "$tmp_conf"; return 1; }
  rm -f "$WARP_ADAPT_STATE" 2>/dev/null
  log_i "Новый персональный WARP-профиль зарегистрирован и сохранён: $WARP_CONF"
  return 0
}

# ------------------------------------------------------------------------------
# Сбор UID приложений из списков (Multi-User aware)
# ------------------------------------------------------------------------------
collect_warp_uids() {
  local uids="" pkg uid user users list_files=""
  [ -f "$WARP_APPS_LIST" ] && list_files="$list_files $WARP_APPS_LIST"
  [ -f "$WARP_APPS_USER_LIST" ] && list_files="$list_files $WARP_APPS_USER_LIST"
  [ -n "$list_files" ] || { echo ""; return 0; }

  users=$(cmd user list 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')
  [ -n "$users" ] || users="0"

  for f in $list_files; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      pkg=$(printf '%s' "$line" | awk '{print $1}')
      case "$pkg" in ''|*[!A-Za-z0-9_.]*) continue ;; esac
      for user in $users; do
        uid=$(cmd package list packages --user "$user" -U "$pkg" 2>/dev/null | awk -v p="$pkg" '
          index($0,"package:" p)==1 {
            for(i=1;i<=NF;i++) if($i ~ /^uid:/){sub(/^uid:/,"",$i); print $i; exit}
          }')
        if [ -z "$uid" ] && [ "$user" = 0 ] && [ -r /data/system/packages.list ]; then
          uid=$(awk -v p="$pkg" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null)
        fi
        case "$uid" in ''|0|*[!0-9]*) ;; *) uids="$uids $uid" ;; esac
      done
    done < "$f"
  done
  printf '%s\n' "$uids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' '
}

# ------------------------------------------------------------------------------
# Управление правилами маршрутизации (Policy Routing & Dedicated Chains)
# ------------------------------------------------------------------------------
next_warp_pref() {
  local pref="${1:-$PREF_BASE}" max=10999
  case "$pref" in ''|*[!0-9]*) pref="$PREF_BASE" ;; esac
  while [ "$pref" -le "$max" ]; do
    if ! ip -4 rule show 2>/dev/null | grep -q "^${pref}:" && ! ip -6 rule show 2>/dev/null | grep -q "^${pref}:"; then
      printf '%s\n' "$pref"
      return 0
    fi
    pref=$((pref + 1))
  done
  return 1
}

verify_routing_rules() {
  local warp_uids="$1" uid
  ip -4 route show table "$TABLE" default 2>/dev/null | grep -q "default.*dev $DEV" || return 1
  { ip -6 route show table "$TABLE" default 2>/dev/null | grep -q "default.*dev $DEV" || ip -6 route show table "$TABLE" 2>/dev/null | grep -Eq '(^|[[:space:]])unreachable[[:space:]]+default'; } || return 1
  for uid in $warp_uids; do
    ip -4 rule show 2>/dev/null | grep -E "^[0-9]+:.*uidrange ${uid}-${uid}.*lookup ${TABLE}([[:space:]]|$)" >/dev/null || return 1
    ip -6 rule show 2>/dev/null | grep -E "^[0-9]+:.*uidrange ${uid}-${uid}.*lookup ${TABLE}([[:space:]]|$)" >/dev/null || return 1
  done
  return 0
}

apply_routing_rules() {
  local warp_uids="$1" uid app_count=0 pref tmp="$WARP_RULE_STATE.tmp.$$"
  log_i "Применение Policy Routing: приложения из списка в WARP ($DEV)..."
  cleanup_routing_rules
  : > "$tmp" || return 1

  ip -4 route replace default dev "$DEV" table "$TABLE" 2>/dev/null || { rm -f "$tmp"; log_e "Не удалось создать IPv4 default route table=$TABLE"; return 1; }
  if ip -6 addr show dev "$DEV" 2>/dev/null | grep -q 'inet6 '; then
    ip -6 route replace default dev "$DEV" table "$TABLE" 2>/dev/null || { rm -f "$tmp"; log_e "Не удалось создать IPv6 default route table=$TABLE"; return 1; }
  else
    # Fail closed: selected WARP apps must not fall back to the system IPv6 route.
    ip -6 route replace unreachable default table "$TABLE" 2>/dev/null || { rm -f "$tmp"; log_e "Не удалось создать IPv6 fail-closed route table=$TABLE"; return 1; }
  fi

  for uid in $warp_uids; do
    case "$uid" in ''|0|*[!0-9]*) continue ;; esac
    pref=$(next_warp_pref "$((PREF_BASE + app_count))") || { rm -f "$tmp"; cleanup_routing_rules; log_e "Нет свободного policy-rule priority для WARP"; return 1; }
    ip -4 rule add uidrange "$uid-$uid" lookup "$TABLE" pref "$pref" 2>/dev/null || { rm -f "$tmp"; cleanup_routing_rules; log_e "IPv4 uid rule failed uid=$uid pref=$pref"; return 1; }
    printf '4|%s|%s|%s\n' "$pref" "$uid" "$TABLE" >> "$tmp"
    ip -6 rule add uidrange "$uid-$uid" lookup "$TABLE" pref "$pref" 2>/dev/null || { rm -f "$tmp"; cleanup_routing_rules; log_e "IPv6 uid rule failed uid=$uid"; return 1; }
    printf '6|%s|%s|%s\n' "$pref" "$uid" "$TABLE" >> "$tmp"
    app_count=$((app_count + 1))
  done

  # Optional per-UID DNS forcing for classic DNS (UDP/TCP 53).
  # DoH/DoT are intentionally not rewritten because they carry application TLS semantics.
  if [ "${WARP_DNS_FORCE:-1}" = "1" ] && [ -n "$warp_uids" ]; then
    dns_target=$(collect_warp_dns | awk '{print $1}')
    if validate_ipv4 "$dns_target"; then
      { iptables -t nat -N ZAPRET2_WARP_DNS 2>/dev/null || iptables -t nat -F ZAPRET2_WARP_DNS 2>/dev/null; } || { rm -f "$tmp"; cleanup_routing_rules; log_e "Не удалось создать WARP DNS chain"; return 1; }
      { iptables -t nat -C OUTPUT -j ZAPRET2_WARP_DNS 2>/dev/null || iptables -t nat -I OUTPUT 1 -j ZAPRET2_WARP_DNS 2>/dev/null; } || { rm -f "$tmp"; cleanup_routing_rules; log_e "Не удалось подключить WARP DNS chain"; return 1; }
      for uid in $warp_uids; do
        iptables -t nat -A ZAPRET2_WARP_DNS -m owner --uid-owner "$uid" -p udp --dport 53 -j DNAT --to-destination "$dns_target:53" 2>/dev/null || { rm -f "$tmp"; cleanup_routing_rules; log_e "WARP DNS UDP rule failed uid=$uid"; return 1; }
        iptables -t nat -A ZAPRET2_WARP_DNS -m owner --uid-owner "$uid" -p tcp --dport 53 -j DNAT --to-destination "$dns_target:53" 2>/dev/null || { rm -f "$tmp"; cleanup_routing_rules; log_e "WARP DNS TCP rule failed uid=$uid"; return 1; }
      done
    else
      rm -f "$tmp"; cleanup_routing_rules; log_e "WARP_DNS_FORCE включён, но валидный IPv4 DNS не найден"; return 1
    fi
  fi

  iptables -t mangle -N ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
  iptables -t mangle -C OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -I OUTPUT 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -C POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t mangle -N ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
    ip6tables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t mangle -A ZAPRET2_WARP_MANGLE -o "$DEV" -j MARK --set-mark 0x40000000/0x40000000 2>/dev/null || true
    ip6tables -t mangle -C OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -I OUTPUT 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
    ip6tables -t mangle -C POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null || ip6tables -t mangle -I POSTROUTING 1 -j ZAPRET2_WARP_MANGLE 2>/dev/null || true
  fi

  mv -f "$tmp" "$WARP_RULE_STATE" || { rm -f "$tmp"; cleanup_routing_rules; return 1; }
  chmod 0600 "$WARP_RULE_STATE" 2>/dev/null || true
  verify_routing_rules "$warp_uids" || { log_e "Финальная проверка WARP policy routing не прошла"; cleanup_routing_rules; return 1; }
  log_i "Policy Routing проверен: $app_count UID направлены в WARP ($DEV)"
  return 0
}

cleanup_routing_rules() {
  local fam pref uid table n
  if [ -f "$WARP_RULE_STATE" ]; then
    while IFS='|' read -r fam pref uid table; do
      case "$fam:$pref:$uid:$table" in *[!0-9:]*|'') continue ;; esac
      [ "$fam" = 4 ] && ip -4 rule del pref "$pref" uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true
      [ "$fam" = 6 ] && ip -6 rule del pref "$pref" uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true
    done < "$WARP_RULE_STATE"
  fi
  rm -f "$WARP_RULE_STATE" 2>/dev/null

  while iptables -t nat -D OUTPUT -j ZAPRET2_WARP_DNS 2>/dev/null; do :; done
  iptables -t nat -F ZAPRET2_WARP_DNS 2>/dev/null || true
  iptables -t nat -X ZAPRET2_WARP_DNS 2>/dev/null || true

  while iptables -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
  while iptables -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
  iptables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
  iptables -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
    while ip6tables -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
    ip6tables -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null || true
    ip6tables -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null || true
  fi

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

get_peer_public_key() {
  grep '^PublicKey[[:space:]]*=' "$WARP_CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'
}

get_latest_handshake_epoch() {
  local hs
  [ -x "$BIN_DIR/awg" ] || { echo 0; return 0; }
  hs=$("$BIN_DIR/awg" show "$DEV" latest-handshakes 2>/dev/null | awk 'NF>=2 && $2+0>m{m=$2+0} END{print m+0}')
  case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
  printf '%s\n' "$hs"
}

get_active_endpoint() {
  local ep
  ep=$("$BIN_DIR/awg" show "$DEV" endpoints 2>/dev/null | awk 'NF>=2{print $2; exit}')
  [ -n "$ep" ] || ep=$(grep '^Endpoint[[:space:]]*=' "$WARP_CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]')
  printf '%s\n' "$ep"
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

# Возвращает один из приоритетных client-side профилей junk train.
# Профиль 0 — пользовательский baseline. Профиль 1 сохраняет тот же J train,
# но меняет WARP port; после этого J-профили постепенно расширяются.
get_j_profile() {
  local base_jc="$WARP_JC" base_min="$WARP_JMIN" base_max="$WARP_JMAX"
  case "$base_jc" in ''|*[!0-9]*) base_jc=5 ;; esac
  case "$base_min" in ''|*[!0-9]*) base_min=40 ;; esac
  case "$base_max" in ''|*[!0-9]*) base_max=70 ;; esac
  [ "$base_jc" -ge 1 ] 2>/dev/null && [ "$base_jc" -le 128 ] 2>/dev/null || base_jc=5
  if ! { [ "$base_min" -ge 1 ] 2>/dev/null && [ "$base_min" -lt "$base_max" ] 2>/dev/null && [ "$base_max" -le 1200 ] 2>/dev/null; }; then
    base_min=40; base_max=70
  fi

  # Не рандомизируем J* на каждом retry: фиксированный набор даёт
  # воспроизводимый поиск и позволяет запомнить рабочую комбинацию.
  case "$1" in
    0|1) printf '%s %s %s\n' "$base_jc" "$base_min" "$base_max" ;;
    2) echo '4 64 96' ;;
    3) echo '6 64 160' ;;
    4) echo '8 96 256' ;;
    *) echo '10 128 512' ;;
  esac
}

# Для consumer WARP используем consumer ingress и документированные
# WireGuard-порты. Не смешиваем его с Zero Trust ingress и случайными портами.
get_adaptive_endpoint() {
  case "$1" in
    0) printf '%s:%s\n' "$WARP_ENDPOINT" "$WARP_PORT" ;;
    1) echo '162.159.192.1:2408' ;;
    2) echo '162.159.192.1:500' ;;
    3) echo '162.159.192.1:1701' ;;
    4) echo '162.159.192.1:4500' ;;
    *) echo '162.159.192.1:2408' ;;
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

apply_candidate() {
  local step="$1" slot mode prof ep peer jc jmin jmax
  case "$step" in ''|*[!0-9]*) step=0 ;; esac
  if [ "$step" -ge 6 ] 2>/dev/null; then
    mode=sip
    slot=$(((step - 6) % 6))
  else
    mode=basic
    slot=$((step % 6))
  fi
  prof="$slot"
  set -- $(get_j_profile "$prof")
  jc="$1"; jmin="$2"; jmax="$3"
  ep=$(get_adaptive_endpoint "$slot")

  replace_conf_kv Jc "$jc" || return 1
  replace_conf_kv Jmin "$jmin" || return 1
  replace_conf_kv Jmax "$jmax" || return 1

  # Cloudflare peer — обычный WG endpoint. S/H не рандомизируем: это server-side
  # часть AWG и произвольная замена сломала бы совместимость. Варьируются только
  # client-side J* и затем signature packets I*.
  replace_conf_kv S1 0 || return 1
  replace_conf_kv S2 0 || return 1
  # Удаляем S3/S4, если они остались от старого профиля.
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
    if ! "$BIN_DIR/awg" syncconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE"; then
      # Старые builds tools могут не иметь syncconf с расширенными полями.
      "$BIN_DIR/awg" setconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE" || return 1
    fi
    peer=$(get_peer_public_key)
    [ -n "$peer" ] || return 1
    "$BIN_DIR/awg" set "$DEV" peer "$peer" endpoint "$ep" persistent-keepalive 15 2>>"$LOG_FILE" || return 1
  fi

  write_adapt_state "$step" pending || true
  log_i "WARP adaptive: step=$step mode=$mode Jc/Jmin/Jmax=$jc/$jmin/$jmax endpoint=$ep"
  return 0
}

probe_handshake() {
  local timeout="${1:-$WARP_PROBE_TIMEOUT}" before hs now start peer
  case "$timeout" in ''|*[!0-9]*) timeout=3 ;; esac
  [ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
  [ "$timeout" -le 10 ] 2>/dev/null || timeout=10
  peer=$(get_peer_public_key)
  [ -n "$peer" ] || return 1
  before=$(get_latest_handshake_epoch)
  "$BIN_DIR/awg" set "$DEV" peer "$peer" persistent-keepalive 1 2>/dev/null || true
  start=$(date +%s 2>/dev/null || echo 0)
  while :; do
    sleep 1
    hs=$(get_latest_handshake_epoch)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$hs" -gt 0 ] 2>/dev/null; then
      if [ "$before" -eq 0 ] 2>/dev/null || [ "$hs" -gt "$before" ] 2>/dev/null || [ $((now - hs)) -le 10 ] 2>/dev/null; then
        "$BIN_DIR/awg" set "$DEV" peer "$peer" persistent-keepalive 15 2>/dev/null || true
        return 0
      fi
    fi
    [ $((now - start)) -ge "$timeout" ] 2>/dev/null && break
  done
  "$BIN_DIR/awg" set "$DEV" peer "$peer" persistent-keepalive 15 2>/dev/null || true
  return 1
}

next_adapt_step() {
  local cur="$1"
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  if [ "$cur" -lt 5 ] 2>/dev/null; then
    echo $((cur + 1))
  elif [ "$cur" -eq 5 ] 2>/dev/null; then
    # Только после полного BASIC-прохода включаем I1/I2.
    echo 6
  elif [ "$cur" -lt 11 ] 2>/dev/null; then
    echo $((cur + 1))
  else
    # SIP уже нужен: дальше циклически меняем только J/endpoint, не прыгая
    # обратно в basic каждую минуту.
    echo 6
  fi
}

adaptive_bootstrap() {
  [ "${WARP_ADAPTIVE:-1}" = 1 ] || return 0
  local tries="${WARP_STARTUP_TRIES:-7}" step n=0
  case "$tries" in ''|*[!0-9]*) tries=7 ;; esac
  [ "$tries" -le 12 ] 2>/dev/null || tries=12
  step=$(adapt_state_step)
  while [ "$n" -lt "$tries" ]; do
    apply_candidate "$step" || return 1
    if probe_handshake "$WARP_PROBE_TIMEOUT"; then
      write_adapt_state "$step" ok || true
      log_i "WARP adaptive: handshake OK на step=$step"
      return 0
    fi
    log_w "WARP adaptive: handshake не получен на step=$step"
    step=$(next_adapt_step "$step")
    n=$((n + 1))
    # После последней быстрой попытки заранее применяем следующий кандидат,
    # чтобы state, WebUI и фактический warp.conf не расходились до watchdog.
    if [ "$n" -ge "$tries" ] 2>/dev/null; then
      apply_candidate "$step" || true
      return 1
    fi
  done
  return 1
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

  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    log_e "amneziawg-go не создал $DEV; generic kernel WireGuard fallback отключён как несовместимый с AWG v3"
    stop_tunnel_internal
    release_warp_lock
    return 1
  fi

  # `awg setconf` получает runtime-конфиг без wg-quick Address/DNS.
  build_runtime_conf || { stop_tunnel_internal; release_warp_lock; return 1; }
  if [ -x "$BIN_DIR/awg" ]; then
    if ! "$BIN_DIR/awg" setconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE"; then
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

  ip -4 addr replace "$client_addr_v4" dev "$DEV" 2>/dev/null || { log_e "Не удалось назначить IPv4 $client_addr_v4"; stop_tunnel_internal; release_warp_lock; return 1; }
  if [ -n "$client_addr_v6" ]; then
    ip -6 addr replace "$client_addr_v6" dev "$DEV" 2>/dev/null || { log_e "Не удалось назначить IPv6 $client_addr_v6"; stop_tunnel_internal; release_warp_lock; return 1; }
  fi
  ip link set up dev "$DEV" 2>/dev/null || { log_e "Не удалось поднять $DEV"; stop_tunnel_internal; release_warp_lock; return 1; }
  ip link set mtu 1280 dev "$DEV" 2>/dev/null || log_w "Не удалось установить MTU=1280"

  # Маршрутизация приложений
  local uids
  uids=$(collect_warp_uids)
  apply_routing_rules "$uids" || { stop_tunnel_internal; release_warp_lock; return 1; }

  if adaptive_bootstrap; then
    local active_ep active_step
    active_ep=$(get_active_endpoint)
    active_step=$(adapt_state_step)
    release_warp_lock
    log_i "WARP $DEV запущен: routing OK, handshake OK, adaptive step=$active_step endpoint=$active_ep"
    return 0
  fi

  # Интерфейс оставляем поднятым и выбранные приложения остаются fail-closed:
  # watchdog продолжит перебор профилей, но ложный SUCCESS не пишем.
  local pending_step
  pending_step=$(adapt_state_step)
  release_warp_lock
  log_w "WARP $DEV поднят, но handshake пока нет; adaptive recovery продолжит с step=$pending_step"
  return 0
}

stop_tunnel_internal() {
  log_i "Остановка туннеля $DEV..."
  cleanup_routing_rules

  ip link set down dev "$DEV" 2>/dev/null || true
  ip link delete dev "$DEV" 2>/dev/null || true

  local pid cmd exe
  pid=$(cat "$WARP_PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if { [ "$exe" = "$BIN_DIR/amneziawg-go" ] || printf '%s' "$cmd" | grep -Fq "$BIN_DIR/amneziawg-go"; } && printf '%s' "$cmd" | grep -Fq "$DEV"; then
      kill -TERM "$pid" 2>/dev/null || true
      local n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.1; n=$((n + 1)); done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    else
      log_w "stale warp.pid=$pid не принадлежит $BIN_DIR/amneziawg-go $DEV; процесс не трогаем"
    fi
  fi
  rm -f "$WARP_PID_FILE" "$WARP_RUNTIME_CONF" 2>/dev/null
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
  if ! ip link show dev "$DEV" >/dev/null 2>&1; then
    start_tunnel
    rc=$?
    release_warp_lock
    return "$rc"
  fi
  local uids
  uids=$(collect_warp_uids)
  apply_routing_rules "$uids"
  rc=$?
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
    [ -x "$BIN_DIR/awg" ] && "$BIN_DIR/awg" show "$DEV" 2>/dev/null || true
  else
    echo "WARP_STATUS=STOPPED"
  fi
}

SIP_I1="<b 0x5349502f322e302031303020547279696e670d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
SIP_I2="<b 0x494e56495445207369703a626f624062696c6f78692e636f6d205349502f322e300d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a4d61782d466f7277617264733a2037300d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"

enable_sip_mode() {
  acquire_warp_lock || return 1
  [ -f "$WARP_CONF" ] || { release_warp_lock; return 1; }
  local step
  step=$(adapt_state_step)
  [ "$step" -ge 6 ] 2>/dev/null || step=6
  log_w "Ручная активация SIP I1/I2 fallback"
  apply_candidate "$step"
  local rc=$?
  release_warp_lock
  return "$rc"
}

disable_sip_mode() {
  acquire_warp_lock || return 1
  [ -f "$WARP_CONF" ] || { release_warp_lock; return 1; }
  log_i "Ручной возврат в BASIC: без I1/I2, baseline J/endpoint"
  apply_candidate 0
  local rc=$?
  [ "$rc" -eq 0 ] && write_adapt_state 0 pending || true
  release_warp_lock
  return "$rc"
}

check_and_heal_warp() {
  [ "${ENABLE_WARP:-0}" = "1" ] || return 0
  acquire_warp_lock || return 1
  [ -x "$BIN_DIR/awg" ] || { release_warp_lock; return 1; }
  ip link show dev "$DEV" >/dev/null 2>&1 || { release_warp_lock; return 1; }

  local hs now diff step next
  hs=$(get_latest_handshake_epoch)
  now=$(date +%s 2>/dev/null || echo 0)
  if [ "$hs" -gt 0 ] 2>/dev/null; then diff=$((now - hs)); else diff=999999; fi

  # Свежий handshake — запоминаем рабочую комбинацию и ничего не дёргаем.
  if [ "$hs" -gt 0 ] 2>/dev/null && [ "$diff" -lt 180 ] 2>/dev/null; then
    step=$(adapt_state_step)
    write_adapt_state "$step" ok || true
    release_warp_lock
    return 0
  fi

  step=$(adapt_state_step)
  log_w "WARP handshake отсутствует/устарел (${diff}s), проверяем текущий adaptive step=$step"
  if probe_handshake "$WARP_PROBE_TIMEOUT"; then
    write_adapt_state "$step" ok || true
    log_i "WARP adaptive recovery: восстановлен step=$step"
    release_warp_lock
    return 0
  fi

  next=$(next_adapt_step "$step")
  if apply_candidate "$next"; then
    log_w "WARP adaptive recovery: step=$step не помог; подготовлен следующий step=$next"
  else
    log_e "WARP adaptive recovery: не удалось применить следующий step=$next"
  fi
  release_warp_lock
  return 1
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
    acquire_warp_lock || exit 1
    log_i "Перегенерация профиля WARP по запросу..."
    old_conf="$WARP_CONF.old.$$"
    [ -f "$WARP_CONF" ] && cp -f "$WARP_CONF" "$old_conf" 2>/dev/null
    stop_tunnel_internal
    rm -f "$WARP_CONF" "$WARP_ADAPT_STATE" 2>/dev/null
    if ! generate_warp_config; then
      [ -f "$old_conf" ] && mv -f "$old_conf" "$WARP_CONF"
      release_warp_lock
      exit 1
    fi
    rm -f "$old_conf" 2>/dev/null
    if [ "$ENABLE_WARP" = "1" ]; then start_tunnel || { release_warp_lock; exit 1; }; fi
    release_warp_lock
    ;;
esac
