#!/system/bin/sh
ui_print "- Установка модуля ADB WiFi On-Demand Fixed Port 5555"
ui_print "- Автор: eCubz (https://t.me/module_ecubz)"
ui_print "- Совместимость: KernelSU / Magisk / APatch"
set_perm "$MODPATH/service.sh" 0 0 0755
ui_print "- Установка завершена! Порт 5555 синхронизирован с тумблером Wi-Fi отладки."
