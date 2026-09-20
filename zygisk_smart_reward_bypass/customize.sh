#!/system/bin/sh
export PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
SKIPUNZIP=0

MOD_VER="$(grep_prop version "$MODPATH/module.prop" 2>/dev/null || echo "unknown")" # глушение-обосновано: безопасное чтение версии при установке
MOD_VCODE="$(grep_prop versionCode "$MODPATH/module.prop" 2>/dev/null || echo "unknown")" # глушение-обосновано: безопасное чтение кода версии
MOD_NAME="$(grep_prop name "$MODPATH/module.prop" 2>/dev/null || echo "Smart Reward & Ad Bypass Zygisk")" # глушение-обосновано: безопасное чтение имени модуля

ui_print "***********************************************"
ui_print "* $MOD_NAME"
ui_print "* $MOD_VER (versionCode=$MOD_VCODE)"
ui_print "* Author: eCubz (https://t.me/eCubz)"
ui_print "***********************************************"

# Проверка минимальной версии Android (API 26 / Android 8.0+)
if [ "$API" -lt 26 ]; then
    ui_print "! Неподдерживаемая версия Android: API $API (требуется Android 8.0+ / API 26)"
    abort "! Прерывание установки."
fi

# Проверка поддерживаемой архитектуры
if [ "$ARCH" != "arm" ] && [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86" ] && [ "$ARCH" != "x64" ]; then
    ui_print "! Неподдерживаемая архитектура: $ARCH"
    abort "! Прерывание установки."
fi

# Каталог конфигураций
DATA_DIR="/data/adb/zygisk_smart_reward_bypass"
mkdir -p "$DATA_DIR/logs" 2>/dev/null # глушение-обосновано: директория логов может уже существовать

# 1. Инициализация или безопасное обновление smart_reward.list
if [ ! -f "$DATA_DIR/smart_reward.list" ]; then
    if [ -f "$MODPATH/smart_reward.list" ]; then
        cp -f "$MODPATH/smart_reward.list" "$DATA_DIR/smart_reward.list" 2>/dev/null # глушение-обосновано: первичное копирование дефолтного списка
    fi
else
    # Сохраняем свежий образец конфигурации
    cp -f "$MODPATH/smart_reward.list" "$DATA_DIR/smart_reward.list.example" 2>/dev/null || true # глушение-обосновано: сохранение примера конфигурации

    # Аккуратно добавляем новые целевые пакеты в существующий список строго по совпадению всей строки (-Fxq)
    if [ -f "$MODPATH/smart_reward.list" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            clean_line="$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')"
            case "$clean_line" in
                ""|\#*) continue ;;
                *)
                    if ! grep -Fxq "$clean_line" "$DATA_DIR/smart_reward.list" 2>/dev/null; then # глушение-обосновано: проверка наличия строки в пользовательском списке
                        echo "$clean_line" >> "$DATA_DIR/smart_reward.list"
                    fi
                    ;;
            esac
        done < "$MODPATH/smart_reward.list"
    fi
fi

# 2. Инициализация и актуализация il2cpp_hooks.conf
if [ -f "$MODPATH/il2cpp_hooks.conf" ]; then
    if [ -f "$DATA_DIR/il2cpp_hooks.conf" ]; then
        cp -f "$DATA_DIR/il2cpp_hooks.conf" "$DATA_DIR/il2cpp_hooks.conf.bak" 2>/dev/null || true # глушение-обосновано: создание бэкапа перед обновлением
    fi
    cp -f "$MODPATH/il2cpp_hooks.conf" "$DATA_DIR/il2cpp_hooks.conf" 2>/dev/null || true # глушение-обосновано: актуализация правил перехвата
fi

# 3. Инициализация и актуализация reporting.conf
if [ -f "$MODPATH/reporting.conf" ]; then
    if [ ! -f "$DATA_DIR/reporting.conf" ]; then
        cp -f "$MODPATH/reporting.conf" "$DATA_DIR/reporting.conf" 2>/dev/null || true # глушение-обосновано: первичное копирование конфигурации
    else
        cp -f "$MODPATH/reporting.conf" "$DATA_DIR/reporting.conf.example" 2>/dev/null || true # глушение-обосновано: сохранение примера новой конфигурации
    fi
fi

# Установка безопасных прав доступа (0755/0644 для чтения из контекста непривилегированных процессов)
chmod 755 "$DATA_DIR" 2>/dev/null || true # глушение-обосновано: установка прав доступа к каталогу
chmod 755 "$DATA_DIR/logs" 2>/dev/null || true # глушение-обосновано: установка прав доступа к каталогу логов
if [ -f "$DATA_DIR/smart_reward.list" ]; then
    chmod 644 "$DATA_DIR/smart_reward.list" 2>/dev/null || true # глушение-обосновано: установка прав доступа к списку пакетов
fi
if [ -f "$DATA_DIR/il2cpp_hooks.conf" ]; then
    chmod 644 "$DATA_DIR/il2cpp_hooks.conf" 2>/dev/null || true # глушение-обосновано: установка прав доступа к правилам
fi
if [ -f "$DATA_DIR/reporting.conf" ]; then
    chmod 644 "$DATA_DIR/reporting.conf" 2>/dev/null || true # глушение-обосновано: установка прав доступа к конфигу
fi

# Зеркало логов
mkdir -p "/sdcard/eCubz/logs/zygisk_smart_reward_bypass" 2>/dev/null || true # глушение-обосновано: sdcard может быть недоступна при установке из recovery

ui_print "- Zygisk Smart Reward & Probe Engine: установлен"
ui_print "- Конфигурации размещены в $DATA_DIR"
ui_print "- Журнал событий: отключен по умолчанию (создайте $DATA_DIR/debug для отладки)"
ui_print "- Установка завершена успешно."
