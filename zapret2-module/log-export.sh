#!/system/bin/sh
umask 077
MODDIR=${0%/*}
INTERNAL_DIR="$MODDIR/logs"
EXPORT_DIR="/sdcard/eCubz"
MODE=${1:-now}

wait_for_export_dir() {
  max=0
  [ "$MODE" = once ] && max=90
  elapsed=0
  while :; do
    if mkdir -p "$EXPORT_DIR" 2>/dev/null; then
      testfile="$EXPORT_DIR/.zapret2-write-test.$$"
      if : > "$testfile" 2>/dev/null; then
        rm -f "$testfile" 2>/dev/null
        return 0
      fi
    fi
    [ "$max" -gt 0 ] || return 1
    elapsed=$((elapsed + 2))
    [ "$elapsed" -lt "$max" ] || return 1
    sleep 2
  done
}

if ! wait_for_export_dir; then
  [ "$MODE" = now ] && echo "Shared storage /sdcard РСС РРРРСССРРР" >&2 && exit 1
  exit 0
fi
mkdir -p "$INTERNAL_DIR" 2>/dev/null
for name in zapret2_debug.log zapret2_nfqws.log zapret2_diagnostics_latest.txt; do
  [ -f "$INTERNAL_DIR/$name" ] || continue
  tmp="$EXPORT_DIR/.$name.tmp.$$"
  if cp -f "$INTERNAL_DIR/$name" "$tmp" 2>/dev/null; then
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$EXPORT_DIR/$name" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
done
[ "$MODE" = now ] && printf '%s\n' "$EXPORT_DIR"
exit 0
