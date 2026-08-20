#!/system/bin/sh

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:${PATH:-/system/bin}"

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null

AAD_APPLET_DIR="$DATA_DIR/bin"

aad_resolve_busybox() {
    for _abb in "${AAD_BUSYBOX:-}" \
                "$(command -v busybox 2>/dev/null)" \
                /data/adb/magisk/busybox \
                /data/adb/ksu/bin/busybox \
                /data/adb/ap/bin/busybox \
                /data/adb/modules/busybox-ndk/system/bin/busybox \
                /system/bin/busybox \
                /system/xbin/busybox; do
        [ -n "$_abb" ] && [ -x "$_abb" ] && { printf '%s\n' "$_abb"; return 0; }
    done
    return 1
}

aad_setup_applet_path() {
    case ":$PATH:" in *":$AAD_APPLET_DIR:"*) return 0 ;; esac
    [ -n "$AAD_BUSYBOX" ] || return 1
    if [ ! -x "$AAD_APPLET_DIR/awk" ]; then
        mkdir -p "$AAD_APPLET_DIR" 2>/dev/null || return 1
        if ! "$AAD_BUSYBOX" --install -s "$AAD_APPLET_DIR" >/dev/null 2>&1; then
            for _aap in awk sed grep egrep fgrep sort uniq tr od strings unzip stat \
                        find cksum head tail cat cut wc timeout inotifyd sleep \
                        readlink dirname basename mktemp xargs date id; do
                [ -e "$AAD_APPLET_DIR/$_aap" ] || ln -s "$AAD_BUSYBOX" "$AAD_APPLET_DIR/$_aap" 2>/dev/null || true
            done
        fi
        chmod 700 "$AAD_APPLET_DIR" 2>/dev/null || true
    fi
    [ -x "$AAD_APPLET_DIR/awk" ] || return 1
    PATH="$AAD_APPLET_DIR:$PATH"
    export PATH
    return 0
}

AAD_BUSYBOX="$(aad_resolve_busybox 2>/dev/null)"
export AAD_BUSYBOX
aad_setup_applet_path >/dev/null 2>&1 || true

aad_bb() {
    if [ -n "$AAD_BUSYBOX" ]; then
        "$AAD_BUSYBOX" "$@"
        return $?
    fi
    command -v busybox >/dev/null 2>&1 || return 127
    busybox "$@"
}

aad_have_bb() {
    [ -n "$AAD_BUSYBOX" ] || command -v busybox >/dev/null 2>&1
}
if [ -z "${LOGFILE:-}" ]; then
    LOGFILE="$LOG_DIR/debug.log"
fi
DISABLED_LIST="$DATA_DIR/disabled_components.list"       # user|pkg/component|CATEGORY
COMPONENT_STATE="$DATA_DIR/component_state.list"         # user|pkg/component|original_override_state
STATE_FILE="$DATA_DIR/package_state.list"                # user|package|versionCode
PACKAGE_VERIFIED_FILE="$DATA_DIR/package_verified.list"  # |user|package|versionCode|
PACKAGE_VERIFIED_HASH_FILE="$DATA_DIR/.package_verified.hash"
LAST_FULL_VERIFY_FILE="$DATA_DIR/.last_full_verify"
RULES_FILE="$DATA_DIR/rules.conf"
SETTINGS_FILE="$DATA_DIR/settings.conf"
WHITELIST_FILE="$DATA_DIR/whitelist.list"
SMART_REWARD_FILE="$DATA_DIR/smart_reward.list"
QA_TARGETS_FILE="$DATA_DIR/qa_targets.list"
WHITE_ADS_FILE="$DATA_DIR/white_ads.list"
WHITE_ANALYTICS_FILE="$DATA_DIR/white_analytics.list"
CACHE_ADS="$DATA_DIR/.white_ads.cache"
CACHE_ANALYTICS="$DATA_DIR/.white_analytics.cache"
CACHE_GLOBAL="$DATA_DIR/.whitelist.cache"
CONFIG_HASH_FILE="$DATA_DIR/.config.hash"
BASE_POLICY_HASH_FILE="$DATA_DIR/.base_policy.hash"
DISCOVERY_HASH_FILE="$DATA_DIR/.discovery.hash"
NON_PRIMARY_HASH_FILE="$DATA_DIR/.non_primary_settings.hash"
CANDIDATE_FILE="$DATA_DIR/component_candidates.list"
CANDIDATE_SCOPE_FILE="$DATA_DIR/.candidate_scope"
PACKAGE_SCOPE_CACHE="$DATA_DIR/package_scope.list"          # user|package|USER|SYSTEM
COMPONENT_VERIFY_PENDING="$DATA_DIR/.component_verify.pending"
APPLIED_GENERATION_FILE="$DATA_DIR/.applied_generation"
RECONCILE_STATUS_FILE="$DATA_DIR/reconcile.status"
WATCH_PID_FILE="$DATA_DIR/config_watch.pid"
INOTIFY_PID_FILE="$DATA_DIR/inotify.pid"
CONFIG_INOTIFY_PID_FILE="$DATA_DIR/config_inotify.pid"
LOG_MIRROR_PID_FILE="$DATA_DIR/log_mirror.pid"
AD_SURFACE_PID_FILE="$DATA_DIR/ad_surface_index.pid"
AD_SURFACE_STATUS_FILE="$DATA_DIR/ad_surface_index.status"
AD_SURFACE_LOCK_DIR="$DATA_DIR/.surface_index.lock"
LOCK_DIR="$DATA_DIR/.operation.lock"
STATE_DB_LOCK="$DATA_DIR/.state_db.lock"
MEMBERSHIP_DB_LOCK="$DATA_DIR/.membership_db.lock"
CAPABILITIES_FILE="$DATA_DIR/capabilities.conf"
COMPONENT_AUDIT_FILE="$LOG_DIR/component_audit.log"
SDK_FINGERPRINT_FILE="$LOG_DIR/sdk_fingerprint.log"
MANIFEST_SCAN_FILE="$LOG_DIR/manifest_scan.log"
AD_SURFACE_SCAN_FILE="$LOG_DIR/ad_surface_scan.log"
AD_KILLER_TARGET_FILE="$DATA_DIR/ad_killer_targets.list"
AD_KILLER_LOG_FILE="$LOG_DIR/ad_killer.log"
AD_KILLER_STATUS_FILE="$DATA_DIR/ad_killer.status"
AD_KILLER_CHAIN="AAD_ADKILL"
AD_KILLER_LOCK_DIR="$DATA_DIR/.ad_killer.lock"
MANIFEST_CACHE_DIR="$DATA_DIR/manifest_cache/v1"
IFW_DIR="${IFW_DIR:-/data/system/ifw}"
IFW_RULE_FILE="$IFW_DIR/analytics_ads_disabler.xml"
IFW_APPLIED_CKSUM="$DATA_DIR/.ifw_applied.cksum"

AAD_LIB_DIR=""
for _ald in "${MODDIR:-}" "${0%/*}" /data/adb/modules/analytics_ads_disabler "$DATA_DIR"; do
    if [ -n "$_ald" ] && [ -f "$_ald/compat.sh" ]; then
        AAD_LIB_DIR="$_ald"
        break
    fi
done
[ -n "$AAD_LIB_DIR" ] || AAD_LIB_DIR="/data/adb/modules/analytics_ads_disabler"
MODULE_PROP="$AAD_LIB_DIR/module.prop"
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
if [ -f "$AAD_LIB_DIR/compat.sh" ]; then
    . "$AAD_LIB_DIR/compat.sh"
    if [ "${AAD_DEFER_CAPABILITY_INIT:-0}" != "1" ]; then
        ensure_capability_profile >/dev/null 2>&1
        load_capabilities
    fi
fi

CATEGORIES="ADS ANALYTICS"
SYSTEM_PROTECTED="android com.android.systemui com.android.settings com.android.packageinstaller com.android.permissioncontroller com.google.android.permissioncontroller com.android.phone com.android.providers.settings com.android.providers.downloads com.android.documentsui com.android.shell com.android.bluetooth com.android.nfc com.android.location.fused com.android.networkstack com.google.android.networkstack com.android.networkstack.tethering com.google.android.networkstack.tethering com.google.android.gms com.android.vending com.google.android.gsf com.google.android.inputmethod.latin com.huawei.hwid com.huawei.hms.config.service com.sec.android.app.samsungapps com.topjohnwu.magisk me.weishu.kernelsu me.bmax.apatch"

aad_oem_protected_packages() {
    _aop_id=$(getprop ro.product.manufacturer 2>/dev/null)
    _aop_id="$_aop_id $(getprop ro.product.brand 2>/dev/null)"
    _aop_id="$_aop_id $(getprop ro.product.name 2>/dev/null)"
    _aop_id=$(printf '%s' "$_aop_id" | tr '[:upper:]' '[:lower:]')
    _aop_out=""
    case "$_aop_id" in
        *xiaomi*|*redmi*|*poco*)
            _aop_out="$_aop_out com.xiaomi.xmsf com.xiaomi.finddevice com.miui.home com.miui.securitycenter com.miui.core com.miui.contentcatcher" ;;
    esac
    case "$_aop_id" in
        *samsung*)
            _aop_out="$_aop_out com.samsung.android.honeyboard com.sec.android.app.launcher com.samsung.android.mdx com.samsung.android.messaging com.samsung.push com.samsung.android.spay" ;;
    esac
    case "$_aop_id" in
        *oppo*|*realme*|*oneplus*|*heytap*)
            _aop_out="$_aop_out com.heytap.mcs com.coloros.mcs com.oplus.push com.oppo.launcher com.android.launcher com.oplus.uifirst" ;;
    esac
    case "$_aop_id" in
        *vivo*|*iqoo*)
            _aop_out="$_aop_out com.vivo.pushservice com.vivo.push com.bbk.launcher2 com.vivo.abe" ;;
    esac
    case "$_aop_id" in
        *huawei*|*honor*)
            _aop_out="$_aop_out com.huawei.android.pushagent com.huawei.android.launcher com.hihonor.push com.huawei.hwid.core" ;;
    esac
    case "$_aop_id" in
        *motorola*|*lenovo*) _aop_out="$_aop_out com.motorola.launcher3 com.motorola.ccc.notification" ;;
    esac
    case "$_aop_id" in
        *transsion*|*infinix*|*tecno*|*itel*) _aop_out="$_aop_out com.transsion.push com.transsion.hilauncher" ;;
    esac
    printf '%s\n' "$_aop_out"
}
SYSTEM_PROTECTED="$SYSTEM_PROTECTED $(aad_oem_protected_packages 2>/dev/null)"

mkdir -p "$DATA_DIR" 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$LOGFILE"
}

aad_now_ms() {
    if [ -r /proc/uptime ]; then
        awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime 2>/dev/null && return 0
    fi
    _aad_sec=$(date +%s 2>/dev/null)
    case "$_aad_sec" in ''|*[!0-9]*) _aad_sec=0 ;; esac
    echo $((_aad_sec * 1000))
}

aad_epoch_ms() {
    _aem_sec=$(date +%s 2>/dev/null)
    case "$_aem_sec" in ''|*[!0-9]*) _aem_sec=0 ;; esac
    echo $((_aem_sec * 1000))
}

aad_elapsed_ms() {
    _aad_start="$1"; _aad_end="$2"
    case "$_aad_start:$_aad_end" in *[!0-9:]*|'') echo 0 ;; *) echo $((_aad_end - _aad_start)) ;; esac
}

log_cmd_exec() {
    cmd_text="$1"
    out="$2"
    rc="$3"
    log "EXEC CMD: $cmd_text"
    log "  |_ EXIT CODE: $rc"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do
            [ -n "$line" ] && log "  |_ OUT: $line"
        done
    fi
}

DIAGFILE="$LOG_DIR/diagnostics.log"

SDCARD_LOG_DIR="${SDCARD_LOG_DIR:-/sdcard/eCubz/logs/Analytics_Ads_Disabler}"

sync_logs_to_sdcard() {
    [ "$(read_bool_setting LOG_MIRROR 1)" = "1" ] || return 0
    mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null || return 0
    _slts_files="debug.log debug.previous.log boot_trace.log diagnostics.log install_diagnostics.log uninstall.log"
    if [ "$(read_bool_setting LOG_MIRROR_FULL 0)" = "1" ]; then
        _slts_files="$_slts_files component_audit.log sdk_fingerprint.log manifest_scan.log ad_surface_scan.log ad_killer.log ad_killer.previous.log"
    fi
    for _slts_f in $_slts_files; do
        [ -f "$LOG_DIR/$_slts_f" ] || continue
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 cp "$LOG_DIR/$_slts_f" "$SDCARD_LOG_DIR/" 2>/dev/null || true
        else
            cp "$LOG_DIR/$_slts_f" "$SDCARD_LOG_DIR/" 2>/dev/null || true
        fi
    done
    return 0
}

diag_line() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$DIAGFILE"
}

diag_capture() {
    label="$1"; shift
    diag_line "===== $label ====="
    diag_line "CMD: $*"
    out=$("$@" 2>&1)
    rc=$?
    diag_line "EXIT: $rc"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do diag_line "OUT: $line"; done
    else
        diag_line "OUT: <empty>"
    fi
}

diag_capture_sh() {
    label="$1"; code="$2"
    diag_line "===== $label ====="
    diag_line "SH: $code"
    out=$(/system/bin/sh -c "$code" 2>&1)
    rc=$?
    diag_line "EXIT: $rc"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do diag_line "OUT: $line"; done
    else
        diag_line "OUT: <empty>"
    fi
}

diag_capture_su() {
    label="$1"; target="$2"; code="$3"
    diag_line "===== $label ====="
    diag_line "SU[$target]: $code"
    if ! command -v su >/dev/null 2>&1; then
        diag_line "EXIT: 127"
        diag_line "OUT: su not found"
        return
    fi
    out=$(su "$target" -c "$code" 2>&1)
    rc=$?
    diag_line "EXIT: $rc"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do diag_line "OUT: $line"; done
    else
        diag_line "OUT: <empty>"
    fi
}

collect_deep_diagnostics() {
    : > "$DIAGFILE" 2>/dev/null || return 1
    diag_line "$MODULE_VERSION_LABEL deep diagnostics"
    diag_line "NOTE: read-only diagnostics; no component state is changed by this snapshot."

    diag_capture_sh "identity/direct" 'echo "pid=$$ ppid=$PPID"; id; id -Z 2>/dev/null; echo "self_ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d "\000")"; echo "parent_ctx=$(cat /proc/$PPID/attr/current 2>/dev/null | tr -d "\000")"; echo "PATH=$PATH"; umask'
    diag_capture_sh "proc/self/status" 'cat /proc/self/status 2>/dev/null'
    diag_capture_sh "proc/parent/status" 'cat /proc/$PPID/status 2>/dev/null'
    diag_capture_sh "SELinux" 'getenforce 2>/dev/null; getenforce 2>/dev/null; cat /sys/fs/selinux/enforce 2>/dev/null'
    diag_capture_sh "kernel" 'uname -a; cat /proc/version 2>/dev/null'
    diag_capture_sh "android-build" 'for k in ro.build.version.release ro.build.version.sdk ro.build.version.security_patch ro.build.fingerprint ro.product.manufacturer ro.product.brand ro.product.model ro.product.device ro.build.type ro.build.tags ro.boot.verifiedbootstate ro.boot.vbmeta.device_state ro.debuggable; do printf "%s=" "$k"; getprop "$k"; done'
    diag_capture_sh "root-manager-env" 'echo "KSU=$KSU KSU_VER=$KSU_VER KSU_VER_CODE=$KSU_VER_CODE APATCH=$APATCH KERNELPATCH=$KERNELPATCH MAGISK_VER=$MAGISK_VER MAGISK_VER_CODE=$MAGISK_VER_CODE"; command -v magisk 2>/dev/null; command -v ksud 2>/dev/null; command -v apd 2>/dev/null; ls -l /data/adb/ksu/bin 2>/dev/null | head -n 80'
    diag_capture_sh "tool-resolution" 'for x in sh cmd pm su runcon service dumpsys getprop toybox busybox; do printf "%s => " "$x"; command -v "$x" 2>/dev/null || echo missing; done; for x in /system/bin/cmd /system/bin/pm /system/bin/service /system/bin/runcon /system/bin/sh; do ls -lZ "$x" 2>/dev/null || ls -l "$x" 2>/dev/null; done'

    diag_capture_sh "cmd --help" 'cmd --help 2>&1'
    diag_capture_sh "cmd -l" 'cmd -l 2>&1'
    diag_capture_sh "cmd package help" 'cmd package help 2>&1'
    diag_capture_sh "pm help" 'pm help 2>&1'
    diag_capture_sh "cmd activity help" 'cmd activity help 2>&1'
    diag_capture_sh "cmd user help" 'cmd user help 2>&1'
    diag_capture_sh "service list" 'service list 2>&1'
    diag_capture_sh "service check package/activity/user" 'service check package 2>&1; service check activity 2>&1; service check user 2>&1'

    smoke='echo "pid=$$ ppid=$PPID uid=$(id -u 2>/dev/null) gid=$(id -g 2>/dev/null) ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d "\000")"; echo "-- activity current user --"; cmd activity get-current-user 2>&1; echo "rc=$?"; echo "-- user list --"; cmd user list 2>&1 | head -n 20; echo "rc=${PIPESTATUS:-n/a}"; echo "-- package list --"; cmd package list packages --user 0 2>&1 | head -n 5; echo "-- package help head --"; cmd package help 2>&1 | head -n 20'
    diag_capture_sh "binder-smoke/direct" "$smoke"
    diag_capture_su "binder-smoke/su-2000" 2000 "$smoke"
    diag_capture_su "binder-smoke/su-shell" shell "$smoke"

    rb=$(cap_runcon_bin 2>/dev/null)
    if [ -n "$rb" ]; then
        diag_line "===== runcon probe ====="
        diag_line "runcon_bin=$rb"
        case "$rb" in
            *" "*) out=$($rb u:r:shell:s0 /system/bin/sh -c "$smoke" 2>&1); rc=$? ;;
            *) out=$("$rb" u:r:shell:s0 /system/bin/sh -c "$smoke" 2>&1); rc=$? ;;
        esac
        diag_line "EXIT: $rc"
        printf '%s\n' "$out" | while IFS= read -r line; do diag_line "OUT: $line"; done
    else
        diag_line "===== runcon probe ====="
        diag_line "runcon unavailable"
    fi

    diag_line "===== PM mutation model ====="
    diag_line "api=$(cap_api_level 2>/dev/null)"
    if cap_shell_uid_component_mutation_allowed; then
        diag_line "shell_uid_component_mutation=legacy_candidate"
    else
        diag_line "shell_uid_component_mutation=disabled_android16_plus"
    fi
    diag_line "runcon_shell_uid0_available=$(cap_runcon_shell_available && echo yes || echo no)"
    diag_line "runcon_scope=pm_command_via_shell_no_data_io fd_sanitizer=module_data_only"

    diag_capture_sh "process-contexts" 'ps -AZ 2>/dev/null | grep -E "(^|[[:space:]])(cmd|pm|sh|su|ksud|magisk|apd)([[:space:]]|$)" | head -n 120'
    diag_capture_sh "binder-proc-summary" 'cat /proc/binder/proc/$$ 2>/dev/null | head -n 120; cat /sys/kernel/debug/binder/proc/$$ 2>/dev/null | head -n 120'
    diag_capture_sh "dmesg-binder-denials-tail" 'dmesg 2>/dev/null | grep -Ei "avc:|binder|transaction|selinux" | tail -n 120'
    diag_capture_sh "logcat-binder-denials-tail" 'logcat -d -v threadtime -t 800 2>/dev/null | grep -Ei "avc:|binder|FAILED_TRANSACTION|PackageManager|SecurityException" | tail -n 160'

    diag_line "===== ad killer ====="
    if [ -f "$AD_KILLER_STATUS_FILE" ]; then
        while IFS= read -r line; do diag_line "ADK-STATUS: $line"; done < "$AD_KILLER_STATUS_FILE"
    else
        diag_line "ADK-STATUS: <missing>"
    fi
    if [ -f "$AD_KILLER_TARGET_FILE" ]; then
        _adk_diag_targets=$(grep -c . "$AD_KILLER_TARGET_FILE" 2>/dev/null); [ -n "$_adk_diag_targets" ] || _adk_diag_targets=0
        diag_line "ADK-TARGETS: count=$_adk_diag_targets file=$AD_KILLER_TARGET_FILE"
        head -n 80 "$AD_KILLER_TARGET_FILE" 2>/dev/null | while IFS= read -r line; do diag_line "ADK-TARGET: $line"; done
    else
        diag_line "ADK-TARGETS: <missing>"
    fi
    _adk_diag4=$(ad_killer_iptables_bin 4)
    _adk_diag6=$(ad_killer_iptables_bin 6)
    [ -n "$_adk_diag4" ] && diag_capture "ad-killer-iptables-v4" "$_adk_diag4" -t filter -S "$AD_KILLER_CHAIN"
    [ -n "$_adk_diag6" ] && diag_capture "ad-killer-iptables-v6" "$_adk_diag6" -t filter -S "$AD_KILLER_CHAIN"

    diag_line "===== policy generation / candidate cache ====="
    diag_line "POLICY-APPLIED: $(cat "$APPLIED_GENERATION_FILE" 2>/dev/null || echo '<missing>')"
    if [ -f "$RECONCILE_STATUS_FILE" ]; then
        while IFS= read -r line; do diag_line "RECONCILE: $line"; done < "$RECONCILE_STATUS_FILE"
    else
        diag_line "RECONCILE: <missing>"
    fi
    diag_line "CANDIDATE-SCOPE: $(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null || echo '<missing>')"
    diag_line "CANDIDATE-COUNT: $(grep -c . "$CANDIDATE_FILE" 2>/dev/null || echo 0)"
    diag_line "DISCOVERY-HASH stored=$(cat "$DISCOVERY_HASH_FILE" 2>/dev/null) current=$(compute_discovery_policy_hash 2>/dev/null)"
    diag_line "NONPRIMARY-HASH stored=$(cat "$NON_PRIMARY_HASH_FILE" 2>/dev/null) current=$(compute_non_primary_settings_hash 2>/dev/null)"

    diag_line "===== capability profile ====="
    if [ -f "$CAPABILITIES_FILE" ]; then
        while IFS= read -r line; do diag_line "CAP: $line"; done < "$CAPABILITIES_FILE"
    else
        diag_line "CAP: <missing>"
    fi
    diag_line "===== diagnostics end ====="
}

trim_config_lines() {
    sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

read_setting() {
    key="$1"
    def="$2"
    val=""
    _rs_file="${AAD_SETTINGS_SNAPSHOT:-$SETTINGS_FILE}"
    if [ -f "$_rs_file" ]; then
        val=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$_rs_file" | head -n1 | tr -d '\r')
    fi
    [ -n "$val" ] && echo "$val" || echo "$def"
}

read_bool_setting() {
    val=$(read_setting "$1" "$2")
    case "$val" in
        1|true|TRUE|yes|YES) echo 1 ;;
        0|false|FALSE|no|NO) echo 0 ;;
        *) [ "$2" = "1" ] && echo 1 || echo 0 ;;
    esac
}

read_poll_interval() {
    val=$(read_setting CATEGORY_POLL_INTERVAL 10)
    case "$val" in
        ''|*[!0-9]*) echo 10 ;;
        *)
            [ "$val" -lt 3 ] 2>/dev/null && val=3
            [ "$val" -gt 3600 ] 2>/dev/null && val=3600
            echo "$val"
            ;;
    esac
}

read_package_poll_interval() {
    val=$(read_setting PACKAGE_POLL_INTERVAL 60)
    case "$val" in
        ''|*[!0-9]*) echo 60 ;;
        *)
            [ "$val" -lt 15 ] 2>/dev/null && val=15
            [ "$val" -gt 3600 ] 2>/dev/null && val=3600
            echo "$val"
            ;;
    esac
}

read_package_safety_poll_interval() {
    val=$(read_setting PACKAGE_SAFETY_POLL_INTERVAL 900)
    case "$val" in
        ''|*[!0-9]*) echo 900 ;;
        *)
            [ "$val" -lt 60 ] 2>/dev/null && val=60
            [ "$val" -gt 86400 ] 2>/dev/null && val=86400
            echo "$val"
            ;;
    esac
}

read_max_matches() {
    val=$(read_setting MAX_MATCHES_PER_CATEGORY 15)
    case "$val" in
        ''|*[!0-9]*) echo 15 ;;
        *)
            [ "$val" -lt 1 ] 2>/dev/null && val=1
            [ "$val" -gt 100 ] 2>/dev/null && val=100
            echo "$val"
            ;;
    esac
}

read_aggressive_ads_max_matches() {
    val=$(read_setting MAX_AGGRESSIVE_ADS_MATCHES 64)
    case "$val" in
        ''|*[!0-9]*) echo 64 ;;
        *)
            [ "$val" -lt 15 ] 2>/dev/null && val=15
            [ "$val" -gt 128 ] 2>/dev/null && val=128
            echo "$val"
            ;;
    esac
}

read_component_mode() {
    echo "UNIVERSAL"
}

read_component_backend() {
    echo "PM"
}

read_ifw_activity_limit() {
    echo 5
}

read_include_system_apps() {
    # Runtime has exactly one authoritative SYSTEM-scope switch. Legacy
    # SCAN_SYSTEM_APPS is migrated by the installer only; a missing/corrupt
    # v6 key must fail safe to OFF rather than resurrect a stale legacy value.
    _val=$(read_setting INCLUDE_SYSTEM_APPS 0)
    case "$_val" in
        1|true|TRUE|yes|YES) echo 1 ;;
        *) echo 0 ;;
    esac
}

probe_ifw_storage() {
    return 1
}

category_enabled() {
    case "$1" in
        ADS) [ "$(read_bool_setting BLOCK_ADS 0)" = "1" ] ;;
        ANALYTICS) [ "$(read_bool_setting BLOCK_ANALYTICS 0)" = "1" ] ;;
        *) return 1 ;;
    esac
}

get_whitelist_file_for_category() {
    case "$1" in
        ADS) echo "$WHITE_ADS_FILE" ;;
        ANALYTICS) echo "$WHITE_ANALYTICS_FILE" ;;
        *) echo "" ;;
    esac
}

get_cache_file_for_category() {
    case "$1" in
        ADS) echo "$CACHE_ADS" ;;
        ANALYTICS) echo "$CACHE_ANALYTICS" ;;
        *) echo "" ;;
    esac
}

aad_dynamic_protected_packages() {
    _adp_user="${1:-0}"
    _adp_cache_file="$DATA_DIR/.dyn_prot_u${_adp_user}"
    _adp_unknown_file="$DATA_DIR/.dyn_prot_unknown_u${_adp_user}"
    if [ -f "$_adp_cache_file" ] && [ -n "${AAD_PROTECTED_CACHE_ACTIVE:-}" ]; then
        cat "$_adp_cache_file" 2>/dev/null
        return 0
    fi

    _adp_out=""
    _adp_uncertain=0
    # Per-user HOME. Do not silently substitute another user's role holder.
    if command -v cmd >/dev/null 2>&1; then
        _adp_home=$(cmd package resolve-activity --brief --user "$_adp_user" -c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null | tail -n1 | cut -d/ -f1)
        if [ -n "$_adp_home" ]; then
            case "$_adp_home" in *[!a-zA-Z0-9._-]*) _adp_uncertain=1 ;; *) _adp_out="$_adp_out $_adp_home" ;; esac
        else
            _adp_uncertain=1
        fi
    else
        _adp_uncertain=1
    fi

    # Per-user default IME. Missing/unreadable role is conservative uncertainty.
    if command -v settings >/dev/null 2>&1; then
        _adp_ime_raw=$(settings get secure --user "$_adp_user" default_input_method 2>/dev/null)
        _adp_ime=$(printf '%s' "$_adp_ime_raw" | cut -d/ -f1)
        case "$_adp_ime" in ''|null) _adp_uncertain=1 ;; *[!a-zA-Z0-9._-]*) _adp_uncertain=1 ;; *) _adp_out="$_adp_out $_adp_ime" ;; esac
    else
        _adp_uncertain=1
    fi

    # Active WebView provider is global, but still part of critical-role protection.
    if command -v dumpsys >/dev/null 2>&1; then
        _adp_wv=$(dumpsys webviewupdate 2>/dev/null | grep -E "Current WebView package|Current package" | head -n1 | sed -n "s/.*'\(.*\)'.*/\1/p")
        [ -z "$_adp_wv" ] && _adp_wv=$(dumpsys webviewupdate 2>/dev/null | grep -i "current.*package" | head -n1 | awk -F'=' '{print $2}' | tr -d ' "\r')
        if [ -n "$_adp_wv" ]; then
            case "$_adp_wv" in *[!a-zA-Z0-9._-]*) _adp_uncertain=1 ;; *) _adp_out="$_adp_out $_adp_wv" ;; esac
        else
            _adp_uncertain=1
        fi
    else
        _adp_uncertain=1
    fi

    if [ "$_adp_uncertain" = "1" ]; then : > "$_adp_unknown_file" 2>/dev/null || true; else rm -f "$_adp_unknown_file" 2>/dev/null; fi
    if [ -n "${AAD_PROTECTED_CACHE_ACTIVE:-}" ]; then
        printf '%s\n' "$_adp_out" > "$_adp_cache_file" 2>/dev/null || true
    fi
    printf '%s\n' "$_adp_out"
}

is_system_protected() {
    _isp_pkg="$1"
    _isp_user="${2:-0}"
    [ -n "$_isp_pkg" ] || return 0
    for sys_pkg in $SYSTEM_PROTECTED; do
        [ "$_isp_pkg" = "$sys_pkg" ] && return 0
    done
    for dyn_pkg in $(aad_dynamic_protected_packages "$_isp_user" 2>/dev/null); do
        [ "$_isp_pkg" = "$dyn_pkg" ] && return 0
    done
    return 1
}

is_smart_reward_pkg() {
    [ -f "$SMART_REWARD_FILE" ] && trim_config_lines < "$SMART_REWARD_FILE" | grep -Fxq -- "$1" 2>/dev/null
}

is_globally_whitelisted() {
    [ -f "$WHITELIST_FILE" ] && trim_config_lines < "$WHITELIST_FILE" | grep -Fxq -- "$1" 2>/dev/null && return 0
    is_smart_reward_pkg "$1" && return 0
    return 1
}

is_package_in_scope() {
    _sc_pkg="$1"
    _sc_user="${2:-0}"
    _sc_is_sys="${3:-unknown}"
    [ -n "$_sc_pkg" ] || return 1
    is_system_protected "$_sc_pkg" "$_sc_user" && return 1
    is_globally_whitelisted "$_sc_pkg" && return 1

    if [ "$_sc_is_sys" = "1" ] || { [ "$_sc_is_sys" = "unknown" ] && cap_is_system_package "$_sc_user" "$_sc_pkg" 2>/dev/null; }; then
        [ "$(read_include_system_apps)" = "1" ] || return 1
        # If critical per-user roles could not be resolved, fail safe for system apps.
        [ ! -f "$DATA_DIR/.dyn_prot_unknown_u${_sc_user}" ] || return 1
    fi
    return 0
}

is_category_whitelisted() {
    wf=$(get_whitelist_file_for_category "$2")
    [ -n "$wf" ] && [ -f "$wf" ] && trim_config_lines < "$wf" | grep -Fxq -- "$1" 2>/dev/null
}

read_category_list() {
    wf=$(get_whitelist_file_for_category "$1")
    [ -f "$wf" ] && trim_config_lines < "$wf" | sort -u
}

read_global_list() {
    {
        [ -f "$WHITELIST_FILE" ] && trim_config_lines < "$WHITELIST_FILE"
        [ -f "$SMART_REWARD_FILE" ] && trim_config_lines < "$SMART_REWARD_FILE"
    } | sort -u
}

aad_lock_write_owner() {
    printf '%s\n' "$$" > "$1/pid" 2>/dev/null
    printf '%s\n' "$(aad_proc_starttime "$$")" > "$1/starttime" 2>/dev/null
    return 0
}

aad_lock_owner_alive() {
    _aloa_dir="$1"
    _aloa_pid=$(cat "$_aloa_dir/pid" 2>/dev/null)
    case "$_aloa_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_aloa_pid" 2>/dev/null || return 1
    _aloa_saved=$(cat "$_aloa_dir/starttime" 2>/dev/null)
    [ -n "$_aloa_saved" ] || return 1
    _aloa_live=$(aad_proc_starttime "$_aloa_pid")
    [ -n "$_aloa_live" ] && [ "$_aloa_saved" = "$_aloa_live" ]
}

acquire_lock() {
    retries=0
    stale_removals=0
    while ! (umask 077; mkdir "$LOCK_DIR") 2>/dev/null; do
        if ! aad_lock_owner_alive "$LOCK_DIR"; then
            log "LOCK-STALE removing owner=$(cat "$LOCK_DIR/pid" 2>/dev/null) (dead pid, reused pid or reboot leftover)"
            rm -rf "$LOCK_DIR" 2>/dev/null
            stale_removals=$((stale_removals + 1))
            [ "$stale_removals" -ge 5 ] && return 1
            continue
        fi
        retries=$((retries + 1))
        [ "$retries" -ge 60 ] && return 1
        sleep 1
    done
    aad_lock_write_owner "$LOCK_DIR"
    return 0
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

aad_db_lock() {
    lock="$1"
    tries=0
    stale=0
    while ! (umask 077; mkdir "$lock") 2>/dev/null; do
        if ! aad_lock_owner_alive "$lock"; then
            rm -rf "$lock" 2>/dev/null
            stale=$((stale + 1))
            [ "$stale" -ge 5 ] && return 1
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 100 ] && return 1
        sleep 0.1 2>/dev/null || sleep 1
    done
    aad_lock_write_owner "$lock"
    return 0
}

aad_db_unlock() {
    rm -rf "$1" 2>/dev/null
}

aad_mktemp_near() {
    target="$1"
    if command -v mktemp >/dev/null 2>&1; then
        mktemp "${target}.tmp.XXXXXX" 2>/dev/null && return 0
    fi
    salt=$(cat /proc/uptime 2>/dev/null | cksum 2>/dev/null | awk '{print $1}')
    [ -n "$salt" ] || salt=0
    echo "${target}.tmp.$$.${salt}"
}

aad_pid_matches_marker() {
    _apm_pid="$1"; _apm_marker="$2"
    case "$_apm_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_apm_pid" 2>/dev/null || return 1
    _apm_cmd=$(tr '\000' ' ' < "/proc/$_apm_pid/cmdline" 2>/dev/null)
    case "$_apm_cmd" in *"$_apm_marker"*) return 0 ;; *) return 1 ;; esac
}

stop_owned_pidfile() {
    pidfile="$1"
    marker="$2"
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if aad_pid_matches_marker "$pid" "$marker"; then
            kill "$pid" 2>/dev/null
            log "Stopped owned process pid=$pid marker=$marker"
        else
            log "PID-SAFETY: pid=$pid no longer matches $marker; not killed."
        fi
    fi
    rm -f "$pidfile" 2>/dev/null
}

launch_ad_surface_indexer_bg() {
    reason="${1:-request}"
    worker="${MODDIR:-$AAD_LIB_DIR}/ad_surface_indexer.sh"
    [ -f "$worker" ] || { log "AD-SURFACE-INDEX unavailable worker=$worker"; return 1; }

    oldpid=$(cat "$AD_SURFACE_PID_FILE" 2>/dev/null)
    case "$oldpid" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$oldpid" 2>/dev/null; then
                oldcmd=$(tr '\000' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null)
                case "$oldcmd" in
                    *ad_surface_indexer.sh*)
                        printf '%s\n' "$reason" > "$DATA_DIR/.surface_index.rerun.tmp.$$" 2>/dev/null \
                            && mv -f "$DATA_DIR/.surface_index.rerun.tmp.$$" "$DATA_DIR/.surface_index.rerun" 2>/dev/null
                        rm -f "$DATA_DIR/.surface_index.rerun.tmp.$$" 2>/dev/null
                        log "AD-SURFACE-INDEX already running pid=$oldpid; queued rerun reason=$reason"
                        return 0
                        ;;
                esac
            fi
            ;;
    esac
    rm -f "$AD_SURFACE_PID_FILE" 2>/dev/null

    "$worker" >> "$LOGFILE" 2>&1 &
    surface_pid=$!
    echo "$surface_pid" > "$AD_SURFACE_PID_FILE" 2>/dev/null
    log "AD-SURFACE-INDEX launched pid=$surface_pid reason=$reason"
    return 0
}

ad_killer_enabled() {
    [ "$(read_bool_setting BLOCK_ADS 0)" = "1" ] || return 1
    [ "$(read_bool_setting AD_SURFACE_KILLER 1)" = "1" ] || return 1
    return 0
}

ad_killer_log_init() {
    if [ ! -f "$AD_KILLER_LOG_FILE" ]; then
        printf 'timestamp|family|action|user|package|uid|sdk|host|result\n' > "$AD_KILLER_LOG_FILE" 2>/dev/null || true
        chmod 600 "$AD_KILLER_LOG_FILE" 2>/dev/null || true
    fi
}

ad_killer_log_rotate() {
    [ -s "$AD_KILLER_LOG_FILE" ] || return 0
    mv -f "$AD_KILLER_LOG_FILE" "$LOG_DIR/ad_killer.previous.log" 2>/dev/null || true
    chmod 600 "$LOG_DIR/ad_killer.previous.log" 2>/dev/null || true
}

ad_killer_log_record() {
    _akl_family="$1"; _akl_action="$2"; _akl_user="$3"; _akl_pkg="$4"; _akl_uid="$5"; _akl_sdk="$6"; _akl_host="$7"; _akl_result="$8"
    ad_killer_log_init
    _akl_stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_akl_stamp" "$_akl_family" "$_akl_action" "$_akl_user" "$_akl_pkg" "$_akl_uid" "$_akl_sdk" "$_akl_host" "$_akl_result" >> "$AD_KILLER_LOG_FILE" 2>/dev/null || true
}

ad_killer_extract_host_map() {
    [ -f "$RULES_FILE" ] || return 0
    awk -F'|' -v target='[ADS_NETWORK_HOST]' '
        function trim(v){sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); return v}
        $0==target {inside=1; next}
        inside && $0 ~ /^\[/ {exit}
        inside {
            line=$0; sub(/\r$/, "", line)
            if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
            n=split(line,a,"|"); if(n<2) next
            sdk=trim(a[1]); host=tolower(trim(a[2]))
            if (sdk!="" && host ~ /^[a-z0-9.-]+$/ && host ~ /\./) print sdk "|" host
        }
    ' "$RULES_FILE" | sort -u
}

ad_killer_min_confidence() {
    _akmc=$(read_setting AD_KILLER_MIN_CONFIDENCE CAPABILITY | tr '[:lower:]' '[:upper:]')
    case "$_akmc" in
        CAPABILITY|LAYOUT_CONFIRMED|MULTI_EVIDENCE) printf '%s\n' "$_akmc" ;;
        *) printf 'CAPABILITY\n' ;;
    esac
}

ad_killer_build_targets_from_surface() {
    [ -f "$AD_SURFACE_SCAN_FILE" ] || return 1
    _ak_hostmap=$(aad_mktemp_near "$DATA_DIR/.adkiller_hostmap")
    _ak_surfaces=$(aad_mktemp_near "$DATA_DIR/.adkiller_surfaces")
    _ak_joined=$(aad_mktemp_near "$DATA_DIR/.adkiller_joined")
    _ak_tmp=$(aad_mktemp_near "$AD_KILLER_TARGET_FILE")
    [ -n "$_ak_hostmap" ] && [ -n "$_ak_surfaces" ] && [ -n "$_ak_joined" ] && [ -n "$_ak_tmp" ] || {
        rm -f "$_ak_hostmap" "$_ak_surfaces" "$_ak_joined" "$_ak_tmp" 2>/dev/null
        return 1
    }
    ad_killer_extract_host_map > "$_ak_hostmap"
    _ak_minconf=$(ad_killer_min_confidence)
    awk -F'|' -v minconf="$_ak_minconf" '
        BEGIN {rank["CAPABILITY"]=1; rank["LAYOUT_CONFIRMED"]=2; rank["MULTI_EVIDENCE"]=3; want=rank[minconf]; if (want=="") want=1}
        NR>1 && $2=="HIT" && $7 ~ /^(BANNER|BANNER_MREC|MREC|NATIVE|APP_OPEN)$/ && $3!="" && $4!="" && $8!="" {
            got=rank[$11]; if (got=="") got=1
            if (got >= want) print $3 "|" $4 "|" $8
        }
    ' "$AD_SURFACE_SCAN_FILE" 2>/dev/null | sort -u > "$_ak_surfaces"
    awk -F'|' '
        FNR==NR {h[$1]=h[$1] "\034" $2; next}
        {
            n=split(h[$3],a,"\034")
            for(i=1;i<=n;i++) if(a[i]!="") print $1 "|" $2 "|" $3 "|" a[i]
        }
    ' "$_ak_hostmap" "$_ak_surfaces" | sort -u > "$_ak_joined"
    : > "$_ak_tmp"
    while IFS='|' read -r _ak_user _ak_pkg _ak_sdk _ak_host; do
        [ -n "$_ak_pkg" ] && [ -n "$_ak_host" ] || continue
        is_package_in_scope "$_ak_pkg" "$_ak_user" || continue
        is_category_whitelisted "$_ak_pkg" ADS && continue
        printf '%s|%s|%s|%s\n' "$_ak_user" "$_ak_pkg" "$_ak_sdk" "$_ak_host" >> "$_ak_tmp"
    done < "$_ak_joined"
    sort -u "$_ak_tmp" -o "$_ak_tmp" 2>/dev/null || true
    chmod 600 "$_ak_tmp" 2>/dev/null || true
    mv -f "$_ak_tmp" "$AD_KILLER_TARGET_FILE" 2>/dev/null || { rm -f "$_ak_tmp" 2>/dev/null; rm -f "$_ak_hostmap" "$_ak_surfaces" "$_ak_joined" 2>/dev/null; return 1; }
    rm -f "$_ak_hostmap" "$_ak_surfaces" "$_ak_joined" 2>/dev/null
    return 0
}

ad_killer_uid_inventory() {
    _akui_users=$(list_user_ids_checked) || _akui_users="0"
    _akui_tmp=$(aad_mktemp_near "$DATA_DIR/.uid_inventory")
    [ -n "$_akui_tmp" ] || return 1
    : > "$_akui_tmp" 2>/dev/null || { rm -f "$_akui_tmp"; return 1; }

    if [ -f /data/system/packages.list ] && [ -r /data/system/packages.list ]; then
        for _aku_user in $_akui_users; do
            awk -v u="$_aku_user" '
                NF >= 2 && $2 ~ /^[0-9]+$/ {
                    uid = $2
                    if (u > 0) {
                        uid = (u * 100000) + (uid % 100000)
                    }
                    print u "|" $1 "|" uid
                }
            ' /data/system/packages.list >> "$_akui_tmp" 2>/dev/null
        done
    fi

    if [ ! -s "$_akui_tmp" ]; then
        for _aku_user in $_akui_users; do
            _akui_raw=$(aad_mktemp_near "$DATA_DIR/.uid_raw_u${_aku_user}")
            [ -n "$_akui_raw" ] || continue
            if command -v cmd >/dev/null 2>&1; then
                cmd package list packages -U --user "$_aku_user" > "$_akui_raw" 2>/dev/null || \
                cmd package list packages -U > "$_akui_raw" 2>/dev/null || true
            elif command -v pm >/dev/null 2>&1; then
                pm list packages -U --user "$_aku_user" > "$_akui_raw" 2>/dev/null || \
                pm list packages -U > "$_akui_raw" 2>/dev/null || true
            fi
            if [ -s "$_akui_raw" ]; then
                awk -v u="$_aku_user" '
                    /^package:/ {
                        pkg=$1; sub(/^package:/,"",pkg); uid=""
                        for(i=2;i<=NF;i++) if($i ~ /^uid:/){uid=$i; sub(/^uid:/,"",uid)}
                        if(pkg!="" && uid ~ /^[0-9]+$/) print u "|" pkg "|" uid
                    }' "$_akui_raw" >> "$_akui_tmp"
            fi
            rm -f "$_akui_raw" 2>/dev/null
        done
    fi

    if [ ! -s "$_akui_tmp" ]; then
        rm -f "$_akui_tmp" 2>/dev/null
        return 1
    fi

    sort -u "$_akui_tmp"
    _akui_rc=$?
    rm -f "$_akui_tmp" 2>/dev/null
    return "$_akui_rc"
}

AAD_IPTABLES_WAIT=""
aad_init_iptables_wait() {
    [ -n "$AAD_IPTABLES_WAIT" ] && return 0
    _probe_bin=$(command -v iptables 2>/dev/null || [ ! -x /system/bin/iptables ] || echo /system/bin/iptables)
    if [ -n "$_probe_bin" ] && "$_probe_bin" -w 2 -L OUTPUT >/dev/null 2>&1; then
        AAD_IPTABLES_WAIT="-w 2"
    else
        AAD_IPTABLES_WAIT="none"
    fi
}

aad_iptables() {
    aad_init_iptables_wait
    _bin=$(ad_killer_iptables_bin 4)
    [ -n "$_bin" ] || return 1
    if [ "$AAD_IPTABLES_WAIT" = "-w 2" ]; then
        "$_bin" -w 2 "$@"
    else
        "$_bin" "$@"
    fi
}

aad_ip6tables() {
    aad_init_iptables_wait
    _bin=$(ad_killer_iptables_bin 6)
    [ -n "$_bin" ] || return 1
    if [ "$AAD_IPTABLES_WAIT" = "-w 2" ]; then
        "$_bin" -w 2 "$@"
    else
        "$_bin" "$@"
    fi
}

aad_iptables_restore() {
    aad_init_iptables_wait
    _bin=$(ad_killer_restore_bin 4)
    [ -n "$_bin" ] || return 1
    if [ "$AAD_IPTABLES_WAIT" = "-w 2" ]; then
        "$_bin" -w 2 "$@"
    else
        "$_bin" "$@"
    fi
}

aad_ip6tables_restore() {
    aad_init_iptables_wait
    _bin=$(ad_killer_restore_bin 6)
    [ -n "$_bin" ] || return 1
    if [ "$AAD_IPTABLES_WAIT" = "-w 2" ]; then
        "$_bin" -w 2 "$@"
    else
        "$_bin" "$@"
    fi
}

ad_killer_iptables_bin() {
    case "$1" in
        4) command -v iptables 2>/dev/null || [ ! -x /system/bin/iptables ] || echo /system/bin/iptables ;;
        6) command -v ip6tables 2>/dev/null || [ ! -x /system/bin/ip6tables ] || echo /system/bin/ip6tables ;;
    esac
}

ad_killer_chain_cleanup_family() {
    _akc_bin="$1"
    [ -n "$_akc_bin" ] || return 0
    command -v "$_akc_bin" >/dev/null 2>&1 || [ -x "$_akc_bin" ] || return 0
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"

    _akc_before=$("$_akc_bin" $_w_flag -t filter -S 2>/dev/null) || return 1
    _akc_subs=$(printf '%s\n' "$_akc_before" | sed -n "s/^-N \\(${AD_KILLER_CHAIN}_[0-9][0-9]*\\)$/\\1/p")

    while "$_akc_bin" $_w_flag -t filter -D OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1; do :; done
    "$_akc_bin" $_w_flag -t filter -F "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
    for _akc_sub in $_akc_subs; do
        "$_akc_bin" $_w_flag -t filter -F "$_akc_sub" >/dev/null 2>&1 || true
    done
    for _akc_sub in $_akc_subs; do
        "$_akc_bin" $_w_flag -t filter -X "$_akc_sub" >/dev/null 2>&1 || true
    done
    "$_akc_bin" $_w_flag -t filter -X "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true

    _akc_after=$("$_akc_bin" $_w_flag -t filter -S 2>/dev/null) || return 1
    if printf '%s\n' "$_akc_after" | grep -Eq "(^-N ${AD_KILLER_CHAIN}($|_)|^-A OUTPUT .* -j ${AD_KILLER_CHAIN}($| ))"; then
        log "AD-KILLER cleanup verification failed bin=$_akc_bin"
        return 1
    fi
    return 0
}

ad_killer_reject_target() {
    _akrt_bin="$1"; _akrt_chain="${AD_KILLER_CHAIN}R"
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    "$_akrt_bin" $_w_flag -t filter -F "$_akrt_chain" >/dev/null 2>&1 || true
    "$_akrt_bin" $_w_flag -t filter -X "$_akrt_chain" >/dev/null 2>&1 || true
    if "$_akrt_bin" $_w_flag -t filter -N "$_akrt_chain" >/dev/null 2>&1; then
        if "$_akrt_bin" $_w_flag -t filter -A "$_akrt_chain" -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
            "$_akrt_bin" $_w_flag -t filter -F "$_akrt_chain" >/dev/null 2>&1 || true
            "$_akrt_bin" $_w_flag -t filter -X "$_akrt_chain" >/dev/null 2>&1 || true
            printf 'REJECT --reject-with tcp-reset\n'
            return 0
        fi
        "$_akrt_bin" $_w_flag -t filter -F "$_akrt_chain" >/dev/null 2>&1 || true
        "$_akrt_bin" $_w_flag -t filter -X "$_akrt_chain" >/dev/null 2>&1 || true
    fi
    printf 'DROP\n'
}

ad_killer_restore_bin() {
    case "$1" in
        4) command -v iptables-restore 2>/dev/null || { [ -x /system/bin/iptables-restore ] && echo /system/bin/iptables-restore; } ;;
        6) command -v ip6tables-restore 2>/dev/null || { [ -x /system/bin/ip6tables-restore ] && echo /system/bin/ip6tables-restore; } ;;
    esac
}

ad_killer_apply_batch() {
    _akab_bin="$1"; _akab_restore="$2"; _akab_rules="$3"; _akab_mode="$4"; _akab_ips="$5"
    [ -n "$_akab_restore" ] && [ -s "$_akab_rules" ] || return 1
    _akab_reject=$(ad_killer_reject_target "$_akab_bin")
    _akab_file=$(aad_mktemp_near "$DATA_DIR/.adkiller_restore")
    [ -n "$_akab_file" ] || return 1

    {
        printf '*filter\n'
        printf ':%s - [0:0]\n' "$AD_KILLER_CHAIN"
        awk -F'|' -v chain="$AD_KILLER_CHAIN" '{if (!seen[$3]++) printf ":%s_%s - [0:0]\n", chain, $3}' "$_akab_rules"
        awk -F'|' -v chain="$AD_KILLER_CHAIN" '{if (!seen[$3]++) printf "-A %s -m owner --uid-owner %s -j %s_%s\n", chain, $3, chain, $3}' "$_akab_rules"
        if [ "$_akab_mode" = "ip" ]; then
            [ -s "$_akab_ips" ] || { rm -f "$_akab_file" 2>/dev/null; return 1; }
            awk -F'|' -v chain="$AD_KILLER_CHAIN" -v rej="$_akab_reject" \
                '{printf "-A %s_%s -d %s -j %s\n", chain, $1, $2, rej}' "$_akab_ips"
        else
            awk -F'|' -v chain="$AD_KILLER_CHAIN" -v rej="$_akab_reject" \
                '{printf "-A %s_%s -p tcp --dport 443 -m string --algo bm --string \"%s\" -j %s\n", chain, $3, $5, rej}' "$_akab_rules"
        fi
        printf 'COMMIT\n'
    } > "$_akab_file" 2>/dev/null || { rm -f "$_akab_file" 2>/dev/null; return 1; }

    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"

    if ! "$_akab_restore" $_w_flag -n "$_akab_file" >/dev/null 2>&1; then
        log "AD-KILLER batch restore failed bin=$_akab_restore file=$_akab_file; falling back to per-rule mode"
        rm -f "$_akab_file" 2>/dev/null
        return 1
    fi
    rm -f "$_akab_file" 2>/dev/null
    return 0
}

ad_killer_status_write() {
    _aks_state="$1"; _aks_reason="${2:-}"; _aks_v4="${3:-0}"; _aks_v6="${4:-0}"
    _aks_tmp="$AD_KILLER_STATUS_FILE.tmp.$$"
    {
        printf 'state=%s\n' "$_aks_state"
        [ -n "$_aks_reason" ] && printf 'reason=%s\n' "$_aks_reason"
        printf 'ipv4_active=%s\n' "$_aks_v4"
        printf 'ipv6_active=%s\n' "$_aks_v6"
        printf 'updated_ms=%s\n' "$(aad_now_ms)"
    } > "$_aks_tmp" 2>/dev/null || return 0
    chmod 600 "$_aks_tmp" 2>/dev/null || true
    mv -f "$_aks_tmp" "$AD_KILLER_STATUS_FILE" 2>/dev/null || rm -f "$_aks_tmp" 2>/dev/null
}

ad_killer_cleanup() {
    _akc_state="${1:-DISABLED}"; _akc_reason="${2:-}"
    _akc_prev4=$(sed -n 's/^ipv4_active=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n1)
    _akc_prev6=$(sed -n 's/^ipv6_active=//p' "$AD_KILLER_STATUS_FILE" 2>/dev/null | head -n1)
    case "$_akc_prev4" in 1) ;; *) _akc_prev4=0 ;; esac
    case "$_akc_prev6" in 1) ;; *) _akc_prev6=0 ;; esac
    _akc4=$(ad_killer_iptables_bin 4); _akc6=$(ad_killer_iptables_bin 6)
    _akc_failed=0
    if [ -n "$_akc4" ]; then
        ad_killer_chain_cleanup_family "$_akc4" || _akc_failed=1
    elif [ "$_akc_prev4" = "1" ]; then
        log "AD-KILLER cleanup pending: IPv4 backend unavailable while previous rules were active"
        _akc_failed=1
    fi
    if [ -n "$_akc6" ]; then
        ad_killer_chain_cleanup_family "$_akc6" || _akc_failed=1
    elif [ "$_akc_prev6" = "1" ]; then
        log "AD-KILLER cleanup pending: IPv6 backend unavailable while previous rules were active"
        _akc_failed=1
    fi
    if [ "$_akc_failed" -ne 0 ]; then
        # Preserve previous active-family evidence so a later retry cannot
        # mistake an unavailable backend for a clean terminal state.
        ad_killer_status_write PENDING "cleanup_failed:$_akc_reason" "$_akc_prev4" "$_akc_prev6"
        return 1
    fi
    ad_killer_status_write "$_akc_state" "$_akc_reason" 0 0
    return 0
}

ad_killer_probe_match() {
    _akpm_bin="$1"; _akpm_kind="$2"; _akpm_chain="${AD_KILLER_CHAIN}P"
    [ -n "$_akpm_bin" ] || return 1
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    while "$_akpm_bin" $_w_flag -t filter -D OUTPUT -j "$_akpm_chain" >/dev/null 2>&1; do :; done
    "$_akpm_bin" $_w_flag -t filter -F "$_akpm_chain" >/dev/null 2>&1 || true
    "$_akpm_bin" $_w_flag -t filter -X "$_akpm_chain" >/dev/null 2>&1 || true
    "$_akpm_bin" $_w_flag -t filter -N "$_akpm_chain" >/dev/null 2>&1 || return 1
    if ! "$_akpm_bin" $_w_flag -t filter -A OUTPUT -j "$_akpm_chain" >/dev/null 2>&1; then
        "$_akpm_bin" $_w_flag -t filter -X "$_akpm_chain" >/dev/null 2>&1 || true
        return 1
    fi
    _akpm_rc=1
    case "$_akpm_kind" in
        owner)
            "$_akpm_bin" $_w_flag -t filter -A "$_akpm_chain" -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN >/dev/null 2>&1 && _akpm_rc=0
            ;;
        string)
            "$_akpm_bin" $_w_flag -t filter -A "$_akpm_chain" -m owner --uid-owner 0 -p tcp --dport 443 -m string --algo bm --string aad.invalid.test -j RETURN >/dev/null 2>&1 && _akpm_rc=0
            ;;
    esac
    while "$_akpm_bin" $_w_flag -t filter -D OUTPUT -j "$_akpm_chain" >/dev/null 2>&1; do :; done
    "$_akpm_bin" $_w_flag -t filter -F "$_akpm_chain" >/dev/null 2>&1 || true
    "$_akpm_bin" $_w_flag -t filter -X "$_akpm_chain" >/dev/null 2>&1 || true
    return "$_akpm_rc"
}

ad_killer_resolve_host() {
    _akrh_host="$1"
    [ -n "$_akrh_host" ] || return 1
    {
        getent ahostsv4 "$_akrh_host" 2>/dev/null | awk '{print $1}'
        nslookup "$_akrh_host" 2>/dev/null | awk '/^Address/ {a=$NF; sub(/#.*/,"",a); print a}'
        ping -c 1 -W 1 "$_akrh_host" 2>/dev/null | sed -n 's/^PING [^(]*(\([0-9.]*\)).*/\1/p'
    } 2>/dev/null \
        | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' \
        | grep -vE '^(0\.|127\.|255\.)' \
        | sort -u
}

ad_killer_add_ip_rule() {
    _akir_bin="$1"; _akir_uid="$2"; _akir_ip="$3"
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    if "$_akir_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akir_uid" -d "$_akir_ip" -j REJECT --reject-with icmp-port-unreachable >/dev/null 2>&1; then
        return 0
    fi
    "$_akir_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akir_uid" -d "$_akir_ip" -j DROP >/dev/null 2>&1
}

ad_killer_chain_alive() {
    [ -f "$AD_KILLER_STATUS_FILE" ] || return 1
    _aks_state=$(sed -n 's/^state=//p' "$AD_KILLER_STATUS_FILE" | head -n1)
    [ "$_aks_state" = "ACTIVE" ] || return 0
    _ak_v4_active=$(sed -n 's/^ipv4_active=//p' "$AD_KILLER_STATUS_FILE" | head -n1)
    _ak_v6_active=$(sed -n 's/^ipv6_active=//p' "$AD_KILLER_STATUS_FILE" | head -n1)
    
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"

    if [ "$_ak_v4_active" = "1" ]; then
        _akca_bin4=$(ad_killer_iptables_bin 4)
        [ -n "$_akca_bin4" ] || return 1
        "$_akca_bin4" $_w_flag -t filter -C OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1 || return 1
    fi
    if [ "$_ak_v6_active" = "1" ]; then
        _akca_bin6=$(ad_killer_iptables_bin 6)
        [ -n "$_akca_bin6" ] || return 1
        "$_akca_bin6" $_w_flag -t filter -C OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1 || return 1
    fi
    return 0
}

ad_killer_add_tcp_rule() {
    _akar_bin="$1"; _akar_uid="$2"; _akar_host="$3"
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    if "$_akar_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akar_uid" -p tcp --dport 443 -m string --algo bm --string "$_akar_host" -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
        return 0
    fi
    "$_akar_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akar_uid" -p tcp --dport 443 -m string --algo bm --string "$_akar_host" -j DROP >/dev/null 2>&1
}

ad_killer_add_quic_rule() {
    _akq_bin="$1"; _akq_uid="$2"
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    if "$_akq_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akq_uid" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable >/dev/null 2>&1; then
        return 0
    fi
    if "$_akq_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akq_uid" -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable >/dev/null 2>&1; then
        return 0
    fi
    if "$_akq_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akq_uid" -p udp --dport 443 -j REJECT >/dev/null 2>&1; then
        return 0
    fi
    "$_akq_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akq_uid" -p udp --dport 443 -j DROP >/dev/null 2>&1
}

AD_KILLER_DOH_IPV4="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 77.88.8.8 77.88.8.1 77.88.8.88 9.9.9.9 149.112.112.112 94.140.14.14 94.140.15.15"
AD_KILLER_DOH_IPV6="2001:4860:4860::8888 2001:4860:4860::8844 2606:4700:4700::1111 2606:4700:4700::1001 2a02:6b8::feed:0ff 2a02:6b8:0:1::feed:0ff 2620:fe::fe 2620:fe::9 2a10:50c0::ad1:ff 2a10:50c0::ad2:ff"

ad_killer_add_doh_bypass_rules() {
    _akd_bin="$1"; _akd_uid="$2"; _akd_family="${3:-4}"
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    _akd_failed=0
    if [ "$_akd_family" = "6" ]; then
        for _akd_ip in $AD_KILLER_DOH_IPV6; do
            for _akd_port in 443 853; do
                if ! "$_akd_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akd_uid" -d "$_akd_ip" -p tcp --dport "$_akd_port" -j REJECT --reject-with icmp6-port-unreachable >/dev/null 2>&1; then
                    "$_akd_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akd_uid" -d "$_akd_ip" -p tcp --dport "$_akd_port" -j DROP >/dev/null 2>&1 || _akd_failed=1
                fi
            done
        done
    else
        for _akd_ip in $AD_KILLER_DOH_IPV4; do
            for _akd_port in 443 853; do
                if ! "$_akd_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akd_uid" -d "$_akd_ip" -p tcp --dport "$_akd_port" -j REJECT --reject-with icmp-port-unreachable >/dev/null 2>&1; then
                    "$_akd_bin" $_w_flag -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akd_uid" -d "$_akd_ip" -p tcp --dport "$_akd_port" -j DROP >/dev/null 2>&1 || _akd_failed=1
                fi
            done
        done
    fi
    [ "$_akd_failed" -eq 0 ]
}

ad_killer_prepare_chain() {
    _akpc_bin="$1"
    aad_init_iptables_wait
    _w_flag=""
    [ "$AAD_IPTABLES_WAIT" = "-w 2" ] && _w_flag="-w 2"
    [ -n "$_akpc_bin" ] || return 1

    if "$_akpc_bin" $_w_flag -t filter -S "$AD_KILLER_CHAIN" >/dev/null 2>&1; then
        "$_akpc_bin" $_w_flag -t filter -F "$AD_KILLER_CHAIN" >/dev/null 2>&1 || return 1
    else
        "$_akpc_bin" $_w_flag -t filter -N "$AD_KILLER_CHAIN" >/dev/null 2>&1 || return 1
    fi
    # iptables-restore -n appends to existing user chains; clear our owned UID chains first.
    _akpc_subs=$("$_akpc_bin" $_w_flag -t filter -S 2>/dev/null | sed -n "s/^-N \(${AD_KILLER_CHAIN}_[0-9][0-9]*\)$/\1/p") || return 1
    for _akpc_sub in $_akpc_subs; do
        "$_akpc_bin" $_w_flag -t filter -F "$_akpc_sub" >/dev/null 2>&1 || return 1
    done
    # Remove old UID chains completely. Master is already empty, so there are
    # no AAD-owned references; iptables-restore -n will recreate only the
    # currently desired child chains. This prevents stale/duplicate chains.
    for _akpc_sub in $_akpc_subs; do
        "$_akpc_bin" $_w_flag -t filter -X "$_akpc_sub" >/dev/null 2>&1 || return 1
    done
    if ! "$_akpc_bin" $_w_flag -t filter -C OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1; then
        # Append once instead of constantly taking position 1 from other firewall modules.
        "$_akpc_bin" $_w_flag -t filter -A OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1 || {
            "$_akpc_bin" $_w_flag -t filter -F "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
            "$_akpc_bin" $_w_flag -t filter -X "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
            return 1
        }
    fi
    return 0
}

_reconcile_ad_surface_killer_unlocked() {
    _akr_reason="${1:-manual}"
    if ! ad_killer_enabled; then
        ad_killer_cleanup DISABLED "$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER disabled reason=$_akr_reason mode=$(read_component_mode) block_ads=$(read_bool_setting BLOCK_ADS 0) setting=$(read_bool_setting AD_SURFACE_KILLER 1)"
        return 0
    fi
    if [ ! -s "$AD_KILLER_TARGET_FILE" ]; then
        if [ -s "$AD_SURFACE_SCAN_FILE" ] && grep -q '|SUMMARY|.*|COMPLETE|' "$AD_SURFACE_SCAN_FILE" 2>/dev/null; then
            if ad_killer_build_targets_from_surface; then
                _akr_bootstrap_targets=$(grep -c . "$AD_KILLER_TARGET_FILE" 2>/dev/null)
                [ -n "$_akr_bootstrap_targets" ] || _akr_bootstrap_targets=0
                log "AD-KILLER targets bootstrapped=$_akr_bootstrap_targets from=last-complete-surface"
            fi
        fi
    fi
    [ -s "$AD_KILLER_TARGET_FILE" ] || {
        ad_killer_cleanup WAITING "no_targets:$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER waiting-targets reason=$_akr_reason file=$AD_KILLER_TARGET_FILE"
        return 0
    }

    _akr_uidmap=$(aad_mktemp_near "$DATA_DIR/.adkiller_uidmap")
    _akr_active=$(aad_mktemp_near "$DATA_DIR/.adkiller_active")
    [ -n "$_akr_uidmap" ] && [ -n "$_akr_active" ] || { rm -f "$_akr_uidmap" "$_akr_active" 2>/dev/null; return 1; }
    if ! ad_killer_uid_inventory > "$_akr_uidmap"; then
        log "AD-KILLER pending reason=$_akr_reason cause=uid_inventory_failed; existing firewall state preserved"
        rm -f "$_akr_uidmap" "$_akr_active" 2>/dev/null
        return 1
    fi
    awk -F'|' '
        FNR==NR {uid[$1 SUBSEP $2]=$3; next}
        {
            u=uid[$1 SUBSEP $2]
            if(u ~ /^[0-9]+$/) print $1 "|" $2 "|" u "|" $3 "|" $4
        }
    ' "$_akr_uidmap" "$AD_KILLER_TARGET_FILE" | sort -u > "$_akr_active"

    _akr_filtered=$(aad_mktemp_near "$DATA_DIR/.adkiller_filtered")
    _akr_hostmap=$(aad_mktemp_near "$DATA_DIR/.adkiller_allowed_hosts")
    [ -n "$_akr_filtered" ] && [ -n "$_akr_hostmap" ] || { rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null; return 1; }
    ad_killer_extract_host_map > "$_akr_hostmap"
    : > "$_akr_filtered"
    while IFS='|' read -r _akr_user _akr_pkg _akr_uid _akr_sdk _akr_host; do
        [ -n "$_akr_uid" ] || continue
        grep -Fxq -- "$_akr_sdk|$_akr_host" "$_akr_hostmap" 2>/dev/null || continue
        is_package_in_scope "$_akr_pkg" "$_akr_user" || continue
        is_category_whitelisted "$_akr_pkg" ADS && continue
        printf '%s|%s|%s|%s|%s\n' "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" >> "$_akr_filtered"
    done < "$_akr_active"
    sort -u "$_akr_filtered" -o "$_akr_filtered" 2>/dev/null || true
    _akr_targets=$(grep -c . "$_akr_filtered" 2>/dev/null); [ -n "$_akr_targets" ] || _akr_targets=0
    if [ "$_akr_targets" -eq 0 ]; then
        ad_killer_cleanup WAITING "no_active_targets:$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER waiting-active-targets reason=$_akr_reason"
        rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null
        return 0
    fi

    _akr4=$(ad_killer_iptables_bin 4); _akr6=$(ad_killer_iptables_bin 6)
    if [ -z "$_akr4" ] && [ -z "$_akr6" ]; then
        ad_killer_cleanup UNAVAILABLE "no_iptables:$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER unavailable reason=$_akr_reason cause=iptables_binary_missing"
        rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null
        return 0
    fi

    _akr_mode=$(read_setting AD_KILLER_MODE auto | tr '[:upper:]' '[:lower:]')
    case "$_akr_mode" in auto|string|ip) ;; *) _akr_mode=auto ;; esac
    _akr_ip_optin=$(read_bool_setting AD_KILLER_IP_FALLBACK 0)

    _akr_owner_ok=0; _akr_string_ok=0
    [ -n "$_akr4" ] && ad_killer_probe_match "$_akr4" owner && _akr_owner_ok=1
    [ -n "$_akr4" ] && [ "$_akr_owner_ok" = "1" ] && ad_killer_probe_match "$_akr4" string && _akr_string_ok=1
    if [ "$_akr_owner_ok" != "1" ] && [ -n "$_akr6" ]; then
        ad_killer_probe_match "$_akr6" owner && _akr_owner_ok=1
        [ "$_akr_owner_ok" = "1" ] && ad_killer_probe_match "$_akr6" string && _akr_string_ok=1
    fi

    if [ "$_akr_owner_ok" != "1" ]; then
        ad_killer_cleanup UNAVAILABLE "xt_owner_missing:$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER unavailable reason=$_akr_reason cause=xt_owner_unsupported (kernel lacks CONFIG_NETFILTER_XT_MATCH_OWNER)"
        rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null
        return 0
    fi

    _akr_active_mode=""
    case "$_akr_mode" in
        string) [ "$_akr_string_ok" = "1" ] && _akr_active_mode=string ;;
        ip)     _akr_active_mode=ip ;;
        auto)
            if [ "$_akr_string_ok" = "1" ]; then
                _akr_active_mode=string
            elif [ "$_akr_ip_optin" = "1" ]; then
                _akr_active_mode=ip
            fi
            ;;
    esac

    if [ -z "$_akr_active_mode" ]; then
        ad_killer_cleanup UNAVAILABLE "xt_string_missing:$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER unavailable reason=$_akr_reason cause=xt_string_unsupported mode=$_akr_mode ip_fallback=$_akr_ip_optin (kernel lacks CONFIG_NETFILTER_XT_MATCH_STRING; set AD_KILLER_IP_FALLBACK=1 to use resolved-IP mode instead)"
        rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null
        return 0
    fi

    _akr4ok=0; _akr6ok=0
    [ -n "$_akr4" ] && ad_killer_prepare_chain "$_akr4" && _akr4ok=1
    if [ "$_akr_active_mode" = "string" ]; then
        [ -n "$_akr6" ] && ad_killer_prepare_chain "$_akr6" && _akr6ok=1
    fi
    if [ "$_akr4ok" != "1" ] && [ "$_akr6ok" != "1" ]; then
        ad_killer_cleanup UNAVAILABLE "chain_setup_failed:$_akr_reason" || { log "AD-KILLER cleanup pending reason=$_akr_reason"; return 1; }
        log "AD-KILLER unavailable reason=$_akr_reason cause=chain_setup_failed mode=$_akr_active_mode"
        rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null
        return 0
    fi
    log "AD-KILLER mode=$_akr_active_mode requested=$_akr_mode xt_owner=$_akr_owner_ok xt_string=$_akr_string_ok ipv4=$_akr4ok ipv6=$_akr6ok min_confidence=$(ad_killer_min_confidence)"

    _akr_force_tcp=$(read_bool_setting AD_KILLER_FORCE_TCP 0)
    _akr_rules4=0; _akr_rules6=0; _akr_failed=0; _akr_quic_uids=""
    ad_killer_log_rotate
    printf 'timestamp|family|action|user|package|uid|sdk|host|result\n' > "$AD_KILLER_LOG_FILE" 2>/dev/null || true
    chmod 600 "$AD_KILLER_LOG_FILE" 2>/dev/null || true

    _akr_rules=$(aad_mktemp_near "$DATA_DIR/.adkiller_rules")
    [ -n "$_akr_rules" ] || { rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null; return 1; }
    awk -F'|' '{k=$3 "|" $5; if (!seen[k]++) print}' "$_akr_filtered" > "$_akr_rules"
    _akr_unique=$(grep -c . "$_akr_rules" 2>/dev/null); [ -n "$_akr_unique" ] || _akr_unique=0

    _akr_ipmap=""
    if [ "$_akr_active_mode" = "ip" ]; then
        _akr_ipmap=$(aad_mktemp_near "$DATA_DIR/.adkiller_ipmap")
        if [ -n "$_akr_ipmap" ]; then
            : > "$_akr_ipmap"
            while IFS='|' read -r _akr_u _akr_p _akr_uid _akr_sdk _akr_host; do
                [ -n "$_akr_uid" ] && [ -n "$_akr_host" ] || continue
                for _akr_ip in $(ad_killer_resolve_host "$_akr_host"); do
                    printf '%s|%s\n' "$_akr_uid" "$_akr_ip" >> "$_akr_ipmap"
                done
            done < "$_akr_rules"
            sort -u "$_akr_ipmap" -o "$_akr_ipmap" 2>/dev/null || true
        fi
    fi

    _akr_batch4=0; _akr_batch6=0
    _akr_restore4=$(ad_killer_restore_bin 4); _akr_restore6=$(ad_killer_restore_bin 6)
    if [ "$_akr4ok" = "1" ] && ad_killer_apply_batch "$_akr4" "$_akr_restore4" "$_akr_rules" "$_akr_active_mode" "$_akr_ipmap"; then
        _akr_batch4=1
    fi
    if [ "$_akr6ok" = "1" ] && [ "$_akr_active_mode" != "ip" ] && \
       ad_killer_apply_batch "$_akr6" "$_akr_restore6" "$_akr_rules" "$_akr_active_mode" "$_akr_ipmap"; then
        _akr_batch6=1
    fi

    if [ "$_akr_batch4" = "1" ] || [ "$_akr_batch6" = "1" ]; then
        if [ "$_akr_active_mode" = "ip" ]; then
            _akr_applied=$(grep -c . "$_akr_ipmap" 2>/dev/null); [ -n "$_akr_applied" ] || _akr_applied=0
        else
            _akr_applied="$_akr_unique"
        fi
        [ "$_akr_batch4" = "1" ] && _akr_rules4="$_akr_applied"
        [ "$_akr_batch6" = "1" ] && _akr_rules6="$_akr_applied"
        _akr_uidchains=$(awk -F'|' '{if(!s[$3]++) n++} END{print n+0}' "$_akr_rules" 2>/dev/null)
        awk -F'|' -v ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" \
            '{printf "%s|batch|BLOCK|%s|%s|%s|%s|%s|OK\n", ts, $1, $2, $3, $4, $5}' "$_akr_rules" >> "$AD_KILLER_LOG_FILE" 2>/dev/null || true
        log "AD-KILLER batch applied mode=$_akr_active_mode ipv4=$_akr_batch4 ipv6=$_akr_batch6 uid_chains=$_akr_uidchains rules_per_family=$_akr_applied"
        [ "$_akr_batch4" = "1" ] && _akr4ok=0
        [ "$_akr_batch6" = "1" ] && _akr6ok=0
        _akr_quic_uids=$(awk -F'|' '{if(!s[$3]++) printf "%s ", $3}' "$_akr_rules" 2>/dev/null)
    fi
    rm -f "$_akr_ipmap" 2>/dev/null

    while IFS='|' read -r _akr_user _akr_pkg _akr_uid _akr_sdk _akr_host; do
        [ -n "$_akr_uid" ] && [ -n "$_akr_host" ] || continue
        if [ "$_akr_active_mode" = "ip" ]; then
            _akr_ips=$(ad_killer_resolve_host "$_akr_host")
            if [ -z "$_akr_ips" ]; then
                _akr_failed=$((_akr_failed + 1))
                ad_killer_log_record ipv4 RESOLVE "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" NO_ADDRESS
                continue
            fi
            for _akr_ip in $_akr_ips; do
                if [ "$_akr4ok" = "1" ] && ad_killer_add_ip_rule "$_akr4" "$_akr_uid" "$_akr_ip"; then
                    _akr_rules4=$((_akr_rules4 + 1))
                    ad_killer_log_record ipv4 BLOCK "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host->$_akr_ip" OK
                else
                    _akr_failed=$((_akr_failed + 1))
                    ad_killer_log_record ipv4 BLOCK "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host->$_akr_ip" FAILED
                fi
            done
        else
            if [ "$_akr4ok" = "1" ]; then
                if ad_killer_add_tcp_rule "$_akr4" "$_akr_uid" "$_akr_host"; then
                    _akr_rules4=$((_akr_rules4 + 1)); ad_killer_log_record ipv4 BLOCK "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" OK
                else
                    _akr_failed=$((_akr_failed + 1)); ad_killer_log_record ipv4 BLOCK "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" FAILED
                fi
            fi
            if [ "$_akr6ok" = "1" ]; then
                if ad_killer_add_tcp_rule "$_akr6" "$_akr_uid" "$_akr_host"; then
                    _akr_rules6=$((_akr_rules6 + 1)); ad_killer_log_record ipv6 BLOCK "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" OK
                else
                    _akr_failed=$((_akr_failed + 1)); ad_killer_log_record ipv6 BLOCK "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" FAILED
                fi
            fi
        fi
        case " $_akr_quic_uids " in *" $_akr_uid "*) ;; *) _akr_quic_uids="$_akr_quic_uids $_akr_uid" ;; esac
    done < "$_akr_rules"

    _akr_quic=0
    if [ "$_akr_force_tcp" = "1" ]; then
        for _akr_uid in $_akr_quic_uids; do
            if [ "$_akr4ok" = "1" ] || [ "$_akr_batch4" = "1" ]; then
                if ad_killer_add_quic_rule "$_akr4" "$_akr_uid"; then _akr_rules4=$((_akr_rules4 + 1)); else _akr_failed=$((_akr_failed + 1)); fi
            fi
            if [ "$_akr6ok" = "1" ] || [ "$_akr_batch6" = "1" ]; then
                if ad_killer_add_quic_rule "$_akr6" "$_akr_uid"; then _akr_rules6=$((_akr_rules6 + 1)); else _akr_failed=$((_akr_failed + 1)); fi
            fi
            _akr_quic=$((_akr_quic + 1))
        done
    fi

    _akr_block_doh=$(read_bool_setting BLOCK_DOH_BYPASS 1)
    if [ "$_akr_block_doh" = "1" ]; then
        for _akr_uid in $_akr_quic_uids; do
            if [ "$_akr4ok" = "1" ] || [ "$_akr_batch4" = "1" ]; then
                ad_killer_add_doh_bypass_rules "$_akr4" "$_akr_uid" 4 || _akr_failed=$((_akr_failed + 1))
            fi
            if [ "$_akr6ok" = "1" ] || [ "$_akr_batch6" = "1" ]; then
                ad_killer_add_doh_bypass_rules "$_akr6" "$_akr_uid" 6 || _akr_failed=$((_akr_failed + 1))
            fi
        done
        log "AD-KILLER anti-doh rules attempted for $(printf '%s\n' "$_akr_quic_uids" | wc -w | tr -d ' ') target UIDs failures=$_akr_failed"
    fi
    _akr_pkgs=$(awk -F'|' '{k=$1 "|" $2; if(!seen[k]++) n++} END{print n+0}' "$_akr_filtered" 2>/dev/null); [ -n "$_akr_pkgs" ] || _akr_pkgs=0
    _ak_v4_active=0; _ak_v6_active=0
    [ "$_akr_rules4" -gt 0 ] 2>/dev/null && _ak_v4_active=1
    [ "$_akr_rules6" -gt 0 ] 2>/dev/null && _ak_v6_active=1
    _akr_status_tmp="$AD_KILLER_STATUS_FILE.tmp.$$"
    {
        if [ "$_akr_failed" -gt 0 ] 2>/dev/null; then printf 'state=PENDING\n'; else printf 'state=ACTIVE\n'; fi
        printf 'reason=%s\n' "$_akr_reason"
        printf 'mode=%s\n' "$_akr_active_mode"
        printf 'min_confidence=%s\n' "$(ad_killer_min_confidence)"
        printf 'targets=%s\n' "$_akr_targets"
        printf 'unique_uid_hosts=%s\n' "$_akr_unique"
        printf 'packages_users=%s\n' "$_akr_pkgs"
        printf 'ipv4_rules=%s\n' "$_akr_rules4"
        printf 'ipv6_rules=%s\n' "$_akr_rules6"
        printf 'ipv4_active=%s\n' "$_ak_v4_active"
        printf 'ipv6_active=%s\n' "$_ak_v6_active"
        printf 'force_tcp=%s\n' "$_akr_force_tcp"
        printf 'quic_uids=%s\n' "$_akr_quic"
        printf 'failed=%s\n' "$_akr_failed"
        printf 'updated_ms=%s\n' "$(aad_now_ms)"
    } > "$_akr_status_tmp" 2>/dev/null || true
    chmod 600 "$_akr_status_tmp" 2>/dev/null || true
    mv -f "$_akr_status_tmp" "$AD_KILLER_STATUS_FILE" 2>/dev/null || rm -f "$_akr_status_tmp" 2>/dev/null
    log "AD-KILLER-SUMMARY reason=$_akr_reason mode=$_akr_active_mode targets=$_akr_targets unique_uid_hosts=$_akr_unique packages/users=$_akr_pkgs ipv4_rules=$_akr_rules4 ipv6_rules=$_akr_rules6 force_tcp=$_akr_force_tcp quic_uids=$_akr_quic failed=$_akr_failed target_file=$AD_KILLER_TARGET_FILE"
    rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" "$_akr_rules" 2>/dev/null
    [ "$_akr_failed" -eq 0 ] || return 1
    return 0
}

aad_proc_starttime() {
    _apst_pid="$1"
    case "$_apst_pid" in ''|*[!0-9]*) return 1 ;; esac
    _apst_raw=$(cat "/proc/$_apst_pid/stat" 2>/dev/null) || return 1
    [ -n "$_apst_raw" ] || return 1
    _apst_tail=${_apst_raw##*') '}
    [ "$_apst_tail" = "$_apst_raw" ] && return 1
    printf '%s\n' "$_apst_tail" | awk '{print $20}'
}

ad_killer_lock() {
    _aklock_tries=0
    _aklock_self_start=$(aad_proc_starttime "$$")
    [ -n "$_aklock_self_start" ] || _aklock_self_start=unknown
    while ! mkdir "$AD_KILLER_LOCK_DIR" 2>/dev/null; do
        _aklock_owner=$(cat "$AD_KILLER_LOCK_DIR/pid" 2>/dev/null)
        _aklock_start=$(cat "$AD_KILLER_LOCK_DIR/starttime" 2>/dev/null)
        _aklock_live_start=""
        case "$_aklock_owner" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$_aklock_owner" 2>/dev/null; then
                    _aklock_live_start=$(aad_proc_starttime "$_aklock_owner")
                    if [ -n "$_aklock_start" ] && [ "$_aklock_start" = "$_aklock_live_start" ]; then
                        return 1
                    fi
                fi
                ;;
        esac
        log "AD-KILLER-LOCK stale owner=${_aklock_owner:-unknown} saved_start=${_aklock_start:-unknown} live_start=${_aklock_live_start:-dead}; removing"
        rm -rf "$AD_KILLER_LOCK_DIR" 2>/dev/null || return 1
        _aklock_tries=$((_aklock_tries + 1))
        [ "$_aklock_tries" -lt 3 ] || return 1
    done
    printf '%s\n' "$$" > "$AD_KILLER_LOCK_DIR/pid" 2>/dev/null
    printf '%s\n' "$_aklock_self_start" > "$AD_KILLER_LOCK_DIR/starttime" 2>/dev/null
    return 0
}

ad_killer_unlock() {
    [ -d "$AD_KILLER_LOCK_DIR" ] || return 0
    _akul_owner=$(cat "$AD_KILLER_LOCK_DIR/pid" 2>/dev/null)
    _akul_start=$(cat "$AD_KILLER_LOCK_DIR/starttime" 2>/dev/null)
    _akul_self_start=$(aad_proc_starttime "$$")
    if [ "$_akul_owner" = "$$" ] && [ -n "$_akul_start" ] && [ "$_akul_start" = "$_akul_self_start" ]; then
        rm -rf "$AD_KILLER_LOCK_DIR" 2>/dev/null || true
    fi
}

reconcile_ad_surface_killer() {
    _akw_reason="${1:-manual}"
    if ! ad_killer_lock; then
        log "AD-KILLER reconcile skipped busy reason=$_akw_reason"
        return 0
    fi
    _reconcile_ad_surface_killer_unlocked "$_akw_reason"
    _akw_rc=$?
    ad_killer_unlock
    return "$_akw_rc"
}

cap_multiuser_ready() {
    [ "${CAP_PACKAGE_LIST_HAS_USER:-0}" = "1" ] || return 1
    [ "${CAP_PM_DISABLE_HAS_USER:-0}" = "1" ] || return 1
    [ "${CAP_PM_ENABLE_HAS_USER:-0}" = "1" ] || return 1
    [ "${CAP_PM_DEFAULT_HAS_USER:-0}" = "1" ] || return 1
    return 0
}

list_user_ids_checked() {
    if [ "$(read_bool_setting SCAN_ALL_USERS 1)" != "1" ]; then
        printf '0\n'
        return 0
    fi

    _luic_raw=$(cap_list_users_raw 2>/dev/null)
    _luic_rc=$?
    [ "$_luic_rc" -eq 0 ] && [ -n "$_luic_raw" ] || {
        log "USER-LIST-FAILED: backend unavailable; preserving previous multi-user state"
        return 1
    }
    _luic_ids=$(printf '%s\n' "$_luic_raw" | awk '
        /UserInfo\{[0-9]+/ {
            match($0, /UserInfo\{[0-9]+/)
            val=substr($0, RSTART+9, RLENGTH-9)
            print val
        }
        /id=[0-9]+/ {
            match($0, /id=[0-9]+/)
            val=substr($0, RSTART+3, RLENGTH-3)
            print val
        }
        /^[[:space:]]*User [0-9]+:/ {
            match($0, /User [0-9]+/)
            val=substr($0, RSTART+5, RLENGTH-5)
            print val
        }
    ' | sort -nu)
    [ -n "$_luic_ids" ] || {
        log "USER-LIST-FAILED: successful command produced no parseable user IDs"
        return 1
    }

    if ! cap_multiuser_ready; then
        _luic_count=$(printf '%s\n' "$_luic_ids" | grep -c . 2>/dev/null)
        if [ "$_luic_count" -eq 1 ] && [ "$_luic_ids" = "0" ]; then
            printf '0\n'
            return 0
        fi
        log "CAPABILITY: secondary users exist but selected package-manager commands lack --user; refusing incomplete scan"
        return 1
    fi
    printf '%s\n' "$_luic_ids"
    return 0
}

list_user_ids() {
    list_user_ids_checked
}

aad_capture_packages_for_user() {
    _acpfu_user="$1"; _acpfu_third="$2"; _acpfu_want_vc="$3"; _acpfu_out="$4"
    [ -n "$_acpfu_out" ] || return 1
    : > "$_acpfu_out" 2>/dev/null || return 1

    _acpfu_raw=$(cap_list_packages_raw "$_acpfu_user" "$_acpfu_third" "$_acpfu_want_vc" "" 2>/dev/null)
    _acpfu_rc=$?
    if [ "$_acpfu_rc" -ne 0 ] && [ "$_acpfu_want_vc" = "1" ]; then
        _acpfu_raw=$(cap_list_packages_raw "$_acpfu_user" "$_acpfu_third" 0 "" 2>/dev/null)
        _acpfu_rc=$?
        _acpfu_want_vc=0
    fi
    [ "$_acpfu_rc" -eq 0 ] || { rm -f "$_acpfu_out" 2>/dev/null; return 1; }

    if [ "$_acpfu_want_vc" = "1" ]; then
        printf '%s\n' "$_acpfu_raw" | awk '
            /^package:/ {
                p=$1; sub(/^package:/,"",p); v="0";
                for(i=2;i<=NF;i++) if($i ~ /^versionCode:/){v=$i; sub(/^versionCode:/,"",v)}
                if (p!="") print p "|" v
            }' > "$_acpfu_out" 2>/dev/null || { rm -f "$_acpfu_out"; return 1; }
    else
        printf '%s\n' "$_acpfu_raw" | sed 's/^package://; s/[[:space:]].*$//; /^$/d; s/$/|0/' > "$_acpfu_out" 2>/dev/null || { rm -f "$_acpfu_out"; return 1; }
    fi
    return 0
}

list_packages_for_user() {
    user="$1"
    third=0
    [ "$(read_include_system_apps)" != "1" ] && third=1
    _lpfu_tmp=$(aad_mktemp_near "$DATA_DIR/.packages_u${user}")
    [ -n "$_lpfu_tmp" ] || return 1
    if aad_capture_packages_for_user "$user" "$third" 1 "$_lpfu_tmp"; then
        cat "$_lpfu_tmp" 2>/dev/null
        rm -f "$_lpfu_tmp" 2>/dev/null
        return 0
    fi
    rm -f "$_lpfu_tmp" 2>/dev/null
    return 1
}

list_all_package_state() {
    _laps_ok_users="$DATA_DIR/.users_desired_snapshot_ok"
    _laps_out=$(aad_mktemp_near "$DATA_DIR/.all_desired")
    [ -n "$_laps_out" ] || return 1
    : > "$_laps_ok_users" 2>/dev/null || { rm -f "$_laps_out"; return 1; }
    : > "$_laps_out" 2>/dev/null || { rm -f "$_laps_out"; return 1; }
    _laps_users=$(list_user_ids_checked) || { rm -f "$_laps_out"; log "SNAPSHOT-DESIRED-FAILED: user enumeration unavailable"; return 1; }
    _laps_failed=0
    for user in $_laps_users; do
        _laps_tmp=$(aad_mktemp_near "$DATA_DIR/.desired_u${user}")
        [ -n "$_laps_tmp" ] || { _laps_failed=1; continue; }
        _laps_third=0
        [ "$(read_include_system_apps)" != "1" ] && _laps_third=1
        if aad_capture_packages_for_user "$user" "$_laps_third" 1 "$_laps_tmp"; then
            echo "$user" >> "$_laps_ok_users" 2>/dev/null || _laps_failed=1
            while IFS='|' read -r pkg vc; do
                [ -n "$pkg" ] && echo "$user|$pkg|${vc:-0}" >> "$_laps_out"
            done < "$_laps_tmp"
        else
            _laps_failed=1
            log "SNAPSHOT-DESIRED-FAILED user=$user; previous candidate/ownership generation must be preserved"
        fi
        rm -f "$_laps_tmp" 2>/dev/null
    done
    if [ "$_laps_failed" -ne 0 ]; then
        rm -f "$_laps_out" 2>/dev/null
        return 1
    fi
    awk -F'|' '!seen[$1,$2]++' "$_laps_out"
    _laps_rc=$?
    rm -f "$_laps_out" 2>/dev/null
    return "$_laps_rc"
}

list_all_installed_package_keys() {
    _lapk_ok_users="$DATA_DIR/.users_snapshot_ok"
    _lapk_out=$(aad_mktemp_near "$DATA_DIR/.all_installed")
    [ -n "$_lapk_out" ] || return 1
    : > "$_lapk_ok_users" 2>/dev/null || { rm -f "$_lapk_out"; return 1; }
    : > "$_lapk_out" 2>/dev/null || { rm -f "$_lapk_out"; return 1; }
    _lapk_users=$(list_user_ids_checked) || { rm -f "$_lapk_out"; log "SNAPSHOT-INSTALLED-FAILED: user enumeration unavailable"; return 1; }
    _lapk_failed=0
    for user in $_lapk_users; do
        _lapk_tmp=$(aad_mktemp_near "$DATA_DIR/.installed_u${user}")
        [ -n "$_lapk_tmp" ] || { _lapk_failed=1; continue; }
        if aad_capture_packages_for_user "$user" 0 0 "$_lapk_tmp"; then
            echo "$user" >> "$_lapk_ok_users" 2>/dev/null || _lapk_failed=1
            while IFS='|' read -r pkg _vc; do
                [ -n "$pkg" ] && echo "$user|$pkg" >> "$_lapk_out"
            done < "$_lapk_tmp"
        else
            _lapk_failed=1
            log "SNAPSHOT-INSTALLED-FAILED user=$user; previous candidate/ownership generation must be preserved"
        fi
        rm -f "$_lapk_tmp" 2>/dev/null
    done
    if [ "$_lapk_failed" -ne 0 ]; then
        rm -f "$_lapk_out" 2>/dev/null
        return 1
    fi
    sort -u "$_lapk_out"
    _lapk_rc=$?
    rm -f "$_lapk_out" 2>/dev/null
    return "$_lapk_rc"
}

disable_component_smart() {
    user="$1"
    comp="$2"
    preserve_state=$(get_saved_original_state "$user" "$comp")
    if [ -z "$preserve_state" ]; then
        preserve_state=$(aad_get_component_override_state_checked "$user" "$comp" 2>/dev/null) || return 1
    fi
    cap_disable_component "$user" "$comp" "$preserve_state" >/dev/null 2>&1
}

set_component_state_smart() {
    user="$1"
    comp="$2"
    state="$3"
    cap_set_component_state "$user" "$comp" "$state" >/dev/null 2>&1
}

AAD_PKG_DUMP_CACHE_DIR="${AAD_PKG_DUMP_CACHE_DIR:-$DATA_DIR/.pkgdump}"

aad_pkg_dump_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

aad_package_dump_cache_reset() {
    rm -rf "$AAD_PKG_DUMP_CACHE_DIR" 2>/dev/null
}

aad_package_dump_invalidate() {
    [ -n "${1:-}" ] || return 0
    rm -f "$AAD_PKG_DUMP_CACHE_DIR/$(aad_pkg_dump_key "$1")" 2>/dev/null
    return 0
}

aad_package_dump_cached() {
    _apd_pkg="$1"
    [ -n "$_apd_pkg" ] || return 1
    if [ "${AAD_PKG_DUMP_CACHE:-1}" = "1" ] && mkdir -p "$AAD_PKG_DUMP_CACHE_DIR" 2>/dev/null; then
        chmod 700 "$AAD_PKG_DUMP_CACHE_DIR" 2>/dev/null || true
        _apd_file="$AAD_PKG_DUMP_CACHE_DIR/$(aad_pkg_dump_key "$_apd_pkg")"
        if [ ! -s "$_apd_file" ]; then
            _apd_tmp="$_apd_file.tmp.$$"
            if cap_package_dump "$_apd_pkg" > "$_apd_tmp" 2>/dev/null && [ -s "$_apd_tmp" ]; then
                chmod 600 "$_apd_tmp" 2>/dev/null || true
                mv -f "$_apd_tmp" "$_apd_file" 2>/dev/null || rm -f "$_apd_tmp" 2>/dev/null
            else
                rm -f "$_apd_tmp" 2>/dev/null
            fi
        fi
        if [ -s "$_apd_file" ]; then
            cat "$_apd_file"
            return 0
        fi
    fi
    cap_package_dump "$_apd_pkg"
}

aad_get_component_override_state_checked() {
    _agcos_user="$1"
    _agcos_comp="$2"
    _agcos_pkg=${_agcos_comp%%/*}
    _agcos_cls=${_agcos_comp#*/}
    case "$_agcos_cls" in
        .*) _agcos_full="$_agcos_pkg$_agcos_cls" ;;
        *) _agcos_full="$_agcos_cls" ;;
    esac

    _agcos_dump=$(aad_package_dump_cached "$_agcos_pkg" 2>/dev/null)
    _agcos_rc=$?
    [ "$_agcos_rc" -eq 0 ] && [ -n "$_agcos_dump" ] || return 1

    _agcos_state=$(printf '%s\n' "$_agcos_dump" | awk -v uid="$_agcos_user" -v full="$_agcos_full" -v short="$_agcos_cls" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s); return s}
        /^[ \t]*User [0-9]+:/ {
            line=$0; gsub(/^[ \t]*/,"",line)
            if (line ~ ("^User " uid ":")) {inuser=1; founduser=1; sec=""; next}
            if (inuser) exit
        }
        !inuser {next}
        /^[ \t]*enabledComponents:/ {sec="enabled"; next}
        /^[ \t]*disabledComponents:/ {sec="disabled"; next}
        /^[ \t]*[A-Za-z][A-Za-z0-9_-]*:/ {sec=""}
        sec!="" {
            x=trim($0)
            if (x==full || x==short) {state=sec; print state; emitted=1; exit}
        }
        END {
            if (founduser && !emitted) print "default"
        }
    ')
    [ -n "$_agcos_state" ] || _agcos_state="default"
    printf '%s\n' "$_agcos_state" | head -n1
    return 0
}

state_record_exists() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] && awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {found=1; exit} END{exit !found}' "$COMPONENT_STATE"
}

ensure_original_state() {
    user="$1"; comp="$2"
    state_record_exists "$user" "$comp" && return 0
    original=$(aad_get_component_override_state_checked "$user" "$comp" 2>/dev/null) || {
        log "STATE-SAVE-PENDING u$user: $comp reason=original_state_read_failed"
        return 1
    }
    aad_db_lock "$STATE_DB_LOCK" || { log "STATE-LOCK-FAILED save u$user: $comp"; return 1; }
    if ! state_record_exists "$user" "$comp"; then
        printf '%s|%s|%s|disabled\n' "$user" "$comp" "$original" >> "$COMPONENT_STATE"
        log "STATE-SAVE u$user: $comp -> $original"
    fi
    aad_db_unlock "$STATE_DB_LOCK"
}

get_saved_original_state() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] || return
    awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {print $3; exit}' "$COMPONENT_STATE"
}

get_saved_applied_state() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] || return
    awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {print ($4!=""?$4:"disabled"); exit}' "$COMPONENT_STATE"
}

remove_state_record() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] || return 0
    aad_db_lock "$STATE_DB_LOCK" || { log "STATE-LOCK-FAILED remove u$user: $comp"; return 1; }
    tmp=$(aad_mktemp_near "$COMPONENT_STATE")
    if [ -n "$tmp" ] && awk -F'|' -v u="$user" -v c="$comp" '!( $1==u && $2==c )' "$COMPONENT_STATE" > "$tmp" 2>/dev/null; then
        if ! mv -f "$tmp" "$COMPONENT_STATE" 2>/dev/null; then
            log "STATE-COMMIT-FAILED remove u$user: $comp temp=$tmp"
            rm -f "$tmp" 2>/dev/null
            aad_db_unlock "$STATE_DB_LOCK"
            return 1
        fi
    else
        log "STATE-REWRITE-FAILED remove u$user: $comp"
        [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
        aad_db_unlock "$STATE_DB_LOCK"
        return 1
    fi
    aad_db_unlock "$STATE_DB_LOCK"
    return 0
}

restore_original_state() {
    user="$1"; comp="$2"
    original=$(get_saved_original_state "$user" "$comp")
    case "$original" in
        enabled) ;;
        *) original=default ;;
    esac
    applied=$(get_saved_applied_state "$user" "$comp")
    [ -n "$applied" ] || applied=disabled
    current=$(aad_get_component_override_state_checked "$user" "$comp" 2>/dev/null) || {
        log "RESTORE-PENDING u$user: $comp reason=current_state_read_failed"
        return 1
    }
    if [ "$current" != "$applied" ]; then
        log "RESTORE-PRESERVE u$user: $comp current=$current differs_from_module=$applied"
        remove_state_record "$user" "$comp"
        return 0
    fi
    if set_component_state_smart "$user" "$comp" "$original"; then
        log "RESTORE u$user: $comp -> $original"
        remove_state_record "$user" "$comp"
        return 0
    fi
    if [ "${CAP_LAST_STATE_NONEXISTENT:-0}" = "1" ]; then
        log "RESTORE-DROP u$user: $comp not in package; dropped obsolete record"
        remove_state_record "$user" "$comp"
        return 0
    fi
    log "RESTORE-FAILED u$user: $comp -> $original"
    return 1
}

cap_list_packages_with_paths_raw() {
    user="$1"
    _pkg_backend="${PACKAGE_LIST_BACKEND:-${CAP_PACKAGE_LIST_BACKEND:-cmd}}"
    _pkg_has_user="${PACKAGE_LIST_HAS_USER:-${CAP_PACKAGE_LIST_HAS_USER:-1}}"
    [ "$_pkg_backend" != "none" ] || return 1
    [ "$_pkg_has_user" = "1" ] || [ "$user" = "0" ] || return 1
    case "$_pkg_backend:$_pkg_has_user" in
        cmd:1) cmd package list packages -f --user "$user" 2>/dev/null ;;
        cmd:0) cmd package list packages -f 2>/dev/null ;;
        pm:1) pm list packages -f --user "$user" 2>/dev/null ;;
        pm:0) pm list packages -f 2>/dev/null ;;
        *) return 1 ;;
    esac
}

build_apk_path_inventory() {
    out_file="$1"
    : > "$out_file" || return 1
    _bapi_users=$(list_user_ids_checked) || _bapi_users="0"
    for inv_user in $_bapi_users; do
        _bapi_raw=$(aad_mktemp_near "$DATA_DIR/.path_inventory_u${inv_user}")
        [ -n "$_bapi_raw" ] || continue
        if cap_list_packages_with_paths_raw "$inv_user" > "$_bapi_raw" 2>/dev/null; then
            while IFS= read -r line; do
                case "$line" in
                    package:*=*)
                        body=${line#package:}
                        inv_pkg=${body##*=}
                        inv_apk=${body%="$inv_pkg"}
                        inv_apk=${inv_apk%=}
                        [ -n "$inv_pkg" ] && [ -n "$inv_apk" ] && printf '%s|%s|%s\n' "$inv_user" "$inv_pkg" "$inv_apk"
                        ;;
                esac
            done < "$_bapi_raw" >> "$out_file"
        fi
        rm -f "$_bapi_raw" 2>/dev/null
    done
    if [ ! -s "$out_file" ]; then
        return 1
    fi
    sort -u "$out_file" -o "$out_file" 2>/dev/null || return 1
    return 0
}

cap_package_paths_readonly() {
    user="${1:-0}"; pkg="$2"
    [ -n "$pkg" ] || return 0
    if [ -n "${AAD_APK_PATH_CACHE:-}" ] && [ -f "$AAD_APK_PATH_CACHE" ] && [ -s "$AAD_APK_PATH_CACHE" ]; then
        _cached_paths=$(awk -F'|' -v u="$user" -v p="$pkg" '$1==u && $2==p {print $3}' "$AAD_APK_PATH_CACHE" 2>/dev/null)
        if [ -n "$_cached_paths" ]; then
            printf '%s\n' "$_cached_paths"
            return 0
        fi
    fi

    _direct_paths=$(cmd package path --user "$user" "$pkg" 2>/dev/null)
    [ -n "$_direct_paths" ] || _direct_paths=$(pm path --user "$user" "$pkg" 2>/dev/null)
    [ -n "$_direct_paths" ] || _direct_paths=$(cmd package path "$pkg" 2>/dev/null)
    [ -n "$_direct_paths" ] || _direct_paths=$(pm path "$pkg" 2>/dev/null)
    printf '%s\n' "$_direct_paths" | sed -n 's/^package://p' | awk 'NF && !seen[$0]++ {print}'
}

cap_activity_component_exists() {
    user="$1"; comp="$2"
    cls=${comp#*/}
    out=$(cmd package query-activities --components --query-flags 0x200 --user "$user" -n "$comp" 2>/dev/null)
    printf '%s\n' "$out" | grep -Fq "/$cls" 2>/dev/null && return 0
    out=$(cmd package resolve-activity --components --query-flags 0x200 --user "$user" -n "$comp" 2>/dev/null)
    printf '%s\n' "$out" | grep -Fq "/$cls" 2>/dev/null
}

extract_compiled_manifest_readonly() {
    apk="$1"; out="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -p "$apk" AndroidManifest.xml > "$out" 2>/dev/null && [ -s "$out" ] && return 0
    fi
    if aad_have_bb; then
        aad_bb unzip -p "$apk" AndroidManifest.xml > "$out" 2>/dev/null && [ -s "$out" ] && return 0
    fi
    : > "$out"
    return 1
}

manifest_class_strings() {
    manifest="$1"
    meta_file="$2"
    [ -n "$meta_file" ] || meta_file=/dev/null

    _mcs_od=""
    if command -v od >/dev/null 2>&1; then
        _mcs_od="od"
    elif aad_have_bb; then
        _mcs_od="bb"
    fi
    if [ -z "$_mcs_od" ]; then
        printf 'parser=none|encoding=UNKNOWN|strings=0|tokens=0|valid=0\n' > "$meta_file"
        return 1
    fi

    if [ "$_mcs_od" = "bb" ]; then
        aad_bb od -An -tu1 -v "$manifest" 2>/dev/null
    else
        od -An -tu1 -v "$manifest" 2>/dev/null
    fi | awk -v meta="$meta_file" '
        function u16(p) { return b[p] + 256*b[p+1] }
        function u32(p) { return b[p] + 256*b[p+1] + 65536*b[p+2] + 16777216*b[p+3] }
        function len8(p,    v,n) {
            v=b[p]
            if (v>=128) { n=((v-128)*256)+b[p+1]; LSKIP=2 }
            else { n=v; LSKIP=1 }
            return n
        }
        function len16(p,    v,n) {
            v=u16(p)
            if (v>=32768) { n=((v-32768)*65536)+u16(p+2); LSKIP=4 }
            else { n=v; LSKIP=2 }
            return n
        }
        function emit_tokens(str,    rest,tok) {
            rest=str
            while (match(rest, /[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)+/)) {
                tok=substr(rest,RSTART,RLENGTH)
                if (!seen[tok]++) { print tok; token_count++ }
                rest=substr(rest,RSTART+RLENGTH)
            }
        }
        function ascii_utf8(p,n,    i,c,out) {
            out=""
            for (i=0; i<n; i++) {
                c=b[p+i]
                if (c>=32 && c<=126) out=out sprintf("%c",c)
                else out=out " "
            }
            return out
        }
        function ascii_utf16(p,n,    i,c,out) {
            out=""
            for (i=0; i<n; i++) {
                c=u16(p+2*i)
                if (c>=32 && c<=126) out=out sprintf("%c",c)
                else out=out " "
            }
            return out
        }
        function parse_pool(pos,    hsz,sz,count,flags,start,idxbase,i,rel,p,u16n,u8n,str) {
            hsz=u16(pos+2); sz=u32(pos+4)
            if (hsz<28 || sz<hsz || pos+sz-1>n) return 0
            count=u32(pos+8); flags=u32(pos+16); start=u32(pos+20)
            if (count<0 || count>200000 || start<hsz || start>=sz) return 0
            idxbase=pos+hsz
            if (idxbase+4*count-1>pos+sz-1) return 0
            isutf8=(int(flags/256)%2)==1
            encoding=(isutf8 ? "UTF8" : "UTF16")
            string_count=count
            for (i=0; i<count; i++) {
                rel=u32(idxbase+4*i)
                p=pos+start+rel
                if (p<pos || p>pos+sz-1) continue
                if (isutf8) {
                    u16n=len8(p); p+=LSKIP
                    u8n=len8(p); p+=LSKIP
                    if (u8n<0 || p+u8n>pos+sz) continue
                    str=ascii_utf8(p,u8n)
                } else {
                    u16n=len16(p); p+=LSKIP
                    if (u16n<0 || p+2*u16n>pos+sz) continue
                    str=ascii_utf16(p,u16n)
                }
                emit_tokens(str)
            }
            return 1
        }
        function fallback_ascii(    i,c,buf) {
            buf=""
            for (i=1;i<=n;i++) {
                c=b[i]
                if (c>=32 && c<=126) buf=buf sprintf("%c",c)
                else { if (length(buf)>=4) emit_tokens(buf); buf="" }
            }
            if (length(buf)>=4) emit_tokens(buf)
        }
        function fallback_utf16le(    i,c,buf) {
            buf=""
            for (i=1;i<n;i+=2) {
                c=u16(i)
                if (c>=32 && c<=126) buf=buf sprintf("%c",c)
                else { if (length(buf)>=4) emit_tokens(buf); buf="" }
            }
            if (length(buf)>=4) emit_tokens(buf)
        }
        { for (i=1;i<=NF;i++) b[++n]=$i+0 }
        END {
            valid=0; parser="axml"
            if (n>=8 && u16(1)==3) {
                root_h=u16(3); root_sz=u32(5)
                if (root_h>=8 && root_sz<=n && root_sz>=root_h) {
                    pos=1+root_h
                    while (pos+7<=root_sz) {
                        type=u16(pos); sz=u32(pos+4)
                        if (sz<8 || pos+sz-1>root_sz) break
                        if (type==1 && parse_pool(pos)) { valid=1; break }
                        pos+=sz
                    }
                }
            }
            if (!valid) {
                parser="text-fallback"; encoding="TEXT"
                fallback_ascii(); fallback_utf16le()
            }
            printf "parser=%s|encoding=%s|strings=%d|tokens=%d|valid=%d\n", parser, (encoding==""?"UNKNOWN":encoding), string_count+0, token_count+0, valid > meta
            close(meta)
        }
    ' | sort -u
}

manifest_sdk_fingerprints() {
    classes="$1"
    [ -f "$classes" ] && [ -f "$RULES_FILE" ] || return 0
    awk -v target='[ADS_SDK_FINGERPRINT]' '
        FNR==NR {
            line=$0
            sub(/\r$/, "", line)
            if (line==target) {inside=1; next}
            if (inside && line ~ /^\[/) {inside=0}
            if (!inside) next
            sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)
            if (line=="" || line ~ /^#/) next
            sep=index(line,"|")
            if (!sep) next
            label=substr(line,1,sep-1)
            pattern=substr(line,sep+1)
            sub(/^[ \t]+/,"",label); sub(/[ \t]+$/,"",label)
            sub(/^[ \t]+/,"",pattern); sub(/[ \t]+$/,"",pattern)
            if (label!="" && pattern!="") {
                labels[++n]=label
                patterns[n]=tolower(pattern)
            }
            next
        }
        {
            cls=$0
            lc=tolower(cls)
            for (i=1; i<=n; i++) {
                if (!seen[labels[i]] && index(lc,patterns[i])>0) {
                    print "SDK|" labels[i] "|" cls
                    seen[labels[i]]=1
                }
            }
        }
    ' "$RULES_FILE" "$classes"
}

aad_surface_rules_hash() {
    [ -f "$RULES_FILE" ] || { printf 'none\n'; return; }
    awk '
        function trim(s){sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
        /^\[ADS_SURFACE_FINGERPRINT\]$/ {inside=1; print; next}
        /^\[ADS_SURFACE_RESOURCE_VIEW\]$/ {inside=1; print; next}
        /^\[/ {inside=0}
        inside {
            line=$0; sub(/\r$/, "", line); line=trim(line)
            if (line!="" && line !~ /^#/) print line
        }
    ' "$RULES_FILE" 2>/dev/null | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

aad_surface_cache_rulesig_compatible() {
    _ascrc_sig="$1"; _ascrc_current="$2"
    [ "$_ascrc_sig" = "$_ascrc_current" ] && return 0
    if [ "$_ascrc_current" = "3191335439:7119" ]; then
        case "$_ascrc_sig" in
            1259099589:7907|2768747396:7908) return 0 ;;
        esac
    fi
    return 1
}

apk_parse_unzip_listing() {
    awk '
        /^[[:space:]]*[0-9]+[[:space:]]+[0-9-]+[[:space:]]+[0-9:]+[[:space:]]+/ {
            print $NF
        }
    '
}

apk_list_entries_readonly() {
    apk="$1"
    if command -v unzip >/dev/null 2>&1; then
        if unzip -Z1 "$apk" 2>/dev/null; then
            return 0
        fi
        unzip -l "$apk" 2>/dev/null | apk_parse_unzip_listing && return 0
    fi
    if aad_have_bb; then
        aad_bb unzip -l "$apk" 2>/dev/null | apk_parse_unzip_listing && return 0
    fi
    return 1
}

extract_apk_entry_readonly() {
    apk="$1"; entry="$2"; out="$3"
    if command -v unzip >/dev/null 2>&1; then
        unzip -p "$apk" "$entry" > "$out" 2>/dev/null && [ -s "$out" ] && return 0
    fi
    if aad_have_bb; then
        aad_bb unzip -p "$apk" "$entry" > "$out" 2>/dev/null && [ -s "$out" ] && return 0
    fi
    : > "$out"
    return 1
}

apk_extract_entries_concat() {
    _aec_apk="$1"; _aec_pattern="$2"; _aec_out="$3"
    : > "$_aec_out"
    if command -v unzip >/dev/null 2>&1; then
        unzip -p "$_aec_apk" "$_aec_pattern" >> "$_aec_out" 2>/dev/null || true
    fi
    if [ ! -s "$_aec_out" ] && aad_have_bb; then
        aad_bb unzip -p "$_aec_apk" "$_aec_pattern" >> "$_aec_out" 2>/dev/null || true
    fi
    [ -s "$_aec_out" ] && return 0

    _aec_tmp=$(aad_mktemp_near "$DATA_DIR/.apk_entry")
    [ -n "$_aec_tmp" ] || return 1
    apk_list_entries_readonly "$_aec_apk" 2>/dev/null | while IFS= read -r _aec_entry; do
        [ -n "$_aec_entry" ] || continue
        case "$_aec_entry" in
            $_aec_pattern) ;;
            *) continue ;;
        esac
        if extract_apk_entry_readonly "$_aec_apk" "$_aec_entry" "$_aec_tmp"; then
            cat "$_aec_tmp" >> "$_aec_out" 2>/dev/null || true
        fi
    done
    rm -f "$_aec_tmp" 2>/dev/null
    [ -s "$_aec_out" ]
}

aad_surface_legacy_cache_gc() {
    [ -d "$MANIFEST_CACHE_DIR" ] || return 0
    find "$MANIFEST_CACHE_DIR" -type f 2>/dev/null | while IFS= read -r f; do
        case "$f" in
            *.surface.dex.tokens|*.surface.res.tokens|*.surface.dexstat|*.surface.resstat|*.surface.hits|*.surface.rulesig|*.surface2.dexstat|*.surface2.resstat|*.surface2.hits|*.surface2.rulesig|*.surface3.dexstat|*.surface3.resstat|*.surface3.hits|*.surface3.rulesig)
                rm -f "$f" 2>/dev/null || true
                ;;
        esac
    done
}

surface_benchmark_grep_backend() {
    _sbg_backend="$1"; _sbg_raw="$2"; _sbg_pattern="$3"
    [ -s "$_sbg_raw" ] && [ -n "$_sbg_pattern" ] || { echo -1; return; }
    _sbg_start=$(aad_now_ms)
    _sbg_n=0
    while [ "$_sbg_n" -lt 2 ]; do
        case "$_sbg_backend" in
            grep) grep -aFq -- "$_sbg_pattern" "$_sbg_raw" 2>/dev/null || true ;;
            busybox) aad_bb grep -aFq -- "$_sbg_pattern" "$_sbg_raw" 2>/dev/null || true ;;
            *) echo -1; return ;;
        esac
        _sbg_n=$((_sbg_n + 1))
    done
    _sbg_end=$(aad_now_ms)
    aad_elapsed_ms "$_sbg_start" "$_sbg_end"
}

surface_exact_file_has() {
    _sefh_raw="$1"; _sefh_pattern="$2"
    [ -f "$_sefh_raw" ] && [ -n "$_sefh_pattern" ] || return 1
    case "${AAD_SURFACE_GREP_BACKEND:-grep}" in
        busybox) aad_bb grep -aFq -- "$_sefh_pattern" "$_sefh_raw" 2>/dev/null ;;
        *) grep -aFq -- "$_sefh_pattern" "$_sefh_raw" 2>/dev/null ;;
    esac
}

surface_exact_match_file() {
    _sem_raw="$1"; _sem_patterns="$2"; _sem_out="$3"
    : > "$_sem_out"
    [ -s "$_sem_raw" ] && [ -s "$_sem_patterns" ] || return 0
    while IFS= read -r _sem_pattern; do
        [ -n "$_sem_pattern" ] || continue
        if surface_exact_file_has "$_sem_raw" "$_sem_pattern"; then
            printf '%s\n' "$_sem_pattern" >> "$_sem_out"
        fi
    done < "$_sem_patterns"
    sort -u "$_sem_out" -o "$_sem_out" 2>/dev/null || true
    return 0
}

surface_strings_dump() {
    _ssd_raw="$1"; _ssd_out="$2"; _ssd_backend="$3"
    : > "$_ssd_out"
    [ -s "$_ssd_raw" ] || return 0
    case "$_ssd_backend" in
        strings)
            strings -n 4 "$_ssd_raw" > "$_ssd_out" 2>/dev/null
            ;;
        busybox_strings)
            aad_bb strings -n 4 "$_ssd_raw" > "$_ssd_out" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

surface_benchmark_strings_backend() {
    _sbs_backend="$1"; _sbs_probe="$2"; _sbs_out="$3"
    _sbs_start=$(aad_now_ms)
    surface_strings_dump "$_sbs_probe" "$_sbs_out" "$_sbs_backend" >/dev/null 2>&1 || { echo -1; return; }
    _sbs_end=$(aad_now_ms)
    aad_elapsed_ms "$_sbs_start" "$_sbs_end"
}

surface_strings_backend_complete() {
    _sbc_backend="$1"; _sbc_probe="$2"; _sbc_patterns="$3"; _sbc_strings="$4"; _sbc_hits="$5"
    surface_strings_dump "$_sbc_probe" "$_sbc_strings" "$_sbc_backend" >/dev/null 2>&1 || return 1
    surface_exact_match_file "$_sbc_strings" "$_sbc_patterns" "$_sbc_hits"
    _sbc_expected=$(grep -c . "$_sbc_patterns" 2>/dev/null); [ -n "$_sbc_expected" ] || _sbc_expected=0
    _sbc_got=$(grep -c . "$_sbc_hits" 2>/dev/null); [ -n "$_sbc_got" ] || _sbc_got=0
    [ "$_sbc_expected" -gt 0 ] && [ "$_sbc_got" -eq "$_sbc_expected" ]
}

aad_surface_prepare_matchers() {
    [ -f "$RULES_FILE" ] || return 1
    AAD_SURFACE_DEX_PATTERNS="$DATA_DIR/.surface_dex_patterns.$$"
    AAD_SURFACE_DEX_MAP="$DATA_DIR/.surface_dex_map.$$"
    AAD_SURFACE_RES_PATTERNS="$DATA_DIR/.surface_res_patterns.$$"
    AAD_SURFACE_RES_MAP="$DATA_DIR/.surface_res_map.$$"
    : > "$AAD_SURFACE_DEX_PATTERNS"; : > "$AAD_SURFACE_DEX_MAP"
    : > "$AAD_SURFACE_RES_PATTERNS"; : > "$AAD_SURFACE_RES_MAP"

    awk -v dexsec='[ADS_SURFACE_FINGERPRINT]' -v ressec='[ADS_SURFACE_RESOURCE_VIEW]' \
        -v dp="$AAD_SURFACE_DEX_PATTERNS" -v dm="$AAD_SURFACE_DEX_MAP" \
        -v rp="$AAD_SURFACE_RES_PATTERNS" -v rm="$AAD_SURFACE_RES_MAP" '
        function trim(v) {sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v); return v}
        $0==dexsec {section="DEX"; next}
        $0==ressec {section="RESOURCE"; next}
        /^\[/ {section=""; next}
        section=="" {next}
        {
            line=$0; sub(/\r$/, "", line); line=trim(line)
            if (line=="" || line ~ /^#/) next
            n=split(line,a,"|"); if (n<4) next
            surface=trim(a[1]); sdk=trim(a[2]); strategy=trim(a[3]); pattern=trim(a[4])
            if (surface=="" || sdk=="" || strategy=="" || pattern=="") next
            if (section=="DEX") {
                dexkey=pattern
                if (index(pattern,".")>0) {
                    gsub(/\./,"/",dexkey)
                    dexkey="L" dexkey ";"
                }
                print dexkey >> dp
                print dexkey "|" surface "|" sdk "|" strategy "|" pattern >> dm
            } else {
                print pattern >> rp
                print pattern "|" surface "|" sdk "|" strategy "|" pattern >> rm
            }
        }
        END {close(dp); close(dm); close(rp); close(rm)}
    ' "$RULES_FILE" 2>/dev/null
    sort -u "$AAD_SURFACE_DEX_PATTERNS" -o "$AAD_SURFACE_DEX_PATTERNS" 2>/dev/null || true
    sort -u "$AAD_SURFACE_RES_PATTERNS" -o "$AAD_SURFACE_RES_PATTERNS" 2>/dev/null || true
    chmod 600 "$AAD_SURFACE_DEX_PATTERNS" "$AAD_SURFACE_DEX_MAP" "$AAD_SURFACE_RES_PATTERNS" "$AAD_SURFACE_RES_MAP" 2>/dev/null || true

    _asp_grep_probe="$DATA_DIR/.surface_grep_probe.$$"
    _asp_first=$(sed -n '1p' "$AAD_SURFACE_DEX_PATTERNS" 2>/dev/null)
    {
        echo "irrelevant"
        echo "$_asp_first"
        echo "irrelevant2"
    } > "$_asp_grep_probe" 2>/dev/null
    AAD_SURFACE_GREP_SYSTEM_MS=-1
    AAD_SURFACE_GREP_BUSYBOX_MS=-1
    _asp_sys_ok=0; _asp_bb_ok=0
    if [ -n "$_asp_first" ] && grep -aFq -- "$_asp_first" "$_asp_grep_probe" 2>/dev/null; then
        _asp_sys_ok=1
        AAD_SURFACE_GREP_SYSTEM_MS=$(surface_benchmark_grep_backend grep "$_asp_grep_probe" "$_asp_first")
    fi
    if [ -n "$_asp_first" ] && aad_have_bb && \
       aad_bb grep -aFq -- "$_asp_first" "$_asp_grep_probe" 2>/dev/null; then
        _asp_bb_ok=1
        AAD_SURFACE_GREP_BUSYBOX_MS=$(surface_benchmark_grep_backend busybox "$_asp_grep_probe" "$_asp_first")
    fi
    if [ "$_asp_sys_ok" = "1" ] && [ "$_asp_bb_ok" = "1" ]; then
        if [ "$AAD_SURFACE_GREP_BUSYBOX_MS" -lt "$AAD_SURFACE_GREP_SYSTEM_MS" ] 2>/dev/null; then
            AAD_SURFACE_GREP_BACKEND=busybox
        else
            AAD_SURFACE_GREP_BACKEND=grep
        fi
    elif [ "$_asp_sys_ok" = "1" ]; then
        AAD_SURFACE_GREP_BACKEND=grep
    elif [ "$_asp_bb_ok" = "1" ]; then
        AAD_SURFACE_GREP_BACKEND=busybox
    else
        AAD_SURFACE_GREP_BACKEND=grep
    fi
    rm -f "$_asp_grep_probe" 2>/dev/null

    _asp_probe="$DATA_DIR/.surface_strings_probe.$$"
    _asp_strings="$DATA_DIR/.surface_strings_probe_out.$$"
    _asp_hits="$DATA_DIR/.surface_strings_probe_hits.$$"
    : > "$_asp_probe"; : > "$_asp_strings"; : > "$_asp_hits"
    while IFS= read -r _asp_pattern; do
        [ -n "$_asp_pattern" ] || continue
        printf '\001%s\000' "$_asp_pattern" >> "$_asp_probe"
    done < "$AAD_SURFACE_DEX_PATTERNS"
    AAD_SURFACE_SELFTEST_EXPECTED=$(grep -c . "$AAD_SURFACE_DEX_PATTERNS" 2>/dev/null)
    [ -n "$AAD_SURFACE_SELFTEST_EXPECTED" ] || AAD_SURFACE_SELFTEST_EXPECTED=0
    AAD_SURFACE_SELFTEST_MATCHED=0
    AAD_SURFACE_STRINGS_SYSTEM_MS=-1
    AAD_SURFACE_STRINGS_BUSYBOX_MS=-1
    _asp_strings_ok=0; _asp_bbstrings_ok=0

    if command -v strings >/dev/null 2>&1 && \
       surface_strings_backend_complete strings "$_asp_probe" "$AAD_SURFACE_DEX_PATTERNS" "$_asp_strings" "$_asp_hits"; then
        _asp_strings_ok=1
        AAD_SURFACE_STRINGS_SYSTEM_MS=$(surface_benchmark_strings_backend strings "$_asp_probe" "$_asp_strings")
    fi
    if aad_have_bb && aad_bb strings --help >/dev/null 2>&1 && \
       surface_strings_backend_complete busybox_strings "$_asp_probe" "$AAD_SURFACE_DEX_PATTERNS" "$_asp_strings" "$_asp_hits"; then
        _asp_bbstrings_ok=1
        AAD_SURFACE_STRINGS_BUSYBOX_MS=$(surface_benchmark_strings_backend busybox_strings "$_asp_probe" "$_asp_strings")
    fi

    if [ "$_asp_strings_ok" = "1" ] && [ "$_asp_bbstrings_ok" = "1" ]; then
        if [ "$AAD_SURFACE_STRINGS_BUSYBOX_MS" -lt "$AAD_SURFACE_STRINGS_SYSTEM_MS" ] 2>/dev/null; then
            AAD_SURFACE_DEX_BACKEND=busybox_strings
        else
            AAD_SURFACE_DEX_BACKEND=strings
        fi
        AAD_SURFACE_SELFTEST_MATCHED="$AAD_SURFACE_SELFTEST_EXPECTED"
    elif [ "$_asp_strings_ok" = "1" ]; then
        AAD_SURFACE_DEX_BACKEND=strings
        AAD_SURFACE_SELFTEST_MATCHED="$AAD_SURFACE_SELFTEST_EXPECTED"
    elif [ "$_asp_bbstrings_ok" = "1" ]; then
        AAD_SURFACE_DEX_BACKEND=busybox_strings
        AAD_SURFACE_SELFTEST_MATCHED="$AAD_SURFACE_SELFTEST_EXPECTED"
    else
        AAD_SURFACE_DEX_BACKEND=raw_exact
        AAD_SURFACE_SELFTEST_MATCHED="$AAD_SURFACE_SELFTEST_EXPECTED"
    fi
    rm -f "$_asp_probe" "$_asp_strings" "$_asp_hits" 2>/dev/null

    export AAD_SURFACE_DEX_PATTERNS AAD_SURFACE_DEX_MAP AAD_SURFACE_RES_PATTERNS AAD_SURFACE_RES_MAP \
           AAD_SURFACE_GREP_BACKEND AAD_SURFACE_GREP_SYSTEM_MS AAD_SURFACE_GREP_BUSYBOX_MS \
           AAD_SURFACE_DEX_BACKEND AAD_SURFACE_STRINGS_SYSTEM_MS AAD_SURFACE_STRINGS_BUSYBOX_MS \
           AAD_SURFACE_SELFTEST_EXPECTED AAD_SURFACE_SELFTEST_MATCHED
    return 0
}

aad_surface_cleanup_matchers() {
    rm -f "${AAD_SURFACE_DEX_PATTERNS:-}" "${AAD_SURFACE_DEX_MAP:-}" \
          "${AAD_SURFACE_RES_PATTERNS:-}" "${AAD_SURFACE_RES_MAP:-}" 2>/dev/null
    unset AAD_SURFACE_DEX_PATTERNS AAD_SURFACE_DEX_MAP AAD_SURFACE_RES_PATTERNS AAD_SURFACE_RES_MAP \
          AAD_SURFACE_GREP_BACKEND AAD_SURFACE_GREP_SYSTEM_MS AAD_SURFACE_GREP_BUSYBOX_MS \
          AAD_SURFACE_DEX_BACKEND AAD_SURFACE_STRINGS_SYSTEM_MS AAD_SURFACE_STRINGS_BUSYBOX_MS \
          AAD_SURFACE_SELFTEST_EXPECTED AAD_SURFACE_SELFTEST_MATCHED
}

surface_map_matches() {
    _smm_matched="$1"; _smm_map="$2"; _smm_source="$3"
    [ -s "$_smm_matched" ] && [ -s "$_smm_map" ] || return 0
    awk -F'|' -v src="$_smm_source" '
        FNR==NR {wanted[$0]=1; next}
        ($1 in wanted) {
            key=src "|" $2 "|" $3 "|" $4 "|" $5
            if (!seen[key]++) print key
        }
    ' "$_smm_matched" "$_smm_map"
}

surface_grep_file_matches() {
    _sgf_raw="$1"; _sgf_patterns="$2"; _sgf_out="$3"
    surface_exact_match_file "$_sgf_raw" "$_sgf_patterns" "$_sgf_out"
}

surface_dex_stream_matches() {
    _sdm_apk="$1"; _sdm_patterns="$2"; _sdm_out="$3"
    : > "$_sdm_out"
    [ -s "$_sdm_patterns" ] || return 0
    _sdm_raw=$(aad_mktemp_near "$DATA_DIR/.surface_dex_raw")
    _sdm_text=$(aad_mktemp_near "$DATA_DIR/.surface_dex_strings")
    [ -n "$_sdm_raw" ] && [ -n "$_sdm_text" ] || {
        rm -f "$_sdm_raw" "$_sdm_text" 2>/dev/null
        return 1
    }
    : > "$_sdm_raw"; : > "$_sdm_text"
    apk_extract_entries_concat "$_sdm_apk" 'classes*.dex' "$_sdm_raw" || true
    if [ -s "$_sdm_raw" ]; then
        case "${AAD_SURFACE_DEX_BACKEND:-raw_exact}" in
            strings|busybox_strings)
                if surface_strings_dump "$_sdm_raw" "$_sdm_text" "$AAD_SURFACE_DEX_BACKEND" && [ -s "$_sdm_text" ]; then
                    surface_exact_match_file "$_sdm_text" "$_sdm_patterns" "$_sdm_out"
                else
                    surface_exact_match_file "$_sdm_raw" "$_sdm_patterns" "$_sdm_out"
                fi
                ;;
            *)
                surface_exact_match_file "$_sdm_raw" "$_sdm_patterns" "$_sdm_out"
                ;;
        esac
    fi
    rm -f "$_sdm_raw" "$_sdm_text" 2>/dev/null
    return 0
}

surface_extract_dex_hits() {
    _sed_apk="$1"; _sed_hits="$2"; _sed_stat="$3"
    _sed_dex_files=$(apk_list_entries_readonly "$_sed_apk" | awk '/^classes([0-9]+)?\.dex$/ {n++} END{print n+0}' 2>/dev/null)
    case "$_sed_dex_files" in ''|*[!0-9]*) _sed_dex_files=0 ;; esac
    _sed_matched=$(aad_mktemp_near "$DATA_DIR/.surface_dex_match")
    [ -n "$_sed_matched" ] || { printf '%s|0\n' "$_sed_dex_files" > "$_sed_stat"; return 0; }
    : > "$_sed_matched"

    if [ "$_sed_dex_files" -gt 0 ]; then
        surface_dex_stream_matches "$_sed_apk" "$AAD_SURFACE_DEX_PATTERNS" "$_sed_matched" || true
        surface_map_matches "$_sed_matched" "$AAD_SURFACE_DEX_MAP" DEX >> "$_sed_hits"
    fi
    _sed_matched_count=$(grep -c . "$_sed_matched" 2>/dev/null)
    case "$_sed_matched_count" in ''|*[!0-9]*) _sed_matched_count=0 ;; esac
    printf '%s|%s\n' "$_sed_dex_files" "$_sed_matched_count" > "$_sed_stat"
    rm -f "$_sed_matched" 2>/dev/null
}

surface_extract_layout_hits() {
    _sel_apk="$1"; _sel_hits="$2"; _sel_stat="$3"
    _sel_layout_files=$(apk_list_entries_readonly "$_sel_apk" | awk '/^res\/layout[^\/]*\/.*\.xml$/ {n++} END{print n+0}' 2>/dev/null)
    case "$_sel_layout_files" in ''|*[!0-9]*) _sel_layout_files=0 ;; esac
    _sel_raw=$(aad_mktemp_near "$DATA_DIR/.surface_layout_raw")
    _sel_stripped=$(aad_mktemp_near "$DATA_DIR/.surface_layout_stripped")
    _sel_matched=$(aad_mktemp_near "$DATA_DIR/.surface_layout_match")
    if [ -z "$_sel_raw" ] || [ -z "$_sel_stripped" ] || [ -z "$_sel_matched" ]; then
        rm -f "$_sel_raw" "$_sel_stripped" "$_sel_matched" 2>/dev/null
        printf '%s|0\n' "$_sel_layout_files" > "$_sel_stat"
        return 0
    fi
    : > "$_sel_raw"; : > "$_sel_stripped"; : > "$_sel_matched"
    if [ "$_sel_layout_files" -gt 0 ]; then
        apk_extract_entries_concat "$_sel_apk" 'res/layout*/*.xml' "$_sel_raw" || true
        if [ -s "$_sel_raw" ]; then
            surface_grep_file_matches "$_sel_raw" "$AAD_SURFACE_RES_PATTERNS" "$_sel_matched" || true
            tr -d '\000' < "$_sel_raw" > "$_sel_stripped" 2>/dev/null || : > "$_sel_stripped"
            _sel_more=$(aad_mktemp_near "$DATA_DIR/.surface_layout_more")
            if [ -n "$_sel_more" ]; then
                surface_grep_file_matches "$_sel_stripped" "$AAD_SURFACE_RES_PATTERNS" "$_sel_more" || true
                cat "$_sel_more" >> "$_sel_matched" 2>/dev/null
                rm -f "$_sel_more" 2>/dev/null
            fi
            sort -u "$_sel_matched" -o "$_sel_matched" 2>/dev/null || true
            surface_map_matches "$_sel_matched" "$AAD_SURFACE_RES_MAP" RESOURCE >> "$_sel_hits"
        fi
    fi
    _sel_matched_count=$(grep -c . "$_sel_matched" 2>/dev/null)
    case "$_sel_matched_count" in ''|*[!0-9]*) _sel_matched_count=0 ;; esac
    printf '%s|%s\n' "$_sel_layout_files" "$_sel_matched_count" > "$_sel_stat"
    rm -f "$_sel_raw" "$_sel_stripped" "$_sel_matched" 2>/dev/null
}

ad_surface_emit_hits() {
    user="$1"; pkg="$2"; apk="$3"; cache_state="$4"; hits="$5"; stamp="$6"
    [ -s "$hits" ] || return 0
    awk -F'|' -v stamp="$stamp" -v user="$user" -v pkg="$pkg" -v apk="$apk" -v cache="$cache_state" '
        {
            line[NR]=$0
            have[$2 SUBSEP $3 SUBSEP $1]=1
        }
        END {
            for (i=1; i<=NR; i++) {
                split(line[i],a,"|")
                src=a[1]; surface=a[2]; sdk=a[3]; strategy=a[4]; evidence=a[5]
                k=surface SUBSEP sdk
                if (have[k SUBSEP "DEX"] && have[k SUBSEP "RESOURCE"]) confidence="MULTI_EVIDENCE"
                else if (src=="RESOURCE") confidence="LAYOUT_CONFIRMED"
                else confidence="CAPABILITY"
                printf "%s|HIT|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|0\n", stamp,user,pkg,apk,src,surface,sdk,strategy,evidence,confidence,cache
            }
        }
    ' "$hits" >> "$AD_SURFACE_SCAN_FILE"
}

scan_ad_surfaces_for_apk() {
    user="$1"; pkg="$2"; vc="$3"; apk="$4"
    [ -f "$apk" ] || return 0
    _aas_apk_start_ms=$(aad_now_ms)
    stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
    cache_state=MISS
    cache_prefix=""; apk_sig=""
    surface_hash="${AAD_SURFACE_RULES_HASH:-}"
    [ -n "$surface_hash" ] || surface_hash=$(aad_surface_rules_hash)

    dex_stat=$(aad_mktemp_near "$DATA_DIR/.surface_dex_stat")
    res_stat=$(aad_mktemp_near "$DATA_DIR/.surface_res_stat")
    hits=$(aad_mktemp_near "$DATA_DIR/.surface_hits")
    [ -n "$dex_stat" ] && [ -n "$res_stat" ] && [ -n "$hits" ] || {
        rm -f "$dex_stat" "$res_stat" "$hits" 2>/dev/null
        return 0
    }
    : > "$dex_stat"; : > "$res_stat"; : > "$hits"

    if [ "${AAD_MANIFEST_CACHE_ENABLED:-0}" = "1" ]; then
        apk_sig=$(aad_apk_stat_signature "$apk" 2>/dev/null)
        cache_prefix=$(aad_manifest_cache_prefix "$user" "$pkg" "$vc" "$apk")
        if [ -n "$apk_sig" ] && [ -n "$cache_prefix" ] && [ -f "$cache_prefix.sig" ] && \
           [ "$(cat "$cache_prefix.sig" 2>/dev/null)" = "$apk_sig" ] && \
           [ -f "$cache_prefix.surface4.rulesig" ] && [ -f "$cache_prefix.surface4.hits" ] && \
           [ -f "$cache_prefix.surface4.dexstat" ] && [ -f "$cache_prefix.surface4.resstat" ]; then
            _aas_cached_surface_sig=$(cat "$cache_prefix.surface4.rulesig" 2>/dev/null)
            if aad_surface_cache_rulesig_compatible "$_aas_cached_surface_sig" "$surface_hash"; then
                cp "$cache_prefix.surface4.hits" "$hits" 2>/dev/null || : > "$hits"
                cp "$cache_prefix.surface4.dexstat" "$dex_stat" 2>/dev/null || : > "$dex_stat"
                cp "$cache_prefix.surface4.resstat" "$res_stat" 2>/dev/null || : > "$res_stat"
                cache_state=FULL_HIT
                if [ "$_aas_cached_surface_sig" != "$surface_hash" ]; then
                    printf '%s\n' "$surface_hash" > "$cache_prefix.surface4.rulesig.tmp.$$" 2>/dev/null
                    chmod 600 "$cache_prefix.surface4.rulesig.tmp.$$" 2>/dev/null || true
                    mv -f "$cache_prefix.surface4.rulesig.tmp.$$" "$cache_prefix.surface4.rulesig" 2>/dev/null || rm -f "$cache_prefix.surface4.rulesig.tmp.$$" 2>/dev/null
                fi
            else
                cache_state=RULE_RESCAN
            fi
        fi
    fi

    if [ "$cache_state" != "FULL_HIT" ]; then
        : > "$hits"; : > "$dex_stat"; : > "$res_stat"
        surface_extract_dex_hits "$apk" "$hits" "$dex_stat"
        need_layout=$(awk -F'|' '$1=="DEX" && $2 ~ /^(BANNER|BANNER_MREC|MREC|NATIVE|INLINE)$/ {found=1} END{print found+0}' "$hits" 2>/dev/null)
        if [ "$need_layout" = "1" ]; then
            surface_extract_layout_hits "$apk" "$hits" "$res_stat"
        else
            printf '0|0\n' > "$res_stat"
        fi
        sort -u "$hits" -o "$hits" 2>/dev/null || true

        if [ "${AAD_MANIFEST_CACHE_ENABLED:-0}" = "1" ] && [ -n "$cache_prefix" ] && [ -n "$apk_sig" ]; then
            cache_dir=${cache_prefix%/*}; mkdir -p "$cache_dir" 2>/dev/null
            printf '%s\n' "$apk_sig" > "$cache_prefix.sig.tmp.$$" 2>/dev/null
            chmod 600 "$cache_prefix.sig.tmp.$$" 2>/dev/null || true
            mv -f "$cache_prefix.sig.tmp.$$" "$cache_prefix.sig" 2>/dev/null || rm -f "$cache_prefix.sig.tmp.$$" 2>/dev/null
            aad_manifest_cache_commit_file "$dex_stat" "$cache_prefix.surface4.dexstat" >/dev/null 2>&1 || true
            aad_manifest_cache_commit_file "$res_stat" "$cache_prefix.surface4.resstat" >/dev/null 2>&1 || true
            aad_manifest_cache_commit_file "$hits" "$cache_prefix.surface4.hits" >/dev/null 2>&1 || true
            printf '%s\n' "$surface_hash" > "$cache_prefix.surface4.rulesig.tmp.$$" 2>/dev/null
            chmod 600 "$cache_prefix.surface4.rulesig.tmp.$$" 2>/dev/null || true
            mv -f "$cache_prefix.surface4.rulesig.tmp.$$" "$cache_prefix.surface4.rulesig" 2>/dev/null || rm -f "$cache_prefix.surface4.rulesig.tmp.$$" 2>/dev/null
        fi
    fi

    dex_files=0; dex_matches=0; layout_files=0; layout_matches=0
    if [ -s "$dex_stat" ]; then
        IFS='|' read -r dex_files dex_matches < "$dex_stat" 2>/dev/null || true
    fi
    if [ -s "$res_stat" ]; then
        IFS='|' read -r layout_files layout_matches < "$res_stat" 2>/dev/null || true
    fi
    case "$dex_files" in ''|*[!0-9]*) dex_files=0 ;; esac
    case "$dex_matches" in ''|*[!0-9]*) dex_matches=0 ;; esac
    case "$layout_files" in ''|*[!0-9]*) layout_files=0 ;; esac
    case "$layout_matches" in ''|*[!0-9]*) layout_matches=0 ;; esac
    hit_count=$(grep -c . "$hits" 2>/dev/null); [ -n "$hit_count" ] || hit_count=0
    _aas_apk_end_ms=$(aad_now_ms); _aas_apk_elapsed=$(aad_elapsed_ms "$_aas_apk_start_ms" "$_aas_apk_end_ms")
    printf '%s|APK|%s|%s|%s|APK|-|-|-|dex_files=%s;dex_matches=%s;layout_files=%s;layout_matches=%s;hits=%s|-|%s|%s\n' \
        "$stamp" "$user" "$pkg" "$apk" "$dex_files" "$dex_matches" "$layout_files" "$layout_matches" "$hit_count" "$cache_state" "$_aas_apk_elapsed" \
        >> "$AD_SURFACE_SCAN_FILE"
    ad_surface_emit_hits "$user" "$pkg" "$apk" "$cache_state" "$hits" "$stamp"
    rm -f "$dex_stat" "$res_stat" "$hits" 2>/dev/null
}

record_ad_surface_scan_package() {
    user="$1"; pkg="$2"
    [ "${AAD_AD_SURFACE_SCAN_ACTIVE:-0}" = "1" ] || return 0
    [ "$(read_bool_setting BLOCK_ADS 0)" = "1" ] || return 0
    paths=$(cap_package_paths_readonly "$user" "$pkg")
    [ -n "$paths" ] || return 0
    vc="${AAD_CURRENT_VERSION_CODE:-unknown}"
    max_apks=$(read_setting AD_SURFACE_MAX_APKS_PER_PACKAGE 64)
    case "$max_apks" in ''|*[!0-9]*) max_apks=64 ;; esac
    [ "$max_apks" -ge 1 ] 2>/dev/null || max_apks=1
    [ "$max_apks" -le 256 ] 2>/dev/null || max_apks=256
    apk_count=0
    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
        apk_count=$((apk_count + 1))
        if [ "$apk_count" -gt "$max_apks" ] 2>/dev/null; then
            log "AD-SURFACE-APK-LIMIT u$user package=$pkg limit=$max_apks remaining_paths_skipped=yes"
            break
        fi
        scan_ad_surfaces_for_apk "$user" "$pkg" "$vc" "$apk"
    done <<EOF
$paths
EOF
}

manifest_activity_rule_hits() {
    classes="$1"
    [ -f "$classes" ] && [ -f "$RULES_FILE" ] || return 0
    awk '
        function trim(s) {sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
        function is_exact_section(s) {return s=="ADS_ACTIVITY_IFW" || s=="ANALYTICS_ACTIVITY_IFW"}
        function is_audit_section(s) {return s=="ADS_ACTIVITY_AUDIT" || s=="ANALYTICS_ACTIVITY_AUDIT"}
        FNR==NR {
            line=$0
            sub(/\r$/, "", line)
            if (line ~ /^\[[^]]+\]$/) {section=substr(line,2,length(line)-2); next}
            line=trim(line)
            if (line=="" || line ~ /^#/) next
            if (is_exact_section(section)) exact[++ne]=line
            else if (is_audit_section(section)) audit[++na]=line
            next
        }
        {
            cls=$0
            lc=tolower(cls)
            for (i=1; i<=ne; i++) {
                rule=exact[i]
                if (substr(rule,1,3)=="re:") {
                    pat=substr(rule,4)
                    if (cls ~ pat || lc ~ tolower(pat)) {print "EXACT|" cls; next}
                } else if (lc==tolower(rule)) {
                    print "EXACT|" cls
                    next
                }
            }
            for (i=1; i<=na; i++) {
                rule=audit[i]
                if (substr(rule,1,3)=="re:") {
                    pat=substr(rule,4)
                    if (cls ~ pat || lc ~ tolower(pat)) {print "AUDIT|" cls; next}
                } else if (index(lc,tolower(rule))>0) {
                    print "AUDIT|" cls
                    next
                }
            }
        }
    ' "$RULES_FILE" "$classes" | sort -u
}

aad_manifest_rules_hash() {
    [ -f "$RULES_FILE" ] || { printf 'none\n'; return; }
    awk '
        function trim(s){sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
        /^\[(ADS_ACTIVITY_IFW|ADS_ACTIVITY_AUDIT|ANALYTICS_ACTIVITY_IFW|ANALYTICS_ACTIVITY_AUDIT)\]$/ {
            inside=1; print; next
        }
        /^\[/ {inside=0}
        inside {
            line=$0; sub(/\r$/, "", line); line=trim(line)
            if (line!="" && line !~ /^#/) print line
        }
    ' "$RULES_FILE" 2>/dev/null | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

aad_manifest_cache_rulesig_compatible() {
    _amcrc_sig="$1"; _amcrc_current="$2"
    [ "$_amcrc_sig" = "$_amcrc_current" ] && return 0
    if [ "$_amcrc_current" = "2393526744:3813" ]; then
        case "$_amcrc_sig" in
            62107431:15382|1443295594:15890) return 0 ;;
        esac
    fi
    return 1
}

aad_apk_stat_signature() {
    apk="$1"
    stat_line=""
    if command -v stat >/dev/null 2>&1; then
        stat_line=$(stat -c '%s|%Y' "$apk" 2>/dev/null)
    fi
    if [ -z "$stat_line" ] && aad_have_bb; then
        stat_line=$(aad_bb stat -c '%s|%Y' "$apk" 2>/dev/null)
    fi
    [ -n "$stat_line" ] || return 1
    printf '%s|%s\n' "$apk" "$stat_line"
}

aad_manifest_cache_prefix() {
    user="$1"; pkg="$2"; vc="$3"; apk="$4"
    pkg_safe=$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9._-' '_')
    vc_safe=$(printf '%s' "$vc" | tr -c 'A-Za-z0-9._-' '_')
    [ -n "$vc_safe" ] || vc_safe=unknown
    apk_base=${apk##*/}
    apk_safe=$(printf '%s' "$apk_base" | tr -c 'A-Za-z0-9._-' '_')
    path_key=$(printf '%s' "$apk" | cksum 2>/dev/null | awk '{print $1 "_" $2}')
    [ -n "$path_key" ] || path_key=path
    cache_dir="$MANIFEST_CACHE_DIR/u$user/$pkg_safe/v$vc_safe"
    printf '%s/%s.%s\n' "$cache_dir" "$apk_safe" "$path_key"
}

aad_manifest_cache_commit_file() {
    src="$1"; dst="$2"
    [ -f "$src" ] || return 1
    tmp="$dst.tmp.$$"
    cp "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

aad_manifest_cache_gc() {
    state_file="$1"
    [ -f "$state_file" ] || return 0
    [ -d "$MANIFEST_CACHE_DIR" ] || return 0
    removed=0
    for udir in "$MANIFEST_CACHE_DIR"/u*; do
        [ -d "$udir" ] || continue
        uname=${udir##*/}
        cache_user=${uname#u}
        for pdir in "$udir"/*; do
            [ -d "$pdir" ] || continue
            cache_pkg=${pdir##*/}
            for vdir in "$pdir"/v*; do
                [ -d "$vdir" ] || continue
                vname=${vdir##*/}
                cache_vc=${vname#v}
                if ! grep -Fxq -- "$cache_user|$cache_pkg|$cache_vc" "$state_file" 2>/dev/null; then
                    rm -rf "$vdir" 2>/dev/null || true
                    removed=$((removed + 1))
                fi
            done
            rmdir "$pdir" 2>/dev/null || true
        done
        rmdir "$udir" 2>/dev/null || true
    done
    log "MANIFEST-CACHE-GC removed_versions=$removed dir=$MANIFEST_CACHE_DIR"
    return 0
}

get_manifest_activity_candidates() {
    user="$1"; pkg="$2"
    _gmac_failed=0

    paths=$(cap_package_paths_readonly "$user" "$pkg")
    if [ -z "$paths" ]; then
        return 0
    fi

    axml=$(aad_mktemp_near "$DATA_DIR/.manifest_axml")
    classes=$(aad_mktemp_near "$DATA_DIR/.manifest_classes")
    meta=$(aad_mktemp_near "$DATA_DIR/.manifest_meta")
    verified_tmp=$(aad_mktemp_near "$DATA_DIR/.manifest_verified")
    [ -n "$axml" ] && [ -n "$classes" ] && [ -n "$meta" ] && [ -n "$verified_tmp" ] || {
        [ -n "$axml" ] && rm -f "$axml" 2>/dev/null
        [ -n "$classes" ] && rm -f "$classes" 2>/dev/null
        [ -n "$meta" ] && rm -f "$meta" 2>/dev/null
        [ -n "$verified_tmp" ] && rm -f "$verified_tmp" 2>/dev/null
        return 1
    }

    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
        if [ ! -f "$apk" ]; then
            _gmac_failed=1
            log "MANIFEST-PATH-INACCESSIBLE u$user: $pkg apk=$apk"
            [ -n "${AAD_MANIFEST_STATS_FILE:-}" ] && printf '%s|%s|%s|%s|path-inaccessible|UNKNOWN|0|0|0|0|0|0|BYPASS\n' \
                "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$user" "$pkg" "$apk" >> "$AAD_MANIFEST_STATS_FILE"
            continue
        fi

        : > "$axml"; : > "$classes"; : > "$meta"; : > "$verified_tmp"
        cache_state=MISS
        cache_prefix=""
        apk_sig=""
        vc_now="${AAD_CURRENT_VERSION_CODE:-unknown}"
        rules_hash="${AAD_MANIFEST_RULES_HASH:-}"
        [ -n "$rules_hash" ] || rules_hash=$(aad_manifest_rules_hash)

        if [ "${AAD_MANIFEST_CACHE_ENABLED:-0}" = "1" ]; then
            apk_sig=$(aad_apk_stat_signature "$apk" 2>/dev/null)
            cache_prefix=$(aad_manifest_cache_prefix "$user" "$pkg" "$vc_now" "$apk")
            if [ -n "$apk_sig" ] && [ -n "$cache_prefix" ] && \
               [ -f "$cache_prefix.sig" ] && [ -f "$cache_prefix.meta" ] && [ -f "$cache_prefix.classes" ] && \
               [ "$(cat "$cache_prefix.sig" 2>/dev/null)" = "$apk_sig" ]; then
                cp "$cache_prefix.classes" "$classes" 2>/dev/null || : > "$classes"
                cp "$cache_prefix.meta" "$meta" 2>/dev/null || : > "$meta"
                if [ -s "$classes" ] && [ -s "$meta" ]; then
                    cache_state=PARSE_HIT
                fi
            fi
        fi

        if [ "$cache_state" = "MISS" ]; then
            if ! extract_compiled_manifest_readonly "$apk" "$axml"; then
                _gmac_failed=1
                [ -n "$AAD_MANIFEST_STATS_FILE" ] && printf '%s|%s|%s|%s|extract-failed|UNKNOWN|0|0|0|0|0|0|MISS\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$user" "$pkg" "$apk" >> "$AAD_MANIFEST_STATS_FILE"
                continue
            fi

            manifest_class_strings "$axml" "$meta" > "$classes"

            if [ "${AAD_MANIFEST_CACHE_ENABLED:-0}" = "1" ] && [ -n "$cache_prefix" ] && [ -n "$apk_sig" ] && [ -s "$meta" ]; then
                cache_dir=${cache_prefix%/*}
                mkdir -p "$cache_dir" 2>/dev/null
                chmod 700 "$MANIFEST_CACHE_DIR" "$MANIFEST_CACHE_DIR/u$user" "$MANIFEST_CACHE_DIR/u$user/$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9._-' '_')" "$cache_dir" 2>/dev/null || true
                printf '%s\n' "$apk_sig" > "$cache_prefix.sig.tmp.$$" 2>/dev/null
                chmod 600 "$cache_prefix.sig.tmp.$$" 2>/dev/null || true
                mv -f "$cache_prefix.sig.tmp.$$" "$cache_prefix.sig" 2>/dev/null || rm -f "$cache_prefix.sig.tmp.$$" 2>/dev/null
                aad_manifest_cache_commit_file "$meta" "$cache_prefix.meta" >/dev/null 2>&1 || true
                aad_manifest_cache_commit_file "$classes" "$cache_prefix.classes" >/dev/null 2>&1 || true
                rm -f "$cache_prefix.rulesig" "$cache_prefix.hitstats" "$cache_prefix.verified" 2>/dev/null
            fi
        fi

        meta_line=$(cat "$meta" 2>/dev/null)
        parser=$(printf '%s\n' "$meta_line" | sed -n 's/.*parser=\([^|]*\).*/\1/p')
        encoding=$(printf '%s\n' "$meta_line" | sed -n 's/.*encoding=\([^|]*\).*/\1/p')
        string_count=$(printf '%s\n' "$meta_line" | sed -n 's/.*strings=\([0-9][0-9]*\).*/\1/p')
        token_count=$(printf '%s\n' "$meta_line" | sed -n 's/.*tokens=\([0-9][0-9]*\).*/\1/p')
        valid=$(printf '%s\n' "$meta_line" | sed -n 's/.*valid=\([01]\).*/\1/p')
        [ -n "$parser" ] || parser=unknown
        [ -n "$encoding" ] || encoding=UNKNOWN
        [ -n "$string_count" ] || string_count=0
        [ -n "$token_count" ] || token_count=0
        [ -n "$valid" ] || valid=0
        [ "$valid" = "1" ] || _gmac_failed=1

        manifest_sdk_fingerprints "$classes"

        exact_hits=0
        audit_hits=0
        verified=0
        verify_miss=0
        use_verified_cache=0
        if [ "$cache_state" = "PARSE_HIT" ] && [ -n "$cache_prefix" ] && \
           [ -f "$cache_prefix.rulesig" ] && [ -f "$cache_prefix.hitstats" ] && [ -f "$cache_prefix.verified" ]; then
            _am_cached_rulesig=$(cat "$cache_prefix.rulesig" 2>/dev/null)
            if aad_manifest_cache_rulesig_compatible "$_am_cached_rulesig" "$rules_hash"; then
                if [ "$_am_cached_rulesig" != "$rules_hash" ]; then
                    printf '%s\n' "$rules_hash" > "$cache_prefix.rulesig.tmp.$$" 2>/dev/null
                    chmod 600 "$cache_prefix.rulesig.tmp.$$" 2>/dev/null || true
                    mv -f "$cache_prefix.rulesig.tmp.$$" "$cache_prefix.rulesig" 2>/dev/null || rm -f "$cache_prefix.rulesig.tmp.$$" 2>/dev/null
                fi
                hitstats=$(cat "$cache_prefix.hitstats" 2>/dev/null)
            old_ifs=$IFS
            IFS='|'
            set -- $hitstats
            IFS=$old_ifs
            exact_hits=${1:-0}; audit_hits=${2:-0}; verified=${3:-0}; verify_miss=${4:-0}
                case "$exact_hits:$audit_hits:$verified:$verify_miss" in
                    *[!0-9:]*|'') use_verified_cache=0 ;;
                    *) use_verified_cache=1 ;;
                esac
            fi
        fi

        if [ "$use_verified_cache" -eq 1 ]; then
            cache_state=FULL_HIT
            cached_verified=$(cat "$cache_prefix.verified" 2>/dev/null)
            old_ifs=$IFS
            IFS='
'
            for cls in $cached_verified; do
                [ -n "$cls" ] && echo "ACTIVITY|$pkg/$cls"
            done
            IFS=$old_ifs
        else
            hit_file=$(aad_mktemp_near "$DATA_DIR/.manifest_hits")
            manifest_activity_rule_hits "$classes" > "$hit_file"
            exact_hits=$(awk -F'|' '$1=="EXACT"{n++} END{print n+0}' "$hit_file" 2>/dev/null)
            audit_hits=$(awk -F'|' '$1=="AUDIT"{n++} END{print n+0}' "$hit_file" 2>/dev/null)
            verified=0
            verify_miss=0
            : > "$verified_tmp"

            while IFS='|' read -r hit cls; do
                [ "$hit" = "EXACT" ] || continue
                [ -n "$cls" ] || continue
                comp="$pkg/$cls"
                echo "ACTIVITY|$comp"
                printf '%s\n' "$cls" >> "$verified_tmp"
                verified=$((verified + 1))
            done < "$hit_file"
            rm -f "$hit_file" 2>/dev/null

            if [ "${AAD_MANIFEST_CACHE_ENABLED:-0}" = "1" ] && [ -n "$cache_prefix" ] && [ -n "$apk_sig" ] && [ -f "$cache_prefix.classes" ]; then
                printf '%s\n' "$rules_hash" > "$cache_prefix.rulesig.tmp.$$" 2>/dev/null
                printf '%s|%s|%s|%s\n' "$exact_hits" "$audit_hits" "$verified" "$verify_miss" > "$cache_prefix.hitstats.tmp.$$" 2>/dev/null
                chmod 600 "$cache_prefix.rulesig.tmp.$$" "$cache_prefix.hitstats.tmp.$$" 2>/dev/null || true
                mv -f "$cache_prefix.rulesig.tmp.$$" "$cache_prefix.rulesig" 2>/dev/null || rm -f "$cache_prefix.rulesig.tmp.$$" 2>/dev/null
                mv -f "$cache_prefix.hitstats.tmp.$$" "$cache_prefix.hitstats" 2>/dev/null || rm -f "$cache_prefix.hitstats.tmp.$$" 2>/dev/null
                aad_manifest_cache_commit_file "$verified_tmp" "$cache_prefix.verified" >/dev/null 2>&1 || true
            fi
        fi

        if [ -n "$AAD_MANIFEST_STATS_FILE" ]; then
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$user" "$pkg" "$apk" \
                "$parser" "$encoding" "$string_count" "$token_count" "$exact_hits" "$audit_hits" "$verified" "$verify_miss" "$cache_state" \
                >> "$AAD_MANIFEST_STATS_FILE"
        fi
    done <<EOF
$paths
EOF

    rm -f "$axml" "$classes" "$meta" "$verified_tmp" 2>/dev/null
    [ "$_gmac_failed" -eq 0 ]
}

get_typed_component_candidates() {
    user="$1"; pkg="$2"
    _gtcc_dump=$(aad_mktemp_near "$DATA_DIR/.typed_dump")
    _gtcc_pm=$(aad_mktemp_near "$DATA_DIR/.typed_pm")
    _gtcc_manifest=$(aad_mktemp_near "$DATA_DIR/.typed_manifest")
    _gtcc_out=$(aad_mktemp_near "$DATA_DIR/.typed_out")
    [ -n "$_gtcc_dump" ] && [ -n "$_gtcc_pm" ] && [ -n "$_gtcc_manifest" ] && [ -n "$_gtcc_out" ] || {
        rm -f "$_gtcc_dump" "$_gtcc_pm" "$_gtcc_manifest" "$_gtcc_out" 2>/dev/null
        return 1
    }
    if ! aad_package_dump_cached "$pkg" > "$_gtcc_dump" 2>/dev/null || [ ! -s "$_gtcc_dump" ]; then
        rm -f "$_gtcc_dump" "$_gtcc_pm" "$_gtcc_manifest" "$_gtcc_out" 2>/dev/null
        log "DISCOVERY-FAILED u$user package=$pkg source=package_dump"
        return 1
    fi
    awk -v p="$pkg" '
        function emit(line, kind,    rest, token, parts) {
            rest=line
            while (match(rest, /[A-Za-z0-9._$-]+\/[A-Za-z0-9._$-]+/)) {
                token=substr(rest,RSTART,RLENGTH)
                split(token,parts,"/")
                if (parts[1]==p) print kind "|" token
                rest=substr(rest,RSTART+RLENGTH)
            }
        }
        /^[[:space:]]*Activity Resolver Table:[[:space:]]*$/ {kind="ACTIVITY"; capture=1; next}
        /^[[:space:]]*Receiver Resolver Table:[[:space:]]*$/ {kind="RECEIVER"; capture=1; next}
        /^[[:space:]]*Service Resolver Table:[[:space:]]*$/ {kind="SERVICE"; capture=1; next}
        /^[[:space:]]*Provider Resolver Table:[[:space:]]*$/ {kind="PROVIDER"; capture=1; next}
        /^[[:space:]]*Activities:[[:space:]]*$/ {kind="ACTIVITY"; capture=1; next}
        /^[[:space:]]*Receivers:[[:space:]]*$/ {kind="RECEIVER"; capture=1; next}
        /^[[:space:]]*Services:[[:space:]]*$/ {kind="SERVICE"; capture=1; next}
        /^[[:space:]]*Providers:[[:space:]]*$/ {kind="PROVIDER"; capture=1; next}
        /^[[:space:]]*Registered ContentProviders:[[:space:]]*$/ {kind="PROVIDER"; capture=1; next}
        /^[[:space:]]*ContentProvider Authorities:[[:space:]]*$/ {capture=0; next}
        /^[[:space:]]*(Packages|Shared users|Queries|Dexopt state|Compiler stats):[[:space:]]*$/ {capture=0; next}
        capture {emit($0,kind)}
    ' "$_gtcc_dump" > "$_gtcc_pm" 2>/dev/null || {
        rm -f "$_gtcc_dump" "$_gtcc_pm" "$_gtcc_manifest" "$_gtcc_out" 2>/dev/null
        return 1
    }
    if ! get_manifest_activity_candidates "$user" "$pkg" > "$_gtcc_manifest"; then
        rm -f "$_gtcc_dump" "$_gtcc_pm" "$_gtcc_manifest" "$_gtcc_out" 2>/dev/null
        log "DISCOVERY-FAILED u$user package=$pkg source=manifest"
        return 1
    fi
    cat "$_gtcc_pm" "$_gtcc_manifest" | sort -u > "$_gtcc_out" 2>/dev/null || {
        rm -f "$_gtcc_dump" "$_gtcc_pm" "$_gtcc_manifest" "$_gtcc_out" 2>/dev/null
        return 1
    }
    cat "$_gtcc_out"
    rm -f "$_gtcc_dump" "$_gtcc_pm" "$_gtcc_manifest" "$_gtcc_out" 2>/dev/null
    return 0
}

get_typed_component_candidates_cached() {
    user="$1"; pkg="$2"
    if [ -n "$SCAN_CANDIDATE_CACHE_DIR" ] && [ -d "$SCAN_CANDIDATE_CACHE_DIR" ]; then
        key=$(printf '%s' "$user|$pkg" | cksum 2>/dev/null | awk '{print $1 "_" $2}')
        [ -n "$key" ] || key=$(printf '%s' "$user|$pkg" | tr '/ :|' '____')
        cache="$SCAN_CANDIDATE_CACHE_DIR/$key"
        if [ ! -f "$cache" ]; then
            _gtccc_tmp="$cache.tmp.$$"
            if ! get_typed_component_candidates "$user" "$pkg" > "$_gtccc_tmp"; then
                rm -f "$_gtccc_tmp" 2>/dev/null
                return 1
            fi
            chmod 600 "$_gtccc_tmp" 2>/dev/null || true
            mv -f "$_gtccc_tmp" "$cache" 2>/dev/null || { rm -f "$_gtccc_tmp" 2>/dev/null; return 1; }
        fi
        cat "$cache" 2>/dev/null
        return $?
    fi
    get_typed_component_candidates "$user" "$pkg"
}

component_rule_match_class() {
    _crmc_comp="$1"
    case "$_crmc_comp" in
        */*)
            _crmc_cls=${_crmc_comp#*/}
            case "$_crmc_cls" in
                .*) printf '%s%s\n' "${_crmc_comp%%/*}" "$_crmc_cls" ;;
                *) printf '%s\n' "$_crmc_cls" ;;
            esac
            ;;
        *) printf '%s\n' "$_crmc_comp" ;;
    esac
}

component_matches_rule_section() {
    comp="$1"
    section="$2"
    [ -f "$RULES_FILE" ] || return 1
    comp_cls=$(component_rule_match_class "$comp")

    awk -v target="[$section]" -v component="$comp" -v cls="$comp_cls" '
        BEGIN {inside=0; lc=tolower(cls); lcfull=tolower(component); found=0}
        {
            sub(/\r$/,"")
            if ($0==target) {inside=1; next}
            if ($0 ~ /^\[/) {inside=0}
            if (!inside) next
            line=$0
            sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)
            if (line=="" || line ~ /^#/) next
            if (line ~ /^re:/) {
                pat=substr(line,4)
                if (cls ~ pat || lc ~ tolower(pat) || component ~ pat || lcfull ~ tolower(pat)) found=1
            } else if (index(lc,tolower(line))>0) found=1
        }
        END {exit found ? 0 : 1}
    ' "$RULES_FILE"
}

component_matches_disable_rule() {
    comp="$1"; cat="$2"; kind="$3"
    case "$kind" in
        SERVICE|RECEIVER)
            component_matches_rule_section "$comp" "${cat}_${kind}" && return 0
            component_matches_rule_section "$comp" "$cat" && return 0
            [ "$(read_bool_setting BLOCK_PUSH_SDK 0)" = "1" ] || return 1
            component_matches_rule_section "$comp" "${cat}_PUSH_RISK"
            ;;
        PROVIDER)
            component_matches_rule_section "$comp" "${cat}_PROVIDER_SAFE" && return 0
            component_matches_rule_section "$comp" "${cat}_PROVIDER_AGGRESSIVE" && return 0
            return 1
            ;;
        ACTIVITY)
            component_matches_rule_section "$comp" "${cat}_ACTIVITY_IFW" && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

component_matches_audit_rule() {
    comp="$1"; cat="$2"; kind="$3"
    case "$kind" in
        SERVICE|RECEIVER)
            component_matches_rule_section "$comp" "${cat}_${kind}" && return 0
            component_matches_rule_section "$comp" "$cat" && return 0
            component_matches_rule_section "$comp" "${cat}_PUSH_RISK"
            ;;
        PROVIDER)
            component_matches_rule_section "$comp" "${cat}_PROVIDER_SAFE" && return 0
            component_matches_rule_section "$comp" "${cat}_PROVIDER_AGGRESSIVE" && return 0
            component_matches_rule_section "$comp" "${cat}_PROVIDER_AUDIT"
            ;;
        ACTIVITY)
            component_matches_rule_section "$comp" "${cat}_ACTIVITY_IFW" && return 0
            component_matches_rule_section "$comp" "${cat}_ACTIVITY_AUDIT"
            ;;
        *) return 1 ;;
    esac
}

get_components_for_category() {
    user="$1"
    pkg="$2"
    cat="$3"
    if [ "${AAD_PACKAGE_AUDIT_READY:-0}" = "1" ] && [ -f "$COMPONENT_AUDIT_FILE" ]; then
        awk -F'|' -v u="$user" -v p="$pkg" -v k="$cat" '$2==u && $3==p && $4==k && $7=="DISABLE" {print $8}' "$COMPONENT_AUDIT_FILE" | sort -u
        return
    fi
    get_typed_component_candidates_cached "$user" "$pkg" | while IFS='|' read -r kind comp; do
        [ -z "$comp" ] && continue
        component_matches_disable_rule "$comp" "$cat" "$kind" && echo "$comp"
    done
}

record_package_sdk_fingerprints() {
    user="$1"; pkg="$2"; candidates="$3"; stamp="$4"
    [ -n "$SDK_FINGERPRINT_FILE" ] && [ -f "$RULES_FILE" ] && [ -f "$candidates" ] || return 0

    if [ "${AAD_AUDIT_FULL_SCAN:-0}" != "1" ] && [ "${AAD_AUDIT_ROWS_PRECLEANED:-0}" != "1" ] && [ -f "$SDK_FINGERPRINT_FILE" ]; then
        fp_clean=$(aad_mktemp_near "$SDK_FINGERPRINT_FILE")
        if [ -n "$fp_clean" ]; then
            awk -F'|' -v u="$user" -v p="$pkg" 'NR==1 || !($2==u && $3==p)' "$SDK_FINGERPRINT_FILE" > "$fp_clean" 2>/dev/null \
                && mv -f "$fp_clean" "$SDK_FINGERPRINT_FILE"
            [ -f "$fp_clean" ] && rm -f "$fp_clean" 2>/dev/null
        fi
    fi

    awk -F'|' -v target='[ADS_SDK_FINGERPRINT]' -v stamp="$stamp" -v user="$user" -v pkg="$pkg" '
        BEGIN {OFS="|"}
        FNR==NR {
            line=$0
            sub(/\r$/, "", line)
            if (line==target) {inside=1; next}
            if (inside && line ~ /^\[/) {inside=0}
            if (!inside) next
            sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)
            if (line=="" || line ~ /^#/) next
            sep=index(line,"|")
            if (!sep) next
            label=substr(line,1,sep-1)
            pattern=substr(line,sep+1)
            sub(/^[ \t]+/,"",label); sub(/[ \t]+$/,"",label)
            sub(/^[ \t]+/,"",pattern); sub(/[ \t]+$/,"",pattern)
            if (label!="" && pattern!="") {
                labels[++n]=label
                patterns[n]=tolower(pattern)
            }
            next
        }
        {
            kind=$1
            if (kind=="SDK") {
                label=$2
                evidence=$3
                if (label!="" && !seen[label]++) print stamp,user,pkg,"ADS",label,evidence
                next
            }
            evidence=$2
            lc=tolower(evidence)
            for (i=1; i<=n; i++) {
                if (!seen[labels[i]] && index(lc,patterns[i])>0) {
                    print stamp,user,pkg,"ADS",labels[i],evidence
                    seen[labels[i]]=1
                }
            }
        }
    ' "$RULES_FILE" "$candidates" >> "$SDK_FINGERPRINT_FILE"
}

record_package_audit() {
    user="$1"; pkg="$2"
    [ -n "$COMPONENT_AUDIT_FILE" ] || return 0
    candidates=$(aad_mktemp_near "$DATA_DIR/.audit_candidates")
    [ -n "$candidates" ] || return 1
    if ! get_typed_component_candidates_cached "$user" "$pkg" > "$candidates"; then
        log "DISCOVERY-FAILED u$user package=$pkg state=PRESERVE_PREVIOUS"
        rm -f "$candidates" 2>/dev/null
        [ -n "${AAD_DISCOVERY_FAILED_FILE:-}" ] && : > "$AAD_DISCOVERY_FAILED_FILE" 2>/dev/null || true
        if [ "${AAD_AUDIT_FULL_SCAN:-0}" = "1" ] && [ -s "${AAD_AUDIT_CARRY:-}" ]; then
            awk -F'|' -v u="$user" -v p="$pkg" 'NR>1 && $2==u && $3==p {print}' "$AAD_AUDIT_CARRY" >> "$COMPONENT_AUDIT_FILE" 2>/dev/null || true
            [ -s "${AAD_SDK_CARRY:-}" ] && awk -F'|' -v u="$user" -v p="$pkg" 'NR>1 && $2==u && $3==p {print}' "$AAD_SDK_CARRY" >> "$SDK_FINGERPRINT_FILE" 2>/dev/null || true
        fi
        return 1
    fi
    # Replace package audit rows only after discovery is authoritative (DATA or EMPTY).
    if [ "${AAD_AUDIT_FULL_SCAN:-0}" != "1" ] && [ "${AAD_AUDIT_ROWS_PRECLEANED:-0}" != "1" ] && [ -f "$COMPONENT_AUDIT_FILE" ]; then
        audit_clean=$(aad_mktemp_near "$COMPONENT_AUDIT_FILE")
        if [ -n "$audit_clean" ]; then
            awk -F'|' -v u="$user" -v p="$pkg" 'NR==1 || !($2==u && $3==p)' "$COMPONENT_AUDIT_FILE" > "$audit_clean" 2>/dev/null && mv -f "$audit_clean" "$COMPONENT_AUDIT_FILE"
            [ -f "$audit_clean" ] && rm -f "$audit_clean" 2>/dev/null
        fi
    fi
    block_ads=$(read_bool_setting BLOCK_ADS 0)
    block_analytics=$(read_bool_setting BLOCK_ANALYTICS 0)
    global_white=0; ads_white=0; analytics_white=0
    is_globally_whitelisted "$pkg" && global_white=1
    is_category_whitelisted "$pkg" ADS && ads_white=1
    is_category_whitelisted "$pkg" ANALYTICS && analytics_white=1
    audit_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

    block_push=$(read_bool_setting BLOCK_PUSH_SDK 0)
    awk -F'|' -v user="$user" -v pkg="$pkg" -v stamp="$audit_time" \
        -v block_ads="$block_ads" -v block_analytics="$block_analytics" -v block_push="$block_push" \
        -v global_white="$global_white" -v ads_white="$ads_white" -v analytics_white="$analytics_white" '
        BEGIN {OFS="|"}
        function trim(s) {sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
        function match_class(component,    slash,cls) {
            slash=index(component,"/")
            if (slash==0) return component
            cls=substr(component,slash+1)
            if (substr(cls,1,1)==".") return substr(component,1,slash-1) cls
            return cls
        }
        function section_match(section, component,    i,rule,pattern,cls,lower_class,lower_component) {
            cls=match_class(component)
            lower_class=tolower(cls)
            lower_component=tolower(component)
            for (i=1; i<=rule_count[section]; i++) {
                rule=rules[section,i]
                if (substr(rule,1,3)=="re:") {
                    pattern=substr(rule,4)
                    if (cls ~ pattern || lower_class ~ tolower(pattern) || component ~ pattern || lower_component ~ tolower(pattern)) return 1
                } else if (index(lower_class,tolower(rule))>0) return 1
            }
            return 0
        }
        function skipped(category) {
            if (global_white) return 1
            if (category=="ADS") return block_ads!=1 || ads_white
            return block_analytics!=1 || analytics_white
        }
        function emit(category,kind,component,risk,action) {
            if (skipped(category)) action="SKIP_POLICY"
            print stamp,user,pkg,category,kind,risk,action,component
        }
        FNR==NR {
            line=$0
            sub(/\r$/, "", line)
            if (line ~ /^\[[^]]+\]$/) {section=substr(line,2,length(line)-2); next}
            line=trim(line)
            if (line=="" || line ~ /^#/ || section=="") next
            rules[section,++rule_count[section]]=line
            next
        }
        {
            kind=$1; component=$2
            if (kind=="SERVICE" || kind=="RECEIVER") {
                for (ci=1; ci<=2; ci++) {
                    category=(ci==1 ? "ADS" : "ANALYTICS")
                    if (section_match(category "_" kind,component) || section_match(category,component))
                        emit(category,kind,component,"SAFE","DISABLE")
                    else if (section_match(category "_PUSH_RISK",component))
                        emit(category,kind,component,"PUSH_RISK",(block_push==1 ? "DISABLE" : "REPORT_ONLY"))
                }
            } else if (kind=="PROVIDER") {
                for (ci=1; ci<=2; ci++) {
                    category=(ci==1 ? "ADS" : "ANALYTICS")
                    if (section_match(category "_PROVIDER_SAFE",component) || section_match(category "_PROVIDER_AGGRESSIVE",component))
                        emit(category,kind,component,"EXACT_PROVIDER","DISABLE")
                    else if (section_match(category "_PROVIDER_AUDIT",component))
                        emit(category,kind,component,"AUDIT","REPORT_ONLY")
                }
            } else if (kind=="ACTIVITY") {
                for (ci=1; ci<=2; ci++) {
                    category=(ci==1 ? "ADS" : "ANALYTICS")
                    if (section_match(category "_ACTIVITY_IFW",component))
                        emit(category,kind,component,"EXACT_ACTIVITY","DISABLE")
                    else if (section_match(category "_ACTIVITY_AUDIT",component))
                        emit(category,kind,component,"AUDIT","REPORT_ONLY")
                }
            }
        }
    ' "$RULES_FILE" "$candidates" >> "$COMPONENT_AUDIT_FILE"
    rc=$?
    record_package_sdk_fingerprints "$user" "$pkg" "$candidates" "$audit_time"
    rm -f "$candidates" 2>/dev/null
    return "$rc"
}

ifw_filter_global_candidates() {
    raw="$1"; pair_file="$2"; installed="$3"; out="$4"
    : > "$out"
    [ -f "$raw" ] || return 1

    while IFS= read -r comp; do
        [ -n "$comp" ] || continue
        pkg=${comp%%/*}
        is_globally_whitelisted "$pkg" && continue
        is_category_whitelisted "$pkg" ADS && continue
        printf '%s\n' "$comp" >> "$out"
    done < "$raw"
}

reconcile_owned_ifw_rules() {
    # v6 runtime is PM-only. IFW is handled only as one-shot legacy cleanup.
    if [ -e "$IFW_RULE_FILE" ]; then
        _lifw_expected=$(cat "$IFW_APPLIED_CKSUM" 2>/dev/null)
        _lifw_current=$(cksum "$IFW_RULE_FILE" 2>/dev/null | awk '{print $1 ":" $2}')
        if [ -n "$_lifw_expected" ] && [ "$_lifw_current" = "$_lifw_expected" ]; then
            if rm -f "$IFW_RULE_FILE" 2>/dev/null; then
                log "LEGACY-IFW removed owned file=$IFW_RULE_FILE"
            else
                log "LEGACY-IFW remove failed; PM runtime continues and will retry later"
                return 0
            fi
        else
            log "LEGACY-IFW relinquished: file changed externally or ownership unknown"
        fi
    fi
    rm -f "$IFW_APPLIED_CKSUM" 2>/dev/null
    return 0
}

aad_pkg_snapshot_load() {
    _apsl_user="$1"; _apsl_pkg="$2"
    aad_pkg_snapshot_clear
    AAD_PKG_MEMBERSHIPS=$(awk -F'|' -v u="$_apsl_user" -v p="$_apsl_pkg/" \
        'index($2,p)==1 && $1==u {print "|" $1 "|" $2 "|" $3 "|"}' "$DISABLED_LIST" 2>/dev/null) || {
        log "SNAPSHOT-FALLBACK u$_apsl_user: $_apsl_pkg (membership query failed; using per-component lookups)"
        aad_pkg_snapshot_clear
        return 1
    }
    AAD_PKG_DISABLED_SET=$(aad_package_dump_cached "$_apsl_pkg" 2>/dev/null | awk -v uid="$_apsl_user" '
        function trim(s){gsub(/^[ 	]+|[ 	]+$/,"",s); return s}
        /^[ 	]*User [0-9]+:/ {
            line=$0; gsub(/^[ 	]*/,"",line)
            if (line ~ ("^User " uid ":")) {inuser=1; sec=""; next}
            if (inuser) exit
        }
        !inuser {next}
        /^[ 	]*disabledComponents:/ {sec="disabled"; next}
        /^[ 	]*enabledComponents:/ {sec="enabled"; next}
        /^[ 	]*[A-Za-z][A-Za-z0-9_-]*:/ {sec=""}
        sec=="disabled" {x=trim($0); if (x!="") print "|" x "|"}
    ') || {
        log "SNAPSHOT-FALLBACK u$_apsl_user: $_apsl_pkg (state query failed; using per-component lookups)"
        aad_pkg_snapshot_clear
        return 1
    }
    AAD_PKG_SNAPSHOT_KEY="$_apsl_user|$_apsl_pkg"
    export AAD_PKG_SNAPSHOT_KEY
    return 0
}

aad_pkg_snapshot_clear() {
    unset AAD_PKG_MEMBERSHIPS AAD_PKG_DISABLED_SET AAD_PKG_SNAPSHOT_KEY
}

aad_pkg_component_disabled() {
    _apcd_user="$1"; _apcd_comp="$2"
    [ "$AAD_PKG_SNAPSHOT_KEY" = "$_apcd_user|${_apcd_comp%%/*}" ] || return 2
    _apcd_cls=${_apcd_comp#*/}
    case "$_apcd_cls" in .*) _apcd_full="${_apcd_comp%%/*}$_apcd_cls" ;; *) _apcd_full="$_apcd_cls" ;; esac
    case "$AAD_PKG_DISABLED_SET" in
        *"|$_apcd_full|"*|*"|$_apcd_cls|"*) return 0 ;;
        *) return 1 ;;
    esac
}

membership_exists() {
    user="$1"; comp="$2"; cat="$3"
    if [ "${AAD_PKG_SNAPSHOT_KEY:-}" = "$user|${comp%%/*}" ]; then
        case "$AAD_PKG_MEMBERSHIPS" in
            *"|$user|$comp|$cat|"*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    [ -f "$DISABLED_LIST" ] && awk -F'|' -v u="$user" -v c="$comp" -v k="$cat" '$1==u && $2==c && $3==k {found=1; exit} END{exit !found}' "$DISABLED_LIST"
}

has_any_membership() {
    user="$1"; comp="$2"
    [ -f "$DISABLED_LIST" ] && awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {found=1; exit} END{exit !found}' "$DISABLED_LIST"
}

remove_membership() {
    user="$1"; comp="$2"; cat="$3"
    [ -f "$DISABLED_LIST" ] || return 0
    aad_db_lock "$MEMBERSHIP_DB_LOCK" || { log "MEMBERSHIP-LOCK-FAILED remove ($cat) u$user: $comp"; return 1; }
    tmp=$(aad_mktemp_near "$DISABLED_LIST")
    if [ -n "$tmp" ] && awk -F'|' -v u="$user" -v c="$comp" -v k="$cat" '!( $1==u && $2==c && $3==k )' "$DISABLED_LIST" > "$tmp" 2>/dev/null; then
        if ! mv -f "$tmp" "$DISABLED_LIST" 2>/dev/null; then
            log "MEMBERSHIP-COMMIT-FAILED remove ($cat) u$user: $comp temp=$tmp"
            rm -f "$tmp" 2>/dev/null
            aad_db_unlock "$MEMBERSHIP_DB_LOCK"
            return 1
        fi
    else
        log "MEMBERSHIP-REWRITE-FAILED remove ($cat) u$user: $comp"
        [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
        aad_db_unlock "$MEMBERSHIP_DB_LOCK"
        return 1
    fi
    aad_db_unlock "$MEMBERSHIP_DB_LOCK"
    return 0
}

aad_fail_fast_reset() {
    [ -n "$AAD_FAIL_FAST_STATE" ] || return 0
    printf '0\n' > "$AAD_FAIL_FAST_STATE" 2>/dev/null
}

aad_fail_fast_note_failure() {
    limit=${AAD_FAIL_FAST_LIMIT:-0}
    case "$limit" in ''|*[!0-9]*) limit=0 ;; esac
    [ "$limit" -gt 0 ] || return 1
    [ -n "$AAD_FAIL_FAST_STATE" ] || return 1

    count=$(cat "$AAD_FAIL_FAST_STATE" 2>/dev/null)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    count=$((count + 1))
    printf '%s\n' "$count" > "$AAD_FAIL_FAST_STATE" 2>/dev/null
    log "FAIL-FAST: consecutive component failures=$count/$limit"

    if [ "$count" -ge "$limit" ]; then
        [ -n "$AAD_FAIL_FAST_ABORT" ] && : > "$AAD_FAIL_FAST_ABORT"
        log "FAIL-FAST STOP: $count consecutive components exhausted the complete disable cascade; aborting manual full scan."
        return 0
    fi
    return 1
}

add_membership_and_disable() {
    user="$1"; comp="$2"; cat="$3"

    if membership_exists "$user" "$comp" "$cat"; then
        aad_pkg_component_disabled "$user" "$comp"
        case $? in
            0) _amd_disabled=1 ;;
            1) _amd_disabled=0 ;;
            *)
                _amd_state=$(aad_get_component_override_state_checked "$user" "$comp" 2>/dev/null) || { log "COMPONENT-STATE-UNKNOWN u$user: $comp"; return 1; }
                [ "$_amd_state" = "disabled" ] && _amd_disabled=1 || _amd_disabled=0
                ;;
        esac
        if [ "$_amd_disabled" = "1" ]; then
            aad_fail_fast_reset
            AAD_ALREADY_DISABLED_COUNT=$((${AAD_ALREADY_DISABLED_COUNT:-0} + 1))
            return 0
        fi
    else
        # Category hand-off: when the same component is already owned and
        # disabled for another active category, adding the new membership must
        # not restore/re-disable it or recapture a stale "original" state.
        if has_any_membership "$user" "$comp" && state_record_exists "$user" "$comp"; then
            aad_pkg_component_disabled "$user" "$comp"
            case $? in
                0) _amd_owned_disabled=1 ;;
                1) _amd_owned_disabled=0 ;;
                *)
                    _amd_state=$(aad_get_component_override_state_checked "$user" "$comp" 2>/dev/null) || { log "COMPONENT-STATE-UNKNOWN handoff u$user: $comp"; return 1; }
                    [ "$_amd_state" = "disabled" ] && _amd_owned_disabled=1 || _amd_owned_disabled=0
                    ;;
            esac
            if [ "$_amd_owned_disabled" = "1" ]; then
                if aad_db_lock "$MEMBERSHIP_DB_LOCK"; then
                    membership_exists "$user" "$comp" "$cat" || printf '%s|%s|%s
' "$user" "$comp" "$cat" >> "$DISABLED_LIST"
                    aad_db_unlock "$MEMBERSHIP_DB_LOCK"
                    if [ "${AAD_PKG_SNAPSHOT_KEY:-}" = "$user|${comp%%/*}" ]; then
                        AAD_PKG_MEMBERSHIPS="$AAD_PKG_MEMBERSHIPS
|$user|$comp|$cat|"
                    fi
                    aad_fail_fast_reset
                    log "MEMBERSHIP-HANDOFF ($cat) u$user: $comp (already module-disabled)"
                    return 0
                fi
                log "MEMBERSHIP-LOCK-FAILED handoff ($cat) u$user: $comp"
                return 1
            fi
        fi
        if ! ensure_original_state "$user" "$comp"; then
            log "DISABLE-SKIP ($cat) u$user: $comp reason=original_state_unavailable"
            return 1
        fi
    fi

    if disable_component_smart "$user" "$comp"; then
        if ! membership_exists "$user" "$comp" "$cat"; then
            if aad_db_lock "$MEMBERSHIP_DB_LOCK"; then
                if ! membership_exists "$user" "$comp" "$cat"; then
                    printf '%s|%s|%s\n' "$user" "$comp" "$cat" >> "$DISABLED_LIST"
                    if [ "${AAD_PKG_SNAPSHOT_KEY:-}" = "$user|${comp%%/*}" ]; then
                        AAD_PKG_MEMBERSHIPS="$AAD_PKG_MEMBERSHIPS
|$user|$comp|$cat|"
                    fi
                fi
                aad_db_unlock "$MEMBERSHIP_DB_LOCK"
            else
                log "MEMBERSHIP-LOCK-FAILED add ($cat) u$user: $comp"
                return 1
            fi
        fi
        aad_fail_fast_reset
        log "DISABLED ($cat) u$user: $comp"
        return 0
    fi
    log "DISABLE-FAILED ($cat) u$user: $comp"
    aad_fail_fast_note_failure >/dev/null 2>&1 || true
    if ! has_any_membership "$user" "$comp"; then
        remove_state_record "$user" "$comp"
    fi
    return 1
}

restore_category_for_package_user() {
    user="$1"; pkg="$2"; cat="$3"
    [ -f "$DISABLED_LIST" ] || return
    affected="$DATA_DIR/.affected.$$"
    : > "$affected"

    aad_db_lock "$MEMBERSHIP_DB_LOCK" || { rm -f "$affected" 2>/dev/null; log "MEMBERSHIP-LOCK-FAILED bulk-restore ($cat) u$user: $pkg"; return 1; }
    tmp=$(aad_mktemp_near "$DISABLED_LIST")
    if [ -z "$tmp" ] || ! awk -F'|' -v u="$user" -v p="$pkg/" -v k="$cat" '
        $1==u && index($2,p)==1 && $3==k {print $1 "|" $2 > "'$affected'"; next}
        {print}
    ' "$DISABLED_LIST" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$DISABLED_LIST" 2>/dev/null; then
        log "MEMBERSHIP-COMMIT-FAILED bulk-restore ($cat) u$user: $pkg"
        [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
        aad_db_unlock "$MEMBERSHIP_DB_LOCK"
        rm -f "$affected" 2>/dev/null
        return 1
    fi
    aad_db_unlock "$MEMBERSHIP_DB_LOCK"

    while IFS='|' read -r au ac; do
        [ -z "$ac" ] && continue
        if ! has_any_membership "$au" "$ac"; then
            restore_original_state "$au" "$ac"
        fi
    done < "$affected"
    rm -f "$affected"
}

restore_category_for_package() {
    pkg="$1"; cat="$2"
    users=$(awk -F'|' -v p="$pkg/" -v k="$cat" '$3==k && index($2,p)==1 {print $1}' "$DISABLED_LIST" 2>/dev/null | sort -u)
    for user in $users; do
        restore_category_for_package_user "$user" "$pkg" "$cat"
    done
}

restore_all_for_package_user() {
    user="$1"; pkg="$2"
    for cat in $CATEGORIES; do
        restore_category_for_package_user "$user" "$pkg" "$cat"
    done
    aad_restore_appops_overlay_control "$user" "$pkg"
}

restore_all_for_package() {
    pkg="$1"
    users=$(awk -F'|' -v p="$pkg/" 'index($2,p)==1 {print $1}' "$DISABLED_LIST" 2>/dev/null | sort -u)
    for user in $users; do
        restore_all_for_package_user "$user" "$pkg"
    done
}

aad_package_presence_authoritative() {
    _ppa_user="$1"; _ppa_pkg="$2"
    _ppa_raw=$(cap_list_packages_raw "$_ppa_user" 0 0 "$_ppa_pkg" 2>/dev/null); _ppa_rc=$?
    [ "$_ppa_rc" -eq 0 ] || return 2
    printf '%s\n' "$_ppa_raw" | sed 's/^package://; s/[[:space:]].*$//' | grep -Fxq -- "$_ppa_pkg" && return 0
    return 1
}

aad_user_presence_authoritative() {
    _upa_user="$1"
    _upa_raw=$(cap_list_users_raw 2>/dev/null); _upa_rc=$?
    [ "$_upa_rc" -eq 0 ] || return 2
    _upa_ids=$(printf '%s\n' "$_upa_raw" | awk '
        /UserInfo\{[0-9]+/ {match($0,/UserInfo\{[0-9]+/); print substr($0,RSTART+9,RLENGTH-9)}
        /id=[0-9]+/ {match($0,/id=[0-9]+/); print substr($0,RSTART+3,RLENGTH-3)}
        /^[[:space:]]*User [0-9]+:/ {match($0,/User [0-9]+/); print substr($0,RSTART+5,RLENGTH-5)}
    ' | sort -nu)
    [ -n "$_upa_ids" ] || return 2
    printf '%s\n' "$_upa_ids" | grep -Fxq -- "$_upa_user" && return 0
    return 1
}


aad_restore_component_state_db() {
    _rcsd_db="$1"
    [ -n "$_rcsd_db" ] || return 1
    [ -s "$_rcsd_db" ] || { rm -f "$_rcsd_db" 2>/dev/null || true; return 0; }
    _rcsd_tmp=$(aad_mktemp_near "$_rcsd_db")
    [ -n "$_rcsd_tmp" ] || return 1
    : > "$_rcsd_tmp" 2>/dev/null || { rm -f "$_rcsd_tmp" 2>/dev/null; return 1; }
    _rcsd_failed=0
    _rcsd_total=0
    aad_package_dump_cache_reset
    while IFS='|' read -r _u _comp _orig _applied; do
        [ -n "$_comp" ] || continue
        _rcsd_total=$((_rcsd_total + 1))
        [ -n "$_applied" ] || _applied=disabled
        _pkg=${_comp%%/*}
        _cur=$(aad_get_component_override_state_checked "$_u" "$_comp" 2>/dev/null)
        _cur_rc=$?
        if [ "$_cur_rc" -ne 0 ]; then
            aad_package_presence_authoritative "$_u" "$_pkg"; _pkg_rc=$?
            if [ "$_pkg_rc" -eq 1 ]; then
                log "COMPONENT-RESTORE-RETIRED u$_u $_comp reason=package_absent"
                continue
            fi
            aad_user_presence_authoritative "$_u"; _usr_rc=$?
            if [ "$_usr_rc" -eq 1 ]; then
                log "COMPONENT-RESTORE-RETIRED u$_u $_comp reason=user_absent"
                continue
            fi
            printf '%s|%s|%s|%s\n' "$_u" "$_comp" "$_orig" "$_applied" >> "$_rcsd_tmp"
            _rcsd_failed=1
            log "COMPONENT-RESTORE-PENDING u$_u $_comp reason=current_state_unknown"
            continue
        fi

        if [ "$_cur" != "$_applied" ]; then
            log "COMPONENT-RESTORE-PRESERVE u$_u $_comp external=$_cur module_applied=$_applied"
            continue
        fi

        _want="${_orig:-default}"
        if ! set_component_state_smart "$_u" "$_comp" "$_want"; then
            printf '%s|%s|%s|%s\n' "$_u" "$_comp" "$_orig" "$_applied" >> "$_rcsd_tmp"
            _rcsd_failed=1
            log "COMPONENT-RESTORE-PENDING u$_u $_comp reason=set_failed wanted=$_want"
            continue
        fi
        aad_package_dump_invalidate "$_pkg"
        _verify=$(aad_get_component_override_state_checked "$_u" "$_comp" 2>/dev/null)
        _verify_rc=$?
        if [ "$_verify_rc" -ne 0 ] || [ "$_verify" != "$_want" ]; then
            printf '%s|%s|%s|%s\n' "$_u" "$_comp" "$_orig" "$_applied" >> "$_rcsd_tmp"
            _rcsd_failed=1
            log "COMPONENT-RESTORE-PENDING u$_u $_comp reason=verify_failed current=${_verify:-unknown} expected=$_want"
        else
            log "COMPONENT-RESTORED u$_u $_comp -> $_want"
        fi
    done < "$_rcsd_db"
    aad_package_dump_cache_reset
    chmod 600 "$_rcsd_tmp" 2>/dev/null || true
    if [ -s "$_rcsd_tmp" ]; then
        mv -f "$_rcsd_tmp" "$_rcsd_db" 2>/dev/null || { rm -f "$_rcsd_tmp" 2>/dev/null; return 1; }
    else
        rm -f "$_rcsd_tmp" "$_rcsd_db" 2>/dev/null
    fi
    log "COMPONENT-RESTORE-SUMMARY total=$_rcsd_total failed=$_rcsd_failed db=$_rcsd_db"
    [ "$_rcsd_failed" -eq 0 ]
}

aad_parse_appops_mode() {
    _ap_raw="$1"
    [ -n "$_ap_raw" ] || return 1
    _ap_norm=$(printf '%s\n' "$_ap_raw" | awk '
        tolower($0) ~ /(allow|ignore|deny|default|foreground)/ {
            for (i=1; i<=NF; i++) {
                t=tolower($i)
                gsub(/[^a-z]/, "", t)
                if (t ~ /^(allow|ignore|deny|default|foreground)$/) {
                    print t
                    exit
                }
            }
        }
    ')
    [ -n "$_ap_norm" ] && echo "$_ap_norm" || return 1
}

aad_restore_appops_state() {
    _ras_user_filter="${1:-}"; _ras_pkg_filter="${2:-}"
    _ras_db="$DATA_DIR/.appops_state"
    [ -f "$_ras_db" ] || return 0
    command -v cmd >/dev/null 2>&1 || return 1

    _ras_tmp=$(aad_mktemp_near "$_ras_db")
    [ -n "$_ras_tmp" ] || return 1
    : > "$_ras_tmp" 2>/dev/null || { rm -f "$_ras_tmp"; return 1; }
    _ras_failed=0

    while IFS='|' read -r _u _p _op _orig _appl; do
        [ -n "$_p" ] || continue
        [ -n "$_appl" ] || _appl="ignore"
        if { [ -n "$_ras_user_filter" ] && [ "$_u" != "$_ras_user_filter" ]; } || { [ -n "$_ras_pkg_filter" ] && [ "$_p" != "$_ras_pkg_filter" ]; }; then
            printf '%s|%s|%s|%s|%s\n' "$_u" "$_p" "$_op" "$_orig" "$_appl" >> "$_ras_tmp"
            continue
        fi

        _out=$(cmd appops get --user "$_u" "$_p" "$_op" 2>/dev/null); _get_rc=$?
        _cur=$(aad_parse_appops_mode "$_out" 2>/dev/null); _parse_rc=$?
        if [ "$_get_rc" -ne 0 ] || [ "$_parse_rc" -ne 0 ] || [ -z "$_cur" ]; then
            aad_package_presence_authoritative "$_u" "$_p"; _ppa_rc=$?
            if [ "$_ppa_rc" -eq 1 ]; then
                log "APPOPS-RESTORE-RETIRED u$_u $_p $_op reason=package_absent"
                continue
            fi
            printf '%s|%s|%s|%s|%s\n' "$_u" "$_p" "$_op" "$_orig" "$_appl" >> "$_ras_tmp"
            _ras_failed=1
            log "APPOPS-RESTORE-PENDING u$_u $_p $_op reason=read_failed"
            continue
        fi

        if [ "$_cur" != "$_appl" ]; then
            log "APPOPS-RESTORE-PRESERVE u$_u $_p $_op external=$_cur module_applied=$_appl"
            continue
        fi

        _want="${_orig:-default}"
        if ! cmd appops set --user "$_u" "$_p" "$_op" "$_want" >/dev/null 2>&1; then
            printf '%s|%s|%s|%s|%s\n' "$_u" "$_p" "$_op" "$_orig" "$_appl" >> "$_ras_tmp"
            _ras_failed=1
            log "APPOPS-RESTORE-PENDING u$_u $_p $_op reason=set_failed"
            continue
        fi
        _verify_out=$(cmd appops get --user "$_u" "$_p" "$_op" 2>/dev/null); _verify_rc=$?
        _verify=$(aad_parse_appops_mode "$_verify_out" 2>/dev/null)
        if [ "$_verify_rc" -ne 0 ] || [ "$_verify" != "$_want" ]; then
            printf '%s|%s|%s|%s|%s\n' "$_u" "$_p" "$_op" "$_orig" "$_appl" >> "$_ras_tmp"
            _ras_failed=1
            log "APPOPS-RESTORE-PENDING u$_u $_p $_op reason=verify_failed current=${_verify:-unknown} expected=$_want"
        else
            log "APPOPS-RESTORED u$_u $_p $_op -> $_want"
        fi
    done < "$_ras_db"

    chmod 600 "$_ras_tmp" 2>/dev/null || true
    if [ -s "$_ras_tmp" ]; then
        mv -f "$_ras_tmp" "$_ras_db" 2>/dev/null || { rm -f "$_ras_tmp"; return 1; }
    else
        rm -f "$_ras_tmp" "$_ras_db" 2>/dev/null
    fi
    [ "$_ras_failed" -eq 0 ]
}

aad_restore_appops_overlay_control() {
    aad_restore_appops_state "$1" "$2"
}

aad_apply_appops_overlay_control() {
    [ "$(read_bool_setting BLOCK_ADS 0)" = "1" ] || return 0
    [ "$(read_bool_setting BLOCK_OVERLAY_ADS 0)" = "1" ] || return 0
    _aoc_user="$1"; _aoc_pkg="$2"; _aoc_scope_hint="${3:-}"
    [ "$_aoc_scope_hint" = "scope-ok" ] || is_package_in_scope "$_aoc_pkg" "$_aoc_user" || return 0
    command -v cmd >/dev/null 2>&1 || return 1

    _appops_db="$DATA_DIR/.appops_state"
    _aoc_failed=0
    for _op in SYSTEM_ALERT_WINDOW TOAST_WINDOW; do
        _aoc_out=$(cmd appops get --user "$_aoc_user" "$_aoc_pkg" "$_op" 2>/dev/null); _aoc_get_rc=$?
        _aoc_cur=$(aad_parse_appops_mode "$_aoc_out" 2>/dev/null); _aoc_parse_rc=$?
        if [ "$_aoc_get_rc" -ne 0 ] || [ "$_aoc_parse_rc" -ne 0 ] || [ -z "$_aoc_cur" ]; then
            _aoc_failed=1
            log "APPOPS-APPLY-PENDING u$_aoc_user $_aoc_pkg $_op reason=read_failed"
            continue
        fi
        case "$_aoc_cur" in
            allow|default)
                if ! grep -q "^${_aoc_user}|${_aoc_pkg}|${_op}|" "$_appops_db" 2>/dev/null; then
                    _aoc_tmp=$(aad_mktemp_near "$_appops_db")
                    [ -n "$_aoc_tmp" ] || return 1
                    { [ -f "$_appops_db" ] && cat "$_appops_db"; printf '%s|%s|%s|%s|ignore\n' "$_aoc_user" "$_aoc_pkg" "$_op" "$_aoc_cur"; } > "$_aoc_tmp" 2>/dev/null || { rm -f "$_aoc_tmp"; return 1; }
                    chmod 600 "$_aoc_tmp" 2>/dev/null || true
                    mv -f "$_aoc_tmp" "$_appops_db" 2>/dev/null || { rm -f "$_aoc_tmp"; return 1; }
                fi
                if ! cmd appops set --user "$_aoc_user" "$_aoc_pkg" "$_op" ignore >/dev/null 2>&1; then
                    _aoc_failed=1
                    log "APPOPS-APPLY-PENDING user=$_aoc_user pkg=$_aoc_pkg op=$_op reason=set_failed"
                    continue
                fi
                _aoc_verify_out=$(cmd appops get --user "$_aoc_user" "$_aoc_pkg" "$_op" 2>/dev/null); _aoc_verify_rc=$?
                _aoc_verify=$(aad_parse_appops_mode "$_aoc_verify_out" 2>/dev/null)
                if [ "$_aoc_verify_rc" -eq 0 ] && [ "$_aoc_verify" = "ignore" ]; then
                    log "APPOPS-OVERLAY-BLOCKED user=$_aoc_user pkg=$_aoc_pkg op=$_op (orig=$_aoc_cur -> ignore)"
                else
                    _aoc_failed=1
                    log "APPOPS-APPLY-PENDING user=$_aoc_user pkg=$_aoc_pkg op=$_op verify=${_aoc_verify:-unknown}"
                fi
                ;;
        esac
    done
    if [ "$_aoc_failed" -ne 0 ]; then
        printf '%s\n' "$(date +%s 2>/dev/null)|appops-apply" > "$DATA_DIR/.side_effects.pending" 2>/dev/null || true
        return 1
    fi
    return 0
}

process_package_user() {
    user="$1"
    pkg="$2"
    desired=$(aad_mktemp_near "$DATA_DIR/.desired")
    existing=$(aad_mktemp_near "$DATA_DIR/.existing")
    if [ -z "$desired" ] || [ -z "$existing" ]; then
        log "PACKAGE-RECONCILE temp allocation failed u$user: $pkg"
        [ -n "$desired" ] && rm -f "$desired" 2>/dev/null
        [ -n "$existing" ] && rm -f "$existing" 2>/dev/null
        return 1
    fi
    : > "$desired"
    aad_package_dump_cache_reset
    aad_pkg_snapshot_load "$user" "$pkg"
    AAD_ALREADY_DISABLED_COUNT=0
    AAD_PACKAGE_AUDIT_READY=0
    if record_package_audit "$user" "$pkg"; then
        AAD_PACKAGE_AUDIT_READY=1
    else
        log "PACKAGE-RECONCILE-PENDING u$user: $pkg reason=discovery_failed previous_candidates_and_memberships_preserved"
        rm -f "$desired" "$existing" 2>/dev/null
        aad_pkg_snapshot_clear
        return 1
    fi

    if ! is_package_in_scope "$pkg" "$user"; then
        log "SCOPE-SKIP u$user: $pkg (protected, whitelisted, or system app with INCLUDE_SYSTEM_APPS=0)"
    else
        for cat in $CATEGORIES; do
            category_enabled "$cat" || continue
            if is_category_whitelisted "$pkg" "$cat"; then
                log "WHITELIST-SKIP ($cat) u$user: $pkg"
                continue
            fi

            comps=$(get_components_for_category "$user" "$pkg" "$cat")
            [ -z "$comps" ] && continue
            count=$(printf '%s\n' "$comps" | grep -c .)
            max=$(read_max_matches)
            if [ "$count" -gt "$max" ]; then
                frozen=$(awk -F'|' -v u="$user" -v p="$pkg/" -v k="$cat" '$1==u && $3==k && index($2,p)==1 {print $1 "|" $2 "|" $3}' "$DISABLED_LIST" 2>/dev/null)
                [ -n "$frozen" ] && printf '%s\n' "$frozen" >> "$desired"
                frozen_count=$(printf '%s\n' "$frozen" | grep -c . 2>/dev/null)
                [ -n "$frozen" ] || frozen_count=0
                log "SAFETY-FREEZE ($cat) u$user $pkg: $count matches > $max; preserved=$frozen_count new mutations skipped."
                continue
            fi
            printf '%s\n' "$comps" | while IFS= read -r comp; do
                [ -n "$comp" ] && echo "$user|$comp|$cat" >> "$desired"
            done
        done
    fi
    sort -u "$desired" > "$desired.sorted" 2>/dev/null && mv "$desired.sorted" "$desired"

    awk -F'|' -v u="$user" -v p="$pkg/" '$1==u && index($2,p)==1' "$DISABLED_LIST" 2>/dev/null > "$existing"
    log "PACKAGE-RECONCILE u$user: $pkg existing_memberships=$(grep -c . "$existing" 2>/dev/null) desired_memberships=$(grep -c . "$desired" 2>/dev/null)"

    # Add desired memberships first. This keeps a component continuously owned
    # when policy hands it from ADS to ANALYTICS (or vice versa), avoiding a
    # transient restore/re-disable cycle and preserving the original state.
    disabled_now=0
    while IFS='|' read -r du dc dk; do
        [ -z "$dc" ] && continue
        if add_membership_and_disable "$du" "$dc" "$dk"; then
            if ! grep -Fxq -- "$du|$dc|$dk" "$existing" 2>/dev/null; then
                disabled_now=$((disabled_now + 1))
            fi
        fi
        if [ -n "$AAD_FAIL_FAST_ABORT" ] && [ -f "$AAD_FAIL_FAST_ABORT" ]; then
            break
        fi
    done < "$desired"

    if [ -z "$AAD_FAIL_FAST_ABORT" ] || [ ! -f "$AAD_FAIL_FAST_ABORT" ]; then
        while IFS='|' read -r eu ec ek; do
            [ -z "$ec" ] && continue
            if ! grep -Fxq -- "$eu|$ec|$ek" "$desired" 2>/dev/null; then
                remove_membership "$eu" "$ec" "$ek"
                log "POLICY-REMOVE ($ek) u$eu: $ec"
                if ! has_any_membership "$eu" "$ec"; then
                    if is_globally_whitelisted "$pkg"; then
                        log "WHITELIST-RESTORE global ($ek) u$eu: $ec"
                    elif is_category_whitelisted "$pkg" "$ek"; then
                        log "WHITELIST-RESTORE ($ek) u$eu: $ec"
                    fi
                    restore_original_state "$eu" "$ec"
                fi
            fi
        done < "$existing"
    fi

    [ "${AAD_ALREADY_DISABLED_COUNT:-0}" -gt 0 ] && \
        log "ALREADY-DISABLED u$user: $pkg components=$AAD_ALREADY_DISABLED_COUNT"

    # Overlay AppOps is an ADS-only side effect. A package that only has
    # ANALYTICS memberships must not receive ADS overlay restrictions merely
    # because BLOCK_ADS is globally enabled for other packages.
    _ppu_side_failed=0
    if grep -q '|ADS$' "$desired" 2>/dev/null; then
        aad_apply_appops_overlay_control "$user" "$pkg" || _ppu_side_failed=1
    else
        aad_restore_appops_overlay_control "$user" "$pkg" >/dev/null 2>&1 || _ppu_side_failed=1
    fi
    [ "$_ppu_side_failed" -eq 0 ] || printf '%s
' "$(date +%s 2>/dev/null)|package-appops" > "$DATA_DIR/.side_effects.pending" 2>/dev/null || true

    [ "${AAD_AUDIT_FULL_SCAN:-0}" = "1" ] || aad_candidate_cache_update_package "$user" "$pkg" >/dev/null 2>&1 || true
    aad_pkg_snapshot_clear
    rm -f "$desired" "$existing"
    echo "$disabled_now"
    if [ -n "$AAD_FAIL_FAST_ABORT" ] && [ -f "$AAD_FAIL_FAST_ABORT" ]; then
        return 2
    fi
    [ "${_ppu_side_failed:-0}" -eq 0 ] || return 1
    return 0
}

package_installed_in_snapshot() {
    snapshot="$1"; user="$2"; pkg="$3"
    [ -f "$snapshot" ] && grep -Fxq -- "$user|$pkg" "$snapshot" 2>/dev/null
}

process_package_all_users() {
    pkg="$1"
    snapshot="${2:-}"
    own_snapshot=0
    if [ -z "$snapshot" ] || [ ! -f "$snapshot" ]; then
        snapshot=$(aad_mktemp_near "$DATA_DIR/.installed_keys.delta")
        [ -n "$snapshot" ] || return 1
        if ! list_all_installed_package_keys > "$snapshot"; then
            rm -f "$snapshot" 2>/dev/null
            log "CONFIG-DELTA failed: authoritative installed-package snapshot unavailable"
            return 1
        fi
        own_snapshot=1
    fi

    total=0
    users=$(list_user_ids_checked) || { [ "$own_snapshot" -eq 1 ] && rm -f "$snapshot" 2>/dev/null; return 1; }
    for user in $users; do
        log "CONFIG-DELTA user=$user package=$pkg begin"
        if package_installed_in_snapshot "$snapshot" "$user" "$pkg"; then
            n=$(process_package_user "$user" "$pkg")
            rc=$?
            case "$n" in ''|*[!0-9]*) n=0 ;; esac
            total=$((total + n))
            log "CONFIG-DELTA user=$user package=$pkg end installed=yes rc=$rc ops=$n"
            [ "$rc" -eq 2 ] && { [ "$own_snapshot" -eq 1 ] && rm -f "$snapshot" 2>/dev/null; return 2; }
        else
            _ppau_ok_users="$DATA_DIR/.users_snapshot_ok"
            if [ -f "$_ppau_ok_users" ] && grep -Fxq "$user" "$_ppau_ok_users" 2>/dev/null; then
                restore_all_for_package_user "$user" "$pkg"
                rc=$?
                log "CONFIG-DELTA user=$user package=$pkg end installed=no restore_rc=${rc:-0}"
            else
                rc=0
                log "CONFIG-DELTA user=$user package=$pkg snapshot=unknown; ownership preserved for retry"
            fi
        fi
    done
    [ "$own_snapshot" -eq 1 ] && rm -f "$snapshot" 2>/dev/null
    echo "$total"
    return 0
}

cleanup_stale_records() {
    [ -f "$DISABLED_LIST" ] || return 0
    installed_keys="${1:-}"
    own_snapshot=0
    if [ -z "$installed_keys" ] || [ ! -f "$installed_keys" ]; then
        installed_keys="$DATA_DIR/.installed_keys.$$"
        if ! list_all_installed_package_keys > "$installed_keys"; then
            rm -f "$installed_keys" 2>/dev/null
            log "STALE-SKIP: authoritative installed-package snapshot unavailable; state preserved"
            return 1
        fi
        own_snapshot=1
    fi

    if [ ! -s "$installed_keys" ]; then
        log "STALE-SKIP: installed-package snapshot is empty (PackageManager unavailable); membership/state DB left untouched."
        [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
        return 0
    fi

    _ok_users_file="$DATA_DIR/.users_snapshot_ok"

    aad_db_lock "$MEMBERSHIP_DB_LOCK" || {
        log "MEMBERSHIP-LOCK-FAILED stale-cleanup"
        [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
        return 1
    }
    tmp=$(aad_mktemp_near "$DISABLED_LIST")
    if [ -z "$tmp" ]; then
        aad_db_unlock "$MEMBERSHIP_DB_LOCK"
        [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
        return 1
    fi
    : > "$tmp"
    stale_dropped=0
    stale_records=$(cat "$DISABLED_LIST" 2>/dev/null)
    old_ifs=$IFS
    IFS='
'
    for stale_line in $stale_records; do
        [ -n "$stale_line" ] || continue
        user=${stale_line%%|*}
        rest=${stale_line#*|}
        comp=${rest%%|*}
        cat=${rest#*|}
        [ -n "$comp" ] || continue
        pkg=${comp%%/*}

        if [ -f "$_ok_users_file" ] && ! grep -Fxq "$user" "$_ok_users_file" 2>/dev/null; then
            printf '%s|%s|%s\n' "$user" "$comp" "$cat" >> "$tmp"
            continue
        fi

        if grep -Fxq -- "$user|$pkg" "$installed_keys" 2>/dev/null; then
            printf '%s|%s|%s\n' "$user" "$comp" "$cat" >> "$tmp"
        else
            log "STALE: dropping record u$user $comp ($cat); package truly absent from verified user snapshot."
            stale_dropped=$((stale_dropped + 1))
        fi
    done
    IFS=$old_ifs

    _scr_before=$(grep -c . "$tmp" 2>/dev/null); [ -n "$_scr_before" ] || _scr_before=0
    if sort -u "$tmp" -o "$tmp" 2>/dev/null; then
        _scr_after=$(grep -c . "$tmp" 2>/dev/null); [ -n "$_scr_after" ] || _scr_after=0
        [ "$_scr_before" -gt "$_scr_after" ] &&             log "MEMBERSHIP-DEDUP removed $((_scr_before - _scr_after)) duplicate row(s)"
    fi
    if ! mv -f "$tmp" "$DISABLED_LIST" 2>/dev/null; then
        log "MEMBERSHIP-COMMIT-FAILED stale-cleanup temp=$tmp"
        rm -f "$tmp" 2>/dev/null
        aad_db_unlock "$MEMBERSHIP_DB_LOCK"
        [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
        return 1
    fi
    aad_db_unlock "$MEMBERSHIP_DB_LOCK"

    if [ "$stale_dropped" -gt 0 ] && [ -f "$COMPONENT_STATE" ]; then
        state_records=$(cat "$COMPONENT_STATE" 2>/dev/null)
        old_ifs=$IFS
        IFS='
'
        for state_line in $state_records; do
            [ -n "$state_line" ] || continue
            suser=${state_line%%|*}
            srest=${state_line#*|}
            scomp=${srest%%|*}
            [ -n "$scomp" ] || continue
            spkg=${scomp%%/*}

            if [ -f "$_ok_users_file" ] && ! grep -Fxq "$suser" "$_ok_users_file" 2>/dev/null; then
                continue
            fi

            grep -Fxq -- "$suser|$spkg" "$installed_keys" 2>/dev/null && continue
            remove_state_record "$suser" "$scomp"
        done
        IFS=$old_ifs
    fi
    log "STALE-CLEANUP dropped=$stale_dropped snapshot_entries=$(grep -c . "$installed_keys" 2>/dev/null)"
    [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
    return 0
}

retry_orphan_restores() {
    [ -f "$COMPONENT_STATE" ] || return
    work="$COMPONENT_STATE.orphans.$$"
    cp "$COMPONENT_STATE" "$work" 2>/dev/null || return

    orphan_records=$(cat "$work" 2>/dev/null)
    rm -f "$work" 2>/dev/null
    [ -n "$orphan_records" ] || return 0

    old_ifs=$IFS
    IFS='
'
    for orphan_line in $orphan_records; do
        [ -n "$orphan_line" ] || continue
        user=${orphan_line%%|*}
        rest=${orphan_line#*|}
        comp=${rest%%|*}
        [ -n "$comp" ] || continue
        if ! has_any_membership "$user" "$comp"; then
            restore_original_state "$user" "$comp"
        fi
    done
    IFS=$old_ifs
}

rebuild_composite_rules() {
    _rc_tmp="$DATA_DIR/.rules_composite.tmp.$$"
    {
        if [ -f "$DATA_DIR/rules.vendor.conf" ]; then
            cat "$DATA_DIR/rules.vendor.conf"
        elif [ -f "$MODDIR/rules.vendor.conf" ]; then
            cat "$MODDIR/rules.vendor.conf"
        fi
        printf '\n\n# --- USER CUSTOM RULES ---\n'
        if [ -f "$DATA_DIR/rules.user.conf" ]; then
            cat "$DATA_DIR/rules.user.conf"
        elif [ -f "$MODDIR/rules.user.conf" ]; then
            cat "$MODDIR/rules.user.conf"
        fi
    } > "$_rc_tmp" 2>/dev/null
    if [ ! -s "$_rc_tmp" ]; then
        rm -f "$_rc_tmp" 2>/dev/null
        return 1
    fi
    chmod 600 "$_rc_tmp" 2>/dev/null || true
    if [ -f "$RULES_FILE" ] && cmp -s "$_rc_tmp" "$RULES_FILE" 2>/dev/null; then
        rm -f "$_rc_tmp" 2>/dev/null
        return 0
    fi
    if mv -f "$_rc_tmp" "$RULES_FILE" 2>/dev/null; then
        sync 2>/dev/null || true
        return 0
    fi
    rm -f "$_rc_tmp" 2>/dev/null
    return 1
}

compute_config_hash() {
    {
        for f in "$SETTINGS_FILE" "$DATA_DIR/rules.vendor.conf" "$DATA_DIR/rules.user.conf" "$RULES_FILE" "$WHITELIST_FILE" "$WHITE_ADS_FILE" "$WHITE_ANALYTICS_FILE" "$SMART_REWARD_FILE" "$QA_TARGETS_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

compute_base_policy_hash() {
    {
        for f in "$SETTINGS_FILE" "$DATA_DIR/rules.vendor.conf" "$DATA_DIR/rules.user.conf" "$RULES_FILE" "$SMART_REWARD_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}


compute_config_hash_with_settings() {
    _cchs_settings="$1"
    {
        [ -f "$_cchs_settings" ] && cat "$_cchs_settings"
        # Keep the canonical SETTINGS_FILE marker so a snapshot with identical
        # bytes hashes exactly like the live configuration.
        echo "--FILE--$SETTINGS_FILE"
        for f in "$DATA_DIR/rules.vendor.conf" "$DATA_DIR/rules.user.conf" "$RULES_FILE" "$WHITELIST_FILE" "$WHITE_ADS_FILE" "$WHITE_ANALYTICS_FILE" "$SMART_REWARD_FILE" "$QA_TARGETS_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

compute_discovery_policy_hash() {
    {
        echo "candidate-schema=v3-policy-neutral-discovery"
        for f in "$DATA_DIR/rules.vendor.conf" "$DATA_DIR/rules.user.conf" "$RULES_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

compute_non_primary_settings_hash() {
    _cnps_file="${1:-${AAD_SETTINGS_SNAPSHOT:-$SETTINGS_FILE}}"
    if [ -f "$_cnps_file" ]; then
        awk '
            /^[[:space:]]*BLOCK_ADS[[:space:]]*=/ {next}
            /^[[:space:]]*BLOCK_ANALYTICS[[:space:]]*=/ {next}
            /^[[:space:]]*INCLUDE_SYSTEM_APPS[[:space:]]*=/ {next}
            /^[[:space:]]*SCAN_SYSTEM_APPS[[:space:]]*=/ {next}
            {print}
        ' "$_cnps_file"
    fi | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

aad_policy_snapshot_begin() {
    AAD_SETTINGS_SNAPSHOT=$(aad_mktemp_near "$DATA_DIR/.settings.policy")
    [ -n "$AAD_SETTINGS_SNAPSHOT" ] || return 1
    if [ -f "$SETTINGS_FILE" ]; then
        cp "$SETTINGS_FILE" "$AAD_SETTINGS_SNAPSHOT" 2>/dev/null || { rm -f "$AAD_SETTINGS_SNAPSHOT"; unset AAD_SETTINGS_SNAPSHOT; return 1; }
    else
        : > "$AAD_SETTINGS_SNAPSHOT" 2>/dev/null || { unset AAD_SETTINGS_SNAPSHOT; return 1; }
    fi
    chmod 600 "$AAD_SETTINGS_SNAPSHOT" 2>/dev/null || true
    export AAD_SETTINGS_SNAPSHOT
    AAD_POLICY_START_HASH=$(compute_config_hash_with_settings "$AAD_SETTINGS_SNAPSHOT")
    AAD_POLICY_DISCOVERY_HASH=$(compute_discovery_policy_hash)
    AAD_POLICY_NON_PRIMARY_HASH=$(compute_non_primary_settings_hash "$AAD_SETTINGS_SNAPSHOT")
    export AAD_POLICY_START_HASH AAD_POLICY_DISCOVERY_HASH AAD_POLICY_NON_PRIMARY_HASH
    return 0
}

aad_policy_snapshot_end() {
    [ -n "${AAD_SETTINGS_SNAPSHOT:-}" ] && rm -f "$AAD_SETTINGS_SNAPSHOT" 2>/dev/null
    unset AAD_SETTINGS_SNAPSHOT AAD_POLICY_START_HASH AAD_POLICY_DISCOVERY_HASH AAD_POLICY_NON_PRIMARY_HASH
}

aad_write_reconcile_status() {
    _awrs_state="$1"; _awrs_mode="$2"; _awrs_generation="$3"; _awrs_detail="${4:-}"
    _awrs_tmp=$(aad_mktemp_near "$RECONCILE_STATUS_FILE")
    [ -n "$_awrs_tmp" ] || return 0
    {
        echo "state=$_awrs_state"
        echo "mode=$_awrs_mode"
        echo "generation=$_awrs_generation"
        echo "timestamp=$(date +%s 2>/dev/null)"
        [ -n "$_awrs_detail" ] && echo "detail=$_awrs_detail"
    } > "$_awrs_tmp" 2>/dev/null || { rm -f "$_awrs_tmp"; return 0; }
    chmod 600 "$_awrs_tmp" 2>/dev/null || true
    mv -f "$_awrs_tmp" "$RECONCILE_STATUS_FILE" 2>/dev/null || rm -f "$_awrs_tmp" 2>/dev/null
}

aad_candidate_cache_rebuild_from_audit() {
    [ -f "$COMPONENT_AUDIT_FILE" ] || return 1
    _acra_tmp=$(aad_mktemp_near "$CANDIDATE_FILE")
    [ -n "$_acra_tmp" ] || return 1
    awk -F'|' 'NR>1 && ($6=="SAFE" || $6=="EXACT_PROVIDER" || $6=="EXACT_ACTIVITY" || $6=="PUSH_RISK") && $2!="" && $3!="" && $4!="" && $8!="" {print $2 "|" $3 "|" $4 "|" $8 "|" $6}' "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$_acra_tmp"
    chmod 600 "$_acra_tmp" 2>/dev/null || true
    mv -f "$_acra_tmp" "$CANDIDATE_FILE" 2>/dev/null || { rm -f "$_acra_tmp"; return 1; }
    return 0
}

aad_candidate_cache_update_package() {
    _accu_user="$1"; _accu_pkg="$2"
    [ -f "$COMPONENT_AUDIT_FILE" ] || return 0
    _accu_tmp=$(aad_mktemp_near "$CANDIDATE_FILE")
    [ -n "$_accu_tmp" ] || return 1
    {
        [ -f "$CANDIDATE_FILE" ] && awk -F'|' -v u="$_accu_user" -v p="$_accu_pkg" '!($1==u && $2==p)' "$CANDIDATE_FILE"
        awk -F'|' -v u="$_accu_user" -v p="$_accu_pkg" 'NR>1 && $2==u && $3==p && ($6=="SAFE" || $6=="EXACT_PROVIDER" || $6=="EXACT_ACTIVITY" || $6=="PUSH_RISK") && $8!="" {print $2 "|" $3 "|" $4 "|" $8 "|" $6}' "$COMPONENT_AUDIT_FILE"
    } | sort -u > "$_accu_tmp" 2>/dev/null || { rm -f "$_accu_tmp"; return 1; }
    chmod 600 "$_accu_tmp" 2>/dev/null || true
    mv -f "$_accu_tmp" "$CANDIDATE_FILE" 2>/dev/null || { rm -f "$_accu_tmp"; return 1; }
    return 0
}

aad_candidate_cache_structural_valid() {
    [ -f "$CANDIDATE_FILE" ] || return 1
    if [ -s "$CANDIDATE_FILE" ] && ! awk -F'|' 'NF!=5 || $1 !~ /^[0-9]+$/ || $2=="" || ($3!="ADS" && $3!="ANALYTICS") || $4=="" || $5=="" {bad=1; exit} END{exit bad?1:0}' "$CANDIDATE_FILE" 2>/dev/null; then
        log "CANDIDATE-CACHE invalid/malformed; deep discovery required"
        return 1
    fi
    [ -f "$DISCOVERY_HASH_FILE" ] || return 1
    [ "$(cat "$DISCOVERY_HASH_FILE" 2>/dev/null)" = "$(compute_discovery_policy_hash)" ] || return 1
    [ -f "$NON_PRIMARY_HASH_FILE" ] || return 1
    [ "$(cat "$NON_PRIMARY_HASH_FILE" 2>/dev/null)" = "$(compute_non_primary_settings_hash)" ] || return 1
    return 0
}

aad_candidate_cache_valid() {
    aad_candidate_cache_structural_valid || return 1
    _accv_scope=$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)
    if [ "$(read_include_system_apps)" = "1" ] && [ "$_accv_scope" != "ALL" ]; then
        return 1
    fi
    return 0
}

aad_candidate_cache_bootstrap_from_audit() {
    # v6.0.8 candidate schema v3 requires policy-neutral manifest discovery.
    # Older audit logs can be incomplete when primary ADS/ANALYTICS toggles
    # were disabled, so they must never be promoted into an authoritative v3 cache.
    log "CANDIDATE-CACHE bootstrap refused: schema v3 requires one authoritative policy-neutral deep discovery"
    return 1
}

aad_scope_cache_build_authoritative() {
    _asc_tmp=$(aad_mktemp_near "$PACKAGE_SCOPE_CACHE")
    [ -n "$_asc_tmp" ] || return 1
    : > "$_asc_tmp" 2>/dev/null || { rm -f "$_asc_tmp"; return 1; }
    _asc_failed=0
    _asc_users=0
    _asc_user_list=$(list_user_ids_checked) || { rm -f "$_asc_tmp" 2>/dev/null; return 1; }
    for _asc_u in $_asc_user_list; do
        _asc_users=$((_asc_users + 1))
        _asc_all=$(aad_mktemp_near "$DATA_DIR/.scope_all_u${_asc_u}")
        _asc_usr=$(aad_mktemp_near "$DATA_DIR/.scope_usr_u${_asc_u}")
        if [ -z "$_asc_all" ] || [ -z "$_asc_usr" ]; then
            _asc_failed=1
            rm -f "$_asc_all" "$_asc_usr" 2>/dev/null
            continue
        fi
        if ! aad_capture_packages_for_user "$_asc_u" 0 0 "$_asc_all" || \
           ! aad_capture_packages_for_user "$_asc_u" 1 0 "$_asc_usr"; then
            _asc_failed=1
            log "SCOPE-CACHE snapshot failed user=$_asc_u"
            rm -f "$_asc_all" "$_asc_usr" 2>/dev/null
            continue
        fi
        awk -F'|' -v u="$_asc_u" '
            FILENAME==ARGV[1] {usr[$1]=1; next}
            $1!="" {print u "|" $1 "|" (($1 in usr) ? "USER" : "SYSTEM")}
        ' "$_asc_usr" "$_asc_all" >> "$_asc_tmp" 2>/dev/null || _asc_failed=1
        rm -f "$_asc_all" "$_asc_usr" 2>/dev/null
    done
    if [ "$_asc_users" -eq 0 ] || [ "$_asc_failed" -ne 0 ]; then
        rm -f "$_asc_tmp" 2>/dev/null
        return 1
    fi
    sort -u "$_asc_tmp" -o "$_asc_tmp" 2>/dev/null || { rm -f "$_asc_tmp"; return 1; }
    chmod 600 "$_asc_tmp" 2>/dev/null || true
    mv -f "$_asc_tmp" "$PACKAGE_SCOPE_CACHE" 2>/dev/null || { rm -f "$_asc_tmp"; return 1; }
    log "SCOPE-CACHE rebuilt entries=$(grep -c . "$PACKAGE_SCOPE_CACHE" 2>/dev/null)"
    return 0
}

aad_scope_cache_update_package() {
    _ascu_user="$1"; _ascu_pkg="$2"
    [ -n "$_ascu_pkg" ] || return 1
    _ascu_class="USER"
    if cap_is_system_package "$_ascu_user" "$_ascu_pkg" 2>/dev/null; then
        _ascu_class="SYSTEM"
    fi
    _ascu_tmp=$(aad_mktemp_near "$PACKAGE_SCOPE_CACHE")
    [ -n "$_ascu_tmp" ] || return 1
    {
        [ -f "$PACKAGE_SCOPE_CACHE" ] && awk -F'|' -v u="$_ascu_user" -v p="$_ascu_pkg" '!($1==u && $2==p)' "$PACKAGE_SCOPE_CACHE"
        printf '%s|%s|%s\n' "$_ascu_user" "$_ascu_pkg" "$_ascu_class"
    } | sort -u > "$_ascu_tmp" 2>/dev/null || { rm -f "$_ascu_tmp"; return 1; }
    chmod 600 "$_ascu_tmp" 2>/dev/null || true
    mv -f "$_ascu_tmp" "$PACKAGE_SCOPE_CACHE" 2>/dev/null || { rm -f "$_ascu_tmp"; return 1; }
    return 0
}

aad_scope_cache_ensure() {
    _asce_need=0
    [ -s "$PACKAGE_SCOPE_CACHE" ] || _asce_need=1
    if [ "$_asce_need" -eq 0 ]; then
        if ! awk -F'|' 'NF!=3 || $1 !~ /^[0-9]+$/ || $2=="" || ($3!="USER" && $3!="SYSTEM") {bad=1; exit} END{exit bad?1:0}' "$PACKAGE_SCOPE_CACHE" 2>/dev/null; then
            log "SCOPE-CACHE invalid/malformed; authoritative rebuild required"
            _asce_need=1
        fi
    fi
    if [ "$_asce_need" -eq 0 ]; then
        _asce_missing=$(
            {
                awk -F'|' '$1!="" && $2!="" {print $1 "|" $2}' "$CANDIDATE_FILE" 2>/dev/null
                awk -F'|' '$1!="" && $2!="" {p=$2; sub(/\/.*/,"",p); print $1 "|" p}' "$DISABLED_LIST" 2>/dev/null
            } | sort -u | awk -F'|' -v sf="$PACKAGE_SCOPE_CACHE" '
                BEGIN {
                    while ((getline line < sf) > 0) {
                        split(line,a,"|")
                        if (a[1]!="" && a[2]!="") known[a[1] SUBSEP a[2]]=1
                    }
                    close(sf)
                }
                !known[$1 SUBSEP $2] {print; exit}
            '
        )
        [ -n "$_asce_missing" ] && _asce_need=1
    fi
    [ "$_asce_need" -eq 0 ] && return 0
    aad_scope_cache_build_authoritative
}

aad_fast_build_protected_files() {
    _afbp_protected="$1"; _afbp_unknown="$2"; _afbp_installed="$3"
    : > "$_afbp_protected"; : > "$_afbp_unknown"
    _afbp_users=$(
        {
            awk -F'|' '$1!="" {print $1}' "$_afbp_installed" 2>/dev/null
            awk -F'|' '$1!="" {print $1}' "$CANDIDATE_FILE" 2>/dev/null
            awk -F'|' '$1!="" {print $1}' "$DISABLED_LIST" 2>/dev/null
        } | sort -nu
    )
    for _afbp_u in $_afbp_users; do
        for _afbp_p in $SYSTEM_PROTECTED; do
            printf '%s|%s\n' "$_afbp_u" "$_afbp_p" >> "$_afbp_protected"
        done
        for _afbp_p in $(aad_dynamic_protected_packages "$_afbp_u" 2>/dev/null); do
            [ -n "$_afbp_p" ] && printf '%s|%s\n' "$_afbp_u" "$_afbp_p" >> "$_afbp_protected"
        done
        [ -f "$DATA_DIR/.dyn_prot_unknown_u${_afbp_u}" ] && printf '%s\n' "$_afbp_u" >> "$_afbp_unknown"
    done
    sort -u "$_afbp_protected" -o "$_afbp_protected" 2>/dev/null || true
    sort -u "$_afbp_unknown" -o "$_afbp_unknown" 2>/dev/null || true
}

aad_fast_build_desired_memberships() {
    _afbd_installed="$1"; _afbd_desired="$2"
    _afbd_in=$(aad_mktemp_near "$DATA_DIR/.fast_input")
    _afbd_protected=$(aad_mktemp_near "$DATA_DIR/.fast_protected")
    _afbd_unknown=$(aad_mktemp_near "$DATA_DIR/.fast_protected_unknown")
    [ -n "$_afbd_in" ] && [ -n "$_afbd_protected" ] && [ -n "$_afbd_unknown" ] || {
        rm -f "$_afbd_in" "$_afbd_protected" "$_afbd_unknown" 2>/dev/null
        return 1
    }

    aad_fast_build_protected_files "$_afbd_protected" "$_afbd_unknown" "$_afbd_installed"
    _afbd_ads=$(read_bool_setting BLOCK_ADS 0)
    _afbd_ana=$(read_bool_setting BLOCK_ANALYTICS 0)
    _afbd_sys=$(read_include_system_apps)
    _afbd_push=$(read_bool_setting BLOCK_PUSH_SDK 0)
    _afbd_max=$(read_max_matches)
    _afbd_cache_scope=$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)
    case "$_afbd_max" in ''|*[!0-9]*) _afbd_max=25 ;; esac

    {
        awk -F'|' '$1!="" && $2!="" {print "I|" $1 "|" $2}' "$_afbd_installed" 2>/dev/null
        awk '$0!="" {print "O|" $0}' "$DATA_DIR/.users_snapshot_ok" 2>/dev/null
        awk -F'|' '$1!="" && $2!="" && $3!="" {print "S|" $1 "|" $2 "|" $3}' "$PACKAGE_SCOPE_CACHE" 2>/dev/null
        read_global_list | awk '$0!="" {print "G|" $0}'
        read_category_list ADS | awk '$0!="" {print "A|" $0}'
        read_category_list ANALYTICS | awk '$0!="" {print "N|" $0}'
        awk -F'|' '$1!="" && $2!="" {print "P|" $1 "|" $2}' "$_afbd_protected" 2>/dev/null
        awk '$0!="" {print "U|" $0}' "$_afbd_unknown" 2>/dev/null
        awk -F'|' '$1!="" && $2!="" && $3!="" {print "E|" $1 "|" $2 "|" $3}' "$DISABLED_LIST" 2>/dev/null
        awk -F'|' '$1!="" && $2!="" && $3!="" && $4!="" {print "C|" $1 "|" $2 "|" $3 "|" $4 "|" $5}' "$CANDIDATE_FILE" 2>/dev/null
    } > "$_afbd_in" 2>/dev/null || {
        rm -f "$_afbd_in" "$_afbd_protected" "$_afbd_unknown" 2>/dev/null
        return 1
    }

    awk -F'|' -v ads="$_afbd_ads" -v ana="$_afbd_ana" -v incsys="$_afbd_sys" \
        -v push="$_afbd_push" -v max="$_afbd_max" -v cachescope="$_afbd_cache_scope" '
        BEGIN {OFS="|"}
        $1=="I" {installed[$2 SUBSEP $3]=1; next}
        $1=="O" {okuser[$2]=1; next}
        $1=="S" {scope[$2 SUBSEP $3]=$4; next}
        $1=="G" {global[$2]=1; next}
        $1=="A" {wads[$2]=1; next}
        $1=="N" {wana[$2]=1; next}
        $1=="P" {protected[$2 SUBSEP $3]=1; next}
        $1=="U" {role_unknown[$2]=1; next}
        $1=="E" {
            el=$2 "|" $3 "|" $4
            existing[el]=1
            next
        }
        $1=="C" {
            ck=$2 SUBSEP $3 SUBSEP $4 SUBSEP $5
            risk[ck]=$6
            candidate[ck]=1
            next
        }
        END {
            for (ck in candidate) {
                split(ck,a,SUBSEP)
                u=a[1]; p=a[2]; cat=a[3]; comp=a[4]
                if (!okuser[u] || !installed[u SUBSEP p]) continue
                if (protected[u SUBSEP p] || global[p]) continue
                sc=scope[u SUBSEP p]
                if (sc=="") continue
                if (sc=="SYSTEM") {
                    if (incsys!=1 || role_unknown[u]) continue
                }
                if (cat=="ADS") {
                    if (ads!=1 || wads[p]) continue
                } else if (cat=="ANALYTICS") {
                    if (ana!=1 || wana[p]) continue
                } else continue
                if (risk[ck]=="PUSH_RISK" && push!=1) continue
                elig[ck]=1
                cnt[u SUBSEP p SUBSEP cat]++
            }

            for (ck in elig) {
                split(ck,a,SUBSEP)
                u=a[1]; p=a[2]; cat=a[3]; comp=a[4]
                pk=u SUBSEP p SUBSEP cat
                if (cnt[pk] <= max) out[u "|" comp "|" cat]=1
                else freeze[pk]=1
            }

            for (el in existing) {
                split(el,e,"|")
                u=e[1]; comp=e[2]; cat=e[3]
                p=comp; sub(/\/.*/,"",p)
                if (!okuser[u]) {
                    out[el]=1
                    continue
                }
                if (installed[u SUBSEP p] && scope[u SUBSEP p]=="") {
                    out[el]=1
                    continue
                }
                if (freeze[u SUBSEP p SUBSEP cat]) out[el]=1
            }

            for (line in out) print line
        }
    ' "$_afbd_in" | sort -u > "$_afbd_desired" 2>/dev/null
    _afbd_rc=$?
    rm -f "$_afbd_in" "$_afbd_protected" "$_afbd_unknown" 2>/dev/null
    return "$_afbd_rc"
}

aad_fast_build_component_transitions() {
    _afbct_current="$1"; _afbct_desired="$2"; _afbct_out="$3"
    {
        awk -F'|' '$1!="" && $2!="" && $3!="" {print "C|" $1 "|" $2 "|" $3}' "$_afbct_current" 2>/dev/null
        awk -F'|' '$1!="" && $2!="" && $3!="" {print "D|" $1 "|" $2 "|" $3}' "$_afbct_desired" 2>/dev/null
    } | awk -F'|' '
        $1=="C" {
            k=$2 SUBSEP $3
            row=$2 "|" $3 "|" $4
            cur_n[k]++
            cur[row]=1
            comp[k]=1
            next
        }
        $1=="D" {
            k=$2 SUBSEP $3
            row=$2 "|" $3 "|" $4
            des_n[k]++
            des[row]=1
            comp[k]=1
            next
        }
        END {
            for (row in cur) if (!(row in des)) {
                split(row,a,"|")
                changed[a[1] SUBSEP a[2]]=1
            }
            for (row in des) if (!(row in cur)) {
                split(row,a,"|")
                changed[a[1] SUBSEP a[2]]=1
            }
            for (k in changed) {
                split(k,a,SUBSEP)
                print a[1] "|" a[2] "|" (cur_n[k]+0) "|" (des_n[k]+0)
            }
        }
    ' | sort -u > "$_afbct_out"
}

aad_state_batch_merge() {
    _asbm_add="$1"
    [ -s "$_asbm_add" ] || return 0
    aad_db_lock "$STATE_DB_LOCK" || return 1
    _asbm_tmp=$(aad_mktemp_near "$COMPONENT_STATE")
    if [ -z "$_asbm_tmp" ]; then aad_db_unlock "$STATE_DB_LOCK"; return 1; fi
    {
        [ -f "$COMPONENT_STATE" ] && cat "$COMPONENT_STATE"
        cat "$_asbm_add"
    } | awk -F'|' '$1!="" && $2!="" {k=$1 SUBSEP $2; if(!seen[k]++) print}' > "$_asbm_tmp" 2>/dev/null
    _asbm_rc=$?
    if [ "$_asbm_rc" -eq 0 ]; then
        chmod 600 "$_asbm_tmp" 2>/dev/null || true
        mv -f "$_asbm_tmp" "$COMPONENT_STATE" 2>/dev/null || _asbm_rc=1
    fi
    [ "$_asbm_rc" -eq 0 ] || rm -f "$_asbm_tmp" 2>/dev/null
    aad_db_unlock "$STATE_DB_LOCK"
    return "$_asbm_rc"
}

aad_state_batch_remove_components() {
    _asbr_drop="$1"
    [ -s "$_asbr_drop" ] || return 0
    [ -f "$COMPONENT_STATE" ] || return 0
    aad_db_lock "$STATE_DB_LOCK" || return 1
    _asbr_tmp=$(aad_mktemp_near "$COMPONENT_STATE")
    if [ -z "$_asbr_tmp" ]; then aad_db_unlock "$STATE_DB_LOCK"; return 1; fi
    awk -F'|' -v df="$_asbr_drop" '
        BEGIN {
            while ((getline line < df) > 0) {
                split(line,a,"|")
                if (a[1]!="" && a[2]!="") drop[a[1] SUBSEP a[2]]=1
            }
            close(df)
        }
        !drop[$1 SUBSEP $2] {print}
    ' "$COMPONENT_STATE" > "$_asbr_tmp" 2>/dev/null
    _asbr_rc=$?
    if [ "$_asbr_rc" -eq 0 ]; then
        chmod 600 "$_asbr_tmp" 2>/dev/null || true
        mv -f "$_asbr_tmp" "$COMPONENT_STATE" 2>/dev/null || _asbr_rc=1
    fi
    [ "$_asbr_rc" -eq 0 ] || rm -f "$_asbr_tmp" 2>/dev/null
    aad_db_unlock "$STATE_DB_LOCK"
    return "$_asbr_rc"
}

aad_membership_batch_commit() {
    _ambc_new="$1"
    aad_db_lock "$MEMBERSHIP_DB_LOCK" || return 1
    _ambc_tmp=$(aad_mktemp_near "$DISABLED_LIST")
    if [ -z "$_ambc_tmp" ]; then aad_db_unlock "$MEMBERSHIP_DB_LOCK"; return 1; fi
    sort -u "$_ambc_new" > "$_ambc_tmp" 2>/dev/null
    _ambc_rc=$?
    if [ "$_ambc_rc" -eq 0 ]; then
        chmod 600 "$_ambc_tmp" 2>/dev/null || true
        mv -f "$_ambc_tmp" "$DISABLED_LIST" 2>/dev/null || _ambc_rc=1
    fi
    [ "$_ambc_rc" -eq 0 ] || rm -f "$_ambc_tmp" 2>/dev/null
    aad_db_unlock "$MEMBERSHIP_DB_LOCK"
    return "$_ambc_rc"
}

aad_restore_original_state_keep_record() {
    _aros_user="$1"; _aros_comp="$2"
    AAD_RESTORE_DID_MUTATE=0
    state_record_exists "$_aros_user" "$_aros_comp" || {
        log "FAST-RESTORE-PENDING u$_aros_user: $_aros_comp reason=missing_state_record"
        return 1
    }
    _aros_original=$(get_saved_original_state "$_aros_user" "$_aros_comp")
    [ -n "$_aros_original" ] || _aros_original=default
    _aros_applied=$(get_saved_applied_state "$_aros_user" "$_aros_comp")
    [ -n "$_aros_applied" ] || _aros_applied=disabled
    _aros_current=$(aad_get_component_override_state_checked "$_aros_user" "$_aros_comp" 2>/dev/null) || {
        log "FAST-RESTORE-PENDING u$_aros_user: $_aros_comp reason=current_state_read_failed"
        return 1
    }
    if [ "$_aros_current" != "$_aros_applied" ]; then
        log "RESTORE-PRESERVE u$_aros_user: $_aros_comp current=$_aros_current differs_from_module=$_aros_applied"
        return 0
    fi
    if set_component_state_smart "$_aros_user" "$_aros_comp" "$_aros_original"; then
        AAD_RESTORE_DID_MUTATE=1
        log "RESTORE u$_aros_user: $_aros_comp -> $_aros_original"
        return 0
    fi
    if [ "${CAP_LAST_STATE_NONEXISTENT:-0}" = "1" ]; then
        log "RESTORE-DROP u$_aros_user: $_aros_comp not in package; terminal"
        return 0
    fi
    log "RESTORE-FAILED u$_aros_user: $_aros_comp -> $_aros_original"
    return 1
}

aad_fast_effective_memberships() {
    _afem_current="$1"; _afem_desired="$2"; _afem_preserve="$3"; _afem_out="$4"
    {
        awk -F'|' '$1!="" && $2!="" {print "P|" $1 "|" $2}' "$_afem_preserve" 2>/dev/null
        awk -F'|' '$1!="" && $2!="" && $3!="" {print "C|" $1 "|" $2 "|" $3}' "$_afem_current" 2>/dev/null
        awk -F'|' '$1!="" && $2!="" && $3!="" {print "D|" $1 "|" $2 "|" $3}' "$_afem_desired" 2>/dev/null
    } | awk -F'|' '
        $1=="P" {preserve[$2 SUBSEP $3]=1; next}
        $1=="C" {
            if (preserve[$2 SUBSEP $3]) out[$2 "|" $3 "|" $4]=1
            next
        }
        $1=="D" {
            if (!preserve[$2 SUBSEP $3]) out[$2 "|" $3 "|" $4]=1
            next
        }
        END {for (line in out) print line}
    ' | sort -u > "$_afem_out"
}

fast_policy_reconcile_locked() {
    aad_candidate_cache_valid || return 4
    _fpr_started=$(aad_now_ms)
    _fpr_installed=$(aad_mktemp_near "$DATA_DIR/.fast_installed")
    _fpr_current=$(aad_mktemp_near "$DATA_DIR/.fast_current")
    _fpr_desired=$(aad_mktemp_near "$DATA_DIR/.fast_desired_global")
    _fpr_trans=$(aad_mktemp_near "$DATA_DIR/.fast_transitions")
    _fpr_state_add=$(aad_mktemp_near "$DATA_DIR/.fast_state_add")
    _fpr_state_drop=$(aad_mktemp_near "$DATA_DIR/.fast_state_drop")
    _fpr_preserve=$(aad_mktemp_near "$DATA_DIR/.fast_preserve")
    _fpr_effective=$(aad_mktemp_near "$DATA_DIR/.fast_effective")
    _fpr_pkgs=$(aad_mktemp_near "$DATA_DIR/.fast_touched_pkgs")
    for _fpr_tmp in "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs"; do
        [ -n "$_fpr_tmp" ] || {
            rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
            return 1
        }
    done
    : > "$_fpr_state_add"; : > "$_fpr_state_drop"; : > "$_fpr_preserve"; : > "$_fpr_pkgs"

    if ! list_all_installed_package_keys > "$_fpr_installed"; then
        log "FAST-POLICY failed: authoritative installed-package snapshot unavailable"
        rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
        return 1
    fi
    [ -f "$DISABLED_LIST" ] && sort -u "$DISABLED_LIST" > "$_fpr_current" 2>/dev/null || : > "$_fpr_current"

    if ! aad_scope_cache_ensure; then
        log "FAST-POLICY failed: authoritative package scope cache unavailable"
        rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
        return 1
    fi
    if ! aad_fast_build_desired_memberships "$_fpr_installed" "$_fpr_desired"; then
        log "FAST-POLICY failed: desired membership set generation failed"
        rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
        return 1
    fi
    aad_fast_build_component_transitions "$_fpr_current" "$_fpr_desired" "$_fpr_trans" || {
        rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
        return 1
    }

    _fpr_components=$(grep -c . "$_fpr_trans" 2>/dev/null); [ -n "$_fpr_components" ] || _fpr_components=0
    if [ "$_fpr_components" -eq 0 ]; then
        _fpr_finished=$(aad_now_ms)
        _fpr_ms=$((_fpr_finished - _fpr_started))
        log "FAST-DELTA finished components=0 membership_delta=0 pm_mutations=0 failed=0 total_ms=$_fpr_ms"
        rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
        return 0
    fi

    aad_package_dump_cache_reset
    # Persist every newly-owned original state in one transaction BEFORE any
    # component mutation. Only real 0->owned component deltas reach this loop.
    while IFS='|' read -r _u _c _cur_n _des_n; do
        [ -n "$_c" ] || continue
        _p=${_c%%/*}
        printf '%s|%s\n' "$_u" "$_p" >> "$_fpr_pkgs"
        if [ "$_cur_n" -eq 0 ] 2>/dev/null && [ "$_des_n" -gt 0 ] 2>/dev/null; then
            if ! state_record_exists "$_u" "$_c"; then
                _orig=$(aad_get_component_override_state_checked "$_u" "$_c" 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$_orig" ]; then
                    printf '%s|%s|%s|disabled\n' "$_u" "$_c" "$_orig" >> "$_fpr_state_add"
                else
                    printf '%s|%s\n' "$_u" "$_c" >> "$_fpr_preserve"
                    : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
                    log "FAST-DELTA-ADD-PENDING u$_u: $_c reason=original_state_read_failed"
                fi
            fi
        fi
    done < "$_fpr_trans"
    sort -u "$_fpr_pkgs" -o "$_fpr_pkgs" 2>/dev/null || true
    if ! aad_state_batch_merge "$_fpr_state_add"; then
        log "FAST-DELTA aborted: could not durably persist original component states"
        aad_package_dump_cache_reset
        rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
        return 1
    fi

    _fpr_failed=0; _fpr_pm=0
    while IFS='|' read -r _u _c _cur_n _des_n; do
        [ -n "$_c" ] || continue
        if grep -Fxq -- "$_u|$_c" "$_fpr_preserve" 2>/dev/null; then
            _fpr_failed=1
            continue
        fi
        if [ "$_cur_n" -eq 0 ] 2>/dev/null && [ "$_des_n" -gt 0 ] 2>/dev/null; then
            if disable_component_smart "$_u" "$_c"; then
                _fpr_pm=$((_fpr_pm + 1))
                log "FAST-DELTA-DISABLED u$_u: $_c"
            else
                printf '%s|%s\n' "$_u" "$_c" >> "$_fpr_preserve"
                _fpr_failed=1
                : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
                log "FAST-DELTA-DISABLE-PENDING u$_u: $_c"
            fi
        elif [ "$_cur_n" -gt 0 ] 2>/dev/null && [ "$_des_n" -eq 0 ] 2>/dev/null; then
            if aad_restore_original_state_keep_record "$_u" "$_c"; then
                printf '%s|%s\n' "$_u" "$_c" >> "$_fpr_state_drop"
                [ "${AAD_RESTORE_DID_MUTATE:-0}" = "1" ] && _fpr_pm=$((_fpr_pm + 1))
            else
                printf '%s|%s\n' "$_u" "$_c" >> "$_fpr_preserve"
                _fpr_failed=1
                : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
            fi
        else
            # Membership hand-off only. No PackageManager call is needed.
            if ! state_record_exists "$_u" "$_c"; then
                printf '%s|%s\n' "$_u" "$_c" >> "$_fpr_preserve"
                _fpr_failed=1
                : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
                log "FAST-DELTA-HANDOFF-PENDING u$_u: $_c reason=missing_state_record"
            else
                log "FAST-DELTA-HANDOFF u$_u: $_c"
            fi
        fi
    done < "$_fpr_trans"
    aad_package_dump_cache_reset

    sort -u "$_fpr_preserve" -o "$_fpr_preserve" 2>/dev/null || true
    aad_fast_effective_memberships "$_fpr_current" "$_fpr_desired" "$_fpr_preserve" "$_fpr_effective"
    if ! aad_membership_batch_commit "$_fpr_effective"; then
        log "FAST-DELTA membership commit failed; state backups retained for retry"
        : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
        _fpr_failed=1
    else
        aad_state_batch_remove_components "$_fpr_state_drop" || {
            _fpr_failed=1
            : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
        }
        # AppOps is ADS-only and only packages whose membership set changed
        # are reconsidered here.
        while IFS='|' read -r _u _p; do
            [ -n "$_p" ] || continue
            if awk -F'|' -v u="$_u" -v p="$_p/" '$1==u && $3=="ADS" && index($2,p)==1 {found=1; exit} END{exit !found}' "$_fpr_effective" 2>/dev/null; then
                aad_apply_appops_overlay_control "$_u" "$_p" scope-ok >/dev/null 2>&1 || _fpr_failed=1
            else
                aad_restore_appops_overlay_control "$_u" "$_p" >/dev/null 2>&1 || _fpr_failed=1
            fi
        done < "$_fpr_pkgs"
    fi

    _fpr_current_n=$(grep -c . "$_fpr_current" 2>/dev/null); [ -n "$_fpr_current_n" ] || _fpr_current_n=0
    _fpr_effective_n=$(grep -c . "$_fpr_effective" 2>/dev/null); [ -n "$_fpr_effective_n" ] || _fpr_effective_n=0
    _fpr_membership_delta=$(
        {
            awk 'NR==FNR {a[$0]=1; next} !($0 in a) {print}' "$_fpr_current" "$_fpr_effective"
            awk 'NR==FNR {a[$0]=1; next} !($0 in a) {print}' "$_fpr_effective" "$_fpr_current"
        } | grep -c . 2>/dev/null
    )
    [ -n "$_fpr_membership_delta" ] || _fpr_membership_delta=0
    _fpr_finished=$(aad_now_ms)
    _fpr_ms=$((_fpr_finished - _fpr_started))
    log "FAST-DELTA finished components=$_fpr_components membership_delta=$_fpr_membership_delta memberships_before=$_fpr_current_n memberships_after=$_fpr_effective_n pm_mutations=$_fpr_pm failed=$_fpr_failed total_ms=$_fpr_ms"

    rm -f "$_fpr_installed" "$_fpr_current" "$_fpr_desired" "$_fpr_trans" "$_fpr_state_add" "$_fpr_state_drop" "$_fpr_preserve" "$_fpr_effective" "$_fpr_pkgs" 2>/dev/null
    [ "$_fpr_failed" -eq 0 ]
}

aad_verify_owned_components_locked() {
    _avoc_started=$(aad_now_ms)
    _avoc_components=$(aad_mktemp_near "$DATA_DIR/.verify_components")
    [ -n "$_avoc_components" ] || return 1
    awk -F'|' '$1!="" && $2!="" {print $1 "|" $2}' "$DISABLED_LIST" 2>/dev/null | sort -u > "$_avoc_components"
    _avoc_failed=0; _avoc_checked=0; _avoc_reapplied=0

    aad_package_dump_cache_reset
    while IFS='|' read -r _avoc_u _avoc_c; do
        [ -n "$_avoc_c" ] || continue
        _avoc_checked=$((_avoc_checked + 1))
        if ! state_record_exists "$_avoc_u" "$_avoc_c"; then
            log "OWNED-VERIFY-PENDING u$_avoc_u: $_avoc_c reason=missing_state_record"
            _avoc_failed=1
            continue
        fi
        _avoc_cur=$(aad_get_component_override_state_checked "$_avoc_u" "$_avoc_c" 2>/dev/null) || {
            log "OWNED-VERIFY-PENDING u$_avoc_u: $_avoc_c reason=state_read_failed"
            _avoc_failed=1
            continue
        }
        if [ "$_avoc_cur" != "disabled" ]; then
            if disable_component_smart "$_avoc_u" "$_avoc_c"; then
                _avoc_reapplied=$((_avoc_reapplied + 1))
                log "OWNED-VERIFY-REAPPLIED u$_avoc_u: $_avoc_c current=$_avoc_cur"
            else
                _avoc_failed=1
                log "OWNED-VERIFY-PENDING u$_avoc_u: $_avoc_c reason=disable_failed current=$_avoc_cur"
            fi
        fi
    done < "$_avoc_components"
    aad_package_dump_cache_reset

    # Orphan state records are recovery records without active membership.
    # Their restore is deliberately kept out of interactive FAST and retried
    # only by this low-frequency verifier.
    retry_orphan_restores >/dev/null 2>&1 || _avoc_failed=1

    rm -f "$_avoc_components" 2>/dev/null
    _avoc_finished=$(aad_now_ms)
    _avoc_ms=$((_avoc_finished - _avoc_started))
    if [ "$_avoc_failed" -eq 0 ]; then
        rm -f "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
    else
        : > "$COMPONENT_VERIFY_PENDING" 2>/dev/null || true
    fi
    log "OWNED-VERIFY finished checked=$_avoc_checked reapplied=$_avoc_reapplied failed=$_avoc_failed total_ms=$_avoc_ms"
    [ "$_avoc_failed" -eq 0 ]
}

aad_verify_owned_components() {
    _avoc_reason="${1:-periodic}"
    _avoc_live=$(compute_config_hash)
    _avoc_applied=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)
    if [ -n "$_avoc_applied" ] && [ "$_avoc_live" != "$_avoc_applied" ]; then
        log "OWNED-VERIFY deferred reason=$_avoc_reason live_generation_not_applied"
        return 0
    fi
    acquire_lock || { log "OWNED-VERIFY deferred reason=$_avoc_reason lock_busy"; return 0; }
    log "OWNED-VERIFY begin reason=$_avoc_reason"
    aad_verify_owned_components_locked
    _avoc_rc=$?
    release_lock
    return "$_avoc_rc"
}

expand_system_candidates_locked() {
    [ -f "$CANDIDATE_FILE" ] || return 4
    [ "$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)" = "USER" ] || return 0
    [ "$(read_include_system_apps)" = "1" ] || return 0

    _esc_all=$(aad_mktemp_near "$DATA_DIR/.expand_all")
    _esc_user=$(aad_mktemp_near "$DATA_DIR/.expand_user")
    _esc_system=$(aad_mktemp_near "$DATA_DIR/.expand_system")
    [ -n "$_esc_all" ] && [ -n "$_esc_user" ] && [ -n "$_esc_system" ] || { rm -f "$_esc_all" "$_esc_user" "$_esc_system" 2>/dev/null; return 1; }
    : > "$_esc_all"; : > "$_esc_user"; : > "$_esc_system"
    _esc_snapshot_failed=0; _esc_users=0
    _esc_user_list=$(list_user_ids_checked) || { rm -f "$_esc_all" "$_esc_user" "$_esc_system" 2>/dev/null; log "SYSTEM-EXPAND aborted: user enumeration unavailable"; return 1; }
    for _u in $_esc_user_list; do
        _esc_users=$((_esc_users + 1))
        _ta=$(aad_mktemp_near "$DATA_DIR/.expand_a${_u}"); _tu=$(aad_mktemp_near "$DATA_DIR/.expand_u${_u}")
        if [ -z "$_ta" ] || [ -z "$_tu" ]; then
            _esc_snapshot_failed=1
            rm -f "$_ta" "$_tu" 2>/dev/null
            continue
        fi
        if aad_capture_packages_for_user "$_u" 0 1 "$_ta"; then
            while IFS='|' read -r _p _v; do [ -n "$_p" ] && echo "$_u|$_p|${_v:-0}"; done < "$_ta" >> "$_esc_all"
        else
            _esc_snapshot_failed=1
            log "SYSTEM-EXPAND snapshot failed user=$_u scope=all; candidate scope remains USER"
        fi
        if aad_capture_packages_for_user "$_u" 1 1 "$_tu"; then
            while IFS='|' read -r _p _v; do [ -n "$_p" ] && echo "$_u|$_p|${_v:-0}"; done < "$_tu" >> "$_esc_user"
        else
            _esc_snapshot_failed=1
            log "SYSTEM-EXPAND snapshot failed user=$_u scope=third-party; candidate scope remains USER"
        fi
        rm -f "$_ta" "$_tu" 2>/dev/null
    done
    if [ "$_esc_users" -eq 0 ] || [ "$_esc_snapshot_failed" -ne 0 ]; then
        rm -f "$_esc_all" "$_esc_user" "$_esc_system" 2>/dev/null
        log "SYSTEM-EXPAND aborted: authoritative package snapshots unavailable users=$_esc_users failures=$_esc_snapshot_failed"
        return 1
    fi
    awk -F'|' 'NR==FNR {usr[$1 "|" $2]=1; next} !(($1 "|" $2) in usr) {print}' "$_esc_user" "$_esc_all" > "$_esc_system"
    _esc_count=$(grep -c . "$_esc_system" 2>/dev/null); [ -n "$_esc_count" ] || _esc_count=0
    log "SYSTEM-EXPAND begin system_packages/users=$_esc_count"
    _esc_failed=0; _esc_done=0
    while IFS='|' read -r _u _p _v; do
        [ -n "$_p" ] || continue
        _esc_done=$((_esc_done + 1))
        AAD_CURRENT_VERSION_CODE="$_v"; export AAD_CURRENT_VERSION_CODE
        process_package_user "$_u" "$_p" >/dev/null || _esc_failed=1
    done < "$_esc_system"
    unset AAD_CURRENT_VERSION_CODE
    if [ "$_esc_failed" -eq 0 ]; then
        cat "$_esc_all" | sort -u > "$STATE_FILE.tmp.$$" 2>/dev/null && mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
        _esc_scope_tmp=$(aad_mktemp_near "$PACKAGE_SCOPE_CACHE")
        if [ -n "$_esc_scope_tmp" ]; then
            {
                awk -F'|' '$1!="" && $2!="" {print $1 "|" $2 "|USER"}' "$_esc_user" 2>/dev/null
                awk -F'|' '$1!="" && $2!="" {print $1 "|" $2 "|SYSTEM"}' "$_esc_system" 2>/dev/null
            } | sort -u > "$_esc_scope_tmp" 2>/dev/null
            chmod 600 "$_esc_scope_tmp" 2>/dev/null || true
            mv -f "$_esc_scope_tmp" "$PACKAGE_SCOPE_CACHE" 2>/dev/null || rm -f "$_esc_scope_tmp" 2>/dev/null
        fi
        echo ALL > "$CANDIDATE_SCOPE_FILE"
        log "SYSTEM-EXPAND complete processed=$_esc_done scope=ALL scope_cache=$(grep -c . "$PACKAGE_SCOPE_CACHE" 2>/dev/null)"
    else
        log "SYSTEM-EXPAND incomplete processed=$_esc_done; candidate scope remains USER"
    fi
    rm -f "$_esc_all" "$_esc_user" "$_esc_system" 2>/dev/null
    [ "$_esc_failed" -eq 0 ]
}

reconcile_out_of_scope_records() {
    _ros_installed="$1"
    _ros_desired="$2"
    [ -f "$DISABLED_LIST" ] || return 0
    [ -s "$_ros_installed" ] || return 0
    [ -f "$_ros_desired" ] || return 0

    _ok_installed="$DATA_DIR/.users_snapshot_ok"
    _ok_desired="$DATA_DIR/.users_desired_snapshot_ok"

    _ros_owned_pkgs=$(awk -F'|' '{comp=$2; sub(/\/.*$/, "", comp); if (comp != "") print $1 "|" comp}' "$DISABLED_LIST" 2>/dev/null | sort -u)
    [ -n "$_ros_owned_pkgs" ] || return 0

    _ros_restored=0
    old_ifs=$IFS
    IFS='
'
    for _ros_pair in $_ros_owned_pkgs; do
        [ -n "$_ros_pair" ] || continue
        _ros_u=${_ros_pair%%|*}
        _ros_p=${_ros_pair#*|}
        [ -n "$_ros_p" ] || continue

        if [ -f "$_ok_installed" ] && ! grep -Fxq "$_ros_u" "$_ok_installed" 2>/dev/null; then
            continue
        fi
        if [ -f "$_ok_desired" ] && ! grep -Fxq "$_ros_u" "$_ok_desired" 2>/dev/null; then
            continue
        fi

        if grep -Fxq -- "$_ros_u|$_ros_p" "$_ros_installed" 2>/dev/null && ! awk -F'|' -v u="$_ros_u" -v p="$_ros_p" '$1==u && $2==p {found=1; exit} END {exit found ? 0 : 1}' "$_ros_desired" 2>/dev/null; then
            log "SCOPE-EXIT-RESTORE user=$_ros_u package=$_ros_p (package out of desired scope; restoring all owned components)"
            restore_all_for_package_user "$_ros_u" "$_ros_p"
            _ros_restored=$((_ros_restored + 1))
        fi
    done
    IFS=$old_ifs
    [ "$_ros_restored" -gt 0 ] && log "SCOPE-EXIT-CLEANUP restored $_ros_restored out-of-scope package(s)"
    return 0
}

aad_is_webview_command_line_supported() {
    _b_type=$(getprop ro.build.type 2>/dev/null)
    [ "$_b_type" = "userdebug" ] || [ "$_b_type" = "eng" ] && return 0

    if command -v settings >/dev/null 2>&1; then
        _dev_enabled=$(settings get global development_settings_enabled 2>/dev/null)
        [ "$_dev_enabled" = "1" ] && return 0
        _adb_enabled=$(settings get global adb_enabled 2>/dev/null)
        [ "$_adb_enabled" = "1" ] && return 0
    fi

    _debuggable=$(getprop ro.debuggable 2>/dev/null)
    [ "$_debuggable" = "1" ] && return 0

    return 1
}

aad_settings_get_value() {
    _sgv_ns="$1"; _sgv_user="$2"; _sgv_key="$3"
    case "$_sgv_ns" in
        global) settings get global "$_sgv_key" 2>/dev/null ;;
        secure_user) settings get secure --user "$_sgv_user" "$_sgv_key" 2>/dev/null ;;
        secure) settings get secure "$_sgv_key" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

aad_settings_set_original() {
    _sso_ns="$1"; _sso_user="$2"; _sso_key="$3"; _sso_orig="$4"
    case "$_sso_ns" in
        global)
            if [ "$_sso_orig" = "null" ] || [ -z "$_sso_orig" ]; then settings delete global "$_sso_key" >/dev/null 2>&1; else settings put global "$_sso_key" "$_sso_orig" >/dev/null 2>&1; fi ;;
        secure_user)
            if [ "$_sso_orig" = "null" ] || [ -z "$_sso_orig" ]; then settings delete secure --user "$_sso_user" "$_sso_key" >/dev/null 2>&1; else settings put secure --user "$_sso_user" "$_sso_key" "$_sso_orig" >/dev/null 2>&1; fi ;;
        secure)
            if [ "$_sso_orig" = "null" ] || [ -z "$_sso_orig" ]; then settings delete secure "$_sso_key" >/dev/null 2>&1; else settings put secure "$_sso_key" "$_sso_orig" >/dev/null 2>&1; fi ;;
        *) return 1 ;;
    esac
}

aad_restore_owned_settings() {
    _aros_dir="${1:-$DATA_DIR}"
    _aros_backup="$_aros_dir/.ad_id_backup"
    [ -f "$_aros_backup" ] || return 0
    command -v settings >/dev/null 2>&1 || return 1

    _aros_tmp=$(aad_mktemp_near "$_aros_backup")
    [ -n "$_aros_tmp" ] || return 1
    : > "$_aros_tmp" 2>/dev/null || { rm -f "$_aros_tmp"; return 1; }
    _aros_pending=0

    while IFS='=' read -r _skey _sval; do
        [ -n "$_skey" ] || continue
        _sorig=${_sval%%|*}; _sappl=${_sval#*|}; [ -n "$_sappl" ] || _sappl=1
        _ns=""; _u=0; _key=""
        case "$_skey" in
            global_ad_id_zero) _ns=global; _key=ad_id_zero ;;
            global_limit_ad_tracking) _ns=global; _key=limit_ad_tracking ;;
            secure_limit_ad_tracking) _ns=secure; _key=limit_ad_tracking ;;
            user_*_secure_limit_ad_tracking) _ns=secure_user; _u=${_skey#user_}; _u=${_u%_secure_limit_ad_tracking}; _key=limit_ad_tracking ;;
            *) continue ;;
        esac

        _cur=$(aad_settings_get_value "$_ns" "$_u" "$_key"); _get_rc=$?
        if [ "$_get_rc" -ne 0 ]; then
            if [ "$_ns" = "secure_user" ]; then
                aad_user_presence_authoritative "$_u"; _upa_rc=$?
                if [ "$_upa_rc" -eq 1 ]; then
                    log "SETTING-RESTORE-RETIRED key=$_skey reason=user_absent"
                    continue
                fi
            fi
            printf '%s=%s|%s\n' "$_skey" "$_sorig" "$_sappl" >> "$_aros_tmp"
            _aros_pending=1
            log "SETTING-RESTORE-PENDING key=$_skey reason=read_failed"
            continue
        fi
        [ -n "$_cur" ] || _cur=null
        if [ "$_cur" != "$_sappl" ]; then
            log "SETTING-RESTORE-PRESERVE key=$_skey external=$_cur module_applied=$_sappl"
            continue
        fi
        if ! aad_settings_set_original "$_ns" "$_u" "$_key" "$_sorig"; then
            printf '%s=%s|%s\n' "$_skey" "$_sorig" "$_sappl" >> "$_aros_tmp"
            _aros_pending=1
            log "SETTING-RESTORE-PENDING key=$_skey reason=set_failed"
            continue
        fi
        _verify=$(aad_settings_get_value "$_ns" "$_u" "$_key"); _verify_rc=$?; [ -n "$_verify" ] || _verify=null
        _expect="${_sorig:-null}"
        if [ "$_verify_rc" -ne 0 ] || [ "$_verify" != "$_expect" ]; then
            printf '%s=%s|%s\n' "$_skey" "$_sorig" "$_sappl" >> "$_aros_tmp"
            _aros_pending=1
            log "SETTING-RESTORE-PENDING key=$_skey reason=verify_failed current=${_verify:-unknown} expected=$_expect"
        else
            log "SETTING-RESTORED key=$_skey -> $_expect"
        fi
    done < "$_aros_backup"

    chmod 600 "$_aros_tmp" 2>/dev/null || true
    if [ -s "$_aros_tmp" ]; then
        mv -f "$_aros_tmp" "$_aros_backup" 2>/dev/null || { rm -f "$_aros_tmp"; return 1; }
    else
        rm -f "$_aros_tmp" "$_aros_backup" 2>/dev/null
    fi
    [ "$_aros_pending" -eq 0 ]
}

aad_apply_zero_ad_id() {
    command -v settings >/dev/null 2>&1 || return 1
    _backup_file="$DATA_DIR/.ad_id_backup"
    _backup_tmp=$(aad_mktemp_near "$_backup_file")
    [ -n "$_backup_tmp" ] || return 1
    [ -f "$_backup_file" ] && cat "$_backup_file" > "$_backup_tmp" 2>/dev/null || : > "$_backup_tmp"

    aad_backup_setting_line() {
        _bsl_key="$1"; _bsl_ns="$2"; _bsl_user="$3"; _bsl_name="$4"
        grep -q "^${_bsl_key}=" "$_backup_tmp" 2>/dev/null && return 0
        _bsl_cur=$(aad_settings_get_value "$_bsl_ns" "$_bsl_user" "$_bsl_name") || return 1
        [ -n "$_bsl_cur" ] || _bsl_cur=null
        printf '%s=%s|1\n' "$_bsl_key" "$_bsl_cur" >> "$_backup_tmp" 2>/dev/null
    }

    _zad_users=$(list_user_ids_checked) || { rm -f "$_backup_tmp"; log "AD-ID-ZERO pending: user enumeration unavailable"; return 1; }
    aad_backup_setting_line global_ad_id_zero global 0 ad_id_zero || { rm -f "$_backup_tmp"; return 1; }
    aad_backup_setting_line global_limit_ad_tracking global 0 limit_ad_tracking || { rm -f "$_backup_tmp"; return 1; }
    aad_backup_setting_line secure_limit_ad_tracking secure 0 limit_ad_tracking || { rm -f "$_backup_tmp"; return 1; }
    for _u in $_zad_users; do
        aad_backup_setting_line "user_${_u}_secure_limit_ad_tracking" secure_user "$_u" limit_ad_tracking || { rm -f "$_backup_tmp"; return 1; }
    done
    chmod 600 "$_backup_tmp" 2>/dev/null || true
    mv -f "$_backup_tmp" "$_backup_file" 2>/dev/null || { rm -f "$_backup_tmp"; return 1; }

    _zad_failed=0
    settings put global ad_id_zero 1 >/dev/null 2>&1 || _zad_failed=1
    settings put global limit_ad_tracking 1 >/dev/null 2>&1 || _zad_failed=1
    settings put secure limit_ad_tracking 1 >/dev/null 2>&1 || _zad_failed=1
    for _u in $_zad_users; do settings put secure --user "$_u" limit_ad_tracking 1 >/dev/null 2>&1 || _zad_failed=1; done

    for _check in "global|0|ad_id_zero" "global|0|limit_ad_tracking" "secure|0|limit_ad_tracking"; do
        _ns=${_check%%|*}; _rest=${_check#*|}; _u=${_rest%%|*}; _key=${_rest#*|}
        _v=$(aad_settings_get_value "$_ns" "$_u" "$_key" 2>/dev/null) || _zad_failed=1
        [ "$_v" = "1" ] || _zad_failed=1
    done
    for _u in $_zad_users; do
        _v=$(aad_settings_get_value secure_user "$_u" limit_ad_tracking 2>/dev/null) || _zad_failed=1
        [ "$_v" = "1" ] || _zad_failed=1
    done
    if [ "$_zad_failed" -eq 0 ]; then
        log "AD-ID-ZERO applied and verified"
        return 0
    fi
    log "AD-ID-ZERO apply incomplete; ownership backup retained for retry/restore"
    return 1
}

aad_restore_webview_owned_state() {
    _rwos_dir="${1:-$DATA_DIR}"
    _rwos_cmd="/data/local/tmp/webview-command-line"
    _rwos_backup="$_rwos_dir/.webview_command_line_backup"
    _rwos_marker="$_rwos_dir/.webview_command_line_applied.cksum"
    [ -f "$_rwos_marker" ] || return 0
    _rwos_expected=$(cat "$_rwos_marker" 2>/dev/null)
    [ -n "$_rwos_expected" ] || return 1
    _rwos_current=$(cksum "$_rwos_cmd" 2>/dev/null | awk '{print $1 ":" $2}')
    if [ "$_rwos_current" != "$_rwos_expected" ]; then
        log "WEBVIEW-FLAGS-PRESERVE external content differs from module snapshot"
        rm -f "$_rwos_marker" "$_rwos_backup" 2>/dev/null
        return 0
    fi
    [ -f "$_rwos_backup" ] || return 1
    if grep -Fxq '__AAD_ABSENT__' "$_rwos_backup" 2>/dev/null; then
        rm -f "$_rwos_cmd" 2>/dev/null || return 1
        [ ! -e "$_rwos_cmd" ] || return 1
    else
        _rwos_tmp="${_rwos_cmd}.aad_restore.$$"
        cp "$_rwos_backup" "$_rwos_tmp" 2>/dev/null || { rm -f "$_rwos_tmp"; return 1; }
        mv -f "$_rwos_tmp" "$_rwos_cmd" 2>/dev/null || { rm -f "$_rwos_tmp"; return 1; }
        cmp -s "$_rwos_backup" "$_rwos_cmd" 2>/dev/null || return 1
    fi
    rm -f "$_rwos_marker" "$_rwos_backup" 2>/dev/null
    log "WEBVIEW-FLAGS restored and verified"
    return 0
}

reconcile_side_effects() {
    _rse_reason="${1:-reconcile}"
    _rse_ads_on=$(read_bool_setting BLOCK_ADS 0)
    _rse_analytics_on=$(read_bool_setting BLOCK_ANALYTICS 0)
    _rse_pending=0
    _rse_pending_file="$DATA_DIR/.side_effects.pending"

    # 1. Zero Advertising ID (подчиняется первичной политике)
    _zad_wanted=0
    if [ "$_rse_analytics_on" = "1" ] || [ "$_rse_ads_on" = "1" ]; then
        [ "$(read_bool_setting ZERO_AD_ID 0)" = "1" ] && _zad_wanted=1
    fi

    if [ "$_zad_wanted" = "1" ]; then
        aad_apply_zero_ad_id || _rse_pending=1
    elif [ -f "$DATA_DIR/.ad_id_backup" ]; then
        aad_restore_owned_settings "$DATA_DIR" || _rse_pending=1
    fi

    # 2. WebView command line flags (optional, ADS-only, default OFF)
    _wv_cmd="/data/local/tmp/webview-command-line"
    _wv_backup="$DATA_DIR/.webview_command_line_backup"
    _wv_wanted=0
    if [ "$_rse_ads_on" = "1" ] && [ "$(read_bool_setting BLOCK_WEBVIEW_ADS 0)" = "1" ]; then _wv_wanted=1; fi

    if [ "$_wv_wanted" = "1" ] && aad_is_webview_command_line_supported; then
        _wv_flags="_ --host-rules=\"MAP *.doubleclick.net 127.0.0.1, MAP *.an.yandex.ru 127.0.0.1, MAP *.googleads.g.doubleclick.net 127.0.0.1, MAP *.applovin.com 127.0.0.1, MAP *.unityads.unity3d.com 127.0.0.1, MAP *.vungle.com 127.0.0.1, MAP *.inmobi.com 127.0.0.1\""
        if [ ! -f "$_wv_backup" ]; then
            if [ -f "$_wv_cmd" ]; then
                cp "$_wv_cmd" "$_wv_backup" 2>/dev/null || { log "WEBVIEW-FLAGS apply skipped: backup failed"; _wv_wanted=0; _rse_pending=1; }
            else
                printf '__AAD_ABSENT__\n' > "$_wv_backup" 2>/dev/null || { _wv_wanted=0; _rse_pending=1; }
            fi
            chmod 600 "$_wv_backup" 2>/dev/null || true
        fi
        if [ "$_wv_wanted" = "1" ]; then
            _wv_tmp="${_wv_cmd}.aad.$$"
            if printf '%s\n' "$_wv_flags" > "$_wv_tmp" 2>/dev/null && mv -f "$_wv_tmp" "$_wv_cmd" 2>/dev/null; then
                _wv_ck=$(cksum "$_wv_cmd" 2>/dev/null | awk '{print $1 ":" $2}')
                if [ -n "$_wv_ck" ]; then
                    printf '%s\n' "$_wv_ck" > "$DATA_DIR/.webview_command_line_applied.cksum" 2>/dev/null || _rse_pending=1
                    chmod 0644 "$_wv_cmd" 2>/dev/null || true
                    log "WEBVIEW-FLAGS applied to $_wv_cmd"
                else
                    _rse_pending=1
                    log "WEBVIEW-FLAGS apply verification failed; ownership backup retained"
                fi
            else
                rm -f "$_wv_tmp" 2>/dev/null
                _rse_pending=1
                log "WEBVIEW-FLAGS apply failed; ownership backup retained"
            fi
        fi
    else
        [ "$_wv_wanted" = "1" ] && log "WEBVIEW-FLAGS-BYPASS: unsupported environment; restoring any previous owned state"
        if [ -f "$DATA_DIR/.webview_command_line_applied.cksum" ]; then
            aad_restore_webview_owned_state "$DATA_DIR" || _rse_pending=1
        fi
    fi

    # 3. AppOps desired state (ADS-only)
    if [ -f "$DATA_DIR/.appops_state" ]; then
        _aop_wanted=0
        if [ "$_rse_ads_on" = "1" ]; then _aop_wanted=$(read_bool_setting BLOCK_OVERLAY_ADS 0); fi
        if [ "$_aop_wanted" != "1" ]; then
            aad_restore_appops_state "" "" || _rse_pending=1
        fi
    fi

    # 4. Ad Killer Firewall (подчиняется BLOCK_ADS=1)
    if [ "$_rse_ads_on" = "1" ]; then
        reconcile_ad_surface_killer "$_rse_reason" >/dev/null 2>&1 || _rse_pending=1
    else
        ad_killer_cleanup DISABLED "$_rse_reason" >/dev/null 2>&1 || _rse_pending=1
        rm -f "$DATA_DIR/.ad_killer_active" 2>/dev/null || true
    fi

    if [ "$_rse_pending" -ne 0 ]; then
        printf '%s\n' "$(date +%s 2>/dev/null)|$_rse_reason" > "$_rse_pending_file" 2>/dev/null || true
        log "SIDE-EFFECTS-PENDING reason=$_rse_reason; retry scheduled"
        return 1
    fi
    rm -f "$_rse_pending_file" 2>/dev/null || true
    return 0
}

policy_list_symmetric_diff() {
    old_file="$1"
    new_file="$2"
    awk '
        NR==FNR { if ($0!="") old[$0]=1; next }
        { if ($0!="") new[$0]=1 }
        END {
            for (k in old) if (!(k in new)) print k
            for (k in new) if (!(k in old)) print k
        }
    ' "$old_file" "$new_file" 2>/dev/null
}

collect_whitelist_delta_packages() {
    work="$DATA_DIR/.whitelist_delta.$$"
    cur_g="$work.global"; cur_a="$work.ads"; cur_n="$work.analytics"
    read_global_list > "$cur_g"
    read_category_list ADS > "$cur_a"
    read_category_list ANALYTICS > "$cur_n"

    : > "$work"
    policy_list_symmetric_diff "$CACHE_GLOBAL" "$cur_g" >> "$work"
    policy_list_symmetric_diff "$CACHE_ADS" "$cur_a" >> "$work"
    policy_list_symmetric_diff "$CACHE_ANALYTICS" "$cur_n" >> "$work"
    sort -u "$work" 2>/dev/null
    rm -f "$work" "$cur_g" "$cur_a" "$cur_n" 2>/dev/null
}

reconcile_whitelist_delta_locked() {
    changed=$(aad_mktemp_near "$DATA_DIR/.whitelist_changed")
    installed_snapshot=$(aad_mktemp_near "$DATA_DIR/.installed_keys.delta")
    if [ -z "$changed" ] || [ -z "$installed_snapshot" ]; then
        log "CONFIG-DELTA: temp-file allocation failed."
        [ -n "$changed" ] && rm -f "$changed" 2>/dev/null
        [ -n "$installed_snapshot" ] && rm -f "$installed_snapshot" 2>/dev/null
        return 1
    fi
    collect_whitelist_delta_packages > "$changed"
    log "CONFIG-DELTA: building installed-package snapshot."
    if ! list_all_installed_package_keys > "$installed_snapshot"; then
        log "CONFIG-DELTA failed: authoritative installed-package snapshot unavailable"
        rm -f "$changed" "$installed_snapshot" 2>/dev/null
        return 1
    fi
    log "CONFIG-DELTA: installed-package snapshot ready entries=$(grep -c . "$installed_snapshot" 2>/dev/null)."
    count=$(grep -c . "$changed" 2>/dev/null)
    [ -n "$count" ] || count=0

    if [ "$count" -eq 0 ]; then
        log "CONFIG-DELTA: whitelist files changed but normalized package policy is unchanged."
        rm -f "$changed" "$installed_snapshot" 2>/dev/null
        return 0
    fi

    log "CONFIG-DELTA: whitelist package changes=$count; reconciling affected packages only."
    for _cdl_file in "$COMPONENT_AUDIT_FILE" "$SDK_FINGERPRINT_FILE"; do
        [ -f "$_cdl_file" ] || continue
        _cdl_tmp=$(aad_mktemp_near "$_cdl_file")
        [ -n "$_cdl_tmp" ] || continue
        if awk -F'|' -v pf="$changed" '
                BEGIN {while ((getline line < pf) > 0) if (line != "") drop[line]=1; close(pf)}
                NR==1 {print; next}
                !($3 in drop) {print}
            ' "$_cdl_file" > "$_cdl_tmp" 2>/dev/null; then
            chmod 600 "$_cdl_tmp" 2>/dev/null || true
            mv -f "$_cdl_tmp" "$_cdl_file" 2>/dev/null || rm -f "$_cdl_tmp" 2>/dev/null
        else
            rm -f "$_cdl_tmp" 2>/dev/null
        fi
    done
    AAD_AUDIT_ROWS_PRECLEANED=1
    export AAD_AUDIT_ROWS_PRECLEANED

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        log "CONFIG-DELTA package=$pkg global=$(is_globally_whitelisted "$pkg" && echo yes || echo no) ads=$(is_category_whitelisted "$pkg" ADS && echo yes || echo no) analytics=$(is_category_whitelisted "$pkg" ANALYTICS && echo yes || echo no)"
        process_package_all_users "$pkg" "$installed_snapshot" >/dev/null
        rc=$?
        log "CONFIG-DELTA package=$pkg complete rc=$rc"
        [ "$rc" -eq 2 ] && { rm -f "$changed" "$installed_snapshot" 2>/dev/null; unset AAD_AUDIT_ROWS_PRECLEANED; return 2; }
    done < "$changed"
    rm -f "$changed" "$installed_snapshot" 2>/dev/null
    unset AAD_AUDIT_ROWS_PRECLEANED
    rm -f "$PACKAGE_VERIFIED_HASH_FILE" 2>/dev/null
    log "CONFIG-DELTA: reconciliation complete."
    return 0
}

refresh_policy_caches() {
    read_category_list ADS > "$CACHE_ADS"
    read_category_list ANALYTICS > "$CACHE_ANALYTICS"
    read_global_list > "$CACHE_GLOBAL"
}

reconcile_config_if_changed() {
    reason="${1:-unknown}"
    _rcc_round=0
    _rcc_last_rc=0
    _rcc_force=0

    while [ "$_rcc_round" -lt 3 ]; do
        _rcc_round=$((_rcc_round + 1))
        if [ -d "$LOCK_DIR" ] && aad_lock_owner_alive "$LOCK_DIR"; then
            owner=$(cat "$LOCK_DIR/pid" 2>/dev/null)
            log "CONFIG-DEFER: reconciliation already active owner=$owner reason=$reason; active owner will coalesce live config on completion"
            return 0
        fi

        rebuild_composite_rules || {
            log "CONFIG-REBUILD-FAILED: composite rules generation failed; deferring reconcile."
            return 1
        }
        acquire_lock || { log "CONFIG-DEFER: could not acquire reconciliation lock reason=$reason"; return 0; }
        aad_policy_snapshot_begin || { release_lock; log "CONFIG-SNAPSHOT-FAILED reason=$reason"; return 1; }

        _rcc_start="$AAD_POLICY_START_HASH"
        _rcc_previous=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)
        if [ "$_rcc_force" = "0" ] && [ "$_rcc_start" = "$_rcc_previous" ] && aad_candidate_cache_valid; then
            aad_write_reconcile_status IDLE NOOP "$_rcc_start" "applied=yes source=$reason"
            aad_policy_snapshot_end
            release_lock
            return 0
        fi

        AAD_PROTECTED_CACHE_ACTIVE=1
        export AAD_PROTECTED_CACHE_ACTIVE
        _rcc_mode="DEEP"
        aad_write_reconcile_status RUNNING "$_rcc_mode" "$_rcc_start" "source=$reason round=$_rcc_round"

        _rcc_candidate_discovery=$(cat "$DISCOVERY_HASH_FILE" 2>/dev/null)
        _rcc_candidate_nonprimary=$(cat "$NON_PRIMARY_HASH_FILE" 2>/dev/null)
        _rcc_scope=$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)
        if [ -f "$CANDIDATE_FILE" ] && [ "$_rcc_candidate_discovery" = "$AAD_POLICY_DISCOVERY_HASH" ] && [ "$_rcc_candidate_nonprimary" = "$AAD_POLICY_NON_PRIMARY_HASH" ]; then
            if [ "$(read_include_system_apps)" = "1" ] && [ "$_rcc_scope" = "USER" ]; then
                _rcc_mode="SYSTEM_EXPAND"
                aad_write_reconcile_status RUNNING "$_rcc_mode" "$_rcc_start" "source=$reason round=$_rcc_round"
                expand_system_candidates_locked
                rc=$?
                if [ "$rc" -eq 0 ]; then
                    _rcc_mode="FAST"
                    aad_write_reconcile_status RUNNING "$_rcc_mode" "$_rcc_start" "source=$reason round=$_rcc_round after=system-expand"
                    fast_policy_reconcile_locked
                    rc=$?
                fi
            else
                _rcc_mode="FAST"
                aad_write_reconcile_status RUNNING "$_rcc_mode" "$_rcc_start" "source=$reason round=$_rcc_round"
                fast_policy_reconcile_locked
                rc=$?
            fi
        else
            log "CONFIG changed -> deep discovery source=$reason candidate_cache=$([ -f "$CANDIDATE_FILE" ] && echo present || echo missing)"
            full_rescan_locked
            rc=$?
        fi

        unset AAD_PROTECTED_CACHE_ACTIVE
        rm -f "$DATA_DIR"/.dyn_prot_u* "$DATA_DIR"/.dyn_prot_unknown_u* 2>/dev/null || true

        _rcc_latest=$(compute_config_hash)
        if [ "$rc" -eq 0 ] && [ "$_rcc_latest" = "$_rcc_start" ]; then
            refresh_policy_caches
            printf '%s\n' "$_rcc_start" > "$CONFIG_HASH_FILE"
            compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"
            printf '%s\n' "$AAD_POLICY_DISCOVERY_HASH" > "$DISCOVERY_HASH_FILE"
            printf '%s\n' "$AAD_POLICY_NON_PRIMARY_HASH" > "$NON_PRIMARY_HASH_FILE"
            printf '%s|%s|%s\n' "$_rcc_start" "$(date +%s 2>/dev/null)" "$_rcc_mode" > "$APPLIED_GENERATION_FILE" 2>/dev/null
            aad_write_reconcile_status IDLE "$_rcc_mode" "$_rcc_start" "applied=yes source=$reason"
        elif [ "$rc" -eq 0 ]; then
            log "CONFIG-COALESCE: generation changed while $_rcc_mode was running old=$_rcc_start latest=$_rcc_latest; old generation not marked applied"
            aad_write_reconcile_status PENDING "$_rcc_mode" "$_rcc_start" "latest=$_rcc_latest source=$reason"
        else
            aad_write_reconcile_status FAILED "$_rcc_mode" "$_rcc_start" "rc=$rc source=$reason"
        fi

        _rcc_generation_applied=0
        [ "$rc" -eq 0 ] && [ "$_rcc_latest" = "$_rcc_start" ] && _rcc_generation_applied=1
        aad_policy_snapshot_end
        release_lock
        if [ "$_rcc_generation_applied" = "1" ]; then
            reconcile_side_effects "config:$reason" >/dev/null 2>&1 || true
            launch_ad_surface_indexer_bg "config:$reason" >/dev/null 2>&1 || true
        fi
        _rcc_last_rc=$rc

        [ "$rc" -eq 0 ] || return "$rc"
        _rcc_now=$(compute_config_hash)
        _rcc_applied=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)
        if [ "$_rcc_now" = "$_rcc_applied" ] && [ "$_rcc_generation_applied" = "1" ]; then
            return 0
        fi
        _rcc_force=1
        log "CONFIG-COALESCE: immediately reconciling latest generation round=$((_rcc_round + 1)) force=$_rcc_force"
        reason="coalesced:$reason"
    done

    log "CONFIG-COALESCE-PENDING: more than 3 generations changed during reconcile; watcher will continue with latest"
    return "$_rcc_last_rc"
}

AAD_FULL_VERIFY_MAX_AGE=${AAD_FULL_VERIFY_MAX_AGE:-86400}

aad_full_verify_due() {
    _afvd_now=$(date +%s 2>/dev/null)
    case "$_afvd_now" in ''|*[!0-9]*) return 0 ;; esac
    _afvd_last=$(cat "$LAST_FULL_VERIFY_FILE" 2>/dev/null)
    case "$_afvd_last" in ''|*[!0-9]*) return 0 ;; esac
    [ $((_afvd_now - _afvd_last)) -ge "$AAD_FULL_VERIFY_MAX_AGE" ]
}

aad_mark_full_verify() {
    date +%s > "$LAST_FULL_VERIFY_FILE" 2>/dev/null || true
}

aad_verified_set_load() {
    _avsl_hash="$1"
    AAD_VERIFIED_SET=""
    [ -f "$PACKAGE_VERIFIED_FILE" ] || return 1
    [ "$(cat "$PACKAGE_VERIFIED_HASH_FILE" 2>/dev/null)" = "$_avsl_hash" ] || return 1
    AAD_VERIFIED_SET=$(cat "$PACKAGE_VERIFIED_FILE" 2>/dev/null)
    [ -n "$AAD_VERIFIED_SET" ]
}

aad_package_verified() {
    case "$AAD_VERIFIED_SET" in
        *"|$1|$2|$3|"*) return 0 ;;
        *) return 1 ;;
    esac
}

full_rescan_locked() {
    AAD_TIMING_TOTAL_START=$(aad_now_ms)
    installed_keys="$DATA_DIR/.installed_keys.$$"
    if ! list_all_installed_package_keys > "$installed_keys"; then
        rm -f "$installed_keys" 2>/dev/null
        log "FULL-SCAN aborted: installed-user snapshot unavailable"
        return 1
    fi
    new_state="$DATA_DIR/package_state.tmp.$$"
    if ! list_all_package_state > "$new_state"; then
        rm -f "$installed_keys" "$new_state" 2>/dev/null
        log "FULL-SCAN aborted: desired-user snapshot unavailable"
        return 1
    fi
    reconcile_out_of_scope_records "$installed_keys" "$new_state"
    cleanup_stale_records "$installed_keys"
    retry_orphan_restores
    total=0
    processed=0
    skipped=0
    aborted=0
    _full_package_failed=0
    AAD_AUDIT_CARRY="$COMPONENT_AUDIT_FILE.carry"
    AAD_SDK_CARRY="$SDK_FINGERPRINT_FILE.carry"
    AAD_DISCOVERY_FAILED_FILE="$DATA_DIR/.discovery_failed.$$"
    export AAD_DISCOVERY_FAILED_FILE
    rm -f "$AAD_AUDIT_CARRY" "$AAD_SDK_CARRY" "$AAD_DISCOVERY_FAILED_FILE" 2>/dev/null
    [ -s "$COMPONENT_AUDIT_FILE" ] && cp "$COMPONENT_AUDIT_FILE" "$AAD_AUDIT_CARRY" 2>/dev/null
    [ -s "$SDK_FINGERPRINT_FILE" ] && cp "$SDK_FINGERPRINT_FILE" "$AAD_SDK_CARRY" 2>/dev/null

    AAD_POLICY_FINGERPRINT="${AAD_POLICY_START_HASH:-$(compute_config_hash)}"
    AAD_SKIPPED_KEYS="$DATA_DIR/.scan_skipped.$$"
    AAD_VERIFIED_NEW="$PACKAGE_VERIFIED_FILE.new.$$"
    : > "$AAD_SKIPPED_KEYS"; : > "$AAD_VERIFIED_NEW"
    aad_fast_path=0
    if aad_full_verify_due; then
        log "FAST-PATH disabled: periodic full verification due (max_age=${AAD_FULL_VERIFY_MAX_AGE}s)"
    elif aad_verified_set_load "$AAD_POLICY_FINGERPRINT"; then
        aad_fast_path=1
        log "FAST-PATH enabled: reusing verification for unchanged packages policy=$AAD_POLICY_FINGERPRINT"
    else
        log "FAST-PATH unavailable: no verified set for policy=$AAD_POLICY_FINGERPRINT (rules/settings changed or first run)"
    fi
    printf 'timestamp|user|package|category|type|risk|action|component\n' > "$COMPONENT_AUDIT_FILE" 2>/dev/null
    chmod 600 "$COMPONENT_AUDIT_FILE" 2>/dev/null
    printf 'timestamp|user|package|category|sdk|evidence\n' > "$SDK_FINGERPRINT_FILE" 2>/dev/null
    chmod 600 "$SDK_FINGERPRINT_FILE" 2>/dev/null
    printf 'timestamp|user|package|apk|parser|encoding|strings|class_tokens|exact_hits|audit_hits|verified|verify_miss|cache\n' > "$MANIFEST_SCAN_FILE" 2>/dev/null
    chmod 600 "$MANIFEST_SCAN_FILE" 2>/dev/null
    AAD_MANIFEST_STATS_FILE="$MANIFEST_SCAN_FILE"
    export AAD_MANIFEST_STATS_FILE
    AAD_MANIFEST_CACHE_ENABLED=1
    AAD_MANIFEST_RULES_HASH=$(aad_manifest_rules_hash)
    export AAD_MANIFEST_CACHE_ENABLED AAD_MANIFEST_RULES_HASH
    mkdir -p "$MANIFEST_CACHE_DIR" 2>/dev/null
    chmod 700 "$MANIFEST_CACHE_DIR" 2>/dev/null || true
    aad_manifest_cache_gc "$new_state"
    log "MANIFEST-CACHE enabled schema=v1 rules_hash=$AAD_MANIFEST_RULES_HASH dir=$MANIFEST_CACHE_DIR"
    AAD_AUDIT_FULL_SCAN=1
    export AAD_AUDIT_FULL_SCAN

    AAD_FAIL_FAST_STATE="$DATA_DIR/.fail_fast_count.$$"
    AAD_FAIL_FAST_ABORT="$DATA_DIR/.fail_fast_abort.$$"
    export AAD_FAIL_FAST_STATE AAD_FAIL_FAST_ABORT
    rm -f "$AAD_FAIL_FAST_ABORT" 2>/dev/null
    printf '0\n' > "$AAD_FAIL_FAST_STATE" 2>/dev/null

    scan_total=$(grep -c '|' "$new_state" 2>/dev/null)
    [ -n "$scan_total" ] || scan_total=0

    AAD_APK_PATH_CACHE="$DATA_DIR/.apk_paths.$$"
    export AAD_APK_PATH_CACHE
    AAD_TIMING_INVENTORY_START=$(aad_now_ms)
    if build_apk_path_inventory "$AAD_APK_PATH_CACHE"; then
        apk_inventory_count=$(grep -c '|' "$AAD_APK_PATH_CACHE" 2>/dev/null); [ -n "$apk_inventory_count" ] || apk_inventory_count=0
        log "MANIFEST-PATH-INVENTORY entries=$apk_inventory_count file=$AAD_APK_PATH_CACHE"
    else
        : > "$AAD_APK_PATH_CACHE" 2>/dev/null
        log "MANIFEST-PATH-INVENTORY failed; per-package path fallback remains active"
    fi
    AAD_TIMING_INVENTORY_END=$(aad_now_ms)

    SCAN_CANDIDATE_CACHE_DIR="$DATA_DIR/.scan_candidates.$$"
    export SCAN_CANDIDATE_CACHE_DIR
    rm -rf "$SCAN_CANDIDATE_CACHE_DIR" 2>/dev/null
    mkdir -p "$SCAN_CANDIDATE_CACHE_DIR" 2>/dev/null

    [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "Packages/users to check: $scan_total"
    AAD_TIMING_PACKAGE_START=$(aad_now_ms)

    while IFS='|' read -r user pkg vc; do
        [ -z "$pkg" ] && continue
        processed=$((processed + 1))
        if [ "$aad_fast_path" = "1" ] && aad_package_verified "$user" "$pkg" "$vc"; then
            printf '|%s|%s|%s|\n' "$user" "$pkg" "$vc" >> "$AAD_VERIFIED_NEW"
            printf '%s|%s\n' "$user" "$pkg" >> "$AAD_SKIPPED_KEYS"
            skipped=$((skipped + 1))
            continue
        fi
        [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "[$processed/$scan_total] u$user $pkg"
        AAD_CURRENT_VERSION_CODE="$vc"
        export AAD_CURRENT_VERSION_CODE
        n=$(process_package_user "$user" "$pkg")
        rc=$?
        [ "$rc" -eq 0 ] && printf '|%s|%s|%s|\n' "$user" "$pkg" "$vc" >> "$AAD_VERIFIED_NEW"
        [ "$rc" -eq 0 ] || _full_package_failed=1
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
        if [ "$rc" -eq 2 ] || [ -f "$AAD_FAIL_FAST_ABORT" ]; then
            aborted=1
            break
        fi
    done < "$new_state"
    AAD_TIMING_PACKAGE_END=$(aad_now_ms)
    _full_discovery_failed=0
    [ -f "$AAD_DISCOVERY_FAILED_FILE" ] && _full_discovery_failed=1

    if [ "$skipped" -gt 0 ]; then
        for _cf in "$AAD_AUDIT_CARRY:$COMPONENT_AUDIT_FILE" "$AAD_SDK_CARRY:$SDK_FINGERPRINT_FILE"; do
            _csrc=${_cf%%:*}; _cdst=${_cf#*:}
            [ -s "$_csrc" ] || continue
            awk -F'|' -v kf="$AAD_SKIPPED_KEYS" '
                BEGIN {while ((getline line < kf) > 0) if (line != "") keep[line]=1; close(kf)}
                NR==1 {next}
                (($2 "|" $3) in keep) {print}
            ' "$_csrc" >> "$_cdst" 2>/dev/null
        done
        log "FAST-PATH carried audit rows for $skipped skipped package(s)"
    fi
    rm -f "$AAD_AUDIT_CARRY" "$AAD_SDK_CARRY" "$AAD_SKIPPED_KEYS" 2>/dev/null

    if [ "$aborted" -ne 1 ] && [ "$_full_discovery_failed" -eq 0 ] && [ -s "$AAD_VERIFIED_NEW" ]; then
        chmod 600 "$AAD_VERIFIED_NEW" 2>/dev/null || true
        if mv -f "$AAD_VERIFIED_NEW" "$PACKAGE_VERIFIED_FILE" 2>/dev/null; then
            printf '%s\n' "$AAD_POLICY_FINGERPRINT" > "$PACKAGE_VERIFIED_HASH_FILE" 2>/dev/null
            [ "$aad_fast_path" = "1" ] || aad_mark_full_verify
        fi
    fi
    rm -f "$AAD_VERIFIED_NEW" 2>/dev/null
    log "SCAN-EFFICIENCY packages=$processed reconciled=$((processed - skipped)) skipped_unchanged=$skipped fast_path=$aad_fast_path"

    rm -rf "$SCAN_CANDIDATE_CACHE_DIR" 2>/dev/null
    unset SCAN_CANDIDATE_CACHE_DIR
    aad_package_dump_cache_reset
    rm -f "$AAD_APK_PATH_CACHE" 2>/dev/null
    unset AAD_APK_PATH_CACHE
    unset AAD_AUDIT_FULL_SCAN
    unset AAD_MANIFEST_STATS_FILE
    unset AAD_MANIFEST_CACHE_ENABLED AAD_MANIFEST_RULES_HASH AAD_CURRENT_VERSION_CODE
    rm -f "$AAD_FAIL_FAST_STATE" 2>/dev/null
    if [ "$_full_discovery_failed" -eq 0 ] && [ -s "$new_state" ]; then
        mv -f "$new_state" "$STATE_FILE"
    else
        rm -f "$new_state" 2>/dev/null
        if [ "$_full_discovery_failed" -ne 0 ]; then
            log "PACKAGE-STATE-PRESERVED: discovery failed for at least one package; previous authoritative baseline retained."
        else
            log "PACKAGE-STATE-SKIP: enumeration returned no packages; previous baseline preserved."
        fi
    fi

    if [ "$aborted" -eq 1 ]; then
        rm -f "$AAD_FAIL_FAST_ABORT" 2>/dev/null
        unset AAD_FAIL_FAST_STATE AAD_FAIL_FAST_ABORT
        rm -f "$installed_keys" 2>/dev/null
        log "FULL-SCAN aborted by fail-fast: packages/users=$processed operations=$total limit=${AAD_FAIL_FAST_LIMIT:-0}"
        [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "Stopped early: ${AAD_FAIL_FAST_LIMIT:-0} consecutive component failures. Logs preserved."
        return 2
    fi

    rm -f "$AAD_FAIL_FAST_ABORT" 2>/dev/null
    unset AAD_FAIL_FAST_STATE AAD_FAIL_FAST_ABORT
    AAD_TIMING_IFW_START=$(aad_now_ms)
    if ! reconcile_owned_ifw_rules; then
        rm -f "$installed_keys" 2>/dev/null
        log "FULL-SCAN: IFW reconciliation failed."
        return 1
    fi
    AAD_TIMING_IFW_END=$(aad_now_ms)
    if [ "$_full_discovery_failed" -ne 0 ]; then
        rm -f "$installed_keys" "$AAD_DISCOVERY_FAILED_FILE" 2>/dev/null
        unset AAD_DISCOVERY_FAILED_FILE
        log "FULL-SCAN incomplete: at least one package discovery FAILED; previous candidate generation preserved and retry required."
        return 1
    fi
    rm -f "$AAD_DISCOVERY_FAILED_FILE" 2>/dev/null
    unset AAD_DISCOVERY_FAILED_FILE
    if aad_candidate_cache_rebuild_from_audit; then
        printf '%s\n' "${AAD_POLICY_DISCOVERY_HASH:-$(compute_discovery_policy_hash)}" > "$DISCOVERY_HASH_FILE"
        printf '%s\n' "${AAD_POLICY_NON_PRIMARY_HASH:-$(compute_non_primary_settings_hash)}" > "$NON_PRIMARY_HASH_FILE"
        if [ "$(read_include_system_apps)" = "1" ]; then echo ALL > "$CANDIDATE_SCOPE_FILE"; else echo USER > "$CANDIDATE_SCOPE_FILE"; fi
        if ! aad_scope_cache_build_authoritative; then
            log "SCOPE-CACHE rebuild deferred after deep discovery; FAST will retry authoritative package scope capture"
            rm -f "$PACKAGE_SCOPE_CACHE" 2>/dev/null
        fi
        log "CANDIDATE-CACHE rebuilt entries=$(grep -c . "$CANDIDATE_FILE" 2>/dev/null) scope=$(cat "$CANDIDATE_SCOPE_FILE" 2>/dev/null)"
    else
        log "CANDIDATE-CACHE rebuild failed; next policy change will use deep discovery"
        rm -f "$DISCOVERY_HASH_FILE" "$NON_PRIMARY_HASH_FILE" "$CANDIDATE_SCOPE_FILE" 2>/dev/null
    fi
    rm -f "$installed_keys" 2>/dev/null
    audit_summary=$(awk -F'|' '
        NR>1 {
            total++
            packages[$2 "|" $3]=1
            categories[$4]++
            risks[$6]++
            actions[$7]++
        }
        END {
            package_count=0
            for (key in packages) package_count++
            printf "candidates=%d packages/users=%d ads=%d analytics=%d safe=%d balanced=%d aggressive=%d hybrid=%d audit_only=%d disable=%d ifw_block=%d report_only=%d skipped=%d", total, package_count, categories["ADS"]+0, categories["ANALYTICS"]+0, risks["SAFE"]+0, risks["BALANCED"]+0, risks["AGGRESSIVE"]+0, risks["HYBRID"]+0, risks["AUDIT"]+0, actions["DISABLE"]+0, actions["IFW_BLOCK"]+0, actions["REPORT_ONLY"]+0, actions["SKIP_POLICY"]+0
        }
    ' "$COMPONENT_AUDIT_FILE" 2>/dev/null)
    log "AUDIT-SUMMARY mode=$(read_component_mode) backend=$(read_component_backend) $audit_summary file=$COMPONENT_AUDIT_FILE"
    sdk_summary=$(awk -F'|' 'NR>1 {detections++; packages[$2 "|" $3]=1; sdks[$5]=1} END {pc=0; sc=0; for (k in packages) pc++; for (k in sdks) sc++; printf "detections=%d packages/users=%d sdk_types=%d", detections+0, pc, sc}' "$SDK_FINGERPRINT_FILE" 2>/dev/null)
    log "SDK-SUMMARY $sdk_summary file=$SDK_FINGERPRINT_FILE"
    manifest_summary=$(awk -F'|' 'NR>1 {
        packages[$2 "|" $3]=1;
        if ($5=="path-miss") {pathmiss++; next}
        apks++;
        if ($5=="path-inaccessible") {inaccessible++; failed++; next}
        if ($5=="extract-failed") {extractfail++; failed++; next}
        scanned++; enc[$6]++; strings+=$7; tokens+=$8; exact+=$9; audit+=$10; verified+=$11; miss+=$12; cache[$13]++;
        if ($6=="UNKNOWN") failed++;
    } END {
        pc=0; for (k in packages) pc++;
        printf "packages/users=%d apks_seen=%d apks_processed=%d apks_parsed=%d utf8=%d utf16=%d text=%d path_miss=%d inaccessible=%d extract_failed=%d failed=%d strings=%d class_tokens=%d exact_hits=%d audit_hits=%d verified=%d verify_miss=%d cache_full_hit=%d cache_parse_hit=%d cache_miss=%d", pc, apks+0, scanned+0, cache["MISS"]+0, enc["UTF8"]+0, enc["UTF16"]+0, enc["TEXT"]+0, pathmiss+0, inaccessible+0, extractfail+0, failed+0, strings+0, tokens+0, exact+0, audit+0, verified+0, miss+0, cache["FULL_HIT"]+0, cache["PARSE_HIT"]+0, cache["MISS"]+0
    }' "$MANIFEST_SCAN_FILE" 2>/dev/null)
    log "MANIFEST-SUMMARY $manifest_summary file=$MANIFEST_SCAN_FILE"
    AAD_TIMING_TOTAL_END=$(aad_now_ms)
    timing_inventory=$(aad_elapsed_ms "$AAD_TIMING_INVENTORY_START" "$AAD_TIMING_INVENTORY_END")
    timing_packages=$(aad_elapsed_ms "$AAD_TIMING_PACKAGE_START" "$AAD_TIMING_PACKAGE_END")
    timing_ifw=$(aad_elapsed_ms "$AAD_TIMING_IFW_START" "$AAD_TIMING_IFW_END")
    timing_total=$(aad_elapsed_ms "$AAD_TIMING_TOTAL_START" "$AAD_TIMING_TOTAL_END")
    log "TIMING-SUMMARY inventory_ms=$timing_inventory package_reconcile_ms=$timing_packages ifw_ms=$timing_ifw total_ms=$timing_total"
    log "FULL-SCAN finished: packages/users=$processed operations=$total package_failed=$_full_package_failed"
    [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "Scan complete: $processed checked, $total policy operations."
    [ "$_full_package_failed" -eq 0 ] || return 1
    return 0
}

full_rescan() {
    acquire_lock || { log "LOCK timeout: full rescan skipped"; return 1; }
    aad_policy_snapshot_begin || { release_lock; return 1; }
    AAD_PROTECTED_CACHE_ACTIVE=1
    export AAD_PROTECTED_CACHE_ACTIVE
    aad_write_reconcile_status RUNNING DEEP_MANUAL "$AAD_POLICY_START_HASH" "source=manual/full"
    full_rescan_locked
    _fr_rc=$?
    _fr_start="$AAD_POLICY_START_HASH"
    unset AAD_PROTECTED_CACHE_ACTIVE
    rm -f "$DATA_DIR"/.dyn_prot_u* "$DATA_DIR"/.dyn_prot_unknown_u* 2>/dev/null || true
    _fr_latest=$(compute_config_hash)
    if [ "$_fr_rc" -eq 0 ] && [ "$_fr_latest" = "$_fr_start" ]; then
        printf '%s\n' "$_fr_start" > "$CONFIG_HASH_FILE"
        compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"
        printf '%s|%s|DEEP_MANUAL\n' "$_fr_start" "$(date +%s 2>/dev/null)" > "$APPLIED_GENERATION_FILE" 2>/dev/null
        aad_write_reconcile_status IDLE DEEP_MANUAL "$_fr_start" "applied=yes"
    elif [ "$_fr_rc" -eq 0 ]; then
        aad_write_reconcile_status PENDING DEEP_MANUAL "$_fr_start" "latest=$_fr_latest"
    else
        aad_write_reconcile_status FAILED DEEP_MANUAL "$_fr_start" "rc=$_fr_rc"
    fi
    aad_policy_snapshot_end
    release_lock
    reconcile_side_effects "full_rescan"
    if [ "$_fr_rc" -eq 0 ] && [ "$_fr_latest" != "$_fr_start" ]; then
        reconcile_config_if_changed "post-manual-coalesce" >/dev/null 2>&1 || true
    fi
    return "$_fr_rc"
}

aad_verified_forget() {
    [ -f "$PACKAGE_VERIFIED_FILE" ] || return 0
    _avf_tmp=$(aad_mktemp_near "$PACKAGE_VERIFIED_FILE")
    [ -n "$_avf_tmp" ] || return 1
    if grep -v "^|$1|$2|" "$PACKAGE_VERIFIED_FILE" > "$_avf_tmp" 2>/dev/null; then
        mv -f "$_avf_tmp" "$PACKAGE_VERIFIED_FILE" 2>/dev/null || rm -f "$_avf_tmp" 2>/dev/null
    else
        rm -f "$_avf_tmp" 2>/dev/null
    fi
    return 0
}

rescan_changed_packages_locked() {
    current="$DATA_DIR/package_state.current.$$"
    old_count=$(grep -c '|' "$STATE_FILE" 2>/dev/null); [ -n "$old_count" ] || old_count=0
    if ! list_all_package_state > "$current"; then
        rm -f "$current" 2>/dev/null
        log "PACKAGE-DELTA-SKIP: authoritative user/package enumeration failed; previous baseline preserved."
        return 1
    fi
    new_count=$(grep -c '|' "$current" 2>/dev/null); [ -n "$new_count" ] || new_count=0
    AAD_PACKAGE_CHANGES=0
    _delta_failed=0
    if [ ! -s "$current" ]; then
        rm -f "$current" 2>/dev/null
        log "PACKAGE-DELTA-SKIP: enumeration returned no packages; nothing reconciled."
        return 0
    fi

    AAD_APK_PATH_CACHE="$DATA_DIR/.apk_paths.delta.$$"
    export AAD_APK_PATH_CACHE
    if build_apk_path_inventory "$AAD_APK_PATH_CACHE"; then
        log "PACKAGE-DELTA path inventory entries=$(grep -c '|' "$AAD_APK_PATH_CACHE" 2>/dev/null)"
    else
        : > "$AAD_APK_PATH_CACHE" 2>/dev/null
    fi
    AAD_MANIFEST_CACHE_ENABLED=1
    AAD_MANIFEST_RULES_HASH=$(aad_manifest_rules_hash)
    export AAD_MANIFEST_CACHE_ENABLED AAD_MANIFEST_RULES_HASH
    [ "$old_count" -ne "$new_count" ] 2>/dev/null && AAD_PACKAGE_CHANGES=1

    while IFS='|' read -r user pkg vc; do
        [ -z "$pkg" ] && continue
        if ! grep -Fxq -- "$user|$pkg|$vc" "$STATE_FILE" 2>/dev/null; then
            AAD_PACKAGE_CHANGES=$((AAD_PACKAGE_CHANGES + 1))
            log "PACKAGE-CHANGE u$user: $pkg ($vc)"
            aad_verified_forget "$user" "$pkg"
            AAD_CURRENT_VERSION_CODE="$vc"
            export AAD_CURRENT_VERSION_CODE
            if process_package_user "$user" "$pkg" >/dev/null; then
                aad_scope_cache_update_package "$user" "$pkg" >/dev/null 2>&1 || rm -f "$PACKAGE_SCOPE_CACHE" 2>/dev/null
            else
                _delta_failed=1
                log "PACKAGE-CHANGE-PENDING u$user: $pkg discovery/policy apply failed; previous package_state baseline preserved for retry"
            fi
        fi
    done < "$current"

    rm -f "$AAD_APK_PATH_CACHE" 2>/dev/null
    unset AAD_APK_PATH_CACHE AAD_MANIFEST_CACHE_ENABLED AAD_MANIFEST_RULES_HASH AAD_CURRENT_VERSION_CODE

    if [ "$_delta_failed" -ne 0 ]; then
        rm -f "$current" 2>/dev/null
        : > "$PACKAGE_RESCAN_PENDING" 2>/dev/null || true
        return 1
    fi
    mv -f "$current" "$STATE_FILE" 2>/dev/null || { rm -f "$current" 2>/dev/null; return 1; }
    cleanup_stale_records || return 1
    reconcile_owned_ifw_rules
}

PACKAGE_RESCAN_PENDING="$DATA_DIR/.package_rescan.pending"

rescan_changed_packages() {
    if ! acquire_lock; then
        : > "$PACKAGE_RESCAN_PENDING" 2>/dev/null
        log "LOCK timeout: incremental rescan deferred (queued for retry)"
        return 1
    fi
    rm -f "$PACKAGE_RESCAN_PENDING" 2>/dev/null
    aad_policy_snapshot_begin || { release_lock; return 1; }
    _rcp_start="$AAD_POLICY_START_HASH"
    AAD_PROTECTED_CACHE_ACTIVE=1
    export AAD_PROTECTED_CACHE_ACTIVE
    aad_write_reconcile_status RUNNING PACKAGE_DELTA "$_rcp_start" "source=package-watch"
    rescan_changed_packages_locked
    rc=$?
    changes=${AAD_PACKAGE_CHANGES:-0}
    unset AAD_PROTECTED_CACHE_ACTIVE
    rm -f "$DATA_DIR"/.dyn_prot_u* "$DATA_DIR"/.dyn_prot_unknown_u* 2>/dev/null || true
    _rcp_latest=$(compute_config_hash)
    if [ "$rc" -eq 0 ] && [ "$_rcp_latest" = "$_rcp_start" ]; then
        aad_write_reconcile_status IDLE PACKAGE_DELTA "$_rcp_start" "changes=$changes"
    elif [ "$rc" -eq 0 ]; then
        aad_write_reconcile_status PENDING PACKAGE_DELTA "$_rcp_start" "latest=$_rcp_latest"
    else
        aad_write_reconcile_status FAILED PACKAGE_DELTA "$_rcp_start" "rc=$rc"
    fi
    aad_policy_snapshot_end
    release_lock
    if [ "$rc" -eq 0 ] && [ "$changes" -gt 0 ] 2>/dev/null && [ "$_rcp_latest" = "$_rcp_start" ]; then
        reconcile_ad_surface_killer "package-change:$changes" >/dev/null 2>&1 || true
        launch_ad_surface_indexer_bg "package-change:$changes" >/dev/null 2>&1 || true
    fi
    if [ "$rc" -eq 0 ] && [ "$_rcp_latest" != "$_rcp_start" ]; then
        reconcile_config_if_changed "post-package-coalesce" >/dev/null 2>&1 || true
    fi
    return "$rc"
}
