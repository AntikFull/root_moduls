#!/system/bin/sh
MODDIR=${0%/*}

VERSION=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION" ] && VERSION="v15.0.2"
VERSION_CODE=$(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$VERSION_CODE" ] && VERSION_CODE="1502"

echo "$VERSION ($VERSION_CODE)" > "$MODDIR/.applied_version" 2>/dev/null || true

QUEUE_NUM=6464
TTL_VALUE=64

LOG_DIR="$MODDIR/logs"
SD_LOG_DIR="/sdcard/eCubz/logs/nfqttl_ecubz"
mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$SD_LOG_DIR" 2>/dev/null || true

WD_LOG="$LOG_DIR/nfqttl_watchdog.log"
NFQTTL_DAEMON_LOG="$LOG_DIR/nfqttl_daemon_stdout.log"

DEBUG_MODE=0
NOQUIC=0
NO6=0
[ -f "$MODDIR/debug" ] && DEBUG_MODE=1
[ -f "$MODDIR/DEBUG" ] && DEBUG_MODE=1
[ -f "$MODDIR/noquic" ] && NOQUIC=1
[ -f "$MODDIR/no6" ] && NO6=1

CELL_IFS="rmnet+ rmnet_data+ r_rmnet_data+ rmnet_mhi+ rmnet_ipa+ ccmni+ pdp+ v4-rmnet+ v4-rmnet_data+ tun+"
CLIENT_IFS="wlan0 wlan1 wlan2 wlan+ ap+ swlan+ softap+ rndis+ usb+ bt-pan+ pan+"

IPT_W=""
if iptables -w 2 -t mangle -L -n >/dev/null 2>&1; then
    IPT_W="-w 5"
fi

IPT4() { iptables $IPT_W "$@" 2>/dev/null; }
IPT6() { ip6tables $IPT_W "$@" 2>/dev/null; }

wd_log() {
    if [ -f "$WD_LOG" ] && [ "$(wc -c < "$WD_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        tail -n 50 "$WD_LOG" > "$WD_LOG.tmp" 2>/dev/null && mv "$WD_LOG.tmp" "$WD_LOG"
    fi
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$WD_LOG"
    chmod 600 "$WD_LOG" 2>/dev/null || true
    if [ -d "$SD_LOG_DIR" ]; then
        cp -f "$WD_LOG" "$SD_LOG_DIR/nfqttl_watchdog.log" 2>/dev/null || true
    fi
}

nfqttl_daemon_log_rotate() {
    if [ -f "$NFQTTL_DAEMON_LOG" ] && [ "$(wc -c < "$NFQTTL_DAEMON_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        tail -n 200 "$NFQTTL_DAEMON_LOG" > "$NFQTTL_DAEMON_LOG.tmp" 2>/dev/null && mv "$NFQTTL_DAEMON_LOG.tmp" "$NFQTTL_DAEMON_LOG"
    fi
    chmod 600 "$NFQTTL_DAEMON_LOG" 2>/dev/null || true
    if [ -d "$SD_LOG_DIR" ]; then
        cp -f "$NFQTTL_DAEMON_LOG" "$SD_LOG_DIR/nfqttl_daemon_stdout.log" 2>/dev/null || true
    fi
}

QUEUE_DROPPED=0
USER_DROPPED=0

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

nfqttl_alive() {
    if [ -x /system/bin/pgrep ]; then
        /system/bin/pgrep -x nfqttl >/dev/null 2>&1
        return $?
    fi
    for _p in /proc/[0-9]*; do
        [ -r "$_p/comm" ] || continue
        read -r _c < "$_p/comm" 2>/dev/null || continue
        [ "$_c" = "nfqttl" ] && return 0
    done
    return 1
}

has_default_route() {
    [ -r /proc/net/route ] || return 1
    while read -r _if _dst _gw _fl _rest; do
        [ "$_if" = "$1" ] || continue
        [ "$_dst" = "00000000" ] || continue
        return 0
    done < /proc/net/route
    return 1
}

tether_up() {
    for _d in /sys/class/net/*; do
        _n=${_d##*/}
        case "$_n" in
            lo|rmnet*|r_rmnet*|ccmni*|pdp*|v4-*|clat*|tun*|ppp*|ipsec*|dummy*) continue ;;
            ifb*|sit*|gre*|erspan*|tunl*|ip6*|p2p*|wifi-aware*|nan*|aware*) continue ;;
        esac
        [ -r "$_d/operstate" ] || continue
        read -r _st < "$_d/operstate" 2>/dev/null || continue
        [ "$_st" = "up" ] || continue
        has_default_route "$_n" && continue
        return 0
    done
    return 1
}

