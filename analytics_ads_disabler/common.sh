#!/system/bin/sh

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
    PATH="$PATH:$AAD_APPLET_DIR"
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
WHITE_ADS_FILE="$DATA_DIR/white_ads.list"
WHITE_ANALYTICS_FILE="$DATA_DIR/white_analytics.list"
CACHE_ADS="$DATA_DIR/.white_ads.cache"
CACHE_ANALYTICS="$DATA_DIR/.white_analytics.cache"
CACHE_GLOBAL="$DATA_DIR/.whitelist.cache"
CONFIG_HASH_FILE="$DATA_DIR/.config.hash"
BASE_POLICY_HASH_FILE="$DATA_DIR/.base_policy.hash"
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

AAD_LIB_DIR="${MODDIR:-${0%/*}}"
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
    if [ -f "$SETTINGS_FILE" ]; then
        val=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$SETTINGS_FILE" | head -n1 | tr -d '\r')
    fi
    if [ -z "$val" ] && [ -f "$RULES_FILE" ]; then
        val=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$RULES_FILE" | head -n1 | tr -d '\r')
    fi
    [ -n "$val" ] && echo "$val" || echo "$def"
}

read_bool_setting() {
    val=$(read_setting "$1" "$2")
    [ "$val" = "1" ] && echo 1 || echo 0
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
    val=$(read_setting COMPONENT_MODE SAFE | tr '[:lower:]' '[:upper:]')
    case "$val" in
        SAFE|BALANCED|AGGRESSIVE) echo "$val" ;;
        *) echo SAFE ;;
    esac
}

read_component_backend() {
    val=$(read_setting COMPONENT_BACKEND PM | tr '[:lower:]' '[:upper:]')
    case "$val" in
        PM|HYBRID) echo "$val" ;;
        *) echo PM ;;
    esac
}

read_ifw_activity_limit() {
    mode_now=$(read_component_mode)
    if [ "$mode_now" = "AGGRESSIVE" ]; then
        val=$(read_setting MAX_AGGRESSIVE_IFW_ACTIVITIES_PER_CATEGORY 64)
        fallback=64
        ceiling=128
    else
        val=$(read_setting MAX_IFW_ACTIVITIES_PER_CATEGORY 5)
        fallback=5
        ceiling=25
    fi
    case "$val" in
        ''|*[!0-9]*) echo "$fallback" ;;
        *)
            [ "$val" -lt 1 ] 2>/dev/null && val=1
            [ "$val" -gt "$ceiling" ] 2>/dev/null && val="$ceiling"
            echo "$val"
            ;;
    esac
}

probe_ifw_storage() {
    [ -d "$IFW_DIR" ] || return 1
    probe="$IFW_DIR/.analytics_ads_disabler.probe.$$"
    (umask 022; printf '<rules/>\n' > "$probe") 2>/dev/null || return 1
    chmod 0644 "$probe" 2>/dev/null || { rm -f "$probe" 2>/dev/null; return 1; }
    rm -f "$probe" 2>/dev/null
    [ ! -e "$probe" ]
}

category_enabled() {
    case "$1" in
        ADS) [ "$(read_bool_setting BLOCK_ADS 1)" = "1" ] ;;
        ANALYTICS) [ "$(read_bool_setting BLOCK_ANALYTICS 1)" = "1" ] ;;
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

is_system_protected() {
    for sys_pkg in $SYSTEM_PROTECTED; do
        [ "$1" = "$sys_pkg" ] && return 0
    done
    return 1
}

is_globally_whitelisted() {
    [ -f "$WHITELIST_FILE" ] && trim_config_lines < "$WHITELIST_FILE" | grep -Fxq -- "$1" 2>/dev/null
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
    [ -f "$WHITELIST_FILE" ] && trim_config_lines < "$WHITELIST_FILE" | sort -u
}

aad_lock_write_owner() {
    printf '%s
' "$$" > "$1/pid" 2>/dev/null
    printf '%s
' "$(aad_proc_starttime "$$")" > "$1/starttime" 2>/dev/null
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
                        : > "$DATA_DIR/.surface_index.rerun" 2>/dev/null
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
    [ "$(read_bool_setting BLOCK_ADS 1)" = "1" ] || return 1
    [ "$(read_component_mode)" = "AGGRESSIVE" ] || return 1
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

XPOSED_TARGET_JSON="$DATA_DIR/xposed_targets.json"
XPOSED_TARGET_LIST="$DATA_DIR/xposed_targets.list"

aad_detect_xposed() {
    for _adx in /data/adb/lspd \
                /data/adb/modules/zygisk_lsposed \
                /data/adb/modules/riru_lsposed \
                /data/adb/modules/lsposed \
                /data/adb/lspatch \
                /data/adb/modules/riru_edxposed \
                /data/adb/modules/xposed; do
        [ -d "$_adx" ] && { printf 'LSPosed:%s\n' "$_adx"; return 0; }
    done
    [ -f /system/framework/XposedBridge.jar ] && { printf 'Xposed:/system/framework/XposedBridge.jar\n'; return 0; }
    return 1
}

aad_xposed_bridge_enabled() {
    _axb=$(read_setting XPOSED_BRIDGE auto | tr '[:upper:]' '[:lower:]')
    case "$_axb" in
        0|off|no) return 1 ;;
        1|on|yes) return 0 ;;
        *) aad_detect_xposed >/dev/null 2>&1 ;;
    esac
}

