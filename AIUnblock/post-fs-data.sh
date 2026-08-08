#!/system/bin/sh
# AI Unblock RU — post-fs-data.sh

MODDIR=${0%/*}

check_hosts_conflict() {
  local modules_dir="/data/adb/modules"
  [ -d "$modules_dir" ] || return 1
  for mod in "$modules_dir"/*; do
    [ -d "$mod" ] || continue
    local mod_name="${mod##*/}"
    case "$mod_name" in
      AIUnblock|AIUnblock*) continue ;;
    esac
    if [ -f "$mod/system/etc/hosts" ] || [ -f "$mod/etc/hosts" ] || [ -f "$mod/mode" ] || [ "$mod_name" = "bindhosts" ] || [ "$mod_name" = "Systemless_Hosts" ]; then
      return 0
    fi
  done
  return 1
}

mount_hosts() {
  local sys_hosts="/system/etc/hosts"
  local ai_hosts="$MODDIR/etc/hosts.ai"
  local adblock_hosts="$MODDIR/etc/hosts.adblock"

  local enable_routing=0
  local enable_adblock=0

  if [ -f "$MODDIR/install.conf" ]; then
    . "$MODDIR/install.conf"
    enable_routing=${ENABLE_HOSTS_ROUTING:-0}
    enable_adblock=${ENABLE_ADBLOCK:-0}
  fi

  # Валидация значений из install.conf
  case "$enable_routing" in 0|1) ;; *) enable_routing=0 ;; esac
  case "$enable_adblock" in 0|1) ;; *) enable_adblock=0 ;; esac

  if check_hosts_conflict; then
    rm -rf "$MODDIR/system" 2>/dev/null
    return 0
  fi

  if [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 0 ]; then
    # Если хосты отключены пользователем — полностью удаляем папку system, чтобы Root-менеджер не включал оверлей hosts
    rm -rf "$MODDIR/system" 2>/dev/null
    return 0
  fi

  mkdir -p "$MODDIR/system/etc"
  local target_hosts="$MODDIR/system/etc/hosts"

  if [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 0 ]; then
    [ -f "$ai_hosts" ] && cp -f "$ai_hosts" "$target_hosts"
  elif [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 1 ]; then
    [ -f "$adblock_hosts" ] && cp -f "$adblock_hosts" "$target_hosts"
  elif [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 1 ]; then
    if [ -f "$ai_hosts" ] && [ -f "$adblock_hosts" ]; then
      sed 's/\r$//' "$ai_hosts" > "$target_hosts" 2>/dev/null
      echo "" >> "$target_hosts"
      sed 's/\r$//' "$adblock_hosts" >> "$target_hosts" 2>/dev/null
    elif [ -f "$ai_hosts" ]; then
      cp -f "$ai_hosts" "$target_hosts"
    fi
  fi
  [ -f "$target_hosts" ] && chmod 0644 "$target_hosts" 2>/dev/null
}

mount_hosts

