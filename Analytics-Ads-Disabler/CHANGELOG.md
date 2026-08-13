

- **Fixed duplicate membership rows introduced by the v4.9.0 snapshot.** The two `awk` programs behind the new per-package snapshot carried a newline inside a string literal, which `awk` rejects outright (`non-terminated string`). Both failed silently, the snapshot came back empty, and an empty snapshot is indistinguishable from "this package has no memberships" — so every reconciliation appended its rows again. Reproduced deterministically on device (3 → 6 → 9 rows for one package) and fixed by using `print` with concatenation, which needs no escape at all.
- The snapshot is now trusted **only when the query actually succeeded**. A failed query falls back to the original per-component lookups and logs `SNAPSHOT-FALLBACK`, so a broken query can never again be mistaken for an empty result.
- **Existing damaged databases heal themselves.** The stale-record pass already rewrites the membership file, so it now collapses identical rows and reports `MEMBERSHIP-DEDUP`. Verified on device: 6 duplicates removed, the database settled at 489 rows / 489 unique, and a subsequent full reconciliation of all 168 packages added none.

Final measurements on the test device (OnePlus, 168 packages/users, AGGRESSIVE + HYBRID):

| Boot | Policy reconciliation |
|---|---|
| Full verification | 195 s |
| Unchanged, fast path | 23 s (`package_reconcile_ms=40`) |

The IFW ruleset produced by the fast path is byte-identical to the full scan (`activity=219 receiver=55 service=76 total=350`), confirming the audit carry-over loses nothing.

Boot cost and lock correctness, driven by measurements taken on device rather than assumptions.

`acquire_lock` trusted `kill -0` alone. A lock directory survives a reboot, and after a reboot the recorded PID is very likely reused — on the test device the stale owner PID had become the LSPosed daemon, so the lock looked held, the boot scan waited out its 60-second timeout and skipped itself. This happened on **two consecutive boots** before it was noticed, and it was only visible at all because v4.7.0 made `full_rescan` report its real exit code.

- Lock ownership is now keyed on PID **and** process start time, matching what the firewall and surface-index locks already did. A lock with no recorded start time is treated as stale, which also migrates old locks safely.
- `aad_db_lock` got the same treatment, and both locks are created with `umask 077` (they were world-writable).
- `service.sh` removes every lock directory at boot: nothing the module started before a reboot can still be running.

Measured first, then optimised. `dumpsys package <pkg>` turned out to cost only **67 ms** (11 s for 168 packages), so the "one big dump" idea was dropped — it would have saved about six seconds for a lot of risk. The real cost is **process spawns**: each per-component `awk` pass measured 18–22 ms, and a reconciliation performs several per component. The equivalent shell-native check costs 1.4 ms.

- **Unchanged packages are skipped.** A package whose versionCode and the full policy fingerprint (settings + rules + whitelists) match the last verified run is left alone; component states persist across reboots, so re-proving them is pure cost. A full verification still runs at least once every 24 hours (`AAD_FULL_VERIFY_MAX_AGE`) so external changes — another app manager, a ROM update — cannot hide indefinitely, and any package whose versionCode changes is dropped from the verified set immediately.
- Audit and SDK-fingerprint rows for skipped packages are carried over in a single pass. Without this the IFW builder and the surface indexer would see an incomplete picture and the IFW ruleset would silently shrink.
- **Per-package snapshots replace per-component subprocesses.** Membership rows and the explicit component states for the package being reconciled are loaded once into shell memory; the hot "already disabled" path then costs no spawns at all.
- `ALREADY-DISABLED` is now one line per package with a count instead of one line per component — on a reboot nearly every component took that path, and each line cost a `date(1)` spawn.
- New `SCAN-EFFICIENCY` log line reports how many packages were reconciled versus skipped.

The indexer re-ran on every boot and mostly re-read a cache that already held every answer (observed: `cache_full_hit=379` of 379 APKs, roughly four minutes of work for no new information). It now fingerprints its inputs — every user/package/versionCode plus the surface rule hash — and skips the traversal entirely when the last *completed* index used the same inputs. Killer targets are persistent, so nothing downstream is lost. `AAD_SURFACE_FORCE=1` overrides.

The boot reconciliation now runs at `nice 19` and idle I/O priority. This does not reduce the work, it stops the work from competing with the system's own boot activity — the device stays responsive while it happens.

Two gaps in newly-installed-app handling, both found by installing real APKs on two devices and timing the response.

- **A package installed while a scan holds the lock is no longer dropped.** `rescan_changed_packages` gave up after the 60-second lock timeout and logged a single line, so the app stayed unhandled until the safety poll — up to 15 minutes with the inotify watcher active. The request is now recorded in `.package_rescan.pending` and the polling watcher consumes it on its next cycle (~10s).
- **A package installed while the boot scan is running is no longer invisible.** The `/data/app` watcher only starts *after* the boot reconciliation, and the boot scan works from a snapshot taken before it began, so an app installed in that window produced no event and was absent from the baseline. A single delta pass now runs right after the boot scan closes that window.

Measured on device: an app installed at 00:54:55 during a boot scan was reconciled at 00:58:12, immediately after the scan finished, instead of waiting for the 15-minute poll.

- **Fresh installs get manifest-based Activity discovery again.** The incremental path never built the `list packages -f` inventory that the full scan uses, and relied on the per-package `cmd package path` query — which is least reliable exactly for a just-installed package, where PackageManager publishes it to `list packages` before the path query answers. The result was a single `MANIFEST-PATH-MISS` and silently skipped AXML discovery, so in AGGRESSIVE the new app's exact ad Activities stayed unblocked until the next full scan. The delta path now builds the same authoritative inventory and enables the manifest cache, keyed by the package's versionCode like the full scan.

Observed response time for a new install with the realtime watcher running (measured on a POCO X3 Pro): component policy applied about 25 seconds after install completes, IFW rules about 60 seconds, network Killer targets and the surface index re-run about 95 seconds. The Killer only gains rules for the new app after the *next* complete surface traversal, since targets are committed from a finished index only.

- **Rebuild without a UTF-8 BOM in `module.prop`.** The v4.8.2 artifact was packaged with a BOM at the start of the file, which made the root manager read the module id as `analytics_ads_disabler` and install a *second* module directory instead of upgrading the existing one — two copies of the runtime would then compete for the same state directory. Only the packaged artifact was affected, not the module logic. The build now verifies that no shipped file carries a BOM or CRLF line endings before packaging.

Verified on a second device (POCO X3 Pro / vayu, Android 16 API 36 on a custom ROM, kernel 4.14, KernelSU 3.3.0), upgrading from v4.2.5 — six releases back:

- **Rule merge across a very old baseline works.** All fifteen sections were added and entries merged: 69 network hosts and 9 push-risk entries reached a `rules.conf` that predates all of them, and `onesignal` was removed from the auto-disabled `[ANALYTICS]` section.
- **OEM protection resolves per vendor.** On this Xiaomi/POCO device `com.xiaomi.xmsf`, `com.miui.home` and `com.miui.securitycenter` are protected while the Samsung entries correctly are not.
- **Xposed bridge activates on detection.** With LSPosed present the completed index exported 7 targets; the JSON is well-formed and one game was found bundling twelve advertising SDKs.
- **Kernel capability probing.** Kernel 4.14 supports both `xt_owner` and `xt_string`, and `iptables-restore` is present, so the Killer would use `string` mode here; it correctly stayed `DISABLED` because the device runs in `SAFE`, where the network layer is not applied.
- Boot reconciliation: 33 packages/users, 53 operations, 15 seconds.

Found and fixed by installing on a real device (OnePlus PJA110, Android 16 / API 36, KernelSU 3.3.0, upgrading from 4.6.17).

