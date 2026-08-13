#!/system/bin/sh
# РђРєС‚РёРІРЅС‹Р№ РїРѕРґР±РѕСЂ СЃС‚СЂР°С‚РµРіРёРё РґР»СЏ СЏРґРµСЂ Р±РµР· xt_connbytes.
# РўРµСЃС‚РѕРІС‹Р№ С‚СЂР°С„РёРє РёР·РѕР»РёСЂСѓРµС‚СЃСЏ РїРѕ Р»РѕРєР°Р»СЊРЅРѕРјСѓ TCP-РїРѕСЂС‚Сѓ Рё РѕС‚РґРµР»СЊРЅРѕР№ NFQUEUE.

umask 077
MODDIR=${0%/*}
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
STATE_DIR="$MODDIR/state"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_auto.log"
LOCK_DIR="$RUN_DIR/auto-select.lock"
RESULT_FILE="$RUN_DIR/auto-current.env"
HEALTH_FILE="$RUN_DIR/health.env"
PROBE_PID_FILE="$RUN_DIR/auto-probe.pid"
TEST_NFQ_PID_FILE="$RUN_DIR/auto-test-nfqws.pid"
BIN_DIR="$MODDIR/bin"
STRATEGY_DIR="$MODDIR/strategies"
STRATEGY_LIB="$MODDIR/strategy-lib.sh"

mkdir -p "$RUN_DIR" "$STATE_DIR" "$LOG_DIR" 2>/dev/null
chmod 0700 "$RUN_DIR" "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${AUTO_SELECT_ENABLED:=1}" "${AUTO_CACHE_TTL:=86400}" "${AUTO_WIFI_CACHE_TTL:=86400}" "${AUTO_CELL_CACHE_TTL:=3600}"
: "${AUTO_TEST_QNUM:=201}"
: "${AUTO_TEST_PORT_MIN:=39000}" "${AUTO_TEST_PORT_MAX:=39049}" "${AUTO_TEST_TIMEOUT:=5}"
: "${AUTO_PROFILE_DEFAULT:=strategy_2}"
: "${AUTO_ALLOW_DIRECT:=1}"
# РљРѕРЅС‚СЂРѕР»СЊРЅС‹Рµ С…РѕСЃС‚С‹. РџСЂРѕРіРѕРЅСЏСЋС‚СЃСЏ С†РµР»РёРєРѕРј Рё РґР»СЏ Р±Р°Р·РѕРІРѕР№ Р»РёРЅРёРё, Рё РґР»СЏ РєР°Р¶РґРѕРіРѕ
# РєР°РЅРґРёРґР°С‚Р°, РїРѕСЌС‚РѕРјСѓ СЃРїРёСЃРѕРє РЅР°РјРµСЂРµРЅРЅРѕ РєРѕСЂРѕС‚РєРёР№.
: "${AUTO_PROBE_HOSTS_GENERAL:=discord.com=200// www.instagram.com=200// x.com=200//}"
: "${AUTO_PROBE_HOSTS_GOOGLE:=www.youtube.com=204//generate_204 youtubei.googleapis.com=204//generate_204 redirector.googlevideo.com=200//report_mapping}"
PROBE_SPEC_FILE="$RUN_DIR/auto-probe-spec.$$"
BASELINE_FILE="$RUN_DIR/auto-probe-base.$$"
CANDIDATE_FILE="$RUN_DIR/auto-probe-cand.$$"
# 0 вЂ” РїСЂРѕРІРµСЂСЏС‚СЊ РІСЃРµ СЃС‚СЂР°С‚РµРіРёРё; РёРЅР°С‡Рµ РѕРіСЂР°РЅРёС‡РµРЅРёРµ РЅР° РѕРґРёРЅ РїСЂРѕРіРѕРЅ.
: "${AUTO_PROBE_MAX_CANDIDATES:=0}"
[ -f "$STRATEGY_LIB" ] && . "$STRATEGY_LIB"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

now_epoch() {
  local value
  value=$(date +%s 2>/dev/null)
  case "$value" in ''|*[!0-9]*) echo 0 ;; *) echo "$value" ;; esac
}

active_network_snapshot() {
  local snapshot="$RUN_DIR/auto-connectivity.$$" net line iface subid dns
  dumpsys connectivity > "$snapshot" 2>/dev/null || { rm -f "$snapshot" 2>/dev/null; return 1; }
  chmod 0600 "$snapshot" 2>/dev/null || true
  net=$(sed -n 's/^Active default network: \([0-9][0-9]*\).*$/\1/p' "$snapshot" | head -n1)
  [ -n "$net" ] || { rm -f "$snapshot" 2>/dev/null; return 1; }
  line=$(grep -F "NetworkAgentInfo{network{$net}" "$snapshot" | head -n1)
  rm -f "$snapshot" 2>/dev/null
  [ -n "$line" ] || return 1
  iface=$(printf '%s\n' "$line" | sed -n 's/^.*InterfaceName: \([^ ]*\).*$/\1/p')
  subid=$(printf '%s\n' "$line" | sed -n 's/^.*SubscriptionIds: {\([^}]*\)}.*$/\1/p' | tr -d ' ' | cut -d, -f1)
  dns=$(printf '%s\n' "$line" | sed -n 's/^.*DnsAddresses: \[ \([^]]*\) \].*$/\1/p' | tr -d '/ ')
  [ -n "$iface" ] || return 1
  printf '%s|%s|%s|%s\n' "$iface" "$subid" "$dns" "$net"
}

snapshot_field() {
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '{print $n; exit}'
}

default_iface() {
  local snapshot iface
  snapshot=$(active_network_snapshot)
  iface=$(snapshot_field "$snapshot" 1)
  [ -n "$iface" ] && { printf '%s\n' "$iface"; return 0; }
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
}

network_identity() {
  local iface="$1" snapshot="$2" route extra rest active_subid subid
  route=$(ip -4 route get 1.1.1.1 2>/dev/null | tr '\n' ' ')
  case "$iface" in
    wlan*|wifi*|swlan*)
      extra=$(cmd wifi status 2>/dev/null | sed -n 's/^Wifi is connected to[[:space:]]*//p' | head -n1)
      [ -n "$extra" ] || extra=$(cmd wifi status 2>/dev/null | sed -n 's/^[[:space:]]*WifiInfo:.*SSID: \([^,}]*\).*$/\1/p' | head -n1)
      extra=$(printf '%s' "$extra" | tr -d '\r\n')
      route=$(printf '%s' "$route" | sed 's/[[:space:]]src[[:space:]][^[:space:]]*//; s/[[:space:]]uid[[:space:]][^[:space:]]*//; s/[[:space:]]cache.*$//')
      printf 'WIFI|%s|%s|%s' "$iface" "$extra" "$route"
      ;;
    rmnet*|ccmni*|pdp*|wwan*)
      extra=$(getprop gsm.operator.numeric 2>/dev/null | tr -d '\r\n ')
      [ -n "$snapshot" ] || snapshot=$(active_network_snapshot)
      active_subid=$(snapshot_field "$snapshot" 2)
      subid=${active_subid:-$(settings get global multi_sim_data_call 2>/dev/null | tr -d '\r\n ')}
      printf 'CELL|%s|%s' "$subid" "$extra"
      ;;
    *) printf 'NET|%s|%s' "$iface" "$route" ;;
  esac
}

