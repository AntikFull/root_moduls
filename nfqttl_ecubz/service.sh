#!/system/bin/sh
# Nfqttl eCubz — Фоновая служба фиксации TTL/HL и Auto VPN Tethering
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}

# Сериализуем фазу настройки ruleset. PID worker защищает последовательные
# перезапуски, а lock закрывает узкое окно двух одновременных service.sh.
SERVICE_LOCK_DIR="$MODDIR/.service.lock"
release_service_lock() {
    rm -f "$SERVICE_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || true
}
acquire_service_lock() {
    _try=0
    while [ "$_try" -lt 2 ]; do
        if mkdir "$SERVICE_LOCK_DIR" 2>/dev/null; then
            echo "$$" > "$SERVICE_LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi

        _owner=""
        [ -r "$SERVICE_LOCK_DIR/pid" ] && read -r _owner < "$SERVICE_LOCK_DIR/pid" 2>/dev/null || true
        if [ -n "$_owner" ] && [ -r "/proc/$_owner/cmdline" ]; then
            _ocmd=$(tr '\000' ' ' < "/proc/$_owner/cmdline" 2>/dev/null)
            case "$_ocmd" in
                *"$MODDIR/service.sh"*) return 1 ;;
            esac
        fi

        rm -rf "$SERVICE_LOCK_DIR" 2>/dev/null || return 1
        _try=$((_try + 1))
    done
    return 1
}

if [ "$1" != "--watchdog" ]; then
    acquire_service_lock || exit 0
    trap 'release_service_lock' EXIT
    trap 'exit 0' HUP INT TERM
fi

VERSION=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION" ] && VERSION="v15.1.4"
VERSION_CODE=$(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION_CODE" ] && VERSION_CODE="1514"

echo "$VERSION ($VERSION_CODE)" > "$MODDIR/.applied_version" 2>/dev/null || true

QUEUE_NUM=6464
TTL_VALUE=64

LOG_DIR="$MODDIR/logs"
SD_LOG_DIR="/sdcard/eCubz/logs/nfqttl_ecubz"
mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$SD_LOG_DIR" 2>/dev/null || true

WD_LOG="$LOG_DIR/nfqttl_watchdog.log"
NFQTTL_DAEMON_LOG="$LOG_DIR/nfqttl_daemon_stdout.log"
WORKER_PID_FILE="$MODDIR/.watchdog.pid"
VPN_RULES_FILE="$MODDIR/.vpn_tether_rules"
VPN_STATUS_FILE="$MODDIR/.vpn_tether_status"
VPN_PREF_MIN=3000
VPN_PREF_MAX=3099
VPN_ROUTE_TABLE_MIN=6500
VPN_ROUTE_TABLE_MAX=6599
VPN_DNS_SERVER_FILE="$MODDIR/vpn_dns_server"

ensure_sd_log_dir() {
    [ -d "$SD_LOG_DIR" ] && return 0
    mkdir -p "$SD_LOG_DIR" 2>/dev/null || return 1
}

DEBUG_MODE=0
NOQUIC=0
NO6=0
[ -f "$MODDIR/debug" ] && DEBUG_MODE=1
[ -f "$MODDIR/DEBUG" ] && DEBUG_MODE=1
[ -f "$MODDIR/noquic" ] && NOQUIC=1
[ -f "$MODDIR/no6" ] && NO6=1

# tun+ исключен из сотовых интерфейсов для предотвращения пересечения NAT
CELL_IFS="rmnet+ r_rmnet_data+ ccmni+ pdp+ v4-rmnet+ wwan+"
CLIENT_IFS="wlan+ ap+ swlan+ softap+ rndis+ usb+ bt-pan+ pan+"

IPT_W=""
if iptables -w 2 -t mangle -L -n >/dev/null 2>&1; then
    IPT_W="-w 5"
fi

IPT4() { iptables $IPT_W "$@" 2>/dev/null; }
IPT6() { ip6tables $IPT_W "$@" 2>/dev/null; }

# Сохранение исходных системных настроек для безопасного отката при удалении
ORIG_CONF="$MODDIR/.original.conf"
if [ ! -f "$ORIG_CONF" ]; then
    {
        echo "ORIG_TETHER_OFFLOAD=\"$(settings get global tether_offload_disabled 2>/dev/null || echo '')\""
        echo "ORIG_BPF_OFFLOAD=\"$(device_config get connectivity override_tether_enable_bpf_offload 2>/dev/null || echo '')\""
        echo "ORIG_PERSIST_OFFLOAD=\"$(getprop persist.sys.tether.offload.enable 2>/dev/null || echo '')\""
        echo "ORIG_IPV4_FORWARD=\"$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '1')\""
        echo "ORIG_IPV6_FORWARD=\"$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo '1')\""
        echo "ORIG_RP_FILTER=\"$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo '')\""
        echo "ORIG_IPV6_DISABLE=\"$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo '')\""
    } > "$ORIG_CONF" 2>/dev/null || true
    chmod 600 "$ORIG_CONF" 2>/dev/null || true
fi

wd_log() {
    if [ -f "$WD_LOG" ] && [ "$(wc -c < "$WD_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        tail -n 50 "$WD_LOG" > "$WD_LOG.tmp" 2>/dev/null && mv "$WD_LOG.tmp" "$WD_LOG"
    fi
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$WD_LOG"
    chmod 600 "$WD_LOG" 2>/dev/null || true
    if ensure_sd_log_dir; then
        cp -f "$WD_LOG" "$SD_LOG_DIR/nfqttl_watchdog.log" 2>/dev/null || true
    fi
}

nfqttl_daemon_log_rotate() {
    if [ -f "$NFQTTL_DAEMON_LOG" ] && [ "$(wc -c < "$NFQTTL_DAEMON_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        tail -n 200 "$NFQTTL_DAEMON_LOG" > "$NFQTTL_DAEMON_LOG.tmp" 2>/dev/null && mv "$NFQTTL_DAEMON_LOG.tmp" "$NFQTTL_DAEMON_LOG"
    fi
    chmod 600 "$NFQTTL_DAEMON_LOG" 2>/dev/null || true
    if ensure_sd_log_dir; then
        cp -f "$NFQTTL_DAEMON_LOG" "$SD_LOG_DIR/nfqttl_daemon_stdout.log" 2>/dev/null || true
    fi
}

QUEUE_DROPPED=0
USER_DROPPED=0
LAST_QUEUE_DROPPED=0
LAST_USER_DROPPED=0

nfqueue_bound() {
    [ -r /proc/net/netfilter/nfnetlink_queue ] || return 1
    while read -r _q _pid _tot _cmode _crange _qdrop _udrop _rest; do
        if [ "$_q" = "$QUEUE_NUM" ]; then
            QUEUE_DROPPED=$_qdrop
            USER_DROPPED=$_udrop
            return 0
        fi
    done < /proc/net/netfilter/nfnetlink_queue
    return 1
}

module_worker_pid_ok() {
    _pid="$1"
    [ -n "$_pid" ] || return 1
    [ -r "/proc/$_pid/cmdline" ] || return 1
    _cmd=$(tr '\000' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
    case "$_cmd" in
        *"$MODDIR/service.sh"*) return 0 ;;
    esac
    return 1
}

stop_old_worker() {
    _my_pid=$$
    _pids_to_kill=""
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _pid=${_p##*/}
        [ "$_pid" = "$_my_pid" ] && continue
        _cmd=$(tr '\000' ' ' < "$_p/cmdline" 2>/dev/null)
        case "$_cmd" in
            *"$MODDIR/service.sh"*)
                _pids_to_kill="$_pids_to_kill $_pid"
                ;;
        esac
    done
    if [ -n "$_pids_to_kill" ]; then
        kill $_pids_to_kill 2>/dev/null || true
        sleep 1
        for _pid in $_pids_to_kill; do
            [ -d "/proc/$_pid" ] && kill -9 "$_pid" 2>/dev/null || true
        done
    fi
    rm -f "$WORKER_PID_FILE" 2>/dev/null || true
}

# Остановка старых процессов выполняется строго в родительском процессе
if [ "$1" != "--watchdog" ]; then
    stop_old_worker
fi

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

nfqttl_alive() {
    for _pid in $(nfqttl_pids); do
        [ -n "$_pid" ] && return 0
    done
    return 1
}

kill_nfqttl() {
    _pids=$(nfqttl_pids)
    [ -z "$_pids" ] && return 0
    kill $_pids 2>/dev/null || true
    _w=0
    while nfqttl_alive && [ "$_w" -lt 3 ]; do
        sleep 1
        _w=$((_w + 1))
    done
    _pids=$(nfqttl_pids)
    [ -n "$_pids" ] && kill -9 $_pids 2>/dev/null || true
}

has_default_route() {
    _dev="$1"
    [ -n "$_dev" ] || return 1

    _eff4=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ "$_eff4" = "$_dev" ] && return 0
    _eff6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ "$_eff6" = "$_dev" ] && return 0

    ip route show table all 2>/dev/null | grep -E "^default .*dev $_dev([[:space:]]|$)" >/dev/null 2>&1 && return 0
    ip -6 route show table all 2>/dev/null | grep -E "^default .*dev $_dev([[:space:]]|$)" >/dev/null 2>&1 && return 0

    if [ -r /proc/net/route ]; then
        while read -r _r_if _r_dst _r_gw _r_fl _r_rest; do
            [ "$_r_if" = "$_dev" ] || continue
            [ "$_r_dst" = "00000000" ] || continue
            return 0
        done < /proc/net/route
    fi
    return 1
}

upstream_ok() {
    case "$1" in
        ''|lo|dummy*|ifb*|p2p*|wifi-aware*|sit*|gre*|erspan*|tunl*|ip6*|ovnet*) return 1 ;;
        wlan*|ap[0-9]*|swlan*|softap*|rndis*|usb*|bt-pan*|pan[0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

iface_covered_by_list() {
    _name="$1"
    shift
    for _pat in "$@"; do
        case "$_pat" in
            *+)
                _prefix=${_pat%+}
                case "$_name" in "$_prefix"*) return 0 ;; esac
                ;;
            *)
                [ "$_name" = "$_pat" ] && return 0
                ;;
        esac
    done
    return 1
}