Expanding coverage from 3 to 17 SDKs raised the live ruleset from 135 to 783 rules per family on the test device, which exposed two costs that did not exist at the old size:

- **Applying the ruleset took 3 minutes 5 seconds** — one `iptables` process per rule, about 1600 invocations, and the chain was half-built for most of that time. Rules are now generated as a single `iptables-restore -n` transaction: the same 783 rules per family commit in about one second, atomically. The per-rule cascade remains as a fallback when `iptables-restore` is unavailable or rejects the ruleset.
- **Every outgoing packet walked all 783 rules** just to evaluate the owner match. Rules are now grouped into one sub-chain per UID (`AAD_ADKILL_<uid>`), so the parent chain holds one jump per targeted UID and a packet is compared against ~54 owner matches plus only its own app's host rules — a 14x reduction in per-packet work at the same coverage.
- Chain cleanup removes the per-UID sub-chains as well, flushing before deleting so a chain still referenced by the parent cannot leak.
- `REJECT --reject-with tcp-reset` support is probed once up front, because a batch transaction is all-or-nothing; the ruleset falls back to `DROP` where REJECT is unavailable.

Verified on device: 54 sub-chains, 783 rules per family, parent chain 54 rules, IPv4 and IPv6 both applied, and an end-to-end test where the targeted host returns `Connection reset by peer` while a control host on the same UID is unaffected.

With the wider host map, 801 targets collapsed to 783 unique `(uid, host)` pairs: 18 duplicate rules per family that the previous release would have installed, caused by apps matching both the classic and Next-generation Google Mobile Ads SDK labels which share hostnames.

- `printf --` inside the rule generator was shell `printf(1)` syntax; in awk `--` parses as the decrement operator and made the program a syntax error. Caught by a generator unit test before shipping.
- QUIC opt-in rules now use chain availability rather than the flag that batch mode clears, so `AD_KILLER_FORCE_TCP=1` still works after a batch commit.

Two v4.7.0 findings turned out to be less severe than stated, and the honest version is:

- The `unzip -Z1` bug is real — toybox rejects the option, confirmed on device — but on KernelSU the BusyBox fallback is reachable through PATH, so surface indexing kept working there. The fix matters for setups where BusyBox is not on PATH, not for every device.
- Duplicate firewall rules were latent, not active, at the old 3-SDK coverage: the device showed 135 targets and 135 unique pairs. They only materialise with the wider host map shipped in 4.8.0.

- **Fixed the upgrade path for rule content, found by testing a real 4.6.17 -> 4.8.0 upgrade on device.** The installer only ever added whole sections that were *missing*, so new entries shipped inside sections that already existed never reached upgrading users: an existing install kept 6 network hosts and 8 aggressive providers while the module reported the new version. Rules are now merged entry-by-entry, and the entries are read from the shipped `rules.conf` itself, so future rule additions propagate automatically instead of needing a hardcoded migration list per release. Replaces the previous hardcoded Activity merge lists. A rule the user deliberately deleted is re-added, which is the contract the Activity merge already had.
- Stale `.ad_surface_scan.running.*` work files are removed when the indexer starts. A worker killed before its EXIT trap ran left ~200 KiB behind each time; three had accumulated on the test device.
- Section parsing in the installer no longer depends on backslash escapes surviving the edit path (`[^[:print:]]`/`[[:space:]]` instead of `
`/`	`), verified against a CRLF-edited rules file.

- `[ADS_NETWORK_HOST]` grew from 6 host rules covering 3 SDKs to **69 rules covering 17 SDKs** — every advertising SDK for which the Surface Indexer can detect a BANNER/MREC/NATIVE/APP_OPEN surface now has matching hostnames: Google Mobile Ads (classic and Next), Yandex, AppLovin MAX, Unity Ads, LevelPlay/ironSource (current and legacy), Meta Audience Network, InMobi, Pangle/TikTok, Vungle/Liftoff, MBridge/Mintegral, myTarget, BidMachine, Chartboost, Start.io, Smaato. Previously the Killer could act on roughly a sixth of what the indexer detected.
- Where possible the list targets **init/config/auction endpoints rather than creative CDNs** (for example `config.unityads.unity3d.com`, `init.supersonicads.com`, `configure.rayjump.com`): blocking those prevents the SDK from initialising at all instead of blocking one creative after the request was already made.
- The section now documents its own safety model: a wrong hostname is harmless because it simply never matches, but a hostname that also carries non-advertising traffic is dangerous because the rule applies to the whole app UID. `an.facebook.com` is listed for Meta Audience Network while `graph.facebook.com` is deliberately excluded — blocking it would break Facebook Login and every Graph API call in the host app.
- Bigo Ads is intentionally left with a documented gap rather than guessed hostnames; its component-level blocking is unaffected.
- Every host label was cross-checked against the surface fingerprint labels, so there are no dead entries that could never join.

- `[ADS_PROVIDER_AGGRESSIVE]` extended from 8 to 16 exact providers plus one namespace-scoped pattern. Ad SDKs are bootstrapped by a ContentProvider that Android instantiates *before* `Application.onCreate()`, so removing the provider usually stops the SDK from initialising at all — no banner is ever requested. This is cheaper and more reliable than blocking the request afterwards, and it was the most under-used lever in the module.
- Added exact providers for Pangle (`TTMultiProvider`, `TTFileProvider`), Unity Ads, AppLovin, Chartboost, Smaato, Start.io and Tapjoy.
- Added a catch-all regex restricted to known advertising namespaces and anchored on `/` so it matches the component class:
  `re:/(com[.](applovin|unity3d|ironsource|vungle|mbridge|...)|io[.]bidmachine|sg[.]bigo[.]ads)[.][a-z0-9_.$]*(initprovider|initializeprovider|lifecycleprovider)$`
  It covers init/lifecycle providers of SDK versions that ship class names this list does not know yet, while being structurally unable to reach `FirebaseInitProvider`, `SentryInitProvider`, `androidx.startup.InitializationProvider` or any non-advertising provider. Verified against 18 positive and negative cases.
- Providers are still AGGRESSIVE-only and remain bounded by `MAX_AGGRESSIVE_ADS_MATCHES`; ambiguous analytics-init providers stay report-only as before.

- Component and network blocking both act *around* the ad: the in-app view hierarchy still reserves the banner slot, so an empty gap remains where the ad was. Only an in-process hook can remove that. **This module still hooks nothing.** When an Xposed-family framework is present it now publishes the completed Ad Surface evidence so a companion Xposed module can consume an exact per-package target list instead of re-implementing DEX discovery.
- Detects LSPosed (Zygisk and Riru variants), LSPatch, EdXposed and classic Xposed.
- After a *completed* surface traversal writes `xposed_targets.json` (schema 1: user, package, SDKs, surfaces, strongest confidence) and a shell-friendly `xposed_targets.list`, both mode 640. A partial or crashed index never publishes targets.
- Controlled by `XPOSED_BRIDGE=auto|1|0`; `auto` exports only when a framework is detected and removes the files when it disappears. Detection is reported by the installer and in the Action.

