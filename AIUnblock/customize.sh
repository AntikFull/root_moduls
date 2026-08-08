#!/system/bin/sh

SKIPUNZIP=0

OLD_MODPATH="/data/adb/modules/AIUnblock"

extract_required_file() {
  local entry="$1"
  local destination="$2"

  [ -s "$destination" ] && return 0

  ui_print "- Повторное извлечение обязательного файла: $entry"
  mkdir -p "${destination%/*}"
  unzip -o "$ZIPFILE" -d "$MODPATH" "$entry" >/dev/null 2>&1 || return 1
  [ -s "$destination" ]
}

ui_print "- Установка AI Unblock RU v2.1.4..."
ui_print "- ПРИМЕЧАНИЕ ПО БЕЗОПАСНОСТИ:"
ui_print "  • Трафик Gemini, ChatGPT, Claude и Grok проксируется через узлы из proxies.conf."
ui_print "  • TLS-валидация гарантирует сквозное шифрование и подлинность целевых сертификатов."
ui_print "  • Узлам прокси виден IP клиента, SNI доменов и тайминги подключений."

sed -i 's/\r$//' "$MODPATH/system/etc/hosts" 2>/dev/null
[ -f "$MODPATH/system/etc/hosts.adblock" ] && sed -i 's/\r$//' "$MODPATH/system/etc/hosts.adblock" 2>/dev/null

# Сохраняем локальное состояние модуля при обновлении
if [ "$OLD_MODPATH" != "$MODPATH" ] && [ -d "$OLD_MODPATH" ]; then
  for state_file in \
    app_locales.state \
    proxies.override \
    install.conf; do
    [ -f "$OLD_MODPATH/$state_file" ] &&
      cp -f "$OLD_MODPATH/$state_file" "$MODPATH/$state_file"
  done

  mkdir -p "$MODPATH/gateways"
  for gateway_file in gemini.current notebook.current grok.current chatgpt.current claude.current; do
    [ -f "$OLD_MODPATH/gateways/$gateway_file" ] &&
      cp -f "$OLD_MODPATH/gateways/$gateway_file" "$MODPATH/gateways/$gateway_file"
  done
fi

# Временные маркеры миграции больше не используются.
rm -f "$MODPATH/.global_locale_restored" "$MODPATH/.google_search_unmanaged"

# Функция опроса клавиш громкости (Vol+ = 1, Vol- = 0, дефолт по таймауту = default_val)
choosekey() {
  local prompt_text="$1"
  local default_val="$2"
  local sel="$default_val"

  ui_print "  $prompt_text"
  ui_print "  [Громкость +] = ДА | [Громкость -] = НЕТ"
  ui_print "  (Автовыбор через 4 сек: $([ "$default_val" -eq 1 ] && echo "ДА" || echo "НЕТ"))"

  if [ -t 0 ] || [ -c /dev/input/event0 ]; then
    local timeout=4
    local start_time=$(date +%s)
    while [ $(($(date +%s) - start_time)) -lt $timeout ]; do
      local key_event=$(timeout 1 getevent -l 2>/dev/null | grep -E "KEY_VOLUMEUP|KEY_VOLUMEDOWN")
      if echo "$key_event" | grep -q "KEY_VOLUMEUP"; then
        sel=1
        ui_print "  -> Выбрано: ДА"
        return $sel
      elif echo "$key_event" | grep -q "KEY_VOLUMEDOWN"; then
        sel=0
        ui_print "  -> Выбрано: НЕТ"
        return $sel
      fi
    done
  fi

  ui_print "  -> Применено значение по умолчанию: $([ "$sel" -eq 1 ] && echo "ДА" || echo "НЕТ")"
  return $sel
}

# Если install.conf еще не существует, проводим опрос или применяем дефолты
if [ ! -f "$MODPATH/install.conf" ]; then
  ui_print "--------------------------------------------------"
  ui_print "- Настройка компонентов AI Unblock RU:"

  choosekey "1. Монтировать AI-роутинг hosts (гео-разблокировка ИИ)?" 1
  ENABLE_HOSTS_ROUTING=$?

  choosekey "2. Включить AdBlock (блокировку рекламы hosts.adblock)?" 1
  ENABLE_ADBLOCK=$?

  echo "ENABLE_HOSTS_ROUTING=$ENABLE_HOSTS_ROUTING" > "$MODPATH/install.conf"
  echo "ENABLE_ADBLOCK=$ENABLE_ADBLOCK" >> "$MODPATH/install.conf"
  ui_print "- Конфигурация сохранена в install.conf"
  ui_print "--------------------------------------------------"
else
  ui_print "- Настройки сохранены из предыдущей версии (install.conf)"
fi

extract_required_file "bin/aiunblock-router" "$MODPATH/bin/aiunblock-router" ||
  abort "Не удалось извлечь bin/aiunblock-router. ZIP повреждён или распакован не полностью."
extract_required_file "bin/curl" "$MODPATH/bin/curl" ||
  abort "Не удалось извлечь bin/curl. ZIP повреждён или распакован не полностью."
extract_required_file "bin/SHA256SUMS" "$MODPATH/bin/SHA256SUMS" || true

# Проверка целостности бинарников при копировании (если sha256sum доступен)
if command -v sha256sum >/dev/null 2>&1 && [ -f "$MODPATH/bin/SHA256SUMS" ]; then
  ui_print "- Проверка целостности файлов при копировании (SHA256)..."
  (cd "$MODPATH/bin" && sha256sum -c SHA256SUMS >/dev/null 2>&1) ||
    abort "КРИТИЧЕСКАЯ ОШИБКА: Контрольная сумма распакованных файлов не совпадает! Установка отменена."
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
[ -f "$MODPATH/action.sh" ] && set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/skip_mount" 0 0 0644
set_perm "$MODPATH/bin/aiunblock-router" 0 0 0700
set_perm "$MODPATH/bin/curl" 0 0 0755
set_perm "$MODPATH/sni_routes.conf" 0 0 0600
[ -f "$MODPATH/proxies.conf" ] && set_perm "$MODPATH/proxies.conf" 0 0 0644
[ -f "$MODPATH/proxies.override.example" ] && set_perm "$MODPATH/proxies.override.example" 0 0 0644
[ -f "$MODPATH/install.conf" ] && set_perm "$MODPATH/install.conf" 0 0 0644
[ -f "$MODPATH/app_locales.state" ] &&
  set_perm "$MODPATH/app_locales.state" 0 0 0600
[ -f "$MODPATH/proxies.override" ] &&
  set_perm "$MODPATH/proxies.override" 0 0 0600
[ -d "$MODPATH/gateways" ] &&
  set_perm_recursive "$MODPATH/gateways" 0 0 0700 0600

[ -x "$MODPATH/bin/aiunblock-router" ] ||
  abort "bin/aiunblock-router извлечён, но не получил право на запуск."
[ -x "$MODPATH/bin/curl" ] ||
  abort "bin/curl извлечён, но не получил право на запуск."