aad_export_xposed_targets() {
    [ -s "$AD_SURFACE_SCAN_FILE" ] || return 1
    aad_xposed_bridge_enabled || {
        rm -f "$XPOSED_TARGET_JSON" "$XPOSED_TARGET_LIST" 2>/dev/null
        return 0
    }
    _axt_json=$(aad_mktemp_near "$XPOSED_TARGET_JSON")
    _axt_list=$(aad_mktemp_near "$XPOSED_TARGET_LIST")
    [ -n "$_axt_json" ] && [ -n "$_axt_list" ] || {
        rm -f "$_axt_json" "$_axt_list" 2>/dev/null
        return 1
    }
    _axt_env=$(aad_detect_xposed 2>/dev/null); [ -n "$_axt_env" ] || _axt_env="none"

    awk -F'|' -v stamp="$(aad_now_ms)" -v version="$MODULE_VERSION" -v env="$_axt_env" \
        -v listout="$_axt_list" '
        function esc(v) {gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); return v}
        function addval(arrname, key, val,   cur, sep) {
            if (seen[arrname, key, val]) return
            seen[arrname, key, val]=1
            if (arrname=="sdk") {sdk[key]=sdk[key] (sdk[key]==""?"":"\034") val}
            else {surf[key]=surf[key] (surf[key]==""?"":"\034") val}
        }
        function emitarr(v,   n,i,parts,out) {
            n=split(v, parts, "\034"); out=""
            for (i=1;i<=n;i++) out=out (i>1?",":"") "\"" esc(parts[i]) "\""
            return out
        }
        BEGIN {rank["CAPABILITY"]=1; rank["LAYOUT_CONFIRMED"]=2; rank["MULTI_EVIDENCE"]=3
               name[1]="CAPABILITY"; name[2]="LAYOUT_CONFIRMED"; name[3]="MULTI_EVIDENCE"}
        NR>1 && $2=="HIT" && $3!="" && $4!="" && $7!="" && $8!="" {
            key=$3 "\035" $4
            if (!(key in known)) {known[key]=1; order[++n]=key}
            addval("sdk", key, $8)
            addval("surface", key, $7)
            r=rank[$11]; if (r=="") r=1
            if (r > best[key]) best[key]=r
        }
        END {
            printf "{\n"
            printf "  \"schema\": 1,\n"
            printf "  \"generator\": \"analytics_ads_disabler %s\",\n", esc(version)
            printf "  \"framework\": \"%s\",\n", esc(env)
            printf "  \"generated_ms\": %s,\n", stamp
            printf "  \"note\": \"Read-only evidence export. Consumed by a companion Xposed module; this module performs no hooking.\",\n"
            printf "  \"targets\": [\n"
            for (i=1;i<=n;i++) {
                split(order[i], k, "\035")
                b=best[order[i]]; if (b<1) b=1
                printf "    {\"user\": %s, \"package\": \"%s\", \"sdks\": [%s], \"surfaces\": [%s], \"confidence\": \"%s\"}%s\n", \
                    k[1], esc(k[2]), emitarr(sdk[order[i]]), emitarr(surf[order[i]]), name[b], (i<n ? "," : "")
                gsub(/\034/, ",", sdk[order[i]])
                gsub(/\034/, ",", surf[order[i]])
                print k[1] "|" k[2] "|" sdk[order[i]] "|" surf[order[i]] "|" name[b] > listout
            }
            printf "  ]\n}\n"
            close(listout)
        }
    ' "$AD_SURFACE_SCAN_FILE" > "$_axt_json" 2>/dev/null

    [ -s "$_axt_json" ] || { rm -f "$_axt_json" "$_axt_list" 2>/dev/null; return 1; }
    [ -f "$_axt_list" ] || : > "$_axt_list"
    chmod 640 "$_axt_json" "$_axt_list" 2>/dev/null || true
    mv -f "$_axt_json" "$XPOSED_TARGET_JSON" 2>/dev/null || { rm -f "$_axt_json" "$_axt_list" 2>/dev/null; return 1; }
    mv -f "$_axt_list" "$XPOSED_TARGET_LIST" 2>/dev/null || rm -f "$_axt_list" 2>/dev/null
    _axt_count=$(grep -c . "$XPOSED_TARGET_LIST" 2>/dev/null); [ -n "$_axt_count" ] || _axt_count=0
    log "XPOSED-BRIDGE exported targets=$_axt_count framework=$_axt_env json=$XPOSED_TARGET_JSON list=$XPOSED_TARGET_LIST"
    return 0
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
        is_system_protected "$_ak_pkg" && continue
        is_globally_whitelisted "$_ak_pkg" && continue
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
    for _aku_user in $(list_user_ids); do
        if command -v cmd >/dev/null 2>&1; then
            cmd package list packages -U --user "$_aku_user" 2>/dev/null | awk -v u="$_aku_user" '
                /^package:/ {
                    pkg=$1; sub(/^package:/,"",pkg); uid=""
                    for(i=2;i<=NF;i++) if($i ~ /^uid:/){uid=$i; sub(/^uid:/,"",uid)}
                    if(pkg!="" && uid ~ /^[0-9]+$/) print u "|" pkg "|" uid
                }'
        elif [ -x /system/bin/cmd ]; then
            /system/bin/cmd package list packages -U --user "$_aku_user" 2>/dev/null | awk -v u="$_aku_user" '
                /^package:/ {
                    pkg=$1; sub(/^package:/,"",pkg); uid=""
                    for(i=2;i<=NF;i++) if($i ~ /^uid:/){uid=$i; sub(/^uid:/,"",uid)}
                    if(pkg!="" && uid ~ /^[0-9]+$/) print u "|" pkg "|" uid
                }'
        fi
    done | sort -u
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
    while "$_akc_bin" -t filter -D OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1; do :; done
    "$_akc_bin" -t filter -F "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
    "$_akc_bin" -t filter -X "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
    _akc_subs=$("$_akc_bin" -t filter -S 2>/dev/null | sed -n "s/^-N \(${AD_KILLER_CHAIN}_[0-9][0-9]*\)$/\1/p")
    [ -n "$_akc_subs" ] || return 0
    for _akc_sub in $_akc_subs; do
        "$_akc_bin" -t filter -F "$_akc_sub" >/dev/null 2>&1 || true
    done
    for _akc_sub in $_akc_subs; do
        "$_akc_bin" -t filter -X "$_akc_sub" >/dev/null 2>&1 || true
    done
    return 0
}

ad_killer_reject_target() {
    _akrt_bin="$1"; _akrt_chain="${AD_KILLER_CHAIN}R"
    "$_akrt_bin" -t filter -F "$_akrt_chain" >/dev/null 2>&1 || true
    "$_akrt_bin" -t filter -X "$_akrt_chain" >/dev/null 2>&1 || true
    if "$_akrt_bin" -t filter -N "$_akrt_chain" >/dev/null 2>&1; then
        if "$_akrt_bin" -t filter -A "$_akrt_chain" -p tcp -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
            "$_akrt_bin" -t filter -F "$_akrt_chain" >/dev/null 2>&1 || true
            "$_akrt_bin" -t filter -X "$_akrt_chain" >/dev/null 2>&1 || true
            printf 'REJECT --reject-with tcp-reset\n'
            return 0
        fi
        "$_akrt_bin" -t filter -F "$_akrt_chain" >/dev/null 2>&1 || true
        "$_akrt_bin" -t filter -X "$_akrt_chain" >/dev/null 2>&1 || true
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

    if ! "$_akab_restore" -n "$_akab_file" >/dev/null 2>&1; then
        log "AD-KILLER batch restore failed bin=$_akab_restore file=$_akab_file; falling back to per-rule mode"
        rm -f "$_akab_file" 2>/dev/null
        return 1
    fi
    rm -f "$_akab_file" 2>/dev/null
    return 0
}

ad_killer_status_write() {
    _aks_state="$1"; _aks_reason="${2:-}"
    _aks_tmp="$AD_KILLER_STATUS_FILE.tmp.$$"
    {
        printf 'state=%s\n' "$_aks_state"
        [ -n "$_aks_reason" ] && printf 'reason=%s\n' "$_aks_reason"
        printf 'updated_ms=%s\n' "$(aad_now_ms)"
    } > "$_aks_tmp" 2>/dev/null || return 0
    chmod 600 "$_aks_tmp" 2>/dev/null || true
    mv -f "$_aks_tmp" "$AD_KILLER_STATUS_FILE" 2>/dev/null || rm -f "$_aks_tmp" 2>/dev/null
}

ad_killer_cleanup() {
    _akc_state="${1:-DISABLED}"; _akc_reason="${2:-}"
    _akc4=$(ad_killer_iptables_bin 4); _akc6=$(ad_killer_iptables_bin 6)
    ad_killer_chain_cleanup_family "$_akc4"
    ad_killer_chain_cleanup_family "$_akc6"
    ad_killer_status_write "$_akc_state" "$_akc_reason"
}

