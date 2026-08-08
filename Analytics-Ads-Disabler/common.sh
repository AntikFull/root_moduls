#!/system/bin/sh
# Shared library for Analytics & Ads Disabler v4 Universal Edition.
# POSIX/BusyBox ash compatible; intended for Magisk, KernelSU and APatch.

DATA_DIR="/data/adb/analytics_ads_disabler"
LOGFILE="$DATA_DIR/disabler.log"
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
WATCH_PID_FILE="$DATA_DIR/config_watch.pid"
INOTIFY_PID_FILE="$DATA_DIR/inotify.pid"
LOCK_DIR="$DATA_DIR/.operation.lock"
CAPABILITIES_FILE="$DATA_DIR/capabilities.conf"

# Compatibility dispatcher. It selects commands once per device/ROM and never evals the profile.
AAD_LIB_DIR="${MODDIR:-${0%/*}}"
[ -f "$AAD_LIB_DIR/compat.sh" ] && . "$AAD_LIB_DIR/compat.sh"

CATEGORIES="ADS ANALYTICS"
SYSTEM_PROTECTED="android com.android.systemui com.android.settings com.android.packageinstaller com.android.permissioncontroller com.google.android.permissioncontroller com.android.phone com.android.providers.settings com.android.providers.downloads com.android.documentsui com.android.shell com.android.bluetooth com.android.nfc com.android.location.fused com.android.networkstack com.google.android.networkstack com.android.networkstack.tethering com.google.android.networkstack.tethering com.google.android.gms com.android.vending com.google.android.gsf com.google.android.inputmethod.latin com.huawei.hwid com.huawei.hms.config.service com.sec.android.app.samsungapps com.topjohnwu.magisk me.weishu.kernelsu me.bmax.apatch"

mkdir -p "$DATA_DIR" 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $*" >> "$LOGFILE"
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

    ids=$(cap_list_users_raw 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -nu)
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
    cap_list_packages_raw "$user" 0 0 "$pkg" 2>/dev/null | sed 's/^package://; s/[[:space:]].*$//' | grep -Fxq -- "$pkg"
}

# Exact package-manager state change through the pre-probed device profile.
# No command fallback chain is executed for every component.
disable_component_smart() {
    user="$1"
    comp="$2"
    cap_disable_component "$user" "$comp" >/dev/null 2>&1
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
    echo "$user|$comp|$original" >> "$COMPONENT_STATE"
    log "STATE-SAVE u$user: $comp -> $original"
}

get_saved_original_state() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] || return
    awk -F'|' -v u="$user" -v c="$comp" '$1==u && $2==c {print $3; exit}' "$COMPONENT_STATE"
}

