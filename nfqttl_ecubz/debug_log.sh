#!/system/bin/sh
# Nfqttl eCubz — Скрипт углубленной диагностики
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}

LOG_DIR="$MODDIR/logs"
SD_LOG_DIR="/sdcard/eCubz/logs/nfqttl_ecubz"
mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$SD_LOG_DIR" 2>/dev/null || true

LOGFILE="$LOG_DIR/nfqttl_debug.log"
exec > "$LOGFILE" 2>&1

echo "=================================================================="
echo " Nfqttl eCubz Deep Diagnostic & Trace Log"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================================="
echo ""

echo "--- 1. MODULE & SYSTEM METADATA ---"
if [ -f "$MODDIR/module.prop" ]; then
    cat "$MODDIR/module.prop"
    echo ""
else
    echo "module.prop NOT FOUND"
fi

APPLIED_VER="Неизвестно"
if [ -f "$MODDIR/.applied_version" ]; then
    APPLIED_VER=$(cat "$MODDIR/.applied_version" | tr -d '\r')
fi
CURRENT_VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)

echo "Applied Active Version: $APPLIED_VER"
if [ "$APPLIED_VER" != "Неизвестно" ] && [ -n "$CURRENT_VER" ] && ! echo "$APPLIED_VER" | grep -Fq "$CURRENT_VER"; then
    echo "[ВНИМАНИЕ] Версия на диске ($CURRENT_VER) отличается от активной в памяти ($APPLIED_VER)! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА УСТРОЙСТВА!"
fi

echo "Device Model: $(getprop ro.product.model)"
echo "Android Release: $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
echo "CPU ABI: $(getprop ro.product.cpu.abi)"
echo "Kernel: $(uname -a)"
echo "SELinux Mode: $(getenforce 2>/dev/null || echo 'Unknown')"
echo ""

echo "--- 2. DAEMON BINARY & STARTUP DIAGNOSTICS ---"
BIN_PATH="$MODDIR/nfqttl"
if [ -f "$BIN_PATH" ]; then
    if [ -x "$BIN_PATH" ]; then
        echo "Binary exists: $BIN_PATH (Executable)"
    else
        echo "Binary exists: $BIN_PATH (NOT EXECUTABLE!)"
    fi
    ls -l "$BIN_PATH"
    _native_ver=$("$BIN_PATH" -h 2>&1 | head -n 1)
    [ -n "$_native_ver" ] && echo "Native CLI: $_native_ver"
    if command -v sha256sum >/dev/null 2>&1; then
        echo "Binary SHA-256: $(sha256sum "$BIN_PATH" 2>/dev/null | awk '{print $1}')"
    fi
else
    echo "Binary NOT FOUND: $BIN_PATH"
fi
echo ""

echo "--- 3. KERNEL NETFILTER CAPABILITIES ---"
echo "IPv4 Targets: $(cat /proc/net/ip_tables_targets 2>/dev/null | tr '\n' ' ')"
echo "IPv6 Targets: $(cat /proc/net/ip6_tables_targets 2>/dev/null | tr '\n' ' ')"
echo "Netfilter Matches: $(cat /proc/net/ip_tables_matches 2>/dev/null | tr '\n' ' ')"
echo ""

echo "--- 4. ACTIVE PROCESSES & NFQUEUE SEARCH ---"
ps -A 2>/dev/null | grep -E "nfqttl|magisk|ksu|apatch" || ps 2>/dev/null | grep -E "nfqttl|magisk|ksu|apatch"
if [ -f "$MODDIR/.watchdog.pid" ]; then
    read -r _wpid < "$MODDIR/.watchdog.pid" 2>/dev/null || _wpid=""
    echo "Worker PID file: $_wpid"
    [ -n "$_wpid" ] && [ -r "/proc/$_wpid/cmdline" ] && {
        echo -n "Worker cmdline: "
        tr '\000' ' ' < "/proc/$_wpid/cmdline" 2>/dev/null
        echo ""
    }
else
    echo "Worker PID file: NOT FOUND"
fi
echo ""

echo "--- 5. ACTIVE NETWORK INTERFACES ---"
ip link show
echo ""

echo "--- 6. IP FORWARDING & TETHER OFFLOAD SETTINGS ---"
echo "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
echo "net.ipv6.conf.all.disable_ipv6 = $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)"
echo "net.ipv6.conf.all.forwarding = $(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)"
echo "net.ipv4.conf.all.rp_filter = $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)"

OFFLOAD_DISABLED=$(/system/bin/settings get global tether_offload_disabled 2>/dev/null || settings get global tether_offload_disabled 2>/dev/null || echo "null")
echo "tether_offload_disabled = $OFFLOAD_DISABLED"

OVERRIDE_BPF=$(/system/bin/device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null || device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null || echo "null")
echo "override_tether_enable_bpf_offload = $OVERRIDE_BPF"
echo ""

