#!/system/bin/sh
# AI Unblock RU вЂ” optional per-app locale, С‚РѕР»СЊРєРѕ РѕРґРёРЅ СЂР°Р· РїРѕСЃР»Рµ boot-completed.

locale_state_contains() {
  local state_file="$1" package_name="$2" user_id="$3"
  [ -f "$state_file" ] || return 1
  awk -F '|' -v p="$package_name" -v u="$user_id" '
    $1 == p && $2 == u { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$state_file"
}

locale_get() {
  local package_name="$1" user_id="$2" output
  output=$(cmd locale get-app-locales "$package_name" --user "$user_id" 2>/dev/null)
  echo "$output" | sed -n 's/.*are \[\(.*\)\].*/\1/p'
}

apply_configured_locales() {
  local moddir="${1:-$MODDIR}" state_file list_file users package_name user_id current
  state_file="$moddir/app_locales.state"
  list_file="$moddir/locale_apps.list"

  AIUNBLOCK_CONFIG_FILE="$moddir/install.conf"
  [ -f "$moddir/lib/config.sh" ] && . "$moddir/lib/config.sh"
  config_load "$AIUNBLOCK_CONFIG_FILE"
  [ "$ENABLE_APP_LOCALE" -eq 1 ] || return 0

  cmd locale help 2>/dev/null | grep -q "set-app-locales" || return 0
  [ -r "$list_file" ] || return 0

  touch "$state_file"
  chmod 0600 "$state_file" 2>/dev/null
  users=$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')
  [ -n "$users" ] || users=0

  while read -r package_name; do
    case "$package_name" in ""|'#'*) continue ;; *[!A-Za-z0-9._-]*) continue ;; esac
    for user_id in $users; do
      pm list packages --user "$user_id" "$package_name" 2>/dev/null | grep -q "^package:$package_name$" || continue
      current=$(locale_get "$package_name" "$user_id")
      if ! locale_state_contains "$state_file" "$package_name" "$user_id"; then
        printf '%s|%s|%s\n' "$package_name" "$user_id" "$current" >> "$state_file"
      fi
      [ "$current" = "en-US" ] && continue
      cmd locale set-app-locales "$package_name" --user "$user_id" --locales en-US >/dev/null 2>&1 || true
    done
  done < "$list_file"
}

restore_saved_locales() {
  local moddir="${1:-$MODDIR}" state_file package_name user_id saved current
  state_file="$moddir/app_locales.state"
  [ -f "$state_file" ] || return 0
  cmd locale help 2>/dev/null | grep -q "set-app-locales" || return 0

  while IFS='|' read -r package_name user_id saved; do
    [ -n "$package_name" ] || continue
    current=$(locale_get "$package_name" "$user_id")
    # РќРµ РїРµСЂРµС‚РёСЂР°РµРј СЏР·С‹Рє, РµСЃР»Рё РїРѕР»СЊР·РѕРІР°С‚РµР»СЊ СѓР¶Рµ СЃР°Рј РёР·РјРµРЅРёР» РµРіРѕ РїРѕСЃР»Рµ AIUnblock.
    [ "$current" = "en-US" ] || continue
    if [ -n "$saved" ]; then
      cmd locale set-app-locales "$package_name" --user "$user_id" --locales "$saved" >/dev/null 2>&1 || true
    else
      cmd locale set-app-locales "$package_name" --user "$user_id" >/dev/null 2>&1 || true
    fi
  done < "$state_file"
}
