#!/system/bin/sh
# uninstall.sh — Полная очистка при удалении модуля
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"

if [ -x "$BIN_DIR/awg-controller" ]; then
  "$BIN_DIR/awg-controller" cleanup 2>/dev/null || true
fi

killall -9 amneziawg-go 2>/dev/null || true
pkill -f awg-netmon 2>/dev/null || true
pkill -f awg-appmon 2>/dev/null || true

# Очистка iptables
iptables -w 2 -t mangle -D OUTPUT -j AWG_MANGLE 2>/dev/null || true
iptables -w 2 -t mangle -D PREROUTING -j AWG_MANGLE 2>/dev/null || true
iptables -w 2 -t mangle -F AWG_MANGLE 2>/dev/null || true
iptables -w 2 -t mangle -X AWG_MANGLE 2>/dev/null || true

iptables -w 2 -t nat -D OUTPUT -j AWG_NAT 2>/dev/null || true
iptables -w 2 -t nat -D PREROUTING -j AWG_NAT 2>/dev/null || true
iptables -w 2 -t nat -F AWG_NAT 2>/dev/null || true
iptables -w 2 -t nat -X AWG_NAT 2>/dev/null || true

iptables -w 2 -t filter -D OUTPUT -j AWG_FILTER 2>/dev/null || true
iptables -w 2 -t filter -F AWG_FILTER 2>/dev/null || true
iptables -w 2 -t filter -X AWG_FILTER 2>/dev/null || true

iptables -w 2 -t nat -D POSTROUTING -o awg+ -j MASQUERADE 2>/dev/null || true

# Очистка правил маршрутизации
while ip rule del table main pref 8990 2>/dev/null; do :; done
while ip -6 rule del table main pref 8990 2>/dev/null; do :; done
while ip rule del table main pref 9001 2>/dev/null; do :; done
while ip -6 rule del table main pref 9001 2>/dev/null; do :; done

# Очистка таблиц 201..232
t=201
while [ $t -le 232 ]; do
  while ip rule del table "$t" 2>/dev/null; do :; done
  while ip -6 rule del table "$t" 2>/dev/null; do :; done
  ip route flush table "$t" 2>/dev/null || true
  ip -6 route flush table "$t" 2>/dev/null || true
  t=$((t + 1))
done

rm -rf /data/adb/amneziawg/run /data/local/tmp/wireguard 2>/dev/null || true
rm -f /dev/wireguard/awg*.sock 2>/dev/null || true