ad_killer_probe_match() {
    _akpm_bin="$1"; _akpm_kind="$2"; _akpm_chain="${AD_KILLER_CHAIN}P"
    [ -n "$_akpm_bin" ] || return 1
    while "$_akpm_bin" -t filter -D OUTPUT -j "$_akpm_chain" >/dev/null 2>&1; do :; done
    "$_akpm_bin" -t filter -F "$_akpm_chain" >/dev/null 2>&1 || true
    "$_akpm_bin" -t filter -X "$_akpm_chain" >/dev/null 2>&1 || true
    "$_akpm_bin" -t filter -N "$_akpm_chain" >/dev/null 2>&1 || return 1
    if ! "$_akpm_bin" -t filter -I OUTPUT 1 -j "$_akpm_chain" >/dev/null 2>&1; then
        "$_akpm_bin" -t filter -X "$_akpm_chain" >/dev/null 2>&1 || true
        return 1
    fi
    _akpm_rc=1
    case "$_akpm_kind" in
        owner)
            "$_akpm_bin" -t filter -A "$_akpm_chain" -m owner --uid-owner 0 -p tcp --dport 443 -j RETURN >/dev/null 2>&1 && _akpm_rc=0
            ;;
        string)
            "$_akpm_bin" -t filter -A "$_akpm_chain" -m owner --uid-owner 0 -p tcp --dport 443 -m string --algo bm --string aad.invalid.test -j RETURN >/dev/null 2>&1 && _akpm_rc=0
            ;;
    esac
    while "$_akpm_bin" -t filter -D OUTPUT -j "$_akpm_chain" >/dev/null 2>&1; do :; done
    "$_akpm_bin" -t filter -F "$_akpm_chain" >/dev/null 2>&1 || true
    "$_akpm_bin" -t filter -X "$_akpm_chain" >/dev/null 2>&1 || true
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
    if "$_akir_bin" -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akir_uid" -d "$_akir_ip" -j REJECT --reject-with icmp-port-unreachable >/dev/null 2>&1; then
        return 0
    fi
    "$_akir_bin" -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akir_uid" -d "$_akir_ip" -j DROP >/dev/null 2>&1
}

ad_killer_chain_alive() {
    _akca_bin=$(ad_killer_iptables_bin 4)
    [ -n "$_akca_bin" ] || return 0
    "$_akca_bin" -t filter -C OUTPUT -j "$AD_KILLER_CHAIN" >/dev/null 2>&1
}

ad_killer_add_tcp_rule() {
    _akar_bin="$1"; _akar_uid="$2"; _akar_host="$3"
    if "$_akar_bin" -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akar_uid" -p tcp --dport 443 -m string --algo bm --string "$_akar_host" -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
        return 0
    fi
    "$_akar_bin" -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akar_uid" -p tcp --dport 443 -m string --algo bm --string "$_akar_host" -j DROP >/dev/null 2>&1
}

ad_killer_add_quic_rule() {
    _akq_bin="$1"; _akq_uid="$2"
    if "$_akq_bin" -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akq_uid" -p udp --dport 443 -j REJECT >/dev/null 2>&1; then
        return 0
    fi
    "$_akq_bin" -t filter -A "$AD_KILLER_CHAIN" -m owner --uid-owner "$_akq_uid" -p udp --dport 443 -j DROP >/dev/null 2>&1
}

ad_killer_prepare_chain() {
    _akpc_bin="$1"
    ad_killer_chain_cleanup_family "$_akpc_bin"
    "$_akpc_bin" -t filter -N "$AD_KILLER_CHAIN" >/dev/null 2>&1 || return 1
    "$_akpc_bin" -t filter -I OUTPUT 1 -j "$AD_KILLER_CHAIN" >/dev/null 2>&1 || {
        "$_akpc_bin" -t filter -F "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
        "$_akpc_bin" -t filter -X "$AD_KILLER_CHAIN" >/dev/null 2>&1 || true
        return 1
    }
    return 0
}

_reconcile_ad_surface_killer_unlocked() {
    _akr_reason="${1:-manual}"
    if ! ad_killer_enabled; then
        ad_killer_cleanup DISABLED "$_akr_reason"
        log "AD-KILLER disabled reason=$_akr_reason mode=$(read_component_mode) block_ads=$(read_bool_setting BLOCK_ADS 1) setting=$(read_bool_setting AD_SURFACE_KILLER 1)"
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
        ad_killer_cleanup WAITING "no_targets:$_akr_reason"
        log "AD-KILLER waiting-targets reason=$_akr_reason file=$AD_KILLER_TARGET_FILE"
        return 0
    }

    _akr_uidmap=$(aad_mktemp_near "$DATA_DIR/.adkiller_uidmap")
    _akr_active=$(aad_mktemp_near "$DATA_DIR/.adkiller_active")
    [ -n "$_akr_uidmap" ] && [ -n "$_akr_active" ] || { rm -f "$_akr_uidmap" "$_akr_active" 2>/dev/null; return 1; }
    ad_killer_uid_inventory > "$_akr_uidmap"
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
        is_system_protected "$_akr_pkg" && continue
        is_globally_whitelisted "$_akr_pkg" && continue
        is_category_whitelisted "$_akr_pkg" ADS && continue
        printf '%s|%s|%s|%s|%s\n' "$_akr_user" "$_akr_pkg" "$_akr_uid" "$_akr_sdk" "$_akr_host" >> "$_akr_filtered"
    done < "$_akr_active"
    sort -u "$_akr_filtered" -o "$_akr_filtered" 2>/dev/null || true
    _akr_targets=$(grep -c . "$_akr_filtered" 2>/dev/null); [ -n "$_akr_targets" ] || _akr_targets=0
    if [ "$_akr_targets" -eq 0 ]; then
        ad_killer_cleanup WAITING "no_active_targets:$_akr_reason"
        log "AD-KILLER waiting-active-targets reason=$_akr_reason"
        rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" 2>/dev/null
        return 0
    fi

    _akr4=$(ad_killer_iptables_bin 4); _akr6=$(ad_killer_iptables_bin 6)
    if [ -z "$_akr4" ] && [ -z "$_akr6" ]; then
        ad_killer_cleanup UNAVAILABLE "no_iptables:$_akr_reason"
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
        ad_killer_cleanup UNAVAILABLE "xt_owner_missing:$_akr_reason"
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
        ad_killer_cleanup UNAVAILABLE "xt_string_missing:$_akr_reason"
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
        ad_killer_cleanup UNAVAILABLE "chain_setup_failed:$_akr_reason"
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
            if { [ "$_akr4ok" = "1" ] || [ "$_akr_batch4" = "1" ]; } && ad_killer_add_quic_rule "$_akr4" "$_akr_uid"; then _akr_rules4=$((_akr_rules4 + 1)); fi
            if { [ "$_akr6ok" = "1" ] || [ "$_akr_batch6" = "1" ]; } && ad_killer_add_quic_rule "$_akr6" "$_akr_uid"; then _akr_rules6=$((_akr_rules6 + 1)); fi
            _akr_quic=$((_akr_quic + 1))
        done
    fi
    _akr_pkgs=$(awk -F'|' '{k=$1 "|" $2; if(!seen[k]++) n++} END{print n+0}' "$_akr_filtered" 2>/dev/null); [ -n "$_akr_pkgs" ] || _akr_pkgs=0
    _akr_status_tmp="$AD_KILLER_STATUS_FILE.tmp.$$"
    {
        printf 'state=ACTIVE\n'
        printf 'reason=%s\n' "$_akr_reason"
        printf 'mode=%s\n' "$_akr_active_mode"
        printf 'min_confidence=%s\n' "$(ad_killer_min_confidence)"
        printf 'targets=%s\n' "$_akr_targets"
        printf 'unique_uid_hosts=%s\n' "$_akr_unique"
        printf 'packages_users=%s\n' "$_akr_pkgs"
        printf 'ipv4_rules=%s\n' "$_akr_rules4"
        printf 'ipv6_rules=%s\n' "$_akr_rules6"
        printf 'force_tcp=%s\n' "$_akr_force_tcp"
        printf 'quic_uids=%s\n' "$_akr_quic"
        printf 'failed=%s\n' "$_akr_failed"
        printf 'updated_ms=%s\n' "$(aad_now_ms)"
    } > "$_akr_status_tmp" 2>/dev/null || true
    chmod 600 "$_akr_status_tmp" 2>/dev/null || true
    mv -f "$_akr_status_tmp" "$AD_KILLER_STATUS_FILE" 2>/dev/null || rm -f "$_akr_status_tmp" 2>/dev/null
    log "AD-KILLER-SUMMARY reason=$_akr_reason mode=$_akr_active_mode targets=$_akr_targets unique_uid_hosts=$_akr_unique packages/users=$_akr_pkgs ipv4_rules=$_akr_rules4 ipv6_rules=$_akr_rules6 force_tcp=$_akr_force_tcp quic_uids=$_akr_quic failed=$_akr_failed target_file=$AD_KILLER_TARGET_FILE"
    rm -f "$_akr_uidmap" "$_akr_active" "$_akr_filtered" "$_akr_hostmap" "$_akr_rules" 2>/dev/null
    return 0
}

