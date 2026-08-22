#!/system/bin/sh

umask 077
MODDIR=${0%/*}
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
LOCK_DIR="$RUN_DIR/vpn-routing.lock"
STATE_FILE="$RUN_DIR/vpn-routing.state"
META_FILE="$RUN_DIR/vpn-routing.meta"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
STATE_BUILD=""

mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null
chmod 0700 "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${ENABLE_HOTSPOT:=1}" "${ENABLE_VPN_HOTSPOT:=0}" "${VPN_TUN_NAME:=AUTO}"
: "${VPN_ROUTE_PREF_BASE:=20550}" "${VPN_ROUTE_TABLE:=11999}"
: "${VPN_HOTSPOT_MASQUERADE:=1}" "${VPN_FALLBACK_MODE:=ANTIDPI}" "${VPN_HOTSPOT_KILLSWITCH:=0}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] VPN Hotspot: $*" >> "$LOG_FILE"; }
IP_BIN=$(command -v ip 2>/dev/null); [ -n "$IP_BIN" ] || IP_BIN=/system/bin/ip
IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables
valid_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
ipv6_forwarding_active() {
  [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = "1" ] || return 1
  return 0
}

normalize_fallback_mode() {
  case "${VPN_FALLBACK_MODE:-}" in
    ANTIDPI|antidpi) VPN_FALLBACK_MODE=ANTIDPI ;;
    BLOCK|block) VPN_FALLBACK_MODE=BLOCK ;;
    *) [ "${VPN_HOTSPOT_KILLSWITCH:-0}" = "1" ] && VPN_FALLBACK_MODE=BLOCK || VPN_FALLBACK_MODE=ANTIDPI ;;
  esac
}
fallback_is_block() { [ "$VPN_FALLBACK_MODE" = "BLOCK" ]; }
normalize_fallback_mode
valid_number "$VPN_ROUTE_PREF_BASE" || VPN_ROUTE_PREF_BASE=20550
valid_number "$VPN_ROUTE_TABLE" || VPN_ROUTE_TABLE=11999

detect_vpn_iface() { "$MODDIR/net-role.sh" vpn 2>/dev/null | head -n1; }
detect_downstreams() { "$MODDIR/net-role.sh" downstreams 2>/dev/null; }
vpn_candidate_exists() { "$MODDIR/net-role.sh" vpn-candidate >/dev/null 2>&1; }
downstream_candidate_exists() { "$MODDIR/net-role.sh" downstream-candidate >/dev/null 2>&1; }

subnet_for_iface() {
  local iface="$1" subnet
  subnet=$("$IP_BIN" -4 route show dev "$iface" scope link 2>/dev/null | awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1; exit}')
  [ -n "$subnet" ] || subnet=$("$IP_BIN" -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')
  [ -n "$subnet" ] && echo "$subnet"
}

cleanup_old_unsafe_rules() {
  "$IP_BIN" rule del pref 11300 from 10.0.0.0/8 2>/dev/null || true
  "$IP_BIN" rule del pref 11301 from 172.16.0.0/12 2>/dev/null || true
  "$IP_BIN" rule del pref 11302 from 192.168.0.0/16 2>/dev/null || true
}

cleanup_rule_file() {
  local file="$1" pref selector value table
  [ -f "$file" ] || return 0
  while IFS='|' read -r pref selector value table; do
    valid_number "$pref" || continue
    if [ -z "$table" ] && [ -n "$selector" ] && [ -n "$value" ]; then
      "$IP_BIN" rule del pref "$pref" iif "$selector" lookup "$value" 2>/dev/null || true
      continue
    fi
    [ -n "$selector" ] && [ -n "$value" ] && [ -n "$table" ] || continue
    case "$selector" in
      iif) "$IP_BIN" rule del pref "$pref" iif "$value" lookup "$table" 2>/dev/null || true ;;
      iif6) "$IP_BIN" -6 rule del pref "$pref" iif "$value" lookup "$table" 2>/dev/null || true ;;
      from) "$IP_BIN" rule del pref "$pref" from "$value" lookup "$table" 2>/dev/null || true ;;
    esac
  done < "$file"
}

cleanup_state_rules() {
  cleanup_rule_file "$STATE_FILE"
  [ -n "$STATE_BUILD" ] && cleanup_rule_file "$STATE_BUILD"
  rm -f "$STATE_FILE" "$STATE_BUILD" 2>/dev/null
}
cleanup_private_tables() {
  valid_number "$VPN_ROUTE_TABLE" || return 0
  "$IP_BIN" -4 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
  "$IP_BIN" -6 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
}
cleanup_iptables() {
  [ -x "$IPT" ] && {
    delete_jump_bounded "$IPT" nat POSTROUTING ZAPRET2_VPN_NAT
    "$IPT" -w 1 -t nat -F ZAPRET2_VPN_NAT >/dev/null 2>&1 || true
    "$IPT" -w 1 -t nat -X ZAPRET2_VPN_NAT >/dev/null 2>&1 || true
    delete_jump_bounded "$IPT" filter FORWARD ZAPRET2_VPN_FORWARD
    "$IPT" -w 1 -t filter -F ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    "$IPT" -w 1 -t filter -X ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
  }
  [ -x "$IP6T" ] && {
    delete_jump_bounded "$IP6T" filter FORWARD ZAPRET2_VPN_FORWARD
    "$IP6T" -w 1 -t filter -F ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    "$IP6T" -w 1 -t filter -X ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
  }
}

delete_jump_bounded() {
  local command="$1" table="$2" chain="$3" target="$4" attempt=0
  while [ "$attempt" -lt 8 ]; do
    "$command" -w 1 -t "$table" -D "$chain" -j "$target" >/dev/null 2>&1 || return 0
    attempt=$((attempt + 1))
  done
  log "Очистка $table/$chain->$target ограничена восемью повторами"
  return 0
}
cleanup_rules() {
  cleanup_state_rules
  cleanup_private_tables
  cleanup_old_unsafe_rules
  cleanup_iptables
  rm -f "$META_FILE" 2>/dev/null
}

next_free_pref() {
  local pref="$1" max=20900
  [ "$VPN_ROUTE_PREF_BASE" -le "$max" ] 2>/dev/null || max=$VPN_ROUTE_PREF_BASE
  while [ "$pref" -le "$max" ]; do
    if ! "$IP_BIN" rule show 2>/dev/null | grep -q "^$pref:" && ! "$IP_BIN" -6 rule show 2>/dev/null | grep -q "^$pref:"; then
      echo "$pref"; return 0
    fi
    pref=$((pref + 1))
  done
  return 1
}

setup_private_route_table() {
  local vpn_if="$1" has4=0 has6=0
  valid_number "$VPN_ROUTE_TABLE" || { log "Некорректный VPN_ROUTE_TABLE=$VPN_ROUTE_TABLE"; return 1; }
  "$IP_BIN" -o -4 addr show dev "$vpn_if" 2>/dev/null | grep -q ' inet ' && has4=1
  "$IP_BIN" -o -6 addr show dev "$vpn_if" 2>/dev/null | grep -q ' inet6 ' && has6=1
  "$IP_BIN" -4 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
  "$IP_BIN" -6 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
  [ "$has4" = 1 ] || { log "VPN=$vpn_if не имеет IPv4-адреса; раздача IPv4 VPN недоступна"; return 1; }
  "$IP_BIN" -4 route replace default dev "$vpn_if" table "$VPN_ROUTE_TABLE" 2>/dev/null || { log "Не удалось установить IPv4 default dev $vpn_if table $VPN_ROUTE_TABLE"; return 1; }
  if [ "$has6" = 1 ]; then
    "$IP_BIN" -6 route replace default dev "$vpn_if" table "$VPN_ROUTE_TABLE" 2>/dev/null || { log "IPv6 default route для VPN не установлен"; return 1; }
  fi
  return 0
}

record_rule() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$STATE_BUILD"; }
add_policy_rule() {
  local pref="$1" down="$2" subnet
  if "$IP_BIN" rule add pref "$pref" iif "$down" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then
    record_rule "$pref" iif "$down" "$VPN_ROUTE_TABLE"
    if "$IP_BIN" -6 rule add pref "$pref" iif "$down" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then record_rule "$pref" iif6 "$down" "$VPN_ROUTE_TABLE"; fi
    log "policy rule: pref=$pref iif=$down lookup=$VPN_ROUTE_TABLE"
    return 0
  fi
  subnet=$(subnet_for_iface "$down"); [ -n "$subnet" ] || return 1
  if "$IP_BIN" rule add pref "$pref" from "$subnet" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then
    record_rule "$pref" from "$subnet" "$VPN_ROUTE_TABLE"
    if "$IP_BIN" -6 rule add pref "$pref" iif "$down" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then record_rule "$pref" iif6 "$down" "$VPN_ROUTE_TABLE"; fi
    log "policy fallback: pref=$pref from=$subnet lookup=$VPN_ROUTE_TABLE"
    return 0
  fi
  return 1
}

setup_guard_only() {
  local downs="$1" down
  fallback_is_block || return 0
  [ -x "$IPT" ] || return 1
  "$IPT" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
  "$IPT" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
  for down in $downs; do "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || return 1; done
  if ipv6_forwarding_active; then
    [ -x "$IP6T" ] || { log "IPv6 forwarding активен, но ip6tables отсутствует: fail-closed setup невозможен"; return 1; }
    "$IP6T" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
    "$IP6T" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
    for down in $downs; do "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || return 1; done
  fi
  log "fallback=BLOCK: VPN разворован, раздача заблокирована"
}

setup_vpn_nat_forward_guard() {
  local vpn_if="$1" downs="$2" down subnet
  [ -x "$IPT" ] || { log "iptables отсутствует: VPN sharing невозможен"; return 1; }
  "$IPT" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
  "$IPT" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
  if [ "$VPN_HOTSPOT_MASQUERADE" = "1" ]; then
    "$IPT" -w 5 -t nat -N ZAPRET2_VPN_NAT >/dev/null 2>&1 || return 1
    "$IPT" -w 5 -t nat -I POSTROUTING 1 -j ZAPRET2_VPN_NAT >/dev/null 2>&1 || return 1
  fi
  for down in $downs; do
    "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -o "$vpn_if" -j ACCEPT >/dev/null 2>&1 || return 1
    if "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$vpn_if" -o "$down" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; then :; else
      "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$vpn_if" -o "$down" -m state --state ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || return 1
    fi
    "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" ! -o "$vpn_if" -j REJECT >/dev/null 2>&1 || return 1
    if [ "$VPN_HOTSPOT_MASQUERADE" = "1" ]; then
      subnet=$(subnet_for_iface "$down"); [ -n "$subnet" ] || { log "Не удалось определить подсеть downstream=$down для MASQUERADE"; return 1; }
      "$IPT" -w 5 -t nat -A ZAPRET2_VPN_NAT -s "$subnet" -o "$vpn_if" -j MASQUERADE >/dev/null 2>&1 || return 1
      log "MASQUERADE: downstream=$down subnet=$subnet -> $vpn_if"
    fi
  done
  if ipv6_forwarding_active; then
    [ -x "$IP6T" ] || { log "IPv6 forwarding активен, но ip6tables отсутствует"; return 1; }
    "$IP6T" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
    "$IP6T" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
    if "$IP_BIN" -6 route show table "$VPN_ROUTE_TABLE" default 2>/dev/null | grep -q "default.*dev $vpn_if"; then
      for down in $downs; do
        "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -o "$vpn_if" -j ACCEPT >/dev/null 2>&1 || return 1
        "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$vpn_if" -o "$down" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || return 1
        "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" ! -o "$vpn_if" -j REJECT >/dev/null 2>&1 || return 1
      done
    else
      for down in $downs; do
        "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || return 1
      done
      log "VPN не имеет подтверждённого IPv6 default route: IPv6 tether заблокирован fail-closed"
    fi
  fi
}

atomic_meta_write() { local tmp="$META_FILE.tmp.$$"; printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$META_FILE"; chmod 0600 "$META_FILE" 2>/dev/null || true; }

desired_signature() {
  local downs vpn_if subnets="" down
  if [ "$ENABLE_HOTSPOT" != "1" ] || [ "$ENABLE_VPN_HOTSPOT" != "1" ]; then echo "disabled"; return; fi
  downs=$(detect_downstreams | awk 'NF&&!seen[$0]++' | sort | tr '\n' ',' | sed 's/,$//')
  vpn_if=$(detect_vpn_iface)
  for down in $(echo "$downs" | tr ',' ' '); do subnets="$subnets,$down=$(subnet_for_iface "$down")"; done
  printf 'down=%s|vpn=%s|fallback=%s|masq=%s|table=%s|subnets=%s' "$downs" "$vpn_if" "$VPN_FALLBACK_MODE" "$VPN_HOTSPOT_MASQUERADE" "$VPN_ROUTE_TABLE" "$subnets"
}

verify_current_rules() {
  local sig="$1" line pref selector value table downs down vpn_if subnet
  [ "$(cat "$META_FILE" 2>/dev/null)" = "$sig" ] || return 1
  [ "$sig" != disabled ] || return 0
  case "$sig" in down='|'*) return 0 ;; esac
  case "$sig" in *'|vpn=|'*)
    if fallback_is_block; then
      "$IPT" -w 5 -t filter -C FORWARD -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
      downs=$(printf '%s' "$sig" | sed -n 's/^down=\([^|]*\).*/\1/p' | tr ',' ' ')
      for down in $downs; do "$IPT" -w 5 -t filter -C ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || return 1; done
      if ipv6_forwarding_active; then
        [ -x "$IP6T" ] || return 1
        "$IP6T" -w 5 -t filter -C FORWARD -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
        for down in $downs; do "$IP6T" -w 5 -t filter -C ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || return 1; done
      fi
    fi
    return 0 ;;
  esac
  "$IPT" -w 5 -t filter -C FORWARD -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
  [ "$VPN_HOTSPOT_MASQUERADE" != "1" ] || "$IPT" -w 5 -t nat -C POSTROUTING -j ZAPRET2_VPN_NAT >/dev/null 2>&1 || return 1
  downs=$(printf '%s' "$sig" | sed -n 's/^down=\([^|]*\).*/\1/p' | tr ',' ' ')
  vpn_if=$(printf '%s' "$sig" | sed -n 's/^.*|vpn=\([^|]*\).*/\1/p')
  [ -n "$vpn_if" ] || return 1
  "$IP_BIN" -4 route show table "$VPN_ROUTE_TABLE" default 2>/dev/null | grep -q "default.*dev $vpn_if" || return 1
  for down in $downs; do
    "$IPT" -w 5 -t filter -C ZAPRET2_VPN_FORWARD -i "$down" -o "$vpn_if" -j ACCEPT >/dev/null 2>&1 || return 1
    "$IPT" -w 5 -t filter -C ZAPRET2_VPN_FORWARD -i "$down" ! -o "$vpn_if" -j REJECT >/dev/null 2>&1 || return 1
    if [ "$VPN_HOTSPOT_MASQUERADE" = "1" ]; then
      subnet=$(subnet_for_iface "$down"); [ -n "$subnet" ] || return 1
      "$IPT" -w 5 -t nat -C ZAPRET2_VPN_NAT -s "$subnet" -o "$vpn_if" -j MASQUERADE >/dev/null 2>&1 || return 1
    fi
    if ipv6_forwarding_active; then
      [ -x "$IP6T" ] || return 1
      "$IP6T" -w 5 -t filter -S ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
      # Either routed through VPN or explicitly rejected; both are fail-closed.
      "$IP6T" -w 5 -t filter -C ZAPRET2_VPN_FORWARD -i "$down" ! -o "$vpn_if" -j REJECT >/dev/null 2>&1 ||       "$IP6T" -w 5 -t filter -C ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || return 1
    fi
  done
  [ -f "$STATE_FILE" ] || return 1
  while IFS='|' read -r pref selector value table; do
    valid_number "$pref" || continue
    case "$selector" in
      iif) "$IP_BIN" rule show 2>/dev/null | grep -E "^${pref}:.*iif ${value}.*lookup ${table}([[:space:]]|$)" >/dev/null || return 1 ;;
      iif6) "$IP_BIN" -6 rule show 2>/dev/null | grep -E "^${pref}:.*iif ${value}.*lookup ${table}([[:space:]]|$)" >/dev/null || return 1 ;;
      from) "$IP_BIN" rule show 2>/dev/null | grep -E "^${pref}:.*from ${value}.*lookup ${table}([[:space:]]|$)" >/dev/null || return 1 ;;
    esac
  done < "$STATE_FILE"
  return 0
}