list_has_word() {
    _needle="$1"
    shift
    for _item in "$@"; do
        [ "$_item" = "$_needle" ] && return 0
    done
    return 1
}

get_iface_v4_cidrs() {
    _dev="$1"
    ip -4 -o addr show dev "$_dev" 2>/dev/null | awk '$3 == "inet" {print $4}'
}

# Используем только реально выбранные default-egress интерфейсы, а не все
# резервные policy-routing таблицы Android. Базовые cellular-маски остаются
# в CELL_IFS, поэтому отсутствие main default не ломает обычный cellular path.
default_upstreams() {
    {
        ip route get 8.8.8.8 2>/dev/null
        ip route get 1.1.1.1 2>/dev/null
        ip -6 route get 2001:4860:4860::8888 2>/dev/null
        ip route show table main 2>/dev/null | grep '^default '
        ip -6 route show table main 2>/dev/null | grep '^default '
    } | while read -r _l; do
        _prev=""
        for _w in $_l; do
            if [ "$_prev" = "dev" ] && upstream_ok "$_w"; then
                echo "$_w"
            fi
            _prev=$_w
        done
    done | awk '!seen[$0]++'
}

# ============================================================================
# ПОДСИСТЕМА AUTO VPN TETHERING
# ============================================================================

detect_vpn_iface() {
    _def_dev=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    case "$_def_dev" in
        tun*|wg*|awg*|vpn*)
            if ip addr show "$_def_dev" 2>/dev/null | grep -q "inet "; then
                echo "$_def_dev"
                return 0
            fi
            ;;
    esac
    for _if in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg|awg|vpn)[0-9]*'); do
        _if="${_if%%@*}"
        if ip addr show "$_if" 2>/dev/null | grep -q "inet "; then
            echo "$_if"
            return 0
        fi
    done
    return 1
}

vpn_table_route_get_dev() {
    _tbl="$1"
    _dst="$2"
    _line=$(ip route get "$_dst" table "$_tbl" 2>/dev/null | head -n 1)
    [ -n "$_line" ] || _line=$(ip route get "$_dst" lookup "$_tbl" 2>/dev/null | head -n 1)
    echo "$_line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

vpn_table_has_tun_routes() {
    _tbl="$1"
    _tun="$2"
    [ -n "$_tbl" ] && [ -n "$_tun" ] || return 1

    _routes=$(ip route show table "$_tbl" 2>/dev/null)
    [ -n "$_routes" ] || return 1

    # Обычный full-tunnel default.
    echo "$_routes" | grep -E "^default .*dev $_tun([[:space:]]|$)" >/dev/null 2>&1 && return 0

    # Android/некоторые VPN-клиенты представляют default двумя /1 маршрутами.
    if echo "$_routes" | grep -E "^0\.0\.0\.0/1 .*dev $_tun([[:space:]]|$)" >/dev/null 2>&1 && \
       echo "$_routes" | grep -E "^128\.0\.0\.0/1 .*dev $_tun([[:space:]]|$)" >/dev/null 2>&1; then
        return 0
    fi

    # Split-route VPN: принимаем явно добавленные маршруты через VPN,
    # но не считаем достаточным один host-route (/32) или обычный connected
    # proto-kernel route интерфейса — это уменьшает ложные активации.
    echo "$_routes" | awk -v dev="$_tun" '
        {
            hasdev=0; iskernel=0
            for (i=1; i<=NF; i++) {
                if ($i=="dev" && $(i+1)==dev) hasdev=1
                if ($i=="proto" && $(i+1)=="kernel") iskernel=1
            }
            if (!hasdev || iskernel) next
            dst=$1
            if (dst=="default") {ok=1; exit}
            if (dst ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
                split(dst,a,"/")
                if ((a[2]+0) < 32) {ok=1; exit}
            }
        }
        END {exit ok ? 0 : 1}'
}

vpn_table_usable() {
    _tbl="$1"
    _tun="$2"
    [ -n "$_tbl" ] && [ -n "$_tun" ] || return 1

    # Самая надёжная проверка: что lookup в конкретной таблице реально
    # выбирает VPN для публичного адреса. Поддерживает default, /1 и сложные
    # policy-route таблицы. Если iproute2 на прошивке не умеет "route get table",
    # ниже остаётся структурный fallback по содержимому таблицы.
    _d1=$(vpn_table_route_get_dev "$_tbl" 1.1.1.1)
    _d2=$(vpn_table_route_get_dev "$_tbl" 8.8.8.8)
    [ "$_d1" = "$_tun" ] && return 0
    [ "$_d2" = "$_tun" ] && return 0

    vpn_table_has_tun_routes "$_tbl" "$_tun"
}

get_vpn_table() {
    _tun="$1"
    [ -z "$_tun" ] && return 1

    # 0. Если текущий effective route уже идёт через VPN, сначала пробуем
    # таблицу, которую сообщает ip route get (Android часто использует имена
    # вроде tun0 или numeric netId tables).
    _eff=$(ip route get 8.8.8.8 2>/dev/null | head -n 1)
    _eff_dev=$(echo "$_eff" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    _eff_tbl=$(echo "$_eff" | awk '{for(i=1;i<=NF;i++) if($i=="table") {print $(i+1); exit}}')
    if [ "$_eff_dev" = "$_tun" ] && [ -n "$_eff_tbl" ] && vpn_table_usable "$_eff_tbl" "$_tun"; then
        echo "$_eff_tbl"
        return 0
    fi

    # 1. Android rt_tables mapping интерфейс -> table id.
    if [ -r /data/misc/net/rt_tables ]; then
        _idx=$(awk -v iface="$_tun" '$2 == iface {print $1; exit}' /data/misc/net/rt_tables 2>/dev/null)
        if [ -n "$_idx" ] && vpn_table_usable "$_idx" "$_tun"; then
            echo "$_idx"
            return 0
        fi
    fi

    # 2. Таблица может называться как интерфейс (tun0/wg0/...).
    if vpn_table_usable "$_tun" "$_tun"; then
        echo "$_tun"
        return 0
    fi

    # 3. Основной Android path: таблицы, реально участвующие в policy rules.
    for _tbl in $(ip rule show 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lookup") print $(i+1)}' | sort -u); do
        case "$_tbl" in
            local|default|unspec|253|255) continue ;;
        esac
        if vpn_table_usable "$_tbl" "$_tun"; then
            echo "$_tbl"
            return 0
        fi
    done

    # 4. Некоторые Android/VPN реализации имеют маршруты в таблице, которая
    # не показана явным lookup в текущем ip rule snapshot. Извлекаем table id
    # прямо из `ip route show table all` для маршрутов через туннель.
    for _tbl in $(ip route show table all 2>/dev/null | awk -v dev="$_tun" '
        {
            hasdev=0; tbl="main"
            for(i=1;i<=NF;i++) {
                if($i=="dev" && $(i+1)==dev) hasdev=1
                if($i=="table" && i<NF) tbl=$(i+1)
            }
            if(hasdev) print tbl
        }' | awk '!seen[$0]++'); do
        case "$_tbl" in local|default|unspec|253|255) continue ;; esac
        if vpn_table_usable "$_tbl" "$_tun"; then
            echo "$_tbl"
            return 0
        fi
    done

    return 1
}

get_active_tether_ifaces() {
    _wan_list="$1"
    _tether_list=""

    # Фактический uplink самого телефона исключаем напрямую. Это защищает от
    # ложной классификации Wi-Fi uplink как downstream при сложном policy routing.
    _host_egress4=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    _host_egress6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')

    # Только RFC1918 IPv4 на ожидаемых downstream-типах. Обычный Wi-Fi uplink
    # исключается фактическим host-egress, наличием default route и списком upstreams.
    _all_ifaces=$(ip -4 -o addr show 2>/dev/null | awk '
        $3 == "inet" {
            split($4, a, "/"); split(a[1], o, ".");
            if (o[1] == 10 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168)) print $2
        }')

    for _if in $_all_ifaces; do
        _if="${_if%%@*}"
        iface_covered_by_list "$_if" $CLIENT_IFS || continue
        list_has_word "$_if" $_wan_list && continue
        [ "$_if" = "$_host_egress4" ] && continue
        [ -n "$_host_egress6" ] && [ "$_if" = "$_host_egress6" ] && continue
        has_default_route "$_if" && continue
        _is_down=0
        _st=""
        if [ -r "/sys/class/net/$_if/operstate" ]; then
            read -r _st < "/sys/class/net/$_if/operstate" 2>/dev/null || _st=""
        fi
        case "$_st" in
            down)
                _is_down=1
                ;;
            up)
                _is_down=0
                ;;
            *)
                # Если operstate пустой, unknown или файл не читается — проверяем через ip link show
                if ! ip link show "$_if" 2>/dev/null | grep -q "state UP"; then
                    _is_down=1
                fi
                ;;
        esac
        [ "$_is_down" -eq 1 ] && continue
        case " $_tether_list " in *" $_if "*) continue ;; esac
        _tether_list="$_tether_list $_if"
    done
    echo "${_tether_list# }"
}

