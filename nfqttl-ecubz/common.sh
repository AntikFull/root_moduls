#!/system/bin/sh

MODDIR=${MODDIR:-${0%/*}}
PROP_FILE="$MODDIR/module.prop"
CONFIG_FILE="$MODDIR/config.conf"
QUEUE_NUM=6464

prop_get() {
    [ -f "$1" ] || return 1
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

MODULE_ID=$(prop_get "$PROP_FILE" id)
MODULE_NAME=$(prop_get "$PROP_FILE" name)
MODULE_VERSION=$(prop_get "$PROP_FILE" version)
MODULE_VERSION_CODE=$(prop_get "$PROP_FILE" versionCode)
[ -n "$MODULE_ID" ] || MODULE_ID="nfqttl-ecubz"
[ -n "$MODULE_VERSION" ] || MODULE_VERSION="unknown"
[ -n "$MODULE_VERSION_CODE" ] || MODULE_VERSION_CODE="unknown"

# Keep rollback/runtime state outside the replaceable module directory so updates
# cannot lose the original Android offload values. uninstall.sh removes it.
STATE_ROOT="/data/adb/$MODULE_ID"
STATE_DIR="$STATE_ROOT/state"
RUNTIME_FILE="$STATE_DIR/runtime.conf"
LOG_DIR="/data/local/tmp/$MODULE_ID"
SERVICE_LOG="$LOG_DIR/service.log"
WD_LOG="$LOG_DIR/controller.log"

# Safe defaults. config.conf may override them.
TTL_VALUE=64
HL_VALUE=64
CARRIER_PROVISIONING_BYPASS=1
OFFLOAD_CONTROL=1
TTL1_PROTECTION=1
CLAMP_MSS=0
ENABLE_DNS_REDIRECT=0
BLOCK_DOT=0
BLOCK_NTP=0
BLOCK_DISCOVERY=0
ENABLE_BLOCKLIST=0
NFQUEUE_OVERLOAD_GUARD=1
NFQUEUE_BACKLOG_LIMIT=768
NFQUEUE_OVERLOAD_LIMIT=3
CONTROLLER_ENABLE=1
CONTROLLER_INTERVAL=30
DEBUG_AUTO_REPORT=1
EXTRA_CLIENT_IFS=""
EXTRA_UPSTREAM_IFS=""

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Sanitize values that can otherwise create a tight controller loop or invalid netfilter rules.
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
clamp_u8_or_default() {
    _v="$1"; _d="$2"
    if is_uint "$_v" && [ "$_v" -ge 1 ] 2>/dev/null && [ "$_v" -le 255 ] 2>/dev/null; then echo "$_v"; else echo "$_d"; fi
}
TTL_VALUE=$(clamp_u8_or_default "$TTL_VALUE" 64)
HL_VALUE=$(clamp_u8_or_default "$HL_VALUE" 64)
is_uint "$CONTROLLER_INTERVAL" || CONTROLLER_INTERVAL=30
[ "$CONTROLLER_INTERVAL" -ge 10 ] 2>/dev/null || CONTROLLER_INTERVAL=10
is_uint "$NFQUEUE_BACKLOG_LIMIT" || NFQUEUE_BACKLOG_LIMIT=768
[ "$NFQUEUE_BACKLOG_LIMIT" -ge 64 ] 2>/dev/null || NFQUEUE_BACKLOG_LIMIT=64
is_uint "$NFQUEUE_OVERLOAD_LIMIT" || NFQUEUE_OVERLOAD_LIMIT=3
[ "$NFQUEUE_OVERLOAD_LIMIT" -ge 1 ] 2>/dev/null || NFQUEUE_OVERLOAD_LIMIT=1

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true

rotate_log() {
    _f="$1"; _max="${2:-262144}"
    [ -f "$_f" ] || return 0
    _size=$(wc -c < "$_f" 2>/dev/null || echo 0)
    [ "$_size" -le "$_max" ] && return 0
    tail -n 300 "$_f" > "$_f.tmp" 2>/dev/null && mv -f "$_f.tmp" "$_f"
}

log_msg() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SERVICE_LOG"
}

wd_log() {
    rotate_log "$WD_LOG" 131072
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WD_LOG"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

IPT_WAIT=""
if iptables -w 1 -L >/dev/null 2>&1; then IPT_WAIT="-w 2"; fi
IP6T_WAIT=""
if ip6tables -w 1 -L >/dev/null 2>&1; then IP6T_WAIT="-w 2"; fi

ipt4() {
    if [ -n "$IPT_WAIT" ]; then iptables $IPT_WAIT "$@"; else iptables "$@"; fi
}

ipt6() {
    if [ -n "$IP6T_WAIT" ]; then ip6tables $IP6T_WAIT "$@"; else ip6tables "$@"; fi
}

run4() {
    ipt4 "$@" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] || log_msg "iptables failed rc=$_rc: $*"
    return "$_rc"
}

run6() {
    ipt6 "$@" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] || log_msg "ip6tables failed rc=$_rc: $*"
    return "$_rc"
}

is_our_nfqttl_pid() {
    _pid="$1"
    [ -r "/proc/$_pid/comm" ] || return 1
    read -r _comm < "/proc/$_pid/comm" 2>/dev/null || return 1
    [ "$_comm" = "nfqttl" ] || return 1
    _exe=$(readlink "/proc/$_pid/exe" 2>/dev/null)
    [ "$_exe" = "$MODDIR/nfqttl" ] && return 0
    # Some Android kernels append " (deleted)" or hide /proc/pid/exe.
    case "$_exe" in "$MODDIR/nfqttl"* ) return 0 ;; esac
    return 1
}

nfqttl_alive() {
    for _p in /proc/[0-9]*; do
        _pid=${_p#/proc/}
        is_our_nfqttl_pid "$_pid" && return 0
    done
    return 1
}

kill_our_nfqttl() {
    for _p in /proc/[0-9]*; do
        _pid=${_p#/proc/}
        if is_our_nfqttl_pid "$_pid"; then
            kill "$_pid" 2>/dev/null || true
        fi
    done
}

save_offload_state_once() {
    _f="$STATE_DIR/offload.orig"
    [ -f "$_f" ] && return 0
    _setting=$(settings get global tether_offload_disabled 2>/dev/null)
    _bpf=$(device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null)
    _prop=$(getprop persist.sys.tether.offload.enable 2>/dev/null)
    {
        echo "TETHER_OFFLOAD_DISABLED_ORIG=${_setting:-null}"
        echo "BPF_OFFLOAD_ORIG=${_bpf:-null}"
        echo "PERSIST_OFFLOAD_PROP_OBSERVED=${_prop:-null}"
    } > "$_f"
    chmod 600 "$_f" 2>/dev/null || true
}

disable_tether_offload() {
    [ "$OFFLOAD_CONTROL" = "1" ] || return 0
    save_offload_state_once
    settings put global tether_offload_disabled 1 >/dev/null 2>&1 || log_msg "cannot set tether_offload_disabled=1"
    device_config put connectivity override_tether_enable_bpf_offload false >/dev/null 2>&1 || log_msg "cannot disable connectivity BPF offload override"
    # Intentionally do NOT touch persist.sys.tether.offload.enable.
}

restore_tether_offload() {
    _f="$STATE_DIR/offload.orig"
    [ -f "$_f" ] || return 0
    TETHER_OFFLOAD_DISABLED_ORIG="null"
    BPF_OFFLOAD_ORIG="null"
    . "$_f" 2>/dev/null || return 0

    if [ "$TETHER_OFFLOAD_DISABLED_ORIG" = "null" ] || [ -z "$TETHER_OFFLOAD_DISABLED_ORIG" ]; then
        settings delete global tether_offload_disabled >/dev/null 2>&1 || true
    else
        settings put global tether_offload_disabled "$TETHER_OFFLOAD_DISABLED_ORIG" >/dev/null 2>&1 || true
    fi

    if [ "$BPF_OFFLOAD_ORIG" = "null" ] || [ -z "$BPF_OFFLOAD_ORIG" ]; then
        device_config delete connectivity override_tether_enable_bpf_offload >/dev/null 2>&1 || true
    else
        device_config put connectivity override_tether_enable_bpf_offload "$BPF_OFFLOAD_ORIG" >/dev/null 2>&1 || true
    fi
}


prop_present() {
    getprop 2>/dev/null | grep -Fq "[$1]:"
}

save_carrier_state_once() {
    _f="$STATE_DIR/carrier.orig"
    [ -f "$_f" ] && return 0
    _dun=$(settings get global tether_dun_required 2>/dev/null)
    _p1=$(getprop net.tethering.noprovisioning 2>/dev/null)
    _p2=$(getprop tether_entitlement_check_state 2>/dev/null)
    _p3=$(getprop tether_dun_required 2>/dev/null)
    prop_present net.tethering.noprovisioning && _e1=1 || _e1=0
    prop_present tether_entitlement_check_state && _e2=1 || _e2=0
    prop_present tether_dun_required && _e3=1 || _e3=0
    {
        echo "TETHER_DUN_SETTING_ORIG=${_dun:-null}"
        echo "NOPROV_PROP_EXISTED=$_e1"
        echo "NOPROV_PROP_ORIG=$_p1"
        echo "ENTITLEMENT_PROP_EXISTED=$_e2"
        echo "ENTITLEMENT_PROP_ORIG=$_p2"
        echo "DUN_PROP_EXISTED=$_e3"
        echo "DUN_PROP_ORIG=$_p3"
    } > "$_f"
    chmod 600 "$_f" 2>/dev/null || true
}

set_runtime_prop() {
    _name="$1"; _value="$2"
    if have_cmd resetprop; then
        resetprop "$_name" "$_value" >/dev/null 2>&1 && return 0
    fi
    setprop "$_name" "$_value" >/dev/null 2>&1
}

delete_runtime_prop() {
    _name="$1"
    if have_cmd resetprop; then
        resetprop --delete "$_name" >/dev/null 2>&1 && return 0
    fi
    # setprop has no portable delete operation; empty is the closest non-persistent fallback.
    setprop "$_name" "" >/dev/null 2>&1
}

apply_carrier_bypass() {
    [ "$CARRIER_PROVISIONING_BYPASS" = "1" ] || return 0
    save_carrier_state_once
    settings put global tether_dun_required 0 >/dev/null 2>&1 || log_msg "cannot set global tether_dun_required=0"
    set_runtime_prop net.tethering.noprovisioning true || log_msg "cannot set net.tethering.noprovisioning=true"
    set_runtime_prop tether_entitlement_check_state 0 || log_msg "cannot set tether_entitlement_check_state=0"
    set_runtime_prop tether_dun_required 0 || log_msg "cannot set tether_dun_required=0 property"
}

restore_carrier_bypass() {
    _f="$STATE_DIR/carrier.orig"
    [ -f "$_f" ] || return 0
    TETHER_DUN_SETTING_ORIG="null"
    NOPROV_PROP_EXISTED=0; NOPROV_PROP_ORIG=""
    ENTITLEMENT_PROP_EXISTED=0; ENTITLEMENT_PROP_ORIG=""
    DUN_PROP_EXISTED=0; DUN_PROP_ORIG=""
    . "$_f" 2>/dev/null || return 0

    if [ "$TETHER_DUN_SETTING_ORIG" = "null" ] || [ -z "$TETHER_DUN_SETTING_ORIG" ]; then
        settings delete global tether_dun_required >/dev/null 2>&1 || true
    else
        settings put global tether_dun_required "$TETHER_DUN_SETTING_ORIG" >/dev/null 2>&1 || true
    fi

    if [ "$NOPROV_PROP_EXISTED" = "1" ]; then set_runtime_prop net.tethering.noprovisioning "$NOPROV_PROP_ORIG" || true; else delete_runtime_prop net.tethering.noprovisioning || true; fi
    if [ "$ENTITLEMENT_PROP_EXISTED" = "1" ]; then set_runtime_prop tether_entitlement_check_state "$ENTITLEMENT_PROP_ORIG" || true; else delete_runtime_prop tether_entitlement_check_state || true; fi
    if [ "$DUN_PROP_EXISTED" = "1" ]; then set_runtime_prop tether_dun_required "$DUN_PROP_ORIG" || true; else delete_runtime_prop tether_dun_required || true; fi
}
