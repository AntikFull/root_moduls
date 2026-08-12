#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

rotate_log "$SERVICE_LOG" 524288
log_msg "=== start $MODULE_ID $MODULE_VERSION ($MODULE_VERSION_CODE) ==="
echo "$MODULE_VERSION ($MODULE_VERSION_CODE)" > "$MODDIR/.applied_version" 2>/dev/null || true

TTL4_CHAIN="ECUBZ_TTL4"
TTL6_CHAIN="ECUBZ_TTL6"
AUX4_PRE="ECUBZ_AUX4P"
AUX6_PRE="ECUBZ_AUX6P"
AUX4_FWD="ECUBZ_AUX4F"
AUX6_FWD="ECUBZ_AUX6F"

del4_all() { while ipt4 "$@" >/dev/null 2>&1; do :; done; }
del6_all() { while ipt6 "$@" >/dev/null 2>&1; do :; done; }

# Trailing + is the iptables prefix wildcard. tun+ is deliberately excluded.
CLIENT_IFS="wlan+ ap+ swlan+ softap+ rndis+ usb+ bt-pan+ pan+ $EXTRA_CLIENT_IFS"
CELL_IFS="rmnet+ r_rmnet+ rmnet_data+ rmnet_mhi+ rmnet_ipa+ ccmni+ pdp+ wwan+ v4-rmnet+ $EXTRA_UPSTREAM_IFS"

cleanup_hook_all() {
    # Absence is normal during cleanup, so do not pollute service.log with expected failures.
    del4_all -t mangle -D FORWARD -j "$TTL4_CHAIN"
    del6_all -t mangle -D FORWARD -j "$TTL6_CHAIN"
    del4_all -t mangle -D PREROUTING -j "$AUX4_PRE"
    del6_all -t mangle -D PREROUTING -j "$AUX6_PRE"
    del4_all -t mangle -D FORWARD -j "$AUX4_FWD"
    del6_all -t mangle -D FORWARD -j "$AUX6_FWD"

    for _c in "$TTL4_CHAIN" "$AUX4_PRE" "$AUX4_FWD"; do
        ipt4 -t mangle -F "$_c" >/dev/null 2>&1 || true
        ipt4 -t mangle -X "$_c" >/dev/null 2>&1 || true
    done
    for _c in "$TTL6_CHAIN" "$AUX6_PRE" "$AUX6_FWD"; do
        ipt6 -t mangle -F "$_c" >/dev/null 2>&1 || true
        ipt6 -t mangle -X "$_c" >/dev/null 2>&1 || true
    done
}

cleanup_legacy() {
    # Remove rules used by older releases. Errors are expected when a rule is absent.
    ipt4 -t mangle -D OUTPUT -j nfqttlo >/dev/null 2>&1 || true
    ipt4 -t mangle -D POSTROUTING ! -o lo -j nfqttlo >/dev/null 2>&1 || true
    ipt4 -t mangle -D FORWARD -j nfqttlo >/dev/null 2>&1 || true
    ipt6 -t mangle -D POSTROUTING -j nfqttlo >/dev/null 2>&1 || true
    ipt6 -t mangle -D FORWARD -j nfqttlo >/dev/null 2>&1 || true
    ipt4 -t mangle -D FORWARD -j TTL --ttl-set 64 >/dev/null 2>&1 || true
    ipt6 -t mangle -D FORWARD -j HL --hl-set 64 >/dev/null 2>&1 || true
    ipt4 -t mangle -F nfqttlo >/dev/null 2>&1 || true
    ipt4 -t mangle -X nfqttlo >/dev/null 2>&1 || true
    ipt6 -t mangle -F nfqttlo >/dev/null 2>&1 || true
    ipt6 -t mangle -X nfqttlo >/dev/null 2>&1 || true

    # Remove old global DNS/DoT/NTP/discovery rules generated from the known interface list.
    for _if in wlan+ ap+ swlan+ softap+ rndis+ usb+ bt-pan+ pan+; do
        ipt4 -t nat -D PREROUTING -i "$_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        ipt4 -t nat -D PREROUTING -i "$_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        ipt6 -t nat -D PREROUTING -i "$_if" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        ipt6 -t nat -D PREROUTING -i "$_if" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        for _p in 123 5353 5355 1900; do
            ipt4 -t mangle -D FORWARD -i "$_if" -p udp --dport "$_p" -j DROP >/dev/null 2>&1 || true
            ipt6 -t mangle -D FORWARD -i "$_if" -p udp --dport "$_p" -j DROP >/dev/null 2>&1 || true
        done
        ipt4 -t mangle -D FORWARD -i "$_if" -p udp --dport 137:138 -j DROP >/dev/null 2>&1 || true
        ipt4 -t mangle -D FORWARD -i "$_if" -p tcp --dport 853 -j DROP >/dev/null 2>&1 || true
        ipt6 -t mangle -D FORWARD -i "$_if" -p tcp --dport 853 -j DROP >/dev/null 2>&1 || true
    done
}

