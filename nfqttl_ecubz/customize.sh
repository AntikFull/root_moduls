SKIPUNZIP=0

ui_print " "
ui_print " ******************************* "
ui_print " *  Magisk Module Nfqttl eCubz   * "
ui_print " *         Version v13.0        * "
ui_print " ******************************* "
ui_print " "

ABI=$(getprop ro.product.cpu.abi)
ui_print "- Архитектура процессора устройства: $ABI"

case "$ABI" in
    arm64-v8a*) ARCH_DIR="arm64-v8a" ;;
    armeabi-v7a*|armeabi*) ARCH_DIR="armeabi-v7a" ;;
    x86_64*) ARCH_DIR="x86_64" ;;
    x86*) ARCH_DIR="x86" ;;
    *) ARCH_DIR="arm64-v8a" ;;
esac

case "$ARCH_DIR" in
    arm64-v8a)   WANT_MACHINE="b700" ;;
    armeabi-v7a) WANT_MACHINE="2800" ;;
    x86_64)      WANT_MACHINE="3e00" ;;
    x86)         WANT_MACHINE="0300" ;;
esac

elf_field() { # $1=файл $2=смещение $3=длина
    dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'
}

check_elf() {
    _f="$1"
    [ -f "$_f" ] || return 1
    command -v od >/dev/null 2>&1 || { ui_print "- [i] od недоступен, проверка ELF пропущена"; return 0; }

    _magic=$(elf_field "$_f" 0 4)
    if [ "$_magic" != "7f454c46" ]; then
        ui_print "- [ОШИБКА] $_f не является ELF (magic=$_magic)"
        return 1
    fi

    _machine=$(elf_field "$_f" 18 2)
    if [ -n "$WANT_MACHINE" ] && [ "$_machine" != "$WANT_MACHINE" ]; then
        ui_print "- [ОШИБКА] Архитектура в ELF=$_machine, ожидалась $WANT_MACHINE"
        return 1
    fi
    return 0
}

TARGET_BIN="$MODPATH/libs/$ARCH_DIR/nfqttl"

if [ -f "$TARGET_BIN" ]; then
    ui_print "- Копирование бинарника для $ARCH_DIR..."
    cp "$TARGET_BIN" "$MODPATH/nfqttl"
else
    ui_print "- [ВНИМАНИЕ] Бинарник под $ARCH_DIR в папке libs не найден!"
    ui_print "- Используем корневой резервный бинарник nfqttl..."
fi

if ! check_elf "$MODPATH/nfqttl"; then
    ui_print " "
    ui_print " *********************************************** "
    ui_print " *  БИНАРНИК ПОВРЕЖДЁН — УСТАНОВКА ПРЕРВАНА    * "
    ui_print " *********************************************** "
    ui_print " "
    ui_print "- Архив повреждён при передаче. Скачайте ZIP заново"
    ui_print "  и не пересылайте его через конвертеры и редакторы."
    ui_print "- Контрольные суммы лежат в BINARY_SHA256.txt внутри архива."
    abort "- Установка отменена."
fi
ui_print "- Бинарник проверен: ELF $ARCH_DIR, $(wc -c < "$MODPATH/nfqttl") байт"

set_perm $MODPATH/nfqttl 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/debug_log.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755

ui_print "- Установка завершена успешно!"
ui_print "- Требуется перезагрузка."
