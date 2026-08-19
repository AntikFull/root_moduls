#!/system/bin/sh
# Analytics & Ads Disabler - Rule Updater Daemon
# Автор: eCubz (https://t.me/eCubz) • Группа: https://t.me/module_ecubz

MODDIR="${0%/*}"
DATA_DIR="/data/adb/analytics_ads_disabler"
LOG_DIR="$DATA_DIR/logs"
LOGFILE="$LOG_DIR/debug.log"
LAST_UPDATE_FILE="$DATA_DIR/.last_rules_update"
VENDOR_RULES="$DATA_DIR/rules.vendor.conf"
USER_RULES="$DATA_DIR/rules.user.conf"
RULES_FILE="$DATA_DIR/rules.conf"
SETTINGS_FILE="$DATA_DIR/settings.conf"
REMOTE_RULES_URL="https://raw.githubusercontent.com/AntikFull/root_moduls/main/analytics_ads_disabler/rules.conf"
REMOTE_HASH_URL="https://raw.githubusercontent.com/AntikFull/root_moduls/main/analytics_ads_disabler/rules.sha256"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] [RULE-UPDATER] $*" >> "$LOGFILE"
}

read_setting() {
    _key="$1"; _def="$2"
    _val=""
    if [ -f "$SETTINGS_FILE" ]; then
        _val=$(sed -n "s/^[[:space:]]*${_key}[[:space:]]*=[[:space:]]*//p" "$SETTINGS_FILE" 2>/dev/null | head -n1 | tr -d '\r')
    fi
    [ -n "$_val" ] && echo "$_val" || echo "$_def"
}

read_bool_setting() {
    _val=$(read_setting "$1" "$2")
    [ "$_val" = "1" ] && echo 1 || echo 0
}

http_fetch() {
    _url="$1"; _out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -sfL --connect-timeout 15 --max-time 60 "$_url" -o "$_out" 2>/dev/null && return 0
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 -O "$_out" "$_url" 2>/dev/null && return 0
    fi
    return 1
}

is_wifi_connected() {
    if command -v dumpsys >/dev/null 2>&1; then
        dumpsys connectivity 2>/dev/null | grep -qi "WIFI.*CONNECTED" && return 0
        dumpsys wifi 2>/dev/null | grep -qi "Wi-Fi is connected" && return 0
    fi
    if command -v ip >/dev/null 2>&1; then
        ip route show 2>/dev/null | grep -qi "wlan" && return 0
    fi
    return 1
}

if [ -f "$MODDIR/common.sh" ]; then
    . "$MODDIR/common.sh"
elif [ -f "$DATA_DIR/common.sh" ]; then
    . "$DATA_DIR/common.sh"
fi

