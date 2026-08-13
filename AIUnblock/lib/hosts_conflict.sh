#!/system/bin/sh

hosts_conflict_detected() {
  local own_id="$1" dir id

  for id in bindhosts Systemless_Hosts systemless_hosts hosts; do
    dir="/data/adb/modules/$id"
    [ -d "$dir" ] || continue
    [ "$id" = "$own_id" ] && continue
    [ -f "$dir/disable" ] && continue
    [ -f "$dir/remove" ] && continue
    echo "$id"
    return 0
  done

  for dir in /data/adb/modules/*/; do
    [ -d "$dir" ] || continue
    id="${dir%/}"
    id="${id##*/}"

    [ "$id" = "$own_id" ] && continue
    [ -f "${dir}disable" ] && continue
    [ -f "${dir}remove" ] && continue
    [ -f "${dir}skip_mount" ] && continue

    if [ -s "${dir}system/etc/hosts" ] || [ -s "/data/adb/metamodule/mnt/$id/system/etc/hosts" ]; then
      echo "$id"
      return 0
    fi
  done

  for dir in /data/adb/metamodule/mnt/*/; do
    [ -d "$dir" ] || continue
    id="${dir%/}"
    id="${id##*/}"
    [ "$id" = "$own_id" ] && continue
    [ -s "${dir}system/etc/hosts" ] || continue
    echo "$id"
    return 0
  done

  return 1
}
