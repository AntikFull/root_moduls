#!/system/bin/sh
# AI Unblock RU — общая проверка конфликта system/etc/hosts с другими модулями.
#
# Magic mount у Magisk/KernelSU/APatch может конфликтовать, если два модуля
# одновременно предоставляют собственный system/etc/hosts: у некоторых
# менеджеров (в первую очередь KernelSU/его форки и APatch) это приводит
# не просто к "тихой" победе одного модуля, а к обнаружению конфликта
# монтирования и автоматическому отключению модуля на следующей загрузке.
#
# hosts_conflict_detected <own_module_id>
#   Возвращает 0 и печатает id первого найденного конфликтующего модуля,
#   если есть другой АКТИВНЫЙ модуль с непустым system/etc/hosts.
#   Возвращает 1, если конфликтов не найдено.

hosts_conflict_detected() {
  local own_id="$1"
  local dir id

  for dir in /data/adb/modules/*/; do
    [ -d "$dir" ] || continue

    id="${dir%/}"
    id="${id##*/}"

    [ "$id" = "$own_id" ] && continue
    [ -f "${dir}disable" ] && continue
    [ -f "${dir}remove" ] && continue
    [ -f "${dir}skip_mount" ] && continue

    if [ -s "${dir}system/etc/hosts" ]; then
      echo "$id"
      return 0
    fi
  done

  return 1
}
