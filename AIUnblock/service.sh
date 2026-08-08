#!/system/bin/sh
# AI Unblock RU v2.2.2 — service.sh

MODDIR=${0%/*}
MODULE_ID="AIUnblock"

[ -f "$MODDIR/lib/hosts_conflict.sh" ] && . "$MODDIR/lib/hosts_conflict.sh"

LOG_DIR="/sdcard/eCubz"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/AIUnblock_debug.log"
LOG_OLD="$MODDIR/dnat.log.1"
ROUTER_LOG="$LOG_DIR/AIUnblock_router_debug.log"
ROUTER_LOG_OLD="$MODDIR/router.log.1"
LOCALE_STATE="$MODDIR/app_locales.state"
LOCKDIR="$MODDIR/.daemon.lock"

ROUTER_BIN="$MODDIR/bin/aiunblock-router"
CURL_BIN="curl"
SNI_ROUTES="$MODDIR/sni_routes.conf"
GATEWAY_DIR="$MODDIR/gateways"
ROUTER_PID_FILE="$MODDIR/.router.pid"
PROXY_OVERRIDE="$MODDIR/proxies.override"
SMARTDNS_CONF="$MODDIR/smartdns.conf"
SMARTDNS_USER_CONF="$MODDIR/smartdns.user.conf"
ROUTER_PORT=15359

CHECK_INTERVAL=1800
FAST_RETRY_INTERVAL=30
WATCHDOG_INTERVAL=15
LOG_MAX_BYTES=262144
CURL_MAX_TIME=8
DOH_MAX_TIME=12
XTABLES_WAIT=10
INIT_RETRIES=5
INIT_RETRY_DELAY=2
AUTH_RETRIES=6
AUTH_RETRY_DELAY=5

PROXIES_CONF="$MODDIR/proxies.conf"
if [ -r "$PROXIES_CONF" ]; then
  . "$PROXIES_CONF"
else
  PUBLIC_PROXIES="62.133.62.97 103.27.157.38 103.27.157.100 45.155.204.190 37.230.192.51 95.182.120.241 95.216.204.218 80.253.249.40 185.246.223.127 87.228.47.204"
  PUBLIC_AI_PROXIES="87.228.47.204 185.246.223.127 103.27.157.38 103.27.157.100 62.133.62.97 45.155.204.190 37.230.192.51 95.182.120.241 95.216.204.218 80.253.249.40"
  AUTH_DNS="80.253.249.40 103.27.157.38 103.27.157.100 95.216.204.218 111.88.96.50 111.88.96.51"
fi

DOH_RESOLVERS=""
DOT_RESOLVERS=""

PROXIES="$PUBLIC_PROXIES"
AI_PROXIES="$PUBLIC_AI_PROXIES"


LOCALE_PACKAGES="com.google.android.apps.bard com.google.android.apps.labs.language.tailwind com.openai.chatgpt com.anthropic.claude ai.x.grok"
GOOGLE_PACKAGE="com.google.android.googlequicksearchbox"
BARD_PACKAGE="com.google.android.apps.bard"
NOTEBOOK_PACKAGE="com.google.android.apps.labs.language.tailwind"
CHATGPT_PACKAGE="com.openai.chatgpt"
CLAUDE_PACKAGE="com.anthropic.claude"
GROK_PACKAGE="ai.x.grok"

CURRENT_GEMINI=""
CURRENT_NOTEBOOK=""
CURRENT_CHATGPT=""
CURRENT_CLAUDE=""
CURRENT_GROK=""
WAITING_FOR_NETWORK=0
RETRY_SOON=0
NETWORK_WAIT_LOGGED=0

GOOGLE_UIDS=""
BARD_UIDS=""
NOTEBOOK_UIDS=""
CHATGPT_UIDS=""
CLAUDE_UIDS=""
GROK_UIDS=""

IPTABLES_WAIT_SUPPORTED=0
IP6TABLES_WAIT_SUPPORTED=0
IPTABLES_RESTORE_WAIT_SUPPORTED=0
IP6TABLES_RESTORE_WAIT_SUPPORTED=0

rotate_file() {
  local file="$1"
  local old="$2"
  [ -f "$file" ] || return 0

  local size
  size=$(wc -c < "$file" 2>/dev/null)
  [ -n "$size" ] || return 0
  if [ "$size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
    mv -f "$file" "$old"
    : > "$file"
    chmod 0600 "$file" 2>/dev/null
  fi
}

rotate_log() {
  rotate_file "$LOG" "$LOG_OLD"
}

log() {
  echo "[$(date)] $*" >> "$LOG"
}

is_ipv4() {
  echo "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
  '
}

load_proxy_override() {
  PROXIES="$PUBLIC_PROXIES"
  AI_PROXIES="$PUBLIC_AI_PROXIES"
  [ -r "$PROXY_OVERRIDE" ] || return 0

  local override
  override=$(awk -F. '
    NF == 4 {
      valid=1
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) valid=0
      }
      if (valid && !seen[$0]++) print $0
    }
  ' "$PROXY_OVERRIDE" | tr '\n' ' ')

  if [ -n "$override" ]; then
    PROXIES="$override $PUBLIC_PROXIES"
    AI_PROXIES="$override $PUBLIC_AI_PROXIES"
    log "Загружен приватный override адресов без публикации значений в лог"
  fi
}

append_unique() {
  local current="$1"
  local value="$2"
  case " $current " in
    *" $value "*) echo "$current" ;;
    *) echo "$current $value" ;;
  esac
}

load_smartdns_file() {
  local file="$1"
  local protocol address extra
  [ -r "$file" ] || return 0

  while read -r protocol address extra; do
    case "$protocol" in
      ""|'#'*) continue ;;
    esac
    [ -n "$address" ] || continue
    [ -z "$extra" ] || {
      log "Smart DNS: пропущена некорректная строка в $file"
      continue
    }

    case "$protocol" in
      DOH)
        case "$address" in
          https://*) DOH_RESOLVERS=$(append_unique "$DOH_RESOLVERS" "$address") ;;
          *) log "Smart DNS: DoH должен начинаться с https:// ($address)" ;;
        esac
        ;;
      DOT)
        case "$address" in
          *[!A-Za-z0-9._:-]*) log "Smart DNS: некорректный DoT endpoint ($address)" ;;
          *) DOT_RESOLVERS=$(append_unique "$DOT_RESOLVERS" "$address") ;;
        esac
        ;;
      DNS)
        if is_ipv4 "$address"; then
          AUTH_DNS=$(append_unique "$AUTH_DNS" "$address")
        else
          log "Smart DNS: некорректный IPv4 DNS ($address)"
        fi
        ;;
      *) log "Smart DNS: неизвестный протокол $protocol в $file" ;;
    esac
  done < "$file"
}

load_smartdns_resolvers() {
  load_smartdns_file "$SMARTDNS_CONF"
  load_smartdns_file "$SMARTDNS_USER_CONF"

  if [ -z "$DOH_RESOLVERS" ]; then
    DOH_RESOLVERS="https://dns.malw.link/dns-query https://xbox-dns.ru/dns-query"
    log "Smart DNS: smartdns.conf недоступен или не содержит DoH; включён встроенный резерв"
  fi
  log "Smart DNS: загружено DoH=$(echo $DOH_RESOLVERS | wc -w), DoT=$(echo $DOT_RESOLVERS | wc -w), DNS=$(echo $AUTH_DNS | wc -w)"
}

configure_xtables_wait() {
  if iptables -w 2 -t filter -S OUTPUT >/dev/null 2>&1; then
    IPTABLES_WAIT_SUPPORTED=1
  fi
  if ip6tables -w 2 -t filter -S OUTPUT >/dev/null 2>&1; then
    IP6TABLES_WAIT_SUPPORTED=1
  fi
  if iptables-restore -w 1 --help >/dev/null 2>&1; then
    IPTABLES_RESTORE_WAIT_SUPPORTED=1
  fi
  if ip6tables-restore -w 1 --help >/dev/null 2>&1; then
    IP6TABLES_RESTORE_WAIT_SUPPORTED=1
  fi
}

ipt() {
  if [ "$IPTABLES_WAIT_SUPPORTED" -eq 1 ]; then
    iptables -w "$XTABLES_WAIT" "$@"
  else
    iptables "$@"
  fi
}

ip6t() {
  if [ "$IP6TABLES_WAIT_SUPPORTED" -eq 1 ]; then
    ip6tables -w "$XTABLES_WAIT" "$@"
  else
    ip6tables "$@"
  fi
}

ipt_restore() {
  if [ "$IPTABLES_RESTORE_WAIT_SUPPORTED" -eq 1 ]; then
    iptables-restore -w "$XTABLES_WAIT" "$@"
  else
    iptables-restore "$@"
  fi
}

ip6t_restore() {
  if [ "$IP6TABLES_RESTORE_WAIT_SUPPORTED" -eq 1 ]; then
    ip6tables-restore -w "$XTABLES_WAIT" "$@"
  else
    ip6tables-restore "$@"
  fi
}

secure_permissions() {
  mkdir -p "$GATEWAY_DIR"
  chown 0:0 "$MODDIR" "$GATEWAY_DIR" 2>/dev/null
  chmod 0755 "$MODDIR" 2>/dev/null
  chmod 0700 "$GATEWAY_DIR" 2>/dev/null

  chown 0:0 "$MODDIR/service.sh" "$MODDIR/module.prop" 2>/dev/null
  chmod 0755 "$MODDIR/service.sh" 2>/dev/null
  chmod 0644 "$MODDIR/module.prop" 2>/dev/null

  [ -f "$MODDIR/uninstall.sh" ] && {
    chown 0:0 "$MODDIR/uninstall.sh" 2>/dev/null
    chmod 0755 "$MODDIR/uninstall.sh" 2>/dev/null
  }
  [ -f "$ROUTER_BIN" ] && {
    chown 0:0 "$ROUTER_BIN" 2>/dev/null
    chmod 0700 "$ROUTER_BIN" 2>/dev/null
  }
  [ -f "$MODDIR/bin/curl" ] && {
    chown 0:0 "$MODDIR/bin/curl" 2>/dev/null
    chmod 0755 "$MODDIR/bin/curl" 2>/dev/null
  }
  [ -f "$SNI_ROUTES" ] && {
    chown 0:0 "$SNI_ROUTES" 2>/dev/null
    chmod 0600 "$SNI_ROUTES" 2>/dev/null
  }

  touch "$LOG" "$ROUTER_LOG"
  chown 0:0 "$LOG" "$ROUTER_LOG" 2>/dev/null
  chmod 0600 "$LOG" "$ROUTER_LOG" 2>/dev/null
  [ -f "$LOCALE_STATE" ] && chmod 0600 "$LOCALE_STATE" 2>/dev/null
  [ -f "$PROXY_OVERRIDE" ] && chmod 0600 "$PROXY_OVERRIDE" 2>/dev/null
  chmod 0600 "$GATEWAY_DIR"/*.current 2>/dev/null
}

router_pid() {
  local pid
  pid=$(cat "$ROUTER_PID_FILE" 2>/dev/null)
  case "$pid" in
    ""|*[!0-9]*) return 1 ;;
  esac
  echo "$pid"
}

router_running() {
  local pid cmdline
  pid=$(router_pid) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case "$cmdline" in
    *"$ROUTER_BIN"*) return 0 ;;
  esac
  return 1
}

stop_router() {
  local pid
  pid=$(router_pid) || {
    rm -f "$ROUTER_PID_FILE"
    return 0
  }
  if router_running; then
    kill "$pid" 2>/dev/null
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$ROUTER_PID_FILE"
}

start_router() {
  router_running && return 0
  stop_router

  [ -x "$ROUTER_BIN" ] || {
    log "ОШИБКА: SNI-router отсутствует или не исполняемый"
    return 1
  }
  [ -s "$SNI_ROUTES" ] || {
    log "ОШИБКА: список SNI-маршрутов отсутствует или пуст"
    return 1
  }

  "$ROUTER_BIN" \
    -listen "127.0.0.1:$ROUTER_PORT" \
    -routes "$SNI_ROUTES" \
    -gateway-dir "$GATEWAY_DIR" >> "$ROUTER_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$ROUTER_PID_FILE"
  chmod 0600 "$ROUTER_PID_FILE" 2>/dev/null
  sleep 1

  if router_running; then
    log "SNI-router запущен (PID $pid, 127.0.0.1:$ROUTER_PORT)"
    return 0
  fi

  log "ОШИБКА: SNI-router завершился при запуске"
  rm -f "$ROUTER_PID_FILE"
  return 1
}

maintain_router() {
  local size
  size=$(wc -c < "$ROUTER_LOG" 2>/dev/null)
  if [ -n "$size" ] && [ "$size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
    stop_router
    mv -f "$ROUTER_LOG" "$ROUTER_LOG_OLD"
    : > "$ROUTER_LOG"
    chmod 0600 "$ROUTER_LOG" 2>/dev/null
  fi
  start_router
}

release_lock() {
  rm -rf "$LOCKDIR"
}

shutdown_service() {
  stop_router
  release_lock
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$LOCKDIR/pid"
    return 0
  fi

  local old_pid
  old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "Повторный запуск отклонён: демон уже работает (PID $old_pid)"
    return 1
  fi

  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  echo "$$" > "$LOCKDIR/pid"
  return 0
}

check_dependencies() {
  local missing=0
  local command_name

  if [ -x "$MODDIR/bin/curl" ]; then
    CURL_BIN="$MODDIR/bin/curl"
  elif command -v curl >/dev/null 2>&1; then
    CURL_BIN="curl"
  else
    log "ОШИБКА: не найдена обязательная команда curl"
    missing=1
  fi

  for command_name in pm getprop iptables iptables-restore ip6tables ip6tables-restore timeout nc awk sed grep sort; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log "ОШИБКА: не найдена обязательная команда $command_name"
      missing=1
    fi
  done
  [ -x "$ROUTER_BIN" ] || {
    log "ОШИБКА: не найден исполняемый $ROUTER_BIN"
    missing=1
  }
  [ -s "$SNI_ROUTES" ] || {
    log "ОШИБКА: не найден $SNI_ROUTES"
    missing=1
  }
  [ "$missing" -eq 0 ]
}

get_uids() {
  local package_name="$1"
  pm list packages -U "$package_name" 2>/dev/null |
    awk -v wanted="package:$package_name" '
      $1 == wanted {
        sub(/^uid:/, "", $2)
        gsub(/,/, "\n", $2)
        print $2
      }
    ' |
    awk '/^[0-9]+$/ && $1 > 9999 && !seen[$1]++ { print $1 }' |
    sort -n
}

refresh_uids() {
  GOOGLE_UIDS=$(get_uids "$GOOGLE_PACKAGE")
  BARD_UIDS=$(get_uids "$BARD_PACKAGE")
  NOTEBOOK_UIDS=$(get_uids "$NOTEBOOK_PACKAGE")
  CHATGPT_UIDS=$(get_uids "$CHATGPT_PACKAGE")
  CLAUDE_UIDS=$(get_uids "$CLAUDE_PACKAGE")
  GROK_UIDS=$(get_uids "$GROK_PACKAGE")
  log "UID: Google=[$GOOGLE_UIDS], Bard=[$BARD_UIDS], Notebook=[$NOTEBOOK_UIDS], ChatGPT=[$CHATGPT_UIDS], Claude=[$CLAUDE_UIDS], Grok=[$GROK_UIDS]"
}

locale_state_contains() {
  local package_name="$1"
  local user_id="$2"
  [ -f "$LOCALE_STATE" ] || return 1
  awk -F '|' -v p="$package_name" -v u="$user_id" '
    $1 == p && $2 == u { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$LOCALE_STATE"
}

apply_app_locales() {
  cmd locale help 2>/dev/null | grep -q "set-app-locales" || {
    log "Per-app locale API недоступен; глобальная локаль не изменяется"
    return 0
  }

  touch "$LOCALE_STATE"
  chmod 0600 "$LOCALE_STATE" 2>/dev/null

  local users package_name user_id current_output current_locales
  users=$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')

  for user_id in $users; do
    for package_name in $LOCALE_PACKAGES; do
      pm list packages --user "$user_id" "$package_name" 2>/dev/null |
        grep -q "^package:$package_name$" || continue

      if ! locale_state_contains "$package_name" "$user_id"; then
        current_output=$(cmd locale get-app-locales "$package_name" --user "$user_id" 2>/dev/null)
        current_locales=$(echo "$current_output" | sed -n 's/.*are \[\(.*\)\].*/\1/p')
        echo "$package_name|$user_id|$current_locales" >> "$LOCALE_STATE"
      fi

      if cmd locale set-app-locales "$package_name" --user "$user_id" --locales en-US >/dev/null 2>&1; then
        log "Per-app locale en-US: $package_name (user $user_id)"
      else
        log "ПРЕДУПРЕЖДЕНИЕ: не удалось установить app-locale для $package_name (user $user_id)"
      fi
    done
  done
}

