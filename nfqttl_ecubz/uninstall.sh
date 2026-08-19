#!/system/bin/sh
# Nfqttl eCubz — Скрипт деинсталляции и полной очистки системы
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}

# 0. Останавливаем фоновые worker-процессы service.sh до очистки правил.
# Иначе старый watchdog может успеть восстановить правила уже после uninstall.
stop_service_workers() {
    if [ -f "$MODDIR/.watchdog.pid" ]; then
        read -r _wpid < "$MODDIR/.watchdog.pid" 2>/dev/null || _wpid=""
        if [ -n "$_wpid" ] && [ -r "/proc/$_wpid/cmdline" ]; then
            _cmd=$(tr '\000' ' ' < "/proc/$_wpid/cmdline" 2>/dev/null)
            case "$_cmd" in
                *"$MODDIR/service.sh"*)
                    kill "$_wpid" 2>/dev/null || true
                    sleep 1
                    [ -d "/proc/$_wpid" ] && kill -9 "$_wpid" 2>/dev/null || true
                    ;;
            esac
        fi
    fi

    # Fallback для старых версий, где PID-файла ещё не было.
    _fallback_pids=""
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _pid=${_p##*/}
        [ "$_pid" = "$$" ] && continue
        _cmd=$(tr '\000' ' ' < "$_p/cmdline" 2>/dev/null)
        case "$_cmd" in
            *"$MODDIR/service.sh"*)
                kill "$_pid" 2>/dev/null || true
                _fallback_pids="$_fallback_pids $_pid"
                ;;
        esac
    done
    sleep 1
    for _pid in $_fallback_pids; do
        [ -d "/proc/$_pid" ] && kill -9 "$_pid" 2>/dev/null || true
    done
    rm -f "$MODDIR/.watchdog.pid" 2>/dev/null || true
}
stop_service_workers

# 1. Остановка только процесса, запущенного из этого модуля
nfqttl_pids() {
    for _p in /proc/[0-9]*; do
        [ -r "$_p/comm" ] || continue
        read -r _c < "$_p/comm" 2>/dev/null || continue
        [ "$_c" = "nfqttl" ] || continue
        _exe=$(readlink "$_p/exe" 2>/dev/null)
        case "$_exe" in
            "$MODDIR/nfqttl"|"$MODDIR/nfqttl (deleted)") echo "${_p##*/}" ;;
        esac
    done
}

_pids=$(nfqttl_pids)
if [ -n "$_pids" ]; then
    kill $_pids 2>/dev/null || true
    sleep 1
    _pids=$(nfqttl_pids)
    [ -n "$_pids" ] && kill -9 $_pids 2>/dev/null || true
fi

# 2. Очистка правил iptables и ip6tables
IPT4() { iptables -w 2 "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }
IPT6() { ip6tables -w 2 "$@" 2>/dev/null || ip6tables "$@" 2>/dev/null; }

del_jump() { # $1=IPT4|IPT6 $2=table $3=chain $4=target
    _n=0
    while [ "$_n" -lt 40 ] && "$1" -t "$2" -D "$3" -j "$4"; do
        _n=$((_n + 1))
    done
}

drop_chain() { # $1=IPT4|IPT6 $2=table $3=chain
    "$1" -t "$2" -F "$3" 2>/dev/null || true
    "$1" -t "$2" -X "$3" 2>/dev/null || true
}

for _cmd in IPT4 IPT6; do
    del_jump "$_cmd" mangle PREROUTING  nfqttlp
    del_jump "$_cmd" mangle FORWARD     nfqttlo
    del_jump "$_cmd" mangle FORWARD     nfqttlb
    del_jump "$_cmd" mangle POSTROUTING nfqttlm
    del_jump "$_cmd" mangle POSTROUTING nfqttlq
    del_jump "$_cmd" mangle OUTPUT      nfqttlo
    del_jump "$_cmd" nat    PREROUTING  nfqttln
    del_jump "$_cmd" nat    POSTROUTING nfqttlnat
    del_jump "$_cmd" filter FORWARD     nfqttlfwd
    del_jump "$_cmd" filter OUTPUT      nfqttlf

    drop_chain "$_cmd" mangle nfqttlp
    drop_chain "$_cmd" mangle nfqttlo
    drop_chain "$_cmd" mangle nfqttlb
    drop_chain "$_cmd" mangle nfqttlc
    drop_chain "$_cmd" mangle nfqttlm
    drop_chain "$_cmd" mangle nfqttlq
    drop_chain "$_cmd" nat    nfqttln
    drop_chain "$_cmd" nat    nfqttlnat
    drop_chain "$_cmd" filter nfqttlfwd
    drop_chain "$_cmd" filter nfqttlf
done

# 2.1 Очистка правил и цепочек Auto VPN Tethering
VPN_RULES="$MODDIR/.vpn_tether_rules"
[ ! -f "$VPN_RULES" ] && VPN_RULES="/data/adb/modules/nfqttl_ecubz/.vpn_tether_rules"
if [ -f "$VPN_RULES" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -z "$_line" ] && continue
        case "$_line" in
            RULE4\|*)
                _oldifs=$IFS; IFS='|'; set -- $_line; IFS=$_oldifs
                _pref="$2"; _iif="$3"; _tbl="$4"
                [ -n "$_pref" ] && [ -n "$_iif" ] && [ -n "$_tbl" ] && \
                    ip rule del iif "$_iif" lookup "$_tbl" pref "$_pref" 2>/dev/null || true
                ;;
            ROUTE4\|*)
                _oldifs=$IFS; IFS='|'; set -- $_line; IFS=$_oldifs
                _tbl="$2"; _dev="$3"; _dst="$4"
                if [ -n "$_tbl" ] && [ -n "$_dev" ] && [ "$_dst" = "default" ]; then
                    ip route del default dev "$_dev" table "$_tbl" 2>/dev/null || true
                fi
                ;;
            iif\ *\ lookup\ *\ pref\ *)
                set -- $_line
                if [ "$1" = "iif" ] && [ "$3" = "lookup" ] && [ "$5" = "pref" ]; then
                    ip rule del iif "$2" lookup "$4" pref "$6" 2>/dev/null || true
                fi
                ;;
        esac
    done < "$VPN_RULES"
    rm -f "$VPN_RULES" 2>/dev/null || true
