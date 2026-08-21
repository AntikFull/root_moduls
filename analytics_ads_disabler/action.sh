#!/system/bin/sh
#
# Analytics & Ads Disabler v7 — кнопка Action в менеджере root.
#
# Показывает текущее состояние и позволяет переключить три основные опции.
# Тяжёлых операций здесь нет: применение сводится к перезаписи engine.policy.
#
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

MODULE_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)
[ -n "$MODULE_VERSION" ] || MODULE_VERSION="v7"

on_off() { [ "$1" = "1" ] && echo ON || echo OFF; }

volume_select() {
    default_answer="$1"
    timeout_s="${2:-30}"
    if ! command -v getevent >/dev/null 2>&1; then
        [ "$default_answer" = "yes" ] && return 0
        return 1
    fi
    tries=0
    while [ "$tries" -lt 40 ]; do
        tries=$((tries + 1))
        if command -v timeout >/dev/null 2>&1; then
            event=$( { timeout "$timeout_s" getevent -qlc 1; } 2>/dev/null )
        else
            event=$(getevent -qlc 1 2>/dev/null)
        fi
        if [ -z "$event" ]; then
            [ "$default_answer" = "yes" ] && return 0
            return 1
        fi
        echo "$event" | grep -q "KEY_VOLUMEUP.*DOWN" && return 0
        echo "$event" | grep -q "KEY_VOLUMEDOWN.*DOWN" && return 1
    done
    [ "$default_answer" = "yes" ] && return 0
    return 1
}

ask() {
    echo ""
    echo "$1"
    echo "  VOL+ = ДА    VOL- = НЕТ"
    echo "  Сейчас: $( [ "$2" = "1" ] && echo ДА || echo НЕТ )"
    if volume_select "$( [ "$2" = "1" ] && echo yes || echo no )" 30; then
        echo "  -> ДА"
        return 0
    fi
    echo "  -> НЕТ"
    return 1
}

set_setting() {
    _ss_key="$1"; _ss_val="$2"
    _ss_tmp="$SETTINGS_FILE.tmp.$$"
    awk -v k="$_ss_key" -v v="$_ss_val" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!done) { print k "=" v; done = 1 } next }
        { print }
        END { if (!done) print k "=" v }
    ' "$SETTINGS_FILE" > "$_ss_tmp" 2>/dev/null || { rm -f "$_ss_tmp" 2>/dev/null; return 1; }
    chmod 600 "$_ss_tmp" 2>/dev/null
    mv -f "$_ss_tmp" "$SETTINGS_FILE" 2>/dev/null || { rm -f "$_ss_tmp" 2>/dev/null; return 1; }
    return 0
}

ADS=$(aad_read_bool BLOCK_ADS 1)
ANALYTICS=$(aad_read_bool BLOCK_ANALYTICS 1)
SYSTEM=$(aad_read_bool INCLUDE_SYSTEM_APPS 0)

echo "==============================================="
echo " Analytics & Ads Disabler $MODULE_VERSION"
echo " Author: eCubz (https://t.me/eCubz)"
echo "==============================================="
echo "Движок      : Zygisk, внутри процессов приложений"
echo "Реклама     : $(on_off "$ADS")"
echo "Аналитика   : $(on_off "$ANALYTICS")"
echo "Системные   : $(on_off "$SYSTEM")"
echo "Сетевой слой: $(on_off "$(aad_read_bool NET_GUARD 1)")"
echo "Схлопывание : $(on_off "$(aad_read_bool COLLAPSE_VIEWS 1)")"
echo "Экраны      : $(on_off "$(aad_read_bool CLOSE_AD_SCREENS 1)")"
echo "WebView     : $(on_off "$(aad_read_bool WEBVIEW_COSMETIC 1)")"

if [ -f "$POLICY_FILE" ]; then
    POLICY_FLAGS=$(sed -n 's/^F|//p' "$POLICY_FILE" 2>/dev/null | head -n1)
    POLICY_EXCL=$(grep -c '^X|' "$POLICY_FILE" 2>/dev/null)
    case "$POLICY_EXCL" in ''|*[!0-9]*) POLICY_EXCL=0 ;; esac
    echo "Политика    : $POLICY_FLAGS"
    echo "Исключений  : $POLICY_EXCL"
else
    echo "Политика    : ОТСУТСТВУЕТ (движок не активен)"
fi
echo "Настройки   : $SETTINGS_FILE"
echo "Логи        : $LOG_DIR"

echo ""
echo "Меню:"
echo "  VOL+ в течение 5 с = ИЗМЕНИТЬ НАСТРОЙКИ"
echo "  VOL- или без нажатия = ПРИМЕНИТЬ ТЕКУЩИЕ"

if volume_select no 5; then
    ask "1. Блокировать РЕКЛАМУ?" "$ADS" && ADS=1 || ADS=0
    ask "2. Блокировать АНАЛИТИКУ?" "$ANALYTICS" && ANALYTICS=1 || ANALYTICS=0
    ask "3. Обрабатывать СИСТЕМНЫЕ приложения?" "$SYSTEM" && SYSTEM=1 || SYSTEM=0

    echo ""
    echo "Новые значения: реклама=$ADS аналитика=$ANALYTICS системные=$SYSTEM"
    echo "  VOL+ = СОХРАНИТЬ    VOL- = ОТМЕНА"
    if volume_select yes 30; then
        rc=0
        set_setting BLOCK_ADS "$ADS" || rc=1
        set_setting BLOCK_ANALYTICS "$ANALYTICS" || rc=1
        set_setting INCLUDE_SYSTEM_APPS "$SYSTEM" || rc=1
        if [ "$rc" -ne 0 ]; then
            echo "! Не удалось сохранить настройки; прежние значения сохранены."
            exit 1
        fi
        aad_log "ACTION-SETTINGS ads=$ADS analytics=$ANALYTICS system=$SYSTEM"
        echo "Настройки сохранены."
    else
        echo "Изменения отменены."
    fi
fi

echo ""
echo "Обновление политики движка..."
aad_sync_policy "action"
rc=$?
case "$rc" in
    0) echo "Готово. Политика применена." ;;
    2) echo "! PackageManager недоступен: движок оставлен выключенным." ;;
    *) echo "! Не удалось обновить политику. Лог: $LOGFILE" ;;
esac

echo ""
echo "Изменения вступают в силу при следующем запуске приложения."
echo "Уже запущенные приложения нужно закрыть из списка недавних."
exit "$rc"
