#!/system/bin/sh
#
# Analytics & Ads Disabler v7 — общая библиотека shell-слоя.
#
# В v7 shell больше не блокирует рекламу сам. Вся блокировка живёт в
# Zygisk-движке внутри процессов приложений. Задача этого слоя ровно одна:
# превратить настройки пользователя в файл политики engine.policy, который
# движок читает при запуске каждого приложения.
#
# Поэтому здесь нет ни опроса состояния, ни фоновых циклов, ни обращений к
# PackageManager в горячем пути.
#
# Автор: eCubz (https://t.me/eCubz)

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:${PATH:-/system/bin}"

AAD_ID="analytics_ads_disabler"
DATA_DIR="${DATA_DIR:-/data/adb/$AAD_ID}"
LOG_DIR="$DATA_DIR/logs"
SETTINGS_FILE="$DATA_DIR/settings.conf"
WHITELIST_FILE="$DATA_DIR/whitelist.list"
RULES_FILE="$DATA_DIR/rules.conf"
POLICY_FILE="$DATA_DIR/engine.policy"
POLICY_HASH_FILE="$DATA_DIR/.engine.policy.hash"
# Задаётся безусловно и выводится из DATA_DIR. Через ${LOGFILE:-...} значение
# залипало бы на пути, унаследованном из окружения родительского скрипта.
LOGFILE="$LOG_DIR/debug.log"

mkdir -p "$DATA_DIR" "$LOG_DIR" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null

aad_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$*" >> "$LOGFILE" 2>/dev/null
}

# Обрезает лог по размеру. Вызывается на старте, не по таймеру.
aad_log_rotate() {
    _alr_max=262144
    _alr_size=$(stat -c %s "$LOGFILE" 2>/dev/null)
    case "$_alr_size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$_alr_size" -le "$_alr_max" ] && return 0
    mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || return 0
    : > "$LOGFILE" 2>/dev/null
    chmod 600 "$LOGFILE" "$LOGFILE.1" 2>/dev/null
    return 0
}

aad_read_setting() {
    _ars_key="$1"
    _ars_def="$2"
    _ars_val=""
    if [ -f "$SETTINGS_FILE" ]; then
        _ars_val=$(sed -n "s/^[[:space:]]*${_ars_key}[[:space:]]*=[[:space:]]*//p" "$SETTINGS_FILE" 2>/dev/null | head -n1 | tr -d '\r')
    fi
    [ -n "$_ars_val" ] && printf '%s\n' "$_ars_val" || printf '%s\n' "$_ars_def"
}

aad_read_bool() {
    case "$(aad_read_setting "$1" "$2")" in
        1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0\n' ;;
        *) printf '%s\n' "$2" ;;
    esac
}

# Перечисляет системные пакеты для исключения из инструментирования.
# Выполняется один раз при генерации политики, а не при запуске приложений.
aad_system_packages() {
    if command -v pm >/dev/null 2>&1; then
        pm list packages -s 2>/dev/null | sed -n 's/^package://p'
        return 0
    fi
    if command -v cmd >/dev/null 2>&1; then
        cmd package list packages -s 2>/dev/null | sed -n 's/^package://p'
        return 0
    fi
    return 1
}

# Переводит rules.conf в строки политики вида R|<код секции>|<значение>.
#
# Разбор ini-подобного файла делается одним проходом awk. Секции с неизвестным
# именем игнорируются: так опечатка в заголовке не превращается в правило,
# применённое не к тому списку.
aad_emit_user_rules() {
    [ -f "$RULES_FILE" ] || return 0
    awk '
        function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        {
            line = trim($0)
            if (line == "" || substr(line, 1, 1) == "#") next
            if (substr(line, 1, 1) == "[" && substr(line, length(line), 1) == "]") {
                name = substr(line, 2, length(line) - 2)
                if (name == "AD_PACKAGES") code = "AP"
                else if (name == "ANALYTICS_PACKAGES") code = "NP"
                else if (name == "AD_HOSTS") code = "AH"
                else if (name == "ANALYTICS_HOSTS") code = "NH"
                else if (name == "NEVER_BLOCK_HOSTS") code = "XH"
                else if (name == "AD_VIEWS") code = "AV"
                else if (name == "AD_ACTIVITIES") code = "AA"
                else code = ""
                next
            }
            if (code == "") next
            # Разделитель "|" служебный: он размечает саму строку политики,
            # поэтому значение с ним принять нельзя.
            if (index(line, "|") > 0) next
            printf "R|%s|%s\n", code, line
        }
    ' "$RULES_FILE" 2>/dev/null
}

