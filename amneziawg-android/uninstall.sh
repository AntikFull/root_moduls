#!/system/bin/sh
# uninstall.sh — полная очистка при удалении модуля.
#
# Единая точка очистки — awg-controller cleanup. Собственной копии списка
# правил здесь быть не должно: прежняя редакция содержала второй, неполный
# перечень (без правил pref 9000/9010, без снятия TCPMSS, без возврата
# rp_filter и без очистки цепочек NFQWS), и он расходился с основным.
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
LOG_DIR="/data/adb/amneziawg/logs"

log_u() {
  printf '%s [UNINSTALL] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_DIR/uninstall.log"
}

if [ -x "$BIN_DIR/awg-controller" ]; then
  if ! "$BIN_DIR/awg-controller" cleanup; then
    log_u "awg-controller cleanup завершился с ошибкой: часть правил могла остаться."
  fi
else
  log_u "awg-controller недоступен: автоматическая очистка правил не выполнена."
fi

killall -9 amneziawg-go 2>/dev/null || true # глушение-обосновано: живых процессов демона может не быть
pkill -f "/bin/awg-netmon" 2>/dev/null || true # глушение-обосновано: монитор может быть уже остановлен
pkill -f "/bin/awg-appmon" 2>/dev/null || true # глушение-обосновано: монитор может быть уже остановлен

rm -rf /data/adb/amneziawg/run /data/adb/amneziawg/state /data/local/tmp/wireguard 2>/dev/null # глушение-обосновано: каталоги могли быть удалены очисткой выше
rm -f /dev/wireguard/awg*.sock 2>/dev/null # глушение-обосновано: сокетов может не быть

# Профили и журналы намеренно остаются: /data/adb/amneziawg/profiles содержит
# конфигурации пользователя с приватными ключами, и их удаление при
# переустановке модуля было бы безвозвратной потерей данных.
# Полное удаление вместе с ключами выполняется вручную:
#   rm -rf /data/adb/amneziawg
