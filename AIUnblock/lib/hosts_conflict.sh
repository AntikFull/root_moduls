#!/system/bin/sh
# AI Unblock RU вЂ” РѕР±РЅР°СЂСѓР¶РµРЅРёРµ РґСЂСѓРіРѕРіРѕ Р°РєС‚РёРІРЅРѕРіРѕ hosts-РјРѕРґСѓР»СЏ.

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

  # РќРµРєРѕС‚РѕСЂС‹Рµ KernelSU metamodules РґРµСЂР¶Р°С‚ РѕР±СЉРµРґРёРЅС‘РЅРЅРѕРµ РґРµСЂРµРІРѕ РѕС‚РґРµР»СЊРЅРѕ РѕС‚ metadata-dir.
  # РџСЂРѕРІРµСЂСЏРµРј РµРіРѕ С‚РѕР»СЊРєРѕ РєР°Рє РґРѕРїРѕР»РЅРёС‚РµР»СЊРЅС‹Р№ РёСЃС‚РѕС‡РЅРёРє, РЅРµ СЃС‡РёС‚Р°СЏ СЃР°Рј С„Р°РєС‚ РЅР°Р»РёС‡РёСЏ metamodule РєРѕРЅС„Р»РёРєС‚РѕРј.
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