echo "--- 7. ROUTING & NETFILTER BACKEND ---"
echo "iptables: $(iptables -V 2>/dev/null)"
echo "ip6tables: $(ip6tables -V 2>/dev/null)"
echo "[IPv4 routes]"
ip route show table all 2>/dev/null
echo "[IPv6 routes]"
ip -6 route show table all 2>/dev/null
echo "[Policy rules]"
ip rule show 2>/dev/null
ip -6 rule show 2>/dev/null
echo ""

echo "--- 8. IPTABLES MANGLE, NAT & FILTER RULES ---"
echo "[IPv4 Mangle PREROUTING]"
iptables -t mangle -L PREROUTING -n -v 2>/dev/null
echo "[IPv4 Mangle FORWARD]"
iptables -t mangle -L FORWARD -n -v 2>/dev/null
echo "[IPv4 Mangle POSTROUTING]"
iptables -t mangle -L POSTROUTING -n -v 2>/dev/null

echo "[IPv4 Mangle NFQTTL CHAINS]"
for _ch in nfqttlp nfqttlo nfqttlb nfqttlc nfqttlm nfqttlq; do
    echo "-- $_ch --"
    iptables -t mangle -L "$_ch" -n -v 2>/dev/null
done
echo "[IPv4 Filter NFQTTLF & NFQTTLFWD CHAINS]"
iptables -t filter -L nfqttlf -n -v 2>/dev/null
iptables -t filter -L nfqttlfwd -n -v 2>/dev/null
echo "[IPv4 NAT POSTROUTING (MASQUERADE)]"
iptables -t nat -L POSTROUTING -n -v 2>/dev/null
iptables -t nat -L nfqttlnat -n -v 2>/dev/null
echo ""

echo "--- 8.1 AUTO VPN TETHERING STATUS & RULES ---"
if [ -f "$MODDIR/.vpn_tether_status" ]; then
    echo "Status: $(cat "$MODDIR/.vpn_tether_status")"
else
    echo "Status: Direct (VPN Tethering inactive)"
fi
if [ -f "$MODDIR/.vpn_tether_rules" ]; then
    echo "Active module-owned VPN state:"
    cat "$MODDIR/.vpn_tether_rules"
    _dbg_vpn_tbl=$(awk -F'|' '$1 == "ROUTE4" && $2 != "" {print $2; exit}' "$MODDIR/.vpn_tether_rules" 2>/dev/null)
    if [ -n "$_dbg_vpn_tbl" ]; then
        echo "[Module-owned tether routing table: $_dbg_vpn_tbl]"
        ip route show table "$_dbg_vpn_tbl" 2>/dev/null
    fi
fi
echo "[VPN FORWARD, NAT & IPv6 Chains]"
iptables -t filter -L nfqttl_vpn_fwd -n -v 2>/dev/null
iptables -t nat -L nfqttl_vpn_nat -n -v 2>/dev/null
iptables -t nat -L nfqttl_vpn_dns -n -v 2>/dev/null
ip6tables -t filter -L nfqttl_vpn6_fwd -n -v 2>/dev/null
echo ""

echo "--- 8.2 ENGINE INTEGRITY & HEALTH CHECK ---"
_eng_status="UNKNOWN"
_v4_rules=$(iptables -t mangle -S nfqttlo 2>/dev/null | grep -c "TTL --ttl-set")
_v6_rules=$(ip6tables -t mangle -S nfqttlo 2>/dev/null | grep -c "HL --hl-set")
_nfq_bound=0
if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    while read -r _q _rest; do
        [ "$_q" = "6464" ] && { _nfq_bound=1; break; }
    done < /proc/net/netfilter/nfnetlink_queue
fi

if [ "$_v4_rules" -gt 0 ] || [ "$_v6_rules" -gt 0 ]; then
    echo "IPv4 Native TTL Rule: $([ "$_v4_rules" -gt 0 ] && echo 'ACTIVE' || echo 'INACTIVE')"
    echo "IPv6 Native HL Rule: $([ "$_v6_rules" -gt 0 ] && echo 'ACTIVE' || echo 'INACTIVE')"
    if [ "$_nfq_bound" -eq 1 ] && { [ "$_v4_rules" -eq 0 ] || [ "$_v6_rules" -eq 0 ]; }; then
        echo "Engine Mode: MIXED NATIVE + NFQUEUE"
    else
        echo "Engine Mode: NATIVE KERNEL TARGETS"
    fi
elif [ "$_nfq_bound" -eq 1 ]; then
    echo "NFQUEUE Queue 6464: BOUND & ACTIVE"
    echo "Engine Mode: NFQUEUE USERSPACE DAEMON"
else
    echo "Engine Mode: [WARNING] NO ACTIVE TTL FIX ENGINE DETECTED!"