upstream_ok() {
    case "$1" in
        ''|lo|dummy*|ifb*|p2p*|wifi-aware*|sit*|gre*|erspan*|tunl*|ip6*|ovnet*) return 1 ;;
        wlan*|ap[0-9]*|swlan*|softap*|rndis*|usb*|bt-pan*|pan[0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

default_upstreams() {
    { ip route show default 2>/dev/null; ip -6 route show default 2>/dev/null; } | while read -r _l; do
        case "$_l" in
            default*) ;;
            *) continue ;;
        esac
        _prev=""
        for _w in $_l; do
            if [ "$_prev" = "dev" ] && upstream_ok "$_w"; then
                echo "$_w"
            fi
            _prev=$_w
        done
    done
}

ensure_nfqttl_running() {
    nfqttl_daemon_log_rotate
    _attempt=1
    while [ "$_attempt" -le 5 ]; do
        if nfqttl_alive && nfqueue_bound; then
            return 0
        fi

        if nfqttl_alive; then
            wd_log "ensure: демон жив, очередь $QUEUE_NUM не подтверждена; перезапуск #$_attempt"
            pkill -9 nfqttl 2>/dev/null || true
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
    device_config put connectivity override_tether_enable_bpf_offload false 2>/dev/null || true
    settings put global tether_offload_disabled 1 2>/dev/null || true
    setprop persist.sys.tether.offload.enable false 2>/dev/null || true
}
kill_offload

echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
if [ "$NO6" -eq 0 ]; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
fi

del_jump() { # $1=IPT4|IPT6 $2=table $3=chain $4=target
    _n=0
    while [ "$_n" -lt 40 ] && "$1" -t "$2" -D "$3" -j "$4"; do
        _n=$((_n + 1))
    done
}
drop_chain() { # $1=IPT4|IPT6 $2=table $3=chain
    "$1" -t "$2" -F "$3"
    "$1" -t "$2" -X "$3"
}

for _cmd in IPT4 IPT6; do
    del_jump "$_cmd" mangle PREROUTING  nfqttlp
    del_jump "$_cmd" mangle FORWARD     nfqttlo
    del_jump "$_cmd" mangle FORWARD     nfqttlb
    del_jump "$_cmd" mangle POSTROUTING nfqttlm
    del_jump "$_cmd" mangle POSTROUTING nfqttlq
    del_jump "$_cmd" mangle OUTPUT      nfqttlo
    del_jump "$_cmd" nat    PREROUTING  nfqttln
    del_jump "$_cmd" filter OUTPUT      nfqttlf

    drop_chain "$_cmd" mangle nfqttlp
    drop_chain "$_cmd" mangle nfqttlo
    drop_chain "$_cmd" mangle nfqttlb
    drop_chain "$_cmd" mangle nfqttlc
    drop_chain "$_cmd" mangle nfqttlm
    drop_chain "$_cmd" mangle nfqttlq
    drop_chain "$_cmd" nat    nfqttln
    drop_chain "$_cmd" filter nfqttlf
done

IPT4 -t mangle -D POSTROUTING ! -o lo -j nfqttlo
_n=0
while [ "$_n" -lt 20 ] && IPT4 -t mangle -D FORWARD -j TTL --ttl-set 64; do _n=$((_n + 1)); done
_n=0
while [ "$_n" -lt 20 ] && IPT6 -t mangle -D FORWARD -j HL --hl-set 64; do _n=$((_n + 1)); done

