#!/system/bin/sh
# post-fs-data.sh — ранняя инициализация окружения AmneziaWG
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
RUN_DIR="/data/adb/amneziawg/run"
TMP_DIR="/data/local/tmp/wireguard"
PROFILES_DIR="/data/adb/amneziawg/profiles"
LOG_DIR="/data/adb/amneziawg/logs"
STATE_DIR="/data/adb/amneziawg/state"

mkdir -p "$RUN_DIR" "$TMP_DIR" "$PROFILES_DIR" "$LOG_DIR" "$STATE_DIR" "/dev/wireguard" 2>/dev/null # глушение-обосновано: каталоги могут уже существовать после прошлой загрузки
chmod 755 "$RUN_DIR" "$TMP_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null # глушение-обосновано: права уже выставлены установщиком
# Каталог профилей содержит PrivateKey интерфейсов.
chmod 700 "$PROFILES_DIR" 2>/dev/null # глушение-обосновано: каталог создан установщиком с теми же правами

# Очистка мусорных и старых сокетов от прошлой загрузки
rm -rf "$RUN_DIR"/* "$TMP_DIR"/* 2>/dev/null # глушение-обосновано: каталоги могут быть пусты после чистой загрузки
rm -f /dev/wireguard/awg*.sock 2>/dev/null # глушение-обосновано: сокетов может не быть

# Ранняя блокировка KillSwitch.
# Туннели поднимаются только в service.sh, после sys.boot_completed. Между
# появлением сети и этим моментом приложения профиля с включенным KillSwitch
# успевали выйти в сеть напрямую. Блокировка ставится до старта сети и
# снимается штатным применением правил, когда туннель поднимется.
if [ -x "$BIN_DIR/awg-controller" ]; then
  for conf in "$PROFILES_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    prof="$(basename "$conf" .conf)"
    json="$PROFILES_DIR/${prof}.json"
    [ -f "$json" ] || continue
    enabled="$("$BIN_DIR/awg-controller" get-opt-val "$json" "enabled" "false")"
    killswitch="$("$BIN_DIR/awg-controller" get-opt-val "$json" "killswitch" "false")"
    if [ "$enabled" = "true" ] && [ "$killswitch" = "true" ]; then
      "$BIN_DIR/awg-controller" fail "$prof" >/dev/null 2>&1 || \
        printf '%s [POST-FS-DATA] Ранний KillSwitch для %s не установлен\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$prof" >> "$LOG_DIR/service.log"
    fi
  done
fi
