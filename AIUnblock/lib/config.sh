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

  ENABLE_APP_LOCALE=0
  FAIL_MODE=0
  BLOCKED_LOC=RU

  value=$(_config_read_raw "$file" ENABLE_APP_LOCALE)
  case "$value" in 0|1) ENABLE_APP_LOCALE="$value" ;; esac

  value=$(_config_read_raw "$file" FAIL_MODE)
  case "$value" in
    0|1) FAIL_MODE="$value" ;;
    direct) FAIL_MODE=0 ;;
    block) FAIL_MODE=1 ;;
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
    echo "# Основной обход ChatGPT/Gemini/Claude/Grok/NotebookLM работает автоматически"
    echo "# только для приложений из apps.list и apps.user.list."
    echo "#"
    echo "# Для переключателей: 0 = выключено, 1 = включено."
    echo ""
    echo "# Принудительно выставлять английский язык (en-US) для поддерживаемых AI-приложений."
    echo "# 0 = не менять язык приложений; 1 = включить en-US. По умолчанию: 0."
    echo "ENABLE_APP_LOCALE=${ENABLE_APP_LOCALE:-0}"
    echo ""
    echo "# Поведение выбранных AI-приложений, если обход временно недоступен."
    echo "# 0 = при аварии обхода разрешить прямое подключение."
    echo "# 1 = при аварии обхода запретить прямой выход до восстановления AI Unblock."
    echo "# Рекомендуемое значение: 0."
    echo "FAIL_MODE=${FAIL_MODE:-0}"
    echo ""
    echo "# Страна, выход через которую считается НЕ обходом блокировки."
    echo "# Проверяется по данным Cloudflare (/cdn-cgi/trace) при выборе gateway."
    echo "# Двухбуквенный код страны или off, чтобы не проверять. По умолчанию: RU."
    echo "BLOCKED_LOC=${BLOCKED_LOC:-RU}"
  } > "$tmp" || return 1
  chmod 0644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$file"
}
