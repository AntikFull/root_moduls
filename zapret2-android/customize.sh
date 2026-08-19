#!/system/bin/sh
umask 077

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
  chmod 0755 "$1" 2>/dev/null || chmod 755 "$1" 2>/dev/null || true
}

set_permissions() {
  for f in \
    "$MODPATH/bin/nfqws2" \
    "$MODPATH/bin/ip2net" \
    "$MODPATH/bin/mdig" \
    "$MODPATH/bin/awg" \
    "$MODPATH/bin/amneziawg-go" \
    "$MODPATH/bin/zapret2-control" \
    "$MODPATH/warp-tunnel.sh" \
    "$MODPATH/service.sh" \
    "$MODPATH/boot-completed.sh" \
    "$MODPATH/action.sh" \
    "$MODPATH/uninstall.sh" \
    "$MODPATH/on_change.sh" \
    "$MODPATH/vpn-routing.sh" \
    "$MODPATH/vpn-watch.sh" \
    "$MODPATH/net-role.sh" \
    "$MODPATH/tether-sync.sh" \
    "$MODPATH/app-sync.sh" \
    "$MODPATH/auto-select.sh" \
    "$MODPATH/strategy-lib.sh" \
    "$MODPATH/service-watch.sh" \
    "$MODPATH/network-event.sh" \
    "$MODPATH/log-export.sh" \
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

ACTIVE_MODDIR="/data/adb/modules/zapret2-android"
UPGRADE_BACKUP="/data/local/tmp/zapret2-upgrade.$$"
UPGRADE_FROM=""
if [ -d "$ACTIVE_MODDIR" ] && [ -f "$ACTIVE_MODDIR/module.prop" ]; then
  mkdir -p "$UPGRADE_BACKUP/lists" 2>/dev/null || fail_install "Не удалось создать временный архив резервных копий"
  [ -f "$ACTIVE_MODDIR/zapret2.conf" ] && cp -f "$ACTIVE_MODDIR/zapret2.conf" "$UPGRADE_BACKUP/zapret2.conf" 2>/dev/null
  for keep in apps.list apps.user.list exclude.list warp_apps.list warp_apps.user.list dns.list dns.user.list auto_domains.list exclude_domains.list probe_hosts.list wifi_direct_ssids.list smart_youtube.list; do
    if [ -f "$ACTIVE_MODDIR/lists/$keep" ]; then
      cp -f "$ACTIVE_MODDIR/lists/$keep" "$UPGRADE_BACKUP/lists/$keep" 2>/dev/null
    elif [ -f "$ACTIVE_MODDIR/$keep" ]; then
      cp -f "$ACTIVE_MODDIR/$keep" "$UPGRADE_BACKUP/lists/$keep" 2>/dev/null
    fi
  done
  if [ -d "$ACTIVE_MODDIR/strategies" ]; then
    mkdir -p "$UPGRADE_BACKUP/strategies" 2>/dev/null
    for strategy in "$ACTIVE_MODDIR"/strategies/strategy_*; do
      [ -f "$strategy" ] && [ ! -L "$strategy" ] && cp -f "$strategy" "$UPGRADE_BACKUP/strategies/" 2>/dev/null
    done
  fi
  if [ -d "$ACTIVE_MODDIR/state" ]; then
    mkdir -p "$UPGRADE_BACKUP/state" 2>/dev/null
    [ -f "$ACTIVE_MODDIR/state/warp.conf" ] && cp -f "$ACTIVE_MODDIR/state/warp.conf" "$UPGRADE_BACKUP/state/warp.conf" 2>/dev/null
    for cache in "$ACTIVE_MODDIR"/state/auto-*.env; do
      [ -f "$cache" ] && cp -f "$cache" "$UPGRADE_BACKUP/state/" 2>/dev/null
    done
  fi
  UPGRADE_FROM="$ACTIVE_MODDIR"
  ilog "upgrade_backup=$UPGRADE_BACKUP source=$ACTIVE_MODDIR"
fi

merge_previous_config() {
  old="$1" new="$2" tmp="$2.merge.$$"
  [ -f "$old" ] && [ -f "$new" ] || return 0
  awk '
    NR==FNR {
      if ($0 ~ /^[A-Z][A-Z0-9_]*=/) { key=$0; sub(/=.*/, "", key); old[key]=$0 }
      next
    }
    {
      if ($0 ~ /^[A-Z][A-Z0-9_]*=/) { key=$0; sub(/=.*/, "", key); if (key in old) { print old[key]; next } }
      print
    }
  ' "$old" "$new" > "$tmp" && mv -f "$tmp" "$new"
  rm -f "$tmp" 2>/dev/null
}

restore_upgrade_data() {
  [ -n "$UPGRADE_FROM" ] || return 0
  merge_previous_config "$UPGRADE_BACKUP/zapret2.conf" "$MODPATH/zapret2.conf"
  mkdir -p "$MODPATH/lists" 2>/dev/null

  # 1. Восстанавливаем пользовательские переопределения (*.user.list и сохранённые Wi-Fi SSID)
  for keep in apps.user.list warp_apps.user.list dns.user.list wifi_direct_ssids.list; do
    if [ -f "$UPGRADE_BACKUP/lists/$keep" ]; then
      cp -f "$UPGRADE_BACKUP/lists/$keep" "$MODPATH/lists/$keep" 2>/dev/null
    fi
  done

  # 2. Пользовательские кастомные стратегии
  if [ -d "$UPGRADE_BACKUP/strategies" ]; then
    mkdir -p "$MODPATH/strategies" 2>/dev/null
    for strategy in "$UPGRADE_BACKUP"/strategies/strategy_custom_*; do
      [ -f "$strategy" ] && [ ! -L "$strategy" ] && cp -f "$strategy" "$MODPATH/strategies/" 2>/dev/null
    done
  fi

  # 3. Сохранённое состояние WARP и кэши автоподбора
  if [ -d "$UPGRADE_BACKUP/state" ]; then
    mkdir -p "$MODPATH/state" 2>/dev/null
    [ -f "$UPGRADE_BACKUP/state/warp.conf" ] && cp -f "$UPGRADE_BACKUP/state/warp.conf" "$MODPATH/state/warp.conf" 2>/dev/null
    for cache in "$UPGRADE_BACKUP"/state/auto-*.env; do
      [ -f "$cache" ] && cp -f "$cache" "$MODPATH/state/" 2>/dev/null
    done
  fi
  ilog "upgrade_preserved=config,apps,exclude,warp_apps,warp_conf,auto_domains,exclude_domains,probe_hosts,wifi_direct_ssids,strategies,auto_cache"
}

[ -n "$MODPATH" ] || fail_install "MODPATH не задан окружением"
mkdir -p "$MODPATH" 2>/dev/null || fail_install "Не удалось создать каталог $MODPATH"
if [ -n "$ZIPFILE" ] && [ -f "$ZIPFILE" ]; then
  ui_print "- Распаковка архива..."
  UNZIP_BIN="unzip"
  if ! command -v unzip >/dev/null 2>&1; then
    if command -v busybox >/dev/null 2>&1; then
      UNZIP_BIN="busybox unzip"
    elif [ -f /data/adb/ksu/bin/busybox ]; then
      UNZIP_BIN="/data/adb/ksu/bin/busybox unzip"
    elif [ -f /data/adb/ap/bin/busybox ]; then
      UNZIP_BIN="/data/adb/ap/bin/busybox unzip"
    elif [ -f /data/adb/magisk/busybox ]; then
      UNZIP_BIN="/data/adb/magisk/busybox unzip"
    fi
  fi
  $UNZIP_BIN -o "$ZIPFILE" -d "$MODPATH" >/dev/null 2>>"$TMP_INSTALL_LOG" || unzip -o "$ZIPFILE" -d "$MODPATH" >/dev/null 2>>"$TMP_INSTALL_LOG" || fail_install "Ошибка распаковки ZIP"
else
  [ -f "$MODPATH/module.prop" ] || fail_install "ZIPFILE отсутствует и модуль не распакован"
  ilog "archive=pre-extracted"
fi
rm -rf "$MODPATH/META-INF" "$MODPATH/common" 2>/dev/null
restore_upgrade_data
if [ -n "$UPGRADE_FROM" ] && [ -f "$MODPATH/zapret2.conf" ]; then
  old_strategy=$(sed -n 's/^STRATEGY_MODE=//p' "$MODPATH/zapret2.conf" | head -n1 | tr -d '"')
  case "$old_strategy" in SIMPLE|AUTO|'') sed -i 's/^STRATEGY_MODE=.*/STRATEGY_MODE="SMART"/' "$MODPATH/zapret2.conf" ;; esac
  grep -q '^AUTO_APPS_ENABLED=' "$MODPATH/zapret2.conf" 2>/dev/null || sed -i '/^STRATEGY_MODE=/a AUTO_APPS_ENABLED="1"' "$MODPATH/zapret2.conf"
  if [ -d "$MODPATH/strategies" ] && ! grep -lq '^# MODE=DIRECT' "$MODPATH"/strategies/strategy_* 2>/dev/null; then
    migrate_tmp="$MODPATH/strategies/.migrate.$$"
    mkdir -p "$migrate_tmp" 2>/dev/null
    for strategy in "$MODPATH"/strategies/strategy_*; do
      [ -f "$strategy" ] || continue
      number=$(basename "$strategy" | cut -d_ -f2-)
      case "$number" in ''|*[!0-9]*) continue ;; esac
      cp -f "$strategy" "$migrate_tmp/strategy_$((number + 1))" 2>/dev/null
    done
    rm -f "$MODPATH"/strategies/strategy_* 2>/dev/null
    mv -f "$migrate_tmp"/strategy_* "$MODPATH/strategies/" 2>/dev/null
    rm -rf "$migrate_tmp" 2>/dev/null
    printf '# NAME=DIRECT\n# MODE=DIRECT\n' > "$MODPATH/strategies/strategy_1"
    ilog "upgrade_migration=strategies_shifted direct_candidate=strategy_1"
  fi
  sed -i 's/^AUTO_PROFILE_DEFAULT=.*/AUTO_PROFILE_DEFAULT="strategy_2"/' "$MODPATH/zapret2.conf"
  for newkey in 'AUTO_ALLOW_DIRECT="1"' \
    'AUTO_PROBE_HOSTS_GENERAL="discord.com=200// www.instagram.com=200// x.com=200//"' \
    'AUTO_PROBE_HOSTS_GOOGLE="www.youtube.com=204//generate_204 youtubei.googleapis.com=204//generate_204 i.ytimg.com=204//generate_204 redirector.googlevideo.com=200//report_mapping"'; do
    key=${newkey%%=*}
    grep -q "^$key=" "$MODPATH/zapret2.conf" 2>/dev/null || printf '%s\n' "$newkey" >> "$MODPATH/zapret2.conf"
  done
  sed -i -e 's/^VPN_WATCH_INTERVAL="[0-9]*"/VPN_WATCH_INTERVAL="20"/' \
         -e 's/^VPN_RETRY_INTERVAL="[0-9]*"/VPN_RETRY_INTERVAL="2"/' \
         -e 's/^VPN_ROLE_RECHECK="[0-9]*"/VPN_ROLE_RECHECK="120"/' \
         -e 's/^VPN_VERIFY_INTERVAL="[0-9]*"/VPN_VERIFY_INTERVAL="300"/' \
         -e 's/^HEALTH_WATCH_INTERVAL="[0-9]*"/HEALTH_WATCH_INTERVAL="60"/' "$MODPATH/zapret2.conf"
  rm -f "$MODPATH"/state/auto-*.env 2>/dev/null
  if [ -f "$MODPATH/lists/apps.list" ] && [ -f "$MODPATH/lists/auto_apps.list" ]; then
    awk 'NR==FNR {t=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if(t!="" && t !~ /^#/) auto[t]=1; next} {t=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if(!(t in auto)) print $0}' "$MODPATH/lists/auto_apps.list" "$MODPATH/lists/apps.list" > "$MODPATH/lists/apps.list.smart.$$" && mv -f "$MODPATH/lists/apps.list.smart.$$" "$MODPATH/lists/apps.list"
  fi
  ilog "upgrade_migration=smart old_strategy=${old_strategy:-unset} auto_apps=enabled manual_catalog_duplicates=removed"
