SKIPUNZIP=0

# ==============================================================================
# Analytics & Ads Disabler v7 — установщик
# Автор: eCubz (https://t.me/eCubz) • Группа: https://t.me/module_ecubz
# ==============================================================================

DATA_DIR="/data/adb/analytics_ads_disabler"
LOG_DIR="$DATA_DIR/logs"
SETTINGS_FILE="$DATA_DIR/settings.conf"
WHITELIST_FILE="$DATA_DIR/whitelist.list"
OLD_MODULE_DIR="/data/adb/modules/analytics_ads_disabler"
INSTALL_LOG="$LOG_DIR/install.log"

mkdir -p "$DATA_DIR" "$LOG_DIR" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null
: > "$INSTALL_LOG" 2>/dev/null

ilog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$*" >> "$INSTALL_LOG" 2>/dev/null
}

module_prop_get() {
  [ -f "$MODPATH/module.prop" ] || return 1
  sed -n "s/^$1=//p" "$MODPATH/module.prop" 2>/dev/null | head -n1
}

MODULE_NAME="$(module_prop_get name)"
MODULE_VERSION="$(module_prop_get version)"
MODULE_VERSION_CODE="$(module_prop_get versionCode)"
[ -n "$MODULE_NAME" ] || MODULE_NAME="Analytics & Ads Disabler"

ui_print "***********************************************"
ui_print "* $MODULE_NAME"
ui_print "* $MODULE_VERSION (versionCode=$MODULE_VERSION_CODE)"
ui_print "* Author: eCubz (https://t.me/eCubz)         *"
ui_print "***********************************************"

if [ "$KSU" = "true" ]; then
  ROOT_MANAGER="KernelSU"
elif [ "$APATCH" = "true" ] || [ "$KERNELPATCH" = "true" ]; then
  ROOT_MANAGER="APatch"
else
  ROOT_MANAGER="Magisk"
fi
ui_print "- Root manager: $ROOT_MANAGER"
ui_print "- Android API: ${API:-unknown} | ABI: ${ARCH:-unknown}"
ilog "root=$ROOT_MANAGER api=${API:-unknown} arch=${ARCH:-unknown}"

# ------------------------------------------------------------------ целостность

if [ -f "$MODPATH/integrity.manifest" ]; then
  ui_print "- Проверка целостности пакета..."
  SHA_TOOL=""
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL="sha256sum"
  elif command -v busybox >/dev/null 2>&1 && busybox sha256sum /dev/null >/dev/null 2>&1; then
    SHA_TOOL="busybox sha256sum"
  fi
  if [ -z "$SHA_TOOL" ]; then
    abort "! Нет утилиты SHA-256 для проверки целостности пакета."
  fi
  integrity_errors=0
  while IFS='=' read -r mf_path mf_hash || [ -n "$mf_path" ]; do
    mf_path=$(printf '%s' "$mf_path" | tr -d '\r\n[:space:]')
    mf_hash=$(printf '%s' "$mf_hash" | tr -d '\r\n[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$mf_path" in ''|'#'*) continue ;; esac
    target="$MODPATH/$mf_path"
    if [ ! -f "$target" ]; then
      ui_print "! Отсутствует файл: $mf_path"
      integrity_errors=$((integrity_errors + 1))
      continue
    fi
    real_hash=$($SHA_TOOL "$target" 2>/dev/null | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    if [ "$real_hash" != "$mf_hash" ]; then
      ui_print "! Несовпадение контрольной суммы: $mf_path"
      integrity_errors=$((integrity_errors + 1))
    fi
  done < "$MODPATH/integrity.manifest"
  if [ "$integrity_errors" -gt 0 ]; then
    abort "! Проверка целостности не пройдена ($integrity_errors)."
  fi
  ui_print "  Целостность подтверждена."
fi

# --------------------------------------------------------------- остановка v6

# Старая версия держала до пяти фоновых процессов. Их надо погасить до того,
# как начнётся откат состояния, иначе они продолжат менять те же файлы.
stop_worker() {
  pf="$1"; marker="$2"
  [ -f "$pf" ] || return 0
  oldpid=$(cat "$pf" 2>/dev/null)
  case "$oldpid" in ''|*[!0-9]*) rm -f "$pf" 2>/dev/null; return 0 ;; esac
  if kill -0 "$oldpid" 2>/dev/null; then
    cmdline=$(tr '\000' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null)
    case "$cmdline" in
      *"$marker"*)
        kill "$oldpid" 2>/dev/null
        n=0
        while kill -0 "$oldpid" 2>/dev/null && [ "$n" -lt 20 ]; do
          sleep 0.1 2>/dev/null || sleep 1
          n=$((n + 1))
        done
        kill -9 "$oldpid" 2>/dev/null
        ilog "stopped worker pid=$oldpid marker=$marker"
        ;;
      *)
        # PID успел уйти другому процессу. Чужой процесс не трогаем.
        ilog "pid-safety: pid=$oldpid не соответствует $marker"
        ;;
    esac
  fi
  rm -f "$pf" 2>/dev/null
}

