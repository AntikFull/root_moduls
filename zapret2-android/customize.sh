#!/system/bin/sh
umask 077

SKIPUNZIP=1

INSTALL_LOG_DIR=/sdcard/eCubz
INSTALL_LOG="$INSTALL_LOG_DIR/zapret2_install.log"
TMP_INSTALL_LOG=/data/local/tmp/zapret2_install.log
mkdir -p /data/local/tmp 2>/dev/null
: > "$TMP_INSTALL_LOG" 2>/dev/null

# Зомби и умирающие процессы не отдают cmdline: ядро держит блокировку памяти
# задачи, и чтение виснет без таймаута — однажды это подвесило перезапуск целиком.
# /proc/PID/stat читается без этой блокировки, поэтому сначала спрашиваем
# состояние. Полный вариант с потолком по времени — в service.sh.
pid_cmdline() {
  local st
  case "$1" in ''|0|*[!0-9]*) return 1 ;; esac
  st=$(sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)
  case "$st" in ''|Z|X|x) return 1 ;; esac
  tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

ilog() {
  line="[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*"
  echo "$line" >> "$TMP_INSTALL_LOG" 2>/dev/null
}

flush_install_log() {
  mkdir -p "$INSTALL_LOG_DIR" 2>/dev/null
  if [ -d "$INSTALL_LOG_DIR" ]; then
    cp -f "$TMP_INSTALL_LOG" "$INSTALL_LOG" 2>/dev/null
    chmod 0600 "$INSTALL_LOG" 2>/dev/null
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

# Права на исполняемые файлы выставляются единым списком ниже, уже после выбора
# ABI и проверки manifest. Объявленная здесь функция set_permissions() ни разу не
# вызывалась и дублировала тот список — удалена.

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
  for keep in user.list exclude_domains.list ipset.list ipset_exclude.list warp_domains.list warp_bypass_nets.list dns.list dns.user.list probe_hosts.list wifi_direct_ssids.list; do
    if [ -f "$ACTIVE_MODDIR/lists/$keep" ]; then
      cp -f "$ACTIVE_MODDIR/lists/$keep" "$UPGRADE_BACKUP/lists/$keep" 2>/dev/null
    elif [ -f "$ACTIVE_MODDIR/$keep" ]; then
      cp -f "$ACTIVE_MODDIR/$keep" "$UPGRADE_BACKUP/lists/$keep" 2>/dev/null
    fi
  done
  # Пользовательские стратегии — это strategy_100 и выше (см. lists/README в
  # strategies/). Диапазон 1..99 занят встроенными и обновляется вместе с модулем.
  if [ -d "$ACTIVE_MODDIR/strategies" ]; then
    mkdir -p "$UPGRADE_BACKUP/strategies" 2>/dev/null
    for strategy in "$ACTIVE_MODDIR"/strategies/strategy_*; do
      [ -f "$strategy" ] && [ ! -L "$strategy" ] || continue
      snum=$(basename "$strategy" | cut -d_ -f2-)
      case "$snum" in ''|*[!0-9]*) continue ;; esac
      [ "$snum" -ge 100 ] 2>/dev/null || continue
      cp -f "$strategy" "$UPGRADE_BACKUP/strategies/" 2>/dev/null
    done
  fi
  if [ -d "$ACTIVE_MODDIR/state" ]; then
    mkdir -p "$UPGRADE_BACKUP/state" 2>/dev/null
    [ -f "$ACTIVE_MODDIR/state/warp.conf" ] && cp -f "$ACTIVE_MODDIR/state/warp.conf" "$UPGRADE_BACKUP/state/warp.conf" 2>/dev/null
    # Выученные домены — результат работы модуля на реальной сети, терять его нельзя.
    [ -f "$ACTIVE_MODDIR/state/auto.list" ] && cp -f "$ACTIVE_MODDIR/state/auto.list" "$UPGRADE_BACKUP/state/auto.list" 2>/dev/null
    [ -f "$ACTIVE_MODDIR/state/warp_auto_domains.list" ] && cp -f "$ACTIVE_MODDIR/state/warp_auto_domains.list" "$UPGRADE_BACKUP/state/warp_auto_domains.list" 2>/dev/null
    for cache in "$ACTIVE_MODDIR"/state/auto-*.env; do
      [ -f "$cache" ] && cp -f "$cache" "$UPGRADE_BACKUP/state/" 2>/dev/null
    done
  fi
  UPGRADE_FROM="$ACTIVE_MODDIR"
  ilog "upgrade_backup=$UPGRADE_BACKUP source=$ACTIVE_MODDIR"
