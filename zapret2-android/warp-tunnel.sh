#!/system/bin/sh
# ==============================================================================
# warp-tunnel.sh — AmneziaWG v3 (Cloudflare WARP) Tunnel for Android (zapret2)
# ==============================================================================
umask 077

MODDIR="${0%/*}"
case "$MODDIR" in /data/adb/modules/*) ;; *) [ -f "/data/adb/modules/zapret2-android/module.prop" ] && MODDIR="/data/adb/modules/zapret2-android" ;; esac
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
# Домены, уводимые в туннель, и разрешённые для них адреса.
WARP_DOMAIN_IPS_STATE="$STATE_DIR/warp-domain-ips.state"
# С какого момента туннель признан нездоровым — для решения о полном перезапуске.
WARP_UNHEALTHY_SINCE="$RUN_DIR/warp-unhealthy-since.ts"
LISTS_DIR="$MODDIR/lists"
[ -d "$LISTS_DIR" ] || LISTS_DIR="$MODDIR"
DNS_LIST="$LISTS_DIR/dns.list"
DNS_USER_LIST="$LISTS_DIR/dns.user.list"
WARP_LOCK="$RUN_DIR/warp.lock"
PREF_BASE="50"
PREF_DEST="40"

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
: "${WARP_SIP_FORCE:=0}"
: "${WARP_STARTUP_TRIES:=40}"
: "${WARP_PROBE_TIMEOUT:=3}"
: "${WARP_DOMAIN_ROUTING:=1}"
: "${WARP_HEALTH_MAX_AGE:=180}"
: "${WARP_HEALTH_PROBE_IP:=1.1.1.1}"
: "${WARP_HEALTH_PROBE_TIMEOUT:=3}"
: "${WARP_HEALTH_PROBE_TRIES:=2}"
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

awg_cmd() {
  run_with_timeout "${WARP_AWG_CMD_TIMEOUT:-2}" "$BIN_DIR/awg" "$@"
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

collect_warp_dns() {
  local dns_list="" list line
  for line in ${WARP_DNS:-1.1.1.1 1.0.0.1}; do
    validate_ipv4 "$line" && dns_list="$dns_list $line"
  done
  if [ -z "$dns_list" ]; then
    for list in "$DNS_USER_LIST" "$DNS_LIST" "$MODDIR/dns.user.list" "$MODDIR/dns.list"; do
      [ -f "$list" ] || continue
      while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$line" in ''|\#*) continue ;; esac
        validate_ipv4 "$line" && dns_list="$dns_list $line"
      done < "$list"
    done
  fi
  [ -n "$dns_list" ] || dns_list="1.1.1.1 1.0.0.1"
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
  mv -f "$tmp_conf" "$WARP_CONF" || { rm -f "$tmp_conf"; return 1; }
  rm -f "$WARP_ADAPT_STATE" 2>/dev/null
  log_i "Новый персональный WARP-профиль зарегистрирован и сохранён: $WARP_CONF"
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
  local host="$1" family="$2" out=""
  case "$host" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
  if [ "$family" = 6 ]; then
    out=$(ping6 -c1 -w1 "$host" 2>/dev/null | sed -n 's/^PING [^(]*(\([0-9a-fA-F:]*\)).*/\1/p' | head -n1)
  else
    out=$(ping -c1 -w1 "$host" 2>/dev/null | sed -n 's/^PING [^(]*(\([0-9.]*\)).*/\1/p' | head -n1)
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Домены, которые уводятся в туннель: заданные вручную плюс добавленные
# автоматически (не поддались ни одной стратегии обхода).
collect_warp_domains() {
  local list line
  for list in "$LISTS_DIR/warp_domains.list" "$STATE_DIR/warp_auto_domains.list"; do
    [ -f "$list" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      case "$line" in *[!A-Za-z0-9.-]*) continue ;; esac
      printf '%s\n' "$line"
    done < "$list"
  done | awk 'NF && !seen[$0]++'
}