fi

# Удаляем только собственные jumps/chains. Чужие pref/TCPMSS/IPv6 DROP не трогаем.
del_jump IPT4 filter FORWARD     nfqttl_vpn_fwd
del_jump IPT4 nat    POSTROUTING nfqttl_vpn_nat
del_jump IPT4 nat    PREROUTING  nfqttl_vpn_dns
del_jump IPT6 filter FORWARD     nfqttl_vpn6_fwd

drop_chain IPT4 filter nfqttl_vpn_fwd
drop_chain IPT4 nat    nfqttl_vpn_nat
drop_chain IPT4 nat    nfqttl_vpn_dns
drop_chain IPT6 filter nfqttl_vpn6_fwd

ip route flush cache 2>/dev/null || true
rm -f "$MODDIR/.vpn_tether_status" "$MODDIR/.vpn_tether_rules" 2>/dev/null || true

# 3. Восстановление исходных настроек Android
ORIG_CONF="$MODDIR/.original.conf"
[ ! -f "$ORIG_CONF" ] && ORIG_CONF="/data/adb/modules/nfqttl_ecubz/.original.conf"

saved_value() {
    _key="$1"
    [ -f "$ORIG_CONF" ] || return 0
    awk -v k="$_key" '
        index($0, k "=\"") == 1 {
            v = substr($0, length(k) + 3)
            sub(/\"$/, "", v)
            print v
            exit
        }
    ' "$ORIG_CONF" 2>/dev/null
}

ORIG_TETHER_OFFLOAD=$(saved_value ORIG_TETHER_OFFLOAD)
ORIG_BPF_OFFLOAD=$(saved_value ORIG_BPF_OFFLOAD)
ORIG_PERSIST_OFFLOAD=$(saved_value ORIG_PERSIST_OFFLOAD)
ORIG_IPV4_FORWARD=$(saved_value ORIG_IPV4_FORWARD)
ORIG_IPV6_FORWARD=$(saved_value ORIG_IPV6_FORWARD)
ORIG_RP_FILTER=$(saved_value ORIG_RP_FILTER)
ORIG_IPV6_DISABLE=$(saved_value ORIG_IPV6_DISABLE)

# Сброс tether_offload_disabled
if [ -n "$ORIG_TETHER_OFFLOAD" ] && [ "$ORIG_TETHER_OFFLOAD" != "null" ]; then
    settings put global tether_offload_disabled "$ORIG_TETHER_OFFLOAD" 2>/dev/null || true
else
    settings delete global tether_offload_disabled 2>/dev/null || settings put global tether_offload_disabled 0 2>/dev/null || true
fi

# Сброс override_tether_enable_bpf_offload
if [ -n "$ORIG_BPF_OFFLOAD" ] && [ "$ORIG_BPF_OFFLOAD" != "null" ]; then
    device_config put connectivity override_tether_enable_bpf_offload "$ORIG_BPF_OFFLOAD" 2>/dev/null || true
else
    device_config delete connectivity override_tether_enable_bpf_offload 2>/dev/null || true
fi

# Сброс persist.sys.tether.offload.enable
if [ -n "$ORIG_PERSIST_OFFLOAD" ]; then
    setprop persist.sys.tether.offload.enable "$ORIG_PERSIST_OFFLOAD" 2>/dev/null || true
else
    setprop persist.sys.tether.offload.enable "" 2>/dev/null || true
fi


# Восстановление sysctl, изменённых service.sh
[ -n "$ORIG_IPV4_FORWARD" ] && echo "$ORIG_IPV4_FORWARD" > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
[ -n "$ORIG_IPV6_FORWARD" ] && echo "$ORIG_IPV6_FORWARD" > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
[ -n "$ORIG_RP_FILTER" ] && echo "$ORIG_RP_FILTER" > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
[ -n "$ORIG_IPV6_DISABLE" ] && echo "$ORIG_IPV6_DISABLE" > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true

# 4. Очистка временных файлов
rm -f "$MODDIR/.applied_version" "$MODDIR/.original.conf" "$MODDIR/.watchdog.pid" "$MODDIR/debug" "$MODDIR/DEBUG" 2>/dev/null || true
rm -rf "$MODDIR/.service.lock" 2>/dev/null || true

exit 0