fi
mkdir -p "$MODPATH/logs" "$MODPATH/run" "$MODPATH/state" 2>/dev/null || fail_install "Не удалось создать рабочие каталоги logs/run/state"
chmod 0700 "$MODPATH/logs" "$MODPATH/run" "$MODPATH/state" 2>/dev/null || fail_install "Не удалось установить права рабочих каталогов"

ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
[ -n "$ABI" ] || ABI="$ARCH"
case "$ABI" in
  arm64-v8a|arm64|aarch64) ABI_DIR=android-arm64 ;;
  armeabi-v7a|armeabi|arm|armv7l) ABI_DIR=android-arm ;;
  x86_64|x64) ABI_DIR=android-x86_64 ;;
  x86) ABI_DIR=android-x86 ;;
  *) fail_install "Неподдерживаемая архитектура CPU: ${ABI:-unknown}" ;;
esac

ui_print "- Архитектура CPU: ${ABI:-unknown} -> $ABI_DIR"
ilog "selected_abi=$ABI_DIR"
[ -d "$MODPATH/binaries/$ABI_DIR" ] || fail_install "В ZIP нет бинарников для $ABI_DIR"
mkdir -p "$MODPATH/bin" 2>/dev/null || fail_install "Не удалось создать каталог bin"
cp -f "$MODPATH/binaries/$ABI_DIR/"* "$MODPATH/bin/" 2>>"$TMP_INSTALL_LOG" || fail_install "Не удалось скопировать ABI-бинарники"
cp -f "$MODPATH/binaries/"*.lua "$MODPATH/bin/" 2>>"$TMP_INSTALL_LOG" || fail_install "Не удалось скопировать Lua-скрипты zapret2"
rm -rf "$MODPATH/binaries" 2>/dev/null