remove_state_record() {
    user="$1"; comp="$2"
    [ -f "$COMPONENT_STATE" ] || return
    tmp="$COMPONENT_STATE.tmp.$$"
    awk -F'|' -v u="$user" -v c="$comp" '!( $1==u && $2==c )' "$COMPONENT_STATE" > "$tmp"
    mv "$tmp" "$COMPONENT_STATE"
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

# Conservative scanner: only Services/Receivers blocks and their Resolver Tables are parsed.
# There is intentionally NO fallback to the full dumpsys output.
get_service_receiver_candidates() {
    pkg="$1"
    cap_package_dump "$pkg" | awk '
        /^[[:space:]]*(Receiver Resolver Table|Service Resolver Table):[[:space:]]*$/ {capture=1; next}
        /^[[:space:]]*(Activity Resolver Table|Provider Resolver Table):[[:space:]]*$/ {capture=0; next}
        /^[[:space:]]*(Receivers|Services):[[:space:]]*$/ {capture=1; next}
        /^[[:space:]]*(Activities|Providers|Packages|Registered ContentProviders):[[:space:]]*$/ {capture=0; next}
        capture {print}
    ' | grep -oE '[A-Za-z0-9._$-]+/[A-Za-z0-9._$]+' 2>/dev/null | awk -F/ -v p="$pkg" '$1==p' | sort -u
}

component_matches_category() {
    comp="$1"
    cat="$2"
    [ -f "$RULES_FILE" ] || return 1

    awk -v target="[$cat]" -v component="$comp" '
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

get_components_for_category() {
    pkg="$1"
    cat="$2"
    get_service_receiver_candidates "$pkg" | while IFS= read -r comp; do
        [ -z "$comp" ] && continue
        component_matches_category "$comp" "$cat" && echo "$comp"
    done
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
    [ -f "$DISABLED_LIST" ] || return
    tmp="$DISABLED_LIST.tmp.$$"
    awk -F'|' -v u="$user" -v c="$comp" -v k="$cat" '!( $1==u && $2==c && $3==k )' "$DISABLED_LIST" > "$tmp"
    mv "$tmp" "$DISABLED_LIST"
}

add_membership_and_disable() {
    user="$1"; comp="$2"; cat="$3"
    if ! membership_exists "$user" "$comp" "$cat"; then
        ensure_original_state "$user" "$comp"
    fi
    if disable_component_smart "$user" "$comp"; then
        if ! membership_exists "$user" "$comp" "$cat"; then
            echo "$user|$comp|$cat" >> "$DISABLED_LIST"
        fi
        log "DISABLED ($cat) u$user: $comp"
        return 0
    fi
    log "DISABLE-FAILED ($cat) u$user: $comp"
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

    awk -F'|' -v u="$user" -v p="$pkg/" -v k="$cat" '
        $1==u && index($2,p)==1 && $3==k {print $1 "|" $2 > "'$affected'"; next}
        {print}
    ' "$DISABLED_LIST" > "$DISABLED_LIST.tmp.$$"
    mv "$DISABLED_LIST.tmp.$$" "$DISABLED_LIST"

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
    desired="$DATA_DIR/.desired.$$"
    : > "$desired"

    if ! is_system_protected "$pkg" && ! is_globally_whitelisted "$pkg"; then
        for cat in $CATEGORIES; do
            category_enabled "$cat" || continue
            is_category_whitelisted "$pkg" "$cat" && continue

            comps=$(get_components_for_category "$pkg" "$cat")
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
    existing="$DATA_DIR/.existing.$$"
    awk -F'|' -v u="$user" -v p="$pkg/" '$1==u && index($2,p)==1' "$DISABLED_LIST" 2>/dev/null > "$existing"
    while IFS='|' read -r eu ec ek; do
        [ -z "$ec" ] && continue
        if ! grep -Fxq -- "$eu|$ec|$ek" "$desired" 2>/dev/null; then
            remove_membership "$eu" "$ec" "$ek"
            log "POLICY-REMOVE ($ek) u$eu: $ec"
            if ! has_any_membership "$eu" "$ec"; then
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
    done < "$desired"

    rm -f "$desired" "$existing"
    echo "$disabled_now"
}

process_package_all_users() {
    pkg="$1"
    total=0
    for user in $(list_user_ids); do
        if package_installed_for_user "$user" "$pkg"; then
            n=$(process_package_user "$user" "$pkg")
            total=$((total + n))
        else
            restore_all_for_package_user "$user" "$pkg"
        fi
    done
    echo "$total"
}

cleanup_stale_records() {
    [ -f "$DISABLED_LIST" ] || return
    tmp="$DISABLED_LIST.tmp.$$"
    : > "$tmp"
    while IFS='|' read -r user comp cat; do
        [ -z "$comp" ] && continue
        pkg=${comp%%/*}
        if package_installed_for_user "$user" "$pkg"; then
            echo "$user|$comp|$cat" >> "$tmp"
        else
            log "STALE: dropping record u$user $comp ($cat); package not installed for user."
            remove_state_record "$user" "$comp"
        fi
    done < "$DISABLED_LIST"
    mv "$tmp" "$DISABLED_LIST"
}


retry_orphan_restores() {
    [ -f "$COMPONENT_STATE" ] || return
    work="$COMPONENT_STATE.orphans.$$"
    cp "$COMPONENT_STATE" "$work" 2>/dev/null || return
    while IFS='|' read -r user comp original; do
        [ -z "$comp" ] && continue
        if ! has_any_membership "$user" "$comp"; then
            restore_original_state "$user" "$comp"
        fi
    done < "$work"
    rm -f "$work"
}

compute_config_hash() {
    {
        for f in "$SETTINGS_FILE" "$RULES_FILE" "$WHITELIST_FILE" "$WHITE_ADS_FILE" "$WHITE_ANALYTICS_FILE"; do
            [ -f "$f" ] && cat "$f"
            echo "--FILE--$f"
        done
    } | cksum 2>/dev/null | awk '{print $1 ":" $2}'
}

full_rescan_locked() {
    cleanup_stale_records
    retry_orphan_restores
    new_state="$DATA_DIR/package_state.tmp.$$"
    list_all_package_state > "$new_state"
    total=0
    processed=0

    while IFS='|' read -r user pkg vc; do
        [ -z "$pkg" ] && continue
        processed=$((processed + 1))
        n=$(process_package_user "$user" "$pkg")
        total=$((total + n))
    done < "$new_state"

    mv "$new_state" "$STATE_FILE"
    compute_config_hash > "$CONFIG_HASH_FILE"
    log "FULL-SCAN finished: packages/users=$processed operations=$total"
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
}

rescan_changed_packages() {
    acquire_lock || { log "LOCK timeout: incremental rescan skipped"; return 1; }
    rescan_changed_packages_locked
    release_lock
}
