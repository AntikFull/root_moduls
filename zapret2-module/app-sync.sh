#!/system/bin/sh

umask 077
MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
CONF_FILE="$MODDIR/zapret2.conf"
APPS_LIST="$MODDIR/apps.list"
AUTO_APPS_LIST="$MODDIR/auto_apps.list"
EXCLUDE_LIST="$MODDIR/exclude.list"
RUNTIME_FILE="$RUN_DIR/tether-runtime.conf"
CACHE="$RUN_DIR/package_uids.cache"
LOCK="$RUN_DIR/app-sync.lock"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"

mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null; chmod 0700 "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
[ -f "$RUNTIME_FILE" ] && . "$RUNTIME_FILE"
: "${MODE:=INCLUDE}" "${AUTO_APPS_ENABLED:=1}" "${FORCE_TCP:=1}" "${QUIC_MODE:=SELECTED}" "${PORTS_TCP:=80,443}" "${QNUM:=200}"
: "${STRATEGY_EFFECTIVE:=SMART_COMPAT}" "${OWNER4:=0}" "${OWNER6:=0}" "${NFQ6:=0}" "${CONNMARK4:=0}" "${CONNMARK6:=0}"
: "${FLOW_CONNMARK:=0x10000000/0x10000000}" "${QBYPASS4:=--queue-bypass}" "${QBYPASS6:=--queue-bypass}"
IPT=$(command -v iptables 2>/dev/null); [ -n "$IPT" ] || IPT=/system/bin/iptables
IP6T=$(command -v ip6tables 2>/dev/null); [ -n "$IP6T" ] || IP6T=/system/bin/ip6tables
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] app-sync: $*" >> "$LOG_FILE"; }

list_users() {
  local users
  users=$(cmd user list 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -nu)
  if [ -z "$users" ] && [ -d /data/system/users ]; then users=$(find /data/system/users -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#.*/##' | grep -E '^[0-9]+$' | sort -nu); fi
  [ -n "$users" ] && printf '%s\n' "$users" || echo 0
}
refresh_fast_cache() {
  local tmp="$CACHE.tmp.$$" user pkg uid usr
  [ -r /data/system/packages.list ] || return 0
  : > "$tmp"
  for user in $(list_users); do
    if [ "$user" = "0" ]; then
      awk -v u="$user" 'NF>=2 && $2 ~ /^[0-9]+$/ {appid=$2%100000; uid=u*100000+appid; print $1,uid,u}' /data/system/packages.list >> "$tmp"
      continue
    fi
    [ -d "/data/user/$user" ] || continue
    awk -v u="$user" 'NF>=2 && $2 ~ /^[0-9]+$/ {appid=$2%100000; uid=u*100000+appid; print $1,uid,u}' /data/system/packages.list 2>/dev/null | \
    while read -r pkg uid usr; do
      [ -d "/data/user/$usr/$pkg" ] && printf '%s %s %s\n' "$pkg" "$uid" "$usr"
    done >> "$tmp"
  done
  [ -s "$tmp" ] && sort -u "$tmp" > "$tmp.sorted" && mv -f "$tmp.sorted" "$CACHE"
  rm -f "$tmp" "$tmp.sorted" 2>/dev/null
  chmod 0600 "$CACHE" 2>/dev/null || true
}
pkg_excluded() { [ -f "$EXCLUDE_LIST" ] && grep -qxF "$1" "$EXCLUDE_LIST" 2>/dev/null; }
get_uids() {
  local file="$1" honor="$2" pkg found out=""
  [ -f "$file" ] || { echo; return; }
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    pkg=$(echo "$pkg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'); case "$pkg" in ''|\#*) continue ;; esac
    [ "$honor" = 1 ] && pkg_excluded "$pkg" && continue
    found=$(awk -v p="$pkg" '$1==p {print $2}' "$CACHE" 2>/dev/null | sort -nu)
    for uid in $found; do out="$out $uid"; done
  done < "$file"
  echo "$out"
}

acquire() {
  local n=0 lp
  while ! mkdir "$LOCK" 2>/dev/null; do
    lp=$(cat "$LOCK/pid" 2>/dev/null)
    case "$lp" in ''|0|*[!0-9]*) rm -rf "$LOCK" 2>/dev/null ;; *) kill -0 "$lp" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null ;; esac
    n=$((n+1)); [ "$n" -lt 5 ] || return 1; sleep 1
  done
  echo $$ > "$LOCK/pid"
}
release() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; }
trap release EXIT HUP INT TERM
acquire || exit 1

[ -x "$IPT" ] || exit 1
"$IPT" -w 5 -t mangle -S ZAPRET2_MANGLE >/dev/null 2>&1 || exit 1
"$IPT" -w 5 -t filter -S ZAPRET2_FILTER >/dev/null 2>&1 || exit 1
"$IPT" -w 5 -t mangle -C OUTPUT -j ZAPRET2_MANGLE >/dev/null 2>&1 || exit 1
[ "$FORCE_TCP" != 1 ] || "$IPT" -w 5 -t filter -C OUTPUT -j ZAPRET2_FILTER >/dev/null 2>&1 || exit 1
refresh_fast_cache
if [ "$MODE" != GLOBAL ] && [ ! -s "$CACHE" ]; then
  log "UID cache unavailable for MODE=$MODE; refusing unsafe app-only rewrite"
  exit 1
