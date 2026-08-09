#!/system/bin/sh
# Uninstall cleanup script for zapret2

pkill -9 -f nfqws2 2>/dev/null
pkill -9 -f "zapret2_watcher" 2>/dev/null
pkill -9 -f "zapret2-control" 2>/dev/null

IPT="iptables -w 5"
IP6T="ip6tables -w 5"

$IPT -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null
$IPT -t mangle -F ZAPRET2_MANGLE 2>/dev/null
$IPT -t mangle -X ZAPRET2_MANGLE 2>/dev/null

$IPT -t mangle -D INPUT -j ZAPRET2_INPUT 2>/dev/null
$IPT -t mangle -F ZAPRET2_INPUT 2>/dev/null
$IPT -t mangle -X ZAPRET2_INPUT 2>/dev/null

$IPT -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null
$IPT -t filter -F ZAPRET2_FILTER 2>/dev/null
$IPT -t filter -X ZAPRET2_FILTER 2>/dev/null

$IP6T -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null
$IP6T -t mangle -F ZAPRET2_MANGLE 2>/dev/null
$IP6T -t mangle -X ZAPRET2_MANGLE 2>/dev/null

$IP6T -t mangle -D INPUT -j ZAPRET2_INPUT 2>/dev/null
$IP6T -t mangle -F ZAPRET2_INPUT 2>/dev/null
$IP6T -t mangle -X ZAPRET2_INPUT 2>/dev/null

$IP6T -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null
$IP6T -t filter -F ZAPRET2_FILTER 2>/dev/null
$IP6T -t filter -X ZAPRET2_FILTER 2>/dev/null

rm -f /tmp/zapret2_apps_cache.json 2>/dev/null
rm -f /tmp/zapret2_apps_new.json 2>/dev/null
