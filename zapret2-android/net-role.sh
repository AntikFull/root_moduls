#!/system/bin/sh

umask 077
MODDIR=${0%/*}
CONF_FILE="$MODDIR/zapret2.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${VPN_TUN_NAME:=AUTO}"
: "${TETHER_IFACES:=ap+ swlan+ softap+ ap_br_wlan+ ap_br_softap+ rndis+ usb+ ncm+ bnep+ bt-pan+ pan+ tether+ wlan1 wlan2 wlan3 wlan4 wifi1 wifi2 wifi3 wifi4}"

IP_BIN=$(command -v ip 2>/dev/null); [ -n "$IP_BIN" ] || IP_BIN=/system/bin/ip
DUMPSYS=$(command -v dumpsys 2>/dev/null); [ -n "$DUMPSYS" ] || DUMPSYS=/system/bin/dumpsys
RT_TABLES=/data/misc/net/rt_tables

_CONNECTIVITY_READY=0
_CONNECTIVITY_PHYSICAL=""
_CONNECTIVITY_VPNS=""
_DEFAULT_UPSTREAM_READY=0
_DEFAULT_UPSTREAM_CACHE=""
_TETHER_STATES_READY=0
_TETHER_STATES_CACHE=""

uniq_lines() { awk 'NF && !seen[$0]++'; }
iface_exists() { [ -n "$1" ] && [ -d "/sys/class/net/$1" ]; }
iface_up() {
  iface_exists "$1" || return 1
  "$IP_BIN" -o link show dev "$1" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'
}
iface_has_ipv4() { "$IP_BIN" -o -4 addr show dev "$1" 2>/dev/null | grep -q '[[:space:]]inet[[:space:]]'; }
iface_has_ip() { "$IP_BIN" -o addr show dev "$1" 2>/dev/null | grep -Eq '[[:space:]]inet6?[[:space:]]'; }

iface_is_strict_vpn_hint() {
  [ "$1" != "${WARP_DEV:-awg99}" ] || return 1
  case "$1" in
    tun*|wg*|awg*|vpn*|warp*|tailscale*|zt*) return 0 ;;
    *) return 1 ;;
  esac
}

iface_matches_tether_config() {
  local iface="$1" pat prefix
  for pat in $TETHER_IFACES; do
    case "$pat" in
      *+)
        prefix=${pat%+}
        case "$iface" in "$prefix"*) return 0 ;; esac
        ;;
      *) [ "$iface" = "$pat" ] && return 0 ;;
    esac
  done
  return 1
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

ensure_default_upstreams() {
  [ "$_DEFAULT_UPSTREAM_READY" = 1 ] && return 0
  _DEFAULT_UPSTREAM_CACHE=$({
    "$IP_BIN" -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
    "$IP_BIN" -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
    "$IP_BIN" -4 route show table main default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
    "$IP_BIN" -6 route show table main default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
  } | uniq_lines | while read -r iface; do
    iface_is_strict_vpn_hint "$iface" && continue
    [ -n "$iface" ] && echo "$iface"
  done)
  _DEFAULT_UPSTREAM_READY=1
}

default_upstream_ifaces() {
  ensure_default_upstreams
  [ -n "$_DEFAULT_UPSTREAM_CACHE" ] && printf '%s\n' "$_DEFAULT_UPSTREAM_CACHE"
}

ensure_connectivity_roles() {
  [ "$_CONNECTIVITY_READY" = 1 ] && return 0
  local tagged
  tagged=""
  if [ -x "$DUMPSYS" ]; then
    tagged=$("$DUMPSYS" connectivity 2>/dev/null | awk '
      /NetworkAgentInfo\{/ && /InterfaceName:/ {
        s=$0
        sub(/^.*InterfaceName:[[:space:]]*/, "", s)
        sub(/[[:space:]}].*$/, "", s)
        if (s == "") next
        if ($0 ~ /NOT_VPN/) print "P|" s
        t=$0
        sub(/^.*Transports:[[:space:]]*/, "", t)
        sub(/[[:space:]]+Capabilities:.*/, "", t)
        if (t ~ /(^|\|)VPN($|\|)/) print "V|" s
      }
    ')
  fi
  _CONNECTIVITY_PHYSICAL=$(printf '%s\n' "$tagged" | awk -F'|' '$1=="P" && $2!="" && !seen[$2]++ {print $2}')
  _CONNECTIVITY_VPNS=$(printf '%s\n' "$tagged" | awk -F'|' '$1=="V" && $2!="" && !seen[$2]++ {print $2}')
  _CONNECTIVITY_READY=1
}

physical_ifaces_from_connectivity() {
  ensure_connectivity_roles
  ensure_default_upstreams
  {
    [ -n "$_CONNECTIVITY_PHYSICAL" ] && printf '%s\n' "$_CONNECTIVITY_PHYSICAL"
    [ -n "$_DEFAULT_UPSTREAM_CACHE" ] && printf '%s\n' "$_DEFAULT_UPSTREAM_CACHE"
  } | uniq_lines
}

iface_is_physical_android() {
  local needle="$1"
  physical_ifaces_from_connectivity | grep -Fxq "$needle"
}

