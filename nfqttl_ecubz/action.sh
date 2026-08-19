#!/system/bin/sh
# Nfqttl eCubz — Скрипт действия (Action Button)
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}

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

queue_6464_bound() {
    [ -r /proc/net/netfilter/nfnetlink_queue ] || return 1
    while read -r _q _rest; do
        [ "$_q" = "6464" ] && return 0
    done < /proc/net/netfilter/nfnetlink_queue
    return 1
}

echo "================================================="
echo "   Nfqttl eCubz — Диагностика и управление       "
echo "================================================="

# 0. Проверка фонового worker service.sh
_worker_found=0
WORKER_PID_FILE="$MODDIR/.watchdog.pid"
if [ -f "$WORKER_PID_FILE" ]; then
    read -r _wpid < "$WORKER_PID_FILE" 2>/dev/null || _wpid=""
    if [ -n "$_wpid" ] && [ -r "/proc/$_wpid/cmdline" ]; then
        _wcmd=$(tr '\000' ' ' < "/proc/$_wpid/cmdline" 2>/dev/null)
        case "$_wcmd" in
            *"$MODDIR/service.sh"*)
                echo "[+] Watchdog Daemon: РАБОТАЕТ (PID: $_wpid)"
                _worker_found=1
                ;;
        esac
    fi
fi
if [ "$_worker_found" -eq 0 ]; then
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _wpid=${_p##*/}
        [ "$_wpid" = "$$" ] && continue
        _wcmd=$(tr '\000' ' ' < "$_p/cmdline" 2>/dev/null)
        case "$_wcmd" in
            *"$MODDIR/service.sh"*)
                echo "[+] Watchdog Daemon: РАБОТАЕТ (PID: $_wpid)"
                echo "$_wpid" > "$WORKER_PID_FILE" 2>/dev/null || true
                _worker_found=1
                break
                ;;
        esac
    done
fi
[ "$_worker_found" -eq 0 ] && echo "[-] Watchdog Daemon: НЕ ЗАПУЩЕН"

# 1. Проверка статуса демона
_pids=$(nfqttl_pids | tr '\n' ' ')
if [ -n "$_pids" ]; then
    echo "[+] Демон nfqttl этого модуля: РАБОТАЕТ (PID: $_pids)"
else
    echo "[-] Демон nfqttl этого модуля: НЕ ЗАПУЩЕН"
fi

# 2. Проверка очереди NFQUEUE
if queue_6464_bound; then
    echo "[+] Очередь NFQUEUE (6464): АКТИВНА"
elif [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    echo "[-] Очередь NFQUEUE (6464): Не привязана"
else
    echo "[i] Состояние NFQUEUE недоступно в /proc"
fi

# 2.1 Проверка режима Auto VPN Tethering
VPN_STATUS_FILE="$MODDIR/.vpn_tether_status"
if [ -f "$VPN_STATUS_FILE" ]; then
    read -r _vpn_st < "$VPN_STATUS_FILE" 2>/dev/null || _vpn_st=""
    echo "[+] Режим раздачи: ЧЕРЕЗ VPN ($_vpn_st)"
else
    echo "[i] Режим раздачи: ПРЯМОЙ / СОТОВЫЙ (Direct Hotspot)"
fi

# 2.2 Проверка активного движка фиксации TTL
_v4_native=$(iptables -t mangle -S nfqttlo 2>/dev/null | grep -c "TTL --ttl-set")
_v6_native=$(ip6tables -t mangle -S nfqttlo 2>/dev/null | grep -c "HL --hl-set")
_nfq=0
queue_6464_bound && _nfq=1
if [ "$_v4_native" -gt 0 ] && [ "$_v6_native" -gt 0 ]; then
    echo "[+] Движок TTL/HL: Native IPv4 + Native IPv6"
elif [ "$_v4_native" -gt 0 ] || [ "$_v6_native" -gt 0 ]; then
    if [ "$_nfq" -eq 1 ]; then
        echo "[+] Движок TTL/HL: MIXED Native + NFQUEUE"
    else
        echo "[!] Движок TTL/HL: MIXED, но NFQUEUE fallback не подтверждён"
    fi
elif [ "$_nfq" -eq 1 ] && [ -n "$(nfqttl_pids)" ]; then
    echo "[+] Движок TTL/HL: NFQUEUE Fallback (daemon + queue active)"
else
    echo "[!] Движок TTL/HL: Ожидание/DEGRADED"
fi

# 3. Переключение режима отладки
if [ -f "$MODDIR/debug" ] || [ -f "$MODDIR/DEBUG" ]; then
    rm -f "$MODDIR/debug" "$MODDIR/DEBUG" 2>/dev/null
    echo "[!] Флаг расширенной отладки: ВЫКЛЮЧЕН."
    echo "[i] Уже установленные трассировочные правила исчезнут после перезапуска службы/устройства."
else
    touch "$MODDIR/debug"
    echo "[+] Флаг расширенной отладки: ВКЛЮЧЕН."
    echo "[i] Трассировочные правила из service.sh применятся после перезапуска службы/устройства."
    echo "[+] Формирую диагностический отчёт сейчас..."
    if [ -f "$MODDIR/debug_log.sh" ]; then
        sh "$MODDIR/debug_log.sh"
    fi
    echo "[+] Отчёт: /sdcard/eCubz/logs/nfqttl_ecubz/nfqttl_debug.log"
fi

echo "================================================="
