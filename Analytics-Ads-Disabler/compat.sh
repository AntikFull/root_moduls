#!/system/bin/sh
# Device capability profile for Analytics & Ads Disabler.
# Probes once, stores safe enum-like selections, and avoids per-operation fallback chains.

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
CAPABILITIES_FILE="${CAPABILITIES_FILE:-$DATA_DIR/capabilities.conf}"
CAP_PROFILE_VERSION=3

cap_read() {
    key="$1"; def="$2"; val=""
    if [ -f "$CAPABILITIES_FILE" ]; then
        val=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$CAPABILITIES_FILE" | head -n1 | tr -d '\r')
    fi
    [ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$def"
}

cap_device_signature() {
    fp=$(getprop ro.build.fingerprint 2>/dev/null)
    sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    abi=$(getprop ro.product.cpu.abi 2>/dev/null)
# No sourcing/eval is used for this value; it is only compared as plain text.
    printf '%s|sdk=%s|abi=%s\n' "$fp" "$sdk" "$abi"
}

cap_root_manager() {
    if [ "$KSU" = "true" ]; then
        echo KernelSU
    elif [ "$APATCH" = "true" ] || [ "$KERNELPATCH" = "true" ]; then
        echo APatch
    else
        echo Magisk
    fi
}

cap_pkg_help() {
    case "$1" in
        cmd) command -v cmd >/dev/null 2>&1 && cmd package help 2>&1 ;;
        pm) command -v pm >/dev/null 2>&1 && pm help 2>&1 ;;
        *) return 1 ;;
    esac
}

cap_pkg_exec_no_target() {
    backend="$1"; verb="$2"
    case "$backend" in
        cmd) cmd package "$verb" 2>&1 ;;
        pm) pm "$verb" 2>&1 ;;
        *) return 127 ;;
    esac
}

cap_backend_has_verb() {
    backend="$1"; verb="$2"
    help=$(cap_pkg_help "$backend")
    if printf '%s\n' "$help" | grep -Eiq "^[[:space:]]*${verb}([[:space:]]|\\[|$)"; then
        return 0
    fi

# Non-destructive parser probe: invoke the verb without a package/component.
# A recognized state command reaches a "missing target" error; an unsupported verb says unknown command.
    out=$(cap_pkg_exec_no_target "$backend" "$verb")
    printf '%s\n' "$out" | grep -Eiq 'no package( or component)? specified|package or component.*specified|no package.*component' && return 0
    return 1
}

cap_backend_verb_has_user() {
    backend="$1"; verb="$2"
    help=$(cap_pkg_help "$backend")
    printf '%s\n' "$help" | grep -Ei "^[[:space:]]*${verb}([[:space:]]|\\[|$)" | grep -q -- '--user'
}

# Runtime probe targets a deliberately impossible component name. When possible
# it uses an installed third-party package so the call traverses the real component
# validation path without touching a protected framework package. No valid component
# is ever toggled. If no third-party package exists, a nonexistent package is used.
cap_runtime_probe_target() {
    pkg=""
    if command -v cmd >/dev/null 2>&1; then
        pkg=$(cmd package list packages -3 --user 0 2>/dev/null | sed -n 's/^package:\([^[:space:]]*\).*/\1/p' | head -n1)
    fi
    if [ -z "$pkg" ] && command -v pm >/dev/null 2>&1; then
        pkg=$(pm list packages -3 --user 0 2>/dev/null | sed -n 's/^package:\([^[:space:]]*\).*/\1/p' | head -n1)
    fi
    [ -n "$pkg" ] || pkg="com.aad.capabilityprobe.never.exists"
    printf '%s/%s\n' "$pkg" '.AadCapabilityProbe_9f31c17f_4bd5_4ca2_bcb9_6d0d8f1e4200'
}

cap_exec_probe_target() {
    backend="$1"; verb="$2"; with_user="$3"
    target=$(cap_runtime_probe_target)
    case "$backend:$with_user" in
        cmd:1) cmd package "$verb" --user 0 "$target" 2>&1 ;;
        cmd:0) cmd package "$verb" "$target" 2>&1 ;;
        pm:1) pm "$verb" --user 0 "$target" 2>&1 ;;
        pm:0) pm "$verb" "$target" 2>&1 ;;
        *) return 127 ;;
    esac
}

