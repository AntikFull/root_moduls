#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
CONF_FILE="$MODDIR/zapret2.conf"
RUN_DIR="$MODDIR/run"
LOG_DIR="$MODDIR/logs"
SERVICE_LOG="$LOG_DIR/zapret2_debug.log"
NFQWS_LOG="$LOG_DIR/zapret2_nfqws.log"
OUT="$LOG_DIR/zapret2_diagnostics_latest.txt"
EXPORT_DIR="/sdcard/eCubz"
mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null
chmod 0700 "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true

IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables
IPT_SAVE=$(command -v iptables-save 2>/dev/null); [ -n "$IPT_SAVE" ] || IPT_SAVE=/system/bin/iptables-save
IP=$(command -v ip 2>/dev/null); [ -n "$IP" ] || IP=/system/bin/ip

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
pid_cmdline() { tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
pid_owned() {
  local pid="$1" kind="$2" cmd comm cwd
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  case "$kind" in
    nfqws2) comm=$(cat "/proc/$pid/comm" 2>/dev/null); cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null); [ "$comm" = nfqws2 ] && [ "$cwd" = "$MODDIR/bin" ] ;;
    config) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/on_change.sh" ;;
    vpn) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/vpn-watch.sh" ;;
    health) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/service-watch.sh" ;;
    auto) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/auto-select.sh" ;;
    service) cmd=$(pid_cmdline "$pid"); printf '%s' "$cmd" | grep -Fq "$MODDIR/service.sh" ;;
    *) return 1 ;;
  esac
}

