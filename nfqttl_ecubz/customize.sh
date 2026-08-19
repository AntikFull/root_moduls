SKIPUNZIP=0

MOD_VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$MOD_VER" ] && MOD_VER="v15.1.5"

# Сохраняем состояние и пользовательские флаги при обновлении модуля.
OLD_MOD="/data/adb/modules/nfqttl_ecubz"
if [ "$OLD_MOD" != "$MODPATH" ] && [ -d "$OLD_MOD" ]; then
    if [ -f "$OLD_MOD/.original.conf" ] && [ ! -f "$MODPATH/.original.conf" ]; then
        if cp -f "$OLD_MOD/.original.conf" "$MODPATH/.original.conf" 2>/dev/null; then
            chmod 600 "$MODPATH/.original.conf" 2>/dev/null || true
            ui_print "- Сохранены исходные системные настройки предыдущей версии."
        else
            ui_print "- [ВНИМАНИЕ] Не удалось перенести .original.conf; uninstall может не знать исходные значения."
        fi
    fi

    for _flag in debug DEBUG noquic no6 keep_offload dns_redirect ingressfix; do
        [ -f "$OLD_MOD/$_flag" ] && touch "$MODPATH/$_flag" 2>/dev/null || true
    done
    if [ -f "$OLD_MOD/vpn_dns_server" ]; then
        cp -f "$OLD_MOD/vpn_dns_server" "$MODPATH/vpn_dns_server" 2>/dev/null || true
        chmod 600 "$MODPATH/vpn_dns_server" 2>/dev/null || true
    fi
    [ -f "$OLD_MOD/strict_block" ] && ui_print "- [i] strict_block устарел и не переносится: в service.sh он не использовался."

    # Старый blocklist сохраняем как backup. При переносе автоматически
    # комментируем legacy NCSI/captive/NTP строки, которые могли оставлять
    # подключённые устройства в состоянии "без интернета".
    if [ -f "$OLD_MOD/blocklist.txt" ] && [ -f "$MODPATH/blocklist.txt" ]; then
        _different=1
        if command -v cmp >/dev/null 2>&1; then
            cmp -s "$OLD_MOD/blocklist.txt" "$MODPATH/blocklist.txt" && _different=0
        fi
        if [ "$_different" -eq 1 ]; then
            cp -f "$OLD_MOD/blocklist.txt" "$MODPATH/blocklist.previous.txt" 2>/dev/null || true
            _tmp="$MODPATH/.blocklist.migrate.$$"
            : > "$_tmp" 2>/dev/null || true
            while IFS= read -r _line || [ -n "$_line" ]; do
                _trim=$(echo "$_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                case "$_trim" in
                    msftncsi|msftconnecttest|dns.msftncsi.com|captive.apple.com|connectivitycheck|connectivitycheck.gstatic.com|clients3.google.com|detectportal.firefox.com|nmcheck.gnome.org|connectivity-check.ubuntu.com|network-test.debian.org|time.windows.com|time.nist.gov|time.apple.com|time.google.com|time.android.com|time.cloudflare.com|pool.ntp.org|ntp.org)
                        echo "#$_trim" >> "$_tmp"
                        ;;
                    *) echo "$_line" >> "$_tmp" ;;
                esac
            done < "$OLD_MOD/blocklist.txt"
            if [ -s "$_tmp" ]; then
                mv -f "$_tmp" "$MODPATH/blocklist.txt"
                ui_print "- Старый blocklist перенесён безопасно; NCSI/captive/NTP legacy-записи отключены."
                ui_print "- Оригинал сохранён как blocklist.previous.txt."
            else
                rm -f "$_tmp" 2>/dev/null || true
            fi
        fi
    fi
fi

ui_print " "
ui_print " ******************************* "
ui_print " *  Magisk Module Nfqttl eCubz   * "
ui_print " *        Version $MOD_VER       * "
ui_print " ******************************* "
ui_print " "

ABI=$(getprop ro.product.cpu.abi)
ui_print "- Архитектура процессора устройства: $ABI"

case "$ABI" in
    arm64-v8a*) ARCH_DIR="arm64-v8a" ;;
    armeabi-v7a*|armeabi*) ARCH_DIR="armeabi-v7a" ;;
    x86_64*) ARCH_DIR="x86_64" ;;
    x86*) ARCH_DIR="x86" ;;
    *)
        ui_print "- [ОШИБКА] Неподдерживаемая ABI: $ABI"
        abort "- Установка отменена: для этой архитектуры нет совместимого бинарника."
        ;;
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
    ui_print "- [ОШИБКА] Бинарник под $ARCH_DIR в папке libs не найден!"
    abort "- Установка отменена: отсутствует обязательный бинарник $TARGET_BIN"
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

# Проверка SHA-256 контрольной суммы бинарника
if [ -f "$MODPATH/BINARY_SHA256.txt" ]; then
    _expected_sum=$(grep "libs/$ARCH_DIR/nfqttl" "$MODPATH/BINARY_SHA256.txt" 2>/dev/null | awk '{print $1}' | tr -d ' \r\n')
    if [ -n "$_expected_sum" ]; then
        _actual_sum=""
        if command -v sha256sum >/dev/null 2>&1; then
            _actual_sum=$(sha256sum "$MODPATH/nfqttl" 2>/dev/null | awk '{print $1}')
        elif command -v sha256 >/dev/null 2>&1; then
            _actual_sum=$(sha256 "$MODPATH/nfqttl" 2>/dev/null | awk '{print $1}')
        fi

        if [ -z "$_actual_sum" ]; then
            ui_print "- [ВНИМАНИЕ] SHA-256 утилита недоступна; проверка контрольной суммы пропущена."
        elif [ "$_actual_sum" != "$_expected_sum" ]; then
            ui_print "- [ОШИБКА] Не совпала контрольная сумма SHA-256 для $ARCH_DIR!"
            ui_print "  Ожидалось: $_expected_sum"
            ui_print "  Получено:  $_actual_sum"
            abort "- Установка отменена из-за повреждения бинарника."
        fi
    fi
fi

ui_print "- Бинарник проверен: ELF $ARCH_DIR, $(wc -c < "$MODPATH/nfqttl") байт"

set_perm $MODPATH/nfqttl 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/debug_log.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755
[ -f "$MODPATH/uninstall.sh" ] && set_perm $MODPATH/uninstall.sh 0 0 0755

ui_print "- Установка завершена успешно!"
ui_print "- Требуется перезагрузка."
