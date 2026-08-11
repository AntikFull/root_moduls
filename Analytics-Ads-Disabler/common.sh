#!/system/bin/sh
# Shared library for Analytics & Ads Disabler v4 Universal Edition.
# POSIX/BusyBox ash compatible; intended for Magisk, KernelSU and APatch.

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null
# service.sh may preselect an internal runtime log so boot/runtime never depends
# on emulated storage readiness. Other entry points use the unified logs dir.
if [ -z "${LOGFILE:-}" ]; then
    LOGFILE="$LOG_DIR/debug.log"
fi
DISABLED_LIST="$DATA_DIR/disabled_components.list"       # user|pkg/component|CATEGORY
COMPONENT_STATE="$DATA_DIR/component_state.list"         # user|pkg/component|original_override_state
STATE_FILE="$DATA_DIR/package_state.list"                # user|package|versionCode
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
LOCK_DIR="$DATA_DIR/.operation.lock"
STATE_DB_LOCK="$DATA_DIR/.state_db.lock"
MEMBERSHIP_DB_LOCK="$DATA_DIR/.membership_db.lock"
CAPABILITIES_FILE="$DATA_DIR/capabilities.conf"
COMPONENT_AUDIT_FILE="$LOG_DIR/component_audit.log"
IFW_DIR="${IFW_DIR:-/data/system/ifw}"
IFW_RULE_FILE="$IFW_DIR/analytics_ads_disabler.xml"

# Compatibility dispatcher. It selects commands once per device/ROM and never evals the profile.
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
    # service.sh may source this before Android has completed boot. In that
    # path defer all Binder/capability probing until sys.boot_completed=1.
    if [ "${AAD_DEFER_CAPABILITY_INIT:-0}" != "1" ]; then
        ensure_capability_profile >/dev/null 2>&1
        load_capabilities
    fi
fi

CATEGORIES="ADS ANALYTICS"
SYSTEM_PROTECTED="android com.android.systemui com.android.settings com.android.packageinstaller com.android.permissioncontroller com.google.android.permissioncontroller com.android.phone com.android.providers.settings com.android.providers.downloads com.android.documentsui com.android.shell com.android.bluetooth com.android.nfc com.android.location.fused com.android.networkstack com.google.android.networkstack com.android.networkstack.tethering com.google.android.networkstack.tethering com.google.android.gms com.android.vending com.google.android.gsf com.google.android.inputmethod.latin com.huawei.hwid com.huawei.hms.config.service com.sec.android.app.samsungapps com.topjohnwu.magisk me.weishu.kernelsu me.bmax.apatch"

