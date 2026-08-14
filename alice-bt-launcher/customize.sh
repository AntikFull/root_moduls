#!/system/bin/sh

# Установка прав доступа для файлов модуля
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/config.conf 0 0 0644

ui_print "=========================================="
ui_print "  Alice AI Bluetooth Auto-Launcher v1.1.0 "
ui_print "  Автор: eCubz (https://t.me/eCubz)      "
ui_print "  Группа: https://t.me/module_ecubz       "
ui_print "=========================================="
ui_print "- Настройки сохранены в config.conf"
ui_print "- Модуль успешно установлен!"