tether_up() {
    _t_ifaces=$(get_active_tether_ifaces "$UPSTREAMS")
    [ -n "$_t_ifaces" ]
}

alloc_vpn_pref() {
    _avp_p=$VPN_PREF_MIN
    while [ "$_avp_p" -le "$VPN_PREF_MAX" ]; do
        if ! ip rule show 2>/dev/null | awk -v p="${_avp_p}:" '$1 == p {found=1} END {exit found ? 0 : 1}'; then
            echo "$_avp_p"
            return 0
        fi
        _avp_p=$((_avp_p + 1))
    done
    return 1
}

alloc_vpn_route_table() {
    _avt_tbl=$VPN_ROUTE_TABLE_MIN
    while [ "$_avt_tbl" -le "$VPN_ROUTE_TABLE_MAX" ]; do
        _avt_used=0
        ip rule show 2>/dev/null | grep -Eq "lookup[[:space:]]+${_avt_tbl}([[:space:]]|$)" && _avt_used=1
        [ -n "$(ip route show table "$_avt_tbl" 2>/dev/null)" ] && _avt_used=1
        [ -n "$(ip -6 route show table "$_avt_tbl" 2>/dev/null)" ] && _avt_used=1
        if [ -r /data/misc/net/rt_tables ] && awk -v t="$_avt_tbl" '$1 == t {found=1} END {exit found ? 0 : 1}' /data/misc/net/rt_tables 2>/dev/null; then
            _avt_used=1
        fi
        if [ "$_avt_used" -eq 0 ]; then
            echo "$_avt_tbl"
            return 0
        fi
        _avt_tbl=$((_avt_tbl + 1))
    done
    return 1
}

owned_vpn_route_table() {
    [ -r "$VPN_RULES_FILE" ] || return 1
    awk -F'|' '$1 == "ROUTE4" && $2 != "" {print $2; exit}' "$VPN_RULES_FILE" 2>/dev/null
}

vpn_pref_iif_table_present() {
    _vpip_pref="$1"
    _vpip_iif="$2"
    _vpip_tbl="$3"
    ip rule show 2>/dev/null | awk -v p="${_vpip_pref}:" -v i="$_vpip_iif" -v t="$_vpip_tbl" '
        $1 == p {
            hasi=0; hast=0
            for (n=1; n<=NF; n++) {
                if ($n == "iif" && $(n+1) == i) hasi=1
                if ($n == "lookup" && $(n+1) == t) hast=1
            }
            if (hasi && hast) found=1
        }
        END {exit found ? 0 : 1}'
}

vpn_owned_table_usable() {
    _votu_tbl="$1"
    _votu_tun="$2"
    [ -n "$_votu_tbl" ] && [ -n "$_votu_tun" ] || return 1
    _votu_dev=$(vpn_table_route_get_dev "$_votu_tbl" 1.1.1.1)
    [ "$_votu_dev" = "$_votu_tun" ] && return 0
    _votu_dev=$(vpn_table_route_get_dev "$_votu_tbl" 8.8.8.8)
    [ "$_votu_dev" = "$_votu_tun" ]
}

valid_ipv4_literal() {
    echo "$1" | awk -F. '
        BEGIN {bad=0}
        NF != 4 {bad=1}
        {
            for (i=1; i<=4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) bad=1
            }
        }
        END {exit bad ? 1 : 0}' >/dev/null 2>&1
}

read_vpn_dns_server() {
    [ -r "$VPN_DNS_SERVER_FILE" ] || return 1
    _dns=$(head -n 1 "$VPN_DNS_SERVER_FILE" 2>/dev/null | tr -d '[:space:]')
    valid_ipv4_literal "$_dns" || return 1
    echo "$_dns"
}

cleanup_vpn_tether_rules() {
    # Удаляем ТОЛЬКО policy rules и маршрут, которые записал сам модуль.
    # Поддерживаем старый state-формат для миграции.
    if [ -f "$VPN_RULES_FILE" ]; then
        while IFS= read -r _cvtr_line || [ -n "$_cvtr_line" ]; do
            [ -z "$_cvtr_line" ] && continue
            case "$_cvtr_line" in
                RULE4\|*)
                    _cvtr_oldifs=$IFS; IFS='|'; set -- $_cvtr_line; IFS=$_cvtr_oldifs
                    _cvtr_pref="$2"; _cvtr_iif="$3"; _cvtr_tbl="$4"
                    [ -n "$_cvtr_pref" ] && [ -n "$_cvtr_iif" ] && [ -n "$_cvtr_tbl" ] && \
                        ip rule del iif "$_cvtr_iif" lookup "$_cvtr_tbl" pref "$_cvtr_pref" 2>/dev/null || true
                    ;;
                ROUTE4\|*)
                    _cvtr_oldifs=$IFS; IFS='|'; set -- $_cvtr_line; IFS=$_cvtr_oldifs
                    _cvtr_tbl="$2"; _cvtr_dev="$3"; _cvtr_dst="$4"
                    if [ -n "$_cvtr_tbl" ] && [ -n "$_cvtr_dev" ] && [ "$_cvtr_dst" = "default" ]; then
                        ip route del default dev "$_cvtr_dev" table "$_cvtr_tbl" 2>/dev/null || true
                    fi
                    ;;
                iif\ *\ lookup\ *\ pref\ *)
                    set -- $_cvtr_line
                    if [ "$1" = "iif" ] && [ "$3" = "lookup" ] && [ "$5" = "pref" ]; then
                        ip rule del iif "$2" lookup "$4" pref "$6" 2>/dev/null || true
                    fi
                    ;;
            esac
        done < "$VPN_RULES_FILE"
        rm -f "$VPN_RULES_FILE" 2>/dev/null || true
    fi

    # Никаких глобальных sweep по pref 3000 / TCPMSS / IPv6 DROP.
    del_jump IPT4 filter FORWARD     nfqttl_vpn_fwd
    del_jump IPT4 nat    POSTROUTING nfqttl_vpn_nat
    del_jump IPT4 nat    PREROUTING  nfqttl_vpn_dns
    del_jump IPT6 filter FORWARD     nfqttl_vpn6_fwd

    drop_chain IPT4 filter nfqttl_vpn_fwd
    drop_chain IPT4 nat    nfqttl_vpn_nat
    drop_chain IPT4 nat    nfqttl_vpn_dns
    drop_chain IPT6 filter nfqttl_vpn6_fwd

    ip route flush cache 2>/dev/null || true
    rm -f "$VPN_STATUS_FILE" 2>/dev/null || true
}

