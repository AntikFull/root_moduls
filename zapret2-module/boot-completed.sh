#!/system/bin/sh
umask 077
MODDIR="${0%/*}"
RUN_DIR="$MODDIR/run"
mkdir -p "$RUN_DIR" 2>/dev/null
chmod 0700 "$RUN_DIR" 2>/dev/null || true
ppid=$(awk '{print $4}' /proc/$$/stat 2>/dev/null)
pgrp=$(awk '{print $5}' /proc/$$/stat 2>/dev/null)
sid=$(awk '{print $6}' /proc/$$/stat 2>/dev/null)
printf '[%s] pid=%s ppid=%s pgrp=%s sid=%s boot_completed=%s boot-completed.sh invoked\n' \
  "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$ppid" "$pgrp" "$sid" "$(getprop sys.boot_completed 2>/dev/null)" \
  >> "$RUN_DIR/boot-trace.log" 2>/dev/null
chmod 0600 "$RUN_DIR/boot-trace.log" 2>/dev/null || true

launch_boot_worker() {
  BOOT_WORKER_DESC=""
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/service.sh" boot </dev/null >/dev/null 2>&1 &
    BOOT_WORKER_DESC="setsid:$!"
    return 0
  fi
  if command -v busybox >/dev/null 2>&1 && busybox setsid true >/dev/null 2>&1; then
    busybox setsid sh "$MODDIR/service.sh" boot </dev/null >/dev/null 2>&1 &
    BOOT_WORKER_DESC="busybox-setsid:$!"
    return 0
  fi
  if command -v toybox >/dev/null 2>&1 && toybox setsid true >/dev/null 2>&1; then
    toybox setsid sh "$MODDIR/service.sh" boot </dev/null >/dev/null 2>&1 &
    BOOT_WORKER_DESC="toybox-setsid:$!"
    return 0
  fi
  nohup sh "$MODDIR/service.sh" boot </dev/null >/dev/null 2>&1 &
  BOOT_WORKER_DESC="nohup-fallback:$!"
}
launch_boot_worker
printf '[%s] pid=%s boot worker=%s lifecycle hook returning\n' \
  "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$BOOT_WORKER_DESC" >> "$RUN_DIR/boot-trace.log" 2>/dev/null
exit 0
