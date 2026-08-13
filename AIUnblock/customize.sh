#!/system/bin/sh

SKIPUNZIP=0
OLD_MODPATH="/data/adb/modules/AIUnblock"

[ -f "$MODPATH/lib/module_meta.sh" ] && . "$MODPATH/lib/module_meta.sh"
load_module_metadata "$MODPATH/module.prop"

ui_print "- РССРРРРРР AI Unblock RU $MODULE_VERSION_LABEL (versionCode=$MODULE_VERSION_CODE)"
ui_print "- РРРРР СРСР: СРРСРР РСРРРРРРРС РР apps.list/apps.user.list"
ui_print "- РРССРРРСР DNS Android РР РРРСРССС"
ui_print "- Hosts/AdBlock в РРРРРРСРРСР optional-РРРРРРРРС Р РР СРРРСРРРС РСРРССРР"

detected_arch="${ARCH:-$(getprop ro.product.cpu.abi 2>/dev/null)}"
case "$detected_arch" in
  arm64|arm64-v8a|aarch64) native_abi="arm64-v8a" ;;
  arm|armeabi-v7a|armeabi|armv7l) native_abi="armeabi-v7a" ;;
  x64|x86_64|amd64) native_abi="x86_64" ;;
  x86|i386|i486|i586|i686) native_abi="x86" ;;
  *) abort "AIUnblock $MODULE_VERSION_LABEL: РРРРРРРСРРРРРРРС РССРСРРСССР: ${detected_arch:-unknown}." ;;
esac
ui_print "- РССРСРРСССР: $native_abi"

native_checksum_ok() {
  file="$1"
  rel=${file#"$MODPATH/bin/"}
  [ -s "$file" ] || return 1
  if command -v sha256sum >/dev/null 2>&1 && [ -f "$MODPATH/bin/SHA256SUMS.all" ]; then
    expected=$(awk -v f="$rel" '{ name=$2; sub(/^\*/, "", name); if (name==f) print $1 }' "$MODPATH/bin/SHA256SUMS.all" | head -n 1)
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || return 1
  fi
  return 0
}

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
[ -n "$native_selected" ] || abort "Native core РР РРРССРРРССС РР ССРР ССССРРССРР ($native_abi). РССРРРРРР РССРРРРРРРР РРРРРРСРР."
ui_print "- Native core: $native_selected / self-test OK"
printf '%s\n' "$native_abi/$native_selected" > "$MODPATH/.native_abi" 2>/dev/null
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$MODPATH/bin/aiunblock-native" 2>/dev/null | awk '{print $1}' > "$MODPATH/.native_sha256"
fi

rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a" "$MODPATH/bin/x86_64" "$MODPATH/bin/x86"
rm -f "$MODPATH/bin/aiunblock-router" "$MODPATH/bin/curl" "$MODPATH/bin/SHA256SUMS" 2>/dev/null

for text_file in \
  "$MODPATH/etc/hosts.ai" \
  "$MODPATH/etc/hosts.adblock" \
  "$MODPATH/apps.list" \
  "$MODPATH/locale_apps.list" \
  "$MODPATH/sni_routes.conf" \
  "$MODPATH/smartdns.conf"; do
  [ -f "$text_file" ] && sed -i 's/\r$//' "$text_file" 2>/dev/null
 done

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

rm -f "$MODPATH/skip_mount" "$MODPATH/.force_refresh" "$MODPATH/.reload"

AIUNBLOCK_CONFIG_FILE="$MODPATH/install.conf"
. "$MODPATH/lib/config.sh"
config_load "$AIUNBLOCK_CONFIG_FILE"
config_write "$AIUNBLOCK_CONFIG_FILE" || abort "РР СРРРРСС РРРРСРСС install.conf"

ui_print "- РРРСРРССРСРС: hosts=$ENABLE_HOSTS_ROUTING, adblock=$ENABLE_ADBLOCK, locale=$ENABLE_APP_LOCALE, fail=$FAIL_MODE"

. "$MODPATH/lib/hosts.sh"
prepare_hosts_tree "$MODPATH" || {
  rm -rf "$MODPATH/system" 2>/dev/null
  ui_print "! Optional hosts РР РРРРРСРРРРР. Per-app routing РСС СРРРР РСРРС СРРРСРСС."
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

ui_print "- РРСРРР. AI Unblock РРРССРРРССС РРСРРРСРСРСРР РРСРР РРСРРРРССРРР."
ui_print "- РРРР: /sdcard/eCubz/AIUnblock/logs"
ui_print "- РСР РСРРРРРР РРРРРСР Action С РРРСРС в РРРРРРССРРР СРССРРРССС ССРР РР."