- **State DB is no longer destroyed by a PackageManager hiccup.** `cleanup_stale_records` treated an empty package enumeration as "every managed package was uninstalled" and wiped both `disabled_components.list` and `component_state.list`, leaving every component disabled with no saved override to roll back to. An empty snapshot is now recognised as a PM failure and the databases are left untouched (`STALE-SKIP`). The same fail-safe was added to the package-state baseline in the full and incremental scans.
- **Uninstall can now actually restore component states.** Root managers execute `uninstall.sh` in post-fs-data, where PackageManager does not exist, so every restore failed and the following `rm -rf` destroyed the saved states permanently. Rollback is now two-phase: if the system is booted it restores inline; otherwise it copies the saved state plus `compat.sh` to `/data/adb/analytics_ads_disabler_rollback`, arms a small self-deleting helper module, waits for `sys.boot_completed` and then performs the exact same rollback. State is retained for a retry if anything fails.
- **`full_rescan()` returned the exit code of `release_lock` (always 0)** instead of the scan result. Boot scans recorded config hashes after failures, and the Action fail-fast summary was unreachable. The inner code is now propagated.
- **Ad Surface indexing silently found nothing on stock ROMs.** `apk_list_entries_readonly` opened with `unzip -Z1`, an Info-ZIP/zipinfo extension that neither toybox nor BusyBox implements, so the branch could never succeed; without BusyBox on PATH entry discovery returned nothing, DEX/layout counts were 0 and the Network Killer stayed in `WAITING` forever. Listing now uses `-l` (supported by all three implementations) with a shared parser, and entry extraction falls back to per-entry unzip when a toybox build does not expand globs.
- **The membership DB is written under its lock during stale cleanup**, matching every other mutator, and state records are dropped only after the membership commit succeeds.
- **`manifest_class_strings` could not report a missing `od`.** The `if ... fi | awk` construct runs its left side in a subshell, so the `return 1` never left the function and awk overwrote the failure marker with a bogus `text-fallback` record. The backend is now decided before the pipeline.

- **Explicit BusyBox resolution.** Workers are spawned through their own `#!/system/bin/sh` shebang and therefore never inherited the root manager's BusyBox standalone mode; stock Android below API 34 ships no `awk`/`strings` at all, and `inotifyd`/`timeout` are BusyBox-only everywhere. BusyBox is now located by absolute path (Magisk, KernelSU, KernelSU Next, APatch, busybox-ndk, system) and its applets are exposed through an appended PATH, so system binaries keep priority and every existing fallback branch becomes real instead of decorative. All ad-hoc `command -v busybox` call sites go through one helper. The resolved toolchain is logged at boot and shown in the Action.
- `cap_runcon_bin` no longer looks only at KernelSU's BusyBox.
- **Bounded `sys.boot_completed` wait** (15 min). Builds that never publish the property previously left the module hanging forever with no log.
- **OEM-critical package protection** for Xiaomi/HyperOS, Samsung, OPPO/realme/OnePlus, vivo/iQOO, Huawei/Honor, Motorola and Transsion shells (push transports, launchers, IMEs), selected from `ro.product.*`. Relevant when `SCAN_SYSTEM_APPS=1` is opted into.
- **Volume-key prompts are bounded** in both the installer and the Action; without `timeout` a blocking `getevent` could hang them indefinitely.
- `cap_backend_verb_has_user` actually probes the backend help text instead of returning success whenever `cmd` or `pm` existed, which had made all `--user`-less handling dead code. Capability profile bumped to 13.
- `/proc/<pid>/stat` starttime parsing no longer breaks when `comm` contains spaces.

- **Duplicate rules eliminated.** Several SDK labels legitimately map to one hostname (classic and Next-generation Google Mobile Ads), so a matching app emitted byte-identical duplicate rules into a chain traversed for every outgoing packet. Rules are now deduplicated per `(uid, host)`.
- **New `ip` mode.** TLS-SNI matching needs `CONFIG_NETFILTER_XT_MATCH_STRING`, which many GKI kernels omit — on those devices the Killer could never activate. `AD_KILLER_MODE=auto|string|ip` plus `AD_KILLER_IP_FALLBACK` enforce resolved ad-host addresses per app UID using only `xt_owner`, which is universally available. Off by default because a shared CDN address can affect other traffic from that app.
- **Precise unavailability reporting.** `xt_owner` and `xt_string` are probed separately, so the log names the missing kernel feature instead of one opaque `iptables_string_owner=no`.
- **Chain liveness check.** netd rebuilds filter chains on connectivity/VPN/tethering changes and could drop the OUTPUT jump while the module still reported `ACTIVE`; the polling watcher now detects this and re-applies.
- **Configurable evidence threshold** via `AD_KILLER_MIN_CONFIDENCE` (`CAPABILITY` default, `LAYOUT_CONFIRMED`, `MULTI_EVIDENCE`). Note that raising it narrows the Killer to banner-style surfaces, since APP_OPEN and most NATIVE loaders cannot produce layout evidence.
- `ad_killer.log` keeps one previous generation instead of being truncated on every reconciliation.

- **PackageManager dump cache.** `dumpsys package <pkg>` returns tens to hundreds of KiB and was executed once per component for state reads, post-write verification and candidate discovery — dozens of identical Binder dumps per package. It is now cached for the package being reconciled and invalidated immediately after any state write, so verification never reads a stale snapshot.
- **Delta reconciliation is no longer quadratic.** Audit and fingerprint rows for all affected packages are stripped in one pass instead of rewriting the whole log per package.
- **Log mirroring is change-driven**, default interval 60s instead of an unconditional copy of every log every 10 seconds around the clock, and is configurable via `LOG_MIRROR*`.
- **App-install events are debounced.** A single APK install emits a burst of `/data/app` events, each of which used to spawn a full package rescan that then queued on the global lock; the burst is now coalesced into one reconciliation.

- **Push-capable SDKs no longer break notifications.** `onesignal`, `braze`/`appboy` were in the auto-disabled `[ANALYTICS]` list even in SAFE mode, silently killing real user notifications in apps that use them for delivery. They moved to the new report-only `[ANALYTICS_PUSH_RISK]` section (extended with Pushwoosh, Airship, CleverTap, Customer.io), which acts only with `BLOCK_PUSH_SDK=1`. Existing `rules.conf` files are migrated on upgrade.
- **Literal rules match the component class, not `package/class`.** A rule such as `applovin` or `sentry` previously also matched every component of any package whose own name contained that substring. Regex (`re:`) rules still see the full component name, so anchored patterns are unaffected.
- Package-level inventories (`component_audit.log`, `sdk_fingerprint.log`, `manifest_scan.log`, `ad_surface_scan.log`) are no longer mirrored to world-readable `/sdcard` unless `LOG_MIRROR_FULL=1`.

- Removed dead code: `dex_java_class_tokens` (defined twice, called never), `resource_java_class_tokens`, `surface_rule_hits_fallback`, `aad_manifest_cache_prepare_prefix`, `package_installed_for_user`, `ad_killer_probe_family`, and the `category_watch.sh` wrapper that nothing launched.
- Version-pinned cache migration checksums are marked with a removal TODO.

- Fix cache invalidation boundaries: Ad Surface cache now hashes only semantic surface fingerprint/View rules and ignores comments/network-host rules; Manifest verified cache hashes only Activity exact/audit sections.
- Adds in-place migration for valid v4.6.15/v4.6.16 cache signatures, avoiding needless DEX/layout or manifest re-verification after installing the network Killer.
- Surface index output is now last-known-good/atomic: a running traversal writes to a temporary file and replaces `ad_surface_scan.log` only after `SUMMARY`; failed partial output is kept separately as `ad_surface_scan.log.failed`.
- A newly installed network Killer can bootstrap targets from an already completed last-known-good surface log before starting a fresh background index.
- Keeps v4.6.16 recycled-PID lock safety and Banner/Native/App-Open Network Killer behavior unchanged.