# Пустой pid не означает брошенную блокировку: владелец мог сделать mkdir и
# ещё не записать себя. Сносим только если пусто две итерации подряд.
acquire_lock() {
  mkdir -p "$RUN_DIR" || return 1; chmod 0700 "$RUN_DIR" 2>/dev/null || true
  local n=0 lock_pid empty_seen=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if ! valid_number "$lock_pid"; then
      empty_seen=$((empty_seen + 1))
      [ "$empty_seen" -ge 2 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; empty_seen=0; }
    else
      empty_seen=0
      kill -0 "$lock_pid" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null
    fi
    n=$((n + 1)); [ "$n" -lt 6 ] || return 1; sleep 1
  done
  echo $$ > "$LOCK_DIR/pid"
}
release_lock() { [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null; }

apply_rules() {
  local vpn_if downs pref down sig
  [ "$ENABLE_HOTSPOT" = "1" ] && [ "$ENABLE_VPN_HOTSPOT" = "1" ] || { cleanup_rules; atomic_meta_write disabled; return 0; }
  [ -x "$IP_BIN" ] || { log "Утилита ip не найдена"; return 1; }

  sig=$(desired_signature)
  verify_current_rules "$sig" && return 0
  cleanup_rules
  downs=$(detect_downstreams)
  if [ -z "$downs" ]; then
    if downstream_candidate_exists; then log "downstream присутствует, но интерфейс не готов; повтор"; return 3; fi
    log "VPN sharing активен, но активных tether downstream сетей не найдено"
    atomic_meta_write "$sig"
    return 0
  fi

  vpn_if=$(detect_vpn_iface)
  if [ -z "$vpn_if" ]; then
    if fallback_is_block; then setup_guard_only "$downs" || return 1; log "VPN отсутствует: fallback=BLOCK"; else log "VPN отсутствует: fallback=ANTIDPI, возврат на обычный upstream + Zapret2"; fi
    if vpn_candidate_exists; then log "VPN-клиент подключается, ожидаем завершения настройки"; return 3; fi
    atomic_meta_write "$sig"
    return 0
  fi

  setup_private_route_table "$vpn_if" || { cleanup_rules; fallback_is_block && setup_guard_only "$downs"; return 1; }
  STATE_BUILD="$STATE_FILE.tmp.$$"; : > "$STATE_BUILD"
  pref="$VPN_ROUTE_PREF_BASE"
  for down in $downs; do
    pref=$(next_free_pref "$pref") || { log "Не удалось получить policy priority"; cleanup_rules; fallback_is_block && setup_guard_only "$downs"; return 1; }
    add_policy_rule "$pref" "$down" || { log "Не удалось добавить policy rule для $down"; cleanup_rules; fallback_is_block && setup_guard_only "$downs"; return 1; }
    pref=$((pref + 1))
  done
  setup_vpn_nat_forward_guard "$vpn_if" "$downs" || { log "Не удалось настроить VPN NAT/FORWARD/guard"; cleanup_rules; fallback_is_block && setup_guard_only "$downs"; return 1; }
  mv -f "$STATE_BUILD" "$STATE_FILE" || { cleanup_rules; return 1; }; STATE_BUILD=""; chmod 0600 "$STATE_FILE" 2>/dev/null || true
  sig=$(desired_signature); atomic_meta_write "$sig"
  log "VPN sharing ACTIVE: downstream=$(echo $downs | tr '\n' ',') -> $vpn_if private_table=$VPN_ROUTE_TABLE fallback=$VPN_FALLBACK_MODE leak_guard=ACTIVE"
  return 0
}

signature() { "$MODDIR/net-role.sh" signature 2>/dev/null; }
acquire_lock || exit 3
trap 'release_lock' EXIT HUP INT TERM
case "$1" in
  apply|reload|'') apply_rules ;;
  verify) verify_current_rules "$(desired_signature)" ;;
  cleanup) cleanup_rules ;;
  signature) signature ;;
  *) exit 2 ;;
esac