vpn_state_healthy() {
    _vsh_tun_dev="$1"
    _vsh_source_tbl="$2"
    _vsh_tether_devs="$3"

    [ -n "$_vsh_tun_dev" ] && [ -n "$_vsh_source_tbl" ] && [ -n "$_vsh_tether_devs" ] || return 1
    # Android/VPN source table используется как признак того, что VPN всё ещё жив.
    vpn_table_usable "$_vsh_source_tbl" "$_vsh_tun_dev" || return 1
    [ -s "$VPN_RULES_FILE" ] || return 1

    _vsh_owned_tbl=$(owned_vpn_route_table)
    [ -n "$_vsh_owned_tbl" ] || return 1
    vpn_owned_table_usable "$_vsh_owned_tbl" "$_vsh_tun_dev" || return 1

    IPT4 -t filter -C FORWARD -j nfqttl_vpn_fwd || return 1
    IPT4 -t nat -C POSTROUTING -j nfqttl_vpn_nat || return 1
    IPT6 -t filter -C FORWARD -j nfqttl_vpn6_fwd || return 1

    _vsh_dns=$(read_vpn_dns_server 2>/dev/null)
    if [ -n "$_vsh_dns" ]; then
        IPT4 -t nat -C PREROUTING -j nfqttl_vpn_dns || return 1
    fi

    while IFS='|' read -r _vsh_kind _vsh_pref _vsh_iif _vsh_tbl || [ -n "$_vsh_kind$_vsh_pref$_vsh_iif$_vsh_tbl" ]; do
        [ "$_vsh_kind" = "RULE4" ] || continue
        vpn_pref_iif_table_present "$_vsh_pref" "$_vsh_iif" "$_vsh_tbl" || return 1
    done < "$VPN_RULES_FILE"

    for _vsh_tif in $_vsh_tether_devs; do
        IPT4 -t filter -C nfqttl_vpn_fwd -i "$_vsh_tif" -o "$_vsh_tun_dev" -j ACCEPT || return 1
        IPT4 -t filter -C nfqttl_vpn_fwd -i "$_vsh_tun_dev" -o "$_vsh_tif" -m state --state RELATED,ESTABLISHED -j ACCEPT || return 1
    done
    return 0
}

apply_vpn_tether_rules() {
    _avtr_tun_dev="$1"
    _avtr_source_tbl="$2"
    _avtr_tether_devs="$3"

    [ -n "$_avtr_tun_dev" ] && [ -n "$_avtr_source_tbl" ] && [ -n "$_avtr_tether_devs" ] || return 1
    vpn_table_usable "$_avtr_source_tbl" "$_avtr_tun_dev" || {
        wd_log "Auto VPN: исходная VPN-таблица $_avtr_source_tbl не имеет рабочего IPv4 route через $_avtr_tun_dev — режим не применён"
        return 1
    }

    cleanup_vpn_tether_rules
    : > "$VPN_RULES_FILE" 2>/dev/null || return 1
    chmod 600 "$VPN_RULES_FILE" 2>/dev/null || true

    # 1. Собственная routing table только для forwarded-трафика раздачи.
    # Мы не меняем default route телефона и не зависим от uid/fwmark-логики netd.
    _avtr_owned_tbl=$(alloc_vpn_route_table) || {
        wd_log "Auto VPN: нет свободной routing table в диапазоне $VPN_ROUTE_TABLE_MIN-$VPN_ROUTE_TABLE_MAX"
        cleanup_vpn_tether_rules
        return 1
    }
    if ip route add default dev "$_avtr_tun_dev" table "$_avtr_owned_tbl" 2>/dev/null; then
        echo "ROUTE4|$_avtr_owned_tbl|$_avtr_tun_dev|default" >> "$VPN_RULES_FILE"
    else
        wd_log "Auto VPN: не удалось создать default route через $_avtr_tun_dev в table $_avtr_owned_tbl"
        cleanup_vpn_tether_rules
        return 1
    fi
    vpn_owned_table_usable "$_avtr_owned_tbl" "$_avtr_tun_dev" || {
        wd_log "Auto VPN: собственная table $_avtr_owned_tbl не маршрутизирует через $_avtr_tun_dev — rollback"
        cleanup_vpn_tether_rules
        return 1
    }

    # 2. Policy Routing: только пакеты, пришедшие с активных downstream.
    for _avtr_tif in $_avtr_tether_devs; do
        _avtr_pref=$(alloc_vpn_pref) || {
            wd_log "Auto VPN: нет свободного policy-rule preference в диапазоне $VPN_PREF_MIN-$VPN_PREF_MAX"
            cleanup_vpn_tether_rules
            return 1
        }
        if ip rule add iif "$_avtr_tif" lookup "$_avtr_owned_tbl" pref "$_avtr_pref" 2>/dev/null; then
            echo "RULE4|$_avtr_pref|$_avtr_tif|$_avtr_owned_tbl" >> "$VPN_RULES_FILE"
        else
            wd_log "Auto VPN: не удалось добавить ip rule для $_avtr_tif -> table $_avtr_owned_tbl"
            cleanup_vpn_tether_rules
            return 1
        fi
    done

    # 3. FORWARD: только конкретные downstream<->VPN пары.
    IPT4 -N nfqttl_vpn_fwd || { cleanup_vpn_tether_rules; return 1; }
    IPT4 -F nfqttl_vpn_fwd || { cleanup_vpn_tether_rules; return 1; }
    IPT4 -I FORWARD 1 -j nfqttl_vpn_fwd || { cleanup_vpn_tether_rules; return 1; }
    IPT4 -A nfqttl_vpn_fwd -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || { cleanup_vpn_tether_rules; return 1; }
    for _avtr_tif in $_avtr_tether_devs; do
        IPT4 -A nfqttl_vpn_fwd -i "$_avtr_tif" -o "$_avtr_tun_dev" -j ACCEPT || { cleanup_vpn_tether_rules; return 1; }
        IPT4 -A nfqttl_vpn_fwd -i "$_avtr_tun_dev" -o "$_avtr_tif" -m state --state RELATED,ESTABLISHED -j ACCEPT || { cleanup_vpn_tether_rules; return 1; }
    done

    # 4. NAT только для адресов реально активных downstream-интерфейсов.
    IPT4 -t nat -N nfqttl_vpn_nat || { cleanup_vpn_tether_rules; return 1; }
    IPT4 -t nat -F nfqttl_vpn_nat || { cleanup_vpn_tether_rules; return 1; }
    IPT4 -t nat -I POSTROUTING 1 -j nfqttl_vpn_nat || { cleanup_vpn_tether_rules; return 1; }
    for _avtr_tif in $_avtr_tether_devs; do
        _avtr_src_seen=0
        for _avtr_src in $(get_iface_v4_cidrs "$_avtr_tif"); do
            _avtr_src_seen=1
            IPT4 -t nat -A nfqttl_vpn_nat -s "$_avtr_src" -o "$_avtr_tun_dev" -j MASQUERADE || { cleanup_vpn_tether_rules; return 1; }
        done
        [ "$_avtr_src_seen" -eq 1 ] || {
            wd_log "Auto VPN: у $_avtr_tif нет IPv4 CIDR для безопасного NAT"
            cleanup_vpn_tether_rules
            return 1
        }
    done

    # 5. DNS override остаётся только явной опцией пользователя.
    _avtr_vpn_dns=$(read_vpn_dns_server 2>/dev/null)
    if [ -n "$_avtr_vpn_dns" ]; then
        IPT4 -t nat -N nfqttl_vpn_dns || { cleanup_vpn_tether_rules; return 1; }
        IPT4 -t nat -F nfqttl_vpn_dns || { cleanup_vpn_tether_rules; return 1; }
        IPT4 -t nat -I PREROUTING 1 -j nfqttl_vpn_dns || { cleanup_vpn_tether_rules; return 1; }
        for _avtr_tif in $_avtr_tether_devs; do
            IPT4 -t nat -A nfqttl_vpn_dns -i "$_avtr_tif" -p udp --dport 53 -j DNAT --to-destination "$_avtr_vpn_dns:53" || { cleanup_vpn_tether_rules; return 1; }
            IPT4 -t nat -A nfqttl_vpn_dns -i "$_avtr_tif" -p tcp --dport 53 -j DNAT --to-destination "$_avtr_vpn_dns:53" || { cleanup_vpn_tether_rules; return 1; }
        done
    fi

    # 6. IPv6 в Auto VPN изолирован в собственной цепочке.
    IPT6 -N nfqttl_vpn6_fwd || { cleanup_vpn_tether_rules; return 1; }
    IPT6 -F nfqttl_vpn6_fwd || { cleanup_vpn_tether_rules; return 1; }
    IPT6 -I FORWARD 1 -j nfqttl_vpn6_fwd || { cleanup_vpn_tether_rules; return 1; }
    for _avtr_tif in $_avtr_tether_devs; do
        IPT6 -A nfqttl_vpn6_fwd -i "$_avtr_tif" -j DROP || { cleanup_vpn_tether_rules; return 1; }
        IPT6 -A nfqttl_vpn6_fwd -o "$_avtr_tif" -j DROP || { cleanup_vpn_tether_rules; return 1; }
    done

    ip route flush cache 2>/dev/null || true

    if ! vpn_state_healthy "$_avtr_tun_dev" "$_avtr_source_tbl" "$_avtr_tether_devs"; then
        wd_log "Auto VPN: post-apply validation FAILED — выполнен rollback"
        cleanup_vpn_tether_rules
        return 1
    fi

    echo "VPN: $_avtr_tun_dev -> $(echo $_avtr_tether_devs | tr ' ' '/') [src_tbl:$_avtr_source_tbl tether_tbl:$_avtr_owned_tbl]" > "$VPN_STATUS_FILE" 2>/dev/null || {
        cleanup_vpn_tether_rules
        return 1
    }
    wd_log "Auto VPN Tethering активирован: $_avtr_tun_dev (source table: $_avtr_source_tbl, tether table: $_avtr_owned_tbl) -> [$_avtr_tether_devs]"
    return 0
}