fi

_owned_rules=0
[ -f "$MODDIR/.vpn_tether_rules" ] && _owned_rules=$(grep -c '^RULE4|' "$MODDIR/.vpn_tether_rules" 2>/dev/null || echo 0)
echo "Module-owned VPN policy rules: $_owned_rules"
echo "Foreign/other pref 3000 rules (informational only): $(ip rule show 2>/dev/null | grep -c '^3000:')"
echo "Flags: ingressfix=$([ -f "$MODDIR/ingressfix" ] && echo 1 || echo 0) noquic=$([ -f "$MODDIR/noquic" ] && echo 1 || echo 0) no6=$([ -f "$MODDIR/no6" ] && echo 1 || echo 0) keep_offload=$([ -f "$MODDIR/keep_offload" ] && echo 1 || echo 0) dns_redirect=$([ -f "$MODDIR/dns_redirect" ] && echo 1 || echo 0)"
echo ""

echo "--- 9. IP6TABLES RULES WITH PACKET COUNTERS ---"
echo "[IPv6 Mangle FORWARD]"
ip6tables -t mangle -L FORWARD -n -v 2>/dev/null
echo "[IPv6 Mangle POSTROUTING]"
ip6tables -t mangle -L POSTROUTING -n -v 2>/dev/null

echo "[IPv6 Mangle NFQTTL CHAINS]"
for _ch in nfqttlp nfqttlo nfqttlb nfqttlc nfqttlm nfqttlq; do
    echo "-- $_ch --"
    ip6tables -t mangle -L "$_ch" -n -v 2>/dev/null
done
echo "[IPv6 Filter NFQTTLF & NFQTTLFWD CHAINS]"
ip6tables -t filter -L nfqttlf -n -v 2>/dev/null
ip6tables -t filter -L nfqttlfwd -n -v 2>/dev/null

echo "[NFQUEUE STATE] (queue peer_portid queue_total copy_mode copy_range queue_dropped user_dropped id_seq)"
cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null || echo "nfnetlink_queue NOT AVAILABLE"
if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    while read -r _q _peer _rest; do
        [ "$_q" = "6464" ] || continue
        echo "Queue 6464 peer_portid: $_peer"
    done < /proc/net/netfilter/nfnetlink_queue
fi
echo ""

echo "--- 10. CUSTOM BLOCKLIST CONFIGURATION ---"
if [ -f "$MODDIR/blocklist.txt" ]; then
    cat "$MODDIR/blocklist.txt"
else
    echo "blocklist.txt NOT FOUND"
fi
echo ""

echo "--- 11. WATCHDOG & DAEMON ERROR LOGS ---"
WD_LOG="$LOG_DIR/nfqttl_watchdog.log"
[ ! -f "$WD_LOG" ] && WD_LOG=/data/local/tmp/nfqttl_watchdog.log
if [ -f "$WD_LOG" ]; then
    tail -n 20 "$WD_LOG"
else
    echo "No watchdog log file found at $WD_LOG"
fi
echo ""

echo "--- 12. BLOCKED SUSPICIOUS TRAFFIC TRACE (DMESG) ---"
_trace=$(dmesg 2>/dev/null | grep -E "NFQTTL-BLOCK|NFQTTL-NTP-BLOCK" | tail -n 20)
if [ -n "$_trace" ]; then
    echo "$_trace"
else
    echo "No suspicious traffic trace found in kernel dmesg log"
fi
echo ""

echo "--- 13. STRUCTURAL WARNINGS ---"
_v4_fwd_policy=$(iptables -t filter -S FORWARD 2>/dev/null | head -n 1)
_v6_fwd_policy=$(ip6tables -t filter -S FORWARD 2>/dev/null | head -n 1)
echo "IPv4 FORWARD policy: $_v4_fwd_policy"
echo "IPv6 FORWARD policy: $_v6_fwd_policy"
echo "nfqttlfwd jumps (v4): $(iptables -t filter -S FORWARD 2>/dev/null | grep -c -- '-j nfqttlfwd')"
echo "nfqttlfwd jumps (v6): $(ip6tables -t filter -S FORWARD 2>/dev/null | grep -c -- '-j nfqttlfwd')"
echo "nfqttlq jumps (v4): $(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c -- '-j nfqttlq')"
echo "nfqttlq jumps (v6): $(ip6tables -t mangle -S POSTROUTING 2>/dev/null | grep -c -- '-j nfqttlq')"
echo ""

echo "=================================================================="
echo " Deep Diagnostic Report Complete: $LOGFILE"
echo "=================================================================="

chmod 600 "$LOGFILE" 2>/dev/null || true
if [ -d "$SD_LOG_DIR" ]; then
    cp -f "$LOGFILE" "$SD_LOG_DIR/nfqttl_debug.log" 2>/dev/null || true
fi
