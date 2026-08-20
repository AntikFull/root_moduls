SKIPUNZIP=0

DATA_DIR="/data/adb/analytics_ads_disabler"
SETTINGS_FILE="$DATA_DIR/settings.conf"
CAPABILITIES_FILE="$DATA_DIR/capabilities.conf"
IFW_DIR="/data/system/ifw"
[ -f "$MODPATH/compat.sh" ] && . "$MODPATH/compat.sh"

MODULE_PROP="$MODPATH/module.prop"
module_prop_get() {
  _mp_key="$1"
  [ -f "$MODULE_PROP" ] || return 1
  sed -n "s/^${_mp_key}=//p" "$MODULE_PROP" 2>/dev/null | head -n 1
}
MODULE_NAME="$(module_prop_get name)"
MODULE_VERSION="$(module_prop_get version)"
MODULE_VERSION_CODE="$(module_prop_get versionCode)"
[ -n "$MODULE_NAME" ] || MODULE_NAME="Analytics & Ads Disabler"
[ -n "$MODULE_VERSION" ] || MODULE_VERSION="unknown"
[ -n "$MODULE_VERSION_CODE" ] || MODULE_VERSION_CODE="unknown"
MODULE_VERSION_LABEL="$MODULE_NAME $MODULE_VERSION (versionCode=$MODULE_VERSION_CODE)"

ui_print "***********************************************"
ui_print "* $MODULE_NAME"
ui_print "* $MODULE_VERSION (versionCode=$MODULE_VERSION_CODE)"
ui_print "* Author: eCubz (https://t.me/eCubz)         *"
ui_print "***********************************************"

if [ "$KSU" = "true" ]; then
  ROOT_MANAGER="KernelSU"
elif [ "$APATCH" = "true" ] || [ "$KERNELPATCH" = "true" ]; then
  ROOT_MANAGER="APatch"
else
  ROOT_MANAGER="Magisk"
fi
ui_print "- Root manager: $ROOT_MANAGER"
ui_print "- Android API: ${API:-unknown} | ABI: ${ARCH:-unknown}"
if [ "$ROOT_MANAGER" != "Magisk" ]; then
  ui_print "! Zygisk engine requires a compatible Zygisk implementation enabled in $ROOT_MANAGER."
fi

if [ -f "$MODPATH/integrity.manifest" ]; then
  ui_print "- Verifying package integrity against integrity.manifest..."
  _manifest_err=0
  _sha_tool=""
  if command -v sha256sum >/dev/null 2>&1; then
    _sha_tool="sha256sum"
  elif command -v busybox >/dev/null 2>&1 && busybox sha256sum /dev/null >/dev/null 2>&1; then
    _sha_tool="busybox sha256sum"
  elif command -v openssl >/dev/null 2>&1; then
    _sha_tool="openssl dgst -sha256"
  fi

  if [ -z "$_sha_tool" ]; then
    abort "! Integrity verification FAILED: no SHA-256 utility available in environment."
  fi

  while IFS='=' read -r _mf_path _mf_hash || [ -n "$_mf_path" ]; do
    _mf_path="$(printf '%s' "$_mf_path" | tr -d '\r\n[:space:]')"
    _mf_hash="$(printf '%s' "$_mf_hash" | tr -d '\r\n[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$_mf_path" in ''|'#'*) continue ;; esac
    _mf_full="$MODPATH/$_mf_path"
    if [ ! -f "$_mf_full" ]; then
      ui_print "! Integrity error: missing file $_mf_path"
      _manifest_err=$((_manifest_err + 1))
      continue
    fi
    if [ "$_sha_tool" = "openssl dgst -sha256" ]; then
      _real_hash=$(openssl dgst -sha256 "$_mf_full" 2>/dev/null | awk '{print $NF}' | tr -d '\r\n[:space:]' | tr '[:upper:]' '[:lower:]')
    else
      _real_hash=$($_sha_tool "$_mf_full" 2>/dev/null | awk '{print $1}' | tr -d '\r\n[:space:]' | tr '[:upper:]' '[:lower:]')
    fi
    if [ "${#_real_hash}" -ne 64 ] || printf '%s' "$_real_hash" | grep -q '[^0-9a-fA-F]'; then
      ui_print "! Integrity error: could not compute valid SHA-256 for $_mf_path"
      _manifest_err=$((_manifest_err + 1))
      continue
    fi
    if [ "${#_mf_hash}" -ne 64 ] || printf '%s' "$_mf_hash" | grep -q '[^0-9a-fA-F]'; then
      ui_print "! Integrity error: malformed expected SHA-256 for $_mf_path"
      _manifest_err=$((_manifest_err + 1))
      continue
    fi
    if [ -z "$_real_hash" ] || [ "$_real_hash" != "$_mf_hash" ]; then
      ui_print "! Integrity mismatch for $_mf_path"
      _manifest_err=$((_manifest_err + 1))
    fi
  done < "$MODPATH/integrity.manifest"
  if [ "$_manifest_err" -gt 0 ]; then
    abort "! Integrity verification FAILED ($_manifest_err errors). Aborting installation."
  fi
  ui_print "  Package integrity verified successfully."