cap_runtime_hard_failure() {
# Errors proving that the command path itself is unusable. Target-specific
# "component does not exist" errors are intentionally NOT included here.
    printf '%s\n' "$1" | grep -Eiq \
        'Failed transaction|Transaction failed|binder[^[:alnum:]]*.*fail|DeadObjectException|RemoteException|SecurityException|Unknown command|Unknown option|not supported|unsupported operation|invalid new component state|Failed setComponentEnabledSetting'
}

cap_runtime_reached_pm() {
    out="$1"; rc="$2"
    cap_runtime_hard_failure "$out" && return 1

# Expected safe result for the synthetic component: PackageManager reached
# the real state-change path and rejected only the nonexistent target.
    printf '%s\n' "$out" | grep -Eiq \
        'does not exist|Unknown component|Unknown package|not found|not installed|new state:' && return 0

# Some OEMs return success with terse/no output after validating the command.
    [ "$rc" -eq 0 ] 2>/dev/null && return 0
    return 1
}

cap_probe_action_candidate() {
    backend="$1"; verb="$2"
    cap_backend_has_verb "$backend" "$verb" || return 1

    if cap_backend_verb_has_user "$backend" "$verb"; then
        out=$(cap_exec_probe_target "$backend" "$verb" 1)
        rc=$?
        if cap_runtime_reached_pm "$out" "$rc"; then
            printf '%s|%s|1\n' "$backend" "$verb"
            return 0
        fi
    fi

# A ROM may expose the verb but not --user. Probe the user-0-only form too.
    out=$(cap_exec_probe_target "$backend" "$verb" 0)
    rc=$?
    if cap_runtime_reached_pm "$out" "$rc"; then
        printf '%s|%s|0\n' "$backend" "$verb"
        return 0
    fi
    return 1
}

cap_pick_action() {
# args: action-key candidate-verb...
# Candidate order is policy. Each candidate must also pass a real,
# non-destructive runtime/Binder probe; help text alone is insufficient.
    key="$1"; shift
    for verb in "$@"; do
        for backend in cmd pm; do
            spec=$(cap_probe_action_candidate "$backend" "$verb")
            if [ -n "$spec" ]; then
                printf '%s\n' "$spec"
                return 0
            fi
        done
    done
    printf 'none|none|0\n'
    return 1
}

cap_probe_user_list() {
    if command -v cmd >/dev/null 2>&1; then
        out=$(cmd user list 2>/dev/null)
        printf '%s\n' "$out" | grep -q 'UserInfo{' && { echo cmd_user; return; }
    fi
    if command -v pm >/dev/null 2>&1; then
        out=$(pm list users 2>/dev/null)
        printf '%s\n' "$out" | grep -q 'UserInfo{' && { echo pm; return; }
    fi
    echo none
}

cap_probe_package_list_backend() {
    if command -v cmd >/dev/null 2>&1; then
        out=$(cmd package list packages android 2>/dev/null)
        printf '%s\n' "$out" | sed 's/^package://; s/[[:space:]].*$//' | grep -Fxq android && { echo cmd; return; }
    fi
    if command -v pm >/dev/null 2>&1; then
        out=$(pm list packages android 2>/dev/null)
        printf '%s\n' "$out" | sed 's/^package://; s/[[:space:]].*$//' | grep -Fxq android && { echo pm; return; }
    fi
    echo none
}

cap_probe_package_list_user() {
    backend="$1"
    case "$backend" in
        cmd) out=$(cmd package list packages --user 0 android 2>/dev/null) ;;
        pm) out=$(pm list packages --user 0 android 2>/dev/null) ;;
        *) echo 0; return ;;
    esac
    printf '%s\n' "$out" | sed 's/^package://; s/[[:space:]].*$//' | grep -Fxq android && echo 1 || echo 0
}

