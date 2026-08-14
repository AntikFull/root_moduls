#!/system/bin/sh
MODDIR=${0%/*}
CTL="$MODDIR/bin/aiunblockctl"
PUBLIC_LOG_DIR="/sdcard/eCubz/AIUnblock/logs"

echo "AI Unblock: Обновление конфигурации..."
if [ ! -x "$CTL" ]; then
  echo "Ошибка: Бинарный файл управления отсутствует."
  exit 1
fi

"$CTL" refresh >/dev/null 2>&1 || true
"$CTL" diag manual

echo "-----------------------------------"
echo "Готово."
echo "Диагностика и логи сохранены в:"
echo "$PUBLIC_LOG_DIR"