ensure_chain() {
  local family="$1"
  local table="$2"
  local chain="$3"

  if [ "$family" = "4" ]; then
    if ipt -t "$table" -N "$chain" 2>/dev/null; then
      if [ "$table" = "nat" ]; then
        ipt -t "$table" -A "$chain" -j RETURN || return 1
      else
        ipt -t "$table" -A "$chain" -j DROP || return 1
      fi
    fi
    ipt -t "$table" -S "$chain" >/dev/null 2>&1
  else
    if ip6t -t "$table" -N "$chain" 2>/dev/null; then
      ip6t -t "$table" -A "$chain" -j DROP || return 1
    fi
    ip6t -t "$table" -S "$chain" >/dev/null 2>&1
  fi
}

init_chains() {
  local chain
  for chain in AIUNBLOCK_OUT AIUNBLOCK_SNI GEMINI_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
    ensure_chain 4 nat "$chain" || {
      log "ОШИБКА: не удалось подготовить nat/$chain"
      return 1
    }
  done

  ensure_chain 4 filter AIUNBLOCK_QUIC || return 1
  ensure_chain 4 filter AIUNBLOCK_GUARD || return 1
  ensure_chain 6 filter AIUNBLOCK_V6 || return 1
  return 0
}

init_chains_with_retry() {
  local attempt=1
  while [ "$attempt" -le "$INIT_RETRIES" ]; do
    if init_chains; then
      return 0
    fi
    if [ "$attempt" -lt "$INIT_RETRIES" ]; then
      log "Повтор инициализации firewall $attempt/$INIT_RETRIES через ${INIT_RETRY_DELAY}с"
      sleep "$INIT_RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

remove_legacy_rules_for_uid() {
  local uid="$1"
  local target

  for target in GEMINI_DNAT GOOGLE_APP_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
    while ipt -t nat -C OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j "$target" 2>/dev/null; do
      ipt -t nat -D OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j "$target" || break
    done
  done

  while ipt -C OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j DROP 2>/dev/null; do
    ipt -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j DROP || break
  done
  while ip6t -C OUTPUT -m owner --uid-owner "$uid" -j DROP 2>/dev/null; do
    ip6t -D OUTPUT -m owner --uid-owner "$uid" -j DROP || break
  done
}

cleanup_legacy_google_chain() {
  ipt -t nat -F GOOGLE_APP_DNAT 2>/dev/null
  ipt -t nat -X GOOGLE_APP_DNAT 2>/dev/null
}

install_hooks() {
  ipt -C OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_GUARD 2>/dev/null ||
    ipt -I OUTPUT 1 -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_GUARD || return 1

  ipt -C OUTPUT -p udp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_QUIC 2>/dev/null ||
    ipt -I OUTPUT 1 -p udp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_QUIC || return 1

  ip6t -C OUTPUT -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6 2>/dev/null ||
    ip6t -I OUTPUT 1 -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6 || return 1

  ipt -t nat -C OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_OUT 2>/dev/null ||
    ipt -t nat -I OUTPUT 1 -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_OUT || return 1
}


apply_uid_rules() {
  router_running || return 1

  {
    echo "*filter"
    echo "-F AIUNBLOCK_GUARD"
    echo "-A AIUNBLOCK_GUARD -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush || return 1

  {
    echo "*nat"
    echo "-F AIUNBLOCK_SNI"
    echo "-A AIUNBLOCK_SNI -p tcp --dport 443 -j REDIRECT --to-ports $ROUTER_PORT"
    echo "-A AIUNBLOCK_SNI -j RETURN"
    echo "-F AIUNBLOCK_OUT"
    if [ -n "$CURRENT_GEMINI" ]; then
      for uid in $GOOGLE_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j AIUNBLOCK_SNI"
      done
      for uid in $BARD_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j GEMINI_DNAT"
      done
    fi
    if [ -n "$CURRENT_NOTEBOOK" ]; then
      for uid in $NOTEBOOK_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j AIUNBLOCK_SNI"
      done
    fi
    if [ -n "$CURRENT_CHATGPT" ]; then
      for uid in $CHATGPT_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j CHATGPT_DNAT"
      done
    fi
    if [ -n "$CURRENT_CLAUDE" ]; then
      for uid in $CLAUDE_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j CLAUDE_DNAT"
      done
    fi
    if [ -n "$CURRENT_GROK" ]; then
      for uid in $GROK_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_OUT -m owner --uid-owner $uid -j GROK_DNAT"
      done
    fi
    echo "-A AIUNBLOCK_OUT -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush || return 1

  {
    echo "*filter"
    echo "-F AIUNBLOCK_QUIC"
    if [ -n "$CURRENT_GEMINI" ]; then
      for uid in $GOOGLE_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j REJECT --reject-with icmp-port-unreachable"
      done
      for uid in $BARD_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j DROP"
      done
    fi
    if [ -n "$CURRENT_NOTEBOOK" ]; then
      for uid in $NOTEBOOK_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j REJECT --reject-with icmp-port-unreachable"
      done
    fi
    if [ -n "$CURRENT_CHATGPT" ]; then
      for uid in $CHATGPT_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j DROP"
      done
    fi
    if [ -n "$CURRENT_CLAUDE" ]; then
      for uid in $CLAUDE_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j DROP"
      done
    fi
    if [ -n "$CURRENT_GROK" ]; then
      for uid in $GROK_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_QUIC -m owner --uid-owner $uid -j DROP"
      done
    fi
    echo "-A AIUNBLOCK_QUIC -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush || return 1

  {
    echo "*filter"
    echo "-F AIUNBLOCK_V6"
    if [ -n "$CURRENT_GEMINI" ]; then
      for uid in $GOOGLE_UIDS $BARD_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j REJECT --reject-with icmp6-port-unreachable"
      done
    fi
    if [ -n "$CURRENT_NOTEBOOK" ]; then
      for uid in $NOTEBOOK_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j REJECT --reject-with icmp6-port-unreachable"
      done
    fi
    if [ -n "$CURRENT_CHATGPT" ]; then
      for uid in $CHATGPT_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j REJECT --reject-with icmp6-port-unreachable"
      done
    fi
    if [ -n "$CURRENT_CLAUDE" ]; then
      for uid in $CLAUDE_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j REJECT --reject-with icmp6-port-unreachable"
      done
    fi
    if [ -n "$CURRENT_GROK" ]; then
      for uid in $GROK_UIDS; do
        [ -n "$uid" ] && echo "-A AIUNBLOCK_V6 -m owner --uid-owner $uid -j REJECT --reject-with icmp6-port-unreachable"
      done
    fi
    echo "-A AIUNBLOCK_V6 -j RETURN"
    echo "COMMIT"
  } | ip6t_restore --noflush || return 1
}

check_proxy_site() {
  local ip="$1"
  local domain="$2"
  local result code curl_status

  result=$(timeout "$CURL_MAX_TIME" "$CURL_BIN" -sS \
    --connect-timeout 5 \
    --max-time "$CURL_MAX_TIME" \
    --resolve "$domain:443:$ip" \
    "https://$domain/" \
    -o /dev/null \
    -w '%{http_code}' 2>/dev/null)
  curl_status=$?
  code="$result"

  if [ "$curl_status" -eq 0 ] &&
     [ "$code" -ge 200 ] 2>/dev/null &&
     [ "$code" -lt 500 ] 2>/dev/null; then
    log "Адрес $ip для $domain доступен (TLS verified, HTTP $code)"
    return 0
  fi

  log "Адрес $ip для $domain не прошёл проверку (curl=$curl_status, HTTP=${code:-000})"
  return 1
}

check_proxy_domains() {
  local ip="$1"
  local domains="$2"
  local domain
  for domain in $domains; do
    check_proxy_site "$ip" "$domain" || return 1
  done
}

# Получает актуальные IPv4-шлюзы непосредственно от Smart DNS через DoH.
# curl одновременно выполняет DNS-запрос и проверяет TLS-соединение с доменом.
# Запросы к независимым резолверам идут параллельно, поэтому один медленный
# провайдер не задерживает переключение на сумму всех таймаутов.
discover_doh_gateways() {
  local domain="$1"
  local tmp_base="$GATEWAY_DIR/.doh.$$"
  local resolver index pid pids file ip discovered

  [ -n "$DOH_RESOLVERS" ] || return 0
  mkdir -p "$GATEWAY_DIR"
  index=0
  pids=""

  for resolver in $DOH_RESOLVERS; do
    index=$((index + 1))
    file="$tmp_base.$index"
    (
      ip=$(timeout "$DOH_MAX_TIME" "$CURL_BIN" -4 -sS \
        --doh-url "$resolver" \
        --connect-timeout 5 \
        --max-time "$DOH_MAX_TIME" \
        "https://$domain/" \
        -o /dev/null \
        -w '%{remote_ip}' 2>/dev/null) || exit 1
      is_ipv4 "$ip" || exit 1
      printf '%s|%s\n' "$ip" "$resolver" > "$file"
    ) &
    pids="$pids $!"
  done

  for pid in $pids; do
    wait "$pid" 2>/dev/null
  done

  discovered=""
  for file in "$tmp_base".*; do
    [ -f "$file" ] || continue
    IFS='|' read -r ip resolver < "$file"
    rm -f "$file"
    is_ipv4 "$ip" || continue
    case " $discovered " in
      *" $ip "*) continue ;;
    esac
    discovered="$discovered $ip"
    log "Smart DNS DoH $resolver выдал для $domain шлюз $ip"
  done

  echo "$discovered"
}

send_udp_dns_packet() {
  local dns="$1"
  local packet="$2"

  if printf "$packet" | timeout 3 nc -u -q 1 "$dns" 53 >/dev/null 2>&1; then
    return 0
  fi
  if printf "$packet" | timeout 3 nc -u -w 1 "$dns" 53 >/dev/null 2>&1; then
    return 0
  fi
  if printf "$packet" | timeout 3 nc -u "$dns" 53 >/dev/null 2>&1; then
    return 0
  fi
  if command -v bash >/dev/null 2>&1; then
    if timeout 3 bash -c "printf '$packet' > /dev/udp/$dns/53" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}


# Механизм "прогрева" / авторизации шлюзов Smart DNS:
# Некоторые Smart DNS (из AUTH_DNS / proxies.conf) требуют предварительного DNS-запроса
# перед тем, как их шлюз начнёт принимать TLS-трафик от клиента.
# Функция authorize_ips() отправляет сырой UDP DNS-пакет (запрос chatgpt.com по UDP/53) на целевые IP.
# Это авторизует внешний IP клиента у Smart DNS и позволяет последующим TCP/TLS-подключениям
# к выданному шлюзу через DNAT работать без сброса по таймауту.
authorize_ips() {
  local packet="\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07chatgpt\x03com\x00\x00\x01\x00\x01"
  local dns pid pids successes
  pids=""
  successes=0

  for dns in $AUTH_DNS; do
    (send_udp_dns_packet "$dns" "$packet") &
    pids="$pids $!"
  done

  for pid in $pids; do
    if wait "$pid"; then
      successes=$((successes + 1))
    fi
  done
  log "UDP-авторизация завершена: успешных DNS-запросов $successes"
  [ "$successes" -gt 0 ]
}


authorize_ips_with_retry() {
  local attempt=1

  while [ "$attempt" -le "$AUTH_RETRIES" ]; do
    if authorize_ips; then
      return 0
    fi
    if [ "$attempt" -lt "$AUTH_RETRIES" ]; then
      log "Сеть для DNS-авторизации ещё не готова; повтор $((attempt + 1))/$AUTH_RETRIES через ${AUTH_RETRY_DELAY}с"
      sleep "$AUTH_RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done

  log "ВНИМАНИЕ: DNS-авторизация пока недоступна; будет быстрый повтор без блокировки приложений"
  return 1
}

ipv4_network_ready() {
  local route
  route=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 1
  echo "$route" | grep -q " dev " || return 1
  echo "$route" | grep -q " dev lo " && return 1
  return 0
}

apply_passthrough_rules() {
  local saved_gemini="$CURRENT_GEMINI"
  local saved_notebook="$CURRENT_NOTEBOOK"
  local saved_chatgpt="$CURRENT_CHATGPT"
  local saved_claude="$CURRENT_CLAUDE"
  local saved_grok="$CURRENT_GROK"
  local result=0

  CURRENT_GEMINI=""
  CURRENT_NOTEBOOK=""
  CURRENT_CHATGPT=""
  CURRENT_CLAUDE=""
  CURRENT_GROK=""

  apply_uid_rules && install_hooks || result=1

  CURRENT_GEMINI="$saved_gemini"
  CURRENT_NOTEBOOK="$saved_notebook"
  CURRENT_CHATGPT="$saved_chatgpt"
  CURRENT_CLAUDE="$saved_claude"
  CURRENT_GROK="$saved_grok"
  return "$result"
}

select_proxy() {
  local current="$1"
  local domains="$2"
  local candidates="$3"
  local discovery_domain="${4:-${domains%% *}}"
  local discovered ip

  if [ -n "$current" ] && check_proxy_domains "$current" "$domains"; then
    echo "$current"
    return 0
  fi

  discovered=$(discover_doh_gateways "$discovery_domain")
  candidates="$discovered $candidates"

  for ip in $candidates; do
    [ "$ip" = "$current" ] && continue
    log "Проверка адреса $ip для [$domains]"
    if check_proxy_domains "$ip" "$domains"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

gateway_path() {
  echo "$GATEWAY_DIR/$1.current"
}

read_gateway() {
  local path value
  path=$(gateway_path "$1")
  value=$(cat "$path" 2>/dev/null)
  if is_ipv4 "$value"; then
    echo "$value"
    return 0
  fi
  return 1
}

publish_gateway() {
  local group="$1"
  local ip="$2"
  local path tmp
  is_ipv4 "$ip" || return 1

  path=$(gateway_path "$group")
  tmp="$path.tmp.$$"
  printf '%s\n' "$ip" > "$tmp" || return 1
  chmod 0600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$path"
}

apply_service_rules() {
  local chain="$1"
  local ip="$2"
  {
    echo "*nat"
    echo "-F $chain"
    echo "-A $chain -d $ip -j RETURN"
    echo "-A $chain -p tcp --dport 443 -j DNAT --to-destination $ip:443"
    echo "-A $chain -j RETURN"
    echo "COMMIT"
  } | ipt_restore --noflush
}

activate_gemini_gateway() {
  local selected="$1"
  local previous="$CURRENT_GEMINI"

  apply_service_rules GEMINI_DNAT "$selected" || return 1
  if publish_gateway gemini "$selected"; then
    CURRENT_GEMINI="$selected"
    return 0
  fi

  if [ -n "$previous" ]; then
    apply_service_rules GEMINI_DNAT "$previous" >/dev/null 2>&1
  fi
  return 1
}

refresh_proxy_rules() {
  local selected

  if [ -n "$BARD_UIDS$GOOGLE_UIDS" ]; then
    selected=$(select_proxy "$CURRENT_GEMINI" \
      "gemini.google.com robinfrontend-pa.googleapis.com proactivebackend-pa.googleapis.com" \
      "$PROXIES" "gemini.google.com")
    if [ -n "$selected" ]; then
      if [ "$selected" != "$CURRENT_GEMINI" ]; then
        if activate_gemini_gateway "$selected"; then
          log "Выбран адрес Gemini: $CURRENT_GEMINI"
        else
          log "ОШИБКА: атомарное обновление Gemini отклонено"
          RETRY_SOON=1
        fi
      elif ! apply_service_rules GEMINI_DNAT "$selected"; then
        CURRENT_GEMINI=""
        RETRY_SOON=1
        log "ОШИБКА: не удалось восстановить правило standalone Gemini"
      fi
    else
      CURRENT_GEMINI=""
      RETRY_SOON=1
      log "ВНИМАНИЕ: рабочий адрес Gemini не найден; включён прямой доступ до следующей проверки"
    fi
  fi

  if [ -n "$NOTEBOOK_UIDS" ]; then
    selected=$(select_proxy "$CURRENT_NOTEBOOK" \
      "notebooklm-pa.googleapis.com" "$PROXIES")
    if [ -n "$selected" ]; then
      if [ "$selected" != "$CURRENT_NOTEBOOK" ]; then
        if publish_gateway notebook "$selected"; then
          CURRENT_NOTEBOOK="$selected"
          log "Выбран адрес NotebookLM: $CURRENT_NOTEBOOK"
        else
          log "ОШИБКА: атомарное обновление NotebookLM отклонено"
        fi
      fi
    else
      CURRENT_NOTEBOOK=""
      RETRY_SOON=1
      log "ВНИМАНИЕ: рабочий адрес NotebookLM не найден; включён прямой доступ до следующей проверки"
    fi
  fi

  if [ -n "$CHATGPT_UIDS" ]; then
    selected=$(select_proxy "$CURRENT_CHATGPT" "chatgpt.com" "$AI_PROXIES")
    if [ -n "$selected" ]; then
      if [ "$selected" != "$CURRENT_CHATGPT" ]; then
        if apply_service_rules CHATGPT_DNAT "$selected" && publish_gateway chatgpt "$selected"; then
          CURRENT_CHATGPT="$selected"
          log "Выбран адрес ChatGPT: $CURRENT_CHATGPT"
        else
          log "ОШИБКА: атомарное обновление ChatGPT отклонено"
        fi
      elif ! apply_service_rules CHATGPT_DNAT "$selected"; then
        CURRENT_CHATGPT=""
        RETRY_SOON=1
        log "ОШИБКА: не удалось восстановить правило ChatGPT"
      fi
    else
      CURRENT_CHATGPT=""
      RETRY_SOON=1
      log "ВНИМАНИЕ: рабочий адрес ChatGPT не найден; включён прямой доступ до следующей проверки"
    fi
  fi

  if [ -n "$CLAUDE_UIDS" ]; then
    selected=$(select_proxy "$CURRENT_CLAUDE" "claude.ai" "$AI_PROXIES")
    if [ -n "$selected" ]; then
      if [ "$selected" != "$CURRENT_CLAUDE" ]; then
        if apply_service_rules CLAUDE_DNAT "$selected" && publish_gateway claude "$selected"; then
          CURRENT_CLAUDE="$selected"
          log "Выбран адрес Claude: $CURRENT_CLAUDE"
        else
          log "ОШИБКА: атомарное обновление Claude отклонено"
        fi
      elif ! apply_service_rules CLAUDE_DNAT "$selected"; then
        CURRENT_CLAUDE=""
        RETRY_SOON=1
        log "ОШИБКА: не удалось восстановить правило Claude"
      fi
    else
      CURRENT_CLAUDE=""
      RETRY_SOON=1
      log "ВНИМАНИЕ: рабочий адрес Claude не найден; включён прямой доступ до следующей проверки"
    fi
  fi


  if [ -n "$GROK_UIDS" ]; then
    selected=$(select_proxy "$CURRENT_GROK" "grok.com" "$AI_PROXIES")
    if [ -n "$selected" ]; then
      if [ "$selected" != "$CURRENT_GROK" ]; then
        if apply_service_rules GROK_DNAT "$selected" && publish_gateway grok "$selected"; then
          CURRENT_GROK="$selected"
          log "Выбран адрес Grok: $CURRENT_GROK"
        else
          log "ОШИБКА: атомарное обновление Grok отклонено"
        fi
      elif ! apply_service_rules GROK_DNAT "$selected"; then
        CURRENT_GROK=""
        RETRY_SOON=1
        log "ОШИБКА: не удалось восстановить правило Grok"
      fi
    else
      CURRENT_GROK=""
      RETRY_SOON=1
      log "ВНИМАНИЕ: рабочий адрес Grok не найден; включён прямой доступ до следующей проверки"
    fi
  fi
}

refresh_all() {
  rotate_log
  refresh_uids
  apply_app_locales

  if ! ipv4_network_ready; then
    WAITING_FOR_NETWORK=1
    RETRY_SOON=1
    if [ "$NETWORK_WAIT_LOGGED" -eq 0 ]; then
      log "IPv4-сеть пока недоступна; DNS-авторизация отложена, приложения работают напрямую"
      NETWORK_WAIT_LOGGED=1
    fi
    apply_passthrough_rules || log "ОШИБКА: не удалось включить прямой режим ожидания сети"
    return 0
  fi

  if [ "$WAITING_FOR_NETWORK" -eq 1 ]; then
    log "IPv4-сеть появилась; запускается DNS-авторизация"
  fi
  WAITING_FOR_NETWORK=0
  NETWORK_WAIT_LOGGED=0
  RETRY_SOON=0

  if ! authorize_ips_with_retry; then
    RETRY_SOON=1
    apply_passthrough_rules || log "ОШИБКА: не удалось включить прямой режим после ошибки DNS-авторизации"
    return 0
  fi

  refresh_proxy_rules

  if apply_uid_rules && install_hooks; then
    local uid
    for uid in $GOOGLE_UIDS $BARD_UIDS $NOTEBOOK_UIDS $CHATGPT_UIDS $CLAUDE_UIDS $GROK_UIDS; do
      [ -n "$uid" ] && remove_legacy_rules_for_uid "$uid"
    done
    cleanup_legacy_google_chain
    log "Правила IPv4/IPv6, QUIC и SNI-router атомарно обновлены"
  else
    log "ОШИБКА: классификаторы UID или OUTPUT hooks не обновлены"
  fi
}

needs_fast_retry() {
  if [ -n "$GOOGLE_UIDS$BARD_UIDS" ] && [ -z "$CURRENT_GEMINI" ]; then
    return 0
  fi
  if [ -n "$NOTEBOOK_UIDS" ] && [ -z "$CURRENT_NOTEBOOK" ]; then
    return 0
  fi
  if [ -n "$CHATGPT_UIDS" ] && [ -z "$CURRENT_CHATGPT" ]; then
    return 0
  fi
  if [ -n "$CLAUDE_UIDS" ] && [ -z "$CURRENT_CLAUDE" ]; then
    return 0
  fi
  if [ -n "$GROK_UIDS" ] && [ -z "$CURRENT_GROK" ]; then
    return 0
  fi
  return 1
}

next_check_interval() {
  if [ "$WAITING_FOR_NETWORK" -eq 1 ] || [ "$RETRY_SOON" -eq 1 ] || needs_fast_retry; then
    echo "$FAST_RETRY_INTERVAL"
  else
    echo "$CHECK_INTERVAL"
  fi
}

mount_hosts() {
  local sys_hosts="/system/etc/hosts"
  local ai_hosts="$MODDIR/etc/hosts.ai"
  local adblock_hosts="$MODDIR/etc/hosts.adblock"

  local enable_routing=1
  local enable_adblock=1

  if [ -f "$MODDIR/install.conf" ]; then
    . "$MODDIR/install.conf"
    enable_routing=${ENABLE_HOSTS_ROUTING:-1}
    enable_adblock=${ENABLE_ADBLOCK:-1}
  fi

  # Валидация значений из install.conf на 0/1
  case "$enable_routing" in 0|1) ;; *) enable_routing=1 ;; esac
  case "$enable_adblock" in 0|1) ;; *) enable_adblock=1 ;; esac

  if [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 0 ]; then
    log "Монтирование hosts отключено пользователем в install.conf"
    rm -rf "$MODDIR/system" 2>/dev/null
    return 0
  fi

  if command -v hosts_conflict_detected >/dev/null 2>&1; then
    local conflict_id
    conflict_id=$(hosts_conflict_detected "$MODULE_ID")
    if [ -n "$conflict_id" ]; then
      log "Монтирование hosts пропущено: конфликт с модулем '$conflict_id'"
      rm -rf "$MODDIR/system" 2>/dev/null
      return 0
    fi
  fi

  mkdir -p "$MODDIR/system/etc"
  local target_hosts="$MODDIR/system/etc/hosts"

  if [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 0 ]; then
    [ -f "$ai_hosts" ] && cp -f "$ai_hosts" "$target_hosts"
  elif [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 1 ]; then
    [ -f "$adblock_hosts" ] && cp -f "$adblock_hosts" "$target_hosts"
  elif [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 1 ]; then
    if [ -f "$ai_hosts" ] && [ -f "$adblock_hosts" ]; then
      sed 's/\r$//' "$ai_hosts" > "$target_hosts" 2>/dev/null
      echo "" >> "$target_hosts"
      sed 's/\r$//' "$adblock_hosts" >> "$target_hosts" 2>/dev/null
    elif [ -f "$ai_hosts" ]; then
      cp -f "$ai_hosts" "$target_hosts"
    fi
  fi
  [ -f "$target_hosts" ] && chmod 0644 "$target_hosts" 2>/dev/null
}