aad_proc_starttime() {
    _apst_pid="$1"
    case "$_apst_pid" in ''|*[!0-9]*) return 1 ;; esac
    _apst_raw=$(cat "/proc/$_apst_pid/stat" 2>/dev/null) || return 1
    [ -n "$_apst_raw" ] || return 1
    _apst_tail=${_apst_raw##*') '}
    [ "$_apst_tail" = "$_apst_raw" ] && return 1
    printf '%s
' "$_apst_tail" | awk '{print $20}'
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

list_user_ids() {
    if [ "$(read_bool_setting SCAN_ALL_USERS 1)" != "1" ]; then
        echo 0
        return
    fi

    if ! cap_multiuser_ready; then
        log "CAPABILITY: multi-user requested but selected package-manager commands lack --user; using user 0 only."
        echo 0
        return
    fi

    raw=$(cap_list_users_raw 2>/dev/null)
    ids=$(printf '%s\n' "$raw" | awk '
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
    if [ -n "$ids" ]; then
        echo "$ids"
    else
        echo 0
    fi
}

list_packages_for_user() {
    user="$1"
    third=0
    [ "$(read_bool_setting SCAN_SYSTEM_APPS 0)" != "1" ] && third=1

    out=$(cap_list_packages_raw "$user" "$third" 1 "")
    if echo "$out" | grep -q '^package:'; then
        echo "$out" | awk '
            /^package:/ {
                p=$1; sub(/^package:/,"",p); v="0";
                for(i=2;i<=NF;i++) if($i ~ /^versionCode:/){v=$i; sub(/^versionCode:/,"",v)}
                print p "|" v
            }'
        return
    fi

    cap_list_packages_raw "$user" "$third" 0 "" | sed 's/^package://; s/[[:space:]].*$//; s/$/|0/'
}

list_all_package_state() {
    for user in $(list_user_ids); do
        list_packages_for_user "$user" | while IFS='|' read -r pkg vc; do
            [ -n "$pkg" ] && echo "$user|$pkg|${vc:-0}"
        done
    done
}

list_all_installed_package_keys() {
    for user in $(list_user_ids); do
        cap_list_packages_raw "$user" 0 0 "" 2>/dev/null \
            | sed 's/^package://; s/[[:space:]].*$//' \
            | while IFS= read -r pkg; do
                [ -n "$pkg" ] && echo "$user|$pkg"
            done
    done | sort -u
}

disable_component_smart() {
    user="$1"
    comp="$2"
    preserve_state=$(get_saved_original_state "$user" "$comp")
    [ -n "$preserve_state" ] || preserve_state=$(get_component_override_state "$user" "$comp")
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

get_component_override_state() {
    user="$1"
    comp="$2"
    pkg=${comp%%/*}
    cls=${comp#*/}
    case "$cls" in
        .*) full_cls="$pkg$cls" ;;
        *) full_cls="$cls" ;;
    esac

    state=$(aad_package_dump_cached "$pkg" | awk -v uid="$user" -v full="$full_cls" -v short="$cls" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s); return s}
        /^[ \t]*User [0-9]+:/ {
            line=$0; gsub(/^[ \t]*/,"",line)
            if (line ~ ("^User " uid ":")) {inuser=1; sec=""; next}
            if (inuser) exit
        }
        !inuser {next}
        /^[ \t]*enabledComponents:/ {sec="enabled"; next}
        /^[ \t]*disabledComponents:/ {sec="disabled"; next}
        /^[ \t]*[A-Za-z][A-Za-z0-9_-]*:/ {sec=""}
        sec!="" {
            x=trim($0)
            if (x==full || x==short) {print sec; exit}
        }
    ')
    [ -n "$state" ] && echo "$state" || echo default
}

state_record_exists() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] && awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {found=1; exit} END{exit !found}' "$COMPONENT_STATE"
}

ensure_original_state() {
    user="$1"; comp="$2"
    state_record_exists "$user" "$comp" && return 0
    original=$(get_component_override_state "$user" "$comp")
    aad_db_lock "$STATE_DB_LOCK" || { log "STATE-LOCK-FAILED save u$user: $comp"; return 1; }
    if ! state_record_exists "$user" "$comp"; then
        printf '%s|%s|%s\n' "$user" "$comp" "$original" >> "$COMPONENT_STATE"
        log "STATE-SAVE u$user: $comp -> $original"
    fi
    aad_db_unlock "$STATE_DB_LOCK"
}

get_saved_original_state() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] || return
    awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {print $3; exit}' "$COMPONENT_STATE"
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
    [ -z "$original" ] && original=default
    if set_component_state_smart "$user" "$comp" "$original"; then
        log "RESTORE u$user: $comp -> $original"
        remove_state_record "$user" "$comp"
        return 0
    fi
    log "RESTORE-FAILED u$user: $comp -> $original"
    return 1
}

