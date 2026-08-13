#!/system/bin/sh
# Device capability profile for Analytics & Ads Disabler.
# Probes once, stores safe enum-like selections, and avoids per-operation fallback chains.

DATA_DIR="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
CAPABILITIES_FILE="${CAPABILITIES_FILE:-$DATA_DIR/capabilities.conf}"
CAP_PROFILE_VERSION=13

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

cap_backend_has_verb() {
    backend="$1"; verb="$2"
    help=$(cap_pkg_help "$backend") || return 1
    printf '%s\n' "$help" | grep -Eq "(^|[[:space:]])${verb}([[:space:]]|\[|$)"
}

# Android 7.0+ supports --user natively for every component-state verb, so this
# is true almost everywhere. It used to return success merely because cmd or pm
# existed, which made the "ROM without --user" handling dead code. Ask the
# backend's own help text first and only then fall back to the optimistic answer.
cap_backend_verb_has_user() {
    backend="$1"; verb="$2"
    help=$(cap_pkg_help "$backend") || return 1
    if printf '%s\n' "$help" | grep -q -- '--user'; then
        return 0
    fi
    # Some OEM builds ship a trimmed help text while still honouring --user.
    # Treat API level as the tie-breaker instead of assuming either way.
    api=$(cap_api_level)
    case "$api" in
        ''|*[!0-9]*) return 0 ;;
        *) [ "$api" -ge 24 ] && return 0 ;;
    esac
    return 1
}

# Runtime probe targets a deliberately impossible component name.
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

cap_shell_exec_available() {
    mode="$1"
    command -v su >/dev/null 2>&1 || return 1
    case "$mode" in
        su_uid2000) out=$(su 2000 -c 'id -u' 2>/dev/null) ;;
        su_shell) out=$(su shell -c 'id -u' 2>/dev/null) ;;
        *) return 1 ;;
    esac
    [ "$out" = "2000" ]
}

# A uid switch is not the same thing as Android's real shell SELinux domain.
# Some Android 16 / KernelSU combinations can reach Binder only from u:r:shell:s0.
# Try a real SELinux context transition when a runcon implementation is available.
cap_runcon_bin() {
    if [ -x /system/bin/runcon ]; then
        echo /system/bin/runcon
        return 0
    fi
    # Any root manager's BusyBox will do, not only KernelSU's.
    for _crb in "${AAD_BUSYBOX:-}" \
                /data/adb/magisk/busybox \
                /data/adb/ksu/bin/busybox \
                /data/adb/ap/bin/busybox; do
        if [ -n "$_crb" ] && [ -x "$_crb" ] && "$_crb" --list 2>/dev/null | grep -Fxq runcon; then
            echo "$_crb runcon"
            return 0
        fi
    done
    if command -v runcon >/dev/null 2>&1; then
        command -v runcon
        return 0
    fi
    return 1
}

cap_runcon_shell_available() {
    rb=$(cap_runcon_bin) || return 1
    # Transition probe only. No PackageManager state is touched here.
    case "$rb" in
        *" "*) out=$($rb u:r:shell:s0 /system/bin/sh -c 'id -u; cat /proc/self/attr/current 2>/dev/null' 2>/dev/null) ;;
        *) out=$("$rb" u:r:shell:s0 /system/bin/sh -c 'id -u; cat /proc/self/attr/current 2>/dev/null' 2>/dev/null) ;;
    esac
    printf '%s\n' "$out" | grep -q 'u:r:shell:s0'
}

# Android 16+ PackageManager blocks component-state mutations from the real
# shell UID (2000). Keep legacy su-shell candidates only on older APIs.
cap_api_level() {
    getprop ro.build.version.sdk 2>/dev/null | tr -cd '0-9'
}

cap_shell_uid_component_mutation_allowed() {
    api=$(cap_api_level)
    [ -z "$api" ] && return 0
    [ "$api" -lt 36 ]
}