for _c in $CELL_IFS; do
    IPT4 -t mangle -D POSTROUTING -o "$_c" -j TTL --ttl-set 64
    IPT4 -t mangle -D POSTROUTING -o "$_c" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtud
    IPT4 -t mangle -D PREROUTING -i "$_c" -m ttl --ttl-eq 1 -j DROP
    IPT4 -t mangle -D FORWARD -i "$_c" -m ttl --ttl-eq 1 -j DROP
    IPT4 -t filter -D OUTPUT -o "$_c" -p icmp --icmp-type time-exceeded -j DROP
    IPT6 -t mangle -D POSTROUTING -o "$_c" -j HL --hl-set 64
    IPT6 -t filter -D OUTPUT -o "$_c" -p icmpv6 --icmpv6-type time-exceeded -j DROP
done

for _i in wlan+ wlan0 ap+ swlan+ softap+ rndis+ usb+ bt-pan+ pan+ wlan1 wlan2; do
    IPT4 -t mangle -D POSTROUTING -o "$_i" -j TTL --ttl-set 64
    IPT4 -t mangle -D POSTROUTING -o "$_i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtud
    for _p in "udp --dport 123" "tcp --dport 853" "udp --dport 5353" "udp --dport 5355" "udp --dport 1900" "udp --dport 137:138"; do
        IPT4 -t mangle -D FORWARD -i "$_i" -p $_p -j DROP
        IPT6 -t mangle -D FORWARD -i "$_i" -p $_p -j DROP
    done
    IPT4 -t nat -D PREROUTING -i "$_i" -p udp --dport 53 -j REDIRECT --to-ports 53
    IPT4 -t nat -D PREROUTING -i "$_i" -p tcp --dport 53 -j REDIRECT --to-ports 53
    IPT6 -t nat -D PREROUTING -i "$_i" -p udp --dport 53 -j REDIRECT --to-ports 53
    IPT6 -t nat -D PREROUTING -i "$_i" -p tcp --dport 53 -j REDIRECT --to-ports 53
done

pkill -9 nfqttl 2>/dev/null || true
_w=0
while nfqttl_alive && [ "$_w" -lt 5 ]; do
    sleep 1
    _w=$((_w + 1))
done
sleep 1

UPSTREAMS=$(default_upstreams)
for _u in $UPSTREAMS; do
    case " $CELL_IFS " in
        *" $_u "*) ;;
        *) CELL_IFS="$CELL_IFS $_u" ;;
    esac
done

HAS_TTL4=0
HAS_HL6=0
grep -q TTL /proc/net/ip_tables_targets  2>/dev/null && HAS_TTL4=1
grep -q HL  /proc/net/ip6_tables_targets 2>/dev/null && HAS_HL6=1

for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlp
    "$_cmd" -t mangle -F nfqttlp
done

INGRESS_MODE="none"
if [ "$HAS_TTL4" -eq 1 ] || [ "$HAS_HL6" -eq 1 ]; then
    for _c in $CELL_IFS; do
        [ "$HAS_TTL4" -eq 1 ] && IPT4 -t mangle -A nfqttlp -i "$_c" -j TTL --ttl-set $TTL_VALUE
        [ "$HAS_HL6" -eq 1 ]  && IPT6 -t mangle -A nfqttlp -i "$_c" -j HL  --hl-set $TTL_VALUE
    done
    INGRESS_MODE="native"
fi

if [ "$INGRESS_MODE" = "none" ] && [ -f "$MODDIR/ingressfix" ]; then
    for _c in $CELL_IFS; do
        IPT4 -t mangle -A nfqttlp -i "$_c" -m ttl --ttl-lt 3 -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
        IPT6 -t mangle -A nfqttlp -i "$_c" -m hl  --hl-lt 3 -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
    done
    INGRESS_MODE="nfqueue"
fi

if [ "$INGRESS_MODE" != "none" ]; then
    IPT4 -t mangle -I PREROUTING 1 -j nfqttlp
    IPT6 -t mangle -I PREROUTING 1 -j nfqttlp
