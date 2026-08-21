#!/system/bin/sh
#
# Analytics & Ads Disabler v7 — удаление.
#
# v7 не меняет состояние системы: движок живёт только внутри процессов
# приложений и исчезает вместе с ними. Восстанавливать нечего — достаточно
# снять политику, чтобы движок не активировался, если библиотека почему-то
# осталась загруженной, и убрать рабочий каталог.
#
# Отдельно обрабатывается наследие v6: если пользователь ставил v7 поверх v6
# и часть компонентов тогда вернуть не удалось, попытка повторяется здесь.
#
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}
DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
LOG_DIR="$DATA_DIR/logs"
LOGFILE="$LOG_DIR/uninstall.log"
LEGACY_STATE="$DATA_DIR/component_state.list"
OLD_MODULE_DIR="/data/adb/modules/analytics_ads_disabler"

mkdir -p "$LOG_DIR" 2>/dev/null
ulog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$*" >> "$LOGFILE" 2>/dev/null; }
: > "$LOGFILE" 2>/dev/null
ulog "=== удаление v7 ==="

# Останавливаем наблюдатель настроек.
WATCH_PID_FILE="$DATA_DIR/config_watch.pid"
pid=$(cat "$WATCH_PID_FILE" 2>/dev/null)
case "$pid" in
    ''|*[!0-9]*) ;;
    *)
        if kill -0 "$pid" 2>/dev/null; then
            cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
            case "$cmdline" in
                *config_event.sh*) kill "$pid" 2>/dev/null; ulog "остановлен наблюдатель pid=$pid" ;;
                *) ulog "pid=$pid не соответствует наблюдателю; не трогаем" ;;
            esac
        fi
        ;;
esac
rm -f "$WATCH_PID_FILE" 2>/dev/null

# Политика снимается первой: без неё движок fail-closed и не внедряется.
rm -f "$DATA_DIR/engine.policy" "$DATA_DIR/.engine.policy.hash" 2>/dev/null
ulog "политика снята"

# Незавершённый откат v6, если он остался с момента обновления.
legacy_rc=0
if [ -s "$LEGACY_STATE" ]; then
    ulog "обнаружено незавершённое состояние v6; повторная попытка отката"
    if [ -f "$OLD_MODULE_DIR/common.sh" ] && [ -f "$OLD_MODULE_DIR/compat.sh" ]; then
        (
            AAD_DEFER_CAPABILITY_INIT=1
            MODDIR="$OLD_MODULE_DIR"
            export AAD_DEFER_CAPABILITY_INIT MODDIR DATA_DIR
            . "$OLD_MODULE_DIR/common.sh" >/dev/null 2>&1 || exit 1
            ensure_capability_profile >/dev/null 2>&1
            load_capabilities >/dev/null 2>&1
            aad_restore_component_state_db "$LEGACY_STATE" >/dev/null 2>&1
        )
        legacy_rc=$?
    else
        while IFS='|' read -r u comp orig applied; do
            [ -n "$comp" ] || continue
            case "$orig" in
                enabled) verb="enable" ;;
                disabled) verb="disable" ;;
                default) verb="default-state" ;;
                *) legacy_rc=1; continue ;;
            esac
            cmd package "$verb" --user "$u" "$comp" >/dev/null 2>&1 \
                || pm "$verb" --user "$u" "$comp" >/dev/null 2>&1 \
                || legacy_rc=1
        done < "$LEGACY_STATE"
    fi
    ulog "откат наследия v6 rc=$legacy_rc"
fi

# Страховка: цепочки фаервола v6, если они каким-то образом уцелели.
for fw in iptables ip6tables; do
    fw_path=$(command -v "$fw" 2>/dev/null) || continue
    [ -n "$fw_path" ] || continue
    fw_wait=""
    "$fw_path" -w 2 -t filter -S >/dev/null 2>&1 && fw_wait="-w 2"
    fw_rules=$("$fw_path" $fw_wait -t filter -S 2>/dev/null) || continue
    while "$fw_path" $fw_wait -t filter -D OUTPUT -j AAD_ADKILL >/dev/null 2>&1; do :; done
    fw_chains=$(printf '%s\n' "$fw_rules" | sed -n 's/^-N \(AAD_ADKILL[^ ]*\)$/\1/p' | sort -r)
    for c in $fw_chains; do "$fw_path" $fw_wait -t filter -F "$c" >/dev/null 2>&1; done
    for c in $fw_chains; do "$fw_path" $fw_wait -t filter -X "$c" >/dev/null 2>&1; done
done

if [ "$legacy_rc" -eq 0 ]; then
    ulog "удаление завершено; рабочий каталог удаляется"
    rm -rf "$DATA_DIR" 2>/dev/null
    exit 0
fi

# Незавершённый откат — единственная причина сохранить каталог: в нём лежит
# component_state.list, без которого восстановить компоненты уже невозможно.
ulog "рабочий каталог сохранён: остались невосстановленные компоненты v6"
exit 0