# Execute PackageManager mutation in the SELinux shell domain while retaining uid 0.
# IMPORTANT: only the PM command string is executed in this domain; policy/state files
# remain handled by the caller in the KernelSU/root domain. Some OEM SELinux policies
# (including the tested OnePlus Android 16 build) deny direct execution of /system/bin/cmd
# after runcon, while allowing /system/bin/sh to transition and exec the PM command.
cap_runcon_pm_exec() {
    backend="$1"; verb="$2"; with_user="$3"; user="$4"; target="$5"
    cap_runcon_shell_available || return 127
    rb=$(cap_runcon_bin) || return 127

    case "$backend" in
        cmd) base="/system/bin/cmd package" ;;
        pm)  base="/system/bin/pm" ;;
        *) return 127 ;;
    esac

    if [ "$with_user" = "1" ]; then
        line="$base $verb --user $user '$target'"
    else
        line="$base $verb '$target'"
    fi

    # Defense in depth for BusyBox/ash and OEM SELinux combinations:
    # a caller may be iterating over a /data/adb file using "done < file".
    # Such loop descriptors are not stdin, so </dev/null alone does not close
    # them. Before switching to u:r:shell:s0, close only inherited descriptors
    # that point into this module's persistent/module directories. The parent
    # shell is untouched because this runs in a subshell.
    (
        data_prefix="${DATA_DIR:-/data/adb/analytics_ads_disabler}"
        module_prefix="${MODDIR:-/data/adb/modules/analytics_ads_disabler}"
        for fd_path in /proc/$$/fd/*; do
            fd=${fd_path##*/}
            case "$fd" in
                0|1|2|''|*[!0-9]*) continue ;;
            esac
            fd_target=$(readlink "$fd_path" 2>/dev/null)
            case "$fd_target" in
                "$data_prefix"/*|"$module_prefix"/*)
                    eval "exec ${fd}>&-" 2>/dev/null || true
                    ;;
            esac
        done

        case "$rb" in
            *" "*) $rb u:r:shell:s0 /system/bin/sh -c "exec $line" </dev/null ;;
            *) "$rb" u:r:shell:s0 /system/bin/sh -c "exec $line" </dev/null ;;
        esac
    )
}

# Execute package-manager shell commands either in the current context or,
# when a root manager/ROM breaks Binder calls from uid 0, through uid 2000.
# The latter is selected only after a runtime probe proves it can reach PMS.
cap_exec_command() {
    exec_mode="$1"; backend="$2"; verb="$3"; with_user="$4"; user="$5"; target="$6"
    [ "$backend" = "cmd" ] || [ "$backend" = "pm" ] || return 127

    if [ "$with_user" = "1" ]; then
        case "$backend" in
            cmd) line="cmd package $verb --user $user '$target'" ;;
            pm) line="pm $verb --user $user '$target'" ;;
        esac
    else
        case "$backend" in
            cmd) line="cmd package $verb '$target'" ;;
            pm) line="pm $verb '$target'" ;;
        esac
    fi

    case "$exec_mode" in
        direct)
            if [ "$with_user" = "1" ]; then
                case "$backend" in
                    cmd) cmd package "$verb" --user "$user" "$target" </dev/null ;;
                    pm) pm "$verb" --user "$user" "$target" </dev/null ;;
                esac
            else
                case "$backend" in
                    cmd) cmd package "$verb" "$target" </dev/null ;;
                    pm) pm "$verb" "$target" </dev/null ;;
                esac
            fi
            ;;
        su_uid2000)
            cap_shell_exec_available su_uid2000 || return 127
            su 2000 -c "$line" </dev/null
            ;;
        su_shell)
            cap_shell_exec_available su_shell || return 127
            su shell -c "$line" </dev/null
            ;;
        runcon_shell_uid0)
            cap_runcon_pm_exec "$backend" "$verb" "$with_user" "$user" "$target"
            ;;
        *) return 127 ;;
    esac
}

cap_exec_probe_target() {
    exec_mode="$1"; backend="$2"; verb="$3"; with_user="$4"
    target=$(cap_runtime_probe_target)
    cap_exec_command "$exec_mode" "$backend" "$verb" "$with_user" 0 "$target" 2>&1
}

cap_runtime_hard_failure() {
    printf '%s\n' "$1" | grep -Eiq \
        'Failed transaction|Transaction failed|binder[^[:alnum:]]*.*fail|DeadObjectException|RemoteException|Unknown command|not supported|unsupported operation'
}

cap_runtime_reached_pm() {
    out="$1"; rc="$2"

    # PackageManager подтвердил обработку команды и отклонил только несуществующий компонент
    printf '%s\n' "$out" | grep -Eiq \
        'does not exist|Unknown component|Unknown package|not found|not installed|new state:' && return 0

    cap_runtime_hard_failure "$out" && return 1

    [ "$rc" -eq 0 ] 2>/dev/null && return 0
    return 1
}

cap_probe_action_candidate() {
    exec_mode="$1"; backend="$2"; verb="$3"
    cap_backend_has_verb "$backend" "$verb" || return 1
    case "$exec_mode" in
        direct) ;;
        su_uid2000|su_shell) cap_shell_exec_available "$exec_mode" || return 1 ;;
        runcon_shell_uid0) cap_runcon_shell_available || return 1 ;;
        *) return 1 ;;
    esac

    if cap_backend_verb_has_user "$backend" "$verb"; then
        out=$(cap_exec_probe_target "$exec_mode" "$backend" "$verb" 1)
        rc=$?
        if cap_runtime_reached_pm "$out" "$rc"; then
            printf '%s|%s|1|%s\n' "$backend" "$verb" "$exec_mode"
            return 0
        fi
    fi

    out=$(cap_exec_probe_target "$exec_mode" "$backend" "$verb" 0)
    rc=$?
    if cap_runtime_reached_pm "$out" "$rc"; then
        printf '%s|%s|0|%s\n' "$backend" "$verb" "$exec_mode"
        return 0
    fi
    return 1
}

cap_pick_action() {
    key="$1"; shift
    # Prefer the normal root context. Only if it cannot reach PackageManager do
    # we try uid 2000 through the installed root manager. No ROM/model allowlist.
    action_exec_modes="direct"
    cap_shell_uid_component_mutation_allowed && action_exec_modes="direct su_uid2000 su_shell"
    for exec_mode in $action_exec_modes; do
        for verb in "$@"; do
            for backend in cmd pm; do
                spec=$(cap_probe_action_candidate "$exec_mode" "$backend" "$verb")
                if [ -n "$spec" ] && [ "$spec" != "none|none|0|direct" ]; then
                    printf '%s\n' "$spec"
                    return 0
                fi
            done
        done
    done

    # Last-resort profile preserves old-device behavior, but is explicitly
    # marked direct and will be re-probed after a hard Binder failure.
    for verb in "$@"; do
        if command -v cmd >/dev/null 2>&1; then
            printf 'cmd|%s|1|direct\n' "$verb"
            return 0
        elif command -v pm >/dev/null 2>&1; then
            printf 'pm|%s|1|direct\n' "$verb"
            return 0
        fi
    done

    printf 'none|none|0|direct\n'
    return 1
}

# Verify the actual component-state Binder path on a REAL component while preserving
# its explicit state. This avoids false positives from nonexistent-component probes on
# ROMs that short-circuit validation before the OEM PackageManager path is reached.
cap_verify_real_context() {
    user="$1"; target="$2"; preserve_state="$3"
    case "$preserve_state" in
        enabled) preserve_verb=enable ;;
        disabled) preserve_verb=disable ;;
        default|*) preserve_verb=default-state ;;
    esac

    verify_exec_modes="direct"
    cap_shell_uid_component_mutation_allowed && verify_exec_modes="direct su_uid2000 su_shell"
    for exec_mode in $verify_exec_modes; do
        [ "$exec_mode" = "direct" ] || cap_shell_exec_available "$exec_mode" || continue
        for backend in cmd pm; do
            # A selected backend must support every state operation the module needs.
            cap_backend_has_verb "$backend" disable || continue
            cap_backend_has_verb "$backend" enable || continue
            cap_backend_has_verb "$backend" default-state || continue
            cap_backend_has_verb "$backend" "$preserve_verb" || continue

            if cap_backend_verb_has_user "$backend" "$preserve_verb"; then
                out=$(cap_exec_command "$exec_mode" "$backend" "$preserve_verb" 1 "$user" "$target" 2>&1)
                rc=$?
                if [ "$rc" -eq 0 ] 2>/dev/null && ! cap_runtime_hard_failure "$out"; then
                    printf '%s|1|%s\n' "$backend" "$exec_mode"
                    return 0
                fi
            fi

            # Without --user this is safe only for user 0.
            if [ "$user" = "0" ]; then
                out=$(cap_exec_command "$exec_mode" "$backend" "$preserve_verb" 0 0 "$target" 2>&1)
                rc=$?
                if [ "$rc" -eq 0 ] 2>/dev/null && ! cap_runtime_hard_failure "$out"; then
                    printf '%s|0|%s\n' "$backend" "$exec_mode"
                    return 0
                fi
            fi
        done
    done
    return 1
}

# Rebuild the profile, then pin component-state operations to a context that has
# just succeeded against the real target. No model/ROM/root-manager allowlist.
cap_reprobe_from_real_target() {
    user="$1"; target="$2"; preserve_state="$3"
    verified=$(cap_verify_real_context "$user" "$target" "$preserve_state") || return 1
    IFS='|' read -r rb ru rx <<EOF_REAL
$verified
EOF_REAL

    probe_capabilities >/dev/null 2>&1
    [ -f "$CAPABILITIES_FILE" ] || return 1
    tmp="$CAPABILITIES_FILE.real.$$"
    awk -F= -v b="$rb" -v u="$ru" -v x="$rx" '
        /^ACTION_PROBE_METHOD=/ {$0="ACTION_PROBE_METHOD=real_component_state_preserving"}
        /^PM_(DISABLE|ENABLE|DEFAULT|STATE_DISABLED|DISABLE_USER|DISABLE_UNTIL)_BACKEND=/ {$0=$1 "=" b}
        /^PM_(DISABLE|ENABLE|DEFAULT|STATE_DISABLED|DISABLE_USER|DISABLE_UNTIL)_HAS_USER=/ {$0=$1 "=" u}
        /^PM_(DISABLE|ENABLE|DEFAULT|STATE_DISABLED|DISABLE_USER|DISABLE_UNTIL)_EXEC=/ {$0=$1 "=" x}
        {print}
    ' "$CAPABILITIES_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$CAPABILITIES_FILE" || return 1
    load_capabilities
    return 0
}

cap_probe_user_list() {
    if command -v cmd >/dev/null 2>&1; then
        out=$(cmd user list 2>/dev/null)
        printf '%s\n' "$out" | grep -Eq 'UserInfo\{|id=[0-9]|User [0-9]|Users:' && { echo cmd_user; return; }
    fi
    if command -v pm >/dev/null 2>&1; then
        out=$(pm list users 2>/dev/null)
        printf '%s\n' "$out" | grep -Eq 'UserInfo\{|id=[0-9]|User [0-9]|Users:' && { echo pm; return; }
    fi
    if command -v cmd >/dev/null 2>&1; then
        echo cmd_user
    elif command -v pm >/dev/null 2>&1; then
        echo pm
    else
        echo none
    fi
}

cap_probe_package_list_backend() {
    if command -v cmd >/dev/null 2>&1; then
        out=$(cmd package list packages 2>/dev/null | head -n5)
        printf '%s\n' "$out" | grep -q '^package:' && { echo cmd; return; }
    fi
    if command -v pm >/dev/null 2>&1; then
        out=$(pm list packages 2>/dev/null | head -n5)
        printf '%s\n' "$out" | grep -q '^package:' && { echo pm; return; }
    fi
    if command -v cmd >/dev/null 2>&1; then
        echo cmd
    elif command -v pm >/dev/null 2>&1; then
        echo pm
    else
        echo none
    fi
}

cap_probe_package_list_user() {
    backend="$1"
    case "$backend" in
        cmd) out=$(cmd package list packages --user 0 2>/dev/null | head -n5) ;;
        pm) out=$(pm list packages --user 0 2>/dev/null | head -n5) ;;
        *) echo 0; return ;;
    esac
    printf '%s\n' "$out" | grep -q '^package:' && echo 1 || echo 0
}

cap_probe_package_versioncode() {
    backend="$1"; userarg="$2"
    case "$backend:$userarg" in
        cmd:1) out=$(cmd package list packages --user 0 --show-versioncode 2>/dev/null | head -n5) ;;
        cmd:0) out=$(cmd package list packages --show-versioncode 2>/dev/null | head -n5) ;;
        pm:1) out=$(pm list packages --user 0 --show-versioncode 2>/dev/null | head -n5) ;;
        pm:0) out=$(pm list packages --show-versioncode 2>/dev/null | head -n5) ;;
        *) echo 0; return ;;
    esac
    printf '%s\n' "$out" | grep -q 'versionCode:' && echo 1 || echo 0
}

cap_probe_dump_backend() {
    if command -v dumpsys >/dev/null 2>&1; then
        echo dumpsys
        return
    fi
    if command -v cmd >/dev/null 2>&1; then
        echo cmd
        return
    fi
    if command -v pm >/dev/null 2>&1; then
        echo pm
        return
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

    # Preserve a backend that was VERIFIED on a real component across module upgrades,
    # but only while the exact device signature is unchanged. Runtime availability is
    # still checked every time before the cached path is used.
    old_sig=$(cap_read DEVICE_SIGNATURE missing)
    cur_sig=$(cap_device_signature)
    old_learn_b=none; old_learn_v=disable; old_learn_u=1; old_learn_x=direct; old_learn_t=numeric
    if [ "$old_sig" = "$cur_sig" ]; then
        old_learn_b=$(cap_read PM_LEARNED_DISABLE_BACKEND none)
        old_learn_v=$(cap_read PM_LEARNED_DISABLE_VERB disable)
        old_learn_u=$(cap_read PM_LEARNED_DISABLE_HAS_USER 1)
        old_learn_x=$(cap_read PM_LEARNED_DISABLE_EXEC direct)
        old_learn_t=$(cap_read PM_LEARNED_DISABLE_USER_TOKEN numeric)
    fi

    disable_spec=$(cap_pick_action block disable)
    enable_spec=$(cap_pick_action enable enable)
    default_spec=$(cap_pick_action default default-state)

    state_disabled_spec=$(cap_pick_action state_disabled disable)
    disable_user_spec=$(cap_pick_action disable_user disable)
    disable_until_spec=$(cap_pick_action disable_until disable)

    IFS='|' read -r dis_b dis_v dis_u dis_x <<EOF_SPEC
$disable_spec
EOF_SPEC
    IFS='|' read -r ena_b ena_v ena_u ena_x <<EOF_SPEC
$enable_spec
EOF_SPEC
    IFS='|' read -r def_b def_v def_u def_x <<EOF_SPEC
$default_spec
EOF_SPEC
    IFS='|' read -r std_b std_v std_u std_x <<EOF_SPEC
$state_disabled_spec
EOF_SPEC
    IFS='|' read -r dsu_b dsu_v dsu_u dsu_x <<EOF_SPEC
$disable_user_spec
EOF_SPEC
    IFS='|' read -r duu_b duu_v duu_u duu_x <<EOF_SPEC
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
ACTION_PROBE_METHOD=runtime_missing_component_then_real_on_failure
PM_DISABLE_BACKEND=$dis_b
PM_DISABLE_VERB=$dis_v
PM_DISABLE_HAS_USER=$dis_u
PM_DISABLE_EXEC=$dis_x
PM_LEARNED_DISABLE_BACKEND=$old_learn_b
PM_LEARNED_DISABLE_VERB=$old_learn_v
PM_LEARNED_DISABLE_HAS_USER=$old_learn_u
PM_LEARNED_DISABLE_EXEC=$old_learn_x
PM_LEARNED_DISABLE_USER_TOKEN=$old_learn_t
PM_LEARNED_DISABLE_VERIFIED=$([ "$old_learn_b" != "none" ] && echo 1 || echo 0)
PM_ENABLE_BACKEND=$ena_b
PM_ENABLE_VERB=$ena_v
PM_ENABLE_HAS_USER=$ena_u
PM_ENABLE_EXEC=$ena_x
PM_DEFAULT_BACKEND=$def_b
PM_DEFAULT_VERB=$def_v
PM_DEFAULT_HAS_USER=$def_u
PM_DEFAULT_EXEC=$def_x
PM_STATE_DISABLED_BACKEND=$std_b
PM_STATE_DISABLED_VERB=$std_v
PM_STATE_DISABLED_HAS_USER=$std_u
PM_STATE_DISABLED_EXEC=$std_x
PM_STATE_DISABLED_EXACT=$([ "$std_v" = "disable" ] && echo 1 || echo 0)
PM_DISABLE_USER_BACKEND=$dsu_b
PM_DISABLE_USER_VERB=$dsu_v
PM_DISABLE_USER_HAS_USER=$dsu_u
PM_DISABLE_USER_EXEC=$dsu_x
PM_DISABLE_UNTIL_BACKEND=$duu_b
PM_DISABLE_UNTIL_VERB=$duu_v
PM_DISABLE_UNTIL_HAS_USER=$duu_u
PM_DISABLE_UNTIL_EXEC=$duu_x
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
    CAP_PM_DISABLE_BACKEND=$(cap_read PM_DISABLE_BACKEND cmd)
    CAP_PM_DISABLE_VERB=$(cap_read PM_DISABLE_VERB disable)
    CAP_PM_DISABLE_HAS_USER=$(cap_read PM_DISABLE_HAS_USER 1)
    CAP_PM_DISABLE_EXEC=$(cap_read PM_DISABLE_EXEC direct)
    CAP_PM_LEARNED_DISABLE_BACKEND=$(cap_read PM_LEARNED_DISABLE_BACKEND none)
    CAP_PM_LEARNED_DISABLE_VERB=$(cap_read PM_LEARNED_DISABLE_VERB disable)
    CAP_PM_LEARNED_DISABLE_HAS_USER=$(cap_read PM_LEARNED_DISABLE_HAS_USER 1)
    CAP_PM_LEARNED_DISABLE_EXEC=$(cap_read PM_LEARNED_DISABLE_EXEC direct)
    CAP_PM_LEARNED_DISABLE_USER_TOKEN=$(cap_read PM_LEARNED_DISABLE_USER_TOKEN numeric)
    CAP_PM_LEARNED_DISABLE_VERIFIED=$(cap_read PM_LEARNED_DISABLE_VERIFIED 0)
    CAP_PM_ENABLE_BACKEND=$(cap_read PM_ENABLE_BACKEND cmd)
    CAP_PM_ENABLE_VERB=$(cap_read PM_ENABLE_VERB enable)
    CAP_PM_ENABLE_HAS_USER=$(cap_read PM_ENABLE_HAS_USER 1)
    CAP_PM_ENABLE_EXEC=$(cap_read PM_ENABLE_EXEC direct)
    CAP_PM_DEFAULT_BACKEND=$(cap_read PM_DEFAULT_BACKEND cmd)
    CAP_PM_DEFAULT_VERB=$(cap_read PM_DEFAULT_VERB default-state)
    CAP_PM_DEFAULT_HAS_USER=$(cap_read PM_DEFAULT_HAS_USER 1)
    CAP_PM_DEFAULT_EXEC=$(cap_read PM_DEFAULT_EXEC direct)
    CAP_PM_STATE_DISABLED_BACKEND=$(cap_read PM_STATE_DISABLED_BACKEND "$CAP_PM_DISABLE_BACKEND")
    CAP_PM_STATE_DISABLED_VERB=$(cap_read PM_STATE_DISABLED_VERB "$CAP_PM_DISABLE_VERB")
    CAP_PM_STATE_DISABLED_HAS_USER=$(cap_read PM_STATE_DISABLED_HAS_USER "$CAP_PM_DISABLE_HAS_USER")
    CAP_PM_STATE_DISABLED_EXEC=$(cap_read PM_STATE_DISABLED_EXEC "$CAP_PM_DISABLE_EXEC")
    CAP_PM_STATE_DISABLED_EXACT=$(cap_read PM_STATE_DISABLED_EXACT 0)
    CAP_PM_DISABLE_USER_BACKEND=$(cap_read PM_DISABLE_USER_BACKEND "$CAP_PM_DISABLE_BACKEND")
    CAP_PM_DISABLE_USER_VERB=$(cap_read PM_DISABLE_USER_VERB "$CAP_PM_DISABLE_VERB")
    CAP_PM_DISABLE_USER_HAS_USER=$(cap_read PM_DISABLE_USER_HAS_USER "$CAP_PM_DISABLE_HAS_USER")
    CAP_PM_DISABLE_USER_EXEC=$(cap_read PM_DISABLE_USER_EXEC "$CAP_PM_DISABLE_EXEC")
    CAP_PM_DISABLE_UNTIL_BACKEND=$(cap_read PM_DISABLE_UNTIL_BACKEND "$CAP_PM_DISABLE_BACKEND")
    CAP_PM_DISABLE_UNTIL_VERB=$(cap_read PM_DISABLE_UNTIL_VERB "$CAP_PM_DISABLE_VERB")
    CAP_PM_DISABLE_UNTIL_HAS_USER=$(cap_read PM_DISABLE_UNTIL_HAS_USER "$CAP_PM_DISABLE_HAS_USER")
    CAP_PM_DISABLE_UNTIL_EXEC=$(cap_read PM_DISABLE_UNTIL_EXEC "$CAP_PM_DISABLE_EXEC")
    CAP_USER_LIST_BACKEND=$(cap_read USER_LIST_BACKEND cmd_user)
    CAP_PACKAGE_LIST_BACKEND=$(cap_read PACKAGE_LIST_BACKEND cmd)
    CAP_PACKAGE_LIST_HAS_USER=$(cap_read PACKAGE_LIST_HAS_USER 1)
    CAP_PACKAGE_LIST_HAS_VERSIONCODE=$(cap_read PACKAGE_LIST_HAS_VERSIONCODE 0)
    CAP_PACKAGE_DUMP_BACKEND=$(cap_read PACKAGE_DUMP_BACKEND dumpsys)
    CAP_APP_WATCH_BACKEND=$(cap_read APP_WATCH_BACKEND inotifyd)
}

cap_exec_pm_action() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user="$5"; target="$6"
    [ "$backend" != "none" ] && [ "$verb" != "none" ] || return 127
    if [ "$has_user" != "1" ] && [ "$user" != "0" ]; then
        return 126
    fi
    cap_exec_command "$exec_mode" "$backend" "$verb" "$has_user" "$user" "$target"
}

cap_action_ok() {
    rc="$1"; out="$2"
    [ "$rc" -eq 0 ] 2>/dev/null || return 1
    printf '%s\n' "$out" | grep -Eiq 'Error:|Exception|SecurityException|Unknown|Failed transaction|Transaction failed' && return 1
    return 0
}

cap_action_text() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user="$5"; target="$6"
    prefix=""
    case "$exec_mode" in
        su_uid2000) prefix="su 2000 -c: " ;;
        su_shell) prefix="su shell -c: " ;;
        runcon_shell_uid0) prefix="runcon u:r:shell:s0: " ;;
    esac
    if [ "$backend" = "cmd" ]; then base="cmd package $verb"; else base="pm $verb"; fi
    [ "$has_user" = "1" ] && base="$base --user $user"
    printf '%s%s %s\n' "$prefix" "$base" "$target"
}

# Execute one pre-probed action. A hard Binder failure invalidates the profile,
# triggers one fresh runtime probe (which can switch execution identity), then retries.
cap_run_profiled_action() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user="$5"; target="$6"; preserve_state="$7"
    cmd_text=$(cap_action_text "$backend" "$verb" "$has_user" "$exec_mode" "$user" "$target")
    out=$(cap_exec_pm_action "$backend" "$verb" "$has_user" "$exec_mode" "$user" "$target" 2>&1)
    rc=$?
    command -v log_cmd_exec >/dev/null 2>&1 && log_cmd_exec "$cmd_text" "$out" "$rc"
    cap_action_ok "$rc" "$out" && return 0

    if cap_runtime_hard_failure "$out" && [ "${CAP_REPROBED_ON_FAILURE:-0}" != "1" ]; then
        CAP_REPROBED_ON_FAILURE=1
        rm -f "$CAPABILITIES_FILE" 2>/dev/null
        if [ -n "$preserve_state" ] && cap_reprobe_from_real_target "$user" "$target" "$preserve_state"; then
            return 125
        fi
        probe_capabilities >/dev/null 2>&1
        return 125
    fi
    return 1
}

cap_current_user_id() {
    if command -v am >/dev/null 2>&1; then
        v=$(am get-current-user 2>/dev/null | tr -cd '0-9')
        [ -n "$v" ] && { printf '%s\n' "$v"; return; }
    fi
    if command -v cmd >/dev/null 2>&1; then
        v=$(cmd activity get-current-user 2>/dev/null | tr -cd '0-9')
        [ -n "$v" ] && { printf '%s\n' "$v"; return; }
    fi
    echo 0
}

# Verify the postcondition, not merely exit code. OEM shells sometimes return 0
# even when PackageManager did not persist the requested component state.
cap_component_is_disabled() {
    user="$1"; target="$2"
    if command -v get_component_override_state >/dev/null 2>&1; then
        st=$(get_component_override_state "$user" "$target" 2>/dev/null)
        [ "$st" = "disabled" ] && return 0
    fi
    return 1
}

cap_remember_disable_spec() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user_token="$5"
    [ -f "$CAPABILITIES_FILE" ] || return 0
    tmp="$CAPABILITIES_FILE.learn.$$"
    awk -F= -v b="$backend" -v v="$verb" -v u="$has_user" -v x="$exec_mode" -v t="$user_token" '
        BEGIN{hb=hv=hu=hx=ht=hver=0}
        /^PM_LEARNED_DISABLE_BACKEND=/{print "PM_LEARNED_DISABLE_BACKEND=" b; hb=1; next}
        /^PM_LEARNED_DISABLE_VERB=/{print "PM_LEARNED_DISABLE_VERB=" v; hv=1; next}
        /^PM_LEARNED_DISABLE_HAS_USER=/{print "PM_LEARNED_DISABLE_HAS_USER=" u; hu=1; next}
        /^PM_LEARNED_DISABLE_EXEC=/{print "PM_LEARNED_DISABLE_EXEC=" x; hx=1; next}
        /^PM_LEARNED_DISABLE_USER_TOKEN=/{print "PM_LEARNED_DISABLE_USER_TOKEN=" t; ht=1; next}
        /^PM_LEARNED_DISABLE_VERIFIED=/{print "PM_LEARNED_DISABLE_VERIFIED=1"; hver=1; next}
        {print}
        END{
            if(!hb) print "PM_LEARNED_DISABLE_BACKEND=" b
            if(!hv) print "PM_LEARNED_DISABLE_VERB=" v
            if(!hu) print "PM_LEARNED_DISABLE_HAS_USER=" u
            if(!hx) print "PM_LEARNED_DISABLE_EXEC=" x
            if(!ht) print "PM_LEARNED_DISABLE_USER_TOKEN=" t
            if(!hver) print "PM_LEARNED_DISABLE_VERIFIED=1"
        }
    ' "$CAPABILITIES_FILE" > "$tmp" && mv "$tmp" "$CAPABILITIES_FILE"
    CAP_PM_LEARNED_DISABLE_BACKEND="$backend"
    CAP_PM_LEARNED_DISABLE_VERB="$verb"
    CAP_PM_LEARNED_DISABLE_HAS_USER="$has_user"
    CAP_PM_LEARNED_DISABLE_EXEC="$exec_mode"
    CAP_PM_LEARNED_DISABLE_USER_TOKEN="$user_token"
    CAP_PM_LEARNED_DISABLE_VERIFIED=1
}

# Read a component override state without depending on common.sh. Used by the
# installer to find an already-disabled, therefore safe/idempotent, write target.
cap_query_component_override_state() {
    user="$1"; comp="$2"
    pkg=${comp%%/*}; cls=${comp#*/}
    case "$cls" in .*) full_cls="$pkg$cls" ;; *) full_cls="$cls" ;; esac
    if command -v dumpsys >/dev/null 2>&1; then
        dump=$(dumpsys package "$pkg" 2>/dev/null)
    elif command -v cmd >/dev/null 2>&1; then
        dump=$(cmd package dump "$pkg" 2>/dev/null)
    else
        dump=$(pm dump "$pkg" 2>/dev/null)
    fi
    state=$(printf '%s\n' "$dump" | awk -v uid="$user" -v full="$full_cls" -v short="$cls" '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/, "", s); return s}
        /^[ \t]*User [0-9]+:/ {
            line=$0; gsub(/^[ \t]*/, "", line)
            if (line ~ ("^User " uid ":")) {inuser=1; sec=""; next}
            if (inuser) exit
        }
        !inuser {next}
        /^[ \t]*enabledComponents:/ {sec="enabled"; next}
        /^[ \t]*disabledComponents:/ {sec="disabled"; next}
        /^[ \t]*[A-Za-z][A-Za-z0-9_-]*:/ {sec=""}
        sec!="" {x=trim($0); if (x==full || x==short) {print sec; exit}}
    ')
    [ -n "$state" ] && printf '%s\n' "$state" || printf 'default\n'
}

