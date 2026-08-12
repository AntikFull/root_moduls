#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

mkdir -p "$LOG_DIR" 2>/dev/null || true
PUBLIC_DIR="/sdcard/eCubz"
INTERNAL_LOG="$LOG_DIR/${MODULE_ID}_debug.log"
PUBLIC_LOG="$PUBLIC_DIR/${MODULE_ID}_debug.log"
TMP_LOG="$INTERNAL_LOG.tmp"

rm -f "$TMP_LOG" 2>/dev/null || true
exec > "$TMP_LOG" 2>&1

section() {
    echo ""
    echo "=================================================================="
    echo "$1"
    echo "=================================================================="
}

run_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 "$@"
    else
        "$@"
    fi
}

section "NFQTTL eCubz diagnostic report"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "Module: $MODULE_NAME"
echo "Version: $MODULE_VERSION ($MODULE_VERSION_CODE)"
echo "Module ID: $MODULE_ID"
echo "Module dir: $MODDIR"

section "1. module.prop / active state / configuration"
cat "$PROP_FILE" 2>/dev/null || echo "module.prop not found"
echo "--- .applied_version ---"
cat "$MODDIR/.applied_version" 2>/dev/null || echo "not present"
echo "--- config.conf ---"
cat "$CONFIG_FILE" 2>/dev/null || echo "not present"
echo "--- runtime.conf ---"
cat "$RUNTIME_FILE" 2>/dev/null || echo "not present"
echo "--- saved offload state ---"
cat "$STATE_DIR/offload.orig" 2>/dev/null || echo "not present"

section "2. Android / kernel / root environment"
echo "Model: $(getprop ro.product.manufacturer) $(getprop ro.product.model)"
echo "Device: $(getprop ro.product.device)"
echo "Android: $(getprop ro.build.version.release) / SDK $(getprop ro.build.version.sdk)"
echo "Build fingerprint: $(getprop ro.build.fingerprint)"
echo "ABI: $(getprop ro.product.cpu.abi)"
echo "ABI list: $(getprop ro.product.cpu.abilist)"
echo "Kernel: $(uname -a)"
echo "SELinux: $(getenforce 2>/dev/null || echo unknown)"
echo "Magisk env: ${MAGISK_VER:-unset} ${MAGISK_VER_CODE:-unset}"
echo "KernelSU env: ${KSU:-unset} ${KSU_VER:-unset} ${KSU_VER_CODE:-unset}"
echo "APatch env: ${APATCH:-unset}"
echo "Boot completed: $(getprop sys.boot_completed)"

