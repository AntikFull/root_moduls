#!/system/bin/sh
# Zapret2 eCubz — standalone installer for Magisk / KernelSU / APatch.
# No nested MMT framework and no system overlay are required.

SKIPUNZIP=1

INSTALL_LOG_DIR=/sdcard/eCubz
INSTALL_LOG="$INSTALL_LOG_DIR/zapret2_install.log"
TMP_INSTALL_LOG=/data/local/tmp/zapret2_install.log
mkdir -p /data/local/tmp 2>/dev/null
: > "$TMP_INSTALL_LOG" 2>/dev/null

ilog() {
  line="[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*"
  echo "$line" >> "$TMP_INSTALL_LOG" 2>/dev/null
}

flush_install_log() {
  mkdir -p "$INSTALL_LOG_DIR" 2>/dev/null
  if [ -d "$INSTALL_LOG_DIR" ]; then
    cp -f "$TMP_INSTALL_LOG" "$INSTALL_LOG" 2>/dev/null
    chmod 0644 "$INSTALL_LOG" 2>/dev/null
  fi
}

fail_install() {
  ilog "ERROR: $*"
  flush_install_log
  abort "! $*"
}

set_exec() {
  [ -f "$1" ] || return 0
  chown 0:0 "$1" 2>/dev/null
  chmod 0755 "$1" 2>/dev/null || return 1
}

# Called by module installers that reset permissions after customize.sh.
set_permissions() {
  for f in \
    "$MODPATH/bin/nfqws2" \
    "$MODPATH/bin/ip2net" \
    "$MODPATH/bin/mdig" \
    "$MODPATH/bin/zapret2-control" \
    "$MODPATH/service.sh" \
    "$MODPATH/action.sh" \
    "$MODPATH/uninstall.sh" \
    "$MODPATH/on_change.sh" \
    "$MODPATH/vpn-routing.sh" \
    "$MODPATH/vpn-watch.sh" \
    "$MODPATH/net-role.sh" \
    "$MODPATH/tether-sync.sh" \
    "$MODPATH/network-event.sh" \
    "$MODPATH/diagnostics.sh"
  do
    if type set_perm >/dev/null 2>&1; then
      [ -f "$f" ] && set_perm "$f" 0 0 0755
    else
      set_exec "$f"
    fi
  done
}

manager_name() {
  if [ -n "$KSU" ] || [ -n "$KSU_VER" ] || [ -d /data/adb/ksu ]; then
    echo "KernelSU"
  elif [ -n "$APATCH" ] || [ -d /data/adb/ap ]; then
    echo "APatch"
  elif [ -n "$MAGISK_VER" ] || [ -d /data/adb/magisk ]; then
    echo "Magisk"
  else
    echo "unknown-root-manager"
  fi
}

ui_print "***************************************"
ui_print " Zapret2 eCubz — universal installer"
ui_print " Magisk / KernelSU / APatch"
ui_print "***************************************"

ilog "installer=start manager=$(manager_name)"
ilog "device=$(getprop ro.product.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null) sdk=$(getprop ro.build.version.sdk 2>/dev/null) abi=$(getprop ro.product.cpu.abi 2>/dev/null)"
ilog "modpath=$MODPATH zipfile=$ZIPFILE"

# Extract ourselves so behavior does not depend on manager-specific unzip order.
[ -n "$MODPATH" ] || fail_install "MODPATH не задан установщиком"
mkdir -p "$MODPATH" 2>/dev/null || fail_install "Не удалось создать $MODPATH"
if [ -n "$ZIPFILE" ] && [ -f "$ZIPFILE" ]; then
  ui_print "- Распаковка модуля..."
  unzip -o "$ZIPFILE" -d "$MODPATH" >/dev/null 2>>"$TMP_INSTALL_LOG" || fail_install "Ошибка распаковки ZIP"
else
  # Some managers pre-extract the archive before customize.sh.
  [ -f "$MODPATH/module.prop" ] || fail_install "ZIPFILE недоступен и модуль не распакован"
  ilog "archive=pre-extracted"
fi
rm -rf "$MODPATH/META-INF" "$MODPATH/common" 2>/dev/null

ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
[ -n "$ABI" ] || ABI="$ARCH"
case "$ABI" in
  arm64-v8a|arm64|aarch64) ABI_DIR=android-arm64 ;;
  armeabi-v7a|armeabi|arm|armv7l) ABI_DIR=android-arm ;;
  x86_64|x64) ABI_DIR=android-x86_64 ;;
  x86) ABI_DIR=android-x86 ;;
  *) fail_install "Неподдерживаемая архитектура: ${ABI:-unknown}" ;;
esac

ui_print "- Архитектура: ${ABI:-unknown} -> $ABI_DIR"
ilog "selected_abi=$ABI_DIR"
[ -d "$MODPATH/binaries/$ABI_DIR" ] || fail_install "В ZIP нет бинарников $ABI_DIR"
mkdir -p "$MODPATH/bin" 2>/dev/null || fail_install "Не удалось создать bin"
cp -f "$MODPATH/binaries/$ABI_DIR/"* "$MODPATH/bin/" 2>>"$TMP_INSTALL_LOG" || fail_install "Не удалось установить ABI-бинарники"
cp -f "$MODPATH/binaries/"*.lua "$MODPATH/bin/" 2>>"$TMP_INSTALL_LOG" || fail_install "Не удалось установить Lua-файлы zapret2"
rm -rf "$MODPATH/binaries" 2>/dev/null