cap_find_safe_disabled_probe_target() {
    list="$DATA_DIR/disabled_components.list"
    [ -s "$list" ] || return 1
    # Prefer records previously managed by this module. Verify current state before
    # using them; stale records are skipped and never written to.
    while IFS='|' read -r user comp cat; do
        case "$user" in ''|*[!0-9]*) continue ;; esac
        [ -n "$comp" ] || continue
        st=$(cap_query_component_override_state "$user" "$comp" 2>/dev/null)
        if [ "$st" = "disabled" ]; then
            printf '%s|%s\n' "$user" "$comp"
            return 0
        fi
    done < "$list"
    return 1
}

cap_install_try_idempotent_candidate() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user="$5"; target="$6"; token="$7"
    # The target MUST already be disabled. This probe only re-applies the same state.
    [ "$(cap_query_component_override_state "$user" "$target" 2>/dev/null)" = "disabled" ] || return 1
    actual_user="$user"; [ "$token" = "current" ] && actual_user=current
    cmd_text=$(cap_action_text "$backend" "$verb" "$has_user" "$exec_mode" "$actual_user" "$target")
    out=$(cap_exec_command "$exec_mode" "$backend" "$verb" "$has_user" "$actual_user" "$target" 2>&1)
    rc=$?
    command -v log_cmd_exec >/dev/null 2>&1 && log_cmd_exec "$cmd_text" "$out" "$rc"
    command -v aad_package_dump_invalidate >/dev/null 2>&1 && aad_package_dump_invalidate "${target%%/*}"
    cap_action_ok "$rc" "$out" || return 1
    [ "$(cap_query_component_override_state "$user" "$target" 2>/dev/null)" = "disabled" ] || return 1
    cap_remember_disable_spec "$backend" "$verb" "$has_user" "$exec_mode" "$token"
    return 0
}