[ -s "$MODPATH/bin/nfqws2" ] || fail_install "nfqws2 отсутствует после установки"
[ -s "$MODPATH/bin/zapret-lib.lua" ] || fail_install "zapret-lib.lua отсутствует после установки"

for f in \
  "$MODPATH/bin/nfqws2" "$MODPATH/bin/ip2net" "$MODPATH/bin/mdig" "$MODPATH/bin/zapret2-control" \
  "$MODPATH/bin/amneziawg-go" "$MODPATH/bin/awg" "$MODPATH/warp-tunnel.sh" \
  "$MODPATH/service.sh" "$MODPATH/boot-completed.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" "$MODPATH/on_change.sh" \
  "$MODPATH/vpn-routing.sh" "$MODPATH/vpn-watch.sh" "$MODPATH/net-role.sh" "$MODPATH/tether-sync.sh" \
  "$MODPATH/app-sync.sh" "$MODPATH/auto-select.sh" "$MODPATH/strategy-lib.sh" "$MODPATH/service-watch.sh" "$MODPATH/network-event.sh" "$MODPATH/log-export.sh" "$MODPATH/diagnostics.sh" \
  "$MODPATH/webroot/api.sh"
do
  [ -f "$f" ] && { set_exec "$f" || fail_install "Не удалось установить права +x: $f"; }