ensure_tether_states() {
  [ "$_TETHER_STATES_READY" = 1 ] && return 0
  if [ -x "$DUMPSYS" ]; then
    _TETHER_STATES_CACHE=$("$DUMPSYS" tethering 2>/dev/null | awk '
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
    ')
  else
    _TETHER_STATES_CACHE=""
  fi
  _TETHER_STATES_READY=1
}

tether_current_states() {
  ensure_tether_states
  [ -n "$_TETHER_STATES_CACHE" ] && printf '%s\n' "$_TETHER_STATES_CACHE"
}

detect_downstreams() {
  local states iface state physical tethered=""
  ensure_connectivity_roles
  ensure_default_upstreams
  ensure_tether_states
  states=$(tether_current_states)
  if [ -n "$states" ]; then
    tethered=$(printf '%s\n' "$states" | while IFS='|' read -r iface state; do
      [ "$state" = "TETHERED" ] || continue
      iface_exists "$iface" || continue
      iface_up "$iface" || continue
      iface_has_ipv4 "$iface" || continue
      iface_is_physical_android "$iface" && continue
      iface_is_strict_vpn_hint "$iface" && continue
      echo "$iface"
    done | uniq_lines)
    [ -n "$tethered" ] && { printf '%s\n' "$tethered"; return 0; }
  fi

  physical=" $(physical_ifaces_from_connectivity | tr '\n' ' ') "
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_matches_tether_config "$iface" || continue
    case "$physical" in *" $iface "*) continue ;; esac
    iface_is_strict_vpn_hint "$iface" && continue
    iface_up "$iface" || continue
    iface_has_private4 "$iface" || continue
    echo "$iface"
  done | uniq_lines
}

vpn_from_connectivity() {
  local iface
  ensure_connectivity_roles
  [ -n "$_CONNECTIVITY_VPNS" ] || return 0
  printf '%s\n' "$_CONNECTIVITY_VPNS" | while read -r iface; do
    iface_exists "$iface" || continue
    iface_up "$iface" || continue
    iface_has_ip "$iface" || continue
    iface_is_physical_android "$iface" && continue
    echo "$iface"
  done | uniq_lines
}

vpn_from_default_route_hint() {
  local iface
  iface=$("$IP_BIN" route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  iface_is_strict_vpn_hint "$iface" || return 0
  iface_is_physical_android "$iface" && return 0
  iface_up "$iface" && iface_has_ip "$iface" && echo "$iface"
}

vpn_from_rt_tables_strict() {
  local idx name rest
  [ -r "$RT_TABLES" ] || return 0
  while read -r idx name rest; do
    case "$idx" in ''|\#*|*[!0-9]*) continue ;; esac
    [ -n "$name" ] || continue
    iface_is_strict_vpn_hint "$name" || continue
    iface_is_physical_android "$name" && continue
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
    iface_is_physical_android "$iface" && continue
    iface_up "$iface" || continue
    iface_has_ip "$iface" || continue
    echo "$iface"
  done | uniq_lines
}

detect_vpns() {
  local explicit found
  ensure_connectivity_roles
  ensure_default_upstreams
  explicit=${VPN_TUN_NAME:-AUTO}
  if [ -n "$explicit" ] && [ "$explicit" != AUTO ] && [ "$explicit" != auto ]; then
    iface_exists "$explicit" && iface_up "$explicit" && iface_has_ip "$explicit" && ! iface_is_physical_android "$explicit" && echo "$explicit"
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
  ensure_connectivity_roles
  ensure_default_upstreams
  explicit=${VPN_TUN_NAME:-AUTO}
  if [ -n "$explicit" ] && [ "$explicit" != AUTO ] && [ "$explicit" != auto ]; then
    iface_exists "$explicit" && iface_up "$explicit" && iface_has_ip "$explicit" && ! iface_is_physical_android "$explicit"
    return
  fi
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_is_strict_vpn_hint "$iface" || continue
    iface_is_physical_android "$iface" && continue
    iface_up "$iface" || continue
    iface_has_ip "$iface" || continue
    return 0
  done
  return 1
}

downstream_candidate_exists() {
  local states iface physical
  ensure_connectivity_roles
  ensure_default_upstreams
  ensure_tether_states
  states=$(tether_current_states)
  if [ -n "$states" ] && printf '%s\n' "$states" | grep -q '|TETHERED$'; then
    return 0
  fi
  physical=" $(physical_ifaces_from_connectivity | tr '\n' ' ') "
  for iface in $(ls /sys/class/net 2>/dev/null); do
    iface_matches_tether_config "$iface" || continue
    case "$physical" in *" $iface "*) continue ;; esac
    iface_is_strict_vpn_hint "$iface" && continue
    iface_up "$iface" || continue
    iface_has_private4 "$iface" && return 0
  done
  return 1
}

signature() {
  local iface
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

role_signature() {
  ensure_connectivity_roles
  ensure_default_upstreams
  ensure_tether_states
  printf 'down=%s|vpn=%s|phys=%s' \
    "$(detect_downstreams | sort | tr '\n' ',' | sed 's/,$//')" \
    "$(detect_vpns | sort | tr '\n' ',' | sed 's/,$//')" \
    "$(physical_ifaces_from_connectivity | sort | tr '\n' ',' | sed 's/,$//')"
}

case "$1" in
  downstream|downstreams) detect_downstreams ;;
  vpn|vpns) detect_vpns ;;
  vpn-candidate) vpn_candidate_exists ;;
  downstream-candidate) downstream_candidate_exists ;;
  physical) physical_ifaces_from_connectivity ;;
  tether-states) tether_current_states ;;
  signature) signature ;;
  role-signature) role_signature ;;
  roles|'')
    echo "downstream=$(detect_downstreams | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "vpn=$(detect_vpns | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "physical=$(physical_ifaces_from_connectivity | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    ;;
  *) exit 2 ;;
esac