# Подсети из общего файла. Раньше тот же список Telegram был захардкожен здесь
# и ещё раз в service.sh, причём наборы успели разойтись.
collect_warp_bypass_nets() {
  local family="$1" line file="$LISTS_DIR/warp_bypass_nets.list"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
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
#
# Свежего handshake НЕДОСТАТОЧНО. Бывает состояние, когда рукопожатие проходит и
# обновляется, а полезные данные не идут: наружу уходят килобайты, обратно
# приходят только служебные пакеты в десятки байт. Формально туннель «живой»,
# фактически — чёрная дыра.
#
# Поэтому проверяются два условия:
#   1. handshake не старше WARP_HEALTH_MAX_AGE секунд;
#   2. сквозь туннель реально проходят данные (см. warp_data_flows).
# Второе условие не зависит от того, идёт ли сейчас пользовательский трафик:
# проверка отправляет собственный пакет, поэтому простой не путается с обрывом.
# ==============================================================================
# Проходят ли сквозь туннель настоящие данные.
#
# Пакет отправляется С ПРИВЯЗКОЙ к интерфейсу туннеля, поэтому проверяется
# именно он, а не общий доступ в интернет. Cloudflare отвечает на 1.1.1.1
# изнутри туннеля; ICMP здесь идёт уже внутри шифрованного канала, так что
# фильтры провайдера на него не влияют.
#
# Это заменило подсчёт байтов rx/tx. Тот подход выглядел разумно, но замер на
# устройстве показал его несостоятельность: в мёртвом туннеле TCP не
# устанавливается, поэтому tx растёт медленно и порог не набирается, а rx при
# этом пухнет ответами на рукопожатие по 92 байта. Любые пороги давали либо
# пропуски, либо ложные срабатывания на обычной отдаче файла.
warp_data_flows() {
  local target="${WARP_HEALTH_PROBE_IP:-1.1.1.1}" timeout="${WARP_HEALTH_PROBE_TIMEOUT:-3}" n=0
  command -v ping >/dev/null 2>&1 || return 0
  case "$timeout" in ''|*[!0-9]*) timeout=3 ;; esac
  while [ "$n" -lt "${WARP_HEALTH_PROBE_TRIES:-2}" ]; do
    ping -c1 -W"$timeout" -I "$DEV" "$target" >/dev/null 2>&1 && return 0
    n=$((n + 1))
  done
  return 1
}

# Есть ли вообще через что поднимать туннель.
#
# Перебор профилей без связи бессмыслен по построению: ни один кандидат не
# получит рукопожатие, потому что пакету некуда идти. Раньше watchdog в такой
# ситуации честно шагал по матрице (по WARP_WATCH_BATCH кандидатов за тик),
# упирался в 40-й профиль, ставил result=failed, выжидал WARP_ADAPT_RETRY_SEC и
# начинал заново — и так до возвращения сети. Плюс раз в WARP_STALL_RESTART_SEC
# поднимал весь туннель с нуля. Всё это в самолёте, метро или подвале.
#
# Маршрут проверяется до endpoint'а, а не «хоть какой-нибудь»: если он ведёт в
# сам туннель, несущей сети тоже нет.
underlay_available() {
  local dev
  dev=$(ip -4 route get "${WARP_ENDPOINT:-162.159.192.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$dev" ] || return 1
  [ "$dev" != "$DEV" ] || return 1
  return 0
}

# Возвращает 0 (живой) / 1 (мёртвый). Причина — в WARP_HEALTH_REASON.
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
    WARP_HEALTH_REASON="handshake устарел на ${diff}с"; return 1
  fi

  # Рукопожатие свежее — но это ещё не значит, что через туннель ходят данные.
  # Бывает состояние, когда пир исправно отвечает на рукопожатия, а полезный
  # трафик молча теряет. Формально живой туннель, фактически — чёрная дыра.
  if ! warp_data_flows; then
    WARP_HEALTH_REASON="рукопожатие есть, но данные сквозь туннель не проходят"
    return 1
  fi
  return 0
}