fi

for _cmd in IPT4 IPT6; do
    "$_cmd" -t filter -N nfqttlf
    "$_cmd" -t filter -F nfqttlf
done
for _c in $CELL_IFS; do
    IPT4 -t filter -A nfqttlf -o "$_c" -p icmp   --icmp-type time-exceeded   -j DROP
    IPT6 -t filter -A nfqttlf -o "$_c" -p icmpv6 --icmpv6-type time-exceeded -j DROP
done
IPT4 -t filter -A OUTPUT -j nfqttlf
IPT6 -t filter -A OUTPUT -j nfqttlf

USE_NFQ=0
for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlo
    "$_cmd" -t mangle -F nfqttlo
done

if [ "$HAS_TTL4" -eq 1 ]; then
    IPT4 -t mangle -A nfqttlo -j TTL --ttl-set $TTL_VALUE
    IPT4 -t mangle -I FORWARD 1 -j nfqttlo
fi
if [ "$HAS_HL6" -eq 1 ]; then
    IPT6 -t mangle -A nfqttlo -j HL --hl-set $TTL_VALUE
    IPT6 -t mangle -I FORWARD 1 -j nfqttlo
fi

if [ "$HAS_TTL4" -eq 0 ] || [ "$HAS_HL6" -eq 0 ]; then
    if ensure_nfqttl_running; then
        USE_NFQ=1
    else
        wd_log "NFQUEUE не активирован: очередь $QUEUE_NUM не подтверждена (ttl4=$HAS_TTL4 hl6=$HAS_HL6)"
    fi
fi

for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlb
    "$_cmd" -t mangle -F nfqttlb
    "$_cmd" -t mangle -N nfqttlc
    "$_cmd" -t mangle -F nfqttlc
done

for _i in $CLIENT_IFS; do
    IPT4 -t mangle -A nfqttlb -i "$_i" -j nfqttlc
    IPT6 -t mangle -A nfqttlb -i "$_i" -j nfqttlc
done

for _p in "udp --dport 123" "tcp --dport 853" "udp --dport 853" \
          "udp --dport 5353" "udp --dport 5355" "udp --dport 1900" \
          "udp --dport 137:138" "tcp --dport 139" "tcp --dport 445"; do
    if [ "$DEBUG_MODE" -eq 1 ]; then
        IPT4 -t mangle -A nfqttlc -p $_p -j LOG --log-prefix "NFQTTL-BLOCK: "
    fi
    IPT4 -t mangle -A nfqttlc -p $_p -j DROP
    IPT6 -t mangle -A nfqttlc -p $_p -j DROP
done

if [ "$NOQUIC" -eq 1 ]; then
    IPT4 -t mangle -A nfqttlc -p udp --dport 443 -j DROP
    IPT6 -t mangle -A nfqttlc -p udp --dport 443 -j DROP
fi

if [ "$NO6" -eq 1 ]; then
    IPT6 -t mangle -A nfqttlc -j DROP
fi

BLOCKLIST_FILE="$MODDIR/blocklist.txt"
HAS_STR4=0
HAS_STR6=0
grep -q string /proc/net/ip_tables_matches  2>/dev/null && HAS_STR4=1
grep -q string /proc/net/ip6_tables_matches 2>/dev/null && HAS_STR6=1