section "3. native engine"
ls -la "$MODDIR/nfqttl" 2>/dev/null || true
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$MODDIR/nfqttl" 2>/dev/null || true; fi
echo "--- engine help ---"
"$MODDIR/nfqttl" -h 2>&1 || true
echo "--- matching processes ---"
ps -A -o PID,PPID,USER,STAT,NAME,ARGS 2>/dev/null | grep -E 'nfqttl|PID' || ps -A 2>/dev/null | grep nfqttl || true
for _p in /proc/[0-9]*; do
    [ -r "$_p/comm" ] || continue
    read -r _c < "$_p/comm" 2>/dev/null || continue
    [ "$_c" = "nfqttl" ] || continue
    _pid=${_p#/proc/}
    echo "PID $_pid exe=$(readlink "$_p/exe" 2>/dev/null)"
    echo "  cmdline=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)"
    echo "  status:"
    grep -E '^(State|VmRSS|VmSize|Threads|voluntary_ctxt_switches|nonvoluntary_ctxt_switches):' "$_p/status" 2>/dev/null | sed 's/^/    /'
done

section "4. NFQUEUE health / kernel netfilter capabilities"
echo "--- /proc/net/netfilter/nfnetlink_queue ---"
cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null || echo "unavailable/no active queue"
echo "--- IPv4 targets ---"
cat /proc/net/ip_tables_targets 2>/dev/null || true
echo "--- IPv6 targets ---"
cat /proc/net/ip6_tables_targets 2>/dev/null || true
echo "--- IPv4 matches ---"
cat /proc/net/ip_tables_matches 2>/dev/null || true
echo "--- IPv6 matches ---"
cat /proc/net/ip6_tables_matches 2>/dev/null || true

section "5. carrier tethering / provisioning"
echo "settings tether_dun_required=$(settings get global tether_dun_required 2>/dev/null)"
echo "prop net.tethering.noprovisioning=$(getprop net.tethering.noprovisioning 2>/dev/null)"
echo "prop tether_entitlement_check_state=$(getprop tether_entitlement_check_state 2>/dev/null)"
echo "prop tether_dun_required=$(getprop tether_dun_required 2>/dev/null)"
echo "--- saved carrier state ---"
cat "$STATE_DIR/carrier.orig" 2>/dev/null || echo "not present"

section "6. forwarding / tether offload"
echo "ipv4.ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
echo "ipv6.all.forwarding=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)"
echo "ipv6.all.disable_ipv6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)"
echo "settings tether_offload_disabled=$(settings get global tether_offload_disabled 2>/dev/null)"
echo "device_config BPF override=$(device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null)"
echo "persist.sys.tether.offload.enable=$(getprop persist.sys.tether.offload.enable 2>/dev/null)"

section "7. interfaces / addresses / routing / policy rules"
echo "--- ip -br link ---"
ip -br link 2>/dev/null || ip link show 2>/dev/null || true
echo "--- ip -br addr ---"
ip -br addr 2>/dev/null || ip addr show 2>/dev/null || true
echo "--- IPv4 rules ---"
ip rule show 2>/dev/null || true
echo "--- IPv6 rules ---"
ip -6 rule show 2>/dev/null || true
echo "--- IPv4 routes all tables ---"
ip route show table all 2>/dev/null || true
echo "--- IPv6 routes all tables ---"
ip -6 route show table all 2>/dev/null || true
echo "--- route probes ---"
ip route get 1.1.1.1 2>/dev/null || true
ip -6 route get 2606:4700:4700::1111 2>/dev/null || true

section "8. module chain counters"
echo "--- IPv4 FORWARD ---"
ipt4 -t mangle -L FORWARD -n -v --line-numbers 2>/dev/null || true
echo "--- IPv4 ECUBZ_TTL4 ---"
ipt4 -t mangle -L ECUBZ_TTL4 -n -v --line-numbers 2>/dev/null || true
echo "--- IPv4 ECUBZ_AUX4P ---"
ipt4 -t mangle -L ECUBZ_AUX4P -n -v --line-numbers 2>/dev/null || true
echo "--- IPv4 ECUBZ_AUX4F ---"
ipt4 -t mangle -L ECUBZ_AUX4F -n -v --line-numbers 2>/dev/null || true
echo "--- IPv6 FORWARD ---"
ipt6 -t mangle -L FORWARD -n -v --line-numbers 2>/dev/null || true
echo "--- IPv6 ECUBZ_TTL6 ---"
ipt6 -t mangle -L ECUBZ_TTL6 -n -v --line-numbers 2>/dev/null || true
echo "--- IPv6 ECUBZ_AUX6P ---"
ipt6 -t mangle -L ECUBZ_AUX6P -n -v --line-numbers 2>/dev/null || true
echo "--- IPv6 ECUBZ_AUX6F ---"
ipt6 -t mangle -L ECUBZ_AUX6F -n -v --line-numbers 2>/dev/null || true

section "9. complete iptables-save / ip6tables-save"
iptables-save 2>/dev/null || true
ip6tables-save 2>/dev/null || true

section "10. Android tethering/connectivity state"
echo "--- dumpsys tethering ---"
run_timeout dumpsys tethering 2>/dev/null || echo "dumpsys tethering unavailable"
echo "--- dumpsys connectivity (tether-related excerpt) ---"
if command -v dumpsys >/dev/null 2>&1; then
    run_timeout dumpsys connectivity 2>/dev/null | grep -i -E -C 4 'tether|upstream|networkagent|TRANSPORT_CELLULAR|rmnet|ccmni|pdp|wwan' | tail -n 700
fi
echo "--- dumpsys wifi (soft AP excerpt) ---"
run_timeout dumpsys wifi 2>/dev/null | grep -i -E -C 3 'SoftAp|hotspot|tether|AP state|interface' | tail -n 500 || true

section "11. service/controller logs"
echo "--- service.log ---"
tail -n 500 "$SERVICE_LOG" 2>/dev/null || echo "no service.log"
echo "--- controller.log ---"
tail -n 300 "$WD_LOG" 2>/dev/null || echo "no controller.log"

section "12. ANR / crash indicators"
echo "--- dumpsys activity lastanr ---"
run_timeout dumpsys activity lastanr 2>/dev/null || true
echo "--- /data/anr listing ---"
ls -lah /data/anr 2>/dev/null || echo "/data/anr unavailable"
_latest_anr=$(ls -1t /data/anr 2>/dev/null | head -n 1)
if [ -n "$_latest_anr" ] && [ -f "/data/anr/$_latest_anr" ]; then
    echo "--- tail of newest ANR: $_latest_anr ---"
    tail -n 300 "/data/anr/$_latest_anr" 2>/dev/null || true
fi
echo "--- recent logcat ANR/crash/network signals ---"
if logcat -b all -d -t 2500 >/dev/null 2>&1; then
    logcat -b all -d -t 2500 2>/dev/null | grep -i -E 'ANR in |am_anr|Input dispatching timed out|FATAL EXCEPTION|Fatal signal|nfqttl|nfnetlink|nfqueue|ENOBUFS|tether|offload|iptables|ip6tables' | tail -n 800
else
    logcat -d 2>/dev/null | grep -i -E 'ANR in |am_anr|Input dispatching timed out|FATAL EXCEPTION|Fatal signal|nfqttl|nfnetlink|nfqueue|ENOBUFS|tether|offload|iptables|ip6tables' | tail -n 800
fi

section "13. kernel log signals"
dmesg 2>/dev/null | grep -i -E 'nfqueue|nfnetlink|netfilter|iptables|ip6tables|tether|rmnet|ccmni|pdp|wwan|watchdog|soft lockup|hung task|oom|out of memory' | tail -n 800 || true

section "14. CPU / memory / pressure snapshot"
cat /proc/loadavg 2>/dev/null || true
cat /proc/meminfo 2>/dev/null | head -n 40 || true
for _p in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    [ -r "$_p" ] && { echo "--- $_p ---"; cat "$_p"; }
done
if command -v top >/dev/null 2>&1; then top -b -n 1 2>/dev/null | head -n 80 || true; fi

section "15. self-check"
_applied=$(cat "$MODDIR/.applied_version" 2>/dev/null)
_expected="$MODULE_VERSION ($MODULE_VERSION_CODE)"
if [ "$_applied" = "$_expected" ]; then
    echo "[OK] applied version matches module.prop"
else
    echo "[WARN] applied='$_applied' expected='$_expected' — reboot/service restart may be required"
fi

_hook4=$(ipt4 -t mangle -S FORWARD 2>/dev/null | grep -c -- "-j ECUBZ_TTL4" || echo 0)
_hook6=$(ipt6 -t mangle -S FORWARD 2>/dev/null | grep -c -- "-j ECUBZ_TTL6" || echo 0)
echo "IPv4 module hook count: $_hook4"
echo "IPv6 module hook count: $_hook6"
[ "$_hook4" -gt 1 ] 2>/dev/null && echo "[WARN] duplicate IPv4 hook"
[ "$_hook6" -gt 1 ] 2>/dev/null && echo "[WARN] duplicate IPv6 hook"

if [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    echo "NFQUEUE stats format is kernel-defined; non-zero drop columns during tether load are important."
fi

section "Report complete"
echo "Internal path: $INTERNAL_LOG"
echo "Public path: $PUBLIC_LOG (when /sdcard is available)"

# Finish atomically inside /data/local/tmp, then make a user-accessible copy.
exec 1>&- 2>&-
mv -f "$TMP_LOG" "$INTERNAL_LOG" 2>/dev/null || cp -f "$TMP_LOG" "$INTERNAL_LOG" 2>/dev/null || true
chmod 600 "$INTERNAL_LOG" 2>/dev/null || true
if [ -d /sdcard ] || [ -d /storage/emulated/0 ]; then
    mkdir -p "$PUBLIC_DIR" 2>/dev/null || true
    cp -f "$INTERNAL_LOG" "$PUBLIC_LOG" 2>/dev/null || true
    chmod 664 "$PUBLIC_LOG" 2>/dev/null || true
fi
exit 0