fi

volume_select() {
  default_answer="$1"
  if ! command -v getevent >/dev/null 2>&1; then
    ui_print "! getevent unavailable; using default selection."
    [ "$default_answer" = "yes" ] && return 0
    return 1
  fi

  tries=0
  while [ "$tries" -lt 40 ]; do
    tries=$((tries + 1))
    if command -v timeout >/dev/null 2>&1; then
      event="$(timeout 30 getevent -qlc 1 2>/dev/null)"
      if [ -z "$event" ]; then
        ui_print "! No volume-key event; using recommended default."
        [ "$default_answer" = "yes" ] && return 0
        return 1
      fi
    else
      event="$(getevent -qlc 1 2>/dev/null)"
      if [ -z "$event" ]; then
        ui_print "! getevent returned nothing; using recommended default."
        [ "$default_answer" = "yes" ] && return 0
        return 1
      fi
    fi
    echo "$event" | grep -q "KEY_VOLUMEUP.*DOWN" && return 0
    echo "$event" | grep -q "KEY_VOLUMEDOWN.*DOWN" && return 1
  done
  ui_print "! No volume-key decision; using recommended default."
  [ "$default_answer" = "yes" ] && return 0
  return 1
}

ask_yes_no() {
  prompt="$1"
  recommended="$2"
  ui_print " "
  ui_print "$prompt"
  ui_print "  VOL+ = YES    VOL- = NO"
  [ -n "$recommended" ] && ui_print "  Recommended: $recommended"
  if volume_select "$( [ "$recommended" = "YES" ] && echo yes || echo no )"; then
    ui_print "  -> YES"
    return 0
  fi
  ui_print "  -> NO"
  return 1
}

ask_system_apps_opt_in() {
  prompt="$1"
  ui_print " "
  ui_print "$prompt"
  ui_print "  VOL+ = NO  (SAFE)    VOL- = YES  (OPT-IN)"
  ui_print "  Recommended: NO"
  if volume_select yes; then
    ui_print "  -> NO (system apps excluded)"
    return 1
  fi
  ui_print "  -> YES (system apps included)"
  return 0
}

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null

# При обновлении сначала полностью останавливаем runtime старой версии. Иначе
# одновременно с PM-пробами установщика. На некоторых HyperOS это перегружает
# Binder Package Manager и приводит к Failed transaction/Broken pipe.
stop_previous_worker() {
  pf="$1"
  marker="$2"
  [ -f "$pf" ] || return 0
  oldpid=$(cat "$pf" 2>/dev/null)
  case "$oldpid" in ''|*[!0-9]*) rm -f "$pf" 2>/dev/null; return 0 ;; esac
  if kill -0 "$oldpid" 2>/dev/null; then
    oldcmd=$(tr '\000' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null)
    case "$oldcmd" in
      *"$marker"*)
        kill "$oldpid" 2>/dev/null
        n=0
        while kill -0 "$oldpid" 2>/dev/null && [ "$n" -lt 20 ]; do
          sleep 0.1 2>/dev/null || sleep 1
          n=$((n + 1))
        done
        kill -9 "$oldpid" 2>/dev/null || true
        ui_print "- Stopped previous runtime worker pid=$oldpid marker=$marker"
        ;;
      *)
        ui_print "! PID-SAFETY: stale/recycled pid=$oldpid does not match $marker; not killed"
        ;;
    esac
  fi
  rm -f "$pf" 2>/dev/null
}
stop_previous_worker "$DATA_DIR/config_watch.pid" "config_watch.sh"
stop_previous_worker "$DATA_DIR/config_inotify.pid" "config_event.sh"
stop_previous_worker "$DATA_DIR/inotify.pid" "on_app_installed.sh"
stop_previous_worker "$DATA_DIR/category_watch.pid" "category_watch.sh"
stop_previous_worker "$DATA_DIR/log_mirror.pid" "log_mirror.sh"
stop_previous_worker "$DATA_DIR/ad_surface_index.pid" "ad_surface_indexer.sh"
stop_previous_worker "$DATA_DIR/rule_updater.pid" "rule_updater.sh"