network_key() {
  local identity="$1" sum size
  set -- $(printf '%s' "$identity" | cksum 2>/dev/null)
  sum=$1; size=$2
  case "$sum:$size" in *[!0-9:]*) return 1 ;; esac
  printf '%s-%s\n' "$sum" "$size"
}

cache_file_for() { printf '%s/auto-%s.env\n' "$STATE_DIR" "$1"; }

cache_ttl_for_iface() {
  case "$1" in
    rmnet*|ccmni*|pdp*|wwan*) printf '%s\n' "$AUTO_CELL_CACHE_TTL" ;;
    wlan*|wifi*|swlan*) printf '%s\n' "$AUTO_WIFI_CACHE_TTL" ;;
    *) printf '%s\n' "$AUTO_CACHE_TTL" ;;
  esac
}

valid_profile() {
  strategy_read "$1"
}

profile_name() {
  strategy_read "$1" || return 1
  printf '%s\n' "$STRATEGY_FILE_NAME"
}

applied_profile() {
  sed -n 's/^AUTO_PROFILE=//p' "$HEALTH_FILE" 2>/dev/null | head -n1
}

sync_health_result() {
  [ -f "$HEALTH_FILE" ] && [ -f "$RESULT_FILE" ] || return 0
  local profile name signature status key iface updated tmp
  profile=$(sed -n 's/^AUTO_PROFILE=//p' "$RESULT_FILE" | head -n1)
  name=$(sed -n 's/^AUTO_PROFILE_NAME=//p' "$RESULT_FILE" | head -n1)
  signature=$(sed -n 's/^AUTO_STRATEGY_SIGNATURE=//p' "$RESULT_FILE" | head -n1)
  status=$(sed -n 's/^AUTO_STATUS=//p' "$RESULT_FILE" | head -n1)
  key=$(sed -n 's/^AUTO_NETWORK_KEY=//p' "$RESULT_FILE" | head -n1)
  iface=$(sed -n 's/^AUTO_NETWORK_IFACE=//p' "$RESULT_FILE" | head -n1)
  updated=$(sed -n 's/^AUTO_UPDATED=//p' "$RESULT_FILE" | head -n1)
  tmp="$HEALTH_FILE.tmp.$$"
  awk -v p="$profile" -v n="$name" -v g="$signature" -v s="$status" -v k="$key" -v i="$iface" -v u="$updated" '
    /^AUTO_PROFILE=/ {print "AUTO_PROFILE=" p; next}
    /^AUTO_PROFILE_NAME=/ {print "AUTO_PROFILE_NAME=" n; next}
    /^AUTO_STRATEGY_SIGNATURE=/ {print "AUTO_STRATEGY_SIGNATURE=" g; next}
    /^AUTO_STATUS=/ {print "AUTO_STATUS=" s; next}
    /^AUTO_NETWORK_KEY=/ {print "AUTO_NETWORK_KEY=" k; next}
    /^AUTO_NETWORK_IFACE=/ {print "AUTO_NETWORK_IFACE=" i; next}
    /^AUTO_UPDATED=/ {print "AUTO_UPDATED=" u; next}
    /^COMPAT_STATUS=/ {if (n == "DIRECT") {print "COMPAT_STATUS=DIRECT"; next}; print; next}
    /^COMPAT_NOTES=/ {
      if (n == "DIRECT") print "COMPAT_NOTES=DIRECT: СЃРµС‚СЊ " i " РЅРµ С„РёР»СЊС‚СЂСѓРµС‚СЃСЏ, РѕР±С…РѕРґ РѕС‚РєР»СЋС‡С‘РЅ"
      else print "COMPAT_NOTES=SMART_ACTIVE: Р°РєС‚РёРІРЅС‹Р№ РїСЂРѕС„РёР»СЊ " p " / " n " (" s ")"
      next
    }
    {print}
  ' "$HEALTH_FILE" > "$tmp" && mv -f "$tmp" "$HEALTH_FILE"
  chmod 0600 "$HEALTH_FILE" 2>/dev/null || true
}

request_profile_reload() {
  local selected="$1" applied applied_signature current_signature
  applied=$(applied_profile)
  valid_profile "$applied" || applied=""
  applied_signature=$(sed -n 's/^AUTO_STRATEGY_SIGNATURE=//p' "$HEALTH_FILE" 2>/dev/null | head -n1)
  current_signature=$(strategy_catalog_signature)
  if [ "$selected" = "$applied" ] && [ -n "$current_signature" ] && [ "$current_signature" = "$applied_signature" ]; then
    sync_health_result
    return 0
  fi
  [ -x "$MODDIR/service.sh" ] || return 1
  log "AUTO: РїСЂРёРјРµРЅС‘РЅРЅС‹Р№ РїСЂРѕС„РёР»СЊ ${applied:-unknown} -> $selected, Р·Р°РїСЂР°С€РёРІР°РµС‚СЃСЏ Р±С‹СЃС‚СЂС‹Р№ reload"
  sh "$MODDIR/service.sh" reload-profile >/dev/null 2>&1 &
}