mkdir -p "$DATA_DIR" 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$LOGFILE"
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
    # Best-effort only: never let emulated-storage health block the core runtime.
    mkdir -p "$SDCARD_LOG_DIR" 2>/dev/null || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 cp "$LOG_DIR"/*.log "$SDCARD_LOG_DIR/" 2>/dev/null || true
    else
        cp "$LOG_DIR"/*.log "$SDCARD_LOG_DIR/" 2>/dev/null || true
    fi
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

    # Help/capability surfaces. These are intentionally verbose and captured once per Action run.
    diag_capture_sh "cmd --help" 'cmd --help 2>&1'
    diag_capture_sh "cmd -l" 'cmd -l 2>&1'
    diag_capture_sh "cmd package help" 'cmd package help 2>&1'
    diag_capture_sh "pm help" 'pm help 2>&1'
    diag_capture_sh "cmd activity help" 'cmd activity help 2>&1'
    diag_capture_sh "cmd user help" 'cmd user help 2>&1'
    diag_capture_sh "service list" 'service list 2>&1'
    diag_capture_sh "service check package/activity/user" 'service check package 2>&1; service check activity 2>&1; service check user 2>&1'

    # Read-only Binder smoke tests in the exact execution domains used by the cascade.
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
# Backward compatibility with v3 rules.conf settings.
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

read_component_mode() {
    val=$(read_setting COMPONENT_MODE SAFE | tr '[:lower:]' '[:upper:]')
    case "$val" in
        SAFE|BALANCED) echo "$val" ;;
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
    val=$(read_setting MAX_IFW_ACTIVITIES_PER_CATEGORY 5)
    case "$val" in
        ''|*[!0-9]*) echo 5 ;;
        *)
            [ "$val" -lt 1 ] 2>/dev/null && val=1
            [ "$val" -gt 25 ] 2>/dev/null && val=25
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

acquire_lock() {
    retries=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -z "$oldpid" ] || ! kill -0 "$oldpid" 2>/dev/null; then
            rm -rf "$LOCK_DIR" 2>/dev/null
            continue
        fi
        retries=$((retries + 1))
        [ "$retries" -ge 60 ] && return 1
        sleep 1
    done
    echo $$ > "$LOCK_DIR/pid" 2>/dev/null
    return 0
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

# File-level DB locks are separate from the scan/reconciliation lock. They make
# state mutations safe even during module upgrades or unexpected overlapping
# callbacks. BusyBox ash may preserve $$ in subshells, so never derive temp
# filenames from $$ alone.
aad_db_lock() {
    lock="$1"
    tries=0
    while ! mkdir "$lock" 2>/dev/null; do
        owner=$(cat "$lock/pid" 2>/dev/null)
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$lock" 2>/dev/null
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 100 ] && return 1
        sleep 0.1 2>/dev/null || sleep 1
    done
    echo $$ > "$lock/pid" 2>/dev/null
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
    # Fallback for very small Android toolboxes: include uptime checksum in
    # addition to PID so nested ash subshells do not collide on one filename.
    salt=$(cat /proc/uptime 2>/dev/null | cksum 2>/dev/null | awk '{print $1}')
    [ -n "$salt" ] || salt=0
    echo "${target}.tmp.$$.${salt}"
}

stop_owned_pidfile() {
    pidfile="$1"
    marker="$2"
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$cmdline" in
            *"$marker"*)
                kill "$pid" 2>/dev/null
                log "Stopped owned process pid=$pid marker=$marker"
                ;;
            *)
                log "PID-SAFETY: pid=$pid no longer matches $marker; not killed."
                ;;
        esac
    fi
    rm -f "$pidfile" 2>/dev/null
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

package_installed_for_user() {
    user="$1"
    pkg="$2"
    # Do not rely on PackageManager's optional trailing package filter here.
    # Android 16 vendor implementations can return a false empty result for an
    # installed package. Enumerating once and exact-matching the package name is
    # slower for an isolated check, but reliable; full-scan stale cleanup uses a
    # cached all-package snapshot below and avoids repeating this Binder call.
    cap_list_packages_raw "$user" 0 0 "" 2>/dev/null \
        | sed 's/^package://; s/[[:space:]].*$//' \
        | grep -Fxq -- "$pkg"
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

# Exact package-manager state change through the pre-probed device profile.
# No command fallback chain is executed for every component.
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

# Determine whether the component had an explicit enabled/disabled override before v4 touched it.
# dumpsys exposes explicit enabledComponents/disabledComponents per Android user. Anything absent is default.
get_component_override_state() {
    user="$1"
    comp="$2"
    pkg=${comp%%/*}
    cls=${comp#*/}
    case "$cls" in
        .*) full_cls="$pkg$cls" ;;
        *) full_cls="$cls" ;;
    esac

    state=$(cap_package_dump "$pkg" | awk -v uid="$user" -v full="$full_cls" -v short="$cls" '
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
    # Re-check after lock acquisition: another callback may have saved it.
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

# Универсальный парсер использует только структурные секции dumpsys и не зависит от OEM.
get_typed_component_candidates() {
    pkg="$1"
    cap_package_dump "$pkg" | awk -v p="$pkg" '
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
    ' | sort -u
}

# Один dumpsys кэшируется для всех категорий и типов компонентов пакета.
get_typed_component_candidates_cached() {
    pkg="$1"
    if [ -n "$SCAN_CANDIDATE_CACHE_DIR" ] && [ -d "$SCAN_CANDIDATE_CACHE_DIR" ]; then
        key=$(printf '%s' "$pkg" | cksum 2>/dev/null | awk '{print $1 "_" $2}')
        [ -n "$key" ] || key=$(printf '%s' "$pkg" | tr '/ :' '___')
        cache="$SCAN_CANDIDATE_CACHE_DIR/$key"
        if [ ! -f "$cache" ]; then
            get_typed_component_candidates "$pkg" > "$cache.tmp.$$"
            mv "$cache.tmp.$$" "$cache" 2>/dev/null || cp "$cache.tmp.$$" "$cache" 2>/dev/null
            rm -f "$cache.tmp.$$"
        fi
        cat "$cache" 2>/dev/null
        return
    fi
    get_typed_component_candidates "$pkg"
}

component_matches_rule_section() {
    comp="$1"
    section="$2"
    [ -f "$RULES_FILE" ] || return 1

    awk -v target="[$section]" -v component="$comp" '
        BEGIN {inside=0; lc=tolower(component); found=0}
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
                if (component ~ pat || lc ~ tolower(pat)) found=1
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
            component_matches_rule_section "$comp" "$cat"
            ;;
        PROVIDER)
            [ "$mode" = "BALANCED" ] || return 1
            component_matches_rule_section "$comp" "${cat}_PROVIDER_SAFE"
            ;;
        *) return 1 ;;
    esac
}

