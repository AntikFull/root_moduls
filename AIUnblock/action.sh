#!/system/bin/sh
# AI Unblock RU - Переключатель конфигурации в режиме реального времени

MODDIR=${0%/*}
CONF="$MODDIR/install.conf"

[ -f "$CONF" ] || {
  echo "ENABLE_HOSTS_ROUTING=1" > "$CONF"
  echo "ENABLE_ADBLOCK=1" >> "$CONF"
}

. "$CONF"

# Валидация значений из install.conf
case "$ENABLE_HOSTS_ROUTING" in 0|1) ;; *) ENABLE_HOSTS_ROUTING=1 ;; esac
case "$ENABLE_ADBLOCK" in 0|1) ;; *) ENABLE_ADBLOCK=1 ;; esac

echo "=== AI Unblock RU Configuration ==="
echo "Текущее состояние:"
echo "1. AI Hosts Routing: $ENABLE_HOSTS_ROUTING (1 - вкл, 0 - выкл)"
echo "2. AdBlock: $ENABLE_ADBLOCK (1 - вкл, 0 - выкл)"
echo "-----------------------------------"

# Переключение режима при каждом запуске action.sh
if [ "$ENABLE_HOSTS_ROUTING" -eq 1 ] && [ "$ENABLE_ADBLOCK" -eq 1 ]; then
  ENABLE_HOSTS_ROUTING=1
  ENABLE_ADBLOCK=0
  echo "Переключено на: Только AI-роутинг (AdBlock выключен)"
elif [ "$ENABLE_HOSTS_ROUTING" -eq 1 ] && [ "$ENABLE_ADBLOCK" -eq 0 ]; then
  ENABLE_HOSTS_ROUTING=0
  ENABLE_ADBLOCK=0
  echo "Переключено на: Hosts отключен полностью (только SNI/DNAT)"
  # Явное отмонтирование hosts при отключении обох опций
  mount | grep -q "/system/etc/hosts" && umount -l /system/etc/hosts 2>/dev/null
elif [ "$ENABLE_HOSTS_ROUTING" -eq 0 ] && [ "$ENABLE_ADBLOCK" -eq 0 ]; then
  ENABLE_HOSTS_ROUTING=0
  ENABLE_ADBLOCK=1
  echo "Переключено на: Только AdBlock (без AI-hosts)"
else
  ENABLE_HOSTS_ROUTING=1
  ENABLE_ADBLOCK=1
  echo "Переключено на: AI-роутинг + AdBlock (Полный режим)"
fi

echo "ENABLE_HOSTS_ROUTING=$ENABLE_HOSTS_ROUTING" > "$CONF"
echo "ENABLE_ADBLOCK=$ENABLE_ADBLOCK" >> "$CONF"
chmod 0644 "$CONF" 2>/dev/null

# Вызываем перезапуск монтирования hosts в service.sh если сервис работает
if [ -f "$MODDIR/service.sh" ]; then
  sh "$MODDIR/service.sh" --remount-hosts >/dev/null 2>&1 &
fi

echo "Настройки сохранены в install.conf"