# ============================================================================

ensure_nfqttl_running() {
    nfqttl_daemon_log_rotate
    _attempt=1
    while [ "$_attempt" -le 5 ]; do
        if nfqttl_alive && nfqueue_bound; then
            return 0
        fi

        if nfqttl_alive; then
            wd_log "ensure: демон жив, очередь $QUEUE_NUM не подтверждена; перезапуск #$_attempt"
            kill_nfqttl
            _w=0
            while nfqttl_alive && [ "$_w" -lt 5 ]; do
                sleep 1
                _w=$((_w + 1))
            done
        fi

        [ "$_attempt" -gt 1 ] && sleep 1
        echo "===== $(date '+%Y-%m-%d %H:%M:%S') ensure start #$_attempt =====" >> "$NFQTTL_DAEMON_LOG"
        "$MODDIR/nfqttl" -d >> "$NFQTTL_DAEMON_LOG" 2>&1

        _w=0
        while [ "$_w" -lt 5 ]; do
            if nfqttl_alive && nfqueue_bound; then
                wd_log "ensure: очередь $QUEUE_NUM подтверждена (попытка #$_attempt)"
                return 0
            fi
            sleep 1
            _w=$((_w + 1))
        done
        _attempt=$((_attempt + 1))
    done

    wd_log "ensure: ОШИБКА — очередь $QUEUE_NUM не забинжена после 5 попыток"
    return 1
}

kill_offload() {
    [ -f "$MODDIR/keep_offload" ] && return 0
    device_config put connectivity override_tether_enable_bpf_offload false 2>/dev/null || true
    settings put global tether_offload_disabled 1 2>/dev/null || true
    setprop persist.sys.tether.offload.enable false 2>/dev/null || true
}
kill_offload

apply_forward_sysctl() {
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
    echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
    if [ "$NO6" -eq 0 ]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
    fi
}
apply_forward_sysctl

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

# Полная очистка старых цепочек
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

cleanup_vpn_tether_rules
kill_nfqttl

UPSTREAMS=$(default_upstreams)
for _u in $UPSTREAMS; do
    iface_covered_by_list "$_u" $CELL_IFS || CELL_IFS="$CELL_IFS $_u"
done

# ============================================================================
# РЕАЛЬНАЯ ПРОВЕРКА ВОЗМОЖНОСТЕЙ ЯДРА (KERNEL PROBE В ТЕСТОВЫХ ЦЕПОЧКАХ)
# ============================================================================

test_native_ttl4() {
    IPT4 -t mangle -N _probe_ttl 2>/dev/null || return 1
    IPT4 -t mangle -A _probe_ttl -j TTL --ttl-set $TTL_VALUE 2>/dev/null
    _res=$?
    IPT4 -t mangle -F _probe_ttl 2>/dev/null
    IPT4 -t mangle -X _probe_ttl 2>/dev/null
    [ "$_res" -eq 0 ] && return 0
    return 1
}

test_native_hl6() {
    IPT6 -t mangle -N _probe_hl 2>/dev/null || return 1
    IPT6 -t mangle -A _probe_hl -j HL --hl-set $TTL_VALUE 2>/dev/null
    _res=$?
    IPT6 -t mangle -F _probe_hl 2>/dev/null
    IPT6 -t mangle -X _probe_hl 2>/dev/null
    [ "$_res" -eq 0 ] && return 0
    return 1
}

test_str4() {
    IPT4 -t mangle -N _probe_str 2>/dev/null || return 1
    IPT4 -t mangle -A _probe_str -m string --string "test" --algo bm -j ACCEPT 2>/dev/null
    _res=$?
    IPT4 -t mangle -F _probe_str 2>/dev/null
    IPT4 -t mangle -X _probe_str 2>/dev/null
    [ "$_res" -eq 0 ] && return 0
    return 1
}

test_str6() {
    IPT6 -t mangle -N _probe_str 2>/dev/null || return 1
    IPT6 -t mangle -A _probe_str -m string --string "test" --algo bm -j ACCEPT 2>/dev/null
    _res=$?
    IPT6 -t mangle -F _probe_str 2>/dev/null
    IPT6 -t mangle -X _probe_str 2>/dev/null
    [ "$_res" -eq 0 ] && return 0
    return 1
}

test_nfqueue4_rule() {
    IPT4 -t mangle -F _probe_nfq 2>/dev/null || true
    IPT4 -t mangle -X _probe_nfq 2>/dev/null || true
    IPT4 -t mangle -N _probe_nfq 2>/dev/null || return 1
    IPT4 -t mangle -A _probe_nfq -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass 2>/dev/null
    _res=$?
    IPT4 -t mangle -F _probe_nfq 2>/dev/null
    IPT4 -t mangle -X _probe_nfq 2>/dev/null
    [ "$_res" -eq 0 ]
}

test_nfqueue6_rule() {
    IPT6 -t mangle -F _probe_nfq 2>/dev/null || true
    IPT6 -t mangle -X _probe_nfq 2>/dev/null || true
    IPT6 -t mangle -N _probe_nfq 2>/dev/null || return 1
    IPT6 -t mangle -A _probe_nfq -m hl ! --hl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass 2>/dev/null
    _res=$?
    IPT6 -t mangle -F _probe_nfq 2>/dev/null
    IPT6 -t mangle -X _probe_nfq 2>/dev/null
    [ "$_res" -eq 0 ]
}

HAS_TTL4=0
HAS_HL6=0
HAS_STR4=0
HAS_STR6=0
HAS_NFQ4_RULE=0
HAS_NFQ6_RULE=0

test_native_ttl4 && HAS_TTL4=1
test_native_hl6  && HAS_HL6=1
test_str4        && HAS_STR4=1
test_str6        && HAS_STR6=1
test_nfqueue4_rule && HAS_NFQ4_RULE=1
test_nfqueue6_rule && HAS_NFQ6_RULE=1

USE_NFQ=0
[ "$HAS_TTL4" -eq 0 ] && [ "$HAS_NFQ4_RULE" -eq 1 ] && USE_NFQ=1
[ "$HAS_HL6" -eq 0 ] && [ "$HAS_NFQ6_RULE" -eq 1 ] && USE_NFQ=1

[ "$HAS_TTL4" -eq 0 ] && [ "$HAS_NFQ4_RULE" -eq 0 ] && wd_log "CRITICAL: IPv4 — нет ни native TTL target, ни рабочего NFQUEUE+ttl rule path"
[ "$HAS_HL6" -eq 0 ] && [ "$HAS_NFQ6_RULE" -eq 0 ] && wd_log "CRITICAL: IPv6 — нет ни native HL target, ни рабочего NFQUEUE+hl rule path"

if [ "$USE_NFQ" -eq 1 ]; then
    ensure_nfqttl_running || wd_log "CRITICAL: NFQUEUE fallback нужен, но daemon/queue не подтвердились"
fi