# Полный boot/action-скан может владеть operation lock до запуска watcher'ов и
# поэтому не иметь отдельного pid-файла. Завершаем только проверенный процесс
# именно этого модуля; чужой или переиспользованный PID никогда не трогаем.
if [ -d "$DATA_DIR/.operation.lock" ]; then
  operation_owner=$(cat "$DATA_DIR/.operation.lock/pid" 2>/dev/null)
  case "$operation_owner" in
    ''|*[!0-9]*) rm -rf "$DATA_DIR/.operation.lock" 2>/dev/null ;;
    *)
      if [ "$operation_owner" != "$$" ] && kill -0 "$operation_owner" 2>/dev/null; then
        operation_cmdline=$(tr '\000' ' ' < "/proc/$operation_owner/cmdline" 2>/dev/null)
        case "$operation_cmdline" in
          *analytics_ads_disabler*)
            kill "$operation_owner" 2>/dev/null
            n=0
            while kill -0 "$operation_owner" 2>/dev/null && [ "$n" -lt 20 ]; do
              sleep 0.1 2>/dev/null || sleep 1
              n=$((n + 1))
            done
            kill -9 "$operation_owner" 2>/dev/null || true
            ui_print "- Stopped previous active scan pid=$operation_owner"
            rm -rf "$DATA_DIR/.operation.lock" 2>/dev/null
            ;;
          *)
            ui_print "! Unrecognized live operation-lock owner pid=$operation_owner"
            abort "! Refusing to update while an unknown live process owns module state. Reboot/disable the old module and retry."
            ;;
        esac
      else
        rm -rf "$DATA_DIR/.operation.lock" 2>/dev/null
      fi
      ;;
  esac
fi
installer_proc_starttime() {
  _ips_pid="$1"
  awk '{print $22}' "/proc/$_ips_pid/stat" 2>/dev/null
}
installer_lock_alive() {
  _ila="$1"; _pid=$(cat "$_ila/pid" 2>/dev/null); _saved=$(cat "$_ila/starttime" 2>/dev/null)
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_pid" 2>/dev/null || return 1
  # Old v6.0.3 app-event locks had PID only. Treat a live PID with no
  # starttime as live/unknown rather than deleting its lock underneath it.
  [ -n "$_saved" ] || return 0
  [ "$(installer_proc_starttime "$_pid")" = "$_saved" ]
}
for _lock in "$DATA_DIR/.state_db.lock" "$DATA_DIR/.membership_db.lock" "$DATA_DIR/.surface_index.lock" "$DATA_DIR/.app_event.lock" "$DATA_DIR/.ad_killer.lock"; do
  [ -d "$_lock" ] || continue
  if installer_lock_alive "$_lock"; then
    ui_print "! Live state lock remains: $_lock; aborting update rather than racing it."
    abort "! Runtime is still writing module state. Reboot or disable the old module, then retry installation."
  fi
  rm -rf "$_lock" 2>/dev/null
 done
rm -f "$DATA_DIR/.surface_index.rerun" 2>/dev/null