write_result() {
  local profile="$1" key="$2" iface="$3" status="$4" updated="$5" tmp="$RESULT_FILE.tmp.$$" name signature
  name=$(profile_name "$profile" 2>/dev/null); [ -n "$name" ] || name=UNKNOWN
  signature=$(strategy_catalog_signature)
  {
    echo "AUTO_PROFILE=$profile"
    echo "AUTO_PROFILE_NAME=$name"
    echo "AUTO_STRATEGY_SIGNATURE=$signature"
    echo "AUTO_NETWORK_KEY=$key"
    echo "AUTO_NETWORK_IFACE=$iface"
    echo "AUTO_STATUS=$status"
    echo "AUTO_UPDATED=$updated"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$RESULT_FILE" 2>/dev/null
  chmod 0600 "$RESULT_FILE" 2>/dev/null || true
}

resolve_current() {
  local snapshot iface identity key cache profile updated now age status ttl default_profile
  default_profile=$AUTO_PROFILE_DEFAULT
  valid_profile "$default_profile" || default_profile=$(strategy_first_valid)
  [ -n "$default_profile" ] || { log "AUTO: РЅРµС‚ РІР°Р»РёРґРЅС‹С… С„Р°Р№Р»РѕРІ СЃС‚СЂР°С‚РµРіРёР№"; return 1; }
  snapshot=$(active_network_snapshot)
  iface=$(snapshot_field "$snapshot" 1)
  [ -n "$iface" ] || iface=$(default_iface)
  [ -n "$iface" ] || { write_result "$default_profile" none none NO_NETWORK 0; return 1; }
  identity="$(network_identity "$iface" "$snapshot")|STRATEGIES=$(strategy_catalog_signature)"
  key=$(network_key "$identity") || key=unknown
  cache=$(cache_file_for "$key")
  profile="$default_profile"; updated=0; status=DEFAULT
  if [ -f "$cache" ]; then
    . "$cache"
    valid_profile "${PROFILE:-}" && profile=$PROFILE
    updated=${UPDATED:-0}
    status=CACHED
  fi
  now=$(now_epoch)
  ttl=$(cache_ttl_for_iface "$iface")
  case "$ttl" in ''|*[!0-9]*) ttl=$AUTO_CACHE_TTL ;; esac
  case "$updated" in ''|*[!0-9]*) updated=0 ;; esac
  age=$((now - updated))
  [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le "$ttl" ] 2>/dev/null || status=STALE
  write_result "$profile" "$key" "$iface" "$status" "$updated"
  printf '%s\n' "$profile"
}

IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables
TEST_PID=""
TEST_RULE_MODE=""

pid_is_test_nfqws() {
  local pid="$1" cmdline
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = nfqws2 ] || return 1
  [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$BIN_DIR" ] || return 1
  cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case " $cmdline " in *" --qnum=$AUTO_TEST_QNUM "*) return 0 ;; *) return 1 ;; esac
}

cleanup_test() {
  local stale_pid n
  while "$IPT" -w 5 -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null; do :; done
  while "$IPT" -w 5 -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN 2>/dev/null; do :; done
  while "$IP6T" -w 5 -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null; do :; done
  while "$IP6T" -w 5 -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN 2>/dev/null; do :; done
  # РЈРґР°Р»РµРЅРёРµ РїСЂР°РІРёР» СЂР°РЅРЅРёС… С‚РµСЃС‚РѕРІС‹С… СЃР±РѕСЂРѕРє, РіРґРµ Android curl РёРіРЅРѕСЂРёСЂРѕРІР°Р» --local-port.
  while "$IPT" -w 5 -t mangle -D OUTPUT -p tcp --sport "$AUTO_TEST_PORT_MIN:$AUTO_TEST_PORT_MAX" --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null; do :; done
  while "$IPT" -w 5 -t mangle -D OUTPUT -p tcp --sport "$AUTO_TEST_PORT_MIN:$AUTO_TEST_PORT_MAX" --dport 443 -j RETURN 2>/dev/null; do :; done
  stale_pid=$(cat "$TEST_NFQ_PID_FILE" 2>/dev/null)
  [ -n "$TEST_PID" ] && stale_pid=$TEST_PID
  if pid_is_test_nfqws "$stale_pid"; then
    kill -TERM "$stale_pid" 2>/dev/null
    n=0; while kill -0 "$stale_pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
    kill -KILL "$stale_pid" 2>/dev/null || true
  fi
  rm -f "$TEST_NFQ_PID_FILE" 2>/dev/null
  TEST_PID=""; TEST_RULE_MODE=""
}

install_direct_rule() {
  cleanup_test
  "$IPT" -w 5 -t mangle -I OUTPUT 1 -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN
  "$IP6T" -w 5 -t mangle -I OUTPUT 1 -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN 2>/dev/null || true
  TEST_RULE_MODE=DIRECT
}

install_candidate_rule() {
  local profile="$1" args
  cleanup_test
  strategy_read "$profile" || return 1
  [ "$STRATEGY_FILE_MODE" = NFQWS ] || return 1
  args=$STRATEGY_FILE_ARGS
  cd "$BIN_DIR" || return 1
  ./nfqws2 --user=root --qnum="$AUTO_TEST_QNUM" --bind-fix4 --bind-fix6 \
    --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
    $args >> "$LOG_FILE" 2>&1 &
  TEST_PID=$!
  echo "$TEST_PID" > "$TEST_NFQ_PID_FILE"
  sleep 1
  pid_is_test_nfqws "$TEST_PID" || { cleanup_test; return 1; }
  "$IPT" -w 5 -t mangle -I OUTPUT 1 -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN || { cleanup_test; return 1; }
  "$IPT" -w 5 -t mangle -I OUTPUT 1 -m owner --uid-owner 0 -p tcp --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass || { cleanup_test; return 1; }
  "$IP6T" -w 5 -t mangle -I OUTPUT 1 -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN 2>/dev/null || true
  "$IP6T" -w 5 -t mangle -I OUTPUT 1 -m owner --uid-owner 0 -p tcp --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null || true
  TEST_RULE_MODE="$profile"
}