# 1. PREROUTING Ingress Fix
for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlp
    "$_cmd" -t mangle -F nfqttlp
done

INGRESS4_MODE="none"
INGRESS6_MODE="none"

if [ "$HAS_TTL4" -eq 1 ]; then
    for _c in $CELL_IFS; do
        IPT4 -t mangle -A nfqttlp -i "$_c" -j TTL --ttl-set $TTL_VALUE
    done
    INGRESS4_MODE="native"
elif [ -f "$MODDIR/ingressfix" ] && [ "$HAS_NFQ4_RULE" -eq 1 ]; then
    for _c in $CELL_IFS; do
        IPT4 -t mangle -A nfqttlp -i "$_c" -m ttl --ttl-lt 3 -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
    done
    INGRESS4_MODE="nfqueue"
fi

if [ "$HAS_HL6" -eq 1 ]; then
    for _c in $CELL_IFS; do
        IPT6 -t mangle -A nfqttlp -i "$_c" -j HL --hl-set $TTL_VALUE
    done
    INGRESS6_MODE="native"
elif [ -f "$MODDIR/ingressfix" ] && [ "$HAS_NFQ6_RULE" -eq 1 ]; then
    for _c in $CELL_IFS; do
        IPT6 -t mangle -A nfqttlp -i "$_c" -m hl --hl-lt 3 -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
    done
    INGRESS6_MODE="nfqueue"
fi

[ "$INGRESS4_MODE" != "none" ] && IPT4 -t mangle -I PREROUTING 1 -j nfqttlp
[ "$INGRESS6_MODE" != "none" ] && IPT6 -t mangle -I PREROUTING 1 -j nfqttlp

INGRESS_MODE="v4:$INGRESS4_MODE,v6:$INGRESS6_MODE"

# 2. OUTPUT Filter (блокировка Time Exceeded для скрытия hop trace)
for _cmd in IPT4 IPT6; do
    "$_cmd" -t filter -N nfqttlf
    "$_cmd" -t filter -F nfqttlf
    "$_cmd" -t filter -I OUTPUT 1 -j nfqttlf
done

for _c in $CELL_IFS; do
    IPT4 -t filter -A nfqttlf -o "$_c" -p icmp   --icmp-type 11 -j DROP
    IPT6 -t filter -A nfqttlf -o "$_c" -p icmpv6 --icmpv6-type 3 -j DROP
done

# 3. DNS Redirect (опционально). Включаем только если на телефоне реально
# есть локальный listener :53; иначе REDIRECT может оставить клиентов без DNS.
DNS_REDIRECT_ACTIVE=0
local_dns53_listener() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -lntu 2>/dev/null | grep -E ':[5]3[[:space:]]' >/dev/null 2>&1
}
if [ -f "$MODDIR/dns_redirect" ]; then
    if local_dns53_listener; then
        IPT4 -t nat -N nfqttln
        IPT4 -t nat -F nfqttln
        IPT4 -t nat -I PREROUTING 1 -j nfqttln
        DNS_REDIRECT_ACTIVE=1
    else
        wd_log "dns_redirect запрошен, но локальный listener :53 не найден — REDIRECT не применён"
    fi
fi

# 4. FORWARD Fix — chain создаётся заранее, но разрешения добавляются только
# для реально активных downstream-интерфейсов.
IPT4 -t filter -N nfqttlfwd
IPT4 -t filter -F nfqttlfwd
IPT4 -t filter -I FORWARD 1 -j nfqttlfwd

# 5. NAT MASQUERADE — source-scoped; правила добавляет rebuild_client_scoped_rules.
IPT4 -t nat -N nfqttlnat
IPT4 -t nat -F nfqttlnat
IPT4 -t nat -I POSTROUTING 1 -j nfqttlnat

# 6. MANGLE: Blocklist и фильтрация утечек
for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlb
    "$_cmd" -t mangle -F nfqttlb
    "$_cmd" -t mangle -N nfqttlc
    "$_cmd" -t mangle -F nfqttlc
done

# Блокировка NetBIOS / SMB
for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -A nfqttlc -p udp --dport 137:138 -j DROP
    "$_cmd" -t mangle -A nfqttlc -p tcp --dport 139     -j DROP
    "$_cmd" -t mangle -A nfqttlc -p tcp --dport 445     -j DROP
done

# QUIC Drop
if [ "$NOQUIC" -eq 1 ]; then
    IPT4 -t mangle -A nfqttlc -p udp --dport 443 -j DROP
    IPT6 -t mangle -A nfqttlc -p udp --dport 443 -j DROP
fi

# IPv6 Drop на клиентских интерфейсах
if [ "$NO6" -eq 1 ]; then
    IPT6 -t mangle -A nfqttlc -j DROP
fi

# Blocklist доменов
if [ "$HAS_STR4" -eq 1 ] || [ "$HAS_STR6" -eq 1 ]; then
    BL_FILE="$MODDIR/blocklist.txt"
    if [ -f "$BL_FILE" ]; then
        while IFS= read -r _pattern || [ -n "$_pattern" ]; do
            _pattern=$(echo "$_pattern" | tr -d '\r\n')
            case "$_pattern" in
                '#'*|'') continue ;;
            esac
            [ "$HAS_STR4" -eq 1 ] && IPT4 -t mangle -A nfqttlc -p tcp -m multiport --dports 80,443 \
                -m length --length 0:1600 -m string --string "$_pattern" --algo bm -j DROP
            [ "$HAS_STR6" -eq 1 ] && IPT6 -t mangle -A nfqttlc -p tcp -m multiport --dports 80,443 \
                -m length --length 0:1600 -m string --string "$_pattern" --algo bm -j DROP
        done < "$BL_FILE"
    fi
fi

rebuild_client_scoped_rules() {
    _clients=$(get_active_tether_ifaces "$UPSTREAMS")

    IPT4 -t filter -F nfqttlfwd 2>/dev/null || true
    IPT4 -t nat -F nfqttlnat 2>/dev/null || true
    IPT4 -t mangle -F nfqttlb 2>/dev/null || true
    IPT6 -t mangle -F nfqttlb 2>/dev/null || true
    [ "$DNS_REDIRECT_ACTIVE" -eq 1 ] && IPT4 -t nat -F nfqttln 2>/dev/null || true

    for _tif in $_clients; do
        IPT4 -t filter -A nfqttlfwd -i "$_tif" -j ACCEPT
        IPT4 -t filter -A nfqttlfwd -o "$_tif" -m state --state RELATED,ESTABLISHED -j ACCEPT

        IPT4 -t mangle -A nfqttlb -i "$_tif" -j nfqttlc
        IPT6 -t mangle -A nfqttlb -i "$_tif" -j nfqttlc

        for _src in $(get_iface_v4_cidrs "$_tif"); do
            for _c in $CELL_IFS; do
                IPT4 -t nat -A nfqttlnat -s "$_src" -o "$_c" -j MASQUERADE
            done
        done

        if [ "$DNS_REDIRECT_ACTIVE" -eq 1 ]; then
            IPT4 -t nat -A nfqttln -i "$_tif" -p udp --dport 53 -j REDIRECT --to-ports 53
            IPT4 -t nat -A nfqttln -i "$_tif" -p tcp --dport 53 -j REDIRECT --to-ports 53
        fi
    done
    ACTIVE_BASE_CLIENTS="$_clients"
}

rebuild_client_scoped_rules

IPT4 -t mangle -I FORWARD 1 -j nfqttlb
IPT6 -t mangle -I FORWARD 1 -j nfqttlb

# 7. MANGLE Native TTL/HL
if [ "$HAS_TTL4" -eq 1 ] || [ "$HAS_HL6" -eq 1 ]; then
    for _cmd in IPT4 IPT6; do
        "$_cmd" -t mangle -N nfqttlo
        "$_cmd" -t mangle -F nfqttlo
    done
    [ "$HAS_TTL4" -eq 1 ] && IPT4 -t mangle -A nfqttlo -j TTL --ttl-set $TTL_VALUE
    [ "$HAS_HL6" -eq 1 ]  && IPT6 -t mangle -A nfqttlo -j HL  --hl-set $TTL_VALUE
    [ "$HAS_TTL4" -eq 1 ] && IPT4 -t mangle -I FORWARD 1 -j nfqttlo
    [ "$HAS_HL6" -eq 1 ]  && IPT6 -t mangle -I FORWARD 1 -j nfqttlo
fi

# 8. MANGLE POSTROUTING Target Chain (nfqttlq)
for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlq
    "$_cmd" -t mangle -F nfqttlq
done

