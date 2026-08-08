#!/system/bin/sh
# action.sh script for KernelSU / APatch / Magisk Action Button & CLI

MODDIR="${0%/*}"
CONF_FILE="$MODDIR/zapret2.conf"

echo "=========================================="
echo "      Zapret 2 Control Panel (Action)"
echo "=========================================="

if [ -f "$CONF_FILE" ]; then
  . "$CONF_FILE"
fi

echo "Текущие настройки:"
echo " - Режим работы (MODE): ${MODE:-EXCLUDE}"
echo " - Перевод UDP -> TCP (FORCE_TCP): ${FORCE_TCP:-1}"
echo ""

echo "Перезапуск службы zapret2 для гарантии работы..."
sh "$MODDIR/service.sh"

echo ""
echo "Служба zapret2 перезапущена!"
echo "=========================================="
