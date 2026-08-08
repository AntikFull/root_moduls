SKIPUNZIP=0

ui_print " "
ui_print " ******************************* "
ui_print " *  Magisk Module Nfqttl eCubz   * "
ui_print " *    Version v8.4-fixed     * "
ui_print " ******************************* "
ui_print " "

# Определение архитектуры устройства
ABI=$(getprop ro.product.cpu.abi)
ui_print "- Архитектура процессора устройства: $ABI"

case "$ABI" in
    arm64-v8a*) ARCH_DIR="arm64-v8a" ;;
    armeabi-v7a*|armeabi*) ARCH_DIR="armeabi-v7a" ;;
    x86_64*) ARCH_DIR="x86_64" ;;
    x86*) ARCH_DIR="x86" ;;
    *) ARCH_DIR="arm64-v8a" ;;
esac

TARGET_BIN="$MODPATH/libs/$ARCH_DIR/nfqttl"

if [ -f "$TARGET_BIN" ]; then
    ui_print "- Копирование бинарника для $ARCH_DIR..."
    cp "$TARGET_BIN" "$MODPATH/nfqttl"
else
    ui_print "- [ВНИМАНИЕ] Бинарник под $ARCH_DIR в папке libs не найден!"
    ui_print "- Используем корневой резервный бинарник nfqttl..."
fi

# Установка прав на исполнение скриптов и бинарников
set_perm $MODPATH/nfqttl 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/debug_log.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755

ui_print "- Установка завершена успешно!"