cleanup_optional_nat() {
    for _ci in $CLIENT_IFS; do
        [ -n "$_ci" ] || continue
        ipt4 -t nat -D PREROUTING -i "$_ci" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        ipt4 -t nat -D PREROUTING -i "$_ci" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        ipt6 -t nat -D PREROUTING -i "$_ci" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
        ipt6 -t nat -D PREROUTING -i "$_ci" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || true
    done
}

probe_ttl4() {
    _c="ECUBZ_P4_$$"
    ipt4 -t mangle -N "$_c" >/dev/null 2>&1 || return 1
    ipt4 -t mangle -A "$_c" -j TTL --ttl-set "$TTL_VALUE" >/dev/null 2>&1
    _rc=$?
    ipt4 -t mangle -F "$_c" >/dev/null 2>&1 || true
    ipt4 -t mangle -X "$_c" >/dev/null 2>&1 || true
    return "$_rc"
}

probe_hl6() {
    _c="ECUBZ_P6_$$"
    ipt6 -t mangle -N "$_c" >/dev/null 2>&1 || return 1
    ipt6 -t mangle -A "$_c" -j HL --hl-set "$HL_VALUE" >/dev/null 2>&1
    _rc=$?
    ipt6 -t mangle -F "$_c" >/dev/null 2>&1 || true
    ipt6 -t mangle -X "$_c" >/dev/null 2>&1 || true
    return "$_rc"
}

probe_nfq4() {
    _c="ECUBZ_N4_$$"
    ipt4 -t mangle -N "$_c" >/dev/null 2>&1 || return 1
    ipt4 -t mangle -A "$_c" -j NFQUEUE --queue-num "$QUEUE_NUM" --queue-bypass >/dev/null 2>&1
    _rc=$?
    ipt4 -t mangle -F "$_c" >/dev/null 2>&1 || true
    ipt4 -t mangle -X "$_c" >/dev/null 2>&1 || true
    return "$_rc"
}

probe_nfq6() {
    _c="ECUBZ_N6_$$"
    ipt6 -t mangle -N "$_c" >/dev/null 2>&1 || return 1
    ipt6 -t mangle -A "$_c" -j NFQUEUE --queue-num "$QUEUE_NUM" --queue-bypass >/dev/null 2>&1
    _rc=$?
    ipt6 -t mangle -F "$_c" >/dev/null 2>&1 || true
    ipt6 -t mangle -X "$_c" >/dev/null 2>&1 || true
    return "$_rc"
}

start_daemon() {
    nfqttl_alive && return 0
    [ -x "$MODDIR/nfqttl" ] || { log_msg "CRITICAL: nfqttl binary missing/not executable"; return 1; }
    export NFQTTL_MODULE_VERSION="$MODULE_VERSION"
    export NFQTTL_MODULE_PROP="$PROP_FILE"
    "$MODDIR/nfqttl" -d -n "$QUEUE_NUM" -t "$TTL_VALUE" >> "$SERVICE_LOG" 2>&1
    sleep 1
    if nfqttl_alive; then
        log_msg "NFQUEUE daemon started (queue=$QUEUE_NUM ttl=$TTL_VALUE)"
        return 0
    fi
    log_msg "CRITICAL: NFQUEUE daemon failed to stay alive"
    return 1
}

ensure_chain4() { ipt4 -t mangle -N "$1" >/dev/null 2>&1 || true; ipt4 -t mangle -F "$1" >/dev/null 2>&1 || true; }
ensure_chain6() { ipt6 -t mangle -N "$1" >/dev/null 2>&1 || true; ipt6 -t mangle -F "$1" >/dev/null 2>&1 || true; }

