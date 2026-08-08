#!/system/bin/sh
# AI Unblock RU — post-fs-data.sh

MODDIR=${0%/*}

mount_hosts() {
  local sys_hosts="/system/etc/hosts"
  local ai_hosts="$MODDIR/system/etc/hosts"
  local adblock_hosts="$MODDIR/system/etc/hosts.adblock"
  local target_hosts=""

  local enable_routing=1
  local enable_adblock=1

  if [ -f "$MODDIR/install.conf" ]; then
    . "$MODDIR/install.conf"
    enable_routing=${ENABLE_HOSTS_ROUTING:-1}
    enable_adblock=${ENABLE_ADBLOCK:-1}
  fi

  # Валидация значений из install.conf
  case "$enable_routing" in 0|1) ;; *) enable_routing=1 ;; esac
  case "$enable_adblock" in 0|1) ;; *) enable_adblock=1 ;; esac

  if mount | grep -q "$sys_hosts"; then
    umount -l "$sys_hosts" 2>/dev/null
  fi

  if [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 0 ]; then
    return 0
  elif [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 0 ]; then
    target_hosts="$ai_hosts"
  elif [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 1 ]; then
    target_hosts="$adblock_hosts"
  elif [ "$enable_routing" -eq 1 ] && [ "$enable_adblock" -eq 1 ]; then
    target_hosts="$MODDIR/.merged_hosts"
    if [ -f "$ai_hosts" ] && [ -f "$adblock_hosts" ]; then
      sed 's/\r$//' "$ai_hosts" > "$target_hosts"
      echo "" >> "$target_hosts"
      sed 's/\r$//' "$adblock_hosts" >> "$target_hosts"
      chmod 0644 "$target_hosts" 2>/dev/null
    elif [ -f "$ai_hosts" ]; then
      target_hosts="$ai_hosts"
    fi
  fi

  [ -n "$target_hosts" ] && [ -f "$target_hosts" ] || return 0
  [ -f "$sys_hosts" ] || return 0

  mount -o bind "$target_hosts" "$sys_hosts" 2>/dev/null || \
  mount --bind "$target_hosts" "$sys_hosts" 2>/dev/null
}

mount_hosts