apply_nfq_rules() {
    for _c in $CELL_IFS; do
        if [ "$HAS_TTL4" -eq 0 ] && [ "$HAS_NFQ4_RULE" -eq 1 ]; then
            IPT4 -t mangle -C nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass 2>/dev/null || \
            IPT4 -t mangle -A nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
        fi
        if [ "$HAS_HL6" -eq 0 ] && [ "$HAS_NFQ6_RULE" -eq 1 ]; then
            IPT6 -t mangle -C nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass 2>/dev/null || \
            IPT6 -t mangle -A nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
        fi
    done
}

for _c in $CELL_IFS; do
    if [ "$HAS_TTL4" -eq 1 ]; then
        IPT4 -t mangle -A nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j TTL --ttl-set $TTL_VALUE
    elif [ "$HAS_NFQ4_RULE" -eq 1 ]; then
        IPT4 -t mangle -A nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
    fi

    if [ "$HAS_HL6" -eq 1 ]; then
        IPT6 -t mangle -A nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j HL --hl-set $TTL_VALUE
    elif [ "$HAS_NFQ6_RULE" -eq 1 ]; then
        IPT6 -t mangle -A nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
    fi
done

IPT4 -t mangle -A POSTROUTING -j nfqttlq
IPT6 -t mangle -A POSTROUTING -j nfqttlq

requeue_tail() {
    del_jump IPT4 mangle POSTROUTING nfqttlq
    del_jump IPT6 mangle POSTROUTING nfqttlq
    IPT4 -t mangle -A POSTROUTING -j nfqttlq
    IPT6 -t mangle -A POSTROUTING -j nfqttlq
}

base_ruleset_healthy() {
    IPT4 -t mangle -C FORWARD -j nfqttlb || return 1
    IPT6 -t mangle -C FORWARD -j nfqttlb || return 1
    IPT4 -t mangle -C POSTROUTING -j nfqttlq || return 1
    IPT6 -t mangle -C POSTROUTING -j nfqttlq || return 1
    IPT4 -t filter -C OUTPUT -j nfqttlf || return 1
    IPT6 -t filter -C OUTPUT -j nfqttlf || return 1
    IPT4 -t filter -C FORWARD -j nfqttlfwd || return 1
    IPT4 -t nat -C POSTROUTING -j nfqttlnat || return 1
    [ "$DNS_REDIRECT_ACTIVE" -eq 0 ] || IPT4 -t nat -C PREROUTING -j nfqttln || return 1
    [ "$HAS_TTL4" -eq 0 ] || IPT4 -t mangle -C FORWARD -j nfqttlo || return 1
    [ "$HAS_HL6" -eq 0 ] || IPT6 -t mangle -C FORWARD -j nfqttlo || return 1
    [ "$INGRESS4_MODE" = "none" ] || IPT4 -t mangle -C PREROUTING -j nfqttlp || return 1
    [ "$INGRESS6_MODE" = "none" ] || IPT6 -t mangle -C PREROUTING -j nfqttlp || return 1

    # Проверяем, что target chains не просто существуют, а содержат ожидаемый path.
    if [ "$HAS_TTL4" -eq 1 ] || [ "$HAS_NFQ4_RULE" -eq 1 ]; then
        IPT4 -t mangle -S nfqttlq 2>/dev/null | grep -q -- ' -o ' || return 1
    fi
    if [ "$HAS_HL6" -eq 1 ] || [ "$HAS_NFQ6_RULE" -eq 1 ]; then
        IPT6 -t mangle -S nfqttlq 2>/dev/null | grep -q -- ' -o ' || return 1
    fi
    for _hc in $(get_active_tether_ifaces "$UPSTREAMS"); do
        IPT4 -t filter -C nfqttlfwd -i "$_hc" -j ACCEPT || return 1
        IPT4 -t mangle -C nfqttlb -i "$_hc" -j nfqttlc || return 1
        IPT6 -t mangle -C nfqttlb -i "$_hc" -j nfqttlc || return 1
    done
    return 0
}

repair_base_jumps() {
    IPT4 -t mangle -C FORWARD -j nfqttlb || IPT4 -t mangle -I FORWARD 1 -j nfqttlb
    IPT6 -t mangle -C FORWARD -j nfqttlb || IPT6 -t mangle -I FORWARD 1 -j nfqttlb
    IPT4 -t filter -C OUTPUT -j nfqttlf || IPT4 -t filter -I OUTPUT 1 -j nfqttlf
    IPT6 -t filter -C OUTPUT -j nfqttlf || IPT6 -t filter -I OUTPUT 1 -j nfqttlf
    if ! IPT4 -t filter -C FORWARD -j nfqttlfwd; then
        if [ -f "$VPN_STATUS_FILE" ] && IPT4 -t filter -S nfqttl_vpn_fwd >/dev/null 2>&1; then
            IPT4 -t filter -I FORWARD 2 -j nfqttlfwd
        else
            IPT4 -t filter -I FORWARD 1 -j nfqttlfwd
        fi
    fi
    if ! IPT4 -t nat -C POSTROUTING -j nfqttlnat; then
        if [ -f "$VPN_STATUS_FILE" ] && IPT4 -t nat -S nfqttl_vpn_nat >/dev/null 2>&1; then
            IPT4 -t nat -I POSTROUTING 2 -j nfqttlnat
        else
            IPT4 -t nat -I POSTROUTING 1 -j nfqttlnat
        fi
    fi
    if [ "$DNS_REDIRECT_ACTIVE" -eq 1 ] && ! IPT4 -t nat -C PREROUTING -j nfqttln; then
        if [ -f "$VPN_STATUS_FILE" ] && IPT4 -t nat -S nfqttl_vpn_dns >/dev/null 2>&1; then
            IPT4 -t nat -I PREROUTING 2 -j nfqttln
        else
            IPT4 -t nat -I PREROUTING 1 -j nfqttln
        fi
    fi
    [ "$HAS_TTL4" -eq 0 ] || { IPT4 -t mangle -C FORWARD -j nfqttlo || IPT4 -t mangle -I FORWARD 1 -j nfqttlo; }
    [ "$HAS_HL6" -eq 0 ] || { IPT6 -t mangle -C FORWARD -j nfqttlo || IPT6 -t mangle -I FORWARD 1 -j nfqttlo; }
    [ "$INGRESS4_MODE" = "none" ] || { IPT4 -t mangle -C PREROUTING -j nfqttlp || IPT4 -t mangle -I PREROUTING 1 -j nfqttlp; }
    [ "$INGRESS6_MODE" = "none" ] || { IPT6 -t mangle -C PREROUTING -j nfqttlp || IPT6 -t mangle -I PREROUTING 1 -j nfqttlp; }
    requeue_tail
}

restart_service_for_ruleset() {
    wd_log "CRITICAL: базовый ruleset повреждён и не восстановился точечным repair — полный безопасный restart service.sh"
    ( sleep 2; sh "$MODDIR/service.sh" >/dev/null 2>&1 ) &
    exit 0
}

verify_and_fallback_engine() {
    _need_reapply=0
    if [ "$HAS_TTL4" -eq 1 ]; then
        if ! IPT4 -t mangle -C nfqttlo -j TTL --ttl-set $TTL_VALUE 2>/dev/null; then
            wd_log "ПРЕДУПРЕЖДЕНИЕ: Нативное правило IPv4 TTL не встало в ядро! Переключение на NFQUEUE fallback."
            HAS_TTL4=0
            if test_nfqueue4_rule; then
                HAS_NFQ4_RULE=1
                USE_NFQ=1
                _need_reapply=1
            else
                HAS_NFQ4_RULE=0
                wd_log "CRITICAL: IPv4 native TTL потерян, а NFQUEUE rule probe не проходит"
            fi
        fi
    fi

    if [ "$HAS_HL6" -eq 1 ]; then
        if ! IPT6 -t mangle -C nfqttlo -j HL --hl-set $TTL_VALUE 2>/dev/null; then
            wd_log "ПРЕДУПРЕЖДЕНИЕ: Нативное правило IPv6 HL не встало в ядро! Переключение на NFQUEUE fallback."
            HAS_HL6=0
            if test_nfqueue6_rule; then
                HAS_NFQ6_RULE=1
                USE_NFQ=1
                _need_reapply=1
            else
                HAS_NFQ6_RULE=0
                wd_log "CRITICAL: IPv6 native HL потерян, а NFQUEUE rule probe не проходит"
            fi
        fi
    fi

    if [ "$_need_reapply" -eq 1 ]; then
        if ensure_nfqttl_running; then
            apply_nfq_rules
            requeue_tail
            wd_log "NFQUEUE fallback активирован и queue подтверждена."
        else
            wd_log "CRITICAL: NFQUEUE fallback требовался, но daemon/queue не поднялись"
        fi
    fi
}