# Снятие правил по адресу назначения.
# UID-правила здесь НЕ трогаются: приложение, которое пользователь сознательно
# увёл в туннель, не должно втихую пойти мимо него. А подсети и домены — это
# улучшение «по возможности»: при мёртвом туннеле правильнее вернуть их на
# обычный маршрут, где работает обход DPI, чем отправлять в никуда.
remove_dest_rules() {
  local subnet fam domain addr
  for subnet in $(collect_warp_bypass_nets 4); do
    ip -4 rule del to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
  done
  for subnet in $(collect_warp_bypass_nets 6); do
    ip -6 rule del to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
  done
  if [ -f "$WARP_DOMAIN_IPS_STATE" ]; then
    while IFS='|' read -r fam domain addr; do
      [ -n "$addr" ] || continue
      case "$addr" in *[!0-9A-Fa-f.:]*) continue ;; esac
      if [ "$fam" = 6 ]; then
        ip -6 rule del to "$addr" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
      else
        ip -4 rule del to "$addr" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
      fi
    done < "$WARP_DOMAIN_IPS_STATE"
    rm -f "$WARP_DOMAIN_IPS_STATE" 2>/dev/null
  fi
}

# Есть ли что вообще ставить: непустой список подсетей или доменов.
dest_rules_wanted() {
  [ -n "$(collect_warp_bypass_nets 4)" ] && return 0
  [ -n "$(collect_warp_bypass_nets 6)" ] && return 0
  [ "${WARP_DOMAIN_ROUTING:-1}" = "1" ] && [ -n "$(collect_warp_domains)" ] && return 0
  return 1
}

# Стоят ли сейчас правила с нашим приоритетом назначения.
dest_rules_present() {
  ip -4 rule show 2>/dev/null | grep -q "^${PREF_DEST}:" && return 0
  ip -6 rule show 2>/dev/null | grep -q "^${PREF_DEST}:" && return 0
  return 1
}