{
  echo "Zapret2 eCubz diagnostics"
  echo "Privacy: contains installed package names, network/routing state and logs; nfqws debug may contain domains/packet metadata if it was enabled."
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Module: $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1) code=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)"

  section "BINARY PROVENANCE"
  cat "$MODDIR/BINARY_MANIFEST.txt" 2>&1
  echo "-- installed selected-ABI files --"
  if command -v sha256sum >/dev/null 2>&1; then
    for bf in "$MODDIR/bin/nfqws2" "$MODDIR/bin/ip2net" "$MODDIR/bin/mdig" "$MODDIR/bin/zapret-lib.lua" "$MODDIR/bin/zapret-antidpi.lua" "$MODDIR/bin/zapret-auto.lua"; do
      [ -f "$bf" ] && sha256sum "$bf"
    done
  else
    echo "sha256sum unavailable"
  fi

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
  section "SMART STRATEGY RESOLUTION"
  if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; fi
  strategy_effective=$(sed -n 's/^STRATEGY_EFFECTIVE=//p' "$RUN_DIR/health.env" 2>/dev/null | head -n1)
  [ -n "$strategy_effective" ] || strategy_effective=${STRATEGY_MODE:-SMART}
  youtube_count=$(grep -cvE '^[[:space:]]*(#|$)' "$MODDIR/smart_youtube.list" 2>/dev/null || echo 0)
  auto_count=$(grep -cvE '^[[:space:]]*(#|$)' "$MODDIR/auto_apps.list" 2>/dev/null || echo 0)
  manual_count=$(grep -cvE '^[[:space:]]*(#|$)' "$MODDIR/apps.list" 2>/dev/null || echo 0)
  echo "STRATEGY_MODE=${STRATEGY_MODE:-SMART}"
  echo "STRATEGY_EFFECTIVE=$strategy_effective"
  echo "AUTO_APPS_ENABLED=${AUTO_APPS_ENABLED:-1}"
  echo "AUTO_APPS_CATALOG_COUNT=$auto_count"
  echo "MANUAL_APPS_COUNT=$manual_count"
  echo "SMART_YOUTUBE_DOMAINS=$youtube_count"
  case "$strategy_effective" in
    SMART_NATIVE) echo "SMART_ENGINE_EFFECT=adaptive circular service profiles with bounded incoming reply-feed" ;;
    SMART_COMPAT) echo "SMART_ENGINE_EFFECT=automatic service profiles without incoming bulk/reply-feed" ;;
    CUSTOM) echo "SMART_ENGINE_EFFECT=expert CUSTOM profile" ;;
    *) echo "SMART_ENGINE_EFFECT=unknown/legacy" ;;
  esac
  section "STARTUP STATE"
  cat "$RUN_DIR/startup.env" 2>&1
  late_start_pid=$(cat "$RUN_DIR/late-start.pid" 2>/dev/null)
  echo "late_start_pid=${late_start_pid:-none}"
  if [ -n "$late_start_pid" ] && pid_owned "$late_start_pid" service; then echo "late_start_alive=1 owned=1"; else echo "late_start_alive=0 owned=0"; fi
  echo "-- boot trace --"
  tail -n 80 "$RUN_DIR/boot-trace.log" 2>/dev/null || true

  section "LOGGING / STORAGE"
  echo "internal_log_dir=$LOG_DIR"
  ls -ld "$LOG_DIR" 2>&1
  ls -l "$SERVICE_LOG" "$NFQWS_LOG" 2>&1 || true
  echo "external_export_dir=$EXPORT_DIR"
  mount 2>/dev/null | grep -E '(/sdcard|/storage/emulated)' | head -n 20 || true
  if mkdir -p "$EXPORT_DIR" 2>/dev/null && testfile="$EXPORT_DIR/.zapret2-write-test.$$" && : > "$testfile" 2>/dev/null; then
    rm -f "$testfile" 2>/dev/null
    echo "external_export_writable=1"
  else
    echo "external_export_writable=0"
  fi
  if command -v setsid >/dev/null 2>&1; then echo "setsid=command"; elif command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then echo "setsid=busybox"; elif command -v toybox >/dev/null 2>&1 && toybox setsid true >/dev/null 2>&1; then echo "setsid=toybox"; else echo "setsid=unavailable"; fi

  section "RUNTIME FILES / WATCHERS"
  echo "watch_mode=event-driven"
  echo "control_loop_sec=${VPN_WATCH_INTERVAL:-2}"
  echo "role_safety_recheck_sec=${VPN_ROLE_RECHECK:-30}"
  echo "event_debounce_sec=${VPN_EVENT_DEBOUNCE:-2}"
  echo "netlink_monitor=${VPN_NETLINK_MONITOR:-1}"
  echo "rule_verify_sec=${VPN_VERIFY_INTERVAL:-60}"
  echo "legacy_VPN_STATE_RECHECK=${VPN_STATE_RECHECK:-unset} (not used by hot loop)"
  ls -ld "$RUN_DIR" 2>&1
  ls -la "$RUN_DIR" 2>&1
  for pf in nfqws2.pid watcher.pid vpn-watcher.pid health-watcher.pid auto-probe.pid auto-test-nfqws.pid late-start.pid; do
    wp=$(cat "$RUN_DIR/$pf" 2>/dev/null)
    alive=0; owned=0; kind=""
    case "$pf" in nfqws2.pid|auto-test-nfqws.pid) kind=nfqws2 ;; watcher.pid) kind=config ;; vpn-watcher.pid) kind=vpn ;; health-watcher.pid) kind=health ;; auto-probe.pid) kind=auto ;; late-start.pid) kind=service ;; esac
    case "$wp" in ''|0|*[!0-9]*) ;; *) kill -0 "$wp" 2>/dev/null && alive=1; pid_owned "$wp" "$kind" && owned=1 ;; esac
    echo "$pf=${wp:-none} alive=$alive owned=$owned"
  done
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) recorded_boot_id=$(cat "$RUN_DIR/boot.id" 2>/dev/null)"
  echo "-- active AUTO result --"
  cat "$RUN_DIR/auto-current.env" 2>&1
  echo "-- active AUTO cache --"
  for cache in "$MODDIR"/state/auto-*.env; do
    [ -f "$cache" ] || continue
    echo "[$cache]"
    cat "$cache" 2>&1
  done
  echo "-- current role signature --"
  [ -x "$MODDIR/net-role.sh" ] && "$MODDIR/net-role.sh" role-signature 2>&1
  echo
  echo "-- tether verify --"
  [ -x "$MODDIR/tether-sync.sh" ] && "$MODDIR/tether-sync.sh" verify >/dev/null 2>&1 && echo "tether_rules=OK" || echo "tether_rules=DRIFT/NOT_READY"
  echo "-- vpn verify --"
  [ -x "$MODDIR/vpn-routing.sh" ] && "$MODDIR/vpn-routing.sh" verify >/dev/null 2>&1 && echo "vpn_rules=OK" || echo "vpn_rules=DRIFT/NOT_READY"

  section "PACKAGE UID RESOLUTION"
  echo "-- Android users --"
  cmd user list 2>&1 || true
  echo "-- cache entries by user --"
  awk '{c[$3]++} END{for(u in c) print u,c[u]}' "$RUN_DIR/package_uids.cache" 2>/dev/null | sort -n | awk '{print "user"$1"="$2}'
  echo "cache_lines=$(wc -l < "$RUN_DIR/package_uids.cache" 2>/dev/null | tr -d ' ')"
  echo "-- AUTO catalog apps that are installed/resolved --"
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    uids=$(awk -v p="$pkg" '$1==p {printf "%s(user%s) ",$2,$3}' "$RUN_DIR/package_uids.cache" 2>/dev/null)
    [ -n "$uids" ] && echo "$pkg -> $uids"
  done < "$MODDIR/auto_apps.list"
  echo "-- manual apps.list additions --"
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in ''|\#*) continue ;; esac
    printf '%s -> ' "$pkg"
    awk -v p="$pkg" '$1==p {printf "%s(user%s) ",$2,$3}' "$RUN_DIR/package_uids.cache" 2>/dev/null
    echo
  done < "$MODDIR/apps.list"
  echo "-- excludes that are installed/resolved (highest priority) --"
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
    printf 'session: '; awk '{printf "ppid=%s pgrp=%s sid=%s\n",$4,$5,$6}' "/proc/$pid/stat" 2>/dev/null
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
  echo "-- vpn-routing.meta --"
  cat "$RUN_DIR/vpn-routing.meta" 2>&1
  echo "-- tether-runtime.conf --"
  cat "$RUN_DIR/tether-runtime.conf" 2>&1
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

chmod 0600 "$OUT" 2>/dev/null
if mkdir -p "$EXPORT_DIR" 2>/dev/null && cp -f "$OUT" "$EXPORT_DIR/zapret2_diagnostics_latest.txt" 2>/dev/null; then
  chmod 0644 "$EXPORT_DIR/zapret2_diagnostics_latest.txt" 2>/dev/null || true
  [ -x "$MODDIR/log-export.sh" ] && sh "$MODDIR/log-export.sh" now >/dev/null 2>&1 || true
  echo "$EXPORT_DIR/zapret2_diagnostics_latest.txt"
else
  echo "$OUT"
fi
