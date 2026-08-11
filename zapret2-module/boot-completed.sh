#!/system/bin/sh
# KernelSU/KernelSU Next/APatch boot-completed lifecycle trigger.
# Do not detach a child here: on some KernelSU Next builds descendants of a
# completed lifecycle script are reaped. Run the real service in this process.
MODDIR="${0%/*}"
RUN_DIR="$MODDIR/run"
mkdir -p "$RUN_DIR" 2>/dev/null
printf '[%s] pid=%s boot_completed=%s boot-completed.sh invoked\n' \
  "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$(getprop sys.boot_completed 2>/dev/null)" \
  >> "$RUN_DIR/boot-trace.log" 2>/dev/null

# late_start normally stays alive and will continue by itself. Starting a second
# trigger is safe because service.lock admits only one initializer.
exec sh "$MODDIR/service.sh" boot
