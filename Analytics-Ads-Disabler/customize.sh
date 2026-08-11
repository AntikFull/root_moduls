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

# Returns 0 for Vol+, 1 for Vol-. If getevent is unavailable, returns the supplied default.
volume_select() {
  default_answer="$1"
  if ! command -v getevent >/dev/null 2>&1; then
    ui_print "! getevent unavailable; using default selection."
    [ "$default_answer" = "yes" ] && return 0
    return 1
  fi

  while true; do
    if command -v timeout >/dev/null 2>&1; then
      event="$(timeout 30 getevent -qlc 1 2>/dev/null)"
      if [ -z "$event" ]; then
        ui_print "! No volume-key event; using recommended default."
        [ "$default_answer" = "yes" ] && return 0
        return 1
      fi
    else
      event="$(getevent -qlc 1 2>/dev/null)"
    fi
    echo "$event" | grep -q "KEY_VOLUMEUP.*DOWN" && return 0
    echo "$event" | grep -q "KEY_VOLUMEDOWN.*DOWN" && return 1
  done
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

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null

# При обновлении сначала полностью останавливаем runtime старой версии. Иначе
# config watcher может начать полный пересчёт на частично обновлённых настройках
# одновременно с PM-пробами установщика. На некоторых HyperOS это перегружает
# Binder Package Manager и приводит к Failed transaction/Broken pipe.
stop_previous_worker() {
  pf="$1"
  [ -f "$pf" ] || return 0
  oldpid=$(cat "$pf" 2>/dev/null)
  case "$oldpid" in ''|*[!0-9]*) rm -f "$pf" 2>/dev/null; return 0 ;; esac
  if kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid" 2>/dev/null
    n=0
    while kill -0 "$oldpid" 2>/dev/null && [ "$n" -lt 20 ]; do
      sleep 0.1 2>/dev/null || sleep 1
      n=$((n + 1))
    done
    kill -9 "$oldpid" 2>/dev/null || true
    ui_print "- Stopped previous runtime worker pid=$oldpid"
  fi
  rm -f "$pf" 2>/dev/null
}
for pf in "$DATA_DIR/config_watch.pid" "$DATA_DIR/config_inotify.pid" "$DATA_DIR/inotify.pid" "$DATA_DIR/category_watch.pid" "$DATA_DIR/log_mirror.pid"; do
  stop_previous_worker "$pf"
done

# Полный boot/action-скан может владеть operation lock до запуска watcher'ов и
# поэтому не иметь отдельного pid-файла. Завершаем только проверенный процесс
# именно этого модуля; чужой или переиспользованный PID никогда не трогаем.
operation_owner=$(cat "$DATA_DIR/.operation.lock/pid" 2>/dev/null)
case "$operation_owner" in
  ''|*[!0-9]*) ;;
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
          ;;
        *)
          ui_print "! Preserving unrecognized operation-lock owner pid=$operation_owner"
          ;;
      esac
    fi
    ;;
esac
rm -rf "$DATA_DIR/.operation.lock" "$DATA_DIR/.state_db.lock" "$DATA_DIR/.membership_db.lock" 2>/dev/null