component_matches_audit_rule() {
    comp="$1"; cat="$2"; kind="$3"
    case "$kind" in
        SERVICE|RECEIVER)
            component_matches_rule_section "$comp" "${cat}_${kind}" && return 0
            component_matches_rule_section "$comp" "$cat"
            ;;
        PROVIDER)
            component_matches_rule_section "$comp" "${cat}_PROVIDER_SAFE" && return 0
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
    get_typed_component_candidates_cached "$pkg" | while IFS='|' read -r kind comp; do
        [ -z "$comp" ] && continue
        component_matches_disable_rule "$comp" "$cat" "$kind" "$mode" && echo "$comp"
    done
}

record_package_audit() {
    user="$1"; pkg="$2"; mode=$(read_component_mode)
    [ -n "$COMPONENT_AUDIT_FILE" ] || return 0
    if [ "${AAD_AUDIT_FULL_SCAN:-0}" != "1" ] && [ -f "$COMPONENT_AUDIT_FILE" ]; then
        audit_clean=$(aad_mktemp_near "$COMPONENT_AUDIT_FILE")
        if [ -n "$audit_clean" ]; then
            awk -F'|' -v u="$user" -v p="$pkg" 'NR==1 || !($2==u && $3==p)' "$COMPONENT_AUDIT_FILE" > "$audit_clean" 2>/dev/null && mv -f "$audit_clean" "$COMPONENT_AUDIT_FILE"
            [ -f "$audit_clean" ] && rm -f "$audit_clean" 2>/dev/null
        fi
    fi
    candidates=$(aad_mktemp_near "$DATA_DIR/.audit_candidates")
    [ -n "$candidates" ] || return 1
    get_typed_component_candidates_cached "$pkg" > "$candidates"
    block_ads=$(read_bool_setting BLOCK_ADS 1)
    block_analytics=$(read_bool_setting BLOCK_ANALYTICS 1)
    global_white=0; ads_white=0; analytics_white=0
    is_globally_whitelisted "$pkg" && global_white=1
    is_category_whitelisted "$pkg" ADS && ads_white=1
    is_category_whitelisted "$pkg" ANALYTICS && analytics_white=1
    audit_time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

    backend=$(read_component_backend)
    awk -F'|' -v user="$user" -v pkg="$pkg" -v mode="$mode" -v backend="$backend" -v stamp="$audit_time" \
        -v block_ads="$block_ads" -v block_analytics="$block_analytics" \
        -v global_white="$global_white" -v ads_white="$ads_white" -v analytics_white="$analytics_white" '
        BEGIN {OFS="|"}
        function trim(s) {sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
        function section_match(section, component,    i,rule,pattern,lower_component) {
            lower_component=tolower(component)
            for (i=1; i<=rule_count[section]; i++) {
                rule=rules[section,i]
                if (substr(rule,1,3)=="re:") {
                    pattern=substr(rule,4)
                    if (component ~ pattern || lower_component ~ tolower(pattern)) return 1
                } else if (index(lower_component,tolower(rule))>0) return 1
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
                }
            } else if (kind=="PROVIDER") {
                for (ci=1; ci<=2; ci++) {
                    category=(ci==1 ? "ADS" : "ANALYTICS")
                    if (section_match(category "_PROVIDER_SAFE",component))
                        emit(category,kind,component,"BALANCED",(mode=="BALANCED" ? "DISABLE" : "REPORT_ONLY"))
                    else if (section_match(category "_PROVIDER_AUDIT",component))
                        emit(category,kind,component,"AUDIT","REPORT_ONLY")
                }
            } else if (kind=="ACTIVITY") {
                for (ci=1; ci<=2; ci++) {
                    category=(ci==1 ? "ADS" : "ANALYTICS")
                    if (section_match(category "_ACTIVITY_IFW",component))
                        emit(category,kind,component,"HYBRID",(backend=="HYBRID" ? "IFW_BLOCK" : "REPORT_ONLY"))
                    else if (section_match(category "_ACTIVITY_AUDIT",component))
                        emit(category,kind,component,"AUDIT","REPORT_ONLY")
                }
            }
        }
    ' "$RULES_FILE" "$candidates" >> "$COMPONENT_AUDIT_FILE"
    rc=$?
    rm -f "$candidates" 2>/dev/null
    return "$rc"
}