check_and_update_rules() {
    [ "$(read_bool_setting AUTO_UPDATE_RULES 0)" = "1" ] || return 0

    if [ "$(read_bool_setting AUTO_UPDATE_WIFI_ONLY 0)" = "1" ]; then
        if ! is_wifi_connected; then
            log "Update skipped: Wi-Fi required but not connected"
            return 0
        fi
    fi

    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) return 0 ;; esac

    _interval_days=$(read_setting AUTO_UPDATE_INTERVAL_DAYS 3)
    case "$_interval_days" in ''|*[!0-9]*) _interval_days=3 ;; esac
    _interval_sec=$((_interval_days * 86400))

    if [ -f "$LAST_UPDATE_FILE" ]; then
        _last=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)
        case "$_last" in
            ''|*[!0-9]*) _last=0 ;;
        esac
        if [ $((_now - _last)) -lt "$_interval_sec" ]; then
            return 0
        fi
    fi

    log "Checking for remote rules update..."
    _tmp_download="$DATA_DIR/.rules_update.tmp.$$"
    _tmp_hash="$DATA_DIR/.rules_hash.tmp.$$"

    if ! http_fetch "$REMOTE_RULES_URL" "$_tmp_download"; then
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        log "Download failed: connection or remote host unavailable"
        return 1
    fi

    # Валидация целостности правил
    _size=$(wc -c < "$_tmp_download" 2>/dev/null | tr -d ' ')
    case "$_size" in ''|*[!0-9]*) _size=0 ;; esac

    if [ "$_size" -lt 5000 ]; then
        log "Validation failed: downloaded file too small (${_size} bytes)"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    fi

    if ! grep -q "^\[ADS\]" "$_tmp_download" 2>/dev/null || \
       ! grep -q "^\[ANALYTICS\]" "$_tmp_download" 2>/dev/null || \
       ! grep -q "^\[ADS_NETWORK_HOST\]" "$_tmp_download" 2>/dev/null; then
        log "Validation failed: missing required rule sections"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    fi

    # Проверка на отсутствие битых байт / BOM
    if [ "$(od -An -tx1 -N3 "$_tmp_download" 2>/dev/null | tr -d ' \n')" = "efbbbf" ]; then
        log "Validation failed: BOM header detected"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    fi

    # Скачивание и проверка SHA-256 хеша манифеста
    if ! http_fetch "$REMOTE_HASH_URL" "$_tmp_hash"; then
        log "Validation failed: SHA-256 manifest unavailable"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    fi
    _expected_hash=$(awk 'NR==1 {print tolower($1)}' "$_tmp_hash" 2>/dev/null | tr -d '\r\n')
    case "$_expected_hash" in ''|*[!0-9a-f]* )
        log "Validation failed: malformed SHA-256 manifest"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1 ;;
    esac
    [ "${#_expected_hash}" -eq 64 ] || {
        log "Validation failed: malformed SHA-256 length"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    }
    _actual_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        _actual_hash=$(sha256sum "$_tmp_download" 2>/dev/null | awk '{print tolower($1)}')
    elif command -v openssl >/dev/null 2>&1; then
        _actual_hash=$(openssl dgst -sha256 "$_tmp_download" 2>/dev/null | awk '{print tolower($NF)}')
    fi
    if [ -z "$_actual_hash" ] || [ "$_expected_hash" != "$_actual_hash" ]; then
        log "Validation failed: SHA-256 mismatch or digest tool unavailable"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    fi
    log "SHA-256 integrity verified successfully: $_actual_hash"

    # Vendor equality does not prove that composite/policy generation was applied.
    if [ -f "$VENDOR_RULES" ] && cmp -s "$_tmp_download" "$VENDOR_RULES" 2>/dev/null; then
        log "Vendor rules are already up to date; verifying composite and applied policy generation"
        rm -f "$_tmp_download" 2>/dev/null
        if rebuild_composite_rules && reconcile_config_if_changed "rules_update_equal"; then
            echo "$_now" > "$LAST_UPDATE_FILE" 2>/dev/null || true
            rm -f "$_tmp_hash" 2>/dev/null
            return 0
        fi
        log "Existing vendor rules could not be reconciled; update remains pending"
        rm -f "$_tmp_hash" 2>/dev/null
        return 1
    fi

    _vendor_prev="$DATA_DIR/.rules.vendor.prev.$$"
    [ -f "$VENDOR_RULES" ] && cp "$VENDOR_RULES" "$_vendor_prev" 2>/dev/null || rm -f "$_vendor_prev" 2>/dev/null
    chmod 600 "$_tmp_download" 2>/dev/null || true
    if mv -f "$_tmp_download" "$VENDOR_RULES" 2>/dev/null; then
        log "VENDOR RULES UPDATED successfully (size=${_size} bytes). Rebuilding and reconciling."
        if rebuild_composite_rules && reconcile_config_if_changed "rules_update"; then
            echo "$_now" > "$LAST_UPDATE_FILE" 2>/dev/null || true
            rm -f "$_tmp_hash" "$_vendor_prev" 2>/dev/null
            log "VENDOR RULES RECONCILED successfully."
            return 0
        fi
        log "Vendor update did not reach applied policy; rolling vendor source back"
        if [ -f "$_vendor_prev" ]; then
            mv -f "$_vendor_prev" "$VENDOR_RULES" 2>/dev/null || true
            rebuild_composite_rules >/dev/null 2>&1 || true
            reconcile_config_if_changed "rules_update_rollback" >/dev/null 2>&1 || true
        fi
        rm -f "$_tmp_hash" 2>/dev/null
        return 1
    else
        rm -f "$_vendor_prev" 2>/dev/null
        log "Failed to apply updated vendor rules file"
        rm -f "$_tmp_download" "$_tmp_hash" 2>/dev/null
        return 1
    fi
}

# Если запущен напрямую - выполняем однократную проверку
if [ "${1:-}" = "--once" ] || [ "${1:-}" = "once" ]; then
    check_and_update_rules
    exit $?
fi

# Фоновый цикл демона
while true; do
    check_and_update_rules
    sleep 21600 # опрос каждые 6 часов
done
