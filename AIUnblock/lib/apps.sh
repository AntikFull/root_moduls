#!/system/bin/sh

PACKAGES_LIST="${PACKAGES_LIST:-/data/system/packages.list}"

append_unique_words() {
  local current="$1" value="$2"
  case " $current " in
    *" $value "*) echo "$current" ;;
    *) echo "$current $value" ;;
  esac
}

android_user_ids() {
  local file user out="" users
  for file in /data/system/users/*.xml; do
    [ -f "$file" ] || continue
    user=${file##*/}
    user=${user%.xml}
    case "$user" in ''|*[!0-9]*) continue ;; esac
    out="$out $user"
  done
  if [ -z "$out" ]; then
    users=$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')
    [ -n "$users" ] && out="$users"
  fi
  [ -n "$out" ] || out=0
  echo $out
}

package_uids_pm() {
  local package_name="$1" users="$2" user_id output
  for user_id in $users; do
    output=$(pm list packages -U --user "$user_id" "$package_name" 2>/dev/null)
    echo "$output" | awk -v wanted="package:$package_name" '
      $1 == wanted {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^uid:/) {
            value=$i
            sub(/^uid:/, "", value)
            gsub(/,/, "\n", value)
            print value
          }
        }
      }
    '
  done | awk '/^[0-9]+$/ && $1 > 9999 && !seen[$1]++ { print $1 }'
}

apps_reset() {
  GEMINI_SNI_UIDS=""
  GEMINI_UIDS=""
  NOTEBOOK_UIDS=""
  CHATGPT_UIDS=""
  CLAUDE_UIDS=""
  GROK_UIDS=""
  TARGET_PACKAGES=""
  APPS_ENTRIES=""
}

apps_assign() {
  local role="$1" uid="$2"
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$uid" -gt 9999 ] || return 1
  case "$role" in
    gemini_sni) GEMINI_SNI_UIDS=$(append_unique_words "$GEMINI_SNI_UIDS" "$uid") ;;
    gemini) GEMINI_UIDS=$(append_unique_words "$GEMINI_UIDS" "$uid") ;;
    notebook) NOTEBOOK_UIDS=$(append_unique_words "$NOTEBOOK_UIDS" "$uid") ;;
    chatgpt) CHATGPT_UIDS=$(append_unique_words "$CHATGPT_UIDS" "$uid") ;;
    claude) CLAUDE_UIDS=$(append_unique_words "$CLAUDE_UIDS" "$uid") ;;
    grok) GROK_UIDS=$(append_unique_words "$GROK_UIDS" "$uid") ;;
    *) return 1 ;;
  esac
}

apps_add_entry() {
  local role="$1" package_name="$2"
  case "$package_name" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$role" in
    gemini_sni|gemini|notebook|chatgpt|claude|grok) ;;
    *) return 1 ;;
  esac
  case " $APPS_ENTRIES " in *" $role:$package_name "*) return 0 ;; esac
  TARGET_PACKAGES=$(append_unique_words "$TARGET_PACKAGES" "$package_name")
  APPS_ENTRIES="$APPS_ENTRIES $role:$package_name"
}

apps_load_file() {
  local file="$1" role package_name extra
  [ -r "$file" ] || return 0
  while read -r role package_name extra; do
    case "$role" in ""|'#'*) continue ;; esac
    [ -n "$package_name" ] || continue
    [ -z "$extra" ] || continue
    apps_add_entry "$role" "$package_name" || true
  done < "$file"
}

apps_resolve_uids() {
  local users user entry role package_name appid uid map line installed
  [ -n "$APPS_ENTRIES" ] || return 0
  users=$(android_user_ids)

  map=""
  if [ -r "$PACKAGES_LIST" ]; then
    map=$(awk -v list="$TARGET_PACKAGES" '
      BEGIN { n = split(list, want, " ") }
      { for (i = 1; i <= n; i++) if ($1 == want[i] && $2 ~ /^[0-9]+$/) print $1 "=" $2 }
    ' "$PACKAGES_LIST" 2>/dev/null)
  fi

  for entry in $APPS_ENTRIES; do
    role=${entry%%:*}
    package_name=${entry#*:}
    appid=""
    for line in $map; do
      case "$line" in "$package_name="*) appid=${line#*=}; break ;; esac
    done

    if [ -z "$appid" ]; then
      for uid in $(package_uids_pm "$package_name" "$users"); do
        apps_assign "$role" "$uid" || true
      done
      continue
    fi

    installed=0
    for user in $users; do
      [ -d "/data/user/$user/$package_name" ] ||
        [ -d "/data/user_de/$user/$package_name" ] ||
        continue
      installed=1
      uid=$((user * 100000 + appid % 100000))
      apps_assign "$role" "$uid" || true
    done
    [ "$installed" -eq 1 ] || apps_assign "$role" "$appid" || true
  done
}

apps_load() {
  local moddir="${1:-$MODDIR}"
  apps_reset
  apps_load_file "$moddir/apps.list"
  apps_load_file "$moddir/apps.user.list"
  apps_resolve_uids
}

all_target_uids() {
  local all="" uid
  for uid in $GEMINI_SNI_UIDS $GEMINI_UIDS $NOTEBOOK_UIDS $CHATGPT_UIDS $CLAUDE_UIDS $GROK_UIDS; do
    all=$(append_unique_words "$all" "$uid")
  done
  echo "$all"
}