add_base_pair_rules4() {
    _mode="$1"
    for _ci in $CLIENT_IFS; do
        [ -n "$_ci" ] || continue
        for _up in $CELL_IFS; do
            [ -n "$_up" ] || continue
            if [ "$_mode" = "native" ]; then
                run4 -t mangle -A "$TTL4_CHAIN" -i "$_ci" -o "$_up" -j TTL --ttl-set "$TTL_VALUE" || true
            elif [ "$_mode" = "nfqueue" ]; then
                run4 -t mangle -A "$TTL4_CHAIN" -i "$_ci" -o "$_up" -j NFQUEUE --queue-num "$QUEUE_NUM" --queue-bypass || true
            fi
        done
    done
}

add_base_pair_rules6() {
    _mode="$1"
    for _ci in $CLIENT_IFS; do
        [ -n "$_ci" ] || continue
        for _up in $CELL_IFS; do
            [ -n "$_up" ] || continue
            if [ "$_mode" = "native" ]; then
                run6 -t mangle -A "$TTL6_CHAIN" -i "$_ci" -o "$_up" -j HL --hl-set "$HL_VALUE" || true
            elif [ "$_mode" = "nfqueue" ]; then
                run6 -t mangle -A "$TTL6_CHAIN" -i "$_ci" -o "$_up" -j NFQUEUE --queue-num "$QUEUE_NUM" --queue-bypass || true
            fi
        done
    done
}

add_ttl1_protection() {
    [ "$TTL1_PROTECTION" = "1" ] || return 0
    ensure_chain4 "$AUX4_PRE"
    ensure_chain6 "$AUX6_PRE"
    for _up in $CELL_IFS; do
        [ -n "$_up" ] || continue
        ipt4 -t mangle -A "$AUX4_PRE" -i "$_up" -m ttl --ttl-eq 1 -j DROP >/dev/null 2>&1 || true
        ipt6 -t mangle -A "$AUX6_PRE" -i "$_up" -m hl --hl-eq 1 -j DROP >/dev/null 2>&1 || true
    done
    ipt4 -t mangle -C PREROUTING -j "$AUX4_PRE" >/dev/null 2>&1 || run4 -t mangle -I PREROUTING 1 -j "$AUX4_PRE" || true
    ipt6 -t mangle -C PREROUTING -j "$AUX6_PRE" >/dev/null 2>&1 || run6 -t mangle -I PREROUTING 1 -j "$AUX6_PRE" || true
}