cap_list_packages_with_paths_raw() {
    user="$1"
    [ "$CAP_PACKAGE_LIST_BACKEND" != "none" ] || return 1
    [ "$CAP_PACKAGE_LIST_HAS_USER" = "1" ] || [ "$user" = "0" ] || return 1
    case "$CAP_PACKAGE_LIST_BACKEND:$CAP_PACKAGE_LIST_HAS_USER" in
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
    for inv_user in $(list_user_ids); do
        cap_list_packages_with_paths_raw "$inv_user" | while IFS= read -r line; do
            case "$line" in
                package:*=*)
                    body=${line#package:}
                    inv_pkg=${body##*=}
                    inv_apk=${body%="$inv_pkg"}
                    inv_apk=${inv_apk%=}
                    [ -n "$inv_pkg" ] && [ -n "$inv_apk" ] && printf '%s|%s|%s\n' "$inv_user" "$inv_pkg" "$inv_apk"
                    ;;
            esac
        done >> "$out_file"
    done
    sort -u "$out_file" -o "$out_file" 2>/dev/null || true
    return 0
}

cap_package_paths_readonly() {
    user="$1"; pkg="$2"
    raw_paths=""
    out=$(cmd package path --user "$user" "$pkg" 2>/dev/null)
    [ -n "$out" ] || out=$(pm path --user "$user" "$pkg" 2>/dev/null)
    [ -n "$out" ] || out=$(cmd package path "$pkg" 2>/dev/null)
    [ -n "$out" ] || out=$(pm path "$pkg" 2>/dev/null)
    direct_paths=$(printf '%s\n' "$out" | sed -n 's/^package://p' | awk 'NF')

    cached_paths=""
    if [ -n "${AAD_APK_PATH_CACHE:-}" ] && [ -f "$AAD_APK_PATH_CACHE" ]; then
        cached_paths=$(awk -F'|' -v u="$user" -v p="$pkg" '$1==u && $2==p {print $3}' "$AAD_APK_PATH_CACHE" 2>/dev/null)
    fi
    raw_paths=$(printf '%s\n%s\n' "$direct_paths" "$cached_paths" | awk 'NF' | sort -u)
    [ -n "$raw_paths" ] || return 0

    {
        printf '%s\n' "$raw_paths"
        printf '%s\n' "$raw_paths" | while IFS= read -r base_apk; do
            [ -n "$base_apk" ] || continue
            apk_dir=${base_apk%/*}
            [ -d "$apk_dir" ] || continue
            for sibling in "$apk_dir"/*.apk; do
                [ -f "$sibling" ] && printf '%s\n' "$sibling"
            done
        done
    } | awk 'NF' | sort -u
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
    _ale_out=""
    if command -v unzip >/dev/null 2>&1; then
        _ale_out=$(unzip -Z1 "$apk" 2>/dev/null)
        if [ -n "$_ale_out" ]; then
            printf '%s\n' "$_ale_out"
            return 0
        fi
        _ale_out=$(unzip -l "$apk" 2>/dev/null | apk_parse_unzip_listing)
        if [ -n "$_ale_out" ]; then
            printf '%s\n' "$_ale_out"
            return 0
        fi
    fi
    if aad_have_bb; then
        _ale_out=$(aad_bb unzip -l "$apk" 2>/dev/null | apk_parse_unzip_listing)
        if [ -n "$_ale_out" ]; then
            printf '%s\n' "$_ale_out"
            return 0
        fi
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
    [ "$(read_bool_setting BLOCK_ADS 1)" = "1" ] || return 0
    paths=$(cap_package_paths_readonly "$user" "$pkg")
    [ -n "$paths" ] || return 0
    vc="${AAD_CURRENT_VERSION_CODE:-unknown}"
    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
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
    mode=$(read_component_mode)
    backend=$(read_component_backend)
    [ "$mode" = "AGGRESSIVE" ] || [ "$backend" = "HYBRID" ] || return 0

    paths=$(cap_package_paths_readonly "$user" "$pkg")
    if [ -z "$paths" ]; then
        log "MANIFEST-PATH-MISS u$user: $pkg direct_and_inventory_empty=yes"
        [ -n "${AAD_MANIFEST_STATS_FILE:-}" ] && printf '%s|%s|%s|-|path-miss|UNKNOWN|0|0|0|0|0|0|BYPASS\n' \
            "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "$user" "$pkg" >> "$AAD_MANIFEST_STATS_FILE"
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
        return 0
    }

    while IFS= read -r apk; do
        [ -n "$apk" ] || continue
        if [ ! -f "$apk" ]; then
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
            hit_snapshot=$(manifest_activity_rule_hits "$classes")
            exact_hits=$(printf '%s\n' "$hit_snapshot" | awk -F'|' '$1=="EXACT"{n++} END{print n+0}')
            audit_hits=$(printf '%s\n' "$hit_snapshot" | awk -F'|' '$1=="AUDIT"{n++} END{print n+0}')
            verified=0
            verify_miss=0
            : > "$verified_tmp"

            old_ifs=$IFS
            IFS='
'
            for rec in $hit_snapshot; do
                [ -n "$rec" ] || continue
                hit=${rec%%|*}
                cls=${rec#*|}
                [ -n "$cls" ] || continue
                comp="$pkg/$cls"
                if cap_activity_component_exists "$user" "$comp"; then
                    echo "ACTIVITY|$comp"
                    printf '%s\n' "$cls" >> "$verified_tmp"
                    verified=$((verified + 1))
                else
                    verify_miss=$((verify_miss + 1))
                    [ "$hit" = "EXACT" ] && log "ACTIVITY-VERIFY-MISS u$user: $comp source=manifest-exact encoding=$encoding"
                fi
            done
            IFS=$old_ifs

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
}

get_typed_component_candidates() {
    user="$1"; pkg="$2"
    {
        aad_package_dump_cached "$pkg" | awk -v p="$pkg" '
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
        '
        get_manifest_activity_candidates "$user" "$pkg"
    } | sort -u
}

get_typed_component_candidates_cached() {
    user="$1"; pkg="$2"
    if [ -n "$SCAN_CANDIDATE_CACHE_DIR" ] && [ -d "$SCAN_CANDIDATE_CACHE_DIR" ]; then
        key=$(printf '%s' "$user|$pkg" | cksum 2>/dev/null | awk '{print $1 "_" $2}')
        [ -n "$key" ] || key=$(printf '%s' "$user|$pkg" | tr '/ :|' '____')
        cache="$SCAN_CANDIDATE_CACHE_DIR/$key"
        if [ ! -f "$cache" ]; then
            get_typed_component_candidates "$user" "$pkg" > "$cache.tmp.$$"
            mv "$cache.tmp.$$" "$cache" 2>/dev/null || cp "$cache.tmp.$$" "$cache" 2>/dev/null
            rm -f "$cache.tmp.$$"
        fi
        cat "$cache" 2>/dev/null
        return
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
                if (component ~ pat || lcfull ~ tolower(pat)) found=1
            } else if (index(lc,tolower(line))>0) found=1
        }
        END {exit found ? 0 : 1}
    ' "$RULES_FILE"
}

component_matches_disable_rule() {
    comp="$1"; cat="$2"; kind="$3"; mode="$4"
    case "$kind" in
        SERVICE|RECEIVER)
            component_matches_rule_section "$comp" "${cat}_${kind}" && return 0
            component_matches_rule_section "$comp" "$cat" && return 0
            [ "$(read_bool_setting BLOCK_PUSH_SDK 0)" = "1" ] || return 1
            component_matches_rule_section "$comp" "${cat}_PUSH_RISK"
            ;;
        PROVIDER)
            case "$mode" in
                BALANCED|AGGRESSIVE)
                    component_matches_rule_section "$comp" "${cat}_PROVIDER_SAFE" && return 0
                    ;;
            esac
            [ "$mode" = "AGGRESSIVE" ] || return 1
            component_matches_rule_section "$comp" "${cat}_PROVIDER_AGGRESSIVE"
            ;;
        ACTIVITY)
            [ "$mode" = "AGGRESSIVE" ] || return 1
            component_matches_rule_section "$comp" "${cat}_ACTIVITY_IFW"
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
        ACTIVITY) component_matches_rule_section "$comp" "${cat}_ACTIVITY_AUDIT" ;;
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
    mode=$(read_component_mode)
    get_typed_component_candidates_cached "$user" "$pkg" | while IFS='|' read -r kind comp; do
        [ -z "$comp" ] && continue
        component_matches_disable_rule "$comp" "$cat" "$kind" "$mode" && echo "$comp"
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
    user="$1"; pkg="$2"; mode=$(read_component_mode)
    [ -n "$COMPONENT_AUDIT_FILE" ] || return 0
    if [ "${AAD_AUDIT_FULL_SCAN:-0}" != "1" ] && [ "${AAD_AUDIT_ROWS_PRECLEANED:-0}" != "1" ] && [ -f "$COMPONENT_AUDIT_FILE" ]; then
        audit_clean=$(aad_mktemp_near "$COMPONENT_AUDIT_FILE")
        if [ -n "$audit_clean" ]; then
            awk -F'|' -v u="$user" -v p="$pkg" 'NR==1 || !($2==u && $3==p)' "$COMPONENT_AUDIT_FILE" > "$audit_clean" 2>/dev/null && mv -f "$audit_clean" "$COMPONENT_AUDIT_FILE"
            [ -f "$audit_clean" ] && rm -f "$audit_clean" 2>/dev/null
        fi
    fi
    candidates=$(aad_mktemp_near "$DATA_DIR/.audit_candidates")
    [ -n "$candidates" ] || return 1
    get_typed_component_candidates_cached "$user" "$pkg" > "$candidates"
    block_ads=$(read_bool_setting BLOCK_ADS 1)
    block_analytics=$(read_bool_setting BLOCK_ANALYTICS 1)
    global_white=0; ads_white=0; analytics_white=0
    is_globally_whitelisted "$pkg" && global_white=1
    is_category_whitelisted "$pkg" ADS && ads_white=1
    is_category_whitelisted "$pkg" ANALYTICS && analytics_white=1
    audit_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

    backend=$(read_component_backend)
    block_push=$(read_bool_setting BLOCK_PUSH_SDK 0)
    awk -F'|' -v user="$user" -v pkg="$pkg" -v mode="$mode" -v backend="$backend" -v stamp="$audit_time" \
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
        function section_match(section, component,    i,rule,pattern,lower_class,lower_component) {
            lower_class=tolower(match_class(component))
            lower_component=tolower(component)
            for (i=1; i<=rule_count[section]; i++) {
                rule=rules[section,i]
                if (substr(rule,1,3)=="re:") {
                    pattern=substr(rule,4)
                    if (component ~ pattern || lower_component ~ tolower(pattern)) return 1
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
                    if (section_match(category "_PROVIDER_SAFE",component))
                        emit(category,kind,component,"BALANCED",((mode=="BALANCED" || mode=="AGGRESSIVE") ? "DISABLE" : "REPORT_ONLY"))
                    else if (section_match(category "_PROVIDER_AGGRESSIVE",component))
                        emit(category,kind,component,"AGGRESSIVE",(mode=="AGGRESSIVE" ? "DISABLE" : "REPORT_ONLY"))
                    else if (section_match(category "_PROVIDER_AUDIT",component))
                        emit(category,kind,component,"AUDIT","REPORT_ONLY")
                }
            } else if (kind=="ACTIVITY") {
                for (ci=1; ci<=2; ci++) {
                    category=(ci==1 ? "ADS" : "ANALYTICS")
                    if (section_match(category "_ACTIVITY_IFW",component)) {
                        if (backend=="HYBRID" && mode=="AGGRESSIVE")
                            emit(category,kind,component,"HYBRID","DISABLE")
                        else if (backend=="HYBRID")
                            emit(category,kind,component,"HYBRID","IFW_BLOCK")
                        else
                            emit(category,kind,component,"AGGRESSIVE",(mode=="AGGRESSIVE" ? "DISABLE" : "REPORT_ONLY"))
                    }
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
    [ -f "$raw" ] && [ -f "$pair_file" ] && [ -f "$installed" ] || return 1

    while IFS= read -r comp; do
        [ -n "$comp" ] || continue
        pkg=${comp%%/*}
        users=$(awk -F'|' -v p="$pkg" '$2==p {print $1}' "$installed" 2>/dev/null | sort -u)
        [ -n "$users" ] || continue
        safe=1
        for user in $users; do
            if ! grep -Fxq -- "$user|$comp" "$pair_file" 2>/dev/null; then
                safe=0
                break
            fi
        done
        if [ "$safe" -eq 1 ]; then
            printf '%s\n' "$comp" >> "$out"
        else
            log "IFW-MULTIUSER-SKIP component=$comp reason=policy_not_unanimous"
        fi
    done < "$raw"
}

reconcile_owned_ifw_rules() {
    backend=$(read_component_backend)
    if [ "$backend" != "HYBRID" ]; then
        if [ -e "$IFW_RULE_FILE" ]; then
            rm -f "$IFW_RULE_FILE" 2>/dev/null || {
                log "IFW-REMOVE-FAILED file=$IFW_RULE_FILE"
                return 1
            }
            log "IFW removed: backend=$backend file=$IFW_RULE_FILE"
        fi
        return 0
    fi

    if ! probe_ifw_storage; then
        log "IFW-UNAVAILABLE: directory is absent or not writable: $IFW_DIR"
        return 1
    fi

    work_base="$DATA_DIR/.ifw_build.$$"
    managed="$work_base.managed"
    managed_pairs="$work_base.managed_pairs"
    installed="$work_base.installed"
    activity_pairs="$work_base.activity_pairs"
    activities_raw="$work_base.activities.raw"
    receivers_raw="$work_base.receivers.raw"
    services_raw="$work_base.services.raw"
    activities="$work_base.activities"
    receivers="$work_base.receivers"
    services="$work_base.services"
    ifw_work_files="$managed $managed_pairs $installed $activity_pairs $activities_raw $receivers_raw $services_raw $activities $receivers $services"
    disabled_source="$DISABLED_LIST"
    [ -f "$disabled_source" ] || disabled_source="/dev/null"

    awk -F'|' 'NF>=3 && $2!="" {print $2}' "$disabled_source" 2>/dev/null | sort -u > "$managed"
    awk -F'|' 'NF>=3 && $1!="" && $2!="" {print $1 "|" $2}' "$disabled_source" 2>/dev/null | sort -u > "$managed_pairs"
    printf '#\n' >> "$managed"

    list_all_installed_package_keys > "$installed" 2>/dev/null
    if [ ! -s "$installed" ]; then
        rm -f "$IFW_RULE_FILE" "$managed" "$managed_pairs" "$installed" \
            "$activity_pairs" "$activities_raw" "$receivers_raw" "$services_raw" \
            "$activities" "$receivers" "$services" 2>/dev/null || true
        log "IFW-SAFETY-SKIP reason=installed_user_snapshot_unavailable"
        return 1
    fi

    awk -F'|' 'NR==FNR {owned[$1]=1; next} FNR>1 && $7=="DISABLE" && $5=="RECEIVER" && owned[$8] {print $8}' \
        "$managed" "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$receivers_raw"
    awk -F'|' 'NR==FNR {owned[$1]=1; next} FNR>1 && $7=="DISABLE" && $5=="SERVICE" && owned[$8] {print $8}' \
        "$managed" "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$services_raw"
    ifw_filter_global_candidates "$receivers_raw" "$managed_pairs" "$installed" "$receivers"
    ifw_filter_global_candidates "$services_raw" "$managed_pairs" "$installed" "$services"

    awk -F'|' 'FNR>1 && $2!="" && $5=="ACTIVITY" && ($7=="IFW_BLOCK" || ($7=="DISABLE" && $6=="HYBRID")) {print $2 "|" $8}' \
        "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$activity_pairs"
    ifw_limit=$(read_ifw_activity_limit)
    awk -F'|' -v limit="$ifw_limit" '
        FNR>1 && $5=="ACTIVITY" && ($7=="IFW_BLOCK" || ($7=="DISABLE" && $6=="HYBRID")) {
            group=$3 "|" $4
            pair=group "|" $8
            if (!seen[pair]++) {
                count[group]++
                component[pair]=$8
            }
        }
        END {
            for (pair in component) {
                split(pair,parts,"|")
                group=parts[1] "|" parts[2]
                if (count[group] <= limit) print component[pair]
            }
        }
    ' "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$activities_raw"
    ifw_filter_global_candidates "$activities_raw" "$activity_pairs" "$installed" "$activities"

    activity_count=$(grep -c . "$activities" 2>/dev/null); [ -n "$activity_count" ] || activity_count=0
    receiver_count=$(grep -c . "$receivers" 2>/dev/null); [ -n "$receiver_count" ] || receiver_count=0
    service_count=$(grep -c . "$services" 2>/dev/null); [ -n "$service_count" ] || service_count=0
    total_ifw=$((activity_count + receiver_count + service_count))

    if [ "$total_ifw" -eq 0 ]; then
        rm -f "$IFW_RULE_FILE" 2>/dev/null || true
        rm -f $ifw_work_files 2>/dev/null
        log "IFW reconciled: no owned rules"
        return 0
    fi

    tmp="$IFW_RULE_FILE.tmp.$$"
    {
        echo '<rules>'
        if [ "$activity_count" -gt 0 ]; then
            echo '  <activity block="true" log="false">'
            while IFS= read -r comp; do
                [ -n "$comp" ] && printf '    <component-filter name="%s"/>\n' "$comp"
            done < "$activities"
            echo '  </activity>'
        fi
        if [ "$service_count" -gt 0 ]; then
            echo '  <service block="true" log="false">'
            while IFS= read -r comp; do
                [ -n "$comp" ] && printf '    <component-filter name="%s"/>\n' "$comp"
            done < "$services"
            echo '  </service>'
        fi
        if [ "$receiver_count" -gt 0 ]; then
            echo '  <broadcast block="true" log="false">'
            while IFS= read -r comp; do
                [ -n "$comp" ] && printf '    <component-filter name="%s"/>\n' "$comp"
            done < "$receivers"
            echo '  </broadcast>'
        fi
        echo '</rules>'
    } > "$tmp" 2>/dev/null || {
        rm -f "$tmp" $ifw_work_files 2>/dev/null
        log "IFW-WRITE-FAILED temp=$tmp"
        return 1
    }

    chmod 0644 "$tmp" 2>/dev/null || {
        rm -f "$tmp" $ifw_work_files 2>/dev/null
        log "IFW-CHMOD-FAILED temp=$tmp"
        return 1
    }
    command -v restorecon >/dev/null 2>&1 && restorecon "$tmp" >/dev/null 2>&1 || true
    mv -f "$tmp" "$IFW_RULE_FILE" 2>/dev/null || {
        rm -f "$tmp" $ifw_work_files 2>/dev/null
        log "IFW-COMMIT-FAILED file=$IFW_RULE_FILE"
        return 1
    }
    command -v restorecon >/dev/null 2>&1 && restorecon "$IFW_RULE_FILE" >/dev/null 2>&1 || true
    rm -f $ifw_work_files 2>/dev/null
    log "IFW reconciled: activity=$activity_count receiver=$receiver_count service=$service_count total=$total_ifw file=$IFW_RULE_FILE"
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
            *) [ "$(get_component_override_state "$user" "$comp")" = "disabled" ] && _amd_disabled=1 || _amd_disabled=0 ;;
        esac
        if [ "$_amd_disabled" = "1" ]; then
            aad_fail_fast_reset
            AAD_ALREADY_DISABLED_COUNT=$((${AAD_ALREADY_DISABLED_COUNT:-0} + 1))
            return 0
        fi
    else
        ensure_original_state "$user" "$comp"
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
}

restore_all_for_package() {
    pkg="$1"
    users=$(awk -F'|' -v p="$pkg/" 'index($2,p)==1 {print $1}' "$DISABLED_LIST" 2>/dev/null | sort -u)
    for user in $users; do
        restore_all_for_package_user "$user" "$pkg"
    done
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
    record_package_audit "$user" "$pkg" && AAD_PACKAGE_AUDIT_READY=1

    if is_system_protected "$pkg"; then
        log "POLICY-SKIP protected u$user: $pkg"
    elif is_globally_whitelisted "$pkg"; then
        log "WHITELIST-SKIP global u$user: $pkg"
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
            mode_now=$(read_component_mode)
            if [ "$cat" = "ADS" ] && [ "$mode_now" = "AGGRESSIVE" ]; then
                max=$(read_aggressive_ads_max_matches)
            fi
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

    disabled_now=0
    while IFS='|' read -r du dc dk; do
        [ -z "$dc" ] && continue
        if add_membership_and_disable "$du" "$dc" "$dk"; then
            disabled_now=$((disabled_now + 1))
        fi
        if [ -n "$AAD_FAIL_FAST_ABORT" ] && [ -f "$AAD_FAIL_FAST_ABORT" ]; then
            break
        fi
    done < "$desired"

    [ "${AAD_ALREADY_DISABLED_COUNT:-0}" -gt 0 ] &&         log "ALREADY-DISABLED u$user: $pkg components=$AAD_ALREADY_DISABLED_COUNT"
    aad_pkg_snapshot_clear
    rm -f "$desired" "$existing"
    echo "$disabled_now"
    if [ -n "$AAD_FAIL_FAST_ABORT" ] && [ -f "$AAD_FAIL_FAST_ABORT" ]; then
        return 2
    fi
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
        list_all_installed_package_keys > "$snapshot"
        own_snapshot=1
    fi

    total=0
    users=$(list_user_ids)
    for user in $users; do
        log "CONFIG-DELTA user=$user package=$pkg begin"
        if package_installed_in_snapshot "$snapshot" "$user" "$pkg"; then
            process_package_user "$user" "$pkg" >/dev/null
            rc=$?
            log "CONFIG-DELTA user=$user package=$pkg end installed=yes rc=$rc"
            [ "$rc" -eq 2 ] && { [ "$own_snapshot" -eq 1 ] && rm -f "$snapshot" 2>/dev/null; return 2; }
        else
            restore_all_for_package_user "$user" "$pkg"
            rc=$?
            log "CONFIG-DELTA user=$user package=$pkg end installed=no restore_rc=${rc:-0}"
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
        list_all_installed_package_keys > "$installed_keys"
        own_snapshot=1
    fi

    if [ ! -s "$installed_keys" ]; then
        log "STALE-SKIP: installed-package snapshot is empty (PackageManager unavailable); membership/state DB left untouched."
        [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
        return 0
    fi

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
        if grep -Fxq -- "$user|$pkg" "$installed_keys" 2>/dev/null; then
            printf '%s|%s|%s\n' "$user" "$comp" "$cat" >> "$tmp"
        else
            log "STALE: dropping record u$user $comp ($cat); package truly absent from installed snapshot."
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
    for record in $orphan_records; do
        [ -n "$record" ] || continue
        user=${record%%|*}
        rest=${record#*|}
        comp=${rest%%|*}
        original=${rest#*|}
        [ -n "$comp" ] || continue
        if ! has_any_membership "$user" "$comp"; then
            restore_original_state "$user" "$comp"
        fi
    done
    IFS=$old_ifs
}

compute_config_hash() {
    {
        for f in "$SETTINGS_FILE" "$RULES_FILE" "$WHITELIST_FILE" "$WHITE_ADS_FILE" "$WHITE_ANALYTICS_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

compute_base_policy_hash() {
    {
        for f in "$SETTINGS_FILE" "$RULES_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
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
    list_all_installed_package_keys > "$installed_snapshot"
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
    reconcile_owned_ifw_rules || {
        log "CONFIG-DELTA: IFW reconciliation failed."
        return 1
    }
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

    if [ -d "$LOCK_DIR" ]; then
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            log "CONFIG-DEFER: reconciliation already active owner=$owner reason=$reason"
            return 0
        fi
    fi

    acquire_lock || { log "CONFIG-DEFER: could not acquire reconciliation lock reason=$reason"; return 0; }

    current_hash=$(compute_config_hash)
    previous_hash=$(cat "$CONFIG_HASH_FILE" 2>/dev/null)
    if [ "$current_hash" = "$previous_hash" ]; then
        release_lock
        return 0
    fi

    current_base=$(compute_base_policy_hash)
    previous_base=$(cat "$BASE_POLICY_HASH_FILE" 2>/dev/null)

    if [ -n "$previous_base" ] && [ "$current_base" = "$previous_base" ]; then
        log "CONFIG changed -> whitelist delta reconciliation source=$reason old=${previous_hash:-none} new=$current_hash"
        reconcile_whitelist_delta_locked
        rc=$?
    else
        log "CONFIG changed -> full policy reconciliation source=$reason base_policy_changed=yes old=${previous_hash:-none} new=$current_hash"
        full_rescan_locked
        rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        refresh_policy_caches
        compute_config_hash > "$CONFIG_HASH_FILE"
        compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"
    fi
    release_lock
    [ "$rc" -eq 0 ] && reconcile_ad_surface_killer "config:$reason" >/dev/null 2>&1 || true
    [ "$rc" -eq 0 ] && launch_ad_surface_indexer_bg "config:$reason" >/dev/null 2>&1 || true
    return "$rc"
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
    list_all_installed_package_keys > "$installed_keys"
    cleanup_stale_records "$installed_keys"
    retry_orphan_restores
    new_state="$DATA_DIR/package_state.tmp.$$"
    list_all_package_state > "$new_state"
    total=0
    processed=0
    skipped=0
    aborted=0
    AAD_AUDIT_CARRY="$COMPONENT_AUDIT_FILE.carry"
    AAD_SDK_CARRY="$SDK_FINGERPRINT_FILE.carry"
    rm -f "$AAD_AUDIT_CARRY" "$AAD_SDK_CARRY" 2>/dev/null
    [ -s "$COMPONENT_AUDIT_FILE" ] && cp "$COMPONENT_AUDIT_FILE" "$AAD_AUDIT_CARRY" 2>/dev/null
    [ -s "$SDK_FINGERPRINT_FILE" ] && cp "$SDK_FINGERPRINT_FILE" "$AAD_SDK_CARRY" 2>/dev/null

    AAD_POLICY_FINGERPRINT=$(compute_config_hash)
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
            printf '|%s|%s|%s|
' "$user" "$pkg" "$vc" >> "$AAD_VERIFIED_NEW"
            printf '%s|%s
' "$user" "$pkg" >> "$AAD_SKIPPED_KEYS"
            skipped=$((skipped + 1))
            continue
        fi
        [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "[$processed/$scan_total] u$user $pkg"
        AAD_CURRENT_VERSION_CODE="$vc"
        export AAD_CURRENT_VERSION_CODE
        n=$(process_package_user "$user" "$pkg")
        rc=$?
        [ "$rc" -eq 0 ] && printf '|%s|%s|%s|
' "$user" "$pkg" "$vc" >> "$AAD_VERIFIED_NEW"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
        if [ "$rc" -eq 2 ] || [ -f "$AAD_FAIL_FAST_ABORT" ]; then
            aborted=1
            break
        fi
    done < "$new_state"
    AAD_TIMING_PACKAGE_END=$(aad_now_ms)

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

    if [ "$aborted" -ne 1 ] && [ -s "$AAD_VERIFIED_NEW" ]; then
        chmod 600 "$AAD_VERIFIED_NEW" 2>/dev/null || true
        if mv -f "$AAD_VERIFIED_NEW" "$PACKAGE_VERIFIED_FILE" 2>/dev/null; then
            printf '%s
' "$AAD_POLICY_FINGERPRINT" > "$PACKAGE_VERIFIED_HASH_FILE" 2>/dev/null
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
    if [ -s "$new_state" ]; then
        mv -f "$new_state" "$STATE_FILE"
    else
        rm -f "$new_state" 2>/dev/null
        log "PACKAGE-STATE-SKIP: enumeration returned no packages; previous baseline preserved."
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
    compute_config_hash > "$CONFIG_HASH_FILE"
    compute_base_policy_hash > "$BASE_POLICY_HASH_FILE"
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
    log "FULL-SCAN finished: packages/users=$processed operations=$total"
    [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "Scan complete: $processed checked, $total policy operations."
    return 0
}

full_rescan() {
    acquire_lock || { log "LOCK timeout: full rescan skipped"; return 1; }
    full_rescan_locked
    _fr_rc=$?
    release_lock
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
    list_all_package_state > "$current"
    new_count=$(grep -c '|' "$current" 2>/dev/null); [ -n "$new_count" ] || new_count=0
    AAD_PACKAGE_CHANGES=0
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
            process_package_user "$user" "$pkg" >/dev/null
        fi
    done < "$current"

    rm -f "$AAD_APK_PATH_CACHE" 2>/dev/null
    unset AAD_APK_PATH_CACHE AAD_MANIFEST_CACHE_ENABLED AAD_MANIFEST_RULES_HASH AAD_CURRENT_VERSION_CODE

    mv -f "$current" "$STATE_FILE"
    cleanup_stale_records
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
    rescan_changed_packages_locked
    rc=$?
    changes=${AAD_PACKAGE_CHANGES:-0}
    release_lock
    if [ "$rc" -eq 0 ] && [ "$changes" -gt 0 ] 2>/dev/null; then
        reconcile_ad_surface_killer "package-change:$changes" >/dev/null 2>&1 || true
        launch_ad_surface_indexer_bg "package-change:$changes" >/dev/null 2>&1 || true
    fi
    return "$rc"
}
