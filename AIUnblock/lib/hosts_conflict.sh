#!/system/bin/sh
# AI Unblock RU — общая проверка конфликта system/etc/hosts с другими модулями.
# Magic mount у Magisk/KernelSU/APatch может конфликтовать, если два модуля
# одновременно предоставляют собственный system/etc/hosts: у некоторых
# менеджеров (в первую очередь KernelSU/его форки и APatch) это приводит
# не просто к "тихой" победе одного модуля, а к обнаружению конфликта
# монтирования и автоматическому отключению модуля на следующей загрузке.
# hosts_conflict_detected <own_module_id>
# Возвращает 0 и печатает id первого найденного конфликтующего модуля,
# если есть другой АКТИВНЫЙ модуль с непустым system/etc/hosts.
# Возвращает 1, если конфликтов не найдено.

hosts_conflict_detected() {
  local own_id="$1"
  local dir id

# Прямая и быстрая проверка известных модулей hosts во избежание проблем с раскрытием маски
  if [ -d "/data/adb/modules/bindhosts" ] && [ ! -f "/data/adb/modules/bindhosts/disable" ] && [ ! -f "/data/adb/modules/bindhosts/remove" ]; then
    echo "bindhosts"
    return 0
  fi
  if [ -d "/data/adb/modules/Systemless_Hosts" ] && [ ! -f "/data/adb/modules/Systemless_Hosts/disable" ] && [ ! -f "/data/adb/modules/Systemless_Hosts/remove" ]; then
    echo "Systemless_Hosts"
    return 0
  fi

# Универсальный сканер для остальных модулей
  for dir in /data/adb/modules/*/; do
    [ -d "$dir" ] || continue

    id="${dir%/}"
    id="${id##*/}"

    [ "$id" = "$own_id" ] && continue
    [ "$id" = "meta-overlayfs" ] && continue
    [ -f "${dir}disable" ] && continue
    [ -f "${dir}remove" ] && continue
    [ -f "${dir}skip_mount" ] && continue

    if [ -s "${dir}system/etc/hosts" ] || [ -f "${dir}mode" ]; then
      echo "$id"
      return 0
    fi
  done

  return 1
}