stop_worker "$DATA_DIR/config_watch.pid" "config_watch.sh"
stop_worker "$DATA_DIR/config_inotify.pid" "config_event.sh"
stop_worker "$DATA_DIR/inotify.pid" "on_app_installed.sh"
stop_worker "$DATA_DIR/log_mirror.pid" "log_mirror.sh"
stop_worker "$DATA_DIR/ad_surface_index.pid" "ad_surface_indexer.sh"
stop_worker "$DATA_DIR/rule_updater.pid" "rule_updater.sh"
stop_worker "$DATA_DIR/category_watch.pid" "category_watch.sh"

for lock in "$DATA_DIR/.operation.lock" "$DATA_DIR/.state_db.lock" \
            "$DATA_DIR/.membership_db.lock" "$DATA_DIR/.surface_index.lock" \
            "$DATA_DIR/.ad_killer.lock" "$DATA_DIR/.app_event.lock"; do
  rm -rf "$lock" 2>/dev/null
done

# ------------------------------------------------------- откат наследия v6

# v6 отключала компоненты приложений через PackageManager. В v7 этого слоя нет,
# поэтому всё, что было отключено, обязано вернуться в исходное состояние —
# иначе компоненты остались бы выключенными навсегда.
LEGACY_STATE="$DATA_DIR/component_state.list"
legacy_restore_rc=0

legacy_restore_fallback() {
  # Запасной путь, если старый common.sh недоступен. Восстанавливает состояние
  # напрямую, построчно. Формат строки: user|pkg/component|original|applied
  fb_failed=0
  fb_total=0
  fb_done=0
  while IFS='|' read -r u comp orig applied; do
    [ -n "$comp" ] || continue
    fb_total=$((fb_total + 1))
    case "$orig" in
      enabled) verb="enable" ;;
      disabled) verb="disable" ;;
      default) verb="default-state" ;;
      *) fb_failed=$((fb_failed + 1)); continue ;;
    esac
    if cmd package "$verb" --user "$u" "$comp" >/dev/null 2>&1; then
      fb_done=$((fb_done + 1))
    elif pm "$verb" --user "$u" "$comp" >/dev/null 2>&1; then
      fb_done=$((fb_done + 1))
    else
      fb_failed=$((fb_failed + 1))
    fi
  done < "$LEGACY_STATE"
  ilog "legacy fallback restore total=$fb_total ok=$fb_done failed=$fb_failed"
  [ "$fb_failed" -eq 0 ]
}

