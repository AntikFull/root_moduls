#!/system/bin/sh
# customize.sh - Установщик Telegram WS Proxy v1.2.0 для Magisk / KernelSU / APatch
# Автор: eCubz (https://t.me/eCubz)

SKIPUNZIP=0
STATE="/data/adb/tg-ws-proxy"

ui_print "****************************************"
ui_print "*         Telegram WS Proxy            *"
ui_print "*   MTProto WebSocket via Cloudflare   *"
ui_print "*     Автор: eCubz (@module_ecubz)     *"
ui_print "****************************************"

# 1. Проверка и сопоставление архитектуры устройства
ui_print "- Определение архитектуры: $ARCH"
case "$ARCH" in
  arm64)
    ARCH_DIR="arm64-v8a"
    ;;
  arm)
    ARCH_DIR="armeabi-v7a"
    ;;
  x64)
    ARCH_DIR="x86_64"
    ;;
  x86)
    ARCH_DIR="x86"
    ;;
  *)
    abort "! Архитектура $ARCH не поддерживается."
    ;;
esac

# 2. Установка бинарника для целевой архитектуры
if [ -f "$MODPATH/bin/$ARCH_DIR/tg-ws-proxy" ]; then
  ui_print "- Установка бинарника для $ARCH ($ARCH_DIR)..."
  mkdir -p "$MODPATH/bin"
  cp -f "$MODPATH/bin/$ARCH_DIR/tg-ws-proxy" "$MODPATH/bin/tg-ws-proxy"
  chmod 0755 "$MODPATH/bin/tg-ws-proxy"
  rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a" "$MODPATH/bin/x86" "$MODPATH/bin/x86_64"
else
  abort "! Бинарник для $ARCH_DIR не найден в архиве модуля."
fi

# 3. Smoke-тест бинарника на целевом устройстве
ui_print "- Проверка запуска бинарника (smoke test)..."
if ! "$MODPATH/bin/tg-ws-proxy" -gen-secret >/dev/null 2>&1; then
  abort "! Ошибка: бинарник tg-ws-proxy не запускается на этом ядре ($ARCH)!"
fi
ui_print "  [OK] Бинарник успешно проверен"

# 4. Миграция состояния в /data/adb/tg-ws-proxy (И5, дефект N1)
mkdir -p "$STATE" "$STATE/logs" "$STATE/run"

if [ ! -f "$STATE/config.conf" ]; then
  if [ -f "/data/adb/modules/tg-ws-proxy/config/config.conf" ]; then
    ui_print "- Миграция существующего config.conf..."
    cp -f "/data/adb/modules/tg-ws-proxy/config/config.conf" "$STATE/config.conf"
  elif [ -f "$MODPATH/config/config.conf" ]; then
    cp -f "$MODPATH/config/config.conf" "$STATE/config.conf"
  fi
fi

if [ ! -f "$STATE/secret.conf" ]; then
  if [ -f "/data/adb/modules/tg-ws-proxy/config/secret.conf" ]; then
    ui_print "- Миграция постоянного ключа secret.conf..."
    cp -f "/data/adb/modules/tg-ws-proxy/config/secret.conf" "$STATE/secret.conf"
  fi
fi

# 5. Выставление прав доступа
ui_print "- Настройка прав доступа..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/tg-ws-proxy" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/lib.sh" 0 0 0644

chown -R 0:0 "$STATE" 2>/dev/null
chmod 0700 "$STATE" "$STATE/logs" "$STATE/run" 2>/dev/null
[ -f "$STATE/secret.conf" ] && chmod 0600 "$STATE/secret.conf"
[ -f "$STATE/config.conf" ] && chmod 0600 "$STATE/config.conf"

ui_print " "
ui_print " Установка завершена!"
ui_print " После перезагрузки нажмите кнопку «Действие»"
ui_print " в менеджере root для подключения прокси."
ui_print "****************************************"
