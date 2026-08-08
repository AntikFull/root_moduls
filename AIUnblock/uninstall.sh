#!/system/bin/sh

MODDIR=${0%/*}
LOCALE_STATE="$MODDIR/app_locales.state"
LOCKDIR="$MODDIR/.daemon.lock"
ROUTER_PID_FILE="$MODDIR/.router.pid"

restore_app_locales() {
  [ -f "$LOCALE_STATE" ] || return 0
  cmd locale help 2>/dev/null | grep -q "set-app-locales" || return 0

  while IFS='|' read -r package_name user_id locales; do
    [ -n "$package_name" ] || continue
    if [ -n "$locales" ]; then
      cmd locale set-app-locales "$package_name" --user "$user_id" \
        --locales "$locales" >/dev/null 2>&1
    else
      cmd locale set-app-locales "$package_name" --user "$user_id" \
        >/dev/null 2>&1
    fi
  done < "$LOCALE_STATE"
}

stop_pid_file() {
  local file="$1"
  local pid
  pid=$(cat "$file" 2>/dev/null)
  case "$pid" in
    ""|*[!0-9]*) return 0 ;;
  esac
  kill "$pid" 2>/dev/null
}

delete_all() {
  local family="$1"
  shift
  while "$family" "$@" 2>/dev/null; do :; done
}

remove_firewall_rules() {
  local package_name uid target

  for package_name in \
    com.google.android.apps.bard \
    com.google.android.googlequicksearchbox \
    com.google.android.apps.labs.language.tailwind \
    com.openai.chatgpt \
    com.anthropic.claude \
    ai.x.grok; do
    for uid in $(pm list packages -U "$package_name" 2>/dev/null |
      awk -v wanted="package:$package_name" '$1 == wanted { sub(/^uid:/, "", $2); gsub(/,/, " ", $2); print $2 }'); do
      for target in GEMINI_DNAT GOOGLE_APP_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
        delete_all iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" \
          -p tcp --dport 443 -j "$target"
      done
      delete_all iptables -D OUTPUT -m owner --uid-owner "$uid" \
        -p udp --dport 443 -j DROP
      delete_all iptables -D OUTPUT -m owner --uid-owner "$uid" \
        -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
      delete_all ip6tables -D OUTPUT -m owner --uid-owner "$uid" -j DROP
      delete_all ip6tables -D OUTPUT -m owner --uid-owner "$uid" \
        -j REJECT --reject-with icmp6-port-unreachable
    done
  done

  delete_all iptables -t nat -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_OUT
  delete_all iptables -t nat -D OUTPUT -p tcp --dport 443 -j AIUNBLOCK_OUT
  delete_all iptables -D OUTPUT -p udp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_QUIC
  delete_all iptables -D OUTPUT -p udp --dport 443 -j AIUNBLOCK_QUIC
  delete_all iptables -D OUTPUT -p tcp --dport 443 -m comment --comment AIUNBLOCK -j AIUNBLOCK_GUARD
  delete_all iptables -D OUTPUT -p tcp --dport 443 -j AIUNBLOCK_GUARD
  delete_all ip6tables -D OUTPUT -m comment --comment AIUNBLOCK -j AIUNBLOCK_V6
  delete_all ip6tables -D OUTPUT -j AIUNBLOCK_V6

  for chain in AIUNBLOCK_OUT AIUNBLOCK_SNI GEMINI_DNAT GOOGLE_APP_DNAT CHATGPT_DNAT CLAUDE_DNAT GROK_DNAT; do
    iptables -t nat -F "$chain" 2>/dev/null
    iptables -t nat -X "$chain" 2>/dev/null
  done
  for chain in AIUNBLOCK_QUIC AIUNBLOCK_GUARD; do
    iptables -F "$chain" 2>/dev/null
    iptables -X "$chain" 2>/dev/null
  done
  ip6tables -F AIUNBLOCK_V6 2>/dev/null
  ip6tables -X AIUNBLOCK_V6 2>/dev/null
}

unmount_hosts() {
  mount | grep -q "/system/etc/hosts" && umount -l /system/etc/hosts 2>/dev/null
}

stop_pid_file "$LOCKDIR/pid"
stop_pid_file "$ROUTER_PID_FILE"
restore_app_locales
remove_firewall_rules
unmount_hosts
rm -rf "$LOCKDIR"
rm -f "$ROUTER_PID_FILE"