fi

# ------------------------------------------------------------------------------
# Ключи, значение которых принадлежит пользователю и переносится при обновлении.
#
# ВСЁ ОСТАЛЬНОЕ берётся из нового zapret2.conf. Это принципиально: раньше
# переносились ВСЕ строки вида KEY="...", включая DESYNC_ARGS_SMART_*, поэтому
# при обновлении встроенные профили обхода всегда перетирались старыми, и
# пользователь никогда не получал улучшенные стратегии.
# ------------------------------------------------------------------------------
USER_CONFIG_KEYS="
QUIC_MODE FORCE_TCP PORTS_TCP QNUM
HOSTLIST_MODE HOSTLIST_AUTO_FAIL_THRESHOLD HOSTLIST_AUTO_FAIL_TIME
STRATEGY_MODE DESYNC_ARGS_CUSTOM
AUTO_SELECT_ENABLED AUTO_ALLOW_DIRECT AUTO_PROFILE_DEFAULT
AUTO_CACHE_TTL AUTO_WIFI_CACHE_TTL AUTO_CELL_CACHE_TTL AUTO_PERIODIC_RECHECK
AUTO_PROBE_HOSTS_GENERAL AUTO_PROBE_HOSTS_GOOGLE AUTO_PROBE_MAX_CANDIDATES AUTO_MIN_PROBE_INTERVAL
AUTO_REPLY_PACKETS
ENABLE_HOTSPOT ENABLE_VPN_HOTSPOT VPN_TUN_NAME VPN_FALLBACK_MODE
VPN_HOTSPOT_KILLSWITCH VPN_HOTSPOT_MASQUERADE FORCE_TCP_HOTSPOT TETHER_IFACES
VPN_RETRY_MAX
DNS_FORWARD_HOTSPOT DNS_FORWARD_SERVERS DNS_FORWARD_SERVER
ENABLE_WARP WARP_DEV WARP_ENDPOINT WARP_PORT WARP_JC WARP_JMIN WARP_JMAX
WARP_S1 WARP_S2 WARP_DNS WARP_DNS_FORCE WARP_ADAPTIVE WARP_SIP_FORCE WARP_DOMAIN_ROUTING WARP_DOMAIN_FALLBACK
WARP_HEALTH_MAX_AGE WARP_HEALTH_PROBE_IP WARP_HEALTH_PROBE_TIMEOUT WARP_HEALTH_PROBE_TRIES WARP_STALL_RESTART_SEC
ENABLE_HTTP_API LOG_EXPORT_ON_BOOT LOG_VERBOSE NFQWS_DEBUG
HEALTH_WATCH_INTERVAL HEALTH_ERROR_BACKOFF CONFIG_DRIFT_CHECK
"

