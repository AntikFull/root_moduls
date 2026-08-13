#!/system/bin/sh
MODDIR=${0%/*}

LOGFILE="$MODDIR/nfqttl_debug.log"
exec > "$LOGFILE" 2>&1

echo "=================================================================="
echo " Nfqttl eCubz Deep Diagnostic & Trace Log"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================================="
echo ""

echo "--- 1. MODULE & SYSTEM METADATA ---"
if [ -f "$MODDIR/module.prop" ]; then
    cat "$MODDIR/module.prop"
    echo "" # Гарантированный перевод строки
else
    echo "module.prop NOT FOUND"
fi

# Проверка "протухшего" состояния сервиса без перезагрузки
APPLIED_VER="Неизвестно"
if [ -f "$MODDIR/.applied_version" ]; then
    APPLIED_VER=$(cat "$MODDIR/.applied_version" | tr -d '\r')
fi
CURRENT_VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)

echo "Applied Active Version: $APPLIED_VER"
if [ "$APPLIED_VER" != "Неизвестно" ] && [ -n "$CURRENT_VER" ] && ! echo "$APPLIED_VER" | grep -q "$CURRENT_VER"; then
    echo "⚠️ [ВНИМАНИЕ] Версия на диске ($CURRENT_VER) отличается от активной в памяти ($APPLIED_VER)! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА УСТРОЙСТВА!"
fi

# Проверка устаревших правила catch-all (!lo)
if iptables -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -q "!lo"; then
    echo "⚠️ [ВНИМАНИЕ] В iptables висит устаревшее правило !lo — служба v7.5 еще не перезапущена! Сделайте reboot."
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
echo ""

echo "--- 5. ACTIVE NETWORK INTERFACES ---"
ip link show
echo ""

echo "--- 6. IP FORWARDING & TETHER OFFLOAD SETTINGS ---"
echo "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
echo "net.ipv6.conf.all.disable_ipv6 = $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)"
echo "net.ipv6.conf.all.forwarding = $(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)"

OFFLOAD_DISABLED=$(/system/bin/settings get global tether_offload_disabled 2>/dev/null || settings get global tether_offload_disabled 2>/dev/null || echo "null")
echo "tether_offload_disabled = $OFFLOAD_DISABLED"

OVERRIDE_BPF=$(/system/bin/device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null || device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null || echo "null")
echo "override_tether_enable_bpf_offload = $OVERRIDE_BPF"
echo ""

echo "--- 7. IPTABLES MANGLE & NAT RULES WITH PACKET COUNTERS ---"
echo "[IPv4 Mangle PREROUTING]"
iptables -t mangle -L PREROUTING -n -v 2>/dev/null
echo "[IPv4 Mangle FORWARD]"
iptables -t mangle -L FORWARD -n -v 2>/dev/null
echo "[IPv4 Mangle POSTROUTING]"
iptables -t mangle -L POSTROUTING -n -v 2>/dev/null

# Проверка дублей правил
NFQ_COUNT=$(iptables -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -c "nfqttlo" || echo 0)
if [ "$NFQ_COUNT" -gt 25 ]; then
    echo "⚠️ [ВНИМАНИЕ] Обнаружено накопление дубликатов правил nfqttlo ($NFQ_COUNT шт) в IPv4 POSTROUTING!"
fi

echo "[IPv4 Mangle NFQTTL CHAINS]"
for _ch in nfqttlp nfqttlo nfqttlb nfqttlc nfqttlm; do
    echo "-- $_ch --"
    iptables -t mangle -L "$_ch" -n -v 2>/dev/null
done
echo "[IPv4 Filter NFQTTLF CHAIN]"
iptables -t filter -L nfqttlf -n -v 2>/dev/null
echo "[IPv4 NAT PREROUTING (DNS REDIRECT)]"
iptables -t nat -L PREROUTING -n -v 2>/dev/null
echo ""

echo "--- 8. IP6TABLES RULES WITH PACKET COUNTERS ---"
echo "[IPv6 Mangle FORWARD]"
ip6tables -t mangle -L FORWARD -n -v 2>/dev/null
echo "[IPv6 Mangle POSTROUTING]"
ip6tables -t mangle -L POSTROUTING -n -v 2>/dev/null

IP6_NFQ_COUNT=$(ip6tables -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -c "nfqttlo" || echo 0)
if [ "$IP6_NFQ_COUNT" -gt 25 ]; then
    echo "⚠️ [ВНИМАНИЕ] Обнаружено накопление дубликатов правил nfqttlo ($IP6_NFQ_COUNT шт) в IPv6 POSTROUTING!"
fi

echo "[IPv6 Mangle NFQTTL CHAINS]"
for _ch in nfqttlp nfqttlo nfqttlb nfqttlc nfqttlm; do
    echo "-- $_ch --"
    ip6tables -t mangle -L "$_ch" -n -v 2>/dev/null
done
echo "[IPv6 Filter NFQTTLF CHAIN]"
ip6tables -t filter -L nfqttlf -n -v 2>/dev/null

echo "[NFQUEUE STATE] (queue peer_portid queue_total copy_mode copy_range queue_dropped user_dropped id_seq)"
cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null || echo "nfnetlink_queue NOT AVAILABLE"
echo "[IPv6 NAT PREROUTING (DNS REDIRECT)]"
ip6tables -t nat -L PREROUTING -n -v 2>/dev/null
echo ""

echo "--- 9. CUSTOM BLOCKLIST CONFIGURATION ---"
if [ -f "$MODDIR/blocklist.txt" ]; then
    cat "$MODDIR/blocklist.txt"
else
    echo "blocklist.txt NOT FOUND"
fi
echo ""

echo "--- 10. WATCHDOG & DAEMON ERROR LOGS ---"
WD_LOG=/data/local/tmp/nfqttl_watchdog.log
if [ -f "$WD_LOG" ]; then
    tail -n 20 "$WD_LOG"
else
    echo "No watchdog log file found at $WD_LOG"
fi
echo ""

echo "--- 11. BLOCKED SUSPICIOUS TRAFFIC TRACE (DMESG) ---"
dmesg 2>/dev/null | grep -E "NFQTTL-BLOCK|NFQTTL-NTP-BLOCK" | tail -n 20 || echo "No suspicious traffic trace found in kernel dmesg log"
echo ""

echo "=================================================================="
echo " Deep Diagnostic Report Complete: $LOGFILE"
echo "=================================================================="

# дамп правил — незачем отдавать его на чтение и запись кому попало.
chmod 600 "$LOGFILE" 2>/dev/null || true
