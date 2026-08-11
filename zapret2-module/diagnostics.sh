#!/system/bin/sh
# Runtime diagnostics for Zapret2 eCubz. This script does not start packet capture.
# If NFQWS_DEBUG was enabled, its existing debug log may contain domains/packet metadata.

MODDIR="${0%/*}"
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
LOG_DIR="/sdcard/eCubz"
SERVICE_LOG="$LOG_DIR/zapret2_debug.log"
NFQWS_LOG="$LOG_DIR/zapret2_nfqws.log"
OUT="$LOG_DIR/zapret2_diagnostics_latest.txt"
mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null

IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables
IPT_SAVE=$(command -v iptables-save 2>/dev/null); [ -n "$IPT_SAVE" ] || IPT_SAVE=/system/bin/iptables-save
IP=$(command -v ip 2>/dev/null); [ -n "$IP" ] || IP=/system/bin/ip

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }

{
  echo "Zapret2 eCubz diagnostics"
  echo "Privacy: contains installed package names, network/routing state and logs; nfqws debug may contain domains/packet metadata if it was enabled."
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Module: $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1) code=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)"

  section "DEVICE"
  echo "brand=$(getprop ro.product.brand 2>/dev/null)"
  echo "manufacturer=$(getprop ro.product.manufacturer 2>/dev/null)"
  echo "model=$(getprop ro.product.model 2>/dev/null)"
  echo "device=$(getprop ro.product.device 2>/dev/null)"
  echo "android=$(getprop ro.build.version.release 2>/dev/null) sdk=$(getprop ro.build.version.sdk 2>/dev/null)"
  echo "fingerprint=$(getprop ro.build.fingerprint 2>/dev/null)"
  run uname -a
  run id
  command -v getenforce >/dev/null 2>&1 && run getenforce
  echo "boot_completed=$(getprop sys.boot_completed 2>/dev/null)"

  section "ROOT / MODULES"
  if command -v magisk >/dev/null 2>&1; then run magisk -v; run magisk -V; fi
  [ -d /data/adb/ksu ] && echo "KernelSU directory present: /data/adb/ksu"
  [ -d /data/adb/ap ] && echo "APatch directory present: /data/adb/ap"
  for p in /data/adb/modules/*/module.prop; do
    [ -f "$p" ] || continue
    d=${p%/module.prop}
    idm=$(sed -n 's/^id=//p' "$p" | head -n1)
    nam=$(sed -n 's/^name=//p' "$p" | head -n1)
    ver=$(sed -n 's/^version=//p' "$p" | head -n1)
    state=enabled; [ -f "$d/disable" ] && state=disabled; [ -f "$d/remove" ] && state=remove
    echo "$idm | $ver | $state | $nam"
  done

  section "CONFIG"
  cat "$CONF_FILE" 2>&1
  section "HEALTH"
  cat "$RUN_DIR/health.env" 2>&1
  echo "package_source=$(cat "$RUN_DIR/package_source" 2>/dev/null)"

  section "PACKAGE UID RESOLUTION"
  echo "cache_lines=$(wc -l < "$RUN_DIR/package_uids.cache" 2>/dev/null | tr -d ' ')"
  echo "-- selected apps --"
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    printf '%s -> ' "$pkg"
    awk -v p="$pkg" '$1==p {printf "%s(user%s) ",$2,$3}' "$RUN_DIR/package_uids.cache" 2>/dev/null
    echo
  done < "$MODDIR/apps.list"
  echo "-- excludes that are installed/resolved --"
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    uids=$(awk -v p="$pkg" '$1==p {printf "%s(user%s) ",$2,$3}' "$RUN_DIR/package_uids.cache" 2>/dev/null)
    [ -n "$uids" ] && echo "$pkg -> $uids"
  done < "$MODDIR/exclude.list"
  run pm list packages -U --user 0
  run cmd package list packages -U --user 0

  section "FIREWALL CAPABILITIES"
  echo "nf_conntrack_acct_sysctl=$(cat /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null || echo unavailable)"
  echo "runtime_probe_acct=$(sed -n 's/^CONNTRACK_ACCT=//p' "$RUN_DIR/health.env" 2>/dev/null | head -n1)"
  echo "runtime_probe_connmark4=$(sed -n 's/^CONNMARK4=//p' "$RUN_DIR/health.env" 2>/dev/null | head -n1)"
  echo "runtime_probe_connbytes4=$(sed -n 's/^CONNBYTES4=//p' "$RUN_DIR/health.env" 2>/dev/null | head -n1)"
  [ -x "$IPT" ] && run "$IPT" -V
  [ -x "$IP6T" ] && run "$IP6T" -V
  [ -r /proc/config.gz ] && {
    echo "-- kernel config --"
    gzip -cd /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(NETFILTER_NETLINK_QUEUE|NETFILTER_XT_TARGET_NFQUEUE|NETFILTER_XT_MATCH_OWNER|NETFILTER_XT_MATCH_CONNBYTES|NETFILTER_XT_TARGET_CONNMARK|NETFILTER_XT_MATCH_CONNMARK|NF_CONNTRACK|NF_TABLES|IP_NF_IPTABLES|IP6_NF_IPTABLES)=' || true
  }

  section "ZAPRET2 IPTABLES IPv4"
  [ -x "$IPT" ] && {
    run "$IPT" -w 5 -t mangle -L ZAPRET2_MANGLE -nvx --line-numbers
    run "$IPT" -w 5 -t mangle -L ZAPRET2_MANGLE_IN -nvx --line-numbers
    run "$IPT" -w 5 -t filter -L ZAPRET2_FILTER -nvx --line-numbers
    run "$IPT" -w 5 -t mangle -L ZAPRET2_MANGLE_FORWARD -nvx --line-numbers
    run "$IPT" -w 5 -t filter -L ZAPRET2_FILTER_FORWARD -nvx --line-numbers
    run "$IPT" -w 5 -t nat -L ZAPRET2_NAT_PREROUTING -nvx --line-numbers
    run "$IPT" -w 5 -t nat -L ZAPRET2_VPN_NAT -nvx --line-numbers
    run "$IPT" -w 5 -t filter -L ZAPRET2_VPN_FORWARD -nvx --line-numbers
    echo "-- builtin hook counters --"
    run "$IPT" -w 5 -t mangle -L INPUT -nvx --line-numbers
    run "$IPT" -w 5 -t mangle -L FORWARD -nvx --line-numbers
    run "$IPT" -w 5 -t filter -L FORWARD -nvx --line-numbers
    run "$IPT" -w 5 -t nat -L PREROUTING -nvx --line-numbers
    run "$IPT" -w 5 -t nat -L POSTROUTING -nvx --line-numbers
    echo "-- hooks containing ZAPRET2 --"
    [ -x "$IPT_SAVE" ] && "$IPT_SAVE" 2>/dev/null | grep ZAPRET2 || true
  }

  section "ZAPRET2 IPTABLES IPv6"
  [ -x "$IP6T" ] && {
    run "$IP6T" -w 5 -t mangle -L ZAPRET2_MANGLE -nvx --line-numbers
    run "$IP6T" -w 5 -t mangle -L ZAPRET2_MANGLE_IN -nvx --line-numbers
    run "$IP6T" -w 5 -t filter -L ZAPRET2_FILTER -nvx --line-numbers
    run "$IP6T" -w 5 -t mangle -L ZAPRET2_MANGLE_FORWARD -nvx --line-numbers
    run "$IP6T" -w 5 -t filter -L ZAPRET2_FILTER_FORWARD -nvx --line-numbers
  }

  section "NFQUEUE / PROCESS"
  cat /proc/net/netfilter/nfnetlink_queue 2>&1
  pid=$(cat "$RUN_DIR/nfqws2.pid" 2>/dev/null)
  echo "nfqws_pid=$pid"
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    printf 'cmdline='; tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null; echo
    printf 'status:\n'; grep -E '^(Name|State|Pid|PPid|Uid|Gid|VmRSS|Threads):' "/proc/$pid/status" 2>/dev/null
  fi
  ps -A -o PID,PPID,USER,NAME,ARGS 2>/dev/null | grep -E 'nfqws|nfqttl|vpn|tether|proxy' || ps -A 2>/dev/null | grep -E 'nfqws|nfqttl|vpn|tether|proxy' || true

  section "ROUTING / TETHERING"
  run "$IP" rule show
  run "$IP" route show table all
  run "$IP" -o link show
  run "$IP" -o -4 addr show
  run "$IP" -o -6 addr show
  run "$IP" route get 1.1.1.1
  echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  echo "-- vpn fallback policy --"
  sed -n 's/^VPN_FALLBACK_MODE=/VPN_FALLBACK_MODE=/p; s/^ENABLE_VPN_HOTSPOT=/ENABLE_VPN_HOTSPOT=/p' "$CONF_FILE" 2>/dev/null
  echo "-- strict network roles --"
  [ -x "$MODDIR/net-role.sh" ] && "$MODDIR/net-role.sh" roles 2>&1
  echo "-- Android tether current states --"
  [ -x "$MODDIR/net-role.sh" ] && "$MODDIR/net-role.sh" tether-states 2>&1
  echo "-- dynamic tether-downstreams.state --"
  cat "$RUN_DIR/tether-downstreams.state" 2>&1
  echo "-- vpn-routing.state --"
  cat "$RUN_DIR/vpn-routing.state" 2>&1
  echo "-- Zapret2 VPN private table --"
  VPN_ROUTE_TABLE=$(sed -n 's/^VPN_ROUTE_TABLE="\([0-9][0-9]*\)"/\1/p' "$CONF_FILE" 2>/dev/null | head -n1)
  [ -n "$VPN_ROUTE_TABLE" ] || VPN_ROUTE_TABLE=11999
  run "$IP" -4 route show table "$VPN_ROUTE_TABLE"
  run "$IP" -6 route show table "$VPN_ROUTE_TABLE"
  [ -x "$IPT" ] && run "$IPT" -w 5 -t filter -L ZAPRET2_VPN_FORWARD -nvx --line-numbers
  [ -x "$IPT" ] && run "$IPT" -w 5 -t nat -L ZAPRET2_VPN_NAT -nvx --line-numbers
  [ -x "$IP6T" ] && run "$IP6T" -w 5 -t filter -L ZAPRET2_VPN_FORWARD -nvx --line-numbers
  echo "-- /data/misc/net/rt_tables --"
  cat /data/misc/net/rt_tables 2>&1
  echo "-- dumpsys tethering (trimmed) --"
  dumpsys tethering 2>&1 | head -n 800
  echo "-- connectivity VPN/tether lines --"
  dumpsys connectivity 2>&1 | grep -Ei 'VPN|TUN|TETHER|TRANSPORT_VPN|InterfaceName|LinkAddresses|Routes' | head -n 600

  section "SERVICE LOG (last 500)"
  tail -n 500 "$SERVICE_LOG" 2>&1
  section "NFQWS DEBUG LOG (last 500)"
  tail -n 500 "$NFQWS_LOG" 2>&1

  section "KERNEL / LOGCAT NETWORK ERRORS"
  dmesg 2>/dev/null | tail -n 1500 | grep -Ei 'nfqueue|netfilter|iptables|ip6tables|xt_owner|avc: denied|nfqws|zapret' | tail -n 300 || true
  logcat -d -t 1500 2>/dev/null | grep -Ei 'nfqueue|netfilter|iptables|ip6tables|avc: denied|nfqws|zapret|KernelSU' | tail -n 400 || true
} > "$OUT" 2>&1

chmod 0644 "$OUT" 2>/dev/null
echo "$OUT"