- Fixed a recycled-PID stale-lock race in the background Ad Surface worker. A lock owner is now trusted only when the PID is alive **and** `/proc/<pid>/cmdline` still identifies `ad_surface_indexer.sh`; a reused PID is logged as stale and the lock is removed instead of falsely skipping the new worker.
- Extended recycled-PID safety to installer worker shutdown, and added a separate firewall reconciliation lock keyed by PID plus `/proc/<pid>/stat` starttime so concurrent surface/config/package reconciles cannot flush/rebuild `AAD_ADKILL` at the same time.
- Added **Banner / Native / App-Open Network Killer v1** for `AGGRESSIVE` mode. Completed Ad Surface evidence is joined with exact per-SDK advertising host rules, then enforced per installed package UID through the module-owned `AAD_ADKILL` OUTPUT chain. SAFE/BALANCED and `BLOCK_ADS=0` remove the network chain.
- Initial exact host map covers Google Mobile Ads (`googleads.g.doubleclick.net`, `pubads.g.doubleclick.net`), Yandex Mobile Ads (`mobile.yandexadexchange.net`), and AppLovin MAX (`ms.applovin.com`). Rules are data-driven via `[ADS_NETWORK_HOST]` so later SDKs can be added without rewriting the engine.
- Network targets persist as `user|package|sdk|host`, never as UID. UID is resolved fresh from PackageManager on every reconciliation, preventing a stale/reused UID from transferring a rule to another app. Global/ADS whitelists and protected packages are applied both when targets are committed and when firewall rules are reconciled.
- `AD_SURFACE_KILLER=1` enables the network layer only under `AGGRESSIVE`; `AD_KILLER_FORCE_TCP=0` is the safe default. Optional FORCE_TCP rejects UDP/443 for targeted UIDs to reduce QUIC bypass, but is explicit opt-in because it affects all QUIC for those apps.
- Action treats FORCE_TCP as a risky opt-in too: **VOL+ = NO (safe default)** and **VOL- = YES (explicit opt-in)**.
- The Killer is fail-open. If `iptables`/`ip6tables` owner+string matching is unavailable, PM/IFW policy continues unchanged and the network chain is removed rather than partially trusted. IPv4 and IPv6 are probed independently.
- Added `ad_killer.log`, `ad_killer.status`, persistent `ad_killer_targets.list`, Action controls/status, boot/package/config re-reconciliation, uninstall cleanup, and read-only deep diagnostics for the owned firewall chain.
- Surface targets are committed only after a complete index traversal. A partial/crashed index keeps the previous known-good target set. Existing `surface4` cache is retained.
- HTTPS hostname rules are intentionally limited to TCP/443 in v1. Plain HTTP is not modified.
- No changes to PM disable transport, exact-state rollback, IFW component policy, Android 16 compatibility profile, or component safety caps.

- Made the installer system-app choice fail-safe. `Scan SYSTEM apps too?` now uses **VOL+ = NO (safe default)** and **VOL- = YES (explicit opt-in)**, so repeatedly confirming normal choices with VOL+ can no longer accidentally include system apps. Timeout or unavailable `getevent` also keeps system apps excluded.
- Upgrade safety follows the same rule: if preserved settings already have `SCAN_SYSTEM_APPS=1`, the installer warns and requires **VOL- explicit opt-in** to keep it enabled; VOL+ changes only that risky setting back to `0` while preserving the rest.
- Fixed Ad Surface Index wall-clock telemetry. Per-APK scanning no longer overwrites the indexer's start timestamp, so `AD-SURFACE-PROGRESS elapsed_ms`, `index_ms`, and final elapsed time now measure the whole background index instead of the most recent APK.
- Added explicit `AD-SURFACE-TRAVERSAL-COMPLETE` before final aggregation.
- Added persistent `/data/adb/analytics_ads_disabler/ad_surface_index.status` with `RUNNING`, `COMPLETE`, `FAILED`, or `SKIPPED`, progress counters, PID, timestamps, exit code and failure reason where applicable.
- `ad_surface_scan.log` now gets terminal `STATUS` / `SUMMARY` records in the same 13-column schema. A completed scan can therefore be identified from that file alone; `debug.log` still receives the human-readable summary.
- Signal/unexpected-exit handling now records a terminal FAILED state before cleaning the worker PID/lock, eliminating silent disappearance of a surface worker.
- No changes to surface fingerprints, PM/IFW policy, exact rollback, whitelists, Android 16 transport, or cache schema (`surface4`).

- Fixed Android `mksh` parsing of surface stat pairs. Pipe-delimited `N|M` values are now read with `IFS='|' read` instead of ksh pattern expansion, so `ad_surface_scan.log` keeps the documented 13-column schema and numeric `dex_files/dex_matches/layout_files/layout_matches`.
- Fixed `Argument list too long` (`E2BIG`) in the background surface worker. DEX/layout entry counts are streamed directly through `awk`; thousands of `res/layout*` paths are never materialized into one `printf` argument.
- Replaced binary multi-pattern `grep -o -f` DEX enumeration after real-device v4.6.13 showed incomplete hit sets on unchanged APKs. DEX is decompressed once, converted to printable strings when a certified `strings` backend is available, then every configured fingerprint is verified independently with a single-pattern fixed-string check.
- Added an all-rules backend self-test: a strings backend is accepted only when it recovers every active DEX fingerprint from a NUL-separated probe. System and BusyBox `strings` are measured; otherwise the worker falls back to deterministic direct matching against one extracted DEX blob.
- RESOURCE View matching is also exact-per-pattern, retaining strict `CAPABILITY` / `LAYOUT_CONFIRMED` / `MULTI_EVIDENCE` semantics without relying on multi-pattern binary grep behavior.
- Surface cache schema advances to `surface4`; v4.6.13 `surface3` sidecars are discarded so incomplete DEX results cannot be reused. Full Manifest cache and PM/IFW policy are untouched.
- Added `AD-SURFACE-PROGRESS` telemetry every 10 package/users and expanded matcher telemetry with DEX backend, all-pattern self-test result, strings timing, and exact-grep backend.
- No new banner/native/app-open blocking is enabled yet. v4.6.14 remains a diagnostic surface-index reliability release; existing exact fullscreen PM+IFW policy, rollback, whitelists and Android 16 transport are unchanged.

- Moved Ad Surface discovery completely out of the critical PM/IFW policy reconciliation path. Boot/full rescans now finish policy first; `ad_surface_indexer.sh` runs read-only DEX/resource indexing afterward in its own worker/lock.
- Added priority indexing: packages already present in ADS component audit or SDK fingerprints are scanned first, then the remaining installed apps. New/updated packages and successful config/Action rescans can trigger a cached background refresh without blocking policy.
- Added adaptive grep backend benchmarking. System grep and BusyBox grep are both function-tested and timed against the active fingerprint set; the faster valid backend is selected for the index run and telemetry records both timings.
- Added strict `[ADS_SURFACE_RESOURCE_VIEW]` rules. RESOURCE evidence is now limited to known View/ViewGroup-style ad containers; loaders, requests and generic ad objects remain DEX-only.
- Added evidence confidence to `ad_surface_scan.log`: `CAPABILITY`, `LAYOUT_CONFIRMED`, and `MULTI_EVIDENCE`.
- Surface cache advances to `surface3` sidecars so v4.6.12 RESOURCE results cannot be reused under the stricter evidence model. Full Manifest cache remains untouched.
- Main `TIMING-SUMMARY` no longer includes diagnostic surface-index cost; the background worker emits its own `AD-SURFACE-SUMMARY` and elapsed time.
- No PM/IFW policy expansion. Banner/native/app-open detection remains diagnostic-only in v4.6.13; exact fullscreen policy, rollback, Android 16 transport, whitelists and safety caps are unchanged.