if [ "$1" = "--remount-hosts" ]; then
  mount_hosts
  exit 0
fi

main_loop() {
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done

  mount_hosts
  secure_permissions
  rotate_log
  log "AI Unblock v2.2.2: supervisor запущен (PID $$)"

  acquire_lock || return 0
  trap shutdown_service EXIT
  trap 'exit 0' HUP INT TERM

  check_dependencies || {
    log "КРИТИЧЕСКАЯ ОШИБКА: запуск остановлен из-за отсутствующих зависимостей"
    return 1
  }

  configure_xtables_wait
  load_smartdns_resolvers
  load_proxy_override
  init_chains_with_retry || {
    log "КРИТИЧЕСКАЯ ОШИБКА: цепочки firewall не созданы"
    return 1
  }

  CURRENT_GEMINI=$(read_gateway gemini)
  CURRENT_NOTEBOOK=$(read_gateway notebook)
  CURRENT_CHATGPT=$(read_gateway chatgpt)
  CURRENT_CLAUDE=$(read_gateway claude)
  CURRENT_GROK=$(read_gateway grok)


  maintain_router || {
    log "КРИТИЧЕСКАЯ ОШИБКА: SNI-router не запущен"
    return 1
  }
  refresh_all

  local next_refresh now interval network_available
  now=$(date +%s)
  interval=$(next_check_interval)
  next_refresh=$((now + interval))

  while true; do
    maintain_router
    now=$(date +%s)
    network_available=0
    ipv4_network_ready && network_available=1

    if [ "$network_available" -eq 0 ] && [ "$WAITING_FOR_NETWORK" -eq 0 ]; then
      refresh_all
      now=$(date +%s)
      interval=$(next_check_interval)
      next_refresh=$((now + interval))
    elif [ "$network_available" -eq 1 ] && [ "$WAITING_FOR_NETWORK" -eq 1 ]; then
      refresh_all
      now=$(date +%s)
      interval=$(next_check_interval)
      next_refresh=$((now + interval))
    elif [ "$network_available" -eq 0 ] && [ "$WAITING_FOR_NETWORK" -eq 1 ]; then
      :
    elif [ "$now" -ge "$next_refresh" ] 2>/dev/null; then
      refresh_all
      now=$(date +%s)
      interval=$(next_check_interval)
      next_refresh=$((now + interval))
    fi
    sleep "$WATCHDOG_INTERVAL"
  done
}

# KernelSU/Magisk/APatch запускают service.sh асинхронно.
main_loop