cap_install_verify_disable_backend() {
    safe=$(cap_find_safe_disabled_probe_target) || return 2
    user=${safe%%|*}; target=${safe#*|}
    CAP_INSTALL_PROBE_TARGET="u${user}:$target"

    # Existing verified cache first (upgrade path).
    if [ "${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}" = "1" ] && [ "${CAP_PM_LEARNED_DISABLE_BACKEND:-none}" != "none" ]; then
        cap_install_try_idempotent_candidate "$CAP_PM_LEARNED_DISABLE_BACKEND" "$CAP_PM_LEARNED_DISABLE_VERB" \
            "$CAP_PM_LEARNED_DISABLE_HAS_USER" "$CAP_PM_LEARNED_DISABLE_EXEC" "$user" "$target" \
            "${CAP_PM_LEARNED_DISABLE_USER_TOKEN:-numeric}" && return 0
    fi

    # Short production probe: baseline first, then materially different execution
    # domains. Full legacy cascade remains available at runtime on failure.
    command -v cmd >/dev/null 2>&1 && {
        cap_install_try_idempotent_candidate cmd disable 1 direct "$user" "$target" numeric && return 0
    }
    command -v pm >/dev/null 2>&1 && {
        cap_install_try_idempotent_candidate pm disable 1 direct "$user" "$target" numeric && return 0
    }
    if cap_shell_uid_component_mutation_allowed; then
        for x in su_uid2000 su_shell; do
            cap_shell_exec_available "$x" || continue
            command -v cmd >/dev/null 2>&1 && cap_install_try_idempotent_candidate cmd disable 1 "$x" "$user" "$target" numeric && return 0
        done
    fi
    if cap_runcon_shell_available; then
        command -v cmd >/dev/null 2>&1 && cap_install_try_idempotent_candidate cmd disable 1 runcon_shell_uid0 "$user" "$target" numeric && return 0
        command -v pm >/dev/null 2>&1 && cap_install_try_idempotent_candidate pm disable 1 runcon_shell_uid0 "$user" "$target" numeric && return 0
    fi
    return 1
}

cap_exec_disable_candidate() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user="$5"; target="$6"; user_token="$7"
    [ "$backend" = "cmd" ] || [ "$backend" = "pm" ] || return 1
    command -v "$backend" >/dev/null 2>&1 || return 1
    case "$exec_mode" in
        direct) ;;
        su_uid2000|su_shell) cap_shell_exec_available "$exec_mode" || return 1 ;;
        runcon_shell_uid0) cap_runcon_shell_available || return 1 ;;
        *) return 1 ;;
    esac

    # no-user forms are only safe for Android user 0.
    [ "$has_user" = "1" ] || [ "$user" = "0" ] || return 1

    actual_user="$user"
    [ "$user_token" = "current" ] && actual_user="current"

    if [ "$has_user" = "1" ]; then
        case "$backend" in
            cmd) line="cmd package $verb --user $actual_user '$target'" ;;
            pm) line="pm $verb --user $actual_user '$target'" ;;
        esac
    else
        case "$backend" in
            cmd) line="cmd package $verb '$target'" ;;
            pm) line="pm $verb '$target'" ;;
        esac
    fi

    case "$exec_mode" in
        direct)
            if [ "$has_user" = "1" ]; then
                case "$backend" in
                    cmd) out=$(cmd package "$verb" --user "$actual_user" "$target" </dev/null 2>&1); rc=$? ;;
                    pm) out=$(pm "$verb" --user "$actual_user" "$target" </dev/null 2>&1); rc=$? ;;
                esac
            else
                case "$backend" in
                    cmd) out=$(cmd package "$verb" "$target" </dev/null 2>&1); rc=$? ;;
                    pm) out=$(pm "$verb" "$target" </dev/null 2>&1); rc=$? ;;
                esac
            fi
            ;;
        su_uid2000) out=$(su 2000 -c "$line" </dev/null 2>&1); rc=$? ;;
        su_shell) out=$(su shell -c "$line" </dev/null 2>&1); rc=$? ;;
        runcon_shell_uid0)
            out=$(cap_runcon_pm_exec "$backend" "$verb" "$has_user" "$actual_user" "$target" 2>&1); rc=$?
            ;;
        *) return 1 ;;
    esac

    cmd_text=$(cap_action_text "$backend" "$verb" "$has_user" "$exec_mode" "$actual_user" "$target")
    command -v log_cmd_exec >/dev/null 2>&1 && log_cmd_exec "$cmd_text" "$out" "$rc"
    # The package dump cache must be dropped before the postcondition check,
    # otherwise verification would read the pre-write snapshot.
    command -v aad_package_dump_invalidate >/dev/null 2>&1 && aad_package_dump_invalidate "${target%%/*}"
    cap_action_ok "$rc" "$out" || return 1
    cap_component_is_disabled "$user" "$target" || return 1
    cap_remember_disable_spec "$backend" "$verb" "$has_user" "$exec_mode" "$user_token"
    return 0
}

