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

ui_print "- Установка AI Unblock RU v2.2.2..."
ui_print "- ПРИМЕЧАНИЕ ПО БЕЗОПАСНОСТИ:"
ui_print "  • Для Gemini, ChatGPT, Claude и Grok используются шлюзы Smart DNS из proxies.conf."
ui_print "  • TLS-валидация гарантирует сквозное шифрование и подлинность целевых сертификатов."
ui_print "  • Шлюзам Smart DNS виден IP клиента, SNI доменов и тайминги подключений."

[ -f "$MODPATH/etc/hosts.ai" ] && sed -i 's/\r$//' "$MODPATH/etc/hosts.ai" 2>/dev/null
[ -f "$MODPATH/etc/hosts.adblock" ] && sed -i 's/\r$//' "$MODPATH/etc/hosts.adblock" 2>/dev/null

# Сохраняем локальное состояние модуля при обновлении (кроме install.conf)
if [ "$OLD_MODPATH" != "$MODPATH" ] && [ -d "$OLD_MODPATH" ]; then
  for state_file in \
    app_locales.state \
    proxies.override \
    smartdns.user.conf; do
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

CHOSEN_KEY=1

choosekey() {
  local prompt_text="$1"
  local default_val="${2:-1}"
  CHOSEN_KEY="$default_val"

  ui_print "  $prompt_text"
  ui_print "  [Громкость +] = ДА | [Громкость -] = НЕТ"

  while true; do
    local key_events
    key_events=$(timeout 3 getevent -l -c 15 2>/dev/null)
    if echo "$key_events" | grep -q "KEY_VOLUMEUP"; then
      CHOSEN_KEY=1
      ui_print "  -> Выбрано: ДА"
      return 0
    elif echo "$key_events" | grep -q "KEY_VOLUMEDOWN"; then
      CHOSEN_KEY=0
      ui_print "  -> Выбрано: НЕТ"
      return 0
    fi
    sleep 0.1
  done
}

# Всегда проводим интерактивный опрос кнопок при установке
ui_print "--------------------------------------------------"
ui_print "- Настройка компонентов AI Unblock RU:"

choosekey "1. Монтировать AI-роутинг hosts (гео-разблокировка ИИ)?" 1
ENABLE_HOSTS_ROUTING=$CHOSEN_KEY

choosekey "2. Включить AdBlock (блокировку рекламы hosts.adblock)?" 1
ENABLE_ADBLOCK=$CHOSEN_KEY

echo "ENABLE_HOSTS_ROUTING=$ENABLE_HOSTS_ROUTING" > "$MODPATH/install.conf"
echo "ENABLE_ADBLOCK=$ENABLE_ADBLOCK" >> "$MODPATH/install.conf"
ui_print "- Конфигурация сохранена в install.conf"
ui_print "--------------------------------------------------"

# Настройка system/etc/hosts в зависимости от выбора в install.conf
prepare_hosts_files() {
  local ai_hosts="$MODPATH/etc/hosts.ai"
  local adblock_hosts="$MODPATH/etc/hosts.adblock"

  [ -f "$MODPATH/install.conf" ] && . "$MODPATH/install.conf"
  local enable_routing=${ENABLE_HOSTS_ROUTING:-1}
  local enable_adblock=${ENABLE_ADBLOCK:-1}

  if [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 0 ]; then
    ui_print "- Hosts отключен. Очищаем папку system/etc/hosts для предотвращения конфликтов."
    rm -rf "$MODPATH/system" 2>/dev/null
  else
    mkdir -p "$MODPATH/system/etc"
    local target_hosts="$MODPATH/system/etc/hosts"

    if [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 0 ]; then
      [ -f "$ai_hosts" ] && cp -f "$ai_hosts" "$target_hosts"
    elif [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 1 ]; then
      [ -f "$adblock_hosts" ] && cp -f "$adblock_hosts" "$target_hosts"
    elif [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 1 ]; then
      if [ -f "$ai_hosts" ] && [ -f "$adblock_hosts" ]; then
        sed 's/\r$//' "$ai_hosts" > "$target_hosts" 2>/dev/null
        echo "" >> "$target_hosts"
        sed 's/\r$//' "$adblock_hosts" >> "$target_hosts" 2>/dev/null
      elif [ -f "$ai_hosts" ]; then
        cp -f "$ai_hosts" "$target_hosts"
      fi
    fi
    [ -f "$target_hosts" ] && chmod 0644 "$target_hosts" 2>/dev/null
  fi
}

prepare_hosts_files

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
[ -f "$MODPATH/post-fs-data.sh" ] && set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
[ -f "$MODPATH/service.sh" ] && set_perm "$MODPATH/service.sh" 0 0 0755
[ -f "$MODPATH/uninstall.sh" ] && set_perm "$MODPATH/uninstall.sh" 0 0 0755
[ -f "$MODPATH/customize.sh" ] && set_perm "$MODPATH/customize.sh" 0 0 0755
[ -f "$MODPATH/action.sh" ] && set_perm "$MODPATH/action.sh" 0 0 0755
[ -f "$MODPATH/bin/aiunblock-router" ] && set_perm "$MODPATH/bin/aiunblock-router" 0 0 0700
[ -f "$MODPATH/bin/curl" ] && set_perm "$MODPATH/bin/curl" 0 0 0755
[ -f "$MODPATH/sni_routes.conf" ] && set_perm "$MODPATH/sni_routes.conf" 0 0 0600
[ -f "$MODPATH/proxies.conf" ] && set_perm "$MODPATH/proxies.conf" 0 0 0644
[ -f "$MODPATH/proxies.override.example" ] && set_perm "$MODPATH/proxies.override.example" 0 0 0644
[ -f "$MODPATH/smartdns.conf" ] && set_perm "$MODPATH/smartdns.conf" 0 0 0644
[ -f "$MODPATH/smartdns.user.conf.example" ] && set_perm "$MODPATH/smartdns.user.conf.example" 0 0 0644
[ -f "$MODPATH/smartdns.user.conf" ] && set_perm "$MODPATH/smartdns.user.conf" 0 0 0600
[ -f "$MODPATH/install.conf" ] && set_perm "$MODPATH/install.conf" 0 0 0644
[ -f "$MODPATH/app_locales.state" ] && set_perm "$MODPATH/app_locales.state" 0 0 0600
[ -f "$MODPATH/proxies.override" ] && set_perm "$MODPATH/proxies.override" 0 0 0600
[ -d "$MODPATH/gateways" ] && set_perm_recursive "$MODPATH/gateways" 0 0 0700 0600

[ -x "$MODPATH/bin/aiunblock-router" ] ||
  abort "bin/aiunblock-router извлечён, но не получил право на запуск."
[ -x "$MODPATH/bin/curl" ] ||
  abort "bin/curl извлечён, но не получил право на запуск."
