#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

TTL4_CHAIN="ECUBZ_TTL4"
TTL6_CHAIN="ECUBZ_TTL6"
AUX4_PRE="ECUBZ_AUX4P"
AUX6_PRE="ECUBZ_AUX6P"
AUX4_FWD="ECUBZ_AUX4F"
AUX6_FWD="ECUBZ_AUX6F"

log_msg "uninstall cleanup for $MODULE_VERSION ($MODULE_VERSION_CODE)"

# Stop the controller, but only if the recorded PID still belongs to service.sh.
if [ -f "$STATE_DIR/controller.pid" ]; then
    _pid=$(cat "$STATE_DIR/controller.pid" 2>/dev/null)
    case "$_pid" in
        ''|*[!0-9]*) ;;
        *)
            if [ -r "/proc/$_pid/cmdline" ] && tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q "service.sh"; then
                kill "$_pid" 2>/dev/null || true
            fi
            ;;
    esac
fi
kill_our_nfqttl

# Remove our named hooks/chains.
ipt4 -t mangle -D FORWARD -j "$TTL4_CHAIN" >/dev/null 2>&1 || true
ipt6 -t mangle -D FORWARD -j "$TTL6_CHAIN" >/dev/null 2>&1 || true
ipt4 -t mangle -D PREROUTING -j "$AUX4_PRE" >/dev/null 2>&1 || true
ipt6 -t mangle -D PREROUTING -j "$AUX6_PRE" >/dev/null 2>&1 || true
ipt4 -t mangle -D FORWARD -j "$AUX4_FWD" >/dev/null 2>&1 || true
ipt6 -t mangle -D FORWARD -j "$AUX6_FWD" >/dev/null 2>&1 || true
for _c in "$TTL4_CHAIN" "$AUX4_PRE" "$AUX4_FWD"; do
    ipt4 -t mangle -F "$_c" >/dev/null 2>&1 || true
    ipt4 -t mangle -X "$_c" >/dev/null 2>&1 || true
done
for _c in "$TTL6_CHAIN" "$AUX6_PRE" "$AUX6_FWD"; do
    ipt6 -t mangle -F "$_c" >/dev/null 2>&1 || true
    ipt6 -t mangle -X "$_c" >/dev/null 2>&1 || true
done

# Remove optional DNS redirects for every interface pattern we may have installed.
CLIENT_IFS="wlan+ ap+ swlan+ softap+ rndis+ usb+ bt-pan+ pan+ $EXTRA_CLIENT_IFS"
for _if in $CLIENT_IFS; do
    ipt4 -t nat -D PREROUTING -i "$_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
    ipt4 -t nat -D PREROUTING -i "$_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
    ipt6 -t nat -D PREROUTING -i "$_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
    ipt6 -t nat -D PREROUTING -i "$_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
done

# Legacy chain cleanup from v8.4 and older.
ipt4 -t mangle -D FORWARD -j nfqttlo >/dev/null 2>&1 || true
ipt6 -t mangle -D FORWARD -j nfqttlo >/dev/null 2>&1 || true
ipt4 -t mangle -F nfqttlo >/dev/null 2>&1 || true
ipt4 -t mangle -X nfqttlo >/dev/null 2>&1 || true
ipt6 -t mangle -F nfqttlo >/dev/null 2>&1 || true
ipt6 -t mangle -X nfqttlo >/dev/null 2>&1 || true

restore_tether_offload
restore_carrier_bypass
log_msg "uninstall cleanup complete; original tether/offload carrier settings restored when available"
rm -rf "$STATE_ROOT" 2>/dev/null || true
exit 0
