# Логика установки модуля zapret2

ui_print "- Настройка файлов модуля zapret2..."
mkdir -p "$MODPATH/system/bin"

case "$ARCH" in
  arm64) ABI_DIR="android-arm64" ;;
  arm)   ABI_DIR="android-arm" ;;
  x86)   ABI_DIR="android-x86" ;;
  x64)   ABI_DIR="android-x86_64" ;;
  *)     ABI_DIR="android-arm64" ;;
esac

ui_print "- Архитектура процессора: $ARCH (используется $ABI_DIR)"

# Если файлы уже распакованы в MODPATH/binaries
if [ -d "$MODPATH/binaries/$ABI_DIR" ]; then
  cp -f "$MODPATH/binaries/$ABI_DIR/"* "$MODPATH/system/bin/" 2>/dev/null
  cp -f "$MODPATH/binaries/"*.lua "$MODPATH/system/bin/" 2>/dev/null
elif [ -f "$ZIPFILE" ]; then
  mkdir -p "$TMPDIR/bin"
  unzip -o "$ZIPFILE" "binaries/$ABI_DIR/*" -d "$TMPDIR/bin" >&2
  cp -f "$TMPDIR/bin/binaries/$ABI_DIR/"* "$MODPATH/system/bin/" 2>/dev/null
  unzip -o "$ZIPFILE" "binaries/*.lua" -d "$TMPDIR/bin" >&2
  cp -f "$TMPDIR/bin/binaries/"*.lua "$MODPATH/system/bin/" 2>/dev/null
fi

# Удаляем временную папку binaries в MODPATH если она была распакована
rm -rf "$MODPATH/binaries" 2>/dev/null

# Установка прав доступа
ui_print "- Настройка прав доступа на исполнимые файлы..."
chmod 0755 "$MODPATH/system/bin/nfqws2" 2>/dev/null
chmod 0755 "$MODPATH/system/bin/ip2net" 2>/dev/null
chmod 0755 "$MODPATH/system/bin/mdig" 2>/dev/null
chmod 0755 "$MODPATH/system/bin/zapret2-control" 2>/dev/null
[ -f "$MODPATH/service.sh" ] && chmod 0755 "$MODPATH/service.sh"
[ -f "$MODPATH/action.sh" ] && chmod 0755 "$MODPATH/action.sh"
[ -f "$MODPATH/uninstall.sh" ] && chmod 0755 "$MODPATH/uninstall.sh"
[ -f "$MODPATH/webroot/cgi-bin/api" ] && chmod 0755 "$MODPATH/webroot/cgi-bin/api" 2>/dev/null

ui_print "- Установка zapret2 завершена успешно!"