- Reworked Ad Surface Scanner DEX discovery from full class-token extraction to a targeted single-pass fixed-string matcher. The scanner now searches only configured ad-surface fingerprints directly in the DEX stream instead of extracting/sorting tens of thousands of unrelated Java type descriptors.
- Added a runtime grep capability probe (`grep` / BusyBox grep) for `-aFo -f`; the slower token extractor is retained only as a compatibility fallback for unusual OEM toolsets.
- Layout discovery is still gated by a banner/native-capable DEX hit and now uses the same targeted matcher for UTF-8 and NUL-stripped UTF-16 compiled layout evidence.
- Surface cache schema moves to compact `surface2` sidecars: unchanged APK + unchanged surface rules = `FULL_HIT`; changed surface rules = `RULE_RESCAN`; changed APK = `MISS`. Large cached DEX token lists are no longer created.
- `ad_surface_scan.log` APK records now report `dex_matches` and `layout_matches` rather than counts of every unrelated class token. `AD-SURFACE-SUMMARY` reports `cache_rule_rescan`.
- No PM/IFW policy expansion: banner/native/app-open evidence remains diagnostic only. Exact rollback, Android 16 transport, whitelists, Full Activity Scanner and AGGRESSIVE component rules are unchanged.

- Added diagnostic Ad Surface Scanner for BANNER/BANNER_MREC/MREC/NATIVE/APP_OPEN/INTERSTITIAL/REWARDED/REWARDED_INTERSTITIAL/SPLASH/VIDEO capabilities using DEX and compiled resource evidence.
- Added data-driven `[ADS_SURFACE_FINGERPRINT]` rules and `logs/ad_surface_scan.log`; surface evidence never grants component-disable permission.
- Added per-phase timing telemetry and clarified Full Manifest cache metrics (`apks_seen`, `apks_processed`, `apks_parsed`).
- Extended persistent cache to surface discovery. v4.6.11 stored full DEX token lists; v4.6.12 supersedes that implementation with targeted matching for performance.

- Added a persistent Full Manifest Scanner cache under `/data/adb/analytics_ads_disabler/manifest_cache/v1`.
- Cache identity uses Android user, package, package versionCode, concrete APK path, file size and mtime. An updated/replaced APK automatically misses the cache and is parsed again.
- Parsed manifest class tokens are cached independently from rule results. If `rules.conf` changes, the expensive APK extraction/AXML parse is reused while rule matching and PackageManager verification are recomputed (`PARSE_HIT`).
- If both APK identity and rules are unchanged, previously verified manifest Activity results are reused (`FULL_HIT`) without repeated unzip/AXML parsing or hundreds of read-only PM verification calls.
- `manifest_scan.log` adds a `cache` column (`MISS`, `PARSE_HIT`, `FULL_HIT`, `BYPASS`) and `MANIFEST-SUMMARY` reports cache hit/miss counts.
- Cache is an optimization only: realtime install/update handling remains fresh, rules changes invalidate verified hit results, and existing PM/IFW policy, exact rollback, whitelists and safety caps are unchanged.

- Fixed category safety semantics: exceeding a safety cap now freezes existing memberships instead of silently removing the category from desired state and restoring previously blocked components.
- Added a separate AGGRESSIVE ADS cap, `MAX_AGGRESSIVE_ADS_MATCHES=64`; SAFE/BALANCED and ANALYTICS keep the conservative `MAX_MATCHES_PER_CATEGORY=15` behavior.
- Added a separate AGGRESSIVE IFW Activity cap, `MAX_AGGRESSIVE_IFW_ACTIVITIES_PER_CATEGORY=64`; non-AGGRESSIVE modes keep the existing limit of 5.
- Expanded the exact AGGRESSIVE fullscreen/reward/interstitial Activity allowlist using verified v4.6.8 Full Manifest Scanner evidence: current AppLovin, myTarget, Vungle/Liftoff, MBridge, InMobi, Fyber, BidMachine, Bigo, Pangle/TikTok and several ad-only SDK Activity variants.
- Debugger/test/browser-only SDK Activities remain audit-only unless explicitly promoted to the exact allowlist.
- No changes to PM transport, exact rollback, whitelist semantics, Android 16 FD isolation, or SAFE/BALANCED matching policy.

- Fixed a wiring failure where Full Manifest Scanner could finish with `packages/users=0 apks=0` while the main scan processed packages normally.
- Added a second APK-path source: per-user `list packages -f` inventory, with automatic base-directory split APK expansion.
- `cmd/pm package path` remains the first source; inventory is an independent fallback for OEM PackageManager quirks.
- Manifest diagnostics no longer fail silently: `path-miss`, `path-inaccessible`, and `extract-failed` are recorded explicitly.
- `MANIFEST-SUMMARY` now distinguishes APKs seen/scanned and path/extraction failures.
- No changes to SAFE/BALANCED policy, PM transport, rollback, whitelists, or Android 16 write handling.

- Replaced heuristic manifest string extraction with a format-aware Android binary XML StringPool parser. Supports both encodings defined by AXML: UTF-8 (`UTF8_FLAG`) and UTF-16, including variable-length string lengths; plain XML gets a fallback path.
- Removed runtime dependence on an optional standalone `strings` command for Full Activity discovery.
- Added `logs/manifest_scan.log` and `MANIFEST-SUMMARY` telemetry (APK count, encoding, string/class-token counts, exact/audit fullscreen hits, PM verification and misses).
- Added interactive Action settings. VOL+ within five seconds opens configuration; otherwise Action behaves as before and starts a rescan. Settings are written atomically and applied immediately without reinstall.
- Existing realtime `settings.conf` editing remains supported.
- No broad Activity names are auto-disabled: AGGRESSIVE still mutates exact allowlisted fullscreen ad Activities only.

- AGGRESSIVE/HYBRID больше не ограничиваются Activity Resolver Table: scanner дополнительно читает `AndroidManifest.xml` из base/split APK и проверяет найденные Activity через PackageManager с `MATCH_DISABLED_COMPONENTS`. Это закрывает explicit/no-intent-filter Activity, которые не попадали в прежний resolver-аудит.
- Добавлен точный allowlist полноэкранных рекламных Activity для Google Mobile Ads, Yandex Mobile Ads, AppLovin/MAX, Unity Ads, LevelPlay/ironSource, Vungle/Liftoff, MBridge/Mintegral, Chartboost, Meta Audience Network, Start.io и Huawei Ads.
- Широкие namespace (`Pangle`, `InMobi`, `Bigo`, `myTarget`, `Fyber`, `Tapjoy`, `Smaato`, `BidMachine` и др.) используются только для discovery/audit и сами по себе ничего не отключают.
- Добавлен `sdk_fingerprint.log`: по каждому пакету фиксируется обнаруженный рекламный SDK и manifest/component evidence без изменения состояния.
- В `AGGRESSIVE + PM` exact fullscreen Activity отключаются PackageManager. В `AGGRESSIVE + HYBRID` они получают двойной слой: PM disable + собственный IFW. SAFE/BALANCED не получают новый PM Activity-блокинг.
- Upgrade migration добавляет новые exact Activity и безопасные audit-only сигнатуры в persistent `rules.conf` без перезаписи пользовательских правил.
- Сохранены exact-state rollback, whitelist semantics, Android 16 FD isolation, fail-fast и multi-user IFW safety.

- Добавлен отдельный `COMPONENT_MODE=AGGRESSIVE`; существующие `SAFE` и `BALANCED` не меняют поведение.
- AGGRESSIVE наследует BALANCED и дополнительно отключает только точные рекламные Provider-компоненты из отдельного allowlist (`Vungle`, `LevelPlay`, `MBridge`, `InMobi`, альтернативный Yandex Ads initializer и др.).
- При backend `PM` AGGRESSIVE может отключать только точные рекламные Activity из существующего `ADS_ACTIVITY_IFW`; при `HYBRID` они, как и раньше, блокируются через IFW.
- Неоднозначные analytics-init Provider (`FirebaseInitProvider`, `FacebookInitProvider`, `Sentry` и др.) намеренно остаются `REPORT_ONLY` даже в AGGRESSIVE.
- Audit-summary теперь отдельно показывает `aggressive=N`. Exact original-state rollback, whitelist semantics, PM transport и multi-user IFW safety не изменены.

