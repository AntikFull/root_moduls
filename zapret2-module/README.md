# Zapret2 eCubz v2.6.19 (2619)

Boot reliability hotfix based on a real KernelSU Next bugreport.

- `service.sh` no longer detaches a `boot-wait.sh` child. The KernelSU late_start process itself waits for `sys.boot_completed=1` and continues startup in the same process.
- `boot-completed.sh` is retained as a synchronous second trigger; `service.lock` prevents duplicate initialization.
- Added `/data/adb/modules/zapret2-android/run/boot-trace.log` for exact lifecycle diagnostics.
- Diagnostics show the live late_start PID and boot trace.
- WebUI version badge now reads the installed version dynamically from KernelSU `moduleInfo()`.
- Network/VPN/Hotspot/AntiDPI routing logic is unchanged from v2.6.18.