test_queue_packets() {
  { "$IPT" -w 5 -t mangle -L OUTPUT -nvx --line-numbers 2>/dev/null; "$IP6T" -w 5 -t mangle -L OUTPUT -nvx --line-numbers 2>/dev/null; } | \
    awk -v q="$AUTO_TEST_QNUM" '$0 ~ "NFQUEUE num " q {sum+=$2} END {print sum+0}'
}

resolve_host_ipv4() {
  local iface="$1" host="$2" dns_servers="$3" provider_ip provider_host query answer ip src server
  query="$RUN_DIR/auto-dns-query.$$"; answer="$RUN_DIR/auto-dns-answer.$$"
  [ -x "$BIN_DIR/mdig" ] || return 1
  "$BIN_DIR/mdig" --family=4 --dns-make-query="$host" > "$query" 2>/dev/null || return 1
  src=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {sub("/.*","",$2); print $2; exit}')
  for server in $(printf '%s' "$dns_servers" | tr ',' ' '); do
    case "$server" in *:*) continue ;; [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;; *) continue ;; esac
    [ -n "$src" ] || break
    : > "$answer"
    if timeout 5 nc -u -q 1 -W 3 -s "$src" "$server" 53 < "$query" > "$answer" 2>/dev/null; then
      ip=$("$BIN_DIR/mdig" --dns-parse-query < "$answer" 2>/dev/null | \
        sed -n '/^[0-9][0-9.]*$/p' | head -n4 | awk 'BEGIN{s=""} {s=s (s?",":"") $0} END{print s}')
      case "$ip" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) rm -f "$query" "$answer" 2>/dev/null; printf '%s\n' "$ip"; return 0 ;; esac
    fi
  done
  for provider in '1.1.1.1|cloudflare-dns.com' '8.8.8.8|dns.google'; do
    provider_ip=$(printf '%s\n' "$provider" | cut -d'|' -f1)
    provider_host=$(printf '%s\n' "$provider" | cut -d'|' -f2)
    if curl -4 -sS --interface "$iface" --resolve "$provider_host:443:$provider_ip" \
      --connect-timeout 3 --max-time 7 -H 'Content-Type: application/dns-message' \
      --data-binary "@$query" "https://$provider_host/dns-query" -o "$answer" 2>/dev/null; then
      ip=$("$BIN_DIR/mdig" --dns-parse-query < "$answer" 2>/dev/null | \
        sed -n '/^[0-9][0-9.]*$/p' | head -n4 | awk 'BEGIN{s=""} {s=s (s?",":"") $0} END{print s}')
      case "$ip" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) rm -f "$query" "$answer" 2>/dev/null; printf '%s\n' "$ip"; return 0 ;; esac
    fi
  done
  rm -f "$query" "$answer" 2>/dev/null
  return 1
}

resolve_host_ipv6() {
  local iface="$1" host="$2" dns_servers="$3" query answer ip src server
  query="$RUN_DIR/auto-dns6-query.$$"; answer="$RUN_DIR/auto-dns6-answer.$$"
  src=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {sub("/.*","",$2); print $2; exit}')
  [ -n "$src" ] && [ -x "$BIN_DIR/mdig" ] || return 1
  "$BIN_DIR/mdig" --family=6 --dns-make-query="$host" > "$query" 2>/dev/null || return 1
  for server in $(printf '%s' "$dns_servers" | tr ',' ' '); do
    case "$server" in *:*) ;; *) continue ;; esac
    : > "$answer"
    if timeout 5 nc -6 -u -q 1 -W 3 -s "$src" "$server" 53 < "$query" > "$answer" 2>/dev/null; then
      ip=$("$BIN_DIR/mdig" --dns-parse-query < "$answer" 2>/dev/null | sed -n '/:/p' | head -n1)
      case "$ip" in *:*) rm -f "$query" "$answer" 2>/dev/null; printf '%s\n' "$ip"; return 0 ;; esac
    fi
  done
  rm -f "$query" "$answer" 2>/dev/null
  return 1
}