cap_probe_package_versioncode() {
    backend="$1"; userarg="$2"
    case "$backend:$userarg" in
        cmd:1) out=$(cmd package list packages --user 0 --show-versioncode android 2>/dev/null) ;;
        cmd:0) out=$(cmd package list packages --show-versioncode android 2>/dev/null) ;;
        pm:1) out=$(pm list packages --user 0 --show-versioncode android 2>/dev/null) ;;
        pm:0) out=$(pm list packages --show-versioncode android 2>/dev/null) ;;
        *) echo 0; return ;;
    esac
    printf '%s\n' "$out" | grep -q 'versionCode:' && echo 1 || echo 0
}

cap_probe_dump_backend() {
    if command -v dumpsys >/dev/null 2>&1; then
        out=$(dumpsys package android 2>/dev/null)
        printf '%s\n' "$out" | grep -Eiq 'Package[[:space:]]*\[android\]|Packages:|User [0-9]+:' && { echo dumpsys; return; }
    fi
    if command -v cmd >/dev/null 2>&1; then
        out=$(cmd package dump android 2>/dev/null)
        printf '%s\n' "$out" | grep -Eiq 'Package[[:space:]]*\[android\]|Packages:|User [0-9]+:' && { echo cmd; return; }
    fi
    if command -v pm >/dev/null 2>&1; then
        out=$(pm dump android 2>/dev/null)
        printf '%s\n' "$out" | grep -Eiq 'Package[[:space:]]*\[android\]|Packages:|User [0-9]+:' && { echo pm; return; }
    fi
    echo none
}

cap_probe_watch_backend() {
    if command -v inotifyd >/dev/null 2>&1; then
        echo inotifyd
    else
        echo polling
    fi
}

probe_capabilities() {
    mkdir -p "$DATA_DIR" 2>/dev/null
    tmp="$CAPABILITIES_FILE.tmp.$$"

# Operational blocking prefers the per-user verb. Android 16 devices have
# been observed advertising both verbs while `disable` can fail at Binder runtime.
    disable_spec=$(cap_pick_action block disable-user disable)
    enable_spec=$(cap_pick_action enable enable-user enable)
    default_spec=$(cap_pick_action default default-state)

# Keep a separate path for restoring an original explicit `disabled` state.
# Prefer the exact verb, but gracefully fall back if this ROM cannot execute it.
    state_disabled_spec=$(cap_pick_action state_disabled disable disable-user)
    disable_user_spec=$(cap_pick_action disable_user disable-user disable)
    disable_until_spec=$(cap_pick_action disable_until disable-until-used disable-user disable)

    IFS='|' read -r dis_b dis_v dis_u <<EOF_SPEC
$disable_spec
EOF_SPEC
    IFS='|' read -r ena_b ena_v ena_u <<EOF_SPEC
$enable_spec
EOF_SPEC
    IFS='|' read -r def_b def_v def_u <<EOF_SPEC
$default_spec
EOF_SPEC
    IFS='|' read -r std_b std_v std_u <<EOF_SPEC
$state_disabled_spec
EOF_SPEC
    IFS='|' read -r dsu_b dsu_v dsu_u <<EOF_SPEC
$disable_user_spec
EOF_SPEC
    IFS='|' read -r duu_b duu_v duu_u <<EOF_SPEC
$disable_until_spec
EOF_SPEC

    user_backend=$(cap_probe_user_list)
    pkg_backend=$(cap_probe_package_list_backend)
    pkg_user=$(cap_probe_package_list_user "$pkg_backend")
    pkg_vc=$(cap_probe_package_versioncode "$pkg_backend" "$pkg_user")
    dump_backend=$(cap_probe_dump_backend)
    watch_backend=$(cap_probe_watch_backend)

    cat > "$tmp" <<EOF_CAP
# Analytics & Ads Disabler — auto-detected device capability profile
# Safe data only: this file is parsed as key/value text and is never sourced/eval'ed.
CAP_PROFILE_VERSION=$CAP_PROFILE_VERSION
DEVICE_SIGNATURE=$(cap_device_signature)
ROOT_MANAGER=$(cap_root_manager)
ACTION_PROBE_METHOD=runtime_missing_component
PM_DISABLE_BACKEND=$dis_b
PM_DISABLE_VERB=$dis_v
PM_DISABLE_HAS_USER=$dis_u
PM_ENABLE_BACKEND=$ena_b
PM_ENABLE_VERB=$ena_v
PM_ENABLE_HAS_USER=$ena_u
PM_DEFAULT_BACKEND=$def_b
PM_DEFAULT_VERB=$def_v
PM_DEFAULT_HAS_USER=$def_u
PM_STATE_DISABLED_BACKEND=$std_b
PM_STATE_DISABLED_VERB=$std_v
PM_STATE_DISABLED_HAS_USER=$std_u
PM_STATE_DISABLED_EXACT=$([ "$std_v" = "disable" ] && echo 1 || echo 0)
PM_DISABLE_USER_BACKEND=$dsu_b
PM_DISABLE_USER_VERB=$dsu_v
PM_DISABLE_USER_HAS_USER=$dsu_u
PM_DISABLE_UNTIL_BACKEND=$duu_b
PM_DISABLE_UNTIL_VERB=$duu_v
PM_DISABLE_UNTIL_HAS_USER=$duu_u
USER_LIST_BACKEND=$user_backend
PACKAGE_LIST_BACKEND=$pkg_backend
PACKAGE_LIST_HAS_USER=$pkg_user
PACKAGE_LIST_HAS_VERSIONCODE=$pkg_vc
PACKAGE_DUMP_BACKEND=$dump_backend
APP_WATCH_BACKEND=$watch_backend
EOF_CAP
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$CAPABILITIES_FILE"
    load_capabilities
}