# v6.0.6: LSPosed/Xposed companion bridge was retired long ago and is no
# longer part of the runtime architecture.  Remove every state artifact that
# older builds could have exported, including interrupted atomic-write temps.
# This is intentionally idempotent so Magisk / KernelSU / APatch updates can
# run it safely more than once.
cleanup_legacy_xposed_bridge_state() {
  rm -f \
    "$DATA_DIR/xposed_targets.json" \
    "$DATA_DIR/xposed_targets.list" \
    "$DATA_DIR"/xposed_targets.json.tmp.* \
    "$DATA_DIR"/xposed_targets.list.tmp.* \
    "$MODPATH/xposed_targets.json" \
    "$MODPATH/xposed_targets.list" \
    "$MODPATH"/xposed_targets.json.tmp.* \
    "$MODPATH"/xposed_targets.list.tmp.* \
    2>/dev/null || true

  # Drop the retired configuration key as well.  Keep every other user choice
  # byte-for-byte/line-for-line, then atomically replace the settings file.
  if [ -f "$SETTINGS_FILE" ] && grep -q '^[[:space:]]*XPOSED_BRIDGE[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null; then
    _xl_tmp="$DATA_DIR/.settings.no_xposed_bridge.$$"
    if awk '!/^[[:space:]]*XPOSED_BRIDGE[[:space:]]*=/' "$SETTINGS_FILE" > "$_xl_tmp" 2>/dev/null; then
      chmod 600 "$_xl_tmp" 2>/dev/null || true
      if mv -f "$_xl_tmp" "$SETTINGS_FILE" 2>/dev/null; then
        ui_print "- Removed retired XPOSED_BRIDGE setting"
      else
        rm -f "$_xl_tmp" 2>/dev/null
        abort "! Failed to remove retired XPOSED_BRIDGE setting safely"
      fi
    else
      rm -f "$_xl_tmp" 2>/dev/null
      abort "! Failed to migrate settings away from retired XPOSED_BRIDGE"
    fi
  fi
}
cleanup_legacy_xposed_bridge_state
ui_print "- Removed legacy LSPosed/Xposed bridge artifacts"

LOG_DIR="$DATA_DIR/logs"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
INSTALL_DIAG="$LOG_DIR/install_diagnostics.log"
mkdir -p "$LOG_DIR" 2>/dev/null
: > "$INSTALL_DIAG" 2>/dev/null

install_diag() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$*" >> "$INSTALL_DIAG" 2>/dev/null
}

KEEP_EXISTING=0
if [ -f "$SETTINGS_FILE" ]; then
  EXISTING_INCLUDE_SYSTEM_APPS=$(sed -n 's/^[[:space:]]*INCLUDE_SYSTEM_APPS[[:space:]]*=[[:space:]]*\([01]\).*/\1/p' "$SETTINGS_FILE" 2>/dev/null | tail -n 1)
  if [ -z "$EXISTING_INCLUDE_SYSTEM_APPS" ]; then
    EXISTING_INCLUDE_SYSTEM_APPS=$(sed -n 's/^[[:space:]]*SCAN_SYSTEM_APPS[[:space:]]*=[[:space:]]*\([01]\).*/\1/p' "$SETTINGS_FILE" 2>/dev/null | tail -n 1)
  fi
  [ -n "$EXISTING_INCLUDE_SYSTEM_APPS" ] || EXISTING_INCLUDE_SYSTEM_APPS=0
  ui_print " "
  ui_print "- Existing settings detected."
  [ "$EXISTING_INCLUDE_SYSTEM_APPS" = "1" ] && ui_print "  ! Current settings INCLUDE SYSTEM applications."
  ui_print "  Keep current choices?"
  ui_print "  VOL+ = KEEP    VOL- = RECONFIGURE"
  if volume_select yes; then
    KEEP_EXISTING=1
    ui_print "  -> Keeping current settings"
    if ! grep -q '^[[:space:]]*INCLUDE_SYSTEM_APPS[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null; then
      echo "INCLUDE_SYSTEM_APPS=$EXISTING_INCLUDE_SYSTEM_APPS" >> "$SETTINGS_FILE"
    fi
  else
    ui_print "  -> Reconfiguring"
  fi
fi

if [ "$KEEP_EXISTING" -eq 0 ]; then
  BLOCK_ADS=0
  BLOCK_ANALYTICS=0
  INCLUDE_SYSTEM_APPS=0

  ask_yes_no "1. Block ADVERTISING & banners?" "YES" && BLOCK_ADS=1
  ask_yes_no "2. Block ANALYTICS & trackers?" "YES" && BLOCK_ANALYTICS=1
  ask_system_apps_opt_in "3. Process SYSTEM applications too? (advanced)" && INCLUDE_SYSTEM_APPS=1

  cat > "$SETTINGS_FILE" <<CFG
