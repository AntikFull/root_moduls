#!/system/bin/sh
# Zapret2 eCubz strict network role resolver.
# v2.6.12: prefer Android-reported roles, never infer VPN from a generic
# private/default interface. Unknown/ambiguous state falls back to "none"
# rather than misclassifying rmnet/wlan as a VPN.

MODDIR=${0%/*}
CONF_FILE="$MODDIR/zapret2.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${VPN_TUN_NAME:=AUTO}"

IP_BIN=$(command -v ip 2>/dev/null); [ -n "$IP_BIN" ] || IP_BIN=/system/bin/ip
DUMPSYS=$(command -v dumpsys 2>/dev/null); [ -n "$DUMPSYS" ] || DUMPSYS=/system/bin/dumpsys
RT_TABLES=/data/misc/net/rt_tables

uniq_lines() { awk 'NF && !seen[$0]++'; }
iface_exists() { [ -n "$1" ] && [ -d "/sys/class/net/$1" ]; }
iface_up() {
  iface_exists "$1" || return 1
  "$IP_BIN" -o link show dev "$1" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'
}
iface_has_ipv4() { "$IP_BIN" -o -4 addr show dev "$1" 2>/dev/null | grep -q '[[:space:]]inet[[:space:]]'; }
iface_has_ip() { "$IP_BIN" -o addr show dev "$1" 2>/dev/null | grep -Eq '[[:space:]]inet6?[[:space:]]'; }

iface_is_strict_vpn_hint() {
  case "$1" in
    tun*|wg*|awg*|vpn*|warp*|tailscale*|zt*) return 0 ;;
    *) return 1 ;;
  esac
}

iface_is_possible_tether_name() {
  case "$1" in
    ap*|swlan*|softap*|ap_br_wlan*|ap_br_softap*|rndis*|usb*|ncm*|bnep*|bt-pan*|pan*|tether*|wlan[0-9]*|wifi[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

ipv4_is_private() {
  local ip="$1" o2
  ip=${ip%%/*}
  case "$ip" in
    10.*|192.168.*) return 0 ;;
    172.*)
      o2=$(echo "$ip" | cut -d. -f2)
      case "$o2" in ''|*[!0-9]*) return 1 ;; esac
      [ "$o2" -ge 16 ] 2>/dev/null && [ "$o2" -le 31 ] 2>/dev/null
      return ;;
  esac
  return 1
}

iface_has_private4() {
  local cidr
  "$IP_BIN" -o -4 addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | while read -r cidr; do
    ipv4_is_private "$cidr" && { echo yes; break; }
  done | grep -q yes
}

# Physical/non-VPN networks as reported by Android. This is used only as an
# exclusion list so wlan0/rmnet cannot accidentally become a tether/VPN role.
physical_ifaces_from_connectivity() {
  [ -x "$DUMPSYS" ] || return 0
  "$DUMPSYS" connectivity 2>/dev/null | awk '
    /NetworkAgentInfo\{/ && /InterfaceName:/ && /NOT_VPN/ {
      s=$0
      sub(/^.*InterfaceName:[[:space:]]*/, "", s)
      sub(/[[:space:]}].*$/, "", s)
      if (s != "") print s
    }
  ' | uniq_lines
}

iface_is_physical_android() {
  local needle="$1"
  physical_ifaces_from_connectivity | grep -Fxq "$needle"
}

# Current tether state from Android's IpServer history. We take the last state
# observed for each interface. If Android gives us any state records at all,
# that result is authoritative: an empty TETHERED set means tether is off.
tether_current_states() {
  [ -x "$DUMPSYS" ] || return 0
  "$DUMPSYS" tethering 2>/dev/null | awk '
    /OBSERVED LinkProperties update iface=/ {
      iface=$0; sub(/^.*iface=/,"",iface); sub(/[[:space:]].*$/,"",iface)
      state=$0; sub(/^.*state=/,"",state); sub(/[[:space:]].*$/,"",state)
      if (iface != "") st[iface]=state
    }
    /OBSERVED iface=/ && /state=/ {
      iface=$0; sub(/^.*iface=/,"",iface); sub(/[[:space:]].*$/,"",iface)
      state=$0; sub(/^.*state=/,"",state); sub(/[[:space:]].*$/,"",state)
      if (iface != "" && state ~ /^[0-9]+$/) {
        if (state == "2") st[iface]="TETHERED"
        else if (state == "1") st[iface]="AVAILABLE"
        else if (state == "0") st[iface]="UNAVAILABLE"
      }
    }
    END { for (i in st) print i "|" st[i] }
  '
}

detect_downstreams() {
  local states iface state physical
  states=$(tether_current_states)
  if [ -n "$states" ]; then
    printf '%s\n' "$states" | while IFS='|' read -r iface state; do
      [ "$state" = "TETHERED" ] || continue
      iface_exists "$iface" || continue
      iface_up "$iface" || continue
      iface_has_ipv4 "$iface" || continue
      echo "$iface"
    done | uniq_lines
    return 0
  fi

  # Fallback for builds whose dumpsys tethering lacks IpServer state. Only
  # consider known tether-style names with a private IPv4 gateway and explicitly
  # exclude Android's physical NOT_VPN interfaces. No generic private-interface
  # guessing is allowed.
  physical=" $(physical_ifaces_from_connectivity | tr '\n' ' ') "
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_is_possible_tether_name "$iface" || continue
    case "$physical" in *" $iface "*) continue ;; esac
    iface_is_strict_vpn_hint "$iface" && continue
    iface_up "$iface" || continue
    iface_has_private4 "$iface" || continue
    echo "$iface"
  done | uniq_lines
}