cap_profile_valid() {
    [ -f "$CAPABILITIES_FILE" ] || return 1
    [ "$(cap_read CAP_PROFILE_VERSION 0)" = "$CAP_PROFILE_VERSION" ] || return 1
    [ "$(cap_read DEVICE_SIGNATURE missing)" = "$(cap_device_signature)" ] || return 1
    [ "$(cap_read PM_DISABLE_BACKEND none)" != "none" ] || return 1
    [ "$(cap_read PM_ENABLE_BACKEND none)" != "none" ] || return 1
    [ "$(cap_read PM_DEFAULT_BACKEND none)" != "none" ] || return 1
    [ "$(cap_read PACKAGE_LIST_BACKEND none)" != "none" ] || return 1
    [ "$(cap_read PACKAGE_DUMP_BACKEND none)" != "none" ] || return 1
    return 0
}

ensure_capability_profile() {
    cap_profile_valid && { load_capabilities; return 0; }
    probe_capabilities
}

load_capabilities() {
    CAP_PM_DISABLE_BACKEND=$(cap_read PM_DISABLE_BACKEND none)
    CAP_PM_DISABLE_VERB=$(cap_read PM_DISABLE_VERB none)
    CAP_PM_DISABLE_HAS_USER=$(cap_read PM_DISABLE_HAS_USER 0)
    CAP_PM_ENABLE_BACKEND=$(cap_read PM_ENABLE_BACKEND none)
    CAP_PM_ENABLE_VERB=$(cap_read PM_ENABLE_VERB none)
    CAP_PM_ENABLE_HAS_USER=$(cap_read PM_ENABLE_HAS_USER 0)
    CAP_PM_DEFAULT_BACKEND=$(cap_read PM_DEFAULT_BACKEND none)
    CAP_PM_DEFAULT_VERB=$(cap_read PM_DEFAULT_VERB none)
    CAP_PM_DEFAULT_HAS_USER=$(cap_read PM_DEFAULT_HAS_USER 0)
    CAP_PM_STATE_DISABLED_BACKEND=$(cap_read PM_STATE_DISABLED_BACKEND "$CAP_PM_DISABLE_BACKEND")
    CAP_PM_STATE_DISABLED_VERB=$(cap_read PM_STATE_DISABLED_VERB "$CAP_PM_DISABLE_VERB")
    CAP_PM_STATE_DISABLED_HAS_USER=$(cap_read PM_STATE_DISABLED_HAS_USER "$CAP_PM_DISABLE_HAS_USER")
    CAP_PM_STATE_DISABLED_EXACT=$(cap_read PM_STATE_DISABLED_EXACT 0)
    CAP_PM_DISABLE_USER_BACKEND=$(cap_read PM_DISABLE_USER_BACKEND "$CAP_PM_DISABLE_BACKEND")
    CAP_PM_DISABLE_USER_VERB=$(cap_read PM_DISABLE_USER_VERB "$CAP_PM_DISABLE_VERB")
    CAP_PM_DISABLE_USER_HAS_USER=$(cap_read PM_DISABLE_USER_HAS_USER "$CAP_PM_DISABLE_HAS_USER")
    CAP_PM_DISABLE_UNTIL_BACKEND=$(cap_read PM_DISABLE_UNTIL_BACKEND "$CAP_PM_DISABLE_BACKEND")
    CAP_PM_DISABLE_UNTIL_VERB=$(cap_read PM_DISABLE_UNTIL_VERB "$CAP_PM_DISABLE_VERB")
    CAP_PM_DISABLE_UNTIL_HAS_USER=$(cap_read PM_DISABLE_UNTIL_HAS_USER "$CAP_PM_DISABLE_HAS_USER")
    CAP_USER_LIST_BACKEND=$(cap_read USER_LIST_BACKEND pm)
    CAP_PACKAGE_LIST_BACKEND=$(cap_read PACKAGE_LIST_BACKEND pm)
    CAP_PACKAGE_LIST_HAS_USER=$(cap_read PACKAGE_LIST_HAS_USER 1)
    CAP_PACKAGE_LIST_HAS_VERSIONCODE=$(cap_read PACKAGE_LIST_HAS_VERSIONCODE 0)
    CAP_PACKAGE_DUMP_BACKEND=$(cap_read PACKAGE_DUMP_BACKEND dumpsys)
    CAP_APP_WATCH_BACKEND=$(cap_read APP_WATCH_BACKEND polling)
}

