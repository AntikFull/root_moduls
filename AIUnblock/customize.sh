#!/system/bin/sh

SKIPUNZIP=0
OLD_MODPATH="/data/adb/modules/AIUnblock"

[ -f "$MODPATH/lib/module_meta.sh" ] && . "$MODPATH/lib/module_meta.sh"
load_module_metadata "$MODPATH/module.prop"

ui_print "- Установка AI Unblock RU $MODULE_VERSION_LABEL (versionCode=$MODULE_VERSION_CODE)"
ui_print "- Умная маршрутизация приложений из apps.list/apps.user.list"
ui_print "- Системный DNS Android и hosts не меняются"

detected_arch="${ARCH:-$(getprop ro.product.cpu.abi 2>/dev/null)}"
case "$detected_arch" in
  arm64|arm64-v8a|aarch64) native_abi="arm64-v8a" ;;
  arm|armeabi-v7a|armeabi|armv7l) native_abi="armeabi-v7a" ;;
  x64|x86_64|amd64) native_abi="x86_64" ;;
  x86|i386|i486|i586|i686) native_abi="x86" ;;
  *) abort "AIUnblock $MODULE_VERSION_LABEL: Неподдерживаемая архитектура: ${detected_arch:-unknown}." ;;
esac
ui_print "- Архитектура CPU: $native_abi"

native_checksum_ok() {
  file="$1"
  rel=${file#"$MODPATH/bin/"}
  [ -s "$file" ] || return 1
  if command -v sha256sum >/dev/null 2>&1 && [ -f "$MODPATH/bin/SHA256SUMS.all" ]; then
    expected=$(tr -d '\r' < "$MODPATH/bin/SHA256SUMS.all" 2>/dev/null | awk -v f="$rel" '{ name=$2; sub(/^\*/, "", name); if (name==f) { print $1; exit } }')
    if [ -n "$expected" ]; then
      actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
      [ "$expected" = "$actual" ] || return 1
    fi
  fi
  return 0
}

run_native_selftest() {
  bin_path="$1"
  if "$bin_path" self-test >/dev/null 2>&1; then
    return 0
  fi
  if [ -x /system/bin/linker64 ] && /system/bin/linker64 "$bin_path" self-test >/dev/null 2>&1; then
    return 0
  fi
  if [ -x /system/bin/linker ] && /system/bin/linker "$bin_path" self-test >/dev/null 2>&1; then
    return 0
  fi
  tmp_bin="/data/local/tmp/aiunblock_test_$$"
  cp -f "$bin_path" "$tmp_bin" 2>/dev/null
  chmod 0755 "$tmp_bin" 2>/dev/null
  if "$tmp_bin" self-test >/dev/null 2>&1; then
    rm -f "$tmp_bin" 2>/dev/null
    return 0
  fi
  if [ -x /system/bin/linker64 ] && /system/bin/linker64 "$tmp_bin" self-test >/dev/null 2>&1; then
    rm -f "$tmp_bin" 2>/dev/null
    return 0
  fi
  rm -f "$tmp_bin" 2>/dev/null
  return 1
}

NATIVE_CANDIDATES="$MODPATH/bin/$native_abi/aiunblock-native"
[ "$native_abi" = "arm64-v8a" ] && NATIVE_CANDIDATES="$NATIVE_CANDIDATES $MODPATH/bin/$native_abi/aiunblock-native.static"
native_selected=""
for native_src in $NATIVE_CANDIDATES; do
  native_checksum_ok "$native_src" || continue
  cp -f "$native_src" "$MODPATH/bin/aiunblock-native" || continue
  chmod 0700 "$MODPATH/bin/aiunblock-native" 2>/dev/null
  if run_native_selftest "$MODPATH/bin/aiunblock-native"; then
    native_selected=${native_src##*/}
    [ "$native_selected" = "aiunblock-native.static" ] && native_selected="static-fallback"
    [ "$native_selected" = "aiunblock-native" ] && native_selected="primary"
    break
  fi
  rm -f "$MODPATH/bin/aiunblock-native"
done
[ -n "$native_selected" ] || abort "Native core не прошел проверки на этой системе ($native_abi). Проверьте системные бинарники."
ui_print "- Native core: $native_selected / self-test OK"
printf '%s\n' "$native_abi/$native_selected" > "$MODPATH/.native_abi" 2>/dev/null
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$MODPATH/bin/aiunblock-native" 2>/dev/null | awk '{print $1}' > "$MODPATH/.native_sha256"
fi

rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/armeabi-v7a" "$MODPATH/bin/x86_64" "$MODPATH/bin/x86"
rm -f "$MODPATH/bin/aiunblock-router" "$MODPATH/bin/curl" "$MODPATH/bin/SHA256SUMS" 2>/dev/null

for text_file in \
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

  rm -rf "$OLD_MODPATH/gateways" 2>/dev/null
  rm -rf "$MODPATH/gateways" 2>/dev/null
fi

rm -f "$MODPATH/skip_mount" "$MODPATH/.force_refresh" "$MODPATH/.reload"

AIUNBLOCK_CONFIG_FILE="$MODPATH/install.conf"
. "$MODPATH/lib/config.sh"
config_load "$AIUNBLOCK_CONFIG_FILE"
config_write "$AIUNBLOCK_CONFIG_FILE" || abort "Не удалось записать install.conf"

ui_print "- Конфигурация: locale=$ENABLE_APP_LOCALE, fail=$FAIL_MODE, loc=${BLOCKED_LOC:-off}"

# Убеждаемся, что в модуле нет папки system (hosts подмена полностью удалена)
rm -rf "$MODPATH/system" 2>/dev/null

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

ui_print "- Готово. AI Unblock запустится автоматически после перезагрузки."
ui_print "- Логи: /sdcard/eCubz/AIUnblock/logs"