cap_disable_component() {
    user="$1"; target="$2"; preserve_state="$3"

    # 0. Learned fast path: only a path that previously changed a REAL component
    # and passed post-state verification is allowed here.
    if [ "${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}" = "1" ] && [ -n "${CAP_PM_LEARNED_DISABLE_BACKEND:-}" ] && [ "$CAP_PM_LEARNED_DISABLE_BACKEND" != "none" ]; then
        cap_exec_disable_candidate "$CAP_PM_LEARNED_DISABLE_BACKEND" "$CAP_PM_LEARNED_DISABLE_VERB" \
            "$CAP_PM_LEARNED_DISABLE_HAS_USER" "$CAP_PM_LEARNED_DISABLE_EXEC" "$user" "$target" \
            "${CAP_PM_LEARNED_DISABLE_USER_TOKEN:-numeric}" && return 0
    fi

    # 1. Original v4.3.0 behavior first. This is intentionally retained as the
    # compatibility baseline because it is known to work on existing devices.
    cap_exec_disable_candidate "$CAP_PM_DISABLE_BACKEND" "$CAP_PM_DISABLE_VERB" \
        "$CAP_PM_DISABLE_HAS_USER" direct "$user" "$target" numeric && return 0

    if command -v cmd >/dev/null 2>&1; then
        cap_exec_disable_candidate cmd disable      1 direct "$user" "$target" numeric && return 0
        cap_exec_disable_candidate cmd disable-user 1 direct "$user" "$target" numeric && return 0
        [ "$user" = "0" ] && cap_exec_disable_candidate cmd disable 0 direct "$user" "$target" numeric && return 0
    fi
    if command -v pm >/dev/null 2>&1; then
        cap_exec_disable_candidate pm disable      1 direct "$user" "$target" numeric && return 0
        cap_exec_disable_candidate pm disable-user 1 direct "$user" "$target" numeric && return 0
        [ "$user" = "0" ] && cap_exec_disable_candidate pm disable 0 direct "$user" "$target" numeric && return 0
    fi

    # 2. Compatibility extension A: some OEMs behave differently when USER_CURRENT
    # is translated inside PackageManagerShellCommand. Only use it if this target
    # Android user is actually the current foreground user.
    current_user=$(cap_current_user_id)
    if [ "$user" = "$current_user" ]; then
        command -v cmd >/dev/null 2>&1 && {
            cap_exec_disable_candidate cmd disable      1 direct "$user" "$target" current && return 0
            cap_exec_disable_candidate cmd disable-user 1 direct "$user" "$target" current && return 0
        }
        command -v pm >/dev/null 2>&1 && {
            cap_exec_disable_candidate pm disable      1 direct "$user" "$target" current && return 0
            cap_exec_disable_candidate pm disable-user 1 direct "$user" "$target" current && return 0
        }
    fi

    # 3. Legacy compatibility only (< Android 16): real shell UID 2000 may be
    # useful on older releases, but Android 16+ rejects component-state writes
    # from SHELL_UID in PackageManagerService.
    for exec_mode in su_uid2000 su_shell; do
        cap_shell_uid_component_mutation_allowed || break
        cap_shell_exec_available "$exec_mode" || continue
        if command -v cmd >/dev/null 2>&1; then
            cap_exec_disable_candidate cmd disable      1 "$exec_mode" "$user" "$target" numeric && return 0
            cap_exec_disable_candidate cmd disable-user 1 "$exec_mode" "$user" "$target" numeric && return 0
            [ "$user" = "0" ] && cap_exec_disable_candidate cmd disable 0 "$exec_mode" "$user" "$target" numeric && return 0
        fi
        if command -v pm >/dev/null 2>&1; then
            cap_exec_disable_candidate pm disable      1 "$exec_mode" "$user" "$target" numeric && return 0
            cap_exec_disable_candidate pm disable-user 1 "$exec_mode" "$user" "$target" numeric && return 0
            [ "$user" = "0" ] && cap_exec_disable_candidate pm disable 0 "$exec_mode" "$user" "$target" numeric && return 0
        fi
        if [ "$user" = "$current_user" ]; then
            command -v cmd >/dev/null 2>&1 && {
                cap_exec_disable_candidate cmd disable      1 "$exec_mode" "$user" "$target" current && return 0
                cap_exec_disable_candidate cmd disable-user 1 "$exec_mode" "$user" "$target" current && return 0
            }
            command -v pm >/dev/null 2>&1 && {
                cap_exec_disable_candidate pm disable      1 "$exec_mode" "$user" "$target" current && return 0
                cap_exec_disable_candidate pm disable-user 1 "$exec_mode" "$user" "$target" current && return 0
            }
        fi
    done

    # 4. Compatibility extension C: actual Android shell SELinux domain.
    # This differs materially from `su 2000`: KernelSU can change uid to 2000
    # while retaining a KSU/root SELinux domain. Only attempt when runcon proves
    # that u:r:shell:s0 was really entered.
    if cap_runcon_shell_available; then
        if command -v cmd >/dev/null 2>&1; then
            cap_exec_disable_candidate cmd disable      1 runcon_shell_uid0 "$user" "$target" numeric && return 0
            cap_exec_disable_candidate cmd disable-user 1 runcon_shell_uid0 "$user" "$target" numeric && return 0
            [ "$user" = "0" ] && cap_exec_disable_candidate cmd disable 0 runcon_shell_uid0 "$user" "$target" numeric && return 0
        fi
        if command -v pm >/dev/null 2>&1; then
            cap_exec_disable_candidate pm disable      1 runcon_shell_uid0 "$user" "$target" numeric && return 0
            cap_exec_disable_candidate pm disable-user 1 runcon_shell_uid0 "$user" "$target" numeric && return 0
            [ "$user" = "0" ] && cap_exec_disable_candidate pm disable 0 runcon_shell_uid0 "$user" "$target" numeric && return 0
        fi
    fi

    return 1
}

