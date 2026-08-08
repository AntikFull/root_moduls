#!/system/bin/sh
# Кнопка Action перезапускает модуль и открывает локальный WebUI.

MODDIR="${0%/*}"
echo "Перезапуск Zapret2 eCubz..."
sh "$MODDIR/service.sh"
echo "WebUI открывается через страницу модуля в KernelSU Next. Отдельный HTTP-порт не используется."