cap_exec_pm_action() {
    backend="$1"; verb="$2"; has_user="$3"; user="$4"; target="$5"
    [ "$backend" != "none" ] && [ "$verb" != "none" ] || return 127
    if [ "$has_user" = "1" ]; then
        case "$backend" in
            cmd) cmd package "$verb" --user "$user" "$target" ;;
            pm) pm "$verb" --user "$user" "$target" ;;
            *) return 127 ;;
        esac
    else
        [ "$user" = "0" ] || return 126
        case "$backend" in
            cmd) cmd package "$verb" "$target" ;;
            pm) pm "$verb" "$target" ;;
            *) return 127 ;;
        esac
    fi
}

cap_exec_pm_action_resilient() {
    backend="$1"; verb="$2"; has_user="$3"; user="$4"; target="$5"
    out=$(cap_exec_pm_action "$backend" "$verb" "$has_user" "$user" "$target" 2>&1)
    rc=$?

# Self-heal only on a transport/parser/backend failure, never on ordinary
# target-specific failures. This does NOT create a per-component fallback chain.
    if [ "$rc" -ne 0 ] && cap_runtime_hard_failure "$out" && [ "${CAP_REPROBED_ON_FAILURE:-0}" != "1" ]; then
        CAP_REPROBED_ON_FAILURE=1
        rm -f "$CAPABILITIES_FILE" 2>/dev/null
        probe_capabilities >/dev/null 2>&1
        return 125  # caller retries once using freshly loaded profile
    fi

    [ -n "$out" ] && printf '%s\n' "$out"
    return "$rc"
}

cap_disable_component() {
    user="$1"; target="$2"
    cap_exec_pm_action_resilient "$CAP_PM_DISABLE_BACKEND" "$CAP_PM_DISABLE_VERB" "$CAP_PM_DISABLE_HAS_USER" "$user" "$target"
    rc=$?
    if [ "$rc" -eq 125 ]; then
        cap_exec_pm_action "$CAP_PM_DISABLE_BACKEND" "$CAP_PM_DISABLE_VERB" "$CAP_PM_DISABLE_HAS_USER" "$user" "$target"
        return $?
    fi
    return "$rc"
}