# IFW is global across Android users. A component may be put into the owned
# IFW file only when every installed user of that package agrees that the
# component should be blocked. This prevents a work profile / secondary user
# whitelist from being overridden by a rule requested only by another user.
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

# IFW не умеет блокировать Provider и действует глобально для всех пользователей.
# Модуль владеет только одним отдельным XML и никогда не изменяет файлы App Manager/Blocker.
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
    # Непустой первый вход устраняет неоднозначность NR==FNR в старых awk.
    printf '#\n' >> "$managed"

    # IFW rules are global, therefore an authoritative user/package snapshot is
    # mandatory before emitting them. On snapshot failure we prefer PM-only
    # behavior over a rule that could override another user's whitelist.
    list_all_installed_package_keys > "$installed" 2>/dev/null
    if [ ! -s "$installed" ]; then
        rm -f "$IFW_RULE_FILE" "$managed" "$managed_pairs" "$installed" \
            "$activity_pairs" "$activities_raw" "$receivers_raw" "$services_raw" \
            "$activities" "$receivers" "$services" 2>/dev/null || true
        log "IFW-SAFETY-SKIP reason=installed_user_snapshot_unavailable"
        return 1
    fi

    # Двойной слой IFW+PM применяется только к компонентам, которыми модуль реально владеет.
    awk -F'|' 'NR==FNR {owned[$1]=1; next} FNR>1 && $7=="DISABLE" && $5=="RECEIVER" && owned[$8] {print $8}' \
        "$managed" "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$receivers_raw"
    awk -F'|' 'NR==FNR {owned[$1]=1; next} FNR>1 && $7=="DISABLE" && $5=="SERVICE" && owned[$8] {print $8}' \
        "$managed" "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$services_raw"
    ifw_filter_global_candidates "$receivers_raw" "$managed_pairs" "$installed" "$receivers"
    ifw_filter_global_candidates "$services_raw" "$managed_pairs" "$installed" "$services"

    # Activity разрешаются только отдельными точными правилами и с лимитом на пакет/категорию.
    # Because activities are IFW-only, user agreement comes from the audit plan
    # rather than PM membership records.
    awk -F'|' 'FNR>1 && $2!="" && $7=="IFW_BLOCK" {print $2 "|" $8}' \
        "$COMPONENT_AUDIT_FILE" 2>/dev/null | sort -u > "$activity_pairs"
    ifw_limit=$(read_ifw_activity_limit)
    awk -F'|' -v limit="$ifw_limit" '
        FNR>1 && $5=="ACTIVITY" && $7=="IFW_BLOCK" {
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

membership_exists() {
    user="$1"; comp="$2"; cat="$3"
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

    # Policy membership and execution transport are separate concerns. If this
    # component is already managed by the module and still disabled, no Binder
    # write is needed during a reconciliation scan.
    if membership_exists "$user" "$comp" "$cat"; then
        current_override=$(get_component_override_state "$user" "$comp")
        if [ "$current_override" = "disabled" ]; then
            aad_fail_fast_reset
            log "ALREADY-DISABLED ($cat) u$user: $comp"
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

# Reconcile one package/user against the complete desired policy, including overlapping categories.
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
            if [ "$count" -gt "$max" ]; then
                log "SAFETY ($cat) u$user $pkg: $count matches > $max; category skipped."
                continue
            fi
            printf '%s\n' "$comps" | while IFS= read -r comp; do
                [ -n "$comp" ] && echo "$user|$comp|$cat" >> "$desired"
            done
        done
    fi
    sort -u "$desired" > "$desired.sorted" 2>/dev/null && mv "$desired.sorted" "$desired"

# Remove obsolete memberships first. Restoration happens only when no other category still needs the component.
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
            # Avoid command substitution here. Besides hiding progress, ash can
            # preserve $$ in subshells and makes debugging/temporary-file
            # ownership unnecessarily confusing. The delta path does not need
            # the numeric disabled counter.
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
    [ -f "$DISABLED_LIST" ] || return
    installed_keys="${1:-}"
    own_snapshot=0
    if [ -z "$installed_keys" ] || [ ! -f "$installed_keys" ]; then
        installed_keys="$DATA_DIR/.installed_keys.$$"
        list_all_installed_package_keys > "$installed_keys"
        own_snapshot=1
    fi

    tmp="$DISABLED_LIST.tmp.$$"
    : > "$tmp"
    while IFS='|' read -r user comp cat; do
        [ -z "$comp" ] && continue
        pkg=${comp%%/*}
        if grep -Fxq -- "$user|$pkg" "$installed_keys" 2>/dev/null; then
            echo "$user|$comp|$cat" >> "$tmp"
        else
            log "STALE: dropping record u$user $comp ($cat); package truly absent from installed snapshot."
            remove_state_record "$user" "$comp"
        fi
    done < "$DISABLED_LIST"
    mv "$tmp" "$DISABLED_LIST"
    [ "$own_snapshot" -eq 1 ] && rm -f "$installed_keys" 2>/dev/null
}

retry_orphan_restores() {
    [ -f "$COMPONENT_STATE" ] || return
    work="$COMPONENT_STATE.orphans.$$"
    cp "$COMPONENT_STATE" "$work" 2>/dev/null || return

    # Do not execute PackageManager mutations while a /data/adb state file is
    # attached to a shell read loop. BusyBox/ash can retain the loop fd across
    # nested function/exec boundaries; when the PM transport switches to
    # u:r:shell:s0, OEM SELinux then reports attempts to read adb_data_file.
    # Snapshot the small state DB into memory, close/remove the backing file,
    # and only then perform restore operations.
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
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        log "CONFIG-DELTA package=$pkg global=$(is_globally_whitelisted "$pkg" && echo yes || echo no) ads=$(is_category_whitelisted "$pkg" ADS && echo yes || echo no) analytics=$(is_category_whitelisted "$pkg" ANALYTICS && echo yes || echo no)"
        process_package_all_users "$pkg" "$installed_snapshot" >/dev/null
        rc=$?
        log "CONFIG-DELTA package=$pkg complete rc=$rc"
        [ "$rc" -eq 2 ] && { rm -f "$changed" "$installed_snapshot" 2>/dev/null; return 2; }
    done < "$changed"
    rm -f "$changed" "$installed_snapshot" 2>/dev/null
    reconcile_owned_ifw_rules || {
        log "CONFIG-DELTA: IFW reconciliation failed."
        return 1
    }
    log "CONFIG-DELTA: reconciliation complete."
    return 0
}

refresh_policy_caches() {
    read_category_list ADS > "$CACHE_ADS"
    read_category_list ANALYTICS > "$CACHE_ANALYTICS"
    read_global_list > "$CACHE_GLOBAL"
}

# Reconcile config changes under the same operation lock used by scans.  The hash
# is re-checked *after* lock acquisition so duplicate inotify events and the
# polling safety net collapse into a single full reconciliation.
reconcile_config_if_changed() {
    reason="${1:-unknown}"

    # Config callbacks should never sit for a minute behind another scan. If a
    # reconciliation already owns the global lock, defer this duplicate/event;
    # the hash polling safety net will retry if the active operation did not
    # consume the new config.
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
    return "$rc"
}

full_rescan_locked() {
    # Build one authoritative all-package snapshot first. Stale cleanup must not
    # use PackageManager's flaky per-package filter on some Android 16 ROMs.
    installed_keys="$DATA_DIR/.installed_keys.$$"
    list_all_installed_package_keys > "$installed_keys"
    cleanup_stale_records "$installed_keys"
    retry_orphan_restores
    new_state="$DATA_DIR/package_state.tmp.$$"
    list_all_package_state > "$new_state"
    total=0
    processed=0
    aborted=0
    printf 'timestamp|user|package|category|type|risk|action|component\n' > "$COMPONENT_AUDIT_FILE" 2>/dev/null
    chmod 600 "$COMPONENT_AUDIT_FILE" 2>/dev/null
    AAD_AUDIT_FULL_SCAN=1
    export AAD_AUDIT_FULL_SCAN

    AAD_FAIL_FAST_STATE="$DATA_DIR/.fail_fast_count.$$"
    AAD_FAIL_FAST_ABORT="$DATA_DIR/.fail_fast_abort.$$"
    export AAD_FAIL_FAST_STATE AAD_FAIL_FAST_ABORT
    rm -f "$AAD_FAIL_FAST_ABORT" 2>/dev/null
    printf '0\n' > "$AAD_FAIL_FAST_STATE" 2>/dev/null

    scan_total=$(grep -c '|' "$new_state" 2>/dev/null)
    [ -n "$scan_total" ] || scan_total=0

    SCAN_CANDIDATE_CACHE_DIR="$DATA_DIR/.scan_candidates.$$"
    export SCAN_CANDIDATE_CACHE_DIR
    rm -rf "$SCAN_CANDIDATE_CACHE_DIR" 2>/dev/null
    mkdir -p "$SCAN_CANDIDATE_CACHE_DIR" 2>/dev/null

    [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "Packages/users to check: $scan_total"

    while IFS='|' read -r user pkg vc; do
        [ -z "$pkg" ] && continue
        processed=$((processed + 1))
        [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "[$processed/$scan_total] u$user $pkg"
        n=$(process_package_user "$user" "$pkg")
        rc=$?
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
        if [ "$rc" -eq 2 ] || [ -f "$AAD_FAIL_FAST_ABORT" ]; then
            aborted=1
            break
        fi
    done < "$new_state"

    rm -rf "$SCAN_CANDIDATE_CACHE_DIR" 2>/dev/null
    unset SCAN_CANDIDATE_CACHE_DIR
    unset AAD_AUDIT_FULL_SCAN
    rm -f "$AAD_FAIL_FAST_STATE" 2>/dev/null
    mv "$new_state" "$STATE_FILE"

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
    if ! reconcile_owned_ifw_rules; then
        rm -f "$installed_keys" 2>/dev/null
        log "FULL-SCAN: IFW reconciliation failed."
        return 1
    fi
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
            printf "candidates=%d packages/users=%d ads=%d analytics=%d safe=%d balanced=%d hybrid=%d audit_only=%d disable=%d ifw_block=%d report_only=%d skipped=%d", total, package_count, categories["ADS"]+0, categories["ANALYTICS"]+0, risks["SAFE"]+0, risks["BALANCED"]+0, risks["HYBRID"]+0, risks["AUDIT"]+0, actions["DISABLE"]+0, actions["IFW_BLOCK"]+0, actions["REPORT_ONLY"]+0, actions["SKIP_POLICY"]+0
        }
    ' "$COMPONENT_AUDIT_FILE" 2>/dev/null)
    log "AUDIT-SUMMARY mode=$(read_component_mode) backend=$(read_component_backend) $audit_summary file=$COMPONENT_AUDIT_FILE"
    log "FULL-SCAN finished: packages/users=$processed operations=$total"
    [ "$AAD_SHOW_PROGRESS" = "1" ] && echo "Scan complete: $processed checked, $total policy operations."
    return 0
}

full_rescan() {
    acquire_lock || { log "LOCK timeout: full rescan skipped"; return 1; }
    full_rescan_locked
    release_lock
}

rescan_changed_packages_locked() {
    current="$DATA_DIR/package_state.current.$$"
    list_all_package_state > "$current"

    while IFS='|' read -r user pkg vc; do
        [ -z "$pkg" ] && continue
        if ! grep -Fxq -- "$user|$pkg|$vc" "$STATE_FILE" 2>/dev/null; then
            log "PACKAGE-CHANGE u$user: $pkg ($vc)"
            process_package_user "$user" "$pkg" >/dev/null
        fi
    done < "$current"

    mv "$current" "$STATE_FILE"
    cleanup_stale_records
    reconcile_owned_ifw_rules
}

rescan_changed_packages() {
    acquire_lock || { log "LOCK timeout: incremental rescan skipped"; return 1; }
    rescan_changed_packages_locked
    release_lock
}