if [ -s "$LEGACY_STATE" ]; then
  legacy_rows=$(grep -c . "$LEGACY_STATE" 2>/dev/null)
  case "$legacy_rows" in ''|*[!0-9]*) legacy_rows=0 ;; esac
  ui_print " "
  ui_print "- Обнаружено состояние v6: $legacy_rows компонент(ов)."
  ui_print "  Возвращаю их в исходное состояние перед переходом на v7..."
  ilog "legacy component_state rows=$legacy_rows"

  if [ -f "$OLD_MODULE_DIR/common.sh" ] && [ -f "$OLD_MODULE_DIR/compat.sh" ]; then
    # Родной откат старой версии предпочтительнее: он сверяет текущее
    # состояние компонента с тем, что применял модуль, и не трогает то,
    # что пользователь или прошивка изменили сами.
    (
      AAD_DEFER_CAPABILITY_INIT=1
      MODDIR="$OLD_MODULE_DIR"
      export AAD_DEFER_CAPABILITY_INIT MODDIR DATA_DIR
      . "$OLD_MODULE_DIR/common.sh" >/dev/null 2>&1 || exit 1
      ensure_capability_profile >/dev/null 2>&1
      load_capabilities >/dev/null 2>&1
      rc=0
      aad_restore_component_state_db "$LEGACY_STATE" >/dev/null 2>&1 || rc=1
      [ -f "$DATA_DIR/.appops_state" ] && { aad_restore_appops_state "" "" >/dev/null 2>&1 || rc=1; }
      [ -f "$DATA_DIR/.ad_id_backup" ] && { aad_restore_owned_settings "$DATA_DIR" >/dev/null 2>&1 || rc=1; }
      [ -f "$DATA_DIR/.webview_command_line_applied.cksum" ] && { aad_restore_webview_owned_state "$DATA_DIR" >/dev/null 2>&1 || rc=1; }
      exit "$rc"
    )
    legacy_restore_rc=$?
    ilog "legacy native restore rc=$legacy_restore_rc"
  else
    legacy_restore_fallback || legacy_restore_rc=1
  fi

  if [ "$legacy_restore_rc" -eq 0 ]; then
    ui_print "  Состояние компонентов восстановлено."
    rm -f "$LEGACY_STATE" "$DATA_DIR/disabled_components.list" 2>/dev/null
  else
    ui_print "! Часть компонентов вернуть не удалось."
    ui_print "  Файл $LEGACY_STATE сохранён; повторите попытку после перезагрузки."
    ilog "legacy restore incomplete; state preserved"
  fi
fi

# Сетевые правила старой версии. Даже если откат компонентов не удался,
# цепочки фаервола надо снять: в v7 сетевого слоя на уровне ядра нет.
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
ilog "legacy firewall chains removed"

# Кэши и рабочие файлы старого движка. Логи не трогаем — они нужны для разбора.
#
# Блок одноразовый и защищён маркером. Причина: среди удаляемого есть
# rules.conf — в v6 это был сгенерированный композит, а в v7 под тем же именем
# лежат пользовательские правила. Без маркера повторная установка v7 стирала бы
# то, что пользователь написал сам.
V7_MIGRATED_MARKER="$DATA_DIR/.v7_migrated"
if [ -f "$V7_MIGRATED_MARKER" ]; then
  ilog "legacy cleanup skipped: миграция уже выполнена"
else
rm -rf "$DATA_DIR/manifest_cache" "$DATA_DIR/.pkgdump" "$DATA_DIR/bin" 2>/dev/null
rm -f "$DATA_DIR/component_candidates.list" "$DATA_DIR/package_scope.list" \
      "$DATA_DIR/package_state.list" "$DATA_DIR/package_verified.list" \
      "$DATA_DIR/ad_killer_targets.list" "$DATA_DIR/ad_killer.status" \
      "$DATA_DIR/reconcile.status" "$DATA_DIR/capabilities.conf" \
      "$DATA_DIR/rules.conf" "$DATA_DIR/rules.vendor.conf" \
      "$DATA_DIR/qa_targets.list" "$DATA_DIR/smart_reward.list" \
      "$DATA_DIR/il2cpp_hooks.conf" "$DATA_DIR/white_ads.list" \
      "$DATA_DIR/white_analytics.list" "$DATA_DIR/integrity.manifest" \
      "$DATA_DIR"/.candidate_scope "$DATA_DIR"/.config.hash \
      "$DATA_DIR"/.base_policy.hash "$DATA_DIR"/.discovery.hash \
      "$DATA_DIR"/.non_primary_settings.hash "$DATA_DIR"/.applied_generation \
      "$DATA_DIR"/.surface_index.fingerprint "$DATA_DIR"/.browser_protected_u* \
      "$DATA_DIR"/.dyn_prot_u* "$DATA_DIR"/.dyn_prot_unknown_u* \
      "$DATA_DIR"/.whitelist.cache "$DATA_DIR"/.white_ads.cache \
      "$DATA_DIR"/.white_analytics.cache 2>/dev/null
find "$DATA_DIR" -maxdepth 1 -name '.*.tmp.*' -delete 2>/dev/null
ilog "legacy caches removed"
fi

# ------------------------------------------------------------------- настройки