if [ -f "$BLOCKLIST_FILE" ] && [ "$HAS_STR4" -eq 1 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        domain=$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\r')
        [ -z "$domain" ] && continue

        if [ "$DEBUG_MODE" -eq 1 ]; then
            IPT4 -t mangle -A nfqttlc -p tcp -m multiport --dports 80,443 \
                 -m length --length 0:1600 -m string --string "$domain" --algo bm \
                 -j LOG --log-prefix "NFQTTL-BLOCK: "
        fi
        IPT4 -t mangle -A nfqttlc -p tcp -m multiport --dports 80,443 \
             -m length --length 0:1600 -m string --string "$domain" --algo bm -j DROP
        if [ "$HAS_STR6" -eq 1 ]; then
            IPT6 -t mangle -A nfqttlc -p tcp -m multiport --dports 80,443 \
                 -m length --length 0:1600 -m string --string "$domain" --algo bm -j DROP
        fi
    done < "$BLOCKLIST_FILE"
fi

IPT4 -t mangle -A FORWARD -j nfqttlb
IPT6 -t mangle -A FORWARD -j nfqttlb

for _cmd in IPT4 IPT6; do
    "$_cmd" -t nat -N nfqttln
    "$_cmd" -t nat -F nfqttln
done
for _i in $CLIENT_IFS; do
    IPT4 -t nat -A nfqttln -i "$_i" -p udp --dport 53 -j REDIRECT --to-ports 53
    IPT4 -t nat -A nfqttln -i "$_i" -p tcp --dport 53 -j REDIRECT --to-ports 53
    IPT6 -t nat -A nfqttln -i "$_i" -p udp --dport 53 -j REDIRECT --to-ports 53
    IPT6 -t nat -A nfqttln -i "$_i" -p tcp --dport 53 -j REDIRECT --to-ports 53
done
IPT4 -t nat -A PREROUTING -j nfqttln
IPT6 -t nat -A PREROUTING -j nfqttln

for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlm
    "$_cmd" -t mangle -F nfqttlm
done
for _c in $CELL_IFS; do
    IPT4 -t mangle -A nfqttlm -o "$_c" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtud
    IPT6 -t mangle -A nfqttlm -o "$_c" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtud
done
IPT4 -t mangle -A POSTROUTING -j nfqttlm
IPT6 -t mangle -A POSTROUTING -j nfqttlm

for _cmd in IPT4 IPT6; do
    "$_cmd" -t mangle -N nfqttlq
    "$_cmd" -t mangle -F nfqttlq
done

apply_nfq_rules() {
    for _c in $CELL_IFS; do
        if [ "$HAS_TTL4" -eq 0 ]; then
            IPT4 -t mangle -C nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass 2>/dev/null || \
            IPT4 -t mangle -A nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
        fi
        if [ "$HAS_HL6" -eq 0 ]; then
            IPT6 -t mangle -C nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass 2>/dev/null || \
            IPT6 -t mangle -A nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
        fi
    done
}

for _c in $CELL_IFS; do
    if [ "$HAS_TTL4" -eq 1 ]; then
        IPT4 -t mangle -A nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j TTL --ttl-set $TTL_VALUE
    elif [ "$USE_NFQ" -eq 1 ]; then
        IPT4 -t mangle -A nfqttlq -o "$_c" -m ttl ! --ttl-eq $TTL_VALUE -j NFQUEUE --queue-num $QUEUE_NUM --queue-bypass
    fi

    if [ "$HAS_HL6" -eq 1 ]; then
        IPT6 -t mangle -A nfqttlq -o "$_c" -m hl ! --hl-eq $TTL_VALUE -j HL --hl-set $TTL_VALUE
    elif [ "$USE_NFQ" -eq 1 ]; then
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

wd_log "старт $VERSION: native_ttl4=$HAS_TTL4 native_hl6=$HAS_HL6 nfqueue=$USE_NFQ ingress=$INGRESS_MODE upstreams='$UPSTREAMS'"

WD_MAX_RESTARTS=50

watchdog() {
    restarts=0
    stable=0
    tether_prev=1
    tick=0

    while true; do
        if tether_up; then
            _interval=10
            _tether=0
        else
            _interval=60
            _tether=1
        fi

        if [ "$_tether" -eq 0 ] && [ "$tether_prev" -ne 0 ]; then
            kill_offload
            echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
            echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
            [ "$HAS_TTL4" -eq 1 ] && { IPT4 -t mangle -C FORWARD -j nfqttlo || IPT4 -t mangle -I FORWARD 1 -j nfqttlo; }
            [ "$HAS_HL6" -eq 1 ] && { IPT6 -t mangle -C FORWARD -j nfqttlo || IPT6 -t mangle -I FORWARD 1 -j nfqttlo; }
            if [ "$INGRESS_MODE" != "none" ]; then
                IPT4 -t mangle -C PREROUTING -j nfqttlp || IPT4 -t mangle -I PREROUTING 1 -j nfqttlp
                IPT6 -t mangle -C PREROUTING -j nfqttlp || IPT6 -t mangle -I PREROUTING 1 -j nfqttlp
            fi
            if [ "$HAS_TTL4" -eq 0 ] || [ "$HAS_HL6" -eq 0 ]; then
                apply_nfq_rules
            fi
            requeue_tail
            wd_log "раздача включена — offload и правила переподтверждены"
        fi
        tether_prev=$_tether

        if [ "$HAS_TTL4" -eq 0 ] || [ "$HAS_HL6" -eq 0 ]; then
            if nfqueue_bound; then
                stable=$((stable + 1))
                if [ "$stable" -ge 60 ] && [ "$restarts" -gt 0 ]; then
                    wd_log "демон стабилен — сброс счётчика рестартов ($restarts -> 0)"
                    restarts=0
                    stable=0
                fi
                if [ "$QUEUE_DROPPED" != "0" ] || [ "$USER_DROPPED" != "0" ]; then
                    tick=$((tick + 1))
                    if [ $((tick % 30)) -eq 0 ]; then
                        wd_log "очередь роняет пакеты: queue_dropped=$QUEUE_DROPPED user_dropped=$USER_DROPPED"
                    fi
                fi
            elif [ "$restarts" -ge "$WD_MAX_RESTARTS" ]; then
                wd_log "лимит перезапусков исчерпан — watchdog остановлен"
                break
            else
                restarts=$((restarts + 1))
                stable=0
                wd_log "очередь $QUEUE_NUM не подтверждена — перезапуск #$restarts"
                pkill -9 nfqttl 2>/dev/null || true
                _w=0
                while nfqttl_alive && [ "$_w" -lt 5 ]; do
                    sleep 1
                    _w=$((_w + 1))
                done
                echo "===== $(date '+%Y-%m-%d %H:%M:%S') watchdog restart #$restarts =====" >> "$NFQTTL_DAEMON_LOG"
                "$MODDIR/nfqttl" -d >> "$NFQTTL_DAEMON_LOG" 2>&1
                _w=0
                while [ "$_w" -lt 5 ]; do
                    if nfqueue_bound; then
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

if [ "$HAS_TTL4" -eq 0 ] || [ "$HAS_HL6" -eq 0 ] || [ "$USE_NFQ" -eq 1 ]; then
    watchdog &
else
    (
        tether_prev=1
        while true; do
            if tether_up; then
                if [ "$tether_prev" -ne 0 ]; then
                    kill_offload
                    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
                    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
                    [ "$HAS_TTL4" -eq 1 ] && { IPT4 -t mangle -C FORWARD -j nfqttlo || IPT4 -t mangle -I FORWARD 1 -j nfqttlo; }
                    [ "$HAS_HL6" -eq 1 ] && { IPT6 -t mangle -C FORWARD -j nfqttlo || IPT6 -t mangle -I FORWARD 1 -j nfqttlo; }
                    if [ "$INGRESS_MODE" != "none" ]; then
                        IPT4 -t mangle -C PREROUTING -j nfqttlp || IPT4 -t mangle -I PREROUTING 1 -j nfqttlp
                        IPT6 -t mangle -C PREROUTING -j nfqttlp || IPT6 -t mangle -I PREROUTING 1 -j nfqttlp
                    fi
                    requeue_tail
                    wd_log "раздача включена (native TTL/HL) — правила переподтверждены"
                    tether_prev=0
                fi
                sleep 30
            else
                tether_prev=1
                sleep 60
            fi
        done
    ) &
fi

if [ "$DEBUG_MODE" -eq 1 ] && [ -f "$MODDIR/debug_log.sh" ]; then
    sh "$MODDIR/debug_log.sh" >/dev/null 2>&1 &
fi

exit 0