fi
MANUAL_APP_UIDS=$(get_uids "$APPS_LIST" 1)
AUTO_APP_UIDS=""
[ "$AUTO_APPS_ENABLED" = 1 ] && AUTO_APP_UIDS=$(get_uids "$AUTO_APPS_LIST" 1)
APP_UIDS=$(printf '%s\n%s\n' "$AUTO_APP_UIDS" "$MANUAL_APP_UIDS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ')
EXCLUDE_UIDS=$(get_uids "$EXCLUDE_LIST" 0)

"$IPT" -w 5 -t mangle -F ZAPRET2_MANGLE >/dev/null 2>&1 || exit 1
"$IPT" -w 5 -t filter -F ZAPRET2_FILTER >/dev/null 2>&1 || exit 1
[ -x "$IP6T" ] && "$IP6T" -w 5 -t mangle -S ZAPRET2_MANGLE >/dev/null 2>&1 && "$IP6T" -w 5 -t mangle -F ZAPRET2_MANGLE >/dev/null 2>&1 || true
[ -x "$IP6T" ] && "$IP6T" -w 5 -t filter -S ZAPRET2_FILTER >/dev/null 2>&1 && "$IP6T" -w 5 -t filter -F ZAPRET2_FILTER >/dev/null 2>&1 || true

add4_nfq() { "$IPT" -w 5 -t mangle -A ZAPRET2_MANGLE "$@" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS4 >/dev/null 2>&1; }
add4_mark() {
  [ "$STRATEGY_EFFECTIVE" = SMART_NATIVE ] || return 0
  [ "$CONNMARK4" = 1 ] || return 1
  "$IPT" -w 5 -t mangle -A ZAPRET2_MANGLE "$@" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" >/dev/null 2>&1
}
add6_nfq() { [ "$NFQ6" = 1 ] && [ -x "$IP6T" ] && "$IP6T" -w 5 -t mangle -A ZAPRET2_MANGLE "$@" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" $QBYPASS6 >/dev/null 2>&1 || true; }
add6_mark() { [ "$STRATEGY_EFFECTIVE" = SMART_NATIVE ] && [ "$CONNMARK6" = 1 ] && [ -x "$IP6T" ] && "$IP6T" -w 5 -t mangle -A ZAPRET2_MANGLE "$@" -p tcp -m multiport --dports "$PORTS_TCP" -j CONNMARK --set-xmark "$FLOW_CONNMARK" >/dev/null 2>&1 || true; }

case "$MODE" in
  GLOBAL)
    add4_mark || exit 1; add4_nfq || exit 1; add6_mark; add6_nfq ;;
  EXCLUDE)
    [ "$OWNER4" = 1 ] || exit 1
    for uid in $EXCLUDE_UIDS; do "$IPT" -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN >/dev/null 2>&1 || exit 1; done
    add4_mark || exit 1; add4_nfq || exit 1
    if [ "$OWNER6" = 1 ]; then for uid in $EXCLUDE_UIDS; do "$IP6T" -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN >/dev/null 2>&1 || true; done; add6_mark; add6_nfq; fi ;;
  INCLUDE)
    [ "$OWNER4" = 1 ] || exit 1
    for uid in $APP_UIDS; do add4_mark -m owner --uid-owner "$uid" || exit 1; add4_nfq -m owner --uid-owner "$uid" || exit 1; done
    if [ "$OWNER6" = 1 ]; then for uid in $APP_UIDS; do add6_mark -m owner --uid-owner "$uid"; add6_nfq -m owner --uid-owner "$uid"; done; fi ;;
  *) exit 1 ;;
esac

if [ "$FORCE_TCP" = 1 ] && [ "$QUIC_MODE" != OFF ]; then
  case "$QUIC_MODE:$MODE" in
    GLOBAL:*|SELECTED:GLOBAL)
      "$IPT" -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT >/dev/null 2>&1 || exit 1
      [ -x "$IP6T" ] && "$IP6T" -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT >/dev/null 2>&1 || true ;;
    SELECTED:INCLUDE)
      [ "$OWNER4" = 1 ] || exit 1
      for uid in $APP_UIDS; do "$IPT" -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT >/dev/null 2>&1 || exit 1; done
      if [ "$OWNER6" = 1 ]; then for uid in $APP_UIDS; do "$IP6T" -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT >/dev/null 2>&1 || true; done; fi ;;
    SELECTED:EXCLUDE)
      [ "$OWNER4" = 1 ] || exit 1
      for uid in $EXCLUDE_UIDS; do "$IPT" -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -j RETURN >/dev/null 2>&1 || exit 1; done
      "$IPT" -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT >/dev/null 2>&1 || exit 1
      if [ "$OWNER6" = 1 ]; then for uid in $EXCLUDE_UIDS; do "$IP6T" -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -j RETURN >/dev/null 2>&1 || true; done; "$IP6T" -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT >/dev/null 2>&1 || true; fi ;;
  esac
fi

shared_want="$RUN_DIR/.shared-want.$$"
{ grep -vE '^[[:space:]]*(#|$)' "$AUTO_APPS_LIST" 2>/dev/null; grep -vE '^[[:space:]]*(#|$)' "$APPS_LIST" 2>/dev/null; grep -vE '^[[:space:]]*(#|$)' "$EXCLUDE_LIST" 2>/dev/null; } | sort -u > "$shared_want"
awk 'NR==FNR{want[$1]=1;next} ($1 in want){p[$2]=p[$2]" "$1;c[$2]++} END{for(u in c) if(c[u]>1) print u":"p[u]}' "$shared_want" "$CACHE" 2>/dev/null | while read -r shared; do log "shared UID: $shared"; done
rm -f "$shared_want" 2>/dev/null
log "rules synced without nfqws/VPN restart; mode=$MODE smart_app_uids=$(echo $APP_UIDS|wc -w) auto=$(echo $AUTO_APP_UIDS|wc -w) manual=$(echo $MANUAL_APP_UIDS|wc -w) exclude_uids=$(echo $EXCLUDE_UIDS|wc -w)"
exit 0