cap_component_state_matches() {
    user="$1"; target="$2"; expected="$3"
    command -v get_component_override_state >/dev/null 2>&1 || return 1
    actual=$(get_component_override_state "$user" "$target" 2>/dev/null)
    [ "$actual" = "$expected" ]
}

# Execute a state-changing PackageManager verb through a specific transport and
# verify the resulting override state. Unlike disable learning, this helper does
# not alter the learned disable backend; it is used by restore/whitelist rollback.
cap_exec_state_candidate() {
    backend="$1"; verb="$2"; has_user="$3"; exec_mode="$4"; user="$5"; target="$6"; expected="$7"; user_token="${8:-numeric}"
    [ -n "$backend" ] && [ "$backend" != "none" ] || return 1

    case "$exec_mode" in
        direct) ;;
        su_uid2000|su_shell) cap_shell_exec_available "$exec_mode" || return 1 ;;
        runcon_shell_uid0) cap_runcon_shell_available || return 1 ;;
        *) return 1 ;;
    esac

    actual_user="$user"
    if [ "$has_user" = "1" ] && [ "$user_token" = "current" ]; then
        [ "$user" = "$(cap_current_user_id)" ] || return 1
        actual_user="current"
    fi
    [ "$has_user" = "1" ] || [ "$user" = "0" ] || return 1

    if [ "$has_user" = "1" ]; then
        line="$backend package $verb --user $actual_user $target"
        [ "$backend" = "pm" ] && line="pm $verb --user $actual_user $target"
    else
        line="$backend package $verb $target"
        [ "$backend" = "pm" ] && line="pm $verb $target"
    fi

    out=""; rc=127
    case "$exec_mode" in
        direct)
            if [ "$has_user" = "1" ]; then
                case "$backend" in
                    cmd) out=$(cmd package "$verb" --user "$actual_user" "$target" </dev/null 2>&1); rc=$? ;;
                    pm) out=$(pm "$verb" --user "$actual_user" "$target" </dev/null 2>&1); rc=$? ;;
                esac
            else
                case "$backend" in
                    cmd) out=$(cmd package "$verb" "$target" </dev/null 2>&1); rc=$? ;;
                    pm) out=$(pm "$verb" "$target" </dev/null 2>&1); rc=$? ;;
                esac
            fi
            ;;
        su_uid2000) out=$(su 2000 -c "$line" </dev/null 2>&1); rc=$? ;;
        su_shell) out=$(su shell -c "$line" </dev/null 2>&1); rc=$? ;;
        runcon_shell_uid0)
            out=$(cap_runcon_pm_exec "$backend" "$verb" "$has_user" "$actual_user" "$target" 2>&1); rc=$?
            ;;
    esac

    cmd_text=$(cap_action_text "$backend" "$verb" "$has_user" "$exec_mode" "$actual_user" "$target")
    command -v log_cmd_exec >/dev/null 2>&1 && log_cmd_exec "$cmd_text" "$out" "$rc"
    command -v aad_package_dump_invalidate >/dev/null 2>&1 && aad_package_dump_invalidate "${target%%/*}"
    cap_action_ok "$rc" "$out" || return 1
    cap_component_state_matches "$user" "$target" "$expected" || return 1
    return 0
}