volume_select() {
  default_answer="$1"
  if ! command -v getevent >/dev/null 2>&1; then
    ui_print "! getevent недоступен; берётся рекомендованный ответ."
    [ "$default_answer" = "yes" ] && return 0
    return 1
  fi
  tries=0
  while [ "$tries" -lt 40 ]; do
    tries=$((tries + 1))
    if command -v timeout >/dev/null 2>&1; then
      # Фигурные скобки нужны, чтобы сообщение оболочки об убитом по
      # таймауту getevent ("Terminated") не попало в вывод установщика.
      event="$( { timeout 30 getevent -qlc 1; } 2>/dev/null )"
    else
      event="$(getevent -qlc 1 2>/dev/null)"
    fi
    if [ -z "$event" ]; then
      ui_print "! Нет нажатия; берётся рекомендованный ответ."
      [ "$default_answer" = "yes" ] && return 0
      return 1
    fi
    echo "$event" | grep -q "KEY_VOLUMEUP.*DOWN" && return 0
    echo "$event" | grep -q "KEY_VOLUMEDOWN.*DOWN" && return 1
  done
  [ "$default_answer" = "yes" ] && return 0
  return 1
}

ask_yes_no() {
  ui_print " "
  ui_print "$1"
  ui_print "  VOL+ = ДА    VOL- = НЕТ"
  ui_print "  Рекомендуется: $2"
  if volume_select "$( [ "$2" = "ДА" ] && echo yes || echo no )"; then
    ui_print "  -> ДА"
    return 0
  fi
  ui_print "  -> НЕТ"
  return 1
}

KEEP_EXISTING=0
if [ -f "$SETTINGS_FILE" ] && grep -q '^[[:space:]]*BLOCK_ADS[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null; then
  ui_print " "
  ui_print "- Найдены существующие настройки."
  ui_print "  VOL+ = ОСТАВИТЬ    VOL- = НАСТРОИТЬ ЗАНОВО"
  if volume_select yes; then
    KEEP_EXISTING=1
    ui_print "  -> Настройки сохранены"
  else
    ui_print "  -> Перенастройка"
  fi
fi

if [ "$KEEP_EXISTING" -eq 0 ]; then
  CFG_ADS=1
  CFG_ANALYTICS=1
  CFG_SYSTEM=0
  ask_yes_no "1. Блокировать РЕКЛАМУ в приложениях?" "ДА" || CFG_ADS=0
  ask_yes_no "2. Блокировать АНАЛИТИКУ и трекеры?" "ДА" || CFG_ANALYTICS=0
  ask_yes_no "3. Обрабатывать СИСТЕМНЫЕ приложения? (шире охват, выше риск)" "НЕТ" && CFG_SYSTEM=1

  cp -f "$MODPATH/settings.conf" "$SETTINGS_FILE" 2>/dev/null || abort "! Не удалось записать настройки."
  sed -i "s/^BLOCK_ADS=.*/BLOCK_ADS=$CFG_ADS/" "$SETTINGS_FILE" 2>/dev/null
  sed -i "s/^BLOCK_ANALYTICS=.*/BLOCK_ANALYTICS=$CFG_ANALYTICS/" "$SETTINGS_FILE" 2>/dev/null
  sed -i "s/^INCLUDE_SYSTEM_APPS=.*/INCLUDE_SYSTEM_APPS=$CFG_SYSTEM/" "$SETTINGS_FILE" 2>/dev/null
  ilog "settings written ads=$CFG_ADS analytics=$CFG_ANALYTICS system=$CFG_SYSTEM"
fi

# Ключи, появившиеся в новых версиях, дописываются без затирания выбора пользователя.
for kv in 'BLOCK_ADS=1' 'BLOCK_ANALYTICS=1' 'INCLUDE_SYSTEM_APPS=0' 'NET_GUARD=1' \
          'COLLAPSE_VIEWS=1' 'CLOSE_AD_SCREENS=1' 'WEBVIEW_COSMETIC=1' 'VERBOSE_LOG=0'; do
  key=${kv%%=*}
  grep -q "^[[:space:]]*$key[[:space:]]*=" "$SETTINGS_FILE" 2>/dev/null || echo "$kv" >> "$SETTINGS_FILE"
done
chmod 600 "$SETTINGS_FILE" 2>/dev/null

