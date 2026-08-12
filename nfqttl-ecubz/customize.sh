SKIPUNZIP=0

prop_get_install() {
    sed -n "s/^$1=//p" "$MODPATH/module.prop" 2>/dev/null | head -n 1 | tr -d '\r'
}

MOD_ID=$(prop_get_install id)
MOD_VERSION=$(prop_get_install version)
MOD_VERSION_CODE=$(prop_get_install versionCode)
MOD_NAME=$(prop_get_install name)

ui_print " "
ui_print " ******************************* "
ui_print " *  ${MOD_NAME:-NFQTTL eCubz}"
ui_print " *  ${MOD_VERSION:-unknown} (${MOD_VERSION_CODE:-unknown})"
ui_print " ******************************* "
ui_print " "

ABI=$(getprop ro.product.cpu.abi)
ui_print "- Архитектура устройства: $ABI"

# Preserve user-facing config values across module updates while keeping new defaults/comments.
OLD_MODDIR="/data/adb/modules/${MOD_ID:-nfqttl-ecubz}"
OLD_CONFIG="$OLD_MODDIR/config.conf"
if [ -f "$OLD_CONFIG" ] && [ "$OLD_CONFIG" != "$MODPATH/config.conf" ]; then
    ui_print "- Обновление: переношу пользовательские настройки config.conf"
    for _key in TTL_VALUE HL_VALUE CARRIER_PROVISIONING_BYPASS OFFLOAD_CONTROL TTL1_PROTECTION CLAMP_MSS ENABLE_DNS_REDIRECT BLOCK_DOT BLOCK_NTP BLOCK_DISCOVERY ENABLE_BLOCKLIST NFQUEUE_OVERLOAD_GUARD NFQUEUE_BACKLOG_LIMIT NFQUEUE_OVERLOAD_LIMIT CONTROLLER_ENABLE CONTROLLER_INTERVAL DEBUG_AUTO_REPORT EXTRA_CLIENT_IFS EXTRA_UPSTREAM_IFS; do
        _old=$(sed -n "s/^${_key}=//p" "$OLD_CONFIG" 2>/dev/null | tail -n 1)
        [ -n "$_old" ] || continue
        if grep -q "^${_key}=" "$MODPATH/config.conf" 2>/dev/null; then
            _esc=$(printf '%s' "$_old" | sed 's/[\\&|]/\\&/g')
            sed -i "s|^${_key}=.*|${_key}=${_esc}|" "$MODPATH/config.conf" 2>/dev/null || true
        fi
    done
fi
[ -f "$OLD_MODDIR/debug" ] && touch "$MODPATH/debug" 2>/dev/null || true

case "$ABI" in
    arm64-v8a*) ARCH_DIR="arm64-v8a" ;;
    armeabi-v7a*|armeabi*) abort "! armeabi-v7a временно заблокирован: бинарник из v8.4 повреждён. Нужна пересборка native engine." ;;
    x86_64*) ARCH_DIR="x86_64" ;;
    x86*) ARCH_DIR="x86" ;;
    *) abort "! Неподдерживаемая ABI: $ABI. Безопасный fallback на чужую архитектуру отключён." ;;
esac

TARGET_BIN="$MODPATH/libs/$ARCH_DIR/nfqttl"
[ -f "$TARGET_BIN" ] || abort "! В архиве нет nfqttl для $ARCH_DIR"

ui_print "- Устанавливаю native engine для $ARCH_DIR..."
cp -f "$TARGET_BIN" "$MODPATH/nfqttl" || abort "! Не удалось скопировать native engine"

set_perm "$MODPATH/nfqttl" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/debug_log.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm "$MODPATH/config.conf" 0 0 0644

# Execute the selected binary once during installation. A wrong/corrupt ABI fails here,
# rather than failing silently after reboot.
if NFQTTL_MODULE_VERSION="$MOD_VERSION" NFQTTL_MODULE_PROP="$MODPATH/module.prop" "$MODPATH/nfqttl" -h >/dev/null 2>&1; then
    ui_print "- Native engine: OK"
else
    abort "! Native engine не запускается на этом устройстве ($ARCH_DIR). Установка остановлена."
fi

ui_print "- Базовый профиль: carrier provisioning bypass + tether-only TTL/HL masking"
ui_print "- DNS/DoT/NTP/discovery block: выключены по умолчанию"
ui_print "- Настройки: $MODPATH/config.conf"
ui_print "- Установка завершена. Перезагрузите устройство."