# Installation-time diagnostics. This is intentionally lightweight and mostly
# read-only; the only optional write probe re-applies DISABLED to a component
# that is already verified disabled by this module.
LOG_DIR="$DATA_DIR/logs"
SDCARD_LOG_DIR="/sdcard/eCubz/logs/Analytics_Ads_Disabler"
INSTALL_DIAG="$LOG_DIR/install_diagnostics.log"
SDCARD_INSTALL_DIAG="$SDCARD_LOG_DIR/install_diagnostics.log"
mkdir -p "$LOG_DIR" "$SDCARD_LOG_DIR" 2>/dev/null
# Migrate pre-v4.4.9 logs into the unified layout without overwriting newer logs.
for pair in \
  "$DATA_DIR/analytics_ads_disabler_debug.log:$LOG_DIR/debug.legacy.log" \
  "/sdcard/eCubz/analytics_ads_disabler_debug.log:$LOG_DIR/debug.sdcard_legacy.log" \
  "/sdcard/eCubz/analytics_ads_disabler_diagnostics.log:$LOG_DIR/diagnostics.legacy.log" \
  "/sdcard/eCubz/analytics_ads_disabler_install_diagnostics.log:$LOG_DIR/install_diagnostics.legacy.log"; do
  src=${pair%%:*}; dst=${pair#*:}
  if [ -s "$src" ] && [ ! -e "$dst" ]; then
    cp "$src" "$dst" 2>/dev/null || true
  fi
done
: > "$INSTALL_DIAG" 2>/dev/null
: > "$SDCARD_INSTALL_DIAG" 2>/dev/null
install_diag() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$INSTALL_DIAG"
  if [ -d "$SDCARD_LOG_DIR" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$SDCARD_INSTALL_DIAG" 2>/dev/null || true
  fi
}
# compat.sh uses log_cmd_exec when available; during installation redirect those
# candidate attempts into the dedicated install diagnostic file.
log_cmd_exec() {
  _c="$1"; _o="$2"; _r="$3"
  install_diag "EXEC CMD: $_c"
  install_diag "  |_ EXIT CODE: $_r"
  if [ -n "$_o" ]; then
    printf '%s\n' "$_o" | while IFS= read -r _l; do [ -n "$_l" ] && install_diag "  |_ OUT: $_l"; done
  fi
}
install_diag "$MODULE_VERSION_LABEL installation diagnostics"
install_diag "NOTE: state-changing validation is idempotent only: an already-disabled managed component may be set to disabled again."
install_diag "identity: $(id 2>/dev/null)"
install_diag "context: $(cat /proc/self/attr/current 2>/dev/null | tr -d '\000')"
install_diag "SELinux: $(getenforce 2>/dev/null)"
install_diag "Android: $(getprop ro.build.version.release 2>/dev/null) API=$(getprop ro.build.version.sdk 2>/dev/null)"
install_diag "fingerprint: $(getprop ro.build.fingerprint 2>/dev/null)"
install_diag "root: KSU=$KSU KSU_VER=$KSU_VER KSU_VER_CODE=$KSU_VER_CODE APATCH=$APATCH MAGISK_VER=$MAGISK_VER"
for _x in cmd pm su runcon service dumpsys; do install_diag "tool $_x: $(command -v $_x 2>/dev/null || echo missing)"; done
install_diag "service package: $(service check package 2>&1 | tr '\n' ' ')"
install_diag "package help verbs: $(cmd package help 2>/dev/null | grep -E '^[[:space:]]+(disable|disable-user|disable-until-used|default-state)([[:space:]]|\[)' | tr '\n' ';')"
install_diag "runcon shell domain available: $(cap_runcon_shell_available && echo yes || echo no)"
install_diag "PM mutation model: API=$(cap_api_level 2>/dev/null) shell_uid_component_mutation=$(cap_shell_uid_component_mutation_allowed && echo legacy_candidate || echo disabled_android16_plus) runcon_uid0=$(cap_runcon_shell_available && echo available || echo unavailable) scope=pm_command_via_shell_no_data_io fd_sanitizer=module_data_only"

KEEP_EXISTING=0
if [ -f "$SETTINGS_FILE" ]; then
  ui_print " "
  ui_print "- Existing v4 settings detected."
  ui_print "  Keep current choices?"
  ui_print "  VOL+ = KEEP    VOL- = RECONFIGURE"
  if volume_select yes; then
    KEEP_EXISTING=1
    ui_print "  -> Keeping current settings"
  else
    ui_print "  -> Reconfiguring"
  fi
fi

if [ "$KEEP_EXISTING" -eq 0 ]; then
  BLOCK_ANALYTICS=0
  BLOCK_ADS=0
  COMPONENT_MODE=SAFE
  COMPONENT_BACKEND=PM
  SCAN_ALL_USERS=0
  SCAN_SYSTEM_APPS=0

  ask_yes_no "Disable ANALYTICS / tracking components?" "YES" && BLOCK_ANALYTICS=1
  ask_yes_no "Disable ADVERTISING components?" "YES" && BLOCK_ADS=1
  ask_yes_no "Use BALANCED mode for exact Provider rules?" "NO" && COMPONENT_MODE=BALANCED
  ask_yes_no "Use HYBRID IFW+PM blocking?" "NO" && COMPONENT_BACKEND=HYBRID
  ask_yes_no "Scan ALL Android users/profiles?" "YES" && SCAN_ALL_USERS=1
  ask_yes_no "Scan SYSTEM apps too?" "NO" && SCAN_SYSTEM_APPS=1

  cat > "$SETTINGS_FILE" <<CFG
# Analytics & Ads Disabler v4 — runtime settings
# Generated by installer. You can edit this file later as root.
BLOCK_ANALYTICS=$BLOCK_ANALYTICS
BLOCK_ADS=$BLOCK_ADS
COMPONENT_MODE=$COMPONENT_MODE
COMPONENT_BACKEND=$COMPONENT_BACKEND
SCAN_ALL_USERS=$SCAN_ALL_USERS
SCAN_SYSTEM_APPS=$SCAN_SYSTEM_APPS
REALTIME_MONITOR=1
CATEGORY_POLL_INTERVAL=10
PACKAGE_POLL_INTERVAL=60
PACKAGE_SAFETY_POLL_INTERVAL=900
MAX_MATCHES_PER_CATEGORY=15
MAX_IFW_ACTIVITIES_PER_CATEGORY=5
CFG
  chmod 600 "$SETTINGS_FILE" 2>/dev/null
fi

# Add new runtime defaults on upgrades without overwriting existing user choices.
for kv in 'COMPONENT_MODE=SAFE' 'COMPONENT_BACKEND=PM' 'MAX_IFW_ACTIVITIES_PER_CATEGORY=5' 'PACKAGE_POLL_INTERVAL=60' 'PACKAGE_SAFETY_POLL_INTERVAL=900'; do
  key=${kv%%=*}
  if ! grep -q "^[[:space:]]*$key[[:space:]]*=" "$SETTINGS_FILE" 2>/dev/null; then
    echo "$kv" >> "$SETTINGS_FILE"
  fi
done

# Probe this ROM once and persist the selected command/profile.
ui_print " "
ui_print "- Detecting device command capabilities..."
probe_capabilities
if ! cap_profile_valid; then
  abort "! Required Android package-manager capabilities were not detected safely."
fi

INSTALL_COMPONENT_BACKEND=$(sed -n 's/^[[:space:]]*COMPONENT_BACKEND[[:space:]]*=[[:space:]]*//p' "$SETTINGS_FILE" | head -n1 | tr '[:lower:]' '[:upper:]')
[ -n "$INSTALL_COMPONENT_BACKEND" ] || INSTALL_COMPONENT_BACKEND=PM
if [ "$INSTALL_COMPONENT_BACKEND" = "HYBRID" ]; then
  ifw_probe="$IFW_DIR/.analytics_ads_disabler.probe.$$"
  if [ -d "$IFW_DIR" ] && (umask 022; printf '<rules/>\n' > "$ifw_probe") 2>/dev/null && chmod 0644 "$ifw_probe" 2>/dev/null && rm -f "$ifw_probe" 2>/dev/null; then
    ui_print "- IFW storage probe: writable ($IFW_DIR)"
  else
    rm -f "$ifw_probe" 2>/dev/null
    ui_print "! IFW storage is unavailable; falling back to PM."
    settings_tmp="$SETTINGS_FILE.tmp.$$"
    sed 's/^[[:space:]]*COMPONENT_BACKEND[[:space:]]*=.*/COMPONENT_BACKEND=PM/' "$SETTINGS_FILE" > "$settings_tmp" \
      && mv -f "$settings_tmp" "$SETTINGS_FILE"
    rm -f "$settings_tmp" 2>/dev/null
  fi
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

# Preserve user configuration across module updates. Defaults are copied only on first install.
for f in rules.conf whitelist.list white_ads.list white_analytics.list; do
  if [ ! -f "$DATA_DIR/$f" ] && [ -f "$MODPATH/$f" ]; then
    cp "$MODPATH/$f" "$DATA_DIR/$f"
  fi
done

# При обновлении сохраняем пользовательские правила и добавляем только новые секции v4.5.
for section in ADS_PROVIDER_SAFE ADS_PROVIDER_AUDIT ADS_ACTIVITY_IFW ADS_ACTIVITY_AUDIT ANALYTICS_PROVIDER_SAFE ANALYTICS_PROVIDER_AUDIT ANALYTICS_ACTIVITY_IFW ANALYTICS_ACTIVITY_AUDIT; do
  if ! grep -Fxq "[$section]" "$DATA_DIR/rules.conf" 2>/dev/null; then
    printf '\n' >> "$DATA_DIR/rules.conf"
    awk -v target="[$section]" '
      $0==target {copy=1}
      copy && $0 ~ /^\[/ && $0!=target {exit}
      copy {print}
    ' "$MODPATH/rules.conf" >> "$DATA_DIR/rules.conf"
    ui_print "- Added rules section: [$section]"
  fi
done

# Точечная миграция v4.6.1: исправляем только прежнее стандартное правило,
# не заменяя остальные пользовательские строки секции.
rules_migrate_tmp="$DATA_DIR/rules.conf.migrate.$$"
awk -v target='[ADS_ACTIVITY_AUDIT]' '
  $0==target {inside=1; print; next}
  inside && $0 ~ /^\[/ {inside=0}
  inside && $0=="adactivity" {print "re:(^|[.$/])adactivity$"; next}
  {print}
' "$DATA_DIR/rules.conf" > "$rules_migrate_tmp" 2>/dev/null \
  && mv -f "$rules_migrate_tmp" "$DATA_DIR/rules.conf"
rm -f "$rules_migrate_tmp" 2>/dev/null

ensure_rule_in_section() {
  section="$1"
  wanted="$2"
  awk -v target="[$section]" -v wanted="$wanted" '
    $0==target {inside=1; next}
    inside && $0 ~ /^\[/ {inside=0}
    inside && $0==wanted {found=1}
    END {exit found ? 0 : 1}
  ' "$DATA_DIR/rules.conf" 2>/dev/null && return 0

  insert_tmp="$DATA_DIR/rules.conf.insert.$$"
  awk -v target="[$section]" -v wanted="$wanted" '
    $0==target {inside=1}
    inside && $0 ~ /^\[/ && $0!=target && !added {print wanted; added=1; inside=0}
    {print}
    END {if (inside && !added) print wanted}
  ' "$DATA_DIR/rules.conf" > "$insert_tmp" 2>/dev/null \
    && mv -f "$insert_tmp" "$DATA_DIR/rules.conf"
  rm -f "$insert_tmp" 2>/dev/null
}

ensure_rule_in_section ADS_ACTIVITY_IFW 'com.huawei.openalliance.ad.ppskit.activity.InterstitialAdActivity'

# Migrate the old state format safely: old v3 state did not preserve user IDs/original states,
# so it must not be trusted for exact rollback in v4. Keep a backup for diagnostics.
if [ -s "$DATA_DIR/disabled_components.list" ] && ! grep -q '^[0-9][0-9]*|' "$DATA_DIR/disabled_components.list" 2>/dev/null; then
  cp "$DATA_DIR/disabled_components.list" "$DATA_DIR/disabled_components.v3.backup" 2>/dev/null
  ui_print "- Legacy v3 state found; resetting its user-0 overrides before migration..."
  while IFS='|' read -r oldcomp oldcat; do
    [ -z "$oldcomp" ] && continue
    cap_set_component_state 0 "$oldcomp" default >/dev/null 2>&1
  done < "$DATA_DIR/disabled_components.list"
  : > "$DATA_DIR/disabled_components.list"
  rm -f "$DATA_DIR/component_state.list" "$DATA_DIR/package_state.list"
  ui_print "- Migrated legacy v3 state (backup kept in data directory)."
fi


# Expose the persistent runtime configuration through the module directory too.
# This removes the ambiguous duplicate-copy UX: editing either visible path edits
# the same underlying file watched by config_event/config_watch.
for f in settings.conf rules.conf whitelist.list white_ads.list white_analytics.list; do
  [ -f "$DATA_DIR/$f" ] || continue
  rm -f "$MODPATH/$f" 2>/dev/null
  ln -s "$DATA_DIR/$f" "$MODPATH/$f" 2>/dev/null || cp "$DATA_DIR/$f" "$MODPATH/$f"
done
ui_print "- Config aliases: $MODPATH/{settings.conf,rules.conf,whitelist.list,white_ads.list,white_analytics.list} -> $DATA_DIR"

set_perm "$MODPATH/common.sh" 0 0 0644
set_perm "$MODPATH/compat.sh" 0 0 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/on_app_installed.sh" 0 0 0755
set_perm "$MODPATH/config_watch.sh" 0 0 0755
set_perm "$MODPATH/config_event.sh" 0 0 0755
set_perm "$MODPATH/category_watch.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/log_mirror.sh" 0 0 0755

ui_print " "
ui_print "- Installation complete. Compatibility profile saved."
ui_print "- Install diagnostics: $INSTALL_DIAG (mirrored: $SDCARD_INSTALL_DIAG)"
ui_print "- Component mode: $(sed -n 's/^COMPONENT_MODE=//p' "$SETTINGS_FILE" | head -n1)"
ui_print "- Component backend: $(sed -n 's/^COMPONENT_BACKEND=//p' "$SETTINGS_FILE" | head -n1)"
ui_print "- SAFE: Services/Receivers; BALANCED: exact Provider rules; Activities: audit only."
ui_print "- Original component state is preserved per Android user."
ui_print "- Config survives module updates: $DATA_DIR"
ui_print "- Live log mirror: $SDCARD_LOG_DIR (best-effort, ~10s)"
ui_print "- Use the module Action button for a manual full rescan."