[ -s "$MODPATH/bin/nfqws2" ] || fail_install "nfqws2 отсутствует после распаковки"
[ -s "$MODPATH/bin/zapret-lib.lua" ] || fail_install "zapret-lib.lua отсутствует после распаковки"

for f in \
  "$MODPATH/bin/nfqws2" "$MODPATH/bin/ip2net" "$MODPATH/bin/mdig" "$MODPATH/bin/zapret2-control" \
  "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" "$MODPATH/on_change.sh" \
  "$MODPATH/vpn-routing.sh" "$MODPATH/vpn-watch.sh" "$MODPATH/net-role.sh" "$MODPATH/tether-sync.sh" \
  "$MODPATH/network-event.sh" "$MODPATH/diagnostics.sh"
do
  set_exec "$f" || fail_install "Не удалось выставить +x: $f"
done

# Read only key DOWN events. UP/SYN/MSC/touch events are ignored instead of
# being mistaken for a default answer on the next question.
volume_select() {
  default_answer="$1"
  if ! command -v getevent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    ilog "volume_input=unavailable default=$default_answer"
    [ "$default_answer" = yes ]
    return
  fi

  while :; do
    event=$(timeout 12 getevent -qlc 1 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$event" ]; then
      ilog "volume_input=timeout default=$default_answer"
      [ "$default_answer" = yes ]
      return
    fi
    case "$event" in
      *KEY_VOLUMEUP*DOWN*)
        ilog "volume_input=VOLUMEUP"
        return 0
        ;;
      *KEY_VOLUMEDOWN*DOWN*)
        ilog "volume_input=VOLUMEDOWN"
        return 1
        ;;
      *)
        # Ignore KEY_* UP, SYN_REPORT, MSC_SCAN and touchscreen events.
        ;;
    esac
  done
}

ask_yes_no() {
  question="$1"
  default_answer="$2"
  if [ "$default_answer" = yes ]; then default_text="ДА"; else default_text="НЕТ"; fi
  ui_print " "
  ui_print "$question"
  ui_print "Громкость [+] — ДА, [-] — НЕТ (12 сек: $default_text)"
  volume_select "$default_answer"
}

CONF_TARGET="$MODPATH/zapret2.conf"
[ -f "$CONF_TARGET" ] || fail_install "zapret2.conf не найден"

if ask_yes_no "Обрабатывать Wi-Fi Hotspot и USB-модем?" yes; then
  ENABLE_HOTSPOT_VAL=1
  if ask_yes_no "Направлять клиентов раздачи через VPN телефона?" no; then
    ENABLE_VPN_HOTSPOT_VAL=1
  else
    ENABLE_VPN_HOTSPOT_VAL=0
  fi
  if ask_yes_no "Блокировать QUIC (UDP/443) у клиентов раздачи?" yes; then
    FORCE_TCP_HOTSPOT_VAL=1
  else
    FORCE_TCP_HOTSPOT_VAL=0
  fi
  if ask_yes_no "Принудительно перенаправлять DNS клиентов раздачи?" no; then
    DNS_FORWARD_HOTSPOT_VAL=1
  else
    DNS_FORWARD_HOTSPOT_VAL=0
  fi
else
  ENABLE_HOTSPOT_VAL=0
  ENABLE_VPN_HOTSPOT_VAL=0
  FORCE_TCP_HOTSPOT_VAL=0
  DNS_FORWARD_HOTSPOT_VAL=0
fi

sed -i "s/^ENABLE_HOTSPOT=.*/ENABLE_HOTSPOT=\"$ENABLE_HOTSPOT_VAL\"/" "$CONF_TARGET"
sed -i "s/^ENABLE_VPN_HOTSPOT=.*/ENABLE_VPN_HOTSPOT=\"$ENABLE_VPN_HOTSPOT_VAL\"/" "$CONF_TARGET"
sed -i "s/^VPN_FALLBACK_MODE=.*/VPN_FALLBACK_MODE=\"ANTIDPI\"/" "$CONF_TARGET"
sed -i "s/^VPN_HOTSPOT_KILLSWITCH=.*/VPN_HOTSPOT_KILLSWITCH=\"0\"/" "$CONF_TARGET"
sed -i "s/^FORCE_TCP_HOTSPOT=.*/FORCE_TCP_HOTSPOT=\"$FORCE_TCP_HOTSPOT_VAL\"/" "$CONF_TARGET"
sed -i "s/^DNS_FORWARD_HOTSPOT=.*/DNS_FORWARD_HOTSPOT=\"$DNS_FORWARD_HOTSPOT_VAL\"/" "$CONF_TARGET"

ilog "choices hotspot=$ENABLE_HOTSPOT_VAL vpn_hotspot=$ENABLE_VPN_HOTSPOT_VAL vpn_fallback=ANTIDPI quic_hotspot=$FORCE_TCP_HOTSPOT_VAL dns_hotspot=$DNS_FORWARD_HOTSPOT_VAL"
ilog "installer=success"
flush_install_log

ui_print " "
ui_print "- Настройка Zapret2 завершена"
ui_print "- После установки перезагрузите устройство"
ui_print "- Лог установки: /sdcard/eCubz/zapret2_install.log"
ui_print "- Остальные настройки доступны в WebUI"