done
chmod 0755 "$MODPATH/webroot" 2>/dev/null || true

# Очистка устаревших файлов и процессов AI Router при обновлении модуля
rm -f "$MODPATH/bin/ai-router" "$MODPATH/lists/ai_apps.list" "$MODPATH/lists/ai_apps.user.list" "$MODPATH/ai_apps.list" 2>/dev/null
rm -f "$ACTIVE_MODDIR/bin/ai-router" "$ACTIVE_MODDIR/lists/ai_apps.list" "$ACTIVE_MODDIR/lists/ai_apps.user.list" "$ACTIVE_MODDIR/ai_apps.list" 2>/dev/null
rm -f "$ACTIVE_MODDIR/run/ai-router.pid" "$MODPATH/run/ai-router.pid" 2>/dev/null
for proc in /proc/[0-9]*; do
  cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null)
  if printf '%s' "$cmd" | grep -Fq "ai-router"; then
    kill -9 "${proc##*/}" 2>/dev/null || true
  fi
done
iptables -w 2 -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j REDIRECT --to-ports 15359 2>/dev/null || true

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
  ui_print "Нажмите [+] для ДА, [-] для НЕТ (12 сек: $default_text)"
  volume_select "$default_answer"
}

CONF_TARGET="$MODPATH/zapret2.conf"
[ -f "$CONF_TARGET" ] || fail_install "zapret2.conf не найден"