# Р—Р°РїРёСЃСЊ РєРѕРЅС‚СЂРѕР»СЊРЅРѕРіРѕ С…РѕСЃС‚Р°: host[=http_РєРѕРґ][//РїСѓС‚СЊ]. РџСѓСЃС‚РѕР№ РїСѓС‚СЊ = "/".
parse_probe_entry() {
  local entry="$1" rest
  P_HOST=${entry%%=*}
  rest=${entry#*=}
  [ "$rest" = "$entry" ] && rest="200//"
  P_CODE=${rest%%//*}
  P_PATH=${rest#*//}
  case "$P_CODE" in ''|*[!0-9]*) P_CODE=200 ;; esac
  case "$P_HOST" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
  case "$P_PATH" in *[!A-Za-z0-9._~/-]*) return 1 ;; esac
  return 0
}

prepare_probe_dns() {
  local iface="$1" snapshot="$2" dns_servers group entries entry ip ip6 total=0 n4=0 n6=0
  dns_servers=$(snapshot_field "$snapshot" 3)
  : > "$PROBE_SPEC_FILE" 2>/dev/null || return 1
  chmod 0600 "$PROBE_SPEC_FILE" 2>/dev/null || true
  for group in GENERAL GOOGLE; do
    eval "entries=\$AUTO_PROBE_HOSTS_$group"
    for entry in $entries; do
      parse_probe_entry "$entry" || { log "AUTO probe: РЅРµРєРѕСЂСЂРµРєС‚РЅР°СЏ Р·Р°РїРёСЃСЊ С…РѕСЃС‚Р° '$entry' РІ РіСЂСѓРїРїРµ $group, РїСЂРѕРїСѓС‰РµРЅР°"; continue; }
      total=$((total + 1))
      ip=$(resolve_host_ipv4 "$iface" "$P_HOST" "$dns_servers") || ip=""
      ip6=$(resolve_host_ipv6 "$iface" "$P_HOST" "$dns_servers") || ip6=""
      if [ -z "$ip" ] && [ -z "$ip6" ]; then
        log "AUTO РѕС‚Р»РѕР¶РµРЅ: РєРѕРЅС‚СЂРѕР»СЊРЅС‹Р№ С…РѕСЃС‚ $P_HOST ($group) РЅРµ СЂР°Р·СЂРµС€С‘РЅ РЅР° $iface"
        rm -f "$PROBE_SPEC_FILE" 2>/dev/null
        return 1
      fi
      printf '%s|%s|%s|%s|%s|%s\n' "$group" "$P_HOST" "$P_CODE" "$P_PATH" "$ip" "$ip6" >> "$PROBE_SPEC_FILE"
      [ -n "$ip" ] && n4=$((n4 + 1))
      [ -n "$ip6" ] && n6=$((n6 + 1))
    done
  done
  [ "$total" -gt 0 ] || { rm -f "$PROBE_SPEC_FILE" 2>/dev/null; return 1; }
  PROBE_IPV4=0; [ "$n4" = "$total" ] && PROBE_IPV4=1
  PROBE_IPV6=0; [ "$n6" = "$total" ] && PROBE_IPV6=1
  log "AUTO probe hosts: total=$total ipv4=$PROBE_IPV4 ipv6=$PROBE_IPV6"
  [ "$PROBE_IPV4" = 1 ] || [ "$PROBE_IPV6" = 1 ]
}

probe_url() {
  local family="$1" iface="$2" host="$3" ip="$4" url="$5" expected="$6" code resolved
  [ "$family" = 6 ] && resolved="[$ip]" || resolved="$ip"
  code=$(curl "-$family" --http1.1 -sS -o /dev/null --interface "$iface" \
    --resolve "$host:443:$resolved" \
    --connect-timeout 3 --max-time "$AUTO_TEST_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null)
  [ "$code" = "$expected" ]
}

# РџСЂРѕРіРѕРЅ РІСЃРµС… РєРѕРЅС‚СЂРѕР»СЊРЅС‹С… С…РѕСЃС‚РѕРІ. Р РµР·СѓР»СЊС‚Р°С‚ вЂ” С„Р°Р№Р» "host|0|1" РїР»СЋСЃ СЃС‡С‘С‚С‡РёРєРё.
# Р Р°РЅСЊС€Рµ СЃСѓС‚СЊ Р±С‹Р»Р° "РІСЃРµ С…РѕСЃС‚С‹ РѕР±СЏР·Р°РЅС‹ РїСЂРѕР№С‚Рё", РёР·-Р·Р° С‡РµРіРѕ РѕРґРёРЅ С…РѕСЃС‚, РєРѕС‚РѕСЂС‹Р№
# РЅРµ С‡РёРЅРёС‚СЃСЏ РѕР±С…РѕРґРѕРј РІ РїСЂРёРЅС†РёРїРµ (Discord РІ Р Р¤ Р±Р»РѕРєРёСЂСѓРµС‚СЃСЏ РїРѕ IP), РѕР±РЅСѓР»СЏР»
# СЂРµР·СѓР»СЊС‚Р°С‚ РґР»СЏ РІСЃРµС… РєР°РЅРґРёРґР°С‚РѕРІ СЃСЂР°Р·Сѓ.
probe_run_all() {
  local iface="$1" outfile="$2" group host code path ip4 ip6 ok
  PROBE_PASS=0; PROBE_FAIL=0; PROBE_FAILED_ON=""
  [ -s "$PROBE_SPEC_FILE" ] || return 1
  : > "$outfile" || return 1
  while IFS='|' read -r group host code path ip4 ip6; do
    [ -n "$host" ] || continue
    ok=0
    if [ "$PROBE_IPV4" = 1 ] && [ -n "$ip4" ] && probe_url 4 "$iface" "$host" "$ip4" "https://$host/$path" "$code"; then
      ok=1
    elif [ "$PROBE_IPV6" = 1 ] && [ -n "$ip6" ] && probe_url 6 "$iface" "$host" "$ip6" "https://$host/$path" "$code"; then
      ok=1
    fi
    printf '%s|%s\n' "$host" "$ok" >> "$outfile"
    if [ "$ok" = 1 ]; then
      PROBE_PASS=$((PROBE_PASS + 1))
    else
      PROBE_FAIL=$((PROBE_FAIL + 1))
      PROBE_FAILED_ON="${PROBE_FAILED_ON}${PROBE_FAILED_ON:+,}$group/$host"
    fi
  done < "$PROBE_SPEC_FILE"
  return 0
}

# РћС†РµРЅРєР° РєР°РЅРґРёРґР°С‚Р° РѕС‚РЅРѕСЃРёС‚РµР»СЊРЅРѕ Р±Р°Р·РѕРІРѕР№ Р»РёРЅРёРё (Р·Р°РјРµСЂ РІРѕРѕР±С‰Рµ Р±РµР· РѕР±С…РѕРґР°):
# FIXED  вЂ” С…РѕСЃС‚ РЅРµ РѕС‚РєСЂС‹РІР°Р»СЃСЏ Р±РµР· РѕР±С…РѕРґР°, РЅРѕ РѕС‚РєСЂС‹Р»СЃСЏ СЃ СЌС‚РѕР№ СЃС‚СЂР°С‚РµРіРёРµР№;
# BROKEN вЂ” С…РѕСЃС‚ РѕС‚РєСЂС‹РІР°Р»СЃСЏ Р±РµР· РѕР±С…РѕРґР°, Р° СЃС‚СЂР°С‚РµРіРёСЏ РµРіРѕ СЃР»РѕРјР°Р»Р°.
score_against_baseline() {
  awk -F'|' '
    NR==FNR { base[$1]=$2; next }
    {
      if (base[$1] == "0" && $2 == "1") fixed++
      if (base[$1] == "1" && $2 == "0") broken++
    }
    END { print fixed+0, broken+0 }
  ' "$BASELINE_FILE" "$1" 2>/dev/null
}

# nfqws2 РїРёС€РµС‚ РѕС€РёР±РєРё lua РІ СЌС‚РѕС‚ Р¶Рµ Р»РѕРі. Р•СЃР»Рё РєР°РЅРґРёРґР°С‚ СЃ РЅРµРїРѕРґРґРµСЂР¶РёРІР°РµРјС‹Рј
# РјР°СЂРєРµСЂРѕРј/Р°СЂРіСѓРјРµРЅС‚РѕРј РІР°Р»РёС‚ desync ("bad marker list"), РѕРЅ РЅРµ РґРѕР»Р¶РµРЅ РїРѕР±РµР¶РґР°С‚СЊ
# С‚РѕР»СЊРєРѕ РїРѕС‚РѕРјСѓ, С‡С‚Рѕ РїР°РєРµС‚С‹ РїСЂРѕС€Р»Рё РЅРµРјРѕРґРёС„РёС†РёСЂРѕРІР°РЅРЅС‹РјРё.
log_size() {
  local size
  size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) echo 0 ;; *) echo "$size" ;; esac
}
candidate_had_lua_error() {
  local from="$1" size
  size=$(log_size)
  [ "$size" -gt "$from" ] 2>/dev/null || return 1
  tail -c $((size - from)) "$LOG_FILE" 2>/dev/null | grep -qE 'LUA ERROR|desync ERROR'
}