- PM `runcon_shell_uid0` теперь перед SELinux-переходом в дочернем процессе закрывает только унаследованные fd, указывающие в `/data/adb/analytics_ads_disabler` или каталог модуля. Это обобщает фиксы `.desired.tmp`/`component_state.list.orphans.*` без расширения sepolicy и без изменения parent shell.
- Рабочий OEM-совместимый transport `runcon u:r:shell:s0 /system/bin/sh -c "exec ..."` сохранн; direct PM, learned backend и обязательная post-state verification не менялись.
- HYBRID IFW получил multi-user safety gate: глобальное IFW-правило создатся только если все Android users, у которых установлен пакет, согласны блокировать данный компонент. Whitelist/work-profile одного user больше не может быть перекрыт решением другого user.
- При невозможности построить authoritative user/package snapshot IFW fail-closed в сторону безопасности: собственное IFW-правило не создатся, PM-состояние не расширяется.
- Атомарная запись IFW через временный файл без `.xml` и rename сохранена; это соответствует механизму AOSP Intent Firewall, который наблюдает только XML-файлы в `/data/system/ifw`.
- Default backend остатся `PM`; HYBRID по-прежнему опционален. Policy/rules/whitelist semantics и exact rollback не расширялись.

## v4.6.3 (603) — закрытие orphan FD перед PM restore

- `retry_orphan_restores()` больше не выполняет PackageManager restore из цикла, чьим входом является `component_state.list.orphans.*` в `/data/adb`.
- Snapshot orphan-state сначала считывается в память, backing-файл закрывается и удаляется, и только после этого запускаются restore-операции.
- Устраняет подтвержднный на Xiaomi 14 Ultra / HyperOS 3 / Android 16 SELinux AVC `u:r:shell:s0 -> adb_data_file` для `component_state.list.orphans.*` без расширения sepolicy.
- PM transport, IFW, SAFE/BALANCED/HYBRID, whitelist semantics, exact rollback и update-race fix v4.6.2 не изменялись.

## v4.6.2 (602) — исправление гонки обновления на HyperOS

- Процессы старой версии теперь останавливаются до изменения persistent-конфигурации и до проверки Package Manager.
- Активный boot/action-скан без watcher pid-файла также безопасно завершается, но только после проверки `/proc/<pid>/cmdline` на принадлежность модулю.
- Старые operation/state/membership locks снимаются сразу после остановки прежних watcher-процессов, поэтому установщик не запускает параллельный пересчт на частично обновлнных файлах.
- Исправление основано на диагностике Xiaomi 14 Ultra, Android 16 / HyperOS 3: во время обновления старый скан и PM-проба пересекались, вызывая `Failed transaction`, `Broken pipe` и незавершнные временные каталоги. После загрузки сама v4.4.14 работала штатно.

## v4.6.1 (601) — точность Activity-аудита

- Ложное подстрочное правило `adactivity` заменено на точное окончание класса `AdActivity`.
- `UploadActivity`, `DownloadActivity`, `NFCReadActivity` и похожие классы больше не считаются рекламными только из-за окончания имени.
- Точная Huawei Ads Activity `com.huawei.openalliance.ad.ppskit.activity.InterstitialAdActivity` добавлена в HYBRID IFW.
- Установщик мигрирует только прежнюю точную строку `adactivity` и добавляет новое правило без перезаписи остальных пользовательских правил.

## v4.6.0 (600) — PM/IFW-контур после сверки с App Manager и Blocker

- Проверены актуальные исходники `MuntashirAkon/AppManager` и `lihenggui/blocker`, включая PM, IFW и комбинированные контроллеры.
- Сохранн основной PM-контур модуля: он точнее сторонних реализаций восстанавливает исходный override и проверяет фактическое состояние после каждой операции.
- Добавлен опциональный `COMPONENT_BACKEND=HYBRID`: Services/Receivers получают второй IFW-слой, а точные рекламные Activities блокируются только через IFW.
- Providers по-прежнему изменяются только через Package Manager, поскольку Android Intent Firewall их не поддерживает.
- IFW хранится в отдельном файле `/data/system/ifw/analytics_ads_disabler.xml`, заменяется атомарно и удаляется при переходе на PM или деинсталляции.
- Добавлены проверка доступности IFW, лимит Activity на пакет/категорию и отдельные действия `IFW_BLOCK` в аудите.
- `PM` остатся безопасным backend по умолчанию; включение HYBRID выполняется явно в установщике или настройках.

## v4.5.0 (500) — типизированный аудит и режимы SAFE/BALANCED

- Сохранена универсальная capability-логика Magisk, KernelSU/Next и APatch без списков моделей и прошивок.
- `COMPONENT_MODE=SAFE` сохраняет прежнее отключение Services/Receivers и остатся режимом по умолчанию.
- `COMPONENT_MODE=BALANCED` дополнительно отключает только Providers из точных секций `*_PROVIDER_SAFE`.
- Activities и неоднозначные Providers обнаруживаются, но записываются только в `component_audit.log` без изменения состояния.
- Добавлены типизированные секции правил, миграция новых секций без перезаписи пользовательских правил и статистика `AUDIT-SUMMARY`.
- Сетевой DNS/hosts-слой не добавлялся.

- PackageManager-команды теперь всегда запускаются со stdin из `/dev/null`.
- Исправлено наследование временных файлов политики из `/data/adb/analytics_ads_disabler/.desired.tmp.*` через Binder в `system_server`.
- Устраняет `translate fd failed` и `Failed transaction` на Android 16 с KernelSU/ReSukiSU при включнном SELinux.
- Сохранены проверки реального результата операции и все прежние безопасные варианты транспорта PM.

- Restored the proven Android 16 `runcon u:r:shell:s0 /system/bin/sh -c "exec ..."` PM transport after v4.4.12 showed OEM SELinux can deny direct execution of `/system/bin/cmd`/`pm` from the transitioned shell domain.
- The shell-domain scope still contains only the PackageManager command; no module state, whitelist, rule, or scratch file under `/data/adb` is read there.
- Keeps Android 16+ real shell-UID (`su 2000` / `su shell`) component mutations excluded.
- No policy, whitelist, state-machine, watcher, or restore semantics changed.

- Preserved the proven 4.4.11 policy, whitelist delta/restore, state DB, watcher and logging behavior.
- Android 16+ no longer tries real shell UID 2000 (`su 2000` / `su shell`) for component-state mutations. Legacy candidates remain available below API 36.
- `runcon_shell_uid0` now executes `/system/bin/cmd` or `/system/bin/pm` directly in `u:r:shell:s0` while retaining uid 0; it no longer wraps PackageManager mutations in `/system/bin/sh -c`.
- Added explicit PM mutation-model diagnostics for API level, shell-UID policy and runcon availability/scope.
- Existing verified learned backends are retained; direct root remains the first compatibility baseline and every write still requires post-state verification.

- Runtime, Action, installer diagnostics, deep diagnostics, and uninstall logs now read `name`, `version`, and `versionCode` from `module.prop`.
- Removed current-release version literals from executable log/status output.
- Added a shared `MODULE_VERSION_LABEL` so changing the release version only requires updating `module.prop`.
- Historical compatibility comments remain intentionally versioned where they describe old behavior/migrations.