# Строит строку флагов для Java-ядра из пользовательских настроек.
aad_build_flags() {
    _abf_ads=$(aad_read_bool BLOCK_ADS 1)
    _abf_analytics=$(aad_read_bool BLOCK_ANALYTICS 1)
    _abf_collapse=$(aad_read_bool COLLAPSE_VIEWS 1)
    _abf_killfs=$(aad_read_bool CLOSE_AD_SCREENS 1)
    _abf_webview=$(aad_read_bool WEBVIEW_COSMETIC 1)
    _abf_net=$(aad_read_bool NET_GUARD 1)
    _abf_optout=$(aad_read_bool SDK_OPT_OUT 1)
    _abf_verbose=$(aad_read_bool VERBOSE_LOG 0)

    # engine=0 означает полный простой: движок не внедряется ни в одно
    # приложение, даже если библиотека Zygisk загружена.
    _abf_engine=1
    if [ "$_abf_ads" = "0" ] && [ "$_abf_analytics" = "0" ]; then
        _abf_engine=0
    fi

    printf 'engine=%s;ads=%s;analytics=%s;collapse=%s;killfs=%s;webview=%s;net=%s;optout=%s;verbose=%s\n' \
        "$_abf_engine" "$_abf_ads" "$_abf_analytics" "$_abf_collapse" \
        "$_abf_killfs" "$_abf_webview" "$_abf_net" "$_abf_optout" "$_abf_verbose"
}

# Генерирует engine.policy.
#
# Формат намеренно примитивен: его разбирает C++ при запуске каждого
# приложения, поэтому парсер должен быть тривиальным и без аллокаций сверх
# необходимого.
#   F|<флаги>            ровно одна строка, первая имеет силу
#   X|<пакет>            исключение по имени пакета или процесса
#   R|<секция>|<знач.>   пользовательское правило из rules.conf; нативная
#                        сторона их только собирает, разбирает Java-ядро
#
# Код возврата:
#   0 — политика записана и полна;
#   2 — записана вынужденно закрытая политика (engine=0), потому что список
#       системных пакетов получить не удалось. Так бывает при установке из
#       recovery, когда PackageManager ещё не поднят. Повторить при загрузке;
#   1 — записать не удалось вовсе, прежняя политика сохранена.
aad_write_policy() {
    _awp_tmp="$POLICY_FILE.tmp.$$"
    _awp_excl="$DATA_DIR/.policy_excl.$$"
    _awp_flags=$(aad_build_flags)
    _awp_degraded=0

    : > "$_awp_excl" 2>/dev/null || {
        aad_log "POLICY-WRITE-FAILED: нет доступа к $DATA_DIR"
        return 1
    }

    if [ -f "$WHITELIST_FILE" ]; then
        sed 's/[[:space:]]*$//' "$WHITELIST_FILE" 2>/dev/null \
            | grep -v '^[[:space:]]*#' \
            | grep -v '^[[:space:]]*$' >> "$_awp_excl" 2>/dev/null
    fi

    if [ "$(aad_read_bool INCLUDE_SYSTEM_APPS 0)" = "0" ]; then
        _awp_sys_tmp="$DATA_DIR/.policy_sys.$$"
        if aad_system_packages > "$_awp_sys_tmp" 2>/dev/null && [ -s "$_awp_sys_tmp" ]; then
            cat "$_awp_sys_tmp" >> "$_awp_excl" 2>/dev/null
        else
            # Настройка требует исключить системные приложения, а получить их
            # список нечем. Внедряться «на всякий случай» нельзя, поэтому
            # движок остаётся выключенным до следующей синхронизации.
            _awp_degraded=1
            _awp_flags=$(printf '%s' "$_awp_flags" | sed 's/^engine=1/engine=0/')
            aad_log "POLICY-DEGRADED: PackageManager недоступен, движок оставлен выключенным"
        fi
        rm -f "$_awp_sys_tmp" 2>/dev/null
    fi

    sort -u "$_awp_excl" -o "$_awp_excl" 2>/dev/null

    {
        printf '# Analytics & Ads Disabler v7 engine policy\n'
        printf '# Генерируется автоматически. Правьте settings.conf, whitelist.list и rules.conf.\n'
        printf 'F|%s\n' "$_awp_flags"
        while IFS= read -r _awp_pkg; do
            [ -n "$_awp_pkg" ] && printf 'X|%s\n' "$_awp_pkg"
        done < "$_awp_excl"
        aad_emit_user_rules
    } > "$_awp_tmp" 2>/dev/null || {
        rm -f "$_awp_tmp" "$_awp_excl" 2>/dev/null
        aad_log "POLICY-WRITE-FAILED: не удалось сформировать $_awp_tmp"
        return 1
    }
    rm -f "$_awp_excl" 2>/dev/null

    # Политику читает процесс приложения, пока он ещё root. Каталог модуля и
    # так доступен только root, поэтому 0600 достаточно.
    chmod 600 "$_awp_tmp" 2>/dev/null
    if ! mv -f "$_awp_tmp" "$POLICY_FILE" 2>/dev/null; then
        rm -f "$_awp_tmp" 2>/dev/null
        aad_log "POLICY-COMMIT-FAILED: не удалось заменить $POLICY_FILE"
        return 1
    fi

    _awp_count=$(grep -c '^X|' "$POLICY_FILE" 2>/dev/null)
    case "$_awp_count" in ''|*[!0-9]*) _awp_count=0 ;; esac
    _awp_rules=$(grep -c '^R|' "$POLICY_FILE" 2>/dev/null)
    case "$_awp_rules" in ''|*[!0-9]*) _awp_rules=0 ;; esac
    aad_log "POLICY: flags=$_awp_flags exclusions=$_awp_count user_rules=$_awp_rules"
    [ "$_awp_degraded" -eq 0 ] || return 2
    return 0
}

