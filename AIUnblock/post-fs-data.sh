#!/system/bin/sh
# AI Unblock RU — post-fs-data.sh

MODDIR=${0%/*}
MODULE_ID="AIUnblock"

[ -f "$MODDIR/lib/hosts_conflict.sh" ] && . "$MODDIR/lib/hosts_conflict.sh"

mount_hosts() {
  local sys_hosts="/system/etc/hosts"
  local ai_hosts="$MODDIR/etc/hosts.ai"
  local adblock_hosts="$MODDIR/etc/hosts.adblock"

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

  if [ "$enable_routing" -eq 0 ] && [ "$enable_adblock" -eq 0 ]; then
# Если хосты отключены пользователем — полностью удаляем папку system, чтобы Root-менеджер не включал оверлей hosts
    rm -rf "$MODDIR/system" 2>/dev/null
    return 0
  fi

# Пересчёт конфликта на каждой загрузке: другой hosts-модуль мог быть
# установлен уже ПОСЛЕ инсталляции AI Unblock, разовой проверки в
# customize.sh недостаточно.
  if command -v hosts_conflict_detected >/dev/null 2>&1; then
    local conflict_id
    conflict_id=$(hosts_conflict_detected "$MODULE_ID")
    if [ -n "$conflict_id" ]; then
      echo "[$(date)] hosts: конфликт с модулем '$conflict_id' — overlay пропущен" >> "$MODDIR/dnat.log" 2>/dev/null
      rm -rf "$MODDIR/system" 2>/dev/null
      return 0
    fi
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
