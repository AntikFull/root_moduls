#!/system/bin/sh

umask 077
MODDIR=${0%/*}
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
RUNTIME_FILE="$RUN_DIR/tether-runtime.conf"
STATE_FILE="$RUN_DIR/tether-downstreams.state"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"

mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null
chmod 0700 "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
[ -f "$RUNTIME_FILE" ] && . "$RUNTIME_FILE"
: "${ENABLE_HOTSPOT:=1}" "${FORCE_TCP_HOTSPOT:=1}" "${DNS_FORWARD_HOTSPOT:=0}"
: "${PORTS_TCP:=80,443}" "${QNUM:=200}" "${STRATEGY_EFFECTIVE:=SMART_COMPAT}"
: "${AUTO_REPLY_PACKETS:=12}" "${FLOW_CONNMARK:=0x10000000/0x10000000}"
: "${NFQ6:=0}" "${CONNBYTES4:=0}" "${CONNBYTES6:=0}" "${CONNMARK4:=0}" "${CONNMARK6:=0}"
: "${QBYPASS4:=--queue-bypass}" "${QBYPASS6:=--queue-bypass}"
: "${DNS_FORWARD_SERVERS:=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112}"
: "${DNS_FORWARD_SERVER:=1.1.1.1}"

IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tether roles: $*" >> "$LOG_FILE"; }
ipt4() { "$IPT" -w 5 "$@" >/dev/null 2>&1; }
ipt6() { "$IP6T" -w 5 "$@" >/dev/null 2>&1; }
chain_exists4() { "$IPT" -w 5 -t "$1" -S "$2" >/dev/null 2>&1; }
chain_exists6() { "$IP6T" -w 5 -t "$1" -S "$2" >/dev/null 2>&1; }
detect_downstreams() { "$MODDIR/net-role.sh" downstreams 2>/dev/null; }

valid_ipv4() {
  local ip="$1" a b c d extra
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

dns_statistic_available() {
  local probe="ZAPRET2_DNS_PROBE_$$"
  case "${DNS_STATISTIC_OK:-}" in 1) return 0 ;; 0) return 1 ;; esac
  if "$IPT" -w 5 -t nat -N "$probe" >/dev/null 2>&1; then
    if "$IPT" -w 5 -t nat -A "$probe" -m statistic --mode random --probability 0.500000 -j RETURN >/dev/null 2>&1; then
      DNS_STATISTIC_OK=1
    else
      DNS_STATISTIC_OK=0
    fi
    "$IPT" -w 5 -t nat -F "$probe" >/dev/null 2>&1 || true
    "$IPT" -w 5 -t nat -X "$probe" >/dev/null 2>&1 || true
  else
    DNS_STATISTIC_OK=0
  fi
  [ "$DNS_STATISTIC_OK" = 1 ]
}

write_state() {
  local downs="$1" old tmp="$STATE_FILE.tmp.$$"
  old=$(cat "$STATE_FILE" 2>/dev/null)
  printf '%s\n' "$downs" > "$tmp" && mv -f "$tmp" "$STATE_FILE"
  chmod 0600 "$STATE_FILE" 2>/dev/null || true
  [ "$old" = "$downs" ] || log "active downstream: ${downs:-none}"
}

flush_chains() {
  [ -x "$IPT" ] || return 1
  chain_exists4 mangle ZAPRET2_MANGLE_FORWARD && ipt4 -t mangle -F ZAPRET2_MANGLE_FORWARD || true
  chain_exists4 filter ZAPRET2_FILTER_FORWARD && ipt4 -t filter -F ZAPRET2_FILTER_FORWARD || true
  chain_exists4 nat ZAPRET2_NAT_PREROUTING && ipt4 -t nat -F ZAPRET2_NAT_PREROUTING || true
  if [ -x "$IP6T" ]; then
    chain_exists6 mangle ZAPRET2_MANGLE_FORWARD && ipt6 -t mangle -F ZAPRET2_MANGLE_FORWARD || true
    chain_exists6 filter ZAPRET2_FILTER_FORWARD && ipt6 -t filter -F ZAPRET2_FILTER_FORWARD || true
  fi
  return 0
}

rules_already_match() {
  local normalized="$1" tif
  [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$normalized" ] || return 1
  [ -n "$normalized" ] || return 0
  chain_exists4 mangle ZAPRET2_MANGLE_FORWARD || return 1
  for tif in $normalized; do
    "$IPT" -w 5 -t mangle -S ZAPRET2_MANGLE_FORWARD 2>/dev/null | grep -F -- "-i $tif" | grep -q -- '-j NFQUEUE' || return 1
    if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNBYTES4" = "1" ] && [ "$CONNMARK4" = "1" ]; then
      "$IPT" -w 5 -t mangle -S ZAPRET2_MANGLE_FORWARD 2>/dev/null | grep -F -- "-o $tif" | grep -q -- '-m connbytes' || return 1
    fi
    if [ "$FORCE_TCP_HOTSPOT" = "1" ]; then
      "$IPT" -w 5 -t filter -S ZAPRET2_FILTER_FORWARD 2>/dev/null | grep -F -- "-i $tif" | grep -q -- '--dport 443' || return 1
    fi
    if [ "$DNS_FORWARD_HOTSPOT" = "1" ]; then
      "$IPT" -w 5 -t nat -S ZAPRET2_NAT_PREROUTING 2>/dev/null | grep -F -- "-i $tif" | grep -q -- '-p udp' || return 1
      "$IPT" -w 5 -t nat -S ZAPRET2_NAT_PREROUTING 2>/dev/null | grep -F -- "-i $tif" | grep -q -- '-p tcp' || return 1
      "$IPT" -w 5 -t nat -S ZAPRET2_NAT_PREROUTING 2>/dev/null | grep -F -- "-i $tif" | grep -q -- '--dport 53' || return 1
    fi
  done
  return 0
}

add_dns_proto_rules_for_iface() {
  local tif="$1" proto="$2" servers server_count remaining dns_server probability first
  servers="$DNS_FORWARD_SERVERS"; [ -n "$servers" ] || servers="$DNS_FORWARD_SERVER"
  server_count=$(echo "$servers" | wc -w | tr -d ' ')
  case "$server_count" in ''|*[!0-9]*|0) return 1 ;; esac
  for dns_server in $servers; do
    valid_ipv4 "$dns_server" || { log "invalid DNS server ignored: $dns_server"; return 1; }
    [ -n "$first" ] || first="$dns_server"
  done
  if [ "$server_count" -gt 1 ] && ! dns_statistic_available; then
    log "xt_statistic unavailable: DNS $proto fallback to first resolver $first"
    ipt4 -t nat -A ZAPRET2_NAT_PREROUTING -i "$tif" -p "$proto" --dport 53 -j DNAT --to "$first" || return 1
    return 0
  fi
  remaining=$server_count
  for dns_server in $servers; do
    if [ "$remaining" -le 1 ]; then
      ipt4 -t nat -A ZAPRET2_NAT_PREROUTING -i "$tif" -p "$proto" --dport 53 -j DNAT --to "$dns_server" || return 1
    else
      probability=$(awk -v n="$remaining" 'BEGIN { printf "%.6f", 1/n }')
      ipt4 -t nat -A ZAPRET2_NAT_PREROUTING -i "$tif" -p "$proto" --dport 53 -m statistic --mode random --probability "$probability" -j DNAT --to "$dns_server" || return 1
    fi
    remaining=$((remaining - 1))
  done
  return 0
}

add_dns_rules_for_iface() {
  local tif="$1"
  [ "$DNS_FORWARD_HOTSPOT" = "1" ] || return 0
  chain_exists4 nat ZAPRET2_NAT_PREROUTING || return 1
  add_dns_proto_rules_for_iface "$tif" udp || return 1
  add_dns_proto_rules_for_iface "$tif" tcp || return 1
}

apply_rules() {
  local downs tif normalized
  [ "$ENABLE_HOTSPOT" = "1" ] || { flush_chains; write_state ""; return 0; }
  [ -x "$IPT" ] || return 1

  downs=$(detect_downstreams)
  normalized=$(echo "$downs" | awk 'NF && !seen[$0]++' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if rules_already_match "$normalized"; then return 0; fi

  flush_chains || return 1

  for tif in $normalized; do
    chain_exists4 mangle ZAPRET2_MANGLE_FORWARD || { log "missing IPv4 mangle tether chain"; return 1; }
    if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNBYTES4" = "1" ] && [ "$CONNMARK4" = "1" ]; then
      ipt4 -t mangle -A ZAPRET2_MANGLE_FORWARD -o "$tif" -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || return 1
      ipt4 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || return 1
    fi
    ipt4 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || return 1

    if [ "$NFQ6" = "1" ] && [ -x "$IP6T" ] && chain_exists6 mangle ZAPRET2_MANGLE_FORWARD; then
      if [ "$STRATEGY_EFFECTIVE" = "SMART_NATIVE" ] && [ "$CONNBYTES6" = "1" ] && [ "$CONNMARK6" = "1" ]; then
        ipt6 -t mangle -A ZAPRET2_MANGLE_FORWARD -o "$tif" -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || log "IPv6 SMART_NATIVE reply rule failed for $tif"
        ipt6 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || log "IPv6 CONNMARK rule failed for $tif"
      fi
      ipt6 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || log "IPv6 NFQUEUE rule failed for $tif"
    fi

    if [ "$FORCE_TCP_HOTSPOT" = "1" ]; then
      chain_exists4 filter ZAPRET2_FILTER_FORWARD || return 1
      ipt4 -t filter -A ZAPRET2_FILTER_FORWARD -i "$tif" -p udp --dport 443 -j REJECT || return 1
      if [ -x "$IP6T" ] && chain_exists6 filter ZAPRET2_FILTER_FORWARD; then
        ipt6 -t filter -A ZAPRET2_FILTER_FORWARD -i "$tif" -p udp --dport 443 -j REJECT || log "IPv6 Hotspot QUIC rule failed for $tif"
      fi
    fi

    add_dns_rules_for_iface "$tif" || { log "DNS forcing rules failed for $tif"; return 1; }
  done

  write_state "$normalized"
  return 0
}

case "$1" in
  apply|reload|'') apply_rules ;;
  verify) rules_already_match "$(detect_downstreams | awk 'NF && !seen[$0]++' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')" ;;
  cleanup) flush_chains; write_state "" ;;
  *) exit 2 ;;
esac
