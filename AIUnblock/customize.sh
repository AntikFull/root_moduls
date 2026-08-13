#!/system/bin/sh

SKIPUNZIP=0
OLD_MODPATH="/data/adb/modules/AIUnblock"

[ -f "$MODPATH/lib/module_meta.sh" ] && . "$MODPATH/lib/module_meta.sh"
load_module_metadata "$MODPATH/module.prop"

ui_print "- РЈСЃС‚Р°РЅРѕРІРєР° AI Unblock RU $MODULE_VERSION_LABEL (versionCode=$MODULE_VERSION_CODE)"
ui_print "- Р РµР¶РёРј СЏРґСЂР°: С‚РѕР»СЊРєРѕ РїСЂРёР»РѕР¶РµРЅРёСЏ РёР· apps.list/apps.user.list"
ui_print "- РЎРёСЃС‚РµРјРЅС‹Р№ DNS Android РЅРµ РјРµРЅСЏРµС‚СЃСЏ"
ui_print "- Hosts/AdBlock вЂ” РЅРµР·Р°РІРёСЃРёРјС‹Р№ optional-РєРѕРјРїРѕРЅРµРЅС‚ Рё РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ РІС‹РєР»СЋС‡РµРЅ"

# Multi-ABI native core. Root managers РѕР±С‹С‡РЅРѕ РїРµСЂРµРґР°СЋС‚ ARCH РєР°Рє arm64/arm/x64/x86;
# РїСЂРё СЂСѓС‡РЅРѕР№ СѓСЃС‚Р°РЅРѕРІРєРµ РёСЃРїРѕР»СЊР·СѓРµРј ro.product.cpu.abi.
detected_arch="${ARCH:-$(getprop ro.product.cpu.abi 2>/dev/null)}"
case "$detected_arch" in
  arm64|arm64-v8a|aarch64) native_abi="arm64-v8a" ;;
  arm|armeabi-v7a|armeabi|armv7l) native_abi="armeabi-v7a" ;;
  x64|x86_64|amd64) native_abi="x86_64" ;;
  x86|i386|i486|i586|i686) native_abi="x86" ;;
  *) abort "AIUnblock $MODULE_VERSION_LABEL: РЅРµРїРѕРґРґРµСЂР¶РёРІР°РµРјР°СЏ Р°СЂС…РёС‚РµРєС‚СѓСЂР°: ${detected_arch:-unknown}." ;;
esac
ui_print "- РђСЂС…РёС‚РµРєС‚СѓСЂР°: $native_abi"

