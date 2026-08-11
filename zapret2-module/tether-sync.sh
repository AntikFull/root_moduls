#!/system/bin/sh
# Rebuild exact Hotspot/USB AntiDPI rules for the currently detected downstreams.
# Keeps Zapret2 independent of fixed names such as wlan2/tun0.

MODDIR=${0%/*}
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
RUNTIME_FILE="$RUN_DIR/tether-runtime.conf"
STATE_FILE="$RUN_DIR/tether-downstreams.state"
LOG_FILE="/sdcard/eCubz/zapret2_debug.log"

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
[ -f "$RUNTIME_FILE" ] && . "$RUNTIME_FILE"
: "${ENABLE_HOTSPOT:=1}" "${FORCE_TCP_HOTSPOT:=1}" "${DNS_FORWARD_HOTSPOT:=0}"
: "${PORTS_TCP:=80,443}" "${QNUM:=200}" "${STRATEGY_EFFECTIVE:=SIMPLE}"
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

write_state() {
  local downs="$1" old
  old=$(cat "$STATE_FILE" 2>/dev/null)
  printf '%s\n' "$downs" > "$STATE_FILE"
  [ "$old" = "$downs" ] || log "active downstream: ${downs:-none}"
}

flush_chains() {
  [ -x "$IPT" ] || return 1
  chain_exists4 mangle ZAPRET2_MANGLE_FORWARD && ipt4 -t mangle -F ZAPRET2_MANGLE_FORWARD
  chain_exists4 filter ZAPRET2_FILTER_FORWARD && ipt4 -t filter -F ZAPRET2_FILTER_FORWARD
  chain_exists4 nat ZAPRET2_NAT_PREROUTING && ipt4 -t nat -F ZAPRET2_NAT_PREROUTING
  if [ -x "$IP6T" ]; then
    chain_exists6 mangle ZAPRET2_MANGLE_FORWARD && ipt6 -t mangle -F ZAPRET2_MANGLE_FORWARD
    chain_exists6 filter ZAPRET2_FILTER_FORWARD && ipt6 -t filter -F ZAPRET2_FILTER_FORWARD
  fi
}

add_dns_rules_for_iface() {
  local tif="$1" servers server_count remaining idx dns_server probability
  [ "$DNS_FORWARD_HOTSPOT" = "1" ] || return 0
  chain_exists4 nat ZAPRET2_NAT_PREROUTING || return 0
  servers="$DNS_FORWARD_SERVERS"
  [ -n "$servers" ] || servers="$DNS_FORWARD_SERVER"
  server_count=$(echo "$servers" | wc -w | tr -d ' ')
  case "$server_count" in ''|*[!0-9]*|0) return 0 ;; esac
  remaining=$server_count
  idx=1
  for dns_server in $servers; do
    if [ "$remaining" -le 1 ]; then
      ipt4 -t nat -A ZAPRET2_NAT_PREROUTING -i "$tif" -p udp --dport 53 -j DNAT --to "$dns_server" || true
    else
      probability=$(awk -v n="$remaining" 'BEGIN { printf "%.6f", 1/n }')
      ipt4 -t nat -A ZAPRET2_NAT_PREROUTING -i "$tif" -p udp --dport 53 -m statistic --mode random --probability "$probability" -j DNAT --to "$dns_server" || true
    fi
    remaining=$((remaining - 1))
    idx=$((idx + 1))
  done
}

apply_rules() {
  local downs tif normalized
  [ "$ENABLE_HOTSPOT" = "1" ] || { flush_chains; write_state ""; return 0; }
  [ -x "$IPT" ] || return 1

  downs=$(detect_downstreams)
  normalized=$(echo "$downs" | awk 'NF && !seen[$0]++' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')

  flush_chains || return 1

  for tif in $normalized; do
    if chain_exists4 mangle ZAPRET2_MANGLE_FORWARD; then
      if [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && [ "$CONNBYTES4" = "1" ] && [ "$CONNMARK4" = "1" ]; then
        ipt4 -t mangle -A ZAPRET2_MANGLE_FORWARD -o "$tif" -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || true
        ipt4 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      fi
      ipt4 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 || true
    fi

    if [ "$NFQ6" = "1" ] && [ -x "$IP6T" ] && chain_exists6 mangle ZAPRET2_MANGLE_FORWARD; then
      if [ "$STRATEGY_EFFECTIVE" = "AUTO" ] && [ "$CONNBYTES6" = "1" ] && [ "$CONNMARK6" = "1" ]; then
        ipt6 -t mangle -A ZAPRET2_MANGLE_FORWARD -o "$tif" -p tcp -m multiport --sports "$PORTS_TCP" -m connmark --mark "$FLOW_CONNMARK" -m connbytes --connbytes 1:"$AUTO_REPLY_PACKETS" --connbytes-dir reply --connbytes-mode packets -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
        ipt6 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" || true
      fi
      ipt6 -t mangle -A ZAPRET2_MANGLE_FORWARD -i "$tif" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 || true
    fi

    if [ "$FORCE_TCP_HOTSPOT" = "1" ]; then
      chain_exists4 filter ZAPRET2_FILTER_FORWARD && ipt4 -t filter -A ZAPRET2_FILTER_FORWARD -i "$tif" -p udp --dport 443 -j REJECT || true
      if [ -x "$IP6T" ] && chain_exists6 filter ZAPRET2_FILTER_FORWARD; then
        ipt6 -t filter -A ZAPRET2_FILTER_FORWARD -i "$tif" -p udp --dport 443 -j REJECT || true
      fi
    fi

    add_dns_rules_for_iface "$tif"
  done

  write_state "$normalized"
  return 0
}

case "$1" in
  apply|reload|'') apply_rules ;;
  cleanup) flush_chains; write_state "" ;;
  *) exit 2 ;;
esac
