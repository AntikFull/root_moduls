

#MINAPI=21
#MAXAPI=25
#DYNLIB=true
#PARTOVER=true
#PARTITIONS=""


REPLACE="
"

# Permissions

set_permissions() {
  set_perm $MODPATH/system/bin/nfqws2 0 0 0755
  set_perm $MODPATH/system/bin/zapret2-control 0 0 0755
  set_perm $MODPATH/service.sh 0 0 0755
  set_perm $MODPATH/action.sh 0 0 0755
  set_perm $MODPATH/uninstall.sh 0 0 0755
  set_perm $MODPATH/on_change.sh 0 0 0755
}

# MMT Extended Logic

SKIPUNZIP=1
[ -z "$TMPDIR" ] && TMPDIR=/data/local/tmp
mkdir -p "$TMPDIR"
unzip -qjo "$ZIPFILE" 'common/functions.sh' -d "$TMPDIR" >&2
. "$TMPDIR/functions.sh"
