# Changelog

## v4.2.0 — Runtime Adaptive Edition

- Fixed Android 16/API 36 compatibility case where `cmd package help` advertises both `disable` and `disable-user`, but `disable --user ...` can fail at Binder runtime on real components.
- Operational disable priority is now `disable-user` -> `disable`; enable priority is `enable-user` -> `enable` (OEM verb is used only if actually supported).
- Capability detection now performs a non-destructive runtime/Binder probe against a guaranteed-missing component (using an installed third-party package when available) instead of trusting help/parser output alone.
- Candidates producing `Failed transaction`, Binder/RemoteException, SecurityException, unsupported/unknown command/option, or invalid component-state errors are rejected.
- Added one-time runtime self-healing: a cached backend that later fails with a hard transport/backend error invalidates the profile, re-probes once, and retries once. Ordinary target-specific failures do not trigger fallback storms.
- Split the module's operational block command from the command used to restore an original explicit `disabled` state, preserving rollback semantics as closely as the ROM allows.
- Capability profile schema bumped to v3, forcing existing v4.1 installations to re-probe automatically.

## v4.1.0 — Adaptive Universal Edition

- Added one-time ROM/device capability probing during installation.
- Added persistent `capabilities.conf` with safe enum-like backend/verb selections; the file is never sourced or eval'ed.
- Runtime component operations now use one preselected PackageManager command instead of trying a fallback chain for every component.
- Added automatic capability re-probe when the profile schema or Android build fingerprint changes after an OTA/ROM update.
- Capability profile now covers disable, enable, default-state, disabled-user, disabled-until-used, user listing, package listing, `--user`, `--show-versioncode`, package dump and app watcher backend.
- Added non-destructive PackageManager command probing; no real component is toggled during detection.
- Added safe user-0 fallback when a ROM lacks complete per-user PackageManager support.
- Added package polling fallback when `inotifyd` is unavailable and a low-frequency safety poll when realtime monitoring is active.
- Action button now prints the selected compatibility profile before rescanning.

## v4.0.0 — Universal Edition

- Added interactive Volume Up/Down installer choices.
- Added independent ADS and ANALYTICS feature flags.
- Added multi-user/profile scanning and per-user state records.
- Added exact/default-state aware rollback instead of blind enable operations.
- Fixed invalid `enable-user` usage and v3 uninstall fallback bug.
- Removed global `killall inotifyd`; watcher PIDs are owned and identity-checked.
- Replaced permissive dumpsys fallback with strict Services/Receivers-only scanning.
- Changed ordinary signatures to literal case-insensitive matching; regex requires `re:`.
- Added correct overlapping-category ownership so one whitelist cannot undo another active block.
- Added persistent settings/config across module updates.
- Added safe migration from legacy v3 state.
- Added stale-lock recovery and PID-reuse protection.
- Added realtime create/delete/move monitoring for `/data/app`.
- Added automatic full reconciliation when settings/rules/whitelists change.
- Added Action button for manual full rescan in Magisk/KernelSU/APatch.
- Added validation/clamping for poll interval and anomaly threshold.
- Expanded protection of critical Android/root-manager infrastructure when system scanning is enabled.