merge_previous_config() {
  old="$1" new="$2" tmp="$2.merge.$$"
  [ -f "$old" ] && [ -f "$new" ] || return 0
  awk -v allow="$USER_CONFIG_KEYS" '
    BEGIN { n=split(allow, a, /[ \t\n]+/); for (i=1; i<=n; i++) if (a[i] != "") ok[a[i]]=1 }
    NR==FNR {
      # Принимаем только тот же простой формат присваивания, который пишет
      # zapret2-control. Это не даёт отравленному старому конфигу превратиться
      # в исполняемый shell, когда новый модуль сделает . zapret2.conf
      if ($0 ~ /^[A-Z][A-Z0-9_]*="[^"]*"$/ && index($0,"`")==0 && index($0,"$")==0 && index($0,"\\")==0 && index($0,"\r")==0) {
        key=$0; sub(/=.*/, "", key)
        if (key in ok) prev[key]=$0
      }
      next
    }
    {
      if ($0 ~ /^[A-Z][A-Z0-9_]*=/) { key=$0; sub(/=.*/, "", key); if (key in prev) { print prev[key]; next } }
      print
    }
  ' "$old" "$new" > "$tmp" && mv -f "$tmp" "$new"
  rm -f "$tmp" 2>/dev/null
}

restore_upgrade_data() {
  [ -n "$UPGRADE_FROM" ] || return 0
  merge_previous_config "$UPGRADE_BACKUP/zapret2.conf" "$MODPATH/zapret2.conf"
  mkdir -p "$MODPATH/lists" 2>/dev/null

  # 1. Восстанавливаем все списки, которые пользователь может менять через WebUI/CLI.
  # Bundled defaults остаются обновляемыми только для файлов, которых пользователь не меняет.
  for keep in user.list exclude_domains.list ipset.list ipset_exclude.list warp_domains.list warp_bypass_nets.list dns.list dns.user.list probe_hosts.list wifi_direct_ssids.list; do
    if [ -f "$UPGRADE_BACKUP/lists/$keep" ]; then
      cp -f "$UPGRADE_BACKUP/lists/$keep" "$MODPATH/lists/$keep" 2>/dev/null
    fi
  done

  # 2. Пользовательские стратегии (strategy_100 и выше).
  # Раньше бэкап делался по маске strategy_*, а восстановление — по
  # strategy_custom_*, причём такие имена не проходят strategy_id_valid()
  # (загрузчик требует strategy_<число>). То есть пользовательские стратегии
  # либо терялись, либо восстанавливались в формате, который никто не читает.
  restored_strategies=0
  if [ -d "$UPGRADE_BACKUP/strategies" ]; then
    mkdir -p "$MODPATH/strategies" 2>/dev/null
    for strategy in "$UPGRADE_BACKUP"/strategies/strategy_*; do
      [ -f "$strategy" ] && [ ! -L "$strategy" ] || continue
      cp -f "$strategy" "$MODPATH/strategies/" 2>/dev/null && restored_strategies=$((restored_strategies + 1))
    done
  fi

  # 3. Сохранённое состояние WARP и кэши автоподбора
  restored_caches=0
  if [ -d "$UPGRADE_BACKUP/state" ]; then
    mkdir -p "$MODPATH/state" 2>/dev/null
    [ -f "$UPGRADE_BACKUP/state/warp.conf" ] && cp -f "$UPGRADE_BACKUP/state/warp.conf" "$MODPATH/state/warp.conf" 2>/dev/null
    [ -f "$UPGRADE_BACKUP/state/auto.list" ] && cp -f "$UPGRADE_BACKUP/state/auto.list" "$MODPATH/state/auto.list" 2>/dev/null
    [ -f "$UPGRADE_BACKUP/state/warp_auto_domains.list" ] && cp -f "$UPGRADE_BACKUP/state/warp_auto_domains.list" "$MODPATH/state/warp_auto_domains.list" 2>/dev/null
    for cache in "$UPGRADE_BACKUP"/state/auto-*.env; do
      [ -f "$cache" ] && cp -f "$cache" "$MODPATH/state/" 2>/dev/null && restored_caches=$((restored_caches + 1))
    done
  fi
  ilog "upgrade_preserved=config,lists,warp_conf user_strategies=$restored_strategies auto_caches=$restored_caches"
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

  # AUTO_PROFILE_DEFAULT принудительно ставится на первую НЕ-DIRECT стратегию:
  # до первого удачного probe модуль обязан защищать, а не пропускать трафик.
  sed -i 's/^AUTO_PROFILE_DEFAULT=.*/AUTO_PROFILE_DEFAULT="strategy_2"/' "$MODPATH/zapret2.conf"

  # Кэш автоподбора НЕ стирается: он привязан к ключу сети, в который уже входит
  # подпись каталога стратегий, поэтому после обновления стратегий устаревшие
  # записи не подхватятся сами по себе. Раньше здесь стоял безусловный
  # rm -f state/auto-*.env — он сносил кэш, только что восстановленный из
  # бэкапа, и при этом в лог писалось, что кэш сохранён.

  # QUIC_MODE: SELECTED/GLOBAL остались от отбора по приложениям.
  sed -i -e 's/^QUIC_MODE="SELECTED"/QUIC_MODE="ON"/' \
         -e 's/^QUIC_MODE="GLOBAL"/QUIC_MODE="ON"/' "$MODPATH/zapret2.conf"

  # --- Переход на отбор по доменам и подсетям ---
  # Прежние версии отбирали трафик по приложениям. Домены оттуда не вывести:
  # соответствия «пакет -> хост» нет. Поэтому старые списки приложений просто
  # удаляются, а пользователю сообщается, что проверить.
  for legacy in apps.list apps.user.list auto_apps.list exclude.list                 warp_apps.list warp_apps.user.list auto_domains.list smart_youtube.list; do
    [ -f "$MODPATH/lists/$legacy" ] && rm -f "$MODPATH/lists/$legacy" 2>/dev/null
  done
  # Читаем из ЕЩЁ живого каталога модуля: в бэкап списки приложений больше не
  # попадают, поэтому в $UPGRADE_BACKUP их нет.
  legacy_excl=$(grep -cvE '^[[:space:]]*(#|$)' "$ACTIVE_MODDIR/lists/exclude.list" 2>/dev/null)
  case "$legacy_excl" in ''|*[!0-9]*) legacy_excl=0 ;; esac
  if [ "$legacy_excl" -gt 0 ] 2>/dev/null; then
    ilog "upgrade_migration=apps_dropped excluded_apps=$legacy_excl"
    ui_print " "
    ui_print "- ВНИМАНИЕ: отбор по приложениям убран."
    ui_print "  Обход теперь применяется по доменам и подсетям, как на роутере."
    ui_print "  У вас было исключено приложений: $legacy_excl (банки, госуслуги)."
    ui_print "  Их домены нужно внести в lists/exclude_domains.list,"
    ui_print "  а адреса — в lists/ipset_exclude.list, иначе обход затронет и их."
  fi

  # Тайминги watcher-ов нормализуются: старые значения (2 сек) были рассчитаны на
  # опрос, а текущий watcher блокируется на netlink-событии.
  sed -i -e 's/^VPN_WATCH_INTERVAL="[0-9]*"/VPN_WATCH_INTERVAL="20"/' \
         -e 's/^VPN_RETRY_INTERVAL="[0-9]*"/VPN_RETRY_INTERVAL="2"/' \
         -e 's/^VPN_ROLE_RECHECK="[0-9]*"/VPN_ROLE_RECHECK="120"/' \
         -e 's/^VPN_VERIFY_INTERVAL="[0-9]*"/VPN_VERIFY_INTERVAL="300"/' "$MODPATH/zapret2.conf"
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

# Проверка целостности выбранных native binaries по release manifest.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
    return
  fi
  for bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$bb" ]; then "$bb" sha256sum "$1" 2>/dev/null | awk '{print $1}'; return; fi
  done
  return 1
}
verify_binary_manifest() {
  [ -f "$MODPATH/BINARY_MANIFEST.txt" ] || fail_install "BINARY_MANIFEST.txt отсутствует"
  manifest_rows=$(awk -v sec="[$ABI_DIR]" '
    $0==sec {insec=1; next}
    /^\[/ {if(insec) exit}
    insec && length($1)==64 && $1 ~ /^[0-9a-fA-F]+$/ && NF>=2 {print $1 " " $2}
  ' "$MODPATH/BINARY_MANIFEST.txt")
  [ -n "$manifest_rows" ] || fail_install "В manifest нет секции $ABI_DIR"
  count=0
  while read -r expected name; do
    [ -n "$name" ] || continue
    [ -f "$MODPATH/bin/$name" ] || fail_install "После выбора ABI отсутствует $name"
    actual=$(sha256_file "$MODPATH/bin/$name") || fail_install "SHA-256 недоступен для проверки $name"
    [ "$actual" = "$expected" ] || fail_install "Checksum mismatch: $name ($ABI_DIR)"
    count=$((count + 1))
  done <<EOMANIFEST
$manifest_rows
EOMANIFEST
  [ "$count" -ge 5 ] || fail_install "Manifest verification incomplete: $count binaries"
  ilog "binary_manifest_verified=$ABI_DIR count=$count"
}
verify_binary_manifest
rm -rf "$MODPATH/binaries" 2>/dev/null

[ -s "$MODPATH/bin/nfqws2" ] || fail_install "nfqws2 отсутствует после установки"
[ -s "$MODPATH/bin/zapret-lib.lua" ] || fail_install "zapret-lib.lua отсутствует после установки"

for f in \
  "$MODPATH/bin/nfqws2" "$MODPATH/bin/ip2net" "$MODPATH/bin/mdig" "$MODPATH/bin/zapret2-control" \
  "$MODPATH/bin/amneziawg-go" "$MODPATH/bin/awg" "$MODPATH/warp-tunnel.sh" \
  "$MODPATH/service.sh" "$MODPATH/boot-completed.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" "$MODPATH/on_change.sh" \
  "$MODPATH/vpn-routing.sh" "$MODPATH/vpn-watch.sh" "$MODPATH/net-role.sh" "$MODPATH/tether-sync.sh" \
  "$MODPATH/auto-select.sh" "$MODPATH/strategy-lib.sh" "$MODPATH/service-watch.sh" "$MODPATH/network-event.sh" "$MODPATH/log-export.sh" "$MODPATH/diagnostics.sh" \
  "$MODPATH/webroot/api.sh"
do
  [ -f "$f" ] && { set_exec "$f" || fail_install "Не удалось установить права +x: $f"; }
done
chmod 0755 "$MODPATH/webroot" 2>/dev/null || true

# Очистка устаревшего AI Router — только доказанно принадлежащий старому модулю PID.
legacy_ai_pid=$(cat "$ACTIVE_MODDIR/run/ai-router.pid" 2>/dev/null)
case "$legacy_ai_pid" in
  ''|0|*[!0-9]*) ;;
  *)
    if kill -0 "$legacy_ai_pid" 2>/dev/null; then
      legacy_cmd=$(pid_cmdline "$legacy_ai_pid")
      legacy_exe=$(readlink "/proc/$legacy_ai_pid/exe" 2>/dev/null)
      if printf '%s' "$legacy_cmd $legacy_exe" | grep -Fq "$ACTIVE_MODDIR/bin/ai-router"; then
        kill -TERM "$legacy_ai_pid" 2>/dev/null || true
      fi
    fi
    ;;
esac
rm -f "$MODPATH/bin/ai-router" "$MODPATH/lists/ai_apps.list" "$MODPATH/lists/ai_apps.user.list" "$MODPATH/ai_apps.list" 2>/dev/null
rm -f "$ACTIVE_MODDIR/bin/ai-router" "$ACTIVE_MODDIR/lists/ai_apps.list" "$ACTIVE_MODDIR/lists/ai_apps.user.list" "$ACTIVE_MODDIR/ai_apps.list" 2>/dev/null
rm -f "$ACTIVE_MODDIR/run/ai-router.pid" "$MODPATH/run/ai-router.pid" 2>/dev/null
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

# Установка через WebUI менеджера root не даёт нажимать кнопки громкости: там
# getevent молчит, и каждый вопрос просто выжидает свои 12 секунд. Четыре вопроса
# превращались в 48 секунд «зависшей» установки без обратной связи. Спрашиваем
# только про раздачу — остальное настраивается в WebUI за пару секунд.

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
  if ask_yes_no "Включить обход DPI и для раздачи (Wi-Fi Hotspot / USB-модем)?" yes; then
    # Разумные значения по умолчанию; всё меняется в WebUI -> «Раздача интернета».
    ENABLE_HOTSPOT_VAL=1; ENABLE_VPN_HOTSPOT_VAL=0; FORCE_TCP_HOTSPOT_VAL=1; DNS_FORWARD_HOTSPOT_VAL=0
    ui_print "- Раздача: включена (QUIC блокируется, перехват DNS выключен)"
    ui_print "  Тонкая настройка — в WebUI, раздел «Раздача интернета»"
  else
    ENABLE_HOTSPOT_VAL=0; ENABLE_VPN_HOTSPOT_VAL=0; FORCE_TCP_HOTSPOT_VAL=0; DNS_FORWARD_HOTSPOT_VAL=0
    ui_print "- Раздача: выключена"
  fi
  sed -i "s|^ENABLE_HOTSPOT=.*|ENABLE_HOTSPOT=\"$ENABLE_HOTSPOT_VAL\"|" "$CONF_TARGET"
  sed -i "s|^ENABLE_VPN_HOTSPOT=.*|ENABLE_VPN_HOTSPOT=\"$ENABLE_VPN_HOTSPOT_VAL\"|" "$CONF_TARGET"
  sed -i 's|^VPN_FALLBACK_MODE=.*|VPN_FALLBACK_MODE="ANTIDPI"|' "$CONF_TARGET"
  sed -i 's|^VPN_HOTSPOT_KILLSWITCH=.*|VPN_HOTSPOT_KILLSWITCH="0"|' "$CONF_TARGET"
  sed -i "s|^FORCE_TCP_HOTSPOT=.*|FORCE_TCP_HOTSPOT=\"$FORCE_TCP_HOTSPOT_VAL\"|" "$CONF_TARGET"
  sed -i "s|^DNS_FORWARD_HOTSPOT=.*|DNS_FORWARD_HOTSPOT=\"$DNS_FORWARD_HOTSPOT_VAL\"|" "$CONF_TARGET"
fi
chmod 0644 "$CONF_TARGET" "$MODPATH/lists"/* "$MODPATH"/strategies/* 2>/dev/null || true
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