BLOCK_ADS=$BLOCK_ADS
BLOCK_ANALYTICS=$BLOCK_ANALYTICS
INCLUDE_SYSTEM_APPS=$INCLUDE_SYSTEM_APPS
AD_SURFACE_KILLER=1
AD_KILLER_MODE=auto
AD_KILLER_IP_FALLBACK=0
AD_KILLER_MIN_CONFIDENCE=CAPABILITY
AD_KILLER_FORCE_TCP=0
BLOCK_DOH_BYPASS=1
ZERO_AD_ID=0
BLOCK_OVERLAY_ADS=0
BLOCK_WEBVIEW_ADS=0
LOG_MIRROR=0
LOG_MIRROR_FULL=0
LOG_MIRROR_INTERVAL=60
AUTO_UPDATE_RULES=0
AUTO_UPDATE_INTERVAL_DAYS=3
AUTO_UPDATE_WIFI_ONLY=1
REALTIME_MONITOR=1
CATEGORY_POLL_INTERVAL=10
PACKAGE_POLL_INTERVAL=60
PACKAGE_SAFETY_POLL_INTERVAL=900
BOOT_STABILIZATION=1
BOOT_STABILIZATION_MIN_UPTIME_SEC=120
BOOT_STABILIZATION_MAX_WAIT_SEC=300
BOOT_STABILIZATION_SAMPLE_SEC=5
BOOT_STABILIZATION_REQUIRED_SAMPLES=3
BOOT_STABILIZATION_MIN_IDLE_PERCENT=60
BOOT_STABILIZATION_MIN_AVAILABLE_KB=1048576
AD_SURFACE_WORKERS=4
AD_SURFACE_MAX_RUNTIME_SEC=1800
AD_SURFACE_MAX_APKS_PER_PACKAGE=64
AD_SURFACE_RERUN_DELAY_SEC=60
AD_SURFACE_FOUR_WORKER_MIN_AVAILABLE_KB=4194304
AD_SURFACE_THREE_WORKER_MIN_AVAILABLE_KB=2097152
AD_SURFACE_MIN_AVAILABLE_KB=1048576
CFG
  chmod 600 "$SETTINGS_FILE" 2>/dev/null
fi

for kv in 'BLOCK_ADS=0' 'BLOCK_ANALYTICS=0' 'INCLUDE_SYSTEM_APPS=0' 'AD_SURFACE_KILLER=1' 'AD_KILLER_FORCE_TCP=0' 'BLOCK_DOH_BYPASS=1' 'ZERO_AD_ID=0' 'BLOCK_OVERLAY_ADS=0' 'BLOCK_WEBVIEW_ADS=0' 'PACKAGE_POLL_INTERVAL=60' 'PACKAGE_SAFETY_POLL_INTERVAL=900' 'BOOT_STABILIZATION=1' 'BOOT_STABILIZATION_MIN_UPTIME_SEC=120' 'BOOT_STABILIZATION_MAX_WAIT_SEC=300' 'BOOT_STABILIZATION_SAMPLE_SEC=5' 'BOOT_STABILIZATION_REQUIRED_SAMPLES=3' 'BOOT_STABILIZATION_MIN_IDLE_PERCENT=60' 'BOOT_STABILIZATION_MIN_AVAILABLE_KB=1048576' 'AD_SURFACE_WORKERS=4' 'AD_SURFACE_MAX_RUNTIME_SEC=1800' 'AD_SURFACE_MAX_APKS_PER_PACKAGE=64' 'AD_SURFACE_RERUN_DELAY_SEC=60' 'AD_SURFACE_FOUR_WORKER_MIN_AVAILABLE_KB=4194304' 'AD_SURFACE_THREE_WORKER_MIN_AVAILABLE_KB=2097152' 'AD_SURFACE_MIN_AVAILABLE_KB=1048576' 'AD_KILLER_MODE=auto' 'AD_KILLER_IP_FALLBACK=0' 'AD_KILLER_MIN_CONFIDENCE=CAPABILITY' 'LOG_MIRROR=0' 'LOG_MIRROR_FULL=0' 'LOG_MIRROR_INTERVAL=60' 'AUTO_UPDATE_RULES=0' 'AUTO_UPDATE_INTERVAL_DAYS=3' 'AUTO_UPDATE_WIFI_ONLY=1'; do
  key=${kv%%=*}
  if ! grep -q "^[[:space:]]*$key[[:space:]]*=" "$SETTINGS_FILE" 2>/dev/null; then
    echo "$kv" >> "$SETTINGS_FILE"
  fi