native_checksum_ok() {
  file="$1"
  rel=${file#"$MODPATH/bin/"}
  [ -s "$file" ] || return 1
  if command -v sha256sum >/dev/null 2>&1 && [ -f "$MODPATH/bin/SHA256SUMS.all" ]; then
    # Р’С‚РѕСЂРѕРµ РїРѕР»Рµ РјРѕР¶РµС‚ Р±С‹С‚СЊ РєР°Рє "path", С‚Р°Рє Рё "*path" (Р±РёРЅР°СЂРЅС‹Р№ СЂРµР¶РёРј sha256sum).
    expected=$(awk -v f="$rel" '{ name=$2; sub(/^\*/, "", name); if (name==f) print $1 }' "$MODPATH/bin/SHA256SUMS.all" | head -n 1)
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || return 1
  fi
  return 0
}

# ARM64 СЃРЅР°С‡Р°Р»Р° РёСЃРїРѕР»СЊР·СѓРµС‚ Android PIE, Р·Р°С‚РµРј static fallback. РћСЃС‚Р°Р»СЊРЅС‹Рµ ABI РёРјРµСЋС‚ РѕРґРёРЅ static core.
NATIVE_CANDIDATES="$MODPATH/bin/$native_abi/aiunblock-native"
[ "$native_abi" = "arm64-v8a" ] && NATIVE_CANDIDATES="$NATIVE_CANDIDATES $MODPATH/bin/$native_abi/aiunblock-native.static"
native_selected=""
for native_src in $NATIVE_CANDIDATES; do
  native_checksum_ok "$native_src" || continue
  cp -f "$native_src" "$MODPATH/bin/aiunblock-native" || continue
  chmod 0700 "$MODPATH/bin/aiunblock-native" 2>/dev/null
  if "$MODPATH/bin/aiunblock-native" self-test >/dev/null 2>&1; then
    native_selected=${native_src##*/}
    [ "$native_selected" = "aiunblock-native.static" ] && native_selected="static-fallback"
    [ "$native_selected" = "aiunblock-native" ] && native_selected="primary"
    break
  fi
  rm -f "$MODPATH/bin/aiunblock-native"
done
[ -n "$native_selected" ] || abort "Native core РЅРµ Р·Р°РїСѓСЃРєР°РµС‚СЃСЏ РЅР° СЌС‚РѕРј СѓСЃС‚СЂРѕР№СЃС‚РІРµ ($native_abi). РЈСЃС‚Р°РЅРѕРІРєР° РѕСЃС‚Р°РЅРѕРІР»РµРЅР° Р±РµР·РѕРїР°СЃРЅРѕ."
ui_print "- Native core: $native_selected / self-test OK"
printf '%s\n' "$native_abi/$native_selected" > "$MODPATH/.native_abi" 2>/dev/null
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$MODPATH/bin/aiunblock-native" 2>/dev/null | awk '{print $1}' > "$MODPATH/.native_sha256"
fi

# РќР° СѓСЃС‚СЂРѕР№СЃС‚РІРµ С…СЂР°РЅРёРј С‚РѕР»СЊРєРѕ РІС‹Р±СЂР°РЅРЅС‹Р№ Р±РёРЅР°СЂРЅРёРє; ABI-РєР°С‚Р°Р»РѕРіРё РЅСѓР¶РЅС‹ С‚РѕР»СЊРєРѕ РІ СѓРЅРёРІРµСЂСЃР°Р»СЊРЅРѕРј ZIP.
rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a" "$MODPATH/bin/x86_64" "$MODPATH/bin/x86"
rm -f "$MODPATH/bin/aiunblock-router" "$MODPATH/bin/curl" "$MODPATH/bin/SHA256SUMS" 2>/dev/null

# РќРѕСЂРјР°Р»РёР·СѓРµРј С‚РµРєСЃС‚РѕРІС‹Рµ С„Р°Р№Р»С‹, РєРѕС‚РѕСЂС‹Рµ РјРѕРіСѓС‚ СЂРµРґР°РєС‚РёСЂРѕРІР°С‚СЊСЃСЏ РЅР° Windows.
for text_file in \
  "$MODPATH/etc/hosts.ai" \
  "$MODPATH/etc/hosts.adblock" \
  "$MODPATH/apps.list" \
  "$MODPATH/locale_apps.list" \
  "$MODPATH/sni_routes.conf" \
  "$MODPATH/smartdns.conf"; do
  [ -f "$text_file" ] && sed -i 's/\r$//' "$text_file" 2>/dev/null
 done

# РџРµСЂРµРЅРѕСЃРёРј С‚РѕР»СЊРєРѕ РїРѕР»СЊР·РѕРІР°С‚РµР»СЊСЃРєРѕРµ/РґРёРЅР°РјРёС‡РµСЃРєРѕРµ СЃРѕСЃС‚РѕСЏРЅРёРµ. Р‘Р°Р·РѕРІС‹Рµ СЃРїРёСЃРєРё
# РёР· СЂРµР»РёР·Р° РІСЃРµРіРґР° РѕР±РЅРѕРІР»СЏСЋС‚СЃСЏ, РїРѕР»СЊР·РѕРІР°С‚РµР»СЊСЃРєРёРµ РґРѕР±Р°РІР»РµРЅРёСЏ Р»РµР¶Р°С‚ РѕС‚РґРµР»СЊРЅРѕ.
if [ "$OLD_MODPATH" != "$MODPATH" ] && [ -d "$OLD_MODPATH" ]; then
  for state_file in \
    install.conf \
    app_locales.state \
    proxies.override \
    smartdns.user.conf \
    apps.user.list; do
    [ -f "$OLD_MODPATH/$state_file" ] && cp -f "$OLD_MODPATH/$state_file" "$MODPATH/$state_file"
  done

  mkdir -p "$MODPATH/gateways"
  for gateway_file in gemini.current notebook.current grok.current chatgpt.current claude.current; do
    [ -f "$OLD_MODPATH/gateways/$gateway_file" ] && cp -f "$OLD_MODPATH/gateways/$gateway_file" "$MODPATH/gateways/$gateway_file"
  done
fi

# РЈРґР°Р»СЏРµРј С‚РѕР»СЊРєРѕ РѕС€РёР±РѕС‡РЅС‹Р№ legacy skip_mount Рё transient-С„Р»Р°РіРё. РЎС‚Р°С‚СѓСЃ disable, РµСЃР»Рё РµРіРѕ СЃРѕС…СЂР°РЅСЏРµС‚ root-manager, РЅРµ РїРµСЂРµРѕРїСЂРµРґРµР»СЏРµРј.
rm -f "$MODPATH/skip_mount" "$MODPATH/.force_refresh" "$MODPATH/.reload"

# РќРѕРІС‹Р№ install.conf: core-only, fail-open. РџСЂРё РѕР±РЅРѕРІР»РµРЅРёРё СЃС‚Р°СЂС‹Рµ РІС‹Р±РѕСЂС‹ СЃРѕС…СЂР°РЅСЏСЋС‚СЃСЏ.
AIUNBLOCK_CONFIG_FILE="$MODPATH/install.conf"
. "$MODPATH/lib/config.sh"
config_load "$AIUNBLOCK_CONFIG_FILE"
config_write "$AIUNBLOCK_CONFIG_FILE" || abort "РќРµ СѓРґР°Р»РѕСЃСЊ Р·Р°РїРёСЃР°С‚СЊ install.conf"

ui_print "- РљРѕРЅС„РёРіСѓСЂР°С†РёСЏ: hosts=$ENABLE_HOSTS_ROUTING, adblock=$ENABLE_ADBLOCK, locale=$ENABLE_APP_LOCALE, fail=$FAIL_MODE"

# Optional hosts СЃС‚СЂРѕРёС‚СЃСЏ РґРѕ mount stage. РљРѕРЅС„Р»РёРєС‚ РќР• РѕС‚РєР»СЋС‡Р°РµС‚ РјРѕРґСѓР»СЊ С†РµР»РёРєРѕРј.
. "$MODPATH/lib/hosts.sh"
prepare_hosts_tree "$MODPATH" || {
  rm -rf "$MODPATH/system" 2>/dev/null
  ui_print "! Optional hosts РЅРµ РїРѕРґРіРѕС‚РѕРІР»РµРЅ. Per-app routing РІСЃС‘ СЂР°РІРЅРѕ Р±СѓРґРµС‚ СЂР°Р±РѕС‚Р°С‚СЊ."
}

set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in customize.sh post-fs-data.sh late-load.sh boot-completed.sh service.sh action.sh uninstall.sh; do
  [ -f "$MODPATH/$script" ] && set_perm "$MODPATH/$script" 0 0 0755
 done
for script in "$MODPATH"/lib/*.sh; do
  [ -f "$script" ] && set_perm "$script" 0 0 0644
 done
[ -f "$MODPATH/bin/aiunblock-native" ] && set_perm "$MODPATH/bin/aiunblock-native" 0 0 0700
[ -f "$MODPATH/bin/aiunblockctl" ] && set_perm "$MODPATH/bin/aiunblockctl" 0 0 0755
[ -f "$MODPATH/sni_routes.conf" ] && set_perm "$MODPATH/sni_routes.conf" 0 0 0600
[ -f "$MODPATH/install.conf" ] && set_perm "$MODPATH/install.conf" 0 0 0644
[ -f "$MODPATH/.native_abi" ] && set_perm "$MODPATH/.native_abi" 0 0 0644
[ -f "$MODPATH/.native_sha256" ] && set_perm "$MODPATH/.native_sha256" 0 0 0644
[ -f "$MODPATH/apps.user.list" ] && set_perm "$MODPATH/apps.user.list" 0 0 0600
[ -f "$MODPATH/proxies.override" ] && set_perm "$MODPATH/proxies.override" 0 0 0600
[ -f "$MODPATH/smartdns.user.conf" ] && set_perm "$MODPATH/smartdns.user.conf" 0 0 0600
[ -d "$MODPATH/gateways" ] && set_perm_recursive "$MODPATH/gateways" 0 0 0700 0600

ui_print "- Р“РѕС‚РѕРІРѕ. AI Unblock Р·Р°РїСѓСЃРєР°РµС‚СЃСЏ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РїРѕСЃР»Рµ РїРµСЂРµР·Р°РіСЂСѓР·РєРё."
ui_print "- Р›РѕРіРё: /sdcard/eCubz/AIUnblock/logs"
ui_print "- РџСЂРё РїСЂРѕР±Р»РµРјРµ РЅР°Р¶РјРёС‚Рµ Action Сѓ РјРѕРґСѓР»СЏ вЂ” РґРёР°РіРЅРѕСЃС‚РёРєР° СЃРѕС…СЂР°РЅРёС‚СЃСЏ С‚СѓРґР° Р¶Рµ."
