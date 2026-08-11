#!/system/bin/sh
# Очистка только процессов и правил, принадлежащих этому модулю.

MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
for pid_file in "$RUN_DIR/nfqws2.pid" "$RUN_DIR/watcher.pid" "$RUN_DIR/vpn-watcher.pid"; do
  pid=$(cat "$pid_file" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) continue ;; esac
  kill -TERM "$pid" 2>/dev/null
done
sh "$MODDIR/vpn-routing.sh" cleanup 2>/dev/null

IPT="iptables -w 5"
IP6T="ip6tables -w 5"

while $IPT -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null; do :; done
$IPT -t mangle -F ZAPRET2_MANGLE_FORWARD 2>/dev/null
while $IPT -t mangle -D FORWARD -j ZAPRET2_MANGLE_FORWARD 2>/dev/null; do :; done
$IPT -t mangle -X ZAPRET2_MANGLE_FORWARD 2>/dev/null
$IPT -t mangle -F ZAPRET2_MANGLE 2>/dev/null
$IPT -t mangle -X ZAPRET2_MANGLE 2>/dev/null

$IPT -t mangle -D INPUT -j ZAPRET2_INPUT 2>/dev/null
$IPT -t mangle -F ZAPRET2_INPUT 2>/dev/null
$IPT -t mangle -X ZAPRET2_INPUT 2>/dev/null

$IPT -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null
$IPT -t filter -F ZAPRET2_FILTER 2>/dev/null
$IPT -t filter -X ZAPRET2_FILTER 2>/dev/null
while $IPT -t filter -D FORWARD -j ZAPRET2_FILTER_FORWARD 2>/dev/null; do :; done
$IPT -t filter -F ZAPRET2_FILTER_FORWARD 2>/dev/null
$IPT -t filter -X ZAPRET2_FILTER_FORWARD 2>/dev/null

while $IPT -t nat -D PREROUTING -j ZAPRET2_NAT_PREROUTING 2>/dev/null; do :; done
$IPT -t nat -F ZAPRET2_NAT_PREROUTING 2>/dev/null
$IPT -t nat -X ZAPRET2_NAT_PREROUTING 2>/dev/null

while $IP6T -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null; do :; done
$IP6T -t mangle -F ZAPRET2_MANGLE_FORWARD 2>/dev/null
while $IP6T -t mangle -D FORWARD -j ZAPRET2_MANGLE_FORWARD 2>/dev/null; do :; done
$IP6T -t mangle -X ZAPRET2_MANGLE_FORWARD 2>/dev/null
$IP6T -t mangle -F ZAPRET2_MANGLE 2>/dev/null
$IP6T -t mangle -X ZAPRET2_MANGLE 2>/dev/null

$IP6T -t mangle -D INPUT -j ZAPRET2_INPUT 2>/dev/null
$IP6T -t mangle -F ZAPRET2_INPUT 2>/dev/null
$IP6T -t mangle -X ZAPRET2_INPUT 2>/dev/null

$IP6T -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null
$IP6T -t filter -F ZAPRET2_FILTER 2>/dev/null
$IP6T -t filter -X ZAPRET2_FILTER 2>/dev/null
while $IP6T -t filter -D FORWARD -j ZAPRET2_FILTER_FORWARD 2>/dev/null; do :; done
$IP6T -t filter -F ZAPRET2_FILTER_FORWARD 2>/dev/null
$IP6T -t filter -X ZAPRET2_FILTER_FORWARD 2>/dev/null

rm -f /tmp/zapret2_apps_cache.json 2>/dev/null
rm -f /tmp/zapret2_apps_new.json 2>/dev/null