verify_and_fallback_engine

wd_log "старт $VERSION: native_ttl4=$HAS_TTL4 native_hl6=$HAS_HL6 nfqueue=$USE_NFQ ingress=$INGRESS_MODE upstreams='$UPSTREAMS'"

WD_MAX_RESTARTS=50

watchdog() {
    restarts=0
    stable=0
    tether_prev=1
    LAST_VPN_DEV=""
    LAST_VPN_TABLE=""
    LAST_TETHER_DEVS=""
    LAST_VPN_STATE="none"
    LAST_BASE_TETHER_DEVS="$ACTIVE_BASE_CLIENTS"
    _ruleset_tick=0

    while true; do
        # 1. Проверка состояния раздачи
        if tether_up; then
            _interval=1
            _tether=0
        else
            _interval=10
            _tether=1
        fi

        # 2. Проверка и применение VPN Tethering
        _curr_vpn=$(detect_vpn_iface)
        _curr_tether=$(get_active_tether_ifaces "$UPSTREAMS")

        if [ -n "$_curr_vpn" ] && [ -n "$_curr_tether" ]; then
            _curr_tbl=$(get_vpn_table "$_curr_vpn" 2>/dev/null)
            if [ -n "$_curr_tbl" ]; then
                _need_vpn_apply=0
                if [ "$_curr_vpn" != "$LAST_VPN_DEV" ] || [ "$_curr_tbl" != "$LAST_VPN_TABLE" ] || [ "$_curr_tether" != "$LAST_TETHER_DEVS" ] || [ "$LAST_VPN_STATE" != "vpn" ]; then
                    _need_vpn_apply=1
                elif ! vpn_state_healthy "$_curr_vpn" "$_curr_tbl" "$_curr_tether"; then
                    wd_log "Auto VPN: health check обнаружил частично потерянный ruleset — reapply"
                    _need_vpn_apply=1
                fi

                if [ "$_need_vpn_apply" -eq 1 ]; then
                    if apply_vpn_tether_rules "$_curr_vpn" "$_curr_tbl" "$_curr_tether"; then
                        LAST_VPN_DEV="$_curr_vpn"
                        LAST_VPN_TABLE="$_curr_tbl"
                        LAST_TETHER_DEVS="$_curr_tether"
                        LAST_VPN_STATE="vpn"
                    else
                        LAST_VPN_DEV=""
                        LAST_VPN_TABLE=""
                        LAST_TETHER_DEVS=""
                        LAST_VPN_STATE="direct"
                        wd_log "Auto VPN: применение не прошло validation; оставлен direct mode"
                    fi
                fi
            elif [ "$LAST_VPN_STATE" = "vpn" ]; then
                cleanup_vpn_tether_rules
                LAST_VPN_DEV=""
                LAST_VPN_TABLE=""
                LAST_TETHER_DEVS=""
                LAST_VPN_STATE="direct"
                wd_log "Auto VPN: VPN-интерфейс есть, но usable routing table не найдена — возврат в direct mode"
            fi
        elif [ "$LAST_VPN_STATE" = "vpn" ]; then
            cleanup_vpn_tether_rules
            LAST_VPN_DEV=""
            LAST_VPN_TABLE=""
            LAST_TETHER_DEVS=""
            LAST_VPN_STATE="direct"
            wd_log "Auto VPN Tethering деактивирован (возврат в прямой режим)"
        fi

        # 3. Scope базовых FORWARD/NAT/filter правил следует за реальными downstream.
        if [ "$_curr_tether" != "$LAST_BASE_TETHER_DEVS" ]; then
            rebuild_client_scoped_rules
            LAST_BASE_TETHER_DEVS="$_curr_tether"
            wd_log "downstream scope обновлён: [$_curr_tether]"
        fi

        # 3.1 Переподтверждение правил при включении раздачи
        if [ "$_tether" -eq 0 ] && [ "$tether_prev" -ne 0 ]; then
            kill_offload
            apply_forward_sysctl
            [ "$HAS_TTL4" -eq 1 ] && { IPT4 -t mangle -C FORWARD -j nfqttlo || IPT4 -t mangle -I FORWARD 1 -j nfqttlo; }
            [ "$HAS_HL6" -eq 1 ] && { IPT6 -t mangle -C FORWARD -j nfqttlo || IPT6 -t mangle -I FORWARD 1 -j nfqttlo; }
            [ "$INGRESS4_MODE" = "native" ] && { IPT4 -t mangle -C PREROUTING -j nfqttlp || IPT4 -t mangle -I PREROUTING 1 -j nfqttlp; }
            [ "$INGRESS6_MODE" = "native" ] && { IPT6 -t mangle -C PREROUTING -j nfqttlp || IPT6 -t mangle -I PREROUTING 1 -j nfqttlp; }
            if [ "$USE_NFQ" -eq 1 ]; then
                apply_nfq_rules
            fi
            requeue_tail
            wd_log "раздача включена — offload и правила переподтверждены"
        fi
        tether_prev=$_tether

        # 4. Проверка целостности движка
        verify_and_fallback_engine

        # 4.1 Раз в несколько циклов проверяем не только daemon, но и сам packet path.
        _ruleset_tick=$((_ruleset_tick + 1))
        if [ "$_ruleset_tick" -ge 6 ]; then
            _ruleset_tick=0
            if ! base_ruleset_healthy; then
                wd_log "base ruleset health: missing jump/chain — попытка repair"
                repair_base_jumps
                rebuild_client_scoped_rules
                base_ruleset_healthy || restart_service_for_ruleset
            fi
        fi

        # 5. Мониторинг демона NFQUEUE (если используется)
        if [ "$USE_NFQ" -eq 1 ]; then
            if nfqttl_alive && nfqueue_bound; then
                stable=$((stable + 1))
                if [ "$stable" -ge 60 ] && [ "$restarts" -gt 0 ]; then
                    wd_log "демон стабилен — сброс счётчика рестартов ($restarts -> 0)"
                    restarts=0
                    stable=0
                fi
                if [ "$QUEUE_DROPPED" != "$LAST_QUEUE_DROPPED" ] || [ "$USER_DROPPED" != "$LAST_USER_DROPPED" ]; then
                    wd_log "счётчики потерь NFQUEUE изменились: queue_dropped=$QUEUE_DROPPED user_dropped=$USER_DROPPED"
                    LAST_QUEUE_DROPPED=$QUEUE_DROPPED
                    LAST_USER_DROPPED=$USER_DROPPED
                fi
            elif [ "$restarts" -ge "$WD_MAX_RESTARTS" ]; then
                wd_log "лимит перезапусков исчерпан — cooldown 300с, затем новый цикл"
                sleep 300
                restarts=0
                stable=0
                continue
            else
                restarts=$((restarts + 1))
                stable=0
                wd_log "очередь $QUEUE_NUM не подтверждена — перезапуск #$restarts"
                kill_nfqttl
                _w=0
                while nfqttl_alive && [ "$_w" -lt 5 ]; do
                    sleep 1
                    _w=$((_w + 1))
                done
                echo "===== $(date '+%Y-%m-%d %H:%M:%S') watchdog restart #$restarts =====" >> "$NFQTTL_DAEMON_LOG"
                "$MODDIR/nfqttl" -d >> "$NFQTTL_DAEMON_LOG" 2>&1
                _w=0
                while [ "$_w" -lt 5 ]; do
                    if nfqttl_alive && nfqueue_bound; then
                        apply_nfq_rules
                        requeue_tail
                        wd_log "очередь $QUEUE_NUM восстановлена и правила активированы"
                        break
                    fi
                    sleep 1
                    _w=$((_w + 1))
                done
            fi
        fi

        sleep "$_interval"
    done
}

if [ "$1" = "--watchdog" ]; then
    trap 'cleanup_vpn_tether_rules; rm -f "$WORKER_PID_FILE" 2>/dev/null || true' EXIT
    trap 'exit 0' HUP INT TERM
    echo "$$" > "$WORKER_PID_FILE" 2>/dev/null || true
    watchdog
    exit 0
fi

sh "$MODDIR/service.sh" --watchdog </dev/null >/dev/null 2>&1 &

if [ "$DEBUG_MODE" -eq 1 ] && [ -f "$MODDIR/debug_log.sh" ]; then
    sh "$MODDIR/debug_log.sh" >/dev/null 2>&1 &
fi

exit 0