save_cache() {
  local key="$1" profile="$2" iface="$3" status="${4:-SELECTED}" now tmp cache
  now=$(now_epoch); cache=$(cache_file_for "$key"); tmp="$cache.tmp.$$"
  {
    echo "PROFILE=$profile"
    echo "UPDATED=$now"
    echo "IFACE=$iface"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
  chmod 0600 "$cache" 2>/dev/null || true
  write_result "$profile" "$key" "$iface" "$status" "$now"
}

run_probe() {
  local force="$1" snapshot iface identity key cache previous previous_updated now age profile selected="" service_pid ttl packets catalog number path \
    direct_profile baseline_fail best best_fixed tried fixed broken log_before
  trap 'cleanup_test; rm -rf "$LOCK_DIR" 2>/dev/null; rm -f "$PROBE_PID_FILE" "$PROBE_SPEC_FILE" "$BASELINE_FILE" "$CANDIDATE_FILE" 2>/dev/null; exit 1' HUP INT TERM
  trap 'cleanup_test; rm -rf "$LOCK_DIR" 2>/dev/null; rm -f "$PROBE_PID_FILE" "$PROBE_SPEC_FILE" "$BASELINE_FILE" "$CANDIDATE_FILE" 2>/dev/null' EXIT
  [ "$AUTO_SELECT_ENABLED" = 1 ] || { resolve_current >/dev/null; return 0; }
  [ "$AUTO_TEST_QNUM" = "${QNUM:-200}" ] && AUTO_TEST_QNUM=$((AUTO_TEST_QNUM + 1))
  # РЈР±РёСЂР°РµРј С‚РѕР»СЊРєРѕ СЃРѕР±СЃС‚РІРµРЅРЅСѓСЋ С‚РµСЃС‚РѕРІСѓСЋ РѕС‡РµСЂРµРґСЊ Рё РїСЂРѕС†РµСЃСЃ РѕС‚ РїСЂРµСЂРІР°РЅРЅРѕРіРѕ probe.
  cleanup_test
  service_pid=$(cat "$RUN_DIR/service.lock/pid" 2>/dev/null)
  case "$service_pid" in
    ''|0|*[!0-9]*) ;;
    *) if kill -0 "$service_pid" 2>/dev/null; then log "AUTO РѕС‚Р»РѕР¶РµРЅ: service.sh Р·Р°РЅСЏС‚ (PID $service_pid)"; resolve_current >/dev/null; return 0; fi ;;
  esac
  command -v curl >/dev/null 2>&1 || { log "AUTO РїСЂРѕРїСѓС‰РµРЅ: curl РЅРµРґРѕСЃС‚СѓРїРµРЅ"; resolve_current >/dev/null; return 1; }
  [ -x "$BIN_DIR/nfqws2" ] || { log "AUTO РїСЂРѕРїСѓС‰РµРЅ: nfqws2 РЅРµРґРѕСЃС‚СѓРїРµРЅ"; resolve_current >/dev/null; return 1; }
  snapshot=$(active_network_snapshot)
  iface=$(snapshot_field "$snapshot" 1)
  [ -n "$iface" ] || iface=$(default_iface)
  [ -n "$iface" ] || { log "AUTO РїСЂРѕРїСѓС‰РµРЅ: РЅРµС‚ IPv4 default route"; resolve_current >/dev/null; return 1; }
  case "$iface" in tun*|wg*|awg*|vpn*|warp*|tailscale*|zt*) log "AUTO РїСЂРѕРїСѓС‰РµРЅ: default route С‡РµСЂРµР· VPN $iface"; resolve_current >/dev/null; return 1 ;; esac
  catalog=$(strategy_catalog_signature)
  [ -n "$(strategy_first_valid)" ] || { log "AUTO РїСЂРѕРїСѓС‰РµРЅ: СЃРїРёСЃРѕРє СЃС‚СЂР°С‚РµРіРёР№ РїСѓСЃС‚ РёР»Рё РЅРµРІР°Р»РёРґРµРЅ"; return 1; }
  identity="$(network_identity "$iface" "$snapshot")|STRATEGIES=$catalog"; key=$(network_key "$identity") || return 1
  ttl=$(cache_ttl_for_iface "$iface")
  case "$ttl" in ''|*[!0-9]*) ttl=$AUTO_CACHE_TTL ;; esac
  cache=$(cache_file_for "$key"); previous=""; previous_updated=0
  if [ -f "$cache" ]; then . "$cache"; previous=${PROFILE:-}; previous_updated=${UPDATED:-0}; fi
  now=$(now_epoch); case "$previous_updated" in ''|*[!0-9]*) previous_updated=0 ;; esac
  age=$((now - previous_updated))
  if [ "$force" != force ] && valid_profile "$previous" && [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le "$ttl" ] 2>/dev/null; then
    write_result "$previous" "$key" "$iface" CACHED "$previous_updated"
    log "AUTO cache hit: key=$key iface=$iface profile=$previous age=$age"
    request_profile_reload "$previous" || true
    return 0
  fi

  if ! prepare_probe_dns "$iface" "$snapshot"; then
    log "AUTO РѕС‚Р»РѕР¶РµРЅ: РєРѕРЅС‚СЂРѕР»СЊРЅС‹Рµ РёРјРµРЅР° РЅРµ СЂР°Р·СЂРµС€РµРЅС‹ РґР»СЏ iface=$iface"
    resolve_current >/dev/null
    return 1
  fi

  log "AUTO probe start: key=$key iface=$iface previous=${previous:-none} catalog=$catalog"

  # РЁР°Рі 1. Р‘Р°Р·РѕРІР°СЏ Р»РёРЅРёСЏ: Р·Р°РјРµСЂ РІРѕРѕР±С‰Рµ Р±РµР· РѕР±С…РѕРґР°. РћРЅ Р¶Рµ РѕС‚РІРµС‡Р°РµС‚ РЅР° РІРѕРїСЂРѕСЃ
  # "РЅСѓР¶РµРЅ Р»Рё РѕР±С…РѕРґ СЌС‚РѕР№ СЃРµС‚Рё РІРѕРѕР±С‰Рµ" Рё РѕС‚РґРµР»СЏРµС‚ С…РѕСЃС‚С‹, РєРѕС‚РѕСЂС‹Рµ РЅРµ С‡РёРЅСЏС‚СЃСЏ
  # РЅРёРєР°РєРёРј desync (Р±Р»РѕРєРёСЂРѕРІРєР° РїРѕ IP), РѕС‚ С‚РµС…, С‡С‚Рѕ С‡РёРЅСЏС‚СЃСЏ.
  direct_profile=""
  strategy_list > "$RUN_DIR/auto-strategies.$$"
  while IFS='|' read -r number profile path; do
    strategy_read "$profile" || continue
    [ "$STRATEGY_FILE_MODE" = DIRECT ] && { direct_profile=$profile; break; }
  done < "$RUN_DIR/auto-strategies.$$"

  install_direct_rule
  probe_run_all "$iface" "$BASELINE_FILE" || { log "AUTO: РЅРµ СѓРґР°Р»РѕСЃСЊ СЃРЅСЏС‚СЊ Р±Р°Р·РѕРІСѓСЋ Р»РёРЅРёСЋ"; return 1; }
  baseline_fail=$PROBE_FAIL
  log "AUTO baseline (Р±РµР· РѕР±С…РѕРґР°): ok=$PROBE_PASS fail=$baseline_fail${PROBE_FAILED_ON:+ failed=$PROBE_FAILED_ON}"

  if [ "$baseline_fail" = 0 ]; then
    cleanup_test
    rm -f "$RUN_DIR/auto-strategies.$$" "$PROBE_SPEC_FILE" "$BASELINE_FILE" "$CANDIDATE_FILE" 2>/dev/null
    if [ -n "$direct_profile" ] && [ "$AUTO_ALLOW_DIRECT" = 1 ]; then
      log "AUTO: СЃРµС‚СЊ РЅРµ С„РёР»СЊС‚СЂСѓРµС‚СЃСЏ, РІС‹Р±СЂР°РЅ DIRECT ($direct_profile)"
      save_cache "$key" "$direct_profile" "$iface"
      request_profile_reload "$direct_profile" || true
      return 0
    fi
    selected=${previous:-$AUTO_PROFILE_DEFAULT}
    valid_profile "$selected" || selected=$(strategy_first_valid)
    [ -n "$selected" ] || return 1
    log "AUTO: СЃРµС‚СЊ РЅРµ С„РёР»СЊС‚СЂСѓРµС‚СЃСЏ, РЅРѕ DIRECT РЅРµРґРѕСЃС‚СѓРїРµРЅ; РѕСЃС‚Р°РІР»РµРЅ РїСЂРѕС„РёР»СЊ=$selected"
    save_cache "$key" "$selected" "$iface"
    request_profile_reload "$selected" || true
    return 0
  fi

  # РЁР°Рі 2. РљР°РЅРґРёРґР°С‚С‹ РѕС†РµРЅРёРІР°СЋС‚СЃСЏ РїРѕ С‡РёСЃР»Сѓ РїРѕС‡РёРЅРµРЅРЅС‹С… С…РѕСЃС‚РѕРІ. РљР°РЅРґРёРґР°С‚, РєРѕС‚РѕСЂС‹Р№
  # Р»РѕРјР°РµС‚ С‚Рѕ, С‡С‚Рѕ СЂР°Р±РѕС‚Р°Р»Рѕ Р±РµР· РѕР±С…РѕРґР°, РѕС‚Р±СЂР°СЃС‹РІР°РµС‚СЃСЏ РЅРµР·Р°РІРёСЃРёРјРѕ РѕС‚ СЃС‡С‘С‚Р°.
  best=""; best_fixed=0; tried=0
  while IFS='|' read -r number profile path; do
    if ! strategy_read "$profile"; then
      log "AUTO candidate=$profile result=INVALID_FILE"
      continue
    fi
    [ "$STRATEGY_FILE_MODE" = DIRECT ] && continue
    case "$AUTO_PROBE_MAX_CANDIDATES" in
      ''|0|*[!0-9]*) ;;
      *) [ "$tried" -ge "$AUTO_PROBE_MAX_CANDIDATES" ] 2>/dev/null && break ;;
    esac
    tried=$((tried + 1))
    log "AUTO candidate=$profile name=$STRATEGY_FILE_NAME position=$number start"
    log_before=$(log_size)
    install_candidate_rule "$profile" || continue
    probe_run_all "$iface" "$CANDIDATE_FILE" || continue
    packets=$(test_queue_packets)
    case "$packets" in ''|*[!0-9]*) packets=0 ;; esac
    if ! pid_is_test_nfqws "$TEST_PID" || [ "$packets" -le 0 ] 2>/dev/null; then
      log "AUTO candidate=$profile result=INVALID queue_packets=$packets"
      continue
    fi
    if candidate_had_lua_error "$log_before"; then
      log "AUTO candidate=$profile result=INVALID_ARGS (nfqws2 РѕС‚РІРµСЂРі desync-Р°СЂРіСѓРјРµРЅС‚С‹)"
      continue
    fi
    set -- $(score_against_baseline "$CANDIDATE_FILE")
    fixed=${1:-0}; broken=${2:-0}
    if [ "$broken" -gt 0 ] 2>/dev/null; then
      log "AUTO candidate=$profile name=$STRATEGY_FILE_NAME result=REGRESSION fixed=$fixed broken=$broken"
      continue
    fi
    log "AUTO candidate=$profile name=$STRATEGY_FILE_NAME result=SCORE fixed=$fixed/$baseline_fail"
    if [ "$fixed" -gt "$best_fixed" ] 2>/dev/null; then best=$profile; best_fixed=$fixed; fi
    [ "$best_fixed" -ge "$baseline_fail" ] 2>/dev/null && break
  done < "$RUN_DIR/auto-strategies.$$"
  rm -f "$RUN_DIR/auto-strategies.$$" "$PROBE_SPEC_FILE" "$BASELINE_FILE" "$CANDIDATE_FILE" 2>/dev/null
  cleanup_test

  if [ -z "$best" ]; then
    selected=${previous:-$AUTO_PROFILE_DEFAULT}
    valid_profile "$selected" || selected=$(strategy_first_valid)
    [ -n "$selected" ] || { log "AUTO: РЅРµС‚ РІР°Р»РёРґРЅС‹С… С„Р°Р№Р»РѕРІ СЃС‚СЂР°С‚РµРіРёР№"; return 1; }
    log "AUTO: РЅРё РѕРґРёРЅ РєР°РЅРґРёРґР°С‚ РЅРёС‡РµРіРѕ РЅРµ РїРѕС‡РёРЅРёР», СЃРѕС…СЂР°РЅС‘РЅ РїСЂРѕС„РёР»СЊ=$selected"
    write_result "$selected" "$key" "$iface" FAILED "$previous_updated"
    request_profile_reload "$selected" || true
    return 1
  fi
  if [ "$best_fixed" -ge "$baseline_fail" ] 2>/dev/null; then
    save_cache "$key" "$best" "$iface" SELECTED
    log "AUTO selected: key=$key iface=$iface profile=$best name=$(profile_name "$best") fixed=$best_fixed/$baseline_fail (РїРѕР»РЅРѕСЃС‚СЊСЋ)"
  else
    save_cache "$key" "$best" "$iface" PARTIAL
    log "AUTO selected: key=$key iface=$iface profile=$best name=$(profile_name "$best") fixed=$best_fixed/$baseline_fail (С‡Р°СЃС‚РёС‡РЅРѕ; РѕСЃС‚Р°Р»СЊРЅС‹Рµ С…РѕСЃС‚С‹ РЅРµ С‡РёРЅСЏС‚СЃСЏ РѕР±С…РѕРґРѕРј)"
  fi
  request_profile_reload "$best" || true
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; return 0; fi
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) rm -rf "$LOCK_DIR" 2>/dev/null ;; *) kill -0 "$pid" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null ;; esac
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo $$ > "$LOCK_DIR/pid"
}