- Keeps v4.4.9 policy/scanner behavior unchanged; this release is log-infrastructure only.
- Adds a dedicated non-blocking log mirror worker (~10 s) from authoritative `/data/adb/.../logs` to `/sdcard/eCubz/logs/Analytics_Ads_Disabler`.
- Adds `debug.previous.log` rotation before each boot clears `debug.log`.
- Preserves `uninstall.log` externally before deleting persistent state.
- Migrates legacy pre-unified debug/diagnostic/install logs into `*.legacy.log` files when found.
- Fixes stale v4.4.5/v4.4.6/v4.4.8/v4.4.9 runtime/diagnostic labels.

- All log files (`debug.log`, `diagnostics.log`, `boot_trace.log`, `install_diagnostics.log`, `uninstall.log`) are now stored in one unified directory: `/data/adb/analytics_ads_disabler/logs/`.
- External user-accessible logs on `/sdcard` are mirrored into a single folder: `/sdcard/eCubz/logs/Analytics_Ads_Disabler/`.
- Keeps all whitelist delta snapshot performance optimizations, DB race locks, and runtime log reliability from v4.4.8.

- Whitelist delta no longer performs per-user PackageManager package-list Binder calls. It builds one authoritative `user|package` snapshot and exact-matches affected packages.
- Added `CONFIG-DELTA user=... begin/end`, package completion, snapshot-ready, and package reconcile membership diagnostics.
- Removed command-substitution around per-user delta reconciliation and switched delta scratch files to unique `mktemp` paths.
- Keeps v4.4.7 runtime-log reliability, v4.4.6 DB locking, and managed-state whitelist restore behavior.

- Runtime boot no longer depends on `/sdcard` being writable after `sys.boot_completed=1`.
- Authoritative live debug log moved to `/data/adb/analytics_ads_disabler/analytics_ads_disabler_debug.log`.
- `/sdcard/eCubz/analytics_ads_disabler_debug.log` is now a best-effort mirror after runtime becomes ready.
- Added post-common boot checkpoints to isolate state-dir, config-alias, runtime-log and capability stages.
- Preserves v4.4.6 DB race/atomic-write protections and v4.4.5 whitelist delta reconciliation.

- Stops runtime workers from the previous module version during installation/update before persistent state is mutated.
- Adds independent locks for `component_state.list` and `disabled_components.list`.
- Uses `mktemp`-based unique transactional files instead of `*.tmp.$$`, avoiding BusyBox ash/subshell PID collisions.
- State/membership commits now log explicit rewrite/commit failures instead of terminating on a missing temp file.
- Keeps v4.4.5 whitelist delta reconciliation and Android 16 installed-package snapshot fix.

- `whitelist.list`, `white_ads.list`, and `white_analytics.list` now reconcile only package names whose normalized whitelist membership changed; a one-package edit no longer triggers a full device scan.
- Global whitelist changes remove all module memberships for the affected package and restore exact saved original component states.
- ADS whitelist changes remove only ADS memberships; restoration occurs only when ANALYTICS no longer owns the same component. ANALYTICS whitelist behavior is symmetric.
- Removing a package from any whitelist is also incremental: only that package is rescanned and required memberships are re-applied.
- Fixes false `STALE ... package not installed` records on Android 16 vendor PackageManager builds by using one authoritative all-package snapshot per full scan instead of filtered package-list probes.
- Duplicate config events no longer wait 60 seconds and emit `LOCK timeout`; they log `CONFIG-DEFER` while the active reconciliation owns the lock.
- `settings.conf` or `rules.conf` changes still intentionally trigger a full policy reconciliation.

- Fixes the confusing duplicate-config layout: module-directory `settings.conf`, `rules.conf`, `whitelist.list`, `white_ads.list`, and `white_analytics.list` now alias the persistent files in `/data/adb/analytics_ads_disabler`.
- Editing config from `/data/adb/modules/analytics_ads_disabler/` or from the persistent data directory now changes the same watched file.
- Boot repairs missing/replaced config aliases and logs both runtime and alias paths.
- Realtime inotify + hash polling remain active and deduplicated.

- `service.sh` no longer sources `common.sh` before Android reports `sys.boot_completed=1`.
- Early boot uses only `/data/adb/analytics_ads_disabler/boot_trace.log`; `/sdcard/eCubz` is touched only after boot completion.
- Adds trace checkpoints for early wait, common source, capability initialization, boot scan, and runtime-ready.
- Full policy reconciliation still runs on every successful boot.
- Fixes stale v4.4.1 labels in install/deep-diagnostics output.
- Keeps realtime config inotify plus hash-poll fallback and verified PM backend persistence.

- Defers PackageManager capability probing until `sys.boot_completed=1`; `common.sh` no longer performs early Binder work when sourced by `service.sh`.
- Adds `/data/adb/analytics_ads_disabler/boot_trace.log`, written before `common.sh`, so a missing runtime log can be distinguished from an early startup failure.
- Full policy reconciliation is explicitly logged and runs on every successful Android boot (`BOOT-SCAN`).
- Verifies app-inotify, config-inotify and polling watcher PIDs one second after launch and reports `RUNNING` or `FAILED-TO-STAY-RUNNING`.
- Explicitly sets executable permission on `config_event.sh` during installation.

- Added realtime BusyBox `inotifyd` monitoring for `settings.conf`, `rules.conf`, `whitelist.list`, `white_ads.list`, and `white_analytics.list`.
- Watches the config directory for close-write/create/delete/move events so both in-place saves and editor atomic-renames are detected.
- Added `config_event.sh` with strict filename filtering; state DB/cache/hash changes cannot recursively trigger policy scans.
- Added lock-aware hash deduplication: multiple filesystem events from one save collapse into one reconciliation.
- Existing hash polling remains active as a safety net and for devices without `inotifyd`.
- Realtime config watcher has its own PID file and is stopped safely on module restart/uninstall.
- Policy/whitelist/restore behavior from v4.4.0 is unchanged.

- Kept policy decisions (system protection, global/category whitelist, ADS/ANALYTICS rules) strictly before any state-changing backend call.
- Added explicit `WHITELIST-SKIP`, `WHITELIST-RESTORE`, `POLICY-SKIP`, and `ALREADY-DISABLED` logging.
- A package added to a whitelist restores only components previously managed by this module, using the exact saved original override state.
- Restore now tries the verified learned write transport first (for example `runcon_shell_uid0`) before the generic compatibility cascade.
- Added a full restore cascade across direct, shell-UID, shell-su, and verified `runcon` transports.
- Reconciliation no longer performs redundant Binder writes for memberships that are already actually disabled.
- Existing v4.3.9 install diagnostics, learned-backend persistence, and manual Action fail-fast behavior are retained.

- Action fail-fast: stop a manual full scan after 3 consecutive components exhaust the complete disable cascade.
- A successful component operation resets the consecutive-failure counter.
- Fail-fast is Action-only; background/incremental scans keep normal behavior.
- Early abort preserves debug/diagnostic logs and does not mark the configuration hash as successfully reconciled.

- Fixes a v4.3.5/v4.3.6 logic bug that required UID 2000 and `u:r:shell:s0` simultaneously before enabling the runcon fallback.
- On tested KernelSU Next, `runcon u:r:shell:s0` correctly changes SELinux domain while retaining UID 0; this is now treated as its own execution backend (`runcon_shell_uid0`).
- The runcon backend is attempted only after the original direct cascade and `su 2000`/`su shell` fallbacks fail.
- A candidate is learned only after the real component state verifies as disabled.
- Keeps deep diagnostics and full help/Binder smoke logging from v4.3.6.

