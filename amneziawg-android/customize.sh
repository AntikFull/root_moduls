#!/system/bin/sh
# customize.sh — Установщик модуля AmneziaWG Multi-Profile
# Выполняется менеджером root при установке ZIP-архива

ui_print "**********************************************"
ui_print "*   AmneziaWG Multi-Profile (Root and App)   *"
ui_print "*      Разработка: eCubz (t.me/eCubz)        *"
ui_print "**********************************************"

ARCH32="arm"
[ "$ARCH" = "arm64" ] && ARCH32="arm"
[ "$ARCH" = "x64" ] && ARCH="x86_64"

ui_print "- Архитектура процессора: $ARCH"

case "$ARCH" in
  arm64)
    SRC_DIR="$MODPATH/binaries/android-arm64"
    ;;
  arm)
    SRC_DIR="$MODPATH/binaries/android-arm"
    ;;
  x86)
    SRC_DIR="$MODPATH/binaries/android-x86"
    ;;
  x86_64)
    SRC_DIR="$MODPATH/binaries/android-x86_64"
    ;;
  *)
    ui_print "! Неизвестная архитектура: $ARCH. Попытка использования arm64..."
    SRC_DIR="$MODPATH/binaries/android-arm64"
    ;;
esac

mkdir -p "$MODPATH/bin" 2>/dev/null
if [ -d "$SRC_DIR" ]; then
  ui_print "- Установка исполняемых файлов из $SRC_DIR..."
  cp -f "$SRC_DIR"/amneziawg-go "$MODPATH/bin/" 2>/dev/null
  cp -f "$SRC_DIR"/awg "$MODPATH/bin/" 2>/dev/null
else
  ui_print "! Каталог скомпилированных файлов $SRC_DIR не найден, используем дефолтные..."
fi

rm -rf "$MODPATH/binaries" 2>/dev/null

ui_print "- Настройка прав доступа (0755)..."
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

DATA_DIR="/data/adb/amneziawg"
mkdir -p "$DATA_DIR/profiles" "$DATA_DIR/run" "$DATA_DIR/logs" 2>/dev/null
chmod 755 "$DATA_DIR" "$DATA_DIR/profiles" "$DATA_DIR/run" "$DATA_DIR/logs" 2>/dev/null

# Создание директории профилей (поставляется чистым без демо-профилей)
mkdir -p "$DATA_DIR/profiles" 2>/dev/null

ui_print "- Установка успешно завершена!"
ui_print "- WebUI доступен в менеджере KernelSU / APatch / Magisk."