cap_set_component_state() {
    user="$1"; target="$2"; state="$3"
    case "$state" in
        enabled) b="$CAP_PM_ENABLE_BACKEND"; v="$CAP_PM_ENABLE_VERB"; u="$CAP_PM_ENABLE_HAS_USER" ;;
        disabled) b="$CAP_PM_STATE_DISABLED_BACKEND"; v="$CAP_PM_STATE_DISABLED_VERB"; u="$CAP_PM_STATE_DISABLED_HAS_USER" ;;
        disabled-user) b="$CAP_PM_DISABLE_USER_BACKEND"; v="$CAP_PM_DISABLE_USER_VERB"; u="$CAP_PM_DISABLE_USER_HAS_USER" ;;
        disabled-until-used) b="$CAP_PM_DISABLE_UNTIL_BACKEND"; v="$CAP_PM_DISABLE_UNTIL_VERB"; u="$CAP_PM_DISABLE_UNTIL_HAS_USER" ;;
        default|*) b="$CAP_PM_DEFAULT_BACKEND"; v="$CAP_PM_DEFAULT_VERB"; u="$CAP_PM_DEFAULT_HAS_USER" ;;
    esac

    cap_exec_pm_action_resilient "$b" "$v" "$u" "$user" "$target"
    rc=$?
    if [ "$rc" -eq 125 ]; then
# Refresh local selection after the one-time re-probe.
        case "$state" in
            enabled) b="$CAP_PM_ENABLE_BACKEND"; v="$CAP_PM_ENABLE_VERB"; u="$CAP_PM_ENABLE_HAS_USER" ;;
            disabled) b="$CAP_PM_STATE_DISABLED_BACKEND"; v="$CAP_PM_STATE_DISABLED_VERB"; u="$CAP_PM_STATE_DISABLED_HAS_USER" ;;
            disabled-user) b="$CAP_PM_DISABLE_USER_BACKEND"; v="$CAP_PM_DISABLE_USER_VERB"; u="$CAP_PM_DISABLE_USER_HAS_USER" ;;
            disabled-until-used) b="$CAP_PM_DISABLE_UNTIL_BACKEND"; v="$CAP_PM_DISABLE_UNTIL_VERB"; u="$CAP_PM_DISABLE_UNTIL_HAS_USER" ;;
            default|*) b="$CAP_PM_DEFAULT_BACKEND"; v="$CAP_PM_DEFAULT_VERB"; u="$CAP_PM_DEFAULT_HAS_USER" ;;
        esac
        cap_exec_pm_action "$b" "$v" "$u" "$user" "$target"
        return $?
    fi
    return "$rc"
}

cap_list_users_raw() {
    case "$CAP_USER_LIST_BACKEND" in
        cmd_user) cmd user list 2>/dev/null ;;
        pm) pm list users 2>/dev/null ;;
        *) return 1 ;;
    esac
}

cap_list_packages_raw() {
    user="$1"; third="$2"; want_vc="$3"; filter="$4"
    [ "$CAP_PACKAGE_LIST_BACKEND" != "none" ] || return 1
    [ "$CAP_PACKAGE_LIST_HAS_USER" = "1" ] || [ "$user" = "0" ] || return 1

    third_arg=""
    [ "$third" = "1" ] && third_arg="-3"
    vc_arg=""
    [ "$want_vc" = "1" ] && [ "$CAP_PACKAGE_LIST_HAS_VERSIONCODE" = "1" ] && vc_arg="--show-versioncode"

    case "$CAP_PACKAGE_LIST_BACKEND:$CAP_PACKAGE_LIST_HAS_USER" in
        cmd:1) cmd package list packages $third_arg --user "$user" $vc_arg ${filter:+"$filter"} 2>/dev/null ;;
        cmd:0) cmd package list packages $third_arg $vc_arg ${filter:+"$filter"} 2>/dev/null ;;
        pm:1) pm list packages $third_arg --user "$user" $vc_arg ${filter:+"$filter"} 2>/dev/null ;;
        pm:0) pm list packages $third_arg $vc_arg ${filter:+"$filter"} 2>/dev/null ;;
        *) return 1 ;;
    esac
}

cap_package_dump() {
    pkg="$1"
    case "$CAP_PACKAGE_DUMP_BACKEND" in
        dumpsys) dumpsys package "$pkg" 2>/dev/null ;;
        cmd) cmd package dump "$pkg" 2>/dev/null ;;
        pm) pm dump "$pkg" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# Load an existing profile opportunistically. service/action will validate it before use.
[ -f "$CAPABILITIES_FILE" ] && load_capabilities
