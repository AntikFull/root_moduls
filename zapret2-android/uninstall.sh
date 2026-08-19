#!/system/bin/sh
umask 077

MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"
: "${AUTO_TEST_QNUM:=201}" "${AUTO_TEST_PORT_MIN:=39000}" "${AUTO_TEST_PORT_MAX:=39049}"
pid_cmdline() { tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
pid_owned() {
  pid="$1" kind="$2"
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  case "$kind" in
    nfqws2) [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = nfqws2 ] && [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$MODDIR/bin" ] ;;
    config) pid_cmdline "$pid" | grep -Fq "$MODDIR/on_change.sh" ;;
    vpn) pid_cmdline "$pid" | grep -Fq "$MODDIR/vpn-watch.sh" ;;
    health) pid_cmdline "$pid" | grep -Fq "$MODDIR/service-watch.sh" ;;
    auto) pid_cmdline "$pid" | grep -Fq "$MODDIR/auto-select.sh" ;;
    service) pid_cmdline "$pid" | grep -Fq "$MODDIR/service.sh" ;;
    httpd) { [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = httpd ] || pid_cmdline "$pid" | grep -Fq "httpd"; } && pid_cmdline "$pid" | grep -Fq "$MODDIR/webroot" ;;
    *) return 1 ;;
  esac
}
for spec in "nfqws2.pid:nfqws2" "watcher.pid:config" "vpn-watcher.pid:vpn" "health-watcher.pid:health" "auto-probe.pid:auto" "late-start.pid:service" "httpd.pid:httpd"; do
  pf=${spec%%:*}; kind=${spec#*:}; pid_file="$RUN_DIR/$pf"
  pid=$(cat "$pid_file" 2>/dev/null)
  pid_owned "$pid" "$kind" && kill -TERM "$pid" 2>/dev/null
  rm -f "$pid_file" 2>/dev/null
done
for proc in /proc/[0-9]*; do
  comm=$(cat "$proc/comm" 2>/dev/null)
  cwd=$(readlink "$proc/cwd" 2>/dev/null)
  if [ "$comm" = "nfqws2" ] && [ "$cwd" = "$MODDIR/bin" ]; then
    kill -TERM "${proc##*/}" 2>/dev/null
  fi
  cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null)
  if printf '%s' "$cmd" | grep -Fq "$MODDIR/webroot" && printf '%s' "$cmd" | grep -Fq "httpd"; then
    kill -TERM "${proc##*/}" 2>/dev/null
  fi
done
[ -f "$MODDIR/warp-tunnel.sh" ] && sh "$MODDIR/warp-tunnel.sh" stop 2>/dev/null
sh "$MODDIR/vpn-routing.sh" cleanup 2>/dev/null

IPT="iptables -w 5"
IP6T="ip6tables -w 5"

while $IPT -t mangle -D OUTPUT -p tcp --sport "$AUTO_TEST_PORT_MIN:$AUTO_TEST_PORT_MAX" --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null; do :; done
while $IPT -t mangle -D OUTPUT -p tcp --sport "$AUTO_TEST_PORT_MIN:$AUTO_TEST_PORT_MAX" --dport 443 -j RETURN 2>/dev/null; do :; done
while $IPT -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null; do :; done
while $IPT -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN 2>/dev/null; do :; done
while $IP6T -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j NFQUEUE --queue-num "$AUTO_TEST_QNUM" --queue-bypass 2>/dev/null; do :; done
while $IP6T -t mangle -D OUTPUT -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN 2>/dev/null; do :; done

while $IPT -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null; do :; done
$IPT -t mangle -F ZAPRET2_MANGLE_FORWARD 2>/dev/null
while $IPT -t mangle -D FORWARD -j ZAPRET2_MANGLE_FORWARD 2>/dev/null; do :; done
$IPT -t mangle -X ZAPRET2_MANGLE_FORWARD 2>/dev/null
$IPT -t mangle -F ZAPRET2_MANGLE 2>/dev/null
$IPT -t mangle -X ZAPRET2_MANGLE 2>/dev/null

while $IPT -t mangle -D INPUT -j ZAPRET2_MANGLE_IN 2>/dev/null; do :; done
$IPT -t mangle -F ZAPRET2_MANGLE_IN 2>/dev/null
$IPT -t mangle -X ZAPRET2_MANGLE_IN 2>/dev/null
while $IPT -t mangle -D INPUT -j ZAPRET2_INPUT 2>/dev/null; do :; done
$IPT -t mangle -F ZAPRET2_INPUT 2>/dev/null
$IPT -t mangle -X ZAPRET2_INPUT 2>/dev/null

while $IPT -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null; do :; done
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

while $IP6T -t mangle -D INPUT -j ZAPRET2_MANGLE_IN 2>/dev/null; do :; done
$IP6T -t mangle -F ZAPRET2_MANGLE_IN 2>/dev/null
$IP6T -t mangle -X ZAPRET2_MANGLE_IN 2>/dev/null
while $IP6T -t mangle -D INPUT -j ZAPRET2_INPUT 2>/dev/null; do :; done
$IP6T -t mangle -F ZAPRET2_INPUT 2>/dev/null
$IP6T -t mangle -X ZAPRET2_INPUT 2>/dev/null

while $IP6T -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null; do :; done
$IP6T -t filter -F ZAPRET2_FILTER 2>/dev/null
$IP6T -t filter -X ZAPRET2_FILTER 2>/dev/null
while $IP6T -t filter -D FORWARD -j ZAPRET2_FILTER_FORWARD 2>/dev/null; do :; done
$IP6T -t filter -F ZAPRET2_FILTER_FORWARD 2>/dev/null
$IP6T -t filter -X ZAPRET2_FILTER_FORWARD 2>/dev/null

# Очистка цепочек WARP и устаревших правил AI Router
while $IPT -t nat -D OUTPUT -j ZAPRET2_WARP_DNS 2>/dev/null; do :; done
$IPT -t nat -F ZAPRET2_WARP_DNS 2>/dev/null
$IPT -t nat -X ZAPRET2_WARP_DNS 2>/dev/null

while $IPT -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
while $IPT -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
$IPT -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null
$IPT -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null
while $IP6T -t mangle -D OUTPUT -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
while $IP6T -t mangle -D POSTROUTING -j ZAPRET2_WARP_MANGLE 2>/dev/null; do :; done
$IP6T -t mangle -F ZAPRET2_WARP_MANGLE 2>/dev/null
$IP6T -t mangle -X ZAPRET2_WARP_MANGLE 2>/dev/null

while $IPT -t nat -D OUTPUT -j ZAPRET2_AI_NAT 2>/dev/null; do :; done
$IPT -t nat -F ZAPRET2_AI_NAT 2>/dev/null
$IPT -t nat -X ZAPRET2_AI_NAT 2>/dev/null
while $IPT -t filter -D OUTPUT -j ZAPRET2_AI_FLT 2>/dev/null; do :; done
$IPT -t filter -F ZAPRET2_AI_FLT 2>/dev/null
$IPT -t filter -X ZAPRET2_AI_FLT 2>/dev/null
while $IPT -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j REDIRECT --to-ports 15359 2>/dev/null; do :; done

rm -f /tmp/zapret2_apps_cache.json 2>/dev/null
rm -f /tmp/zapret2_apps_new.json 2>/dev/null

rm -rf "$RUN_DIR/app-sync.lock" "$RUN_DIR/service.lock" "$RUN_DIR/vpn-routing.lock" "$RUN_DIR/auto-select.lock" "$RUN_DIR/warp.lock" 2>/dev/null
