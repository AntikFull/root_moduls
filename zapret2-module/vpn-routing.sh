#!/system/bin/sh
# Standalone VPN sharing for Hotspot/USB.
# v2.6.12: stable v2.6.10 routing + strict role detection.
# VPN and tether roles are resolved from Android state/strict tunnel hints;
# rmnet/wlan underlay is never accepted as VPN. Transitional states return rc=3
# so the watcher retries until Android/netd finishes configuring the network.

MODDIR=${0%/*}
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
LOCK_DIR="$RUN_DIR/vpn-routing.lock"
STATE_FILE="$RUN_DIR/vpn-routing.state"
LOG_FILE="/sdcard/eCubz/zapret2_debug.log"

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${ENABLE_HOTSPOT:=1}" "${ENABLE_VPN_HOTSPOT:=0}" "${VPN_TUN_NAME:=AUTO}"
: "${VPN_ROUTE_PREF_BASE:=20550}" "${VPN_ROUTE_TABLE:=11999}"
: "${VPN_HOTSPOT_MASQUERADE:=1}" "${VPN_FALLBACK_MODE:=ANTIDPI}" "${VPN_HOTSPOT_KILLSWITCH:=0}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] VPN Hotspot: $*" >> "$LOG_FILE"; }

IP_BIN=$(command -v ip 2>/dev/null); [ -n "$IP_BIN" ] || IP_BIN=/system/bin/ip
IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables

valid_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

normalize_fallback_mode() {
  case "${VPN_FALLBACK_MODE:-}" in
    ANTIDPI|antidpi) VPN_FALLBACK_MODE=ANTIDPI ;;
    BLOCK|block) VPN_FALLBACK_MODE=BLOCK ;;
    *)
      # Migration from v2.6.8: honor an explicitly enabled legacy killswitch,
      # otherwise use the new safer/user-friendly default.
      if [ "${VPN_HOTSPOT_KILLSWITCH:-0}" = "1" ]; then
        VPN_FALLBACK_MODE=BLOCK
      else
        VPN_FALLBACK_MODE=ANTIDPI
      fi
      ;;
  esac
}

fallback_is_block() { [ "$VPN_FALLBACK_MODE" = "BLOCK" ]; }

normalize_fallback_mode

detect_vpn_iface() {
  "$MODDIR/net-role.sh" vpn 2>/dev/null | head -n1
}

detect_downstreams() {
  "$MODDIR/net-role.sh" downstreams 2>/dev/null
}

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

cleanup_state_rules() {
  local pref selector value table
  if [ -f "$STATE_FILE" ]; then
    while IFS='|' read -r pref selector value table; do
      valid_number "$pref" || continue
      # v2.6.7 state format was: pref|iif|table. Clean it during upgrade.
      if [ -z "$table" ] && [ -n "$selector" ] && [ -n "$value" ]; then
        "$IP_BIN" rule del pref "$pref" iif "$selector" lookup "$value" 2>/dev/null || true
        continue
      fi
      [ -n "$selector" ] || continue
      [ -n "$value" ] || continue
      [ -n "$table" ] || continue
      case "$selector" in
        iif) "$IP_BIN" rule del pref "$pref" iif "$value" lookup "$table" 2>/dev/null || true ;;
        iif6) "$IP_BIN" -6 rule del pref "$pref" iif "$value" lookup "$table" 2>/dev/null || true ;;
        from) "$IP_BIN" rule del pref "$pref" from "$value" lookup "$table" 2>/dev/null || true ;;
      esac
    done < "$STATE_FILE"
  fi
  rm -f "$STATE_FILE"
}

cleanup_private_tables() {
  valid_number "$VPN_ROUTE_TABLE" || return 0
  "$IP_BIN" -4 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
  "$IP_BIN" -6 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
}

cleanup_iptables() {
  [ -x "$IPT" ] && {
    while "$IPT" -w 5 -t nat -D POSTROUTING -j ZAPRET2_VPN_NAT >/dev/null 2>&1; do :; done
    "$IPT" -w 5 -t nat -F ZAPRET2_VPN_NAT >/dev/null 2>&1 || true
    "$IPT" -w 5 -t nat -X ZAPRET2_VPN_NAT >/dev/null 2>&1 || true
    while "$IPT" -w 5 -t filter -D FORWARD -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1; do :; done
    "$IPT" -w 5 -t filter -F ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    "$IPT" -w 5 -t filter -X ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
  }
  [ -x "$IP6T" ] && {
    while "$IP6T" -w 5 -t filter -D FORWARD -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1; do :; done
    "$IP6T" -w 5 -t filter -F ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    "$IP6T" -w 5 -t filter -X ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
  }
}

cleanup_rules() {
  cleanup_state_rules
  cleanup_private_tables
  cleanup_old_unsafe_rules
  cleanup_iptables
}

next_free_pref() {
  local pref="$1" max=$((VPN_ROUTE_PREF_BASE + 399))
  while [ "$pref" -le "$max" ]; do
    "$IP_BIN" rule show 2>/dev/null | grep -q "^$pref:" || { echo "$pref"; return 0; }
    pref=$((pref + 1))
  done
  return 1
}

setup_private_route_table() {
  local vpn_if="$1" has4=0 has6=0
  valid_number "$VPN_ROUTE_TABLE" || { log "некорректный VPN_ROUTE_TABLE=$VPN_ROUTE_TABLE"; return 1; }
  "$IP_BIN" -o -4 addr show dev "$vpn_if" 2>/dev/null | grep -q ' inet ' && has4=1
  "$IP_BIN" -o -6 addr show dev "$vpn_if" 2>/dev/null | grep -q ' inet6 ' && has6=1

  "$IP_BIN" -4 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true
  "$IP_BIN" -6 route flush table "$VPN_ROUTE_TABLE" 2>/dev/null || true

  if [ "$has4" = 1 ]; then
    "$IP_BIN" -4 route replace default dev "$vpn_if" table "$VPN_ROUTE_TABLE" 2>/dev/null || {
      log "не удалось создать IPv4 default dev $vpn_if table $VPN_ROUTE_TABLE"
      return 1
    }
  fi
  if [ "$has6" = 1 ]; then
    "$IP_BIN" -6 route replace default dev "$vpn_if" table "$VPN_ROUTE_TABLE" 2>/dev/null || \
      log "IPv6 default через $vpn_if не создан; IPv6 leak guard всё равно останется активным"
  fi
  [ "$has4" = 1 ] || { log "VPN=$vpn_if не имеет IPv4-адреса; IPv4 VPN sharing недоступен"; return 1; }
  return 0
}

add_policy_rule() {
  local pref="$1" down="$2" subnet
  if "$IP_BIN" rule add pref "$pref" iif "$down" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then
    echo "$pref|iif|$down|$VPN_ROUTE_TABLE" >> "$STATE_FILE"
    if "$IP_BIN" -6 rule add pref "$pref" iif "$down" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then
      echo "$pref|iif6|$down|$VPN_ROUTE_TABLE" >> "$STATE_FILE"
    fi
    log "policy rule: pref=$pref iif=$down lookup=$VPN_ROUTE_TABLE"
    return 0
  fi

  # Some vendor kernels/userspace reject iif rules. Fall back only to the exact
  # tether subnet, never to broad RFC1918 ranges.
  subnet=$(subnet_for_iface "$down")
  [ -n "$subnet" ] || return 1
  if "$IP_BIN" rule add pref "$pref" from "$subnet" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then
    echo "$pref|from|$subnet|$VPN_ROUTE_TABLE" >> "$STATE_FILE"
    if "$IP_BIN" -6 rule add pref "$pref" iif "$down" lookup "$VPN_ROUTE_TABLE" 2>/dev/null; then
      echo "$pref|iif6|$down|$VPN_ROUTE_TABLE" >> "$STATE_FILE"
    fi
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
  for down in $downs; do
    "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || true
  done
  if [ -x "$IP6T" ]; then
    "$IP6T" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    "$IP6T" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    for down in $downs; do "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -j REJECT >/dev/null 2>&1 || true; done
  fi
  log "fallback=BLOCK: VPN не готов, интернет клиентов раздачи заблокирован"
}

setup_vpn_nat_forward_guard() {
  local vpn_if="$1" downs="$2" down subnet
  [ -x "$IPT" ] || { log "iptables недоступен: VPN sharing не применён"; return 1; }

  "$IPT" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1
  "$IPT" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || return 1

  if [ "$VPN_HOTSPOT_MASQUERADE" = "1" ]; then
    "$IPT" -w 5 -t nat -N ZAPRET2_VPN_NAT >/dev/null 2>&1 || return 1
    "$IPT" -w 5 -t nat -I POSTROUTING 1 -j ZAPRET2_VPN_NAT >/dev/null 2>&1 || return 1
  fi

  for down in $downs; do
    "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -o "$vpn_if" -j ACCEPT >/dev/null 2>&1 || true
    if "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$vpn_if" -o "$down" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; then :; else
      "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$vpn_if" -o "$down" -m state --state ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
    fi
    if fallback_is_block; then
      "$IPT" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" ! -o "$vpn_if" -j REJECT >/dev/null 2>&1 || true
    fi
    if [ "$VPN_HOTSPOT_MASQUERADE" = "1" ]; then
      subnet=$(subnet_for_iface "$down")
      if [ -n "$subnet" ]; then
        "$IPT" -w 5 -t nat -A ZAPRET2_VPN_NAT -s "$subnet" -o "$vpn_if" -j MASQUERADE >/dev/null 2>&1 || true
        log "MASQUERADE: downstream=$down subnet=$subnet -> $vpn_if"
      else
        log "не удалось определить подсеть downstream=$down для MASQUERADE"
      fi
    fi
  done

  # IPv6: route into the VPN when possible and always prevent physical-interface leakage.
  if [ -x "$IP6T" ]; then
    "$IP6T" -w 5 -t filter -N ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    "$IP6T" -w 5 -t filter -I FORWARD 1 -j ZAPRET2_VPN_FORWARD >/dev/null 2>&1 || true
    for down in $downs; do
      "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" -o "$vpn_if" -j ACCEPT >/dev/null 2>&1 || true
      "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$vpn_if" -o "$down" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
      if fallback_is_block; then
        "$IP6T" -w 5 -t filter -A ZAPRET2_VPN_FORWARD -i "$down" ! -o "$vpn_if" -j REJECT >/dev/null 2>&1 || true
      fi
    done
  fi
}

acquire_lock() {
  mkdir -p "$RUN_DIR" || return 1
  local n=0 lock_pid
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if ! valid_number "$lock_pid" || ! kill -0 "$lock_pid" 2>/dev/null; then rm -rf "$LOCK_DIR" 2>/dev/null; fi
    n=$((n + 1)); [ "$n" -lt 6 ] || return 1
    sleep 1
  done
  echo $$ > "$LOCK_DIR/pid"
}

release_lock() { [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null; }

apply_rules() {
  local vpn_if downs pref down
  cleanup_rules
  [ "$ENABLE_HOTSPOT" = "1" ] && [ "$ENABLE_VPN_HOTSPOT" = "1" ] || return 0
  [ -x "$IP_BIN" ] || { log "команда ip не найдена"; return 1; }

  downs=$(detect_downstreams)
  if [ -z "$downs" ]; then
    if downstream_candidate_exists; then
      log "downstream-интерфейс появился, но адрес ещё не готов; повторим применение"
      return 3
    fi
    log "VPN sharing включён, но активный tether downstream пока не найден"
    return 0
  fi

  vpn_if=$(detect_vpn_iface) || {
    if fallback_is_block; then
      setup_guard_only "$downs" || true
      log "VPN недоступен: fallback=BLOCK, клиенты раздачи заблокированы"
    else
      # cleanup_rules above already removed our private VPN table/policy/NAT/guard.
      # Android tethering can therefore use its normal upstream, while service.sh
      # keeps ZAPRET2_MANGLE_FORWARD / QUIC rules active on the same downstream.
      log "VPN недоступен: fallback=ANTIDPI, клиенты продолжают через обычный upstream + Zapret2"
    fi
    if vpn_candidate_exists; then
      log "VPN-кандидат уже появился, но Android ещё не завершил настройку; watcher повторит применение"
      return 3
    fi
    return 0
  }

  if ! setup_private_route_table "$vpn_if"; then
    cleanup_rules
    if fallback_is_block; then setup_guard_only "$downs" || true; fi
    log "VPN route-table не готова: fallback=$VPN_FALLBACK_MODE"
    return 1
  fi

  : > "$STATE_FILE"
  pref="$VPN_ROUTE_PREF_BASE"
  for down in $downs; do
    pref=$(next_free_pref "$pref") || { log "нет свободного priority в диапазоне ${VPN_ROUTE_PREF_BASE}..$((VPN_ROUTE_PREF_BASE + 399))"; cleanup_rules; setup_guard_only "$downs"; return 1; }
    if add_policy_rule "$pref" "$down"; then
      pref=$((pref + 1))
    else
      log "не удалось добавить policy rule для downstream=$down"
      cleanup_rules
      if fallback_is_block; then setup_guard_only "$downs" || true; fi
      log "policy routing не применён: fallback=$VPN_FALLBACK_MODE"
      return 1
    fi
  done

  setup_vpn_nat_forward_guard "$vpn_if" "$downs" || {
    log "не удалось настроить VPN NAT/FORWARD"
    cleanup_rules
    if fallback_is_block; then setup_guard_only "$downs" || true; fi
    log "VPN NAT/FORWARD не применён: fallback=$VPN_FALLBACK_MODE"
    return 1
  }
  log "VPN sharing ACTIVE: downstream=$(echo $downs | tr '\n' ',') -> $vpn_if private_table=$VPN_ROUTE_TABLE fallback=$VPN_FALLBACK_MODE"
  return 0
}

signature() {
  "$MODDIR/net-role.sh" signature 2>/dev/null
}

acquire_lock || exit 0
trap 'release_lock' EXIT HUP INT TERM
case "$1" in
  apply|reload|'') apply_rules ;;
  cleanup) cleanup_rules ;;
  signature) signature ;;
  *) exit 2 ;;
esac