add_optional_rules() {
    ensure_chain4 "$AUX4_FWD"
    ensure_chain6 "$AUX6_FWD"

    for _ci in $CLIENT_IFS; do
        [ -n "$_ci" ] || continue
        for _up in $CELL_IFS; do
            [ -n "$_up" ] || continue
            if [ "$CLAMP_MSS" = "1" ]; then
                run4 -t mangle -A "$AUX4_FWD" -i "$_ci" -o "$_up" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtud || true
            fi
        done

        if [ "$BLOCK_DOT" = "1" ]; then
            run4 -t mangle -A "$AUX4_FWD" -i "$_ci" -p tcp --dport 853 -j DROP || true
            run6 -t mangle -A "$AUX6_FWD" -i "$_ci" -p tcp --dport 853 -j DROP || true
        fi
        if [ "$BLOCK_NTP" = "1" ]; then
            run4 -t mangle -A "$AUX4_FWD" -i "$_ci" -p udp --dport 123 -j DROP || true
            run6 -t mangle -A "$AUX6_FWD" -i "$_ci" -p udp --dport 123 -j DROP || true
        fi
        if [ "$BLOCK_DISCOVERY" = "1" ]; then
            for _p in 5353 5355 1900; do
                run4 -t mangle -A "$AUX4_FWD" -i "$_ci" -p udp --dport "$_p" -j DROP || true
                run6 -t mangle -A "$AUX6_FWD" -i "$_ci" -p udp --dport "$_p" -j DROP || true
            done
            run4 -t mangle -A "$AUX4_FWD" -i "$_ci" -p udp --dport 137:138 -j DROP || true
        fi

        if [ "$ENABLE_DNS_REDIRECT" = "1" ]; then
            ipt4 -t nat -C PREROUTING -i "$_ci" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || run4 -t nat -A PREROUTING -i "$_ci" -p udp --dport 53 -j REDIRECT --to-ports 53 || true
            ipt4 -t nat -C PREROUTING -i "$_ci" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || run4 -t nat -A PREROUTING -i "$_ci" -p tcp --dport 53 -j REDIRECT --to-ports 53 || true
            ipt6 -t nat -C PREROUTING -i "$_ci" -p udp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || run6 -t nat -A PREROUTING -i "$_ci" -p udp --dport 53 -j REDIRECT --to-ports 53 || true
            ipt6 -t nat -C PREROUTING -i "$_ci" -p tcp --dport 53 -j REDIRECT --to-ports 53 >/dev/null 2>&1 || run6 -t nat -A PREROUTING -i "$_ci" -p tcp --dport 53 -j REDIRECT --to-ports 53 || true
        fi
    done

    if [ "$ENABLE_BLOCKLIST" = "1" ] && [ -s "$MODDIR/blocklist.txt" ]; then
        _has4=0; _has6=0
        grep -qw string /proc/net/ip_tables_matches 2>/dev/null && _has4=1
        grep -qw string /proc/net/ip6_tables_matches 2>/dev/null && _has6=1
        while IFS= read -r _line || [ -n "$_line" ]; do
            _domain=$(echo "$_line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\r')
            [ -n "$_domain" ] || continue
            for _ci in $CLIENT_IFS; do
                [ "$_has4" = "1" ] && run4 -t mangle -A "$AUX4_FWD" -i "$_ci" -m string --string "$_domain" --algo bm -j DROP || true
                [ "$_has6" = "1" ] && run6 -t mangle -A "$AUX6_FWD" -i "$_ci" -m string --string "$_domain" --algo bm -j DROP || true
            done
        done < "$MODDIR/blocklist.txt"
    fi

    # Hook optional chains only if they contain at least one rule.
    if ipt4 -t mangle -S "$AUX4_FWD" 2>/dev/null | grep -q -- "^-A"; then
        ipt4 -t mangle -C FORWARD -j "$AUX4_FWD" >/dev/null 2>&1 || run4 -t mangle -A FORWARD -j "$AUX4_FWD" || true
    fi
    if ipt6 -t mangle -S "$AUX6_FWD" 2>/dev/null | grep -q -- "^-A"; then
        ipt6 -t mangle -C FORWARD -j "$AUX6_FWD" >/dev/null 2>&1 || run6 -t mangle -A FORWARD -j "$AUX6_FWD" || true
    fi
}

write_runtime() {
    {
        echo "MODULE_VERSION=$MODULE_VERSION"
        echo "MODULE_VERSION_CODE=$MODULE_VERSION_CODE"
        echo "MODE4=$MODE4"
        echo "MODE6=$MODE6"
        echo "QUEUE_NUM=$QUEUE_NUM"
        echo "TTL_VALUE=$TTL_VALUE"
        echo "HL_VALUE=$HL_VALUE"
        echo "CARRIER_PROVISIONING_BYPASS=$CARRIER_PROVISIONING_BYPASS"
        echo "NFQ_REQUIRED=$NFQ_REQUIRED"
        echo "NFQUEUE_OVERLOAD_GUARD=$NFQUEUE_OVERLOAD_GUARD"
        echo "NFQUEUE_BACKLOG_LIMIT=$NFQUEUE_BACKLOG_LIMIT"
        echo "LAST_APPLY_EPOCH=$(date +%s 2>/dev/null || echo 0)"
    } > "$RUNTIME_FILE"
}

apply_rules() {
    MODE4="unsupported"
    MODE6="unsupported"
    NFQ_REQUIRED=0

    ensure_chain4 "$TTL4_CHAIN"
    ensure_chain6 "$TTL6_CHAIN"

    if probe_ttl4; then
        MODE4="native"
    elif probe_nfq4; then
        MODE4="nfqueue"
        NFQ_REQUIRED=1
    fi

    if probe_hl6; then
        MODE6="native"
    elif probe_nfq6; then
        MODE6="nfqueue"
        NFQ_REQUIRED=1
    fi

    if [ "$NFQ_REQUIRED" = "1" ]; then
        if ! start_daemon; then
            [ "$MODE4" = "nfqueue" ] && MODE4="unsupported"
            [ "$MODE6" = "nfqueue" ] && MODE6="unsupported"
            NFQ_REQUIRED=0
            log_msg "NFQUEUE unavailable: leaving affected traffic untouched (fail-safe connectivity)"
        fi
    else
        kill_our_nfqttl
    fi

    add_base_pair_rules4 "$MODE4"
    add_base_pair_rules6 "$MODE6"

    if [ "$MODE4" != "unsupported" ]; then
        ipt4 -t mangle -C FORWARD -j "$TTL4_CHAIN" >/dev/null 2>&1 || run4 -t mangle -I FORWARD 1 -j "$TTL4_CHAIN" || true
    fi
    if [ "$MODE6" != "unsupported" ]; then
        ipt6 -t mangle -C FORWARD -j "$TTL6_CHAIN" >/dev/null 2>&1 || run6 -t mangle -I FORWARD 1 -j "$TTL6_CHAIN" || true
    fi

    add_ttl1_protection
    cleanup_optional_nat
    add_optional_rules
    write_runtime
    log_msg "rules applied: IPv4=$MODE4 IPv6=$MODE6 NFQ=$NFQ_REQUIRED ttl=$TTL_VALUE hl=$HL_VALUE"
}

nfq_queue_stats() {
    _qf=/proc/net/netfilter/nfnetlink_queue
    [ -r "$_qf" ] || return 1
    # Columns: queue, peer portid, queued, copy mode/range, kernel dropped, userspace dropped, sequence.
    awk -v q="$QUEUE_NUM" '$1 == q {print $3, $6, $7; found=1; exit} END {if (!found) exit 1}' "$_qf" 2>/dev/null
}

remove_ttl_hooks_only() {
    del4_all -t mangle -D FORWARD -j "$TTL4_CHAIN"
    del6_all -t mangle -D FORWARD -j "$TTL6_CHAIN"
}

stop_old_controller() {
    _pf="$STATE_DIR/controller.pid"
    [ -f "$_pf" ] || return 0
    _pid=$(cat "$_pf" 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) rm -f "$_pf" 2>/dev/null || true; return 0 ;; esac
    if [ -r "/proc/$_pid/cmdline" ] && tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q "service.sh"; then
        kill "$_pid" 2>/dev/null || true
    fi
    rm -f "$_pf" 2>/dev/null || true
}

controller() {
    echo "$$" > "$STATE_DIR/controller.pid" 2>/dev/null || true
    _restarts=0
    _overloads=0
    _last_kdrop=0
    _last_udrop=0
    wd_log "controller started; interval=${CONTROLLER_INTERVAL}s; native mode never starts daemon"
    while true; do
        sleep "$CONTROLLER_INTERVAL"

        _need_reapply=0
        if [ "$MODE4" != "unsupported" ]; then
            ipt4 -t mangle -C FORWARD -j "$TTL4_CHAIN" >/dev/null 2>&1 || _need_reapply=1
            ipt4 -t mangle -S "$TTL4_CHAIN" 2>/dev/null | grep -q -- "^-A" || _need_reapply=1
        fi
        if [ "$MODE6" != "unsupported" ]; then
            ipt6 -t mangle -C FORWARD -j "$TTL6_CHAIN" >/dev/null 2>&1 || _need_reapply=1
            ipt6 -t mangle -S "$TTL6_CHAIN" 2>/dev/null | grep -q -- "^-A" || _need_reapply=1
        fi

        if [ "$CARRIER_PROVISIONING_BYPASS" = "1" ]; then
            _dun=$(settings get global tether_dun_required 2>/dev/null)
            _np=$(getprop net.tethering.noprovisioning 2>/dev/null)
            _te=$(getprop tether_entitlement_check_state 2>/dev/null)
            if [ "$_dun" != "0" ] || [ "$_np" != "true" ] || [ "$_te" != "0" ]; then
                wd_log "carrier provisioning values changed; reapplying reversible bypass"
                apply_carrier_bypass
            fi
        fi

        # Android/DeviceConfig may overwrite offload flags after boot. Reassert only the
        # two reversible keys we own; never touch the persistent vendor property.
        if [ "$OFFLOAD_CONTROL" = "1" ]; then
            _off=$(settings get global tether_offload_disabled 2>/dev/null)
            _bpf=$(device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null)
            [ "$_off" = "1" ] || { wd_log "tether_offload_disabled changed; restoring module value"; settings put global tether_offload_disabled 1 >/dev/null 2>&1 || true; }
            [ "$_bpf" = "false" ] || { wd_log "BPF offload override changed; restoring module value"; device_config put connectivity override_tether_enable_bpf_offload false >/dev/null 2>&1 || true; }
        fi

        if [ "$NFQ_REQUIRED" = "1" ] && ! nfqttl_alive; then
            _restarts=$((_restarts + 1))
            wd_log "nfqttl daemon missing; restart #$_restarts"
            start_daemon || wd_log "daemon restart failed; --queue-bypass keeps traffic open while listener is absent"
        fi

        # Legacy prebuilt engines do not contain the current per-queue fail-open source hardening yet.
        # Detect queue pressure from procfs and open our FORWARD path before a sick queue
        # can keep degrading tethered clients. Re-apply on the next pass; after repeated
        # overloads, keep NFQUEUE bypassed until reboot instead of flapping forever.
        if [ "$NFQ_REQUIRED" = "1" ] && [ "$NFQUEUE_OVERLOAD_GUARD" = "1" ]; then
            _stats=$(nfq_queue_stats 2>/dev/null)
            if [ -n "$_stats" ]; then
                set -- $_stats
                _queued=${1:-0}; _kdrop=${2:-0}; _udrop=${3:-0}
                _over=0
                is_uint "$_queued" && [ "$_queued" -ge "$NFQUEUE_BACKLOG_LIMIT" ] 2>/dev/null && _over=1
                is_uint "$_kdrop" && is_uint "$_last_kdrop" && [ "$_kdrop" -gt "$_last_kdrop" ] 2>/dev/null && _over=1
                is_uint "$_udrop" && is_uint "$_last_udrop" && [ "$_udrop" -gt "$_last_udrop" ] 2>/dev/null && _over=1
                _last_kdrop=$_kdrop; _last_udrop=$_udrop
                if [ "$_over" = "1" ]; then
                    _overloads=$((_overloads + 1))
                    wd_log "NFQUEUE pressure: queued=$_queued kernel_drop=$_kdrop user_drop=$_udrop event=$_overloads/$NFQUEUE_OVERLOAD_LIMIT; opening tether path"
                    remove_ttl_hooks_only
                    kill_our_nfqttl
                    if [ "$_overloads" -ge "$NFQUEUE_OVERLOAD_LIMIT" ]; then
                        [ "$MODE4" = "nfqueue" ] && MODE4="unsupported"
                        [ "$MODE6" = "nfqueue" ] && MODE6="unsupported"
                        NFQ_REQUIRED=0
                        _need_reapply=0
                        write_runtime
                        wd_log "NFQUEUE circuit breaker OPEN until reboot; connectivity preserved, masking disabled for fallback families"
                    else
                        sleep 2
                        _need_reapply=1
                    fi
                fi
            fi
        fi

        if [ "$_need_reapply" = "1" ]; then
            wd_log "netfilter state changed/removed; rebuilding module chains"
            cleanup_hook_all
            apply_rules
        fi
    done
}
stop_old_controller
kill_our_nfqttl
cleanup_legacy
cleanup_hook_all
if [ "$CARRIER_PROVISIONING_BYPASS" = "1" ]; then apply_carrier_bypass; else restore_carrier_bypass; fi
if [ "$OFFLOAD_CONTROL" = "1" ]; then disable_tether_offload; else restore_tether_offload; fi
apply_rules

if [ "$CONTROLLER_ENABLE" = "1" ]; then
    controller &
fi

if { [ -f "$MODDIR/debug" ] || [ -f "$MODDIR/DEBUG" ]; } && [ "$DEBUG_AUTO_REPORT" = "1" ] && [ -x "$MODDIR/debug_log.sh" ]; then
    sh "$MODDIR/debug_log.sh" >/dev/null 2>&1 &
fi

# Test harness for static/CI environments. Normal Android execution ignores this.
[ "$NFQTTL_TEST_ONCE" = "1" ] && stop_old_controller
exit 0