vpn_from_connectivity() {
  [ -x "$DUMPSYS" ] || return 0
  # On current Android dumpsys the complete NetworkAgentInfo commonly fits on
  # one line. Only a NetworkAgentInfo with Transport VPN is accepted.
  "$DUMPSYS" connectivity 2>/dev/null | awk '
    /NetworkAgentInfo\{/ && /Transports:/ && /InterfaceName:/ {
      t=$0
      sub(/^.*Transports:[[:space:]]*/, "", t)
      sub(/[[:space:]]+Capabilities:.*/, "", t)
      if (t !~ /(^|\|)VPN($|\|)/) next
      s=$0
      sub(/^.*InterfaceName:[[:space:]]*/, "", s)
      sub(/[[:space:]}].*$/, "", s)
      if (s != "") print s
    }
  ' | while read -r iface; do
    iface_exists "$iface" || continue
    iface_up "$iface" || continue
    iface_has_ip "$iface" || continue
    echo "$iface"
  done | uniq_lines
}

vpn_from_default_route_hint() {
  local iface
  iface=$("$IP_BIN" route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  iface_is_strict_vpn_hint "$iface" || return 0
  iface_up "$iface" && iface_has_ip "$iface" && echo "$iface"
}

vpn_from_rt_tables_strict() {
  local idx name rest
  [ -r "$RT_TABLES" ] || return 0
  while read -r idx name rest; do
    case "$idx" in ''|\#*|*[!0-9]*) continue ;; esac
    [ -n "$name" ] || continue
    iface_is_strict_vpn_hint "$name" || continue
    iface_exists "$name" || continue
    iface_up "$name" || continue
    iface_has_ip "$name" || continue
    echo "$name"
  done < "$RT_TABLES" | uniq_lines
}

vpn_from_name_hints() {
  local iface
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_is_strict_vpn_hint "$iface" || continue
    iface_up "$iface" || continue
    iface_has_ip "$iface" || continue
    echo "$iface"
  done | uniq_lines
}

detect_vpns() {
  local explicit found
  explicit=${VPN_TUN_NAME:-AUTO}
  if [ -n "$explicit" ] && [ "$explicit" != AUTO ] && [ "$explicit" != auto ]; then
    iface_exists "$explicit" && iface_up "$explicit" && iface_has_ip "$explicit" && echo "$explicit"
    return 0
  fi

  found=$(vpn_from_connectivity)
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  found=$(vpn_from_default_route_hint)
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  found=$(vpn_from_rt_tables_strict)
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  vpn_from_name_hints
}

vpn_candidate_exists() {
  local explicit iface
  explicit=${VPN_TUN_NAME:-AUTO}
  if [ -n "$explicit" ] && [ "$explicit" != AUTO ] && [ "$explicit" != auto ]; then
    iface_exists "$explicit"
    return
  fi
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_is_strict_vpn_hint "$iface" && return 0
  done
  return 1
}

downstream_candidate_exists() {
  local states iface physical
  states=$(tether_current_states)
  if [ -n "$states" ]; then
    printf '%s\n' "$states" | grep -q '|TETHERED$'
    return
  fi
  physical=" $(physical_ifaces_from_connectivity | tr '\n' ' ') "
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_is_possible_tether_name "$iface" || continue
    case "$physical" in *" $iface "*) continue ;; esac
    iface_has_private4 "$iface" && return 0
  done
  return 1
}

signature() {
  local iface
  # Lightweight signature: interfaces/addresses + Android routing table file.
  # dumpsys is intentionally not run every polling tick; /data/misc/net inotify
  # provides an extra immediate trigger for netd/VPN state changes.
  for iface in $(ls /sys/class/net 2>/dev/null | sort); do
    printf '%s|' "$iface"
    cat "/sys/class/net/$iface/ifindex" 2>/dev/null | tr '\n' ':'
    cat "/sys/class/net/$iface/operstate" 2>/dev/null | tr '\n' ':'
    "$IP_BIN" -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | tr '\n' ','
    printf ';'
  done
  printf '|rt='
  if [ -r "$RT_TABLES" ]; then cksum "$RT_TABLES" 2>/dev/null | awk '{print $1":"$2}'; else printf 'none'; fi
}

case "$1" in
  downstream|downstreams) detect_downstreams ;;
  vpn|vpns) detect_vpns ;;
  vpn-candidate) vpn_candidate_exists ;;
  downstream-candidate) downstream_candidate_exists ;;
  physical) physical_ifaces_from_connectivity ;;
  tether-states) tether_current_states ;;
  signature) signature ;;
  roles|'')
    echo "downstream=$(detect_downstreams | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "vpn=$(detect_vpns | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "physical=$(physical_ifaces_from_connectivity | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    ;;
  *) exit 2 ;;
esac