# Возвращает 0, если политика уже соответствует текущим настройкам.
# Нужна, чтобы не переписывать файл и не дёргать PackageManager без причины.
aad_policy_current() {
    [ -f "$POLICY_FILE" ] || return 1
    _apc_want=$(aad_build_flags)
    _apc_have=$(sed -n 's/^F|//p' "$POLICY_FILE" 2>/dev/null | head -n1)
    [ "$_apc_want" = "$_apc_have" ] || return 1

    # Белый список мог измениться при неизменных флагах.
    _apc_hash=$(cat "$SETTINGS_FILE" "$WHITELIST_FILE" "$RULES_FILE" 2>/dev/null | cksum 2>/dev/null | awk '{print $1 ":" $2}')
    [ -n "$_apc_hash" ] || return 1
    [ "$_apc_hash" = "$(cat "$POLICY_HASH_FILE" 2>/dev/null)" ] || return 1
    return 0
}

aad_mark_policy_current() {
    _amp_hash=$(cat "$SETTINGS_FILE" "$WHITELIST_FILE" "$RULES_FILE" 2>/dev/null | cksum 2>/dev/null | awk '{print $1 ":" $2}')
    [ -n "$_amp_hash" ] || return 1
    _amp_tmp="$POLICY_HASH_FILE.tmp.$$"
    printf '%s\n' "$_amp_hash" > "$_amp_tmp" 2>/dev/null || return 1
    chmod 600 "$_amp_tmp" 2>/dev/null
    mv -f "$_amp_tmp" "$POLICY_HASH_FILE" 2>/dev/null || { rm -f "$_amp_tmp" 2>/dev/null; return 1; }
    return 0
}

# Полный цикл: сгенерировать политику, если она устарела.
#
# Синхронизация сериализуется: редактор сохраняет файл несколькими записями,
# и inotifyd успевает запустить несколько обработчиков. Без блокировки они
# одновременно полезли бы перечислять пакеты через PackageManager.
AAD_LOCK_DIR="$DATA_DIR/.sync.lock"

aad_lock_acquire() {
    _ala_tries=0
    while ! mkdir "$AAD_LOCK_DIR" 2>/dev/null; do
        _ala_owner=$(cat "$AAD_LOCK_DIR/pid" 2>/dev/null)
        case "$_ala_owner" in
            ''|*[!0-9]*)
                # Каталог без владельца — остаток аварийного завершения.
                rm -rf "$AAD_LOCK_DIR" 2>/dev/null
                ;;
            *)
                if ! kill -0 "$_ala_owner" 2>/dev/null; then
                    aad_log "LOCK-STALE: владелец $_ala_owner мёртв, замок снят"
                    rm -rf "$AAD_LOCK_DIR" 2>/dev/null
                fi
                ;;
        esac
        _ala_tries=$((_ala_tries + 1))
        [ "$_ala_tries" -ge 30 ] && return 1
        sleep 1
    done
    printf '%s\n' "$$" > "$AAD_LOCK_DIR/pid" 2>/dev/null
    return 0
}

aad_lock_release() {
    [ -d "$AAD_LOCK_DIR" ] || return 0
    # Снимаем только собственный замок: чужой мог быть взят после нашего
    # аварийного завершения.
    [ "$(cat "$AAD_LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -rf "$AAD_LOCK_DIR" 2>/dev/null
    return 0
}

aad_sync_policy() {
    _asp_reason="${1:-sync}"
    if ! aad_lock_acquire; then
        aad_log "POLICY-BUSY reason=$_asp_reason; синхронизация уже выполняется"
        return 0
    fi
    _aad_sync_policy_locked "$_asp_reason"
    _asp_outer_rc=$?
    aad_lock_release
    return "$_asp_outer_rc"
}

_aad_sync_policy_locked() {
    _asp_reason="$1"
    if aad_policy_current; then
        aad_log "POLICY-UNCHANGED reason=$_asp_reason"
        return 0
    fi
    aad_write_policy
    _asp_rc=$?
    if [ "$_asp_rc" -eq 1 ]; then
        aad_log "POLICY-SYNC-FAILED reason=$_asp_reason"
        return 1
    fi
    if [ "$_asp_rc" -eq 2 ]; then
        # Отметку актуальности не ставим: политика неполная и должна быть
        # переписана при следующей возможности.
        rm -f "$POLICY_HASH_FILE" 2>/dev/null
        aad_log "POLICY-PARTIAL reason=$_asp_reason; повтор при загрузке"
        return 2
    fi
    aad_mark_policy_current || aad_log "POLICY-HASH-WARN: политика записана, отметка актуальности не сохранена"
    aad_log "POLICY-UPDATED reason=$_asp_reason"
    return 0
}