schedule_probe() {
  [ "$AUTO_SELECT_ENABLED" = 1 ] || return 0
  pid=$(cat "$PROBE_PID_FILE" 2>/dev/null)
  # РџСЂРѕРІРµСЂСЏРµРј РЅРµ С‚РѕР»СЊРєРѕ "Р¶РёРІ Р»Рё PID", РЅРѕ Рё С‡С‚Рѕ СЌС‚Рѕ РґРµР№СЃС‚РІРёС‚РµР»СЊРЅРѕ РЅР°С€ probe:
  # РїРµСЂРµРёСЃРїРѕР»СЊР·РѕРІР°РЅРЅС‹Р№ СЏРґСЂРѕРј PID РёРЅР°С‡Рµ РЅР°РІСЃРµРіРґР° Р·Р°Р±Р»РѕРєРёСЂРѕРІР°Р» Р±С‹ РїР»Р°РЅРёСЂРѕРІР°РЅРёРµ.
  case "$pid" in
    ''|0|*[!0-9]*) ;;
    *) if kill -0 "$pid" 2>/dev/null && tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq "$MODDIR/auto-select.sh"; then return 0; fi ;;
  esac
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/auto-select.sh" scheduled </dev/null >/dev/null 2>&1 &
  elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
    busybox setsid sh "$MODDIR/auto-select.sh" scheduled </dev/null >/dev/null 2>&1 &
  else
    sh "$MODDIR/auto-select.sh" scheduled </dev/null >/dev/null 2>&1 &
  fi
  echo $! > "$PROBE_PID_FILE"
}

clear_state() {
  local pid n
  pid=$(cat "$PROBE_PID_FILE" 2>/dev/null)
  case "$pid" in
    ''|0|*[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null && tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq "$MODDIR/auto-select.sh"; then
        kill -TERM "$pid" 2>/dev/null
        n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
      fi
      ;;
  esac
  acquire_lock || return 1
  trap 'cleanup_test; rm -rf "$LOCK_DIR" 2>/dev/null; rm -f "$PROBE_PID_FILE" 2>/dev/null' EXIT
  cleanup_test
  rm -f "$STATE_DIR"/auto-*.env "$RESULT_FILE" 2>/dev/null
}

case "$1" in
  current|'') resolve_current ;;
  schedule) schedule_probe ;;
  run) acquire_lock || exit 0; echo $$ > "$PROBE_PID_FILE"; run_probe normal ;;
  scheduled) sleep 4; acquire_lock || exit 0; echo $$ > "$PROBE_PID_FILE"; run_probe normal ;;
  force) acquire_lock || exit 1; echo $$ > "$PROBE_PID_FILE"; run_probe force ;;
  status) resolve_current >/dev/null; cat "$RESULT_FILE" 2>/dev/null ;;
  clear) clear_state ;;
  *) exit 2 ;;
esac