if [ -n "$UPGRADE_FROM" ]; then
  ENABLE_HOTSPOT_VAL=$(sed -n 's/^ENABLE_HOTSPOT=//p' "$CONF_TARGET" | head -n1 | tr -d '"'); [ -n "$ENABLE_HOTSPOT_VAL" ] || ENABLE_HOTSPOT_VAL=1
  ENABLE_VPN_HOTSPOT_VAL=$(sed -n 's/^ENABLE_VPN_HOTSPOT=//p' "$CONF_TARGET" | head -n1 | tr -d '"'); [ -n "$ENABLE_VPN_HOTSPOT_VAL" ] || ENABLE_VPN_HOTSPOT_VAL=0
  FORCE_TCP_HOTSPOT_VAL=$(sed -n 's/^FORCE_TCP_HOTSPOT=//p' "$CONF_TARGET" | head -n1 | tr -d '"'); [ -n "$FORCE_TCP_HOTSPOT_VAL" ] || FORCE_TCP_HOTSPOT_VAL=1
  DNS_FORWARD_HOTSPOT_VAL=$(sed -n 's/^DNS_FORWARD_HOTSPOT=//p' "$CONF_TARGET" | head -n1 | tr -d '"'); [ -n "$DNS_FORWARD_HOTSPOT_VAL" ] || DNS_FORWARD_HOTSPOT_VAL=0
  ilog "upgrade_questions=skipped preserved_user_choices=1"
  ui_print "- Обновление: настройки Hotspot/VPN/QUIC/DNS сохранены"
else
  if ask_yes_no "Включить раздачу Wi-Fi Hotspot и USB-модем?" yes; then
    ENABLE_HOTSPOT_VAL=1
    if ask_yes_no "Включать защиту трафика при работе VPN соединения?" no; then ENABLE_VPN_HOTSPOT_VAL=1; else ENABLE_VPN_HOTSPOT_VAL=0; fi
    if ask_yes_no "Запретить QUIC (UDP/443) при раздаче интернета?" yes; then FORCE_TCP_HOTSPOT_VAL=1; else FORCE_TCP_HOTSPOT_VAL=0; fi
    if ask_yes_no "Принудительно перехватывать DNS при раздаче?" no; then DNS_FORWARD_HOTSPOT_VAL=1; else DNS_FORWARD_HOTSPOT_VAL=0; fi
  else
    ENABLE_HOTSPOT_VAL=0; ENABLE_VPN_HOTSPOT_VAL=0; FORCE_TCP_HOTSPOT_VAL=0; DNS_FORWARD_HOTSPOT_VAL=0
  fi
  sed -i "s|^ENABLE_HOTSPOT=.*|ENABLE_HOTSPOT=\"$ENABLE_HOTSPOT_VAL\"|" "$CONF_TARGET"
  sed -i "s|^ENABLE_VPN_HOTSPOT=.*|ENABLE_VPN_HOTSPOT=\"$ENABLE_VPN_HOTSPOT_VAL\"|" "$CONF_TARGET"
  sed -i 's|^VPN_FALLBACK_MODE=.*|VPN_FALLBACK_MODE="ANTIDPI"|' "$CONF_TARGET"
  sed -i 's|^VPN_HOTSPOT_KILLSWITCH=.*|VPN_HOTSPOT_KILLSWITCH="0"|' "$CONF_TARGET"
  sed -i "s|^FORCE_TCP_HOTSPOT=.*|FORCE_TCP_HOTSPOT=\"$FORCE_TCP_HOTSPOT_VAL\"|" "$CONF_TARGET"
  sed -i "s|^DNS_FORWARD_HOTSPOT=.*|DNS_FORWARD_HOTSPOT=\"$DNS_FORWARD_HOTSPOT_VAL\"|" "$CONF_TARGET"
fi
chmod 0644 "$CONF_TARGET" "$MODPATH/lists"/* "$MODPATH"/strategies/strategy_* 2>/dev/null || true
chmod 0755 "$MODPATH/lists" "$MODPATH/strategies" 2>/dev/null || true

VPN_FALLBACK_LOG=$(sed -n 's/^VPN_FALLBACK_MODE=//p' "$CONF_TARGET" | head -n1 | tr -d '"')
[ -n "$VPN_FALLBACK_LOG" ] || VPN_FALLBACK_LOG=ANTIDPI
ilog "choices hotspot=$ENABLE_HOTSPOT_VAL vpn_hotspot=$ENABLE_VPN_HOTSPOT_VAL vpn_fallback=$VPN_FALLBACK_LOG quic_hotspot=$FORCE_TCP_HOTSPOT_VAL dns_hotspot=$DNS_FORWARD_HOTSPOT_VAL"
rm -rf "$UPGRADE_BACKUP" 2>/dev/null
ilog "installer=success"
flush_install_log

ui_print " "
ui_print "- Установка Zapret2 завершена!"
ui_print "- После перезагрузки модуль запустится автоматически"
ui_print "- Лог установки: /sdcard/eCubz/zapret2_install.log"
ui_print "- Настройка доступна через WebUI"
