#!/system/bin/sh
# AI Unblock RU — безопасная загрузка runtime-настроек без source/eval.

AIUNBLOCK_CONFIG_FILE="${AIUNBLOCK_CONFIG_FILE:-$MODDIR/install.conf}"

_config_read_raw() {
  local file="$1" key="$2"
  [ -r "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n 1 | tr -d '\r'
}

config_load() {
  local file="${1:-$AIUNBLOCK_CONFIG_FILE}" value

  ENABLE_HOSTS_ROUTING=0
  ENABLE_ADBLOCK=0
  ENABLE_APP_LOCALE=0
  FAIL_MODE=0
  BLOCKED_LOC=RU

  value=$(_config_read_raw "$file" ENABLE_HOSTS_ROUTING)
  case "$value" in 0|1) ENABLE_HOSTS_ROUTING="$value" ;; esac

  value=$(_config_read_raw "$file" ENABLE_ADBLOCK)
  case "$value" in 0|1) ENABLE_ADBLOCK="$value" ;; esac

  value=$(_config_read_raw "$file" ENABLE_APP_LOCALE)
  case "$value" in 0|1) ENABLE_APP_LOCALE="$value" ;; esac

  value=$(_config_read_raw "$file" FAIL_MODE)
  case "$value" in
    0|1) FAIL_MODE="$value" ;;
    direct) FAIL_MODE=0 ;;  # migration from v2.3.0-rc1..rc3
    block) FAIL_MODE=1 ;;   # migration from v2.3.0-rc1..rc3
  esac

  value=$(_config_read_raw "$file" BLOCKED_LOC)
  case "$value" in
    off|OFF|Off) BLOCKED_LOC="" ;;
    [A-Za-z][A-Za-z]) BLOCKED_LOC=$(printf '%s' "$value" | tr 'a-z' 'A-Z') ;;
  esac
}

config_write() {
  local file="${1:-$AIUNBLOCK_CONFIG_FILE}" tmp
  tmp="$file.tmp.$$"
  umask 022
  {
    echo "# AI Unblock RU — пользовательские настройки"
    echo "#"
    echo "# Основной обход ChatGPT/Gemini/Claude/Grok/NotebookLM работает всегда"
    echo "# только для приложений из apps.list и apps.user.list."
    echo "# Настройки ниже относятся только к дополнительным функциям."
    echo "#"
    echo "# Для переключателей: 0 = выключено, 1 = включено. FAIL_MODE описан отдельно."
    echo "# После ручного изменения hosts-настроек рекомендуется перезагрузка устройства."
    echo ""
    echo "# Дополнительный системный hosts для маршрутизации/разблокировки доменов."
    echo "# Работает для всей системы, а не только для приложений из apps.list."
    echo "# При обнаружении другого hosts-модуля AI Unblock сам отключит только эту функцию;"
    echo "# основной per-app обход продолжит работать. По умолчанию: 0."
    echo "ENABLE_HOSTS_ROUTING=${ENABLE_HOSTS_ROUTING:-0}"
    echo ""
    echo "# Дополнительная блокировка рекламы и трекеров через системный hosts."
    echo "# Работает для всей системы. Может использоваться отдельно от hosts-маршрутизации."
    echo "# При конфликте с другим hosts-модулем автоматически не подключается. По умолчанию: 0."
    echo "ENABLE_ADBLOCK=${ENABLE_ADBLOCK:-0}"
    echo ""
    echo "# Принудительно выставлять английский язык (en-US) для поддерживаемых AI-приложений."
    echo "# 0 = не менять язык приложений; 1 = включить en-US. По умолчанию: 0."
    echo "ENABLE_APP_LOCALE=${ENABLE_APP_LOCALE:-0}"
    echo ""
    echo "# Поведение выбранных AI-приложений, если обход временно недоступен."
    echo "# 0 = только ПРИ АВАРИИ обхода разрешить обычное прямое подключение."
    echo "#     В нормальном состоянии DNAT/SNI/QUIC-правила AI Unblock продолжают работать."
    echo "# 1 = при АВАРИИ обхода запретить прямой выход до восстановления AI Unblock."
    echo "# Рекомендуемое и стандартное значение: 0."
    echo "FAIL_MODE=${FAIL_MODE:-0}"
    echo ""
    echo "# Страна, выход через которую считается НЕ обходом блокировки."
    echo "# Проверяется по данным Cloudflare (/cdn-cgi/trace) при выборе gateway."
    echo "# Без этой проверки заблокированный сервер отвечает обычным кодом 403/200"
    echo "# и модуль принимает его за рабочий маршрут."
    echo "# Двухбуквенный код страны или off, чтобы не проверять. По умолчанию: RU."
    echo "BLOCKED_LOC=${BLOCKED_LOC:-RU}"
  } > "$tmp" || return 1
  chmod 0644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$file"
}
