#!/system/bin/sh

HOSTS_MARKER="# AIUnblock-hosts"

hosts_status_write() {
  local moddir="$1" status="$2"
  printf '%s\n' "$status" > "$moddir/.hosts_status" 2>/dev/null || true
  chmod 0600 "$moddir/.hosts_status" 2>/dev/null
}

hosts_log() {
  local message="$1" dir="/data/adb/AIUnblock/logs"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)] $message" >> "$dir/AIUnblock_debug.log" 2>/dev/null
}

ksu_runtime_detected() {
  [ "${KSU:-}" = "true" ] && return 0
  [ -d /data/adb/ksu ] && return 0
  command -v ksud >/dev/null 2>&1 && return 0
  return 1
}

hosts_overlay_applied() {
  grep -q "^$HOSTS_MARKER" /system/etc/hosts 2>/dev/null
}

verify_hosts_overlay() {
  local moddir="${1:-$MODDIR}" status
  status=$(cat "$moddir/.hosts_status" 2>/dev/null)
  case "$status" in
    disabled|conflict:*|missing:*) return 0 ;;
  esac
  [ -f "$moddir/system/etc/hosts" ] || return 0
  if hosts_overlay_applied; then
    hosts_status_write "$moddir" "active"
  else
    hosts_status_write "$moddir" "not-mounted"
    hosts_log "hosts: overlay РР СРРРСРСРРРР ССРР РСРСРРРРР/РРРРРРРСРР root; per-app routing РСРРРРРРРС СРРРСРСС"
  fi
}

prepare_hosts_tree() {
  local moddir="${1:-$MODDIR}" ai_hosts adblock_hosts target tmp conflict_id
  ai_hosts="$moddir/etc/hosts.ai"
  adblock_hosts="$moddir/etc/hosts.adblock"

  AIUNBLOCK_CONFIG_FILE="$moddir/install.conf"
  [ -f "$moddir/lib/config.sh" ] && . "$moddir/lib/config.sh"
  config_load "$AIUNBLOCK_CONFIG_FILE"

  if [ "$ENABLE_HOSTS_ROUTING" -eq 0 ] && [ "$ENABLE_ADBLOCK" -eq 0 ]; then
    rm -rf "$moddir/system" 2>/dev/null
    hosts_status_write "$moddir" "disabled"
    return 0
  fi

  if [ -f "$moddir/lib/hosts_conflict.sh" ]; then
    . "$moddir/lib/hosts_conflict.sh"
    conflict_id=$(hosts_conflict_detected "AIUnblock" 2>/dev/null)
    if [ -n "$conflict_id" ]; then
      rm -rf "$moddir/system" 2>/dev/null
      hosts_status_write "$moddir" "conflict:$conflict_id"
      hosts_log "hosts: РСРРСССР optional overlay РР-РР РРРСРРРСР С '$conflict_id'; per-app routing РСРРРРРРРС СРРРСРСС"
      return 0
    fi
  fi

  [ "$ENABLE_HOSTS_ROUTING" -eq 0 ] || [ -s "$ai_hosts" ] || {
    rm -rf "$moddir/system" 2>/dev/null
    hosts_status_write "$moddir" "missing:hosts.ai"
    hosts_log "hosts: РССССССРСРС etc/hosts.ai; optional overlay РСРРСССР"
    return 0
  }
  [ "$ENABLE_ADBLOCK" -eq 0 ] || [ -s "$adblock_hosts" ] || {
    rm -rf "$moddir/system" 2>/dev/null
    hosts_status_write "$moddir" "missing:hosts.adblock"
    hosts_log "hosts: РССССССРСРС etc/hosts.adblock; optional overlay РСРРСССР"
    return 0
  }

  mkdir -p "$moddir/system/etc" || return 1
  target="$moddir/system/etc/hosts"
  tmp="$target.tmp.$$"

  printf '%s\n' "$HOSTS_MARKER" > "$tmp" || return 1
  if [ "$ENABLE_HOSTS_ROUTING" -eq 1 ]; then
    cat "$ai_hosts" >> "$tmp" || return 1
  fi
  if [ "$ENABLE_HOSTS_ROUTING" -eq 1 ] && [ "$ENABLE_ADBLOCK" -eq 1 ]; then
    echo >> "$tmp"
  fi
  if [ "$ENABLE_ADBLOCK" -eq 1 ]; then
    cat "$adblock_hosts" >> "$tmp" || return 1
  fi

  chmod 0644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$target" || return 1

  if ksu_runtime_detected && [ ! -e /data/adb/metamodule ] && [ ! -L /data/adb/metamodule ]; then
    hosts_status_write "$moddir" "prepared:ksu-overlayfs"
  else
    hosts_status_write "$moddir" "prepared"
  fi
  return 0
}