# Установка правил маршрутизации по адресу назначения (подсети + домены).
# Вынесена отдельно, потому что вызывается из двух мест: при полном
# применении правил и из watchdog при восстановлении туннеля.
install_dest_rules() {
  local subnet net_count=0 domain addr domain_count=0
  if ! warp_tunnel_healthy; then
    remove_dest_rules
    log_w "Туннель нерабочий (${WARP_HEALTH_REASON:-?}): маршруты по адресу назначения сняты, трафик идёт обычным путём с обходом DPI"
    return 1
  fi

  # Подсети назначения из lists/warp_bypass_nets.list — тот же файл, что использует
  # service.sh для вывода их из-под AntiDPI, чтобы наборы не расходились.
  for subnet in $(collect_warp_bypass_nets 4); do
    ip -4 route replace "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip -4 rule add to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
    net_count=$((net_count + 1))
  done
  for subnet in $(collect_warp_bypass_nets 6); do
    ip -6 route replace "$subnet" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip -6 rule add to "$subnet" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null || true
    net_count=$((net_count + 1))
  done

  # Домены, уводимые в туннель целиком. Резолвим на месте: адреса CDN меняются,
  # поэтому список пересобирается при каждой синхронизации.
  if [ "${WARP_DOMAIN_ROUTING:-1}" = "1" ]; then
    : > "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null || true
    for domain in $(collect_warp_domains); do
      addr=$(resolve_domain_addrs "$domain" 4) || { log_w "WARP-домен $domain не резолвится, пропущен"; continue; }
      ip -4 route replace "$addr" dev "$DEV" table "$TABLE" 2>/dev/null || true
      if ip -4 rule add to "$addr" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null; then
        printf '4|%s|%s\n' "$domain" "$addr" >> "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
        domain_count=$((domain_count + 1))
      fi
      addr=$(resolve_domain_addrs "$domain" 6) || continue
      ip -6 route replace "$addr" dev "$DEV" table "$TABLE" 2>/dev/null || true
      if ip -6 rule add to "$addr" lookup "$TABLE" pref "$PREF_DEST" 2>/dev/null; then
        printf '6|%s|%s\n' "$domain" "$addr" >> "$WARP_DOMAIN_IPS_STATE.tmp.$$" 2>/dev/null
      fi
    done
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
  cleanup_routing_rules

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
  # Отбор по приложениям убран: маршрутизация идёт только по адресу назначения,
  # поэтому Telegram и прочее уводится подсетями из warp_bypass_nets.list, а не
  # правилами по UID конкретного клиента.
  install_dest_rules || true

  # Принудительный DNS по UID убран вместе с отбором по приложениям. Домены,
  # которые должны идти через туннель, задаются в warp_domains.list, и их адреса
  # уводятся в туннель напрямую — подменять резолвер для этого не требуется.

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

get_peer_public_key() {
  grep '^PublicKey[[:space:]]*=' "$WARP_CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'
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

adaptive_profile_count() { echo 5; }
adaptive_endpoint_count() { echo 4; }
adaptive_total_steps() { echo 40; }

get_underlay_mtu() {
  local route dev mtu
  route=$(ip -4 route get "$WARP_ENDPOINT" 2>/dev/null | head -n1)
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
  local total step tries n=0 result
  total=$(adaptive_total_steps)
  if [ "${WARP_ADAPTIVE:-1}" != 1 ]; then
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

  # При ручном режиме значения WebUI должны применяться буквально и больше
  # не перезаписываться адаптивным поиском. При AUTO свежий поиск стартует с step 0.
  if [ "${WARP_ADAPTIVE:-1}" = 1 ]; then
    [ -f "$WARP_ADAPT_STATE" ] || write_adapt_state 0 pending || true
    apply_candidate 0 || log_w "WARP adaptive recovery: step=0 не применился; продолжим матрицу"
  else
    prepare_manual_profile || { release_warp_lock; return 1; }
  fi

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
    if ! awg_cmd setconf "$DEV" "$WARP_RUNTIME_CONF" 2>>"$LOG_FILE"; then
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
  apply_routing_rules || { stop_tunnel_internal; release_warp_lock; return 1; }

  local adapt_rc=0
  adaptive_bootstrap || adapt_rc=$?
  if [ "$adapt_rc" -eq 0 ]; then
    local active_ep active_step
    active_ep=$(get_active_endpoint)
    active_step=$(adapt_state_step)
    release_warp_lock
    log_i "WARP $DEV запущен: routing OK, handshake OK, adaptive step=$active_step endpoint=$active_ep"
    return 0
  fi

  local pending_step pending_result
  pending_step=$(adapt_state_step); pending_result=$(adapt_state_value result)
  release_warp_lock
  if [ "$adapt_rc" -eq 2 ] || [ "$pending_result" = failed ]; then
    log_e "WARP $DEV поднят fail-closed, но рабочий handshake не найден (step=$pending_step)"
  else
    log_w "WARP $DEV поднят, handshake пока нет; adaptive recovery продолжит с step=$pending_step"
  fi
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
    cmd=$(pid_cmdline "$pid")
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
  apply_routing_rules
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

  local hs now diff step next result batch stall i=0

  # Единая проверка живости: свежий handshake И реально идущие данные.
  # Раньше здесь смотрели только на возраст handshake, поэтому состояние
  # «рукопожатие обновляется, а полезный трафик не ходит» считалось нормой:
  # туннель формально жив, а весь трафик, направленный в него, пропадает.
  if warp_tunnel_healthy; then
    step=$(adapt_state_step)
    write_adapt_state "$step" ok || true
    warp_clear_unhealthy
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

case "$1" in
  start) start_tunnel ;;
  stop) stop_tunnel ;;
  restart|reload) start_tunnel ;;
  # Полный перезапуск по требованию: сбрасывает перебор профилей на начало.
  # Нужен, когда туннель завис на одном шаге и сам не выбирается.
  force-restart)
    acquire_warp_lock || { log_w "Перезапуск отложен: операция с туннелем уже выполняется"; exit 1; }
    log_i "Полный перезапуск туннеля по запросу пользователя"
    stop_tunnel_internal
    rm -f "$WARP_ADAPT_STATE" "$WARP_UNHEALTHY_SINCE" 2>/dev/null
    release_warp_lock
    start_tunnel
    ;;
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