# Белый список и пользовательские правила: файлы пользователя никогда не
# перезаписываются, иначе обновление стирало бы его настройку.
if [ ! -f "$WHITELIST_FILE" ]; then
  cp -f "$MODPATH/whitelist.list" "$WHITELIST_FILE" 2>/dev/null
  chmod 600 "$WHITELIST_FILE" 2>/dev/null
fi
if [ ! -f "$DATA_DIR/rules.conf" ]; then
  cp -f "$MODPATH/rules.conf" "$DATA_DIR/rules.conf" 2>/dev/null
  chmod 600 "$DATA_DIR/rules.conf" 2>/dev/null
fi

# --------------------------------------------------------------------- политика

. "$MODPATH/lib.sh"
aad_sync_policy "install"
policy_rc=$?
if [ "$policy_rc" -eq 1 ]; then
  abort "! Не удалось создать файл политики движка."
elif [ "$policy_rc" -eq 2 ]; then
  ui_print "! PackageManager недоступен: движок останется выключенным до перезагрузки."
else
  ui_print "- Политика движка сформирована."
fi

# ----------------------------------------------------------------------- права

set_perm "$MODPATH/lib.sh" 0 0 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/config_event.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
if [ -d "$MODPATH/zygisk" ]; then
  set_perm_recursive "$MODPATH/zygisk" 0 0 0755 0644
fi

# --------------------------------------------------------------- проверка Zygisk

# Провайдеров Zygisk несколько, и опознать их по одному имени нельзя:
# ZygiskNext ставится как модуль zygisksu, ReZygisk — как rezygisk.
# Проверять «в имени есть zygisk» тоже неверно: под это подпадают LSPosed и
# любой сторонний zygisk-модуль, который сам провайдером не является.
detect_zygisk() {
  for zid in zygisksu rezygisk; do
    if [ -d "/data/adb/modules/$zid" ] && [ ! -f "/data/adb/modules/$zid/disable" ]; then
      ZYGISK_PROVIDER="$zid"
      return 0
    fi
  done
  # Рабочие каталоги провайдеров: остаются, даже если модуль переименован.
  if [ -d /data/adb/zygisksu ]; then ZYGISK_PROVIDER="zygisksu"; return 0; fi
  if [ -d /data/adb/rezygisk ]; then ZYGISK_PROVIDER="rezygisk"; return 0; fi
  # Встроенный Zygisk в Magisk.
  if command -v magisk >/dev/null 2>&1; then
    zstate=$(magisk --sqlite "select value from settings where key='zygisk'" 2>/dev/null | sed -n 's/^value=//p')
    if [ "$zstate" = "1" ]; then ZYGISK_PROVIDER="magisk"; return 0; fi
  fi
  # APatch поставляет Zygisk в своём составе.
  if [ "$APATCH" = "true" ] || [ "$KERNELPATCH" = "true" ]; then
    ZYGISK_PROVIDER="apatch"
    return 0
  fi
  return 1
}

ZYGISK_OK=0
ZYGISK_PROVIDER=""
detect_zygisk && ZYGISK_OK=1

ui_print " "
if [ "$ZYGISK_OK" -eq 1 ]; then
  ui_print "- Zygisk: обнаружен ($ZYGISK_PROVIDER)."
else
  ui_print "! Zygisk не обнаружен."
  ui_print "  Модуль v7 работает ТОЛЬКО через Zygisk."
  ui_print "  Magisk: включите Zygisk в настройках."
  ui_print "  KernelSU: установите ZygiskNext или ReZygisk."
fi
ilog "zygisk_detected=$ZYGISK_OK provider=${ZYGISK_PROVIDER:-none}"

# Маркер ставится последним: если установка оборвалась раньше, следующая
# попытка должна снова пройти полную миграцию.
: > "$V7_MIGRATED_MARKER" 2>/dev/null
chmod 600 "$V7_MIGRATED_MARKER" 2>/dev/null

ui_print " "
ui_print "- Установка завершена. Требуется перезагрузка."
ui_print "- Настройки: $SETTINGS_FILE"
ui_print "- Белый список: $WHITELIST_FILE"
ui_print "- Свои правила: $DATA_DIR/rules.conf"
ui_print "- Логи: $LOG_DIR"
