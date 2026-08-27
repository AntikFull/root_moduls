#!/system/bin/sh
# post-fs-data.sh — ранняя инициализация окружения AmneziaWG
MODDIR="${0%/*}"
RUN_DIR="/data/adb/amneziawg/run"
TMP_DIR="/data/local/tmp/wireguard"
PROFILES_DIR="/data/adb/amneziawg/profiles"
LOG_DIR="/data/adb/amneziawg/logs"

mkdir -p "$RUN_DIR" "$TMP_DIR" "$PROFILES_DIR" "$LOG_DIR" "/dev/wireguard" 2>/dev/null
chmod 755 "$RUN_DIR" "$TMP_DIR" "$PROFILES_DIR" "$LOG_DIR" 2>/dev/null

# Очистка мусорных и старых сокетов
rm -rf "$RUN_DIR"/* "$TMP_DIR"/* 2>/dev/null
rm -f /dev/wireguard/awg*.sock 2>/dev/null

if [ ! -f "$PROFILES_DIR"/*.conf ]; then
  if [ -d "$MODDIR/profiles" ]; then
    cp -rn "$MODDIR/profiles"/* "$PROFILES_DIR/" 2>/dev/null || true
  fi
fi
