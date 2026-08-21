#!/system/bin/sh
#
# Обработчик события изменения настроек. Вызывается inotifyd.
#
# Аргументы inotifyd: <события> <каталог> <имя файла>
#
# Автор: eCubz (https://t.me/eCubz)

MODDIR=${0%/*}
child="$3"

case "$child" in
    settings.conf|whitelist.list|rules.conf) ;;
    *) exit 0 ;;
esac

. "$MODDIR/lib.sh"

# Редакторы сохраняют файл в несколько операций записи. Небольшая пауза
# схлопывает пачку событий в одну перегенерацию политики.
sleep 2

aad_sync_policy "inotify:$child"
exit $?