done

ui_print " "
ui_print "- Detecting device command capabilities (PM per-user backend)..."
probe_capabilities
if ! cap_profile_valid; then
  abort "! Required Android package-manager capabilities were not detected safely."
fi
load_capabilities
ui_print "- Verifying write backend safely..."
install_diag "profile before safe write probe: disable=$CAP_PM_DISABLE_BACKEND/$CAP_PM_DISABLE_VERB exec=$CAP_PM_DISABLE_EXEC learned=${CAP_PM_LEARNED_DISABLE_BACKEND:-none}/${CAP_PM_LEARNED_DISABLE_EXEC:-direct} verified=${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}"
cap_install_verify_disable_backend
INSTALL_PROBE_RC=$?
load_capabilities
case "$INSTALL_PROBE_RC" in
  0)
    ui_print "  Write backend VERIFIED: $CAP_PM_LEARNED_DISABLE_BACKEND $CAP_PM_LEARNED_DISABLE_VERB exec=$CAP_PM_LEARNED_DISABLE_EXEC"
    ui_print "  Safe target: ${CAP_INSTALL_PROBE_TARGET:-managed disabled component}"
    install_diag "SAFE WRITE PROBE: PASS target=${CAP_INSTALL_PROBE_TARGET:-unknown} learned=$CAP_PM_LEARNED_DISABLE_BACKEND/$CAP_PM_LEARNED_DISABLE_VERB exec=$CAP_PM_LEARNED_DISABLE_EXEC"
    ;;
  2)
    if [ "${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}" = "1" ] && [ "${CAP_PM_LEARNED_DISABLE_BACKEND:-none}" != "none" ]; then
      ui_print "  Verified backend preserved: $CAP_PM_LEARNED_DISABLE_BACKEND exec=$CAP_PM_LEARNED_DISABLE_EXEC"
      ui_print "  No already-disabled probe target found; live re-check deferred."
      install_diag "SAFE WRITE PROBE: SKIPPED no disabled target; preserved verified backend=$CAP_PM_LEARNED_DISABLE_BACKEND exec=$CAP_PM_LEARNED_DISABLE_EXEC"
    else
      ui_print "  Write backend: UNVERIFIED (no safe disabled target)."
      ui_print "  It will be learned on the first real component."
      install_diag "SAFE WRITE PROBE: SKIPPED no already-disabled managed target; runtime learning required"
    fi
    ;;
  *)
    ui_print "! Safe write probe exhausted candidates; runtime cascade will retry on a real target."
    install_diag "SAFE WRITE PROBE: FAILED all safe candidates"
    ;;
esac
install_diag "profile after safe write probe: learned=${CAP_PM_LEARNED_DISABLE_BACKEND:-none}/${CAP_PM_LEARNED_DISABLE_VERB:-disable} exec=${CAP_PM_LEARNED_DISABLE_EXEC:-direct} verified=${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}"
ui_print "  Disable : $CAP_PM_DISABLE_BACKEND package $CAP_PM_DISABLE_VERB (user=$CAP_PM_DISABLE_HAS_USER)"
ui_print "  Enable  : $CAP_PM_ENABLE_BACKEND package $CAP_PM_ENABLE_VERB (user=$CAP_PM_ENABLE_HAS_USER)"
ui_print "  Default : $CAP_PM_DEFAULT_BACKEND package $CAP_PM_DEFAULT_VERB (user=$CAP_PM_DEFAULT_HAS_USER)"
ui_print "  Restore disabled: $CAP_PM_STATE_DISABLED_BACKEND package $CAP_PM_STATE_DISABLED_VERB (exact=$CAP_PM_STATE_DISABLED_EXACT)"
ui_print "  Probe   : runtime missing-component validation"
ui_print "  Users   : $CAP_USER_LIST_BACKEND"
ui_print "  Packages: $CAP_PACKAGE_LIST_BACKEND (user=$CAP_PACKAGE_LIST_HAS_USER, versionCode=$CAP_PACKAGE_LIST_HAS_VERSIONCODE)"
ui_print "  Dump    : $CAP_PACKAGE_DUMP_BACKEND"
ui_print "  Watcher : $CAP_APP_WATCH_BACKEND"
SCAN_ALL_USERS_EFFECTIVE=$(sed -n 's/^[[:space:]]*SCAN_ALL_USERS[[:space:]]*=[[:space:]]*//p' "$SETTINGS_FILE" | head -n1 | tr -d '\r')
[ -n "$SCAN_ALL_USERS_EFFECTIVE" ] || SCAN_ALL_USERS_EFFECTIVE=1
if [ "$SCAN_ALL_USERS_EFFECTIVE" = "1" ] && { [ "$CAP_PM_DISABLE_HAS_USER" != "1" ] || [ "$CAP_PM_ENABLE_HAS_USER" != "1" ] || [ "$CAP_PM_DEFAULT_HAS_USER" != "1" ] || [ "$CAP_PACKAGE_LIST_HAS_USER" != "1" ]; }; then
  ui_print "! This ROM lacks complete --user support; runtime will safely use user 0 only."