cap_set_component_state() {
    user="$1"; target="$2"; state="$3"
    [ -z "$state" ] && state="default"
    case "$state" in
        enabled) verb="enable" ;;
        disabled) verb="disable" ;;
        default|*) state="default"; verb="default-state" ;;
    esac

    # First reuse the already verified write transport. The learned backend is a
    # transport decision (cmd/pm + execution context), while policy decides which
    # state verb is appropriate. This keeps whitelist/uninstall restore as robust
    # as disabling on OEMs that reject direct Binder writes.
    if [ "${CAP_PM_LEARNED_DISABLE_VERIFIED:-0}" = "1" ] && [ -n "${CAP_PM_LEARNED_DISABLE_BACKEND:-}" ] && [ "$CAP_PM_LEARNED_DISABLE_BACKEND" != "none" ]; then
        cap_exec_state_candidate "$CAP_PM_LEARNED_DISABLE_BACKEND" "$verb" \
            "${CAP_PM_LEARNED_DISABLE_HAS_USER:-1}" "${CAP_PM_LEARNED_DISABLE_EXEC:-direct}" \
            "$user" "$target" "$state" "${CAP_PM_LEARNED_DISABLE_USER_TOKEN:-numeric}" && return 0
        command -v log >/dev/null 2>&1 && log "WRITE-TRANSPORT learned backend failed for restore state=$state u$user: $target; trying restore cascade."
    fi

    # Existing probed state profile remains the compatibility baseline.
    case "$state" in
        enabled) b="$CAP_PM_ENABLE_BACKEND"; v="$CAP_PM_ENABLE_VERB"; u="$CAP_PM_ENABLE_HAS_USER"; x="$CAP_PM_ENABLE_EXEC" ;;
        disabled) b="$CAP_PM_STATE_DISABLED_BACKEND"; v="$CAP_PM_STATE_DISABLED_VERB"; u="$CAP_PM_STATE_DISABLED_HAS_USER"; x="$CAP_PM_STATE_DISABLED_EXEC" ;;
        default) b="$CAP_PM_DEFAULT_BACKEND"; v="$CAP_PM_DEFAULT_VERB"; u="$CAP_PM_DEFAULT_HAS_USER"; x="$CAP_PM_DEFAULT_EXEC" ;;
    esac
    cap_exec_state_candidate "$b" "$v" "$u" "$x" "$user" "$target" "$state" numeric && return 0

    # Restore cascade: same safe transports as disable, but with the verb needed
    # to reproduce the exact original override state.
    current_user=$(cap_current_user_id)
    restore_exec_modes="direct runcon_shell_uid0"
    cap_shell_uid_component_mutation_allowed && restore_exec_modes="direct su_uid2000 su_shell runcon_shell_uid0"
    for exec_mode in $restore_exec_modes; do
        case "$exec_mode" in
            su_uid2000|su_shell) cap_shell_exec_available "$exec_mode" || continue ;;
            runcon_shell_uid0) cap_runcon_shell_available || continue ;;
        esac
        if command -v cmd >/dev/null 2>&1; then
            cap_exec_state_candidate cmd "$verb" 1 "$exec_mode" "$user" "$target" "$state" numeric && return 0
            [ "$user" = "0" ] && cap_exec_state_candidate cmd "$verb" 0 "$exec_mode" "$user" "$target" "$state" numeric && return 0
            [ "$user" = "$current_user" ] && cap_exec_state_candidate cmd "$verb" 1 "$exec_mode" "$user" "$target" "$state" current && return 0
        fi
        if command -v pm >/dev/null 2>&1; then
            cap_exec_state_candidate pm "$verb" 1 "$exec_mode" "$user" "$target" "$state" numeric && return 0
            [ "$user" = "0" ] && cap_exec_state_candidate pm "$verb" 0 "$exec_mode" "$user" "$target" "$state" numeric && return 0
            [ "$user" = "$current_user" ] && cap_exec_state_candidate pm "$verb" 1 "$exec_mode" "$user" "$target" "$state" current && return 0
        fi
    done
    return 1
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

[ -f "$CAPABILITIES_FILE" ] && load_capabilities
