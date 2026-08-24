#!/system/bin/sh
MODDIR=${0%/*}
LOCKDIR="$MODDIR/.daemon.lock"
ROUTER_PID_FILE="$MODDIR/.router.pid"

[ -f "$MODDIR/lib/apps.sh" ] && . "$MODDIR/lib/apps.sh"
[ -f "$MODDIR/lib/locales.sh" ] && . "$MODDIR/lib/locales.sh"

pid_matches() {
  local p="$1" expected="$2" exe comm cmdline
  [ -n "$p" ] || return 1
  case "$p" in *[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  [ -d "/proc/$p" ] || return 1

  exe=$(readlink "/proc/$p/exe" 2>/dev/null)
  case "$exe" in *"$expected"*) return 0 ;; esac

  read -r comm 2>/dev/null < "/proc/$p/comm"
  case "$comm" in *"$expected"*) return 0 ;; esac

  if read -r cmdline 2>/dev/null < "/proc/$p/cmdline"; then
    case "$cmdline" in *"$expected"*) return 0 ;; esac
  fi

  return 1
}

stop_pid_file() {
  local file="$1" expected="$2" pid n=0
  pid=$(cat "$file" 2>/dev/null)
  case "$pid" in ""|*[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  pid_matches "$pid" "$expected" || return 0
  kill "$pid" 2>/dev/null || return 0
  while [ "$n" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
}

delete_all() {
  while "$@" 2>/dev/null; do :; done
}

remove_firewall_rules() {
  local chain uid
  delete_all iptables -t mangle -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_MANGLE
  delete_all iptables -t mangle -D OUTPUT -p tcp --dport 443 -j AIUNBLOCK_MANGLE
  delete_all iptables -t nat -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_OUT
  delete_all iptables -D OUTPUT -p udp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_QUIC
  delete_all iptables -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK_FAIL -j AIUNBLOCK_FAIL
  delete_all iptables -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_GUARD
  delete_all ip6tables -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6
  delete_all ip6tables -D OUTPUT -p udp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6
  delete_all ip6tables -D OUTPUT -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6

  delete_all iptables -t nat -D OUTPUT -p tcp --dport 443 -j AIUNBLOCK_OUT
  delete_all iptables -D OUTPUT -p udp --dport 443 -j AIUNBLOCK_QUIC
  delete_all iptables -D OUTPUT -p tcp --dport 443 -j AIUNBLOCK_GUARD
  delete_all ip6tables -D OUTPUT -j AIUNBLOCK_V6

  iptables -t mangle -F AIUNBLOCK_MANGLE 2>/dev/null || true
  iptables -t mangle -X AIUNBLOCK_MANGLE 2>/dev/null || true
  for chain in AIUNBLOCK_OUT AIUNBLOCK_SNI GEMINI_DNAT GOOGLE_APP_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
    iptables -t nat -F "$chain" 2>/dev/null || true
    iptables -t nat -X "$chain" 2>/dev/null || true
  done
  for chain in AIUNBLOCK_QUIC AIUNBLOCK_FAIL AIUNBLOCK_GUARD; do
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
  done
  ip6tables -F AIUNBLOCK_V6 2>/dev/null || true
  ip6tables -X AIUNBLOCK_V6 2>/dev/null || true

  if command -v apps_load >/dev/null 2>&1; then
    apps_load "$MODDIR"
    for uid in $(all_target_uids); do
      for chain in GEMINI_DNAT GOOGLE_APP_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
        delete_all iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" -p tcp --dport 443 -j "$chain"
      done
      delete_all iptables -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j DROP
      delete_all iptables -D OUTPUT -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
      delete_all ip6tables -D OUTPUT -m owner --uid-owner "$uid" -j DROP
      delete_all ip6tables -D OUTPUT -m owner --uid-owner "$uid" -j REJECT --reject-with icmp6-port-unreachable
    done
  fi
}

stop_pid_file "$LOCKDIR/pid" "$MODDIR/service.sh"
stop_pid_file "$ROUTER_PID_FILE" "aiunblock-native"
command -v restore_saved_locales >/dev/null 2>&1 && restore_saved_locales "$MODDIR"
remove_firewall_rules
rm -rf "$LOCKDIR"
rm -f "$ROUTER_PID_FILE" "$MODDIR/.force_refresh" "$MODDIR/.reload"
rm -rf /data/adb/AIUnblock/logs /data/adb/AIUnblock/diagnostics 2>/dev/null || true
rm -f /data/adb/AIUnblock/.log_version /data/adb/AIUnblock/.public_log_version /data/adb/AIUnblock/.last_auto_diag 2>/dev/null || true
rm -rf /sdcard/eCubz/AIUnblock/logs 2>/dev/null || true