fi

# Миграция пользовательского rules.conf из v5 (если rules.user.conf еще не существует)
if [ -f "$DATA_DIR/rules.conf" ] && [ ! -f "$DATA_DIR/rules.user.conf" ]; then
  ui_print "- Migrating custom rules from legacy rules.conf -> rules.user.conf..."
  cp "$DATA_DIR/rules.conf" "$DATA_DIR/rules.legacy.backup.conf" 2>/dev/null || true
  if [ -f "$MODPATH/rules.vendor.conf" ]; then
    _custom_delta="$DATA_DIR/.rules_custom_delta.$$"
    awk '
      FNR==NR {
        line=$0
        if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {vsec=line; gsub(/^[[:space:]]+|[[:space:]]+$/, "", vsec); next}
        norm=line; sub(/^[[:space:]]+/, "", norm); sub(/[[:space:]]+$/, "", norm)
        if (norm != "" && norm !~ /^#/) vendor[vsec SUBSEP norm]=1
        next
      }
      {
        line=$0
        if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {sec=line; gsub(/^[[:space:]]+|[[:space:]]+$/, "", sec); next}
        norm=line; sub(/^[[:space:]]+/, "", norm); sub(/[[:space:]]+$/, "", norm)
        if (norm != "" && norm !~ /^#/ && sec != "" && !vendor[sec SUBSEP norm]) {
          if (sec != outsec) { if (outsec != "") print ""; print sec; outsec=sec }
          print line
        }
      }
    ' "$MODPATH/rules.vendor.conf" "$DATA_DIR/rules.conf" > "$_custom_delta" 2>/dev/null
    if [ -s "$_custom_delta" ]; then
      {
        printf '# ==============================================================================
'
        printf '# Analytics & Ads Disabler User Custom Rules (Best-effort migration from v5)
'
        printf '# Original legacy composite is preserved as rules.legacy.backup.conf
'
        printf '# ==============================================================================

'
        cat "$_custom_delta"
      } > "$DATA_DIR/rules.user.conf" 2>/dev/null
      ui_print "- Migrated $(wc -l < "$_custom_delta" | tr -d ' ') custom rule(s) into rules.user.conf"
    elif [ -f "$MODPATH/rules.user.conf" ]; then
      cp "$MODPATH/rules.user.conf" "$DATA_DIR/rules.user.conf" 2>/dev/null || true
    fi
    rm -f "$_custom_delta" 2>/dev/null
  elif [ -f "$MODPATH/rules.user.conf" ]; then
    cp "$MODPATH/rules.user.conf" "$DATA_DIR/rules.user.conf" 2>/dev/null || true
  fi
fi

for f in rules.vendor.conf rules.user.conf whitelist.list white_ads.list white_analytics.list smart_reward.list qa_targets.list il2cpp_hooks.conf; do
  if [ ! -f "$DATA_DIR/$f" ] && [ -f "$MODPATH/$f" ]; then
    cp "$MODPATH/$f" "$DATA_DIR/$f"
  fi
done

# Всегда обновляем rules.vendor.conf из архива модуля при установке/обновлении
if [ -f "$MODPATH/rules.vendor.conf" ]; then
  cp -f "$MODPATH/rules.vendor.conf" "$DATA_DIR/rules.vendor.conf"
fi

# Собираем композитный rules.conf из rules.vendor.conf и rules.user.conf
_tmp_composite="$DATA_DIR/.rules_composite.tmp.$$"
{
  if [ -f "$DATA_DIR/rules.vendor.conf" ]; then
    cat "$DATA_DIR/rules.vendor.conf"
  elif [ -f "$MODPATH/rules.vendor.conf" ]; then
    cat "$MODPATH/rules.vendor.conf"
  fi
  printf '\n\n# --- USER CUSTOM RULES ---\n'
  if [ -f "$DATA_DIR/rules.user.conf" ]; then
    cat "$DATA_DIR/rules.user.conf"
  elif [ -f "$MODPATH/rules.user.conf" ]; then
    cat "$MODPATH/rules.user.conf"
  fi
} > "$_tmp_composite" 2>/dev/null
chmod 600 "$_tmp_composite" 2>/dev/null || true
if ! mv -f "$_tmp_composite" "$DATA_DIR/rules.conf" 2>/dev/null; then
  rm -f "$_tmp_composite" 2>/dev/null
  abort "! Failed to commit composite rules.conf safely."
fi
sync 2>/dev/null || true

if [ -s "$DATA_DIR/disabled_components.list" ] && ! grep -q '^[0-9][0-9]*|' "$DATA_DIR/disabled_components.list" 2>/dev/null; then
  cp "$DATA_DIR/disabled_components.list" "$DATA_DIR/disabled_components.v3.backup" 2>/dev/null || abort "! Failed to preserve legacy v3 state before migration."
  # Legacy v3 did not persist authoritative original component overrides.
  # Resetting those components to `default` would overwrite any later user/OEM/
  # module change. Preserve the current Android state instead and relinquish the
  # unverifiable legacy ownership; the backup remains for diagnostics/manual review.
  ui_print "- Legacy v3 state found; preserving current component overrides (original ownership was not recorded)."
  : > "$DATA_DIR/disabled_components.list" || abort "! Failed to reset legacy membership database safely."
  rm -f "$DATA_DIR/component_state.list" "$DATA_DIR/package_state.list"
  ui_print "- Legacy v3 ownership relinquished safely (backup kept; no guessed default-state restore)."
fi

for f in settings.conf rules.conf whitelist.list white_ads.list white_analytics.list qa_targets.list il2cpp_hooks.conf; do
  [ -f "$DATA_DIR/$f" ] || continue
  rm -f "$MODPATH/$f" 2>/dev/null
  ln -s "$DATA_DIR/$f" "$MODPATH/$f" 2>/dev/null || cp "$DATA_DIR/$f" "$MODPATH/$f"
done
ui_print "- Config aliases configured in $DATA_DIR"

set_perm "$MODPATH/common.sh" 0 0 0644
set_perm "$MODPATH/compat.sh" 0 0 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/ad_surface_indexer.sh" 0 0 0755
set_perm "$MODPATH/on_app_installed.sh" 0 0 0755
set_perm "$MODPATH/config_watch.sh" 0 0 0755
set_perm "$MODPATH/config_event.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/log_mirror.sh" 0 0 0755
set_perm "$MODPATH/rule_updater.sh" 0 0 0755

if [ -d "$MODPATH/zygisk" ]; then
  set_perm_recursive "$MODPATH/zygisk" 0 0 0755 0755
  [ -f "$MODPATH/zygisk/aad_core.dex" ] && set_perm "$MODPATH/zygisk/aad_core.dex" 0 0 0644
  ui_print "- Zygisk QA IL2CPP Engine: installed (fail-closed allowlist)"
fi

ui_print " "
ui_print "- Installation complete. Compatibility profile saved."
ui_print "- Backend : PM per-user (isolated multi-user)"
ui_print "- Config  : $DATA_DIR"
ui_print "- Logs    : $LOG_DIR (mirror: $SDCARD_LOG_DIR if LOG_MIRROR=1)"
ui_print "- Action  : VOL+ opens runtime settings; VOL-/no key runs full rescan."