- Keeps the v4.3.4 original/direct cascade and uid-2000 fallbacks.
- Adds execution diagnostics (UID + SELinux context) to Action output.
- Adds a last-resort `runcon u:r:shell:s0` backend when a real shell-domain transition is supported.
- The new backend is accepted only after a transition probe confirms both UID 2000 and `u:r:shell:s0`.
- No package-wide suspend/hide and no direct packages.xml/service-call hacks.

- Restored the original v4.3.0 direct cmd/pm fallback cascade as the compatibility baseline.
- Added verified learned fast-path: a method is cached only after a real component reaches disabled state.
- Added `--user current` fallback only when it matches the scanned foreground Android user.
- Added shell-UID execution fallbacks (`su 2000`, `su shell`) after the complete original cascade fails.
- Every candidate is validated by the actual component override state, not exit code alone.
- Kept v4.3.3 scan dump caching and Action progress output.
- Deliberately avoids package-wide hide/suspend and unstable raw Binder transaction calls.

- Full scan caches parsed Services/Receivers once per package and reuses the result across ADS/ANALYTICS and Android users/profiles.
- Action button shows live `[current/total] user package` progress plus a final summary.
- Background scans remain quiet.

# Changelog (Журнал изменений)

- **Исправлен HyperOS 3 / Android 16 кейс с Binder `FAILED_TRANSACTION`:** если PackageManager-команды из текущего root-контекста не проходят Binder, модуль непрерывно не перебирает одинаково нерабочие `cmd`/`pm` варианты.
- **Добавлен runtime-профиль контекста исполнения:** capability probe теперь выбирает не только backend/verb/`--user`, но и `direct`, `su_uid2000` или `su_shell`. Shell UID используется только если безопасный probe на заведомо отсутствующем компоненте подтвердил доступ к PackageManager.
- **Без OEM-хардкода:** нет привязки к Xiaomi/HyperOS/Android 16/KernelSU; обычные устройства продолжают использовать `direct`, поэтому модуль остатся универсальным для Magisk / KernelSU / APatch и разных ROM.
- **Убран fallback storm на каждом компоненте:** после профилирования выполняется одна рабочая команда. При hard Binder failure профиль один раз инвалидируется, заново определяется и операция повторяется один раз.
- **Восстановление состояния использует отдельный профилированный action:** `enabled`, `disabled` и `default` выбирают соответствующий рабочий профиль, включая execution context.
- **Capability schema поднята до v8:** старый `capabilities.conf` автоматически будет пересоздан.

- **Тотальное трассировочное логирование всех команд:** Добавлена функция `log_cmd_exec`, логирующая саму исполняемую системную команду (`cmd`, `pm`, `dumpsys`), е выводимый результат (stdout + stderr) и код завершения (`$rc`).
- **Глубокая детализация в файле журнала:** Все низкоуровневые вызовы, зонды, перебор каскадов и изменения состояний протоколируются с точными временными метками `[YYYY-MM-DD HH:MM:SS]`.

- **Расширенный каскадный перебор:** В `cap_disable_component` добавлена поддержка обратной совместимости с `disable-user` для устройств, где OEM разрешал этот глагол для любых объектов.
- **Полная поддержка всех версий Android (7-16):** Команды отключения автоматически подстраиваются под прошивку без сбоев на любых смартфонах.

- **Автоматическая инициализация возможностей (`common.sh`):** Добавлен гарантированный вызов `ensure_capability_profile` и `load_capabilities` при инклюде библиотеки `common.sh` из любых подпроцессов и скриптов.
- **Безопасная обработка временных файлов:** Добавлены проверки существования файлов `$tmp` в `remove_state_record` и `remove_membership` перед перемещением (`mv`), предотвращающие сообщения об ошибках на чистых устройствах.
- **Живое тестирование на POCO X3 Pro (Android 16, KernelSU):** Подтверждена 100% стабильность работы зондирования и отключения компонентов на втором устройстве.

- **Исправление оценки кода возврата (POSIX Shell):** Выделено прямое сохранение `rc=$?` перед вызовами `grep` в `cap_disable_component` и `cap_set_component_state`, устранены сбои из-за особенностей конвейера `printf | grep` в Android shell.
- **Оптимизация зондирования `dumpsys`:** Убраны хрупкие регулярные выражения в `cap_probe_dump_backend`. Если системная утилита `dumpsys` доступна на прошивке, бэкенд выставляется напрямую в `dumpsys` без обрыва пайпа `Broken pipe` на Android 16.
- **Прямое тестирование по ADB:** Полная живая проверка логики отключения и сохранения состояний компонентов на устройствах Android 16 (ColorOS / HyperOS / OxygenOS) с KernelSU.

- **Каскадный механизм фолбэков (Fail-Safe Cascade):** Реализована многоуровневая цепочка выполнения команд при отключении и восстановлении компонентов (`cmd package disable --user` -> `cmd package disable` -> `pm disable --user` -> `pm disable`).
- **Специфика AOSP Component State:** Соблюдено официальное ограничение `PackageManager.java`, запрещающее использовать глагол `disable-user` (код `3`) для отдельных классов/компонентов (`ComponentName`). Для Services и Receivers используется строго `disable` (код `2`).
- **Автоматический сброс кэша:** Версия профиля повышена для гарантированного обновления параметров на устройстве.

- **Поддержка вывода пользователей Android 15/16:** Обновлены регулярные выражения для парсинга вывода `cmd user list` (`id=[0-9]+`, `User [0-9]+` помимо классического `UserInfo{`).
- **Оптимизация вызовов `cmd`:** Удалена привязка к текстам `help` парсера, команды отправляются напрямую через Binder/Shell системному PackageManager.

- **Исправление приоритета подстрок зонда:** Устранена ошибка, при которой подстрока `help` перехватывала вывод проверок бэкенда.

- Fixed Android 16/API 36 compatibility case where `cmd package help` advertises both `disable` and `disable-user`, but `disable --user ...` can fail at Binder runtime on real components.
- Operational disable priority is now `disable-user` -> `disable`; enable priority is `enable-user` -> `enable` (OEM verb is used only if actually supported).
- Capability detection now performs a non-destructive runtime/Binder probe against a guaranteed-missing component (using an installed third-party package when available) instead of trusting help/parser output alone.
- Candidates producing `Failed transaction`, Binder/RemoteException, SecurityException, unsupported/unknown command/option, or invalid component-state errors are rejected.
- Added one-time runtime self-healing: a cached backend that later fails with a hard transport/backend error invalidates the profile, re-probes once, and retries once. Ordinary target-specific failures do not trigger fallback storms.
- Split the module's operational block command from the command used to restore an original explicit `disabled` state, preserving rollback semantics as closely as the ROM allows.
- Capability profile schema bumped to v3, forcing existing v4.1 installations to re-probe automatically.

- Added one-time ROM/device capability probing during installation.
- Added persistent `capabilities.conf` with safe enum-like backend/verb selections; the file is never sourced or eval'ed.
- Runtime component operations now use one preselected PackageManager command instead of trying a fallback chain for every component.
- Added automatic capability re-probe when the profile schema or Android build fingerprint changes after an OTA/ROM update.
- Capability profile now covers disable, enable, default-state, disabled-user, disabled-until-used, user listing, package listing, `--user`, `--show-versioncode`, package dump and app watcher backend.
- Added non-destructive PackageManager command probing; no real component is toggled during detection.
- Added safe user-0 fallback when a ROM lacks complete per-user PackageManager support.
- Added package polling fallback when `inotifyd` is unavailable and a low-frequency safety poll when realtime monitoring is active.
- Action button now prints the selected compatibility profile before rescanning.

- Added interactive Volume Up/Down installer choices.
- Added independent ADS and ANALYTICS feature flags.
- Added multi-user/profile scanning and per-user state records.
- Added exact/default-state aware rollback instead of blind enable operations.
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
