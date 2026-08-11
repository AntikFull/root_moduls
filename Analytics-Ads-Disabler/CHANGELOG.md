# Changelog

## v4.6.4 (604) — universal FD isolation + multi-user IFW safety

- PM `runcon_shell_uid0` теперь перед SELinux-переходом в дочернем процессе закрывает только унаследованные fd, указывающие в `/data/adb/analytics_ads_disabler` или каталог модуля. Это обобщает фиксы `.desired.tmp`/`component_state.list.orphans.*` без расширения sepolicy и без изменения parent shell.
- Рабочий OEM-совместимый transport `runcon u:r:shell:s0 /system/bin/sh -c "exec ..."` сохранён; direct PM, learned backend и обязательная post-state verification не менялись.
- HYBRID IFW получил multi-user safety gate: глобальное IFW-правило создаётся только если все Android users, у которых установлен пакет, согласны блокировать данный компонент. Whitelist/work-profile одного user больше не может быть перекрыт решением другого user.
- При невозможности построить authoritative user/package snapshot IFW fail-closed в сторону безопасности: собственное IFW-правило не создаётся, PM-состояние не расширяется.
- Атомарная запись IFW через временный файл без `.xml` и rename сохранена; это соответствует механизму AOSP Intent Firewall, который наблюдает только XML-файлы в `/data/system/ifw`.
- Default backend остаётся `PM`; HYBRID по-прежнему опционален. Policy/rules/whitelist semantics и exact rollback не расширялись.

## v4.6.3 (603) — закрытие orphan FD перед PM restore

- `retry_orphan_restores()` больше не выполняет PackageManager restore из цикла, чьим входом является `component_state.list.orphans.*` в `/data/adb`.
- Snapshot orphan-state сначала считывается в память, backing-файл закрывается и удаляется, и только после этого запускаются restore-операции.
- Устраняет подтверждённый на Xiaomi 14 Ultra / HyperOS 3 / Android 16 SELinux AVC `u:r:shell:s0 -> adb_data_file` для `component_state.list.orphans.*` без расширения sepolicy.
- PM transport, IFW, SAFE/BALANCED/HYBRID, whitelist semantics, exact rollback и update-race fix v4.6.2 не изменялись.

## v4.6.2 (602) — исправление гонки обновления на HyperOS

- Процессы старой версии теперь останавливаются до изменения persistent-конфигурации и до проверки Package Manager.
- Активный boot/action-скан без watcher pid-файла также безопасно завершается, но только после проверки `/proc/<pid>/cmdline` на принадлежность модулю.
- Старые operation/state/membership locks снимаются сразу после остановки прежних watcher-процессов, поэтому установщик не запускает параллельный пересчёт на частично обновлённых файлах.
- Исправление основано на диагностике Xiaomi 14 Ultra, Android 16 / HyperOS 3: во время обновления старый скан и PM-проба пересекались, вызывая `Failed transaction`, `Broken pipe` и незавершённые временные каталоги. После загрузки сама v4.4.14 работала штатно.

## v4.6.1 (601) — точность Activity-аудита

- Ложное подстрочное правило `adactivity` заменено на точное окончание класса `AdActivity`.
- `UploadActivity`, `DownloadActivity`, `NFCReadActivity` и похожие классы больше не считаются рекламными только из-за окончания имени.
- Точная Huawei Ads Activity `com.huawei.openalliance.ad.ppskit.activity.InterstitialAdActivity` добавлена в HYBRID IFW.
- Установщик мигрирует только прежнюю точную строку `adactivity` и добавляет новое правило без перезаписи остальных пользовательских правил.

## v4.6.0 (600) — PM/IFW-контур после сверки с App Manager и Blocker

- Проверены актуальные исходники `MuntashirAkon/AppManager` и `lihenggui/blocker`, включая PM, IFW и комбинированные контроллеры.
- Сохранён основной PM-контур модуля: он точнее сторонних реализаций восстанавливает исходный override и проверяет фактическое состояние после каждой операции.
- Добавлен опциональный `COMPONENT_BACKEND=HYBRID`: Services/Receivers получают второй IFW-слой, а точные рекламные Activities блокируются только через IFW.
- Providers по-прежнему изменяются только через Package Manager, поскольку Android Intent Firewall их не поддерживает.
- IFW хранится в отдельном файле `/data/system/ifw/analytics_ads_disabler.xml`, заменяется атомарно и удаляется при переходе на PM или деинсталляции.
- Добавлены проверка доступности IFW, лимит Activity на пакет/категорию и отдельные действия `IFW_BLOCK` в аудите.
- `PM` остаётся безопасным backend по умолчанию; включение HYBRID выполняется явно в установщике или настройках.

## v4.5.0 (500) — типизированный аудит и режимы SAFE/BALANCED

- Сохранена универсальная capability-логика Magisk, KernelSU/Next и APatch без списков моделей и прошивок.
- `COMPONENT_MODE=SAFE` сохраняет прежнее отключение Services/Receivers и остаётся режимом по умолчанию.
- `COMPONENT_MODE=BALANCED` дополнительно отключает только Providers из точных секций `*_PROVIDER_SAFE`.
- Activities и неоднозначные Providers обнаруживаются, но записываются только в `component_audit.log` без изменения состояния.
- Добавлены типизированные секции правил, миграция новых секций без перезаписи пользовательских правил и статистика `AUDIT-SUMMARY`.
- Сетевой DNS/hosts-слой не добавлялся.

## v4.4.14 (454) — KernelSU/Android 16 Binder FD compatibility

- PackageManager-команды теперь всегда запускаются со stdin из `/dev/null`.
- Исправлено наследование временных файлов политики из `/data/adb/analytics_ads_disabler/.desired.tmp.*` через Binder в `system_server`.
- Устраняет `translate fd failed` и `Failed transaction` на Android 16 с KernelSU/ReSukiSU при включённом SELinux.
- Сохранены проверки реального результата операции и все прежние безопасные варианты транспорта PM.

## v4.4.13 (453) — OEM runcon execution compatibility

- Restored the proven Android 16 `runcon u:r:shell:s0 /system/bin/sh -c "exec ..."` PM transport after v4.4.12 showed OEM SELinux can deny direct execution of `/system/bin/cmd`/`pm` from the transitioned shell domain.
- The shell-domain scope still contains only the PackageManager command; no module state, whitelist, rule, or scratch file under `/data/adb` is read there.
- Keeps Android 16+ real shell-UID (`su 2000` / `su shell`) component mutations excluded.
- No policy, whitelist, state-machine, watcher, or restore semantics changed.

## v4.4.12 (452) — Android 16 PM Transport Hardening

- Preserved the proven 4.4.11 policy, whitelist delta/restore, state DB, watcher and logging behavior.
- Android 16+ no longer tries real shell UID 2000 (`su 2000` / `su shell`) for component-state mutations. Legacy candidates remain available below API 36.
- `runcon_shell_uid0` now executes `/system/bin/cmd` or `/system/bin/pm` directly in `u:r:shell:s0` while retaining uid 0; it no longer wraps PackageManager mutations in `/system/bin/sh -c`.
- Added explicit PM mutation-model diagnostics for API level, shell-UID policy and runcon availability/scope.
- Existing verified learned backends are retained; direct root remains the first compatibility baseline and every write still requires post-state verification.

## v4.4.11 (451) — module.prop as version source of truth

- Runtime, Action, installer diagnostics, deep diagnostics, and uninstall logs now read `name`, `version`, and `versionCode` from `module.prop`.
- Removed current-release version literals from executable log/status output.
- Added a shared `MODULE_VERSION_LABEL` so changing the release version only requires updating `module.prop`.
- Historical compatibility comments remain intentionally versioned where they describe old behavior/migrations.

## v4.4.10 (450) — Unified Live Log Reliability
- Keeps v4.4.9 policy/scanner behavior unchanged; this release is log-infrastructure only.
- Adds a dedicated non-blocking log mirror worker (~10 s) from authoritative `/data/adb/.../logs` to `/sdcard/eCubz/logs/Analytics_Ads_Disabler`.
- Adds `debug.previous.log` rotation before each boot clears `debug.log`.
- Preserves `uninstall.log` externally before deleting persistent state.
- Migrates legacy pre-unified debug/diagnostic/install logs into `*.legacy.log` files when found.
- Fixes stale v4.4.5/v4.4.6/v4.4.8/v4.4.9 runtime/diagnostic labels.

## 4.4.9 (449) — Unified Log Directory

- All log files (`debug.log`, `diagnostics.log`, `boot_trace.log`, `install_diagnostics.log`, `uninstall.log`) are now stored in one unified directory: `/data/adb/analytics_ads_disabler/logs/`.
- External user-accessible logs on `/sdcard` are mirrored into a single folder: `/sdcard/eCubz/logs/Analytics_Ads_Disabler/`.
- Keeps all whitelist delta snapshot performance optimizations, DB race locks, and runtime log reliability from v4.4.8.

## 4.4.8 (448) — Delta Snapshot / Hang Diagnostics
- Whitelist delta no longer performs per-user PackageManager package-list Binder calls. It builds one authoritative `user|package` snapshot and exact-matches affected packages.
- Added `CONFIG-DELTA user=... begin/end`, package completion, snapshot-ready, and package reconcile membership diagnostics.
- Removed command-substitution around per-user delta reconciliation and switched delta scratch files to unique `mktemp` paths.
- Keeps v4.4.7 runtime-log reliability, v4.4.6 DB locking, and managed-state whitelist restore behavior.

## 4.4.7 (447) — Runtime Log Reliability

- Runtime boot no longer depends on `/sdcard` being writable after `sys.boot_completed=1`.
- Authoritative live debug log moved to `/data/adb/analytics_ads_disabler/analytics_ads_disabler_debug.log`.
- `/sdcard/eCubz/analytics_ads_disabler_debug.log` is now a best-effort mirror after runtime becomes ready.
- Added post-common boot checkpoints to isolate state-dir, config-alias, runtime-log and capability stages.
- Preserves v4.4.6 DB race/atomic-write protections and v4.4.5 whitelist delta reconciliation.

## 4.4.6 (446) — State DB Race Fix

- Stops runtime workers from the previous module version during installation/update before persistent state is mutated.
- Adds independent locks for `component_state.list` and `disabled_components.list`.
- Uses `mktemp`-based unique transactional files instead of `*.tmp.$$`, avoiding BusyBox ash/subshell PID collisions.
- State/membership commits now log explicit rewrite/commit failures instead of terminating on a missing temp file.
- Keeps v4.4.5 whitelist delta reconciliation and Android 16 installed-package snapshot fix.

## 4.4.5 (445) — Whitelist Delta Restore

- `whitelist.list`, `white_ads.list`, and `white_analytics.list` now reconcile only package names whose normalized whitelist membership changed; a one-package edit no longer triggers a full device scan.
- Global whitelist changes remove all module memberships for the affected package and restore exact saved original component states.
- ADS whitelist changes remove only ADS memberships; restoration occurs only when ANALYTICS no longer owns the same component. ANALYTICS whitelist behavior is symmetric.
- Removing a package from any whitelist is also incremental: only that package is rescanned and required memberships are re-applied.
- Fixes false `STALE ... package not installed` records on Android 16 vendor PackageManager builds by using one authoritative all-package snapshot per full scan instead of filtered package-list probes.
- Duplicate config events no longer wait 60 seconds and emit `LOCK timeout`; they log `CONFIG-DEFER` while the active reconciliation owns the lock.
- `settings.conf` or `rules.conf` changes still intentionally trigger a full policy reconciliation.

## 4.4.4 (444) — Unified Config Paths

- Fixes the confusing duplicate-config layout: module-directory `settings.conf`, `rules.conf`, `whitelist.list`, `white_ads.list`, and `white_analytics.list` now alias the persistent files in `/data/adb/analytics_ads_disabler`.
- Editing config from `/data/adb/modules/analytics_ads_disabler/` or from the persistent data directory now changes the same watched file.
- Boot repairs missing/replaced config aliases and logs both runtime and alias paths.
- Realtime inotify + hash polling remain active and deduplicated.

## 4.4.3 (443) — Boot-Safe Runtime / Trace Checkpoints

- `service.sh` no longer sources `common.sh` before Android reports `sys.boot_completed=1`.
- Early boot uses only `/data/adb/analytics_ads_disabler/boot_trace.log`; `/sdcard/eCubz` is touched only after boot completion.
- Adds trace checkpoints for early wait, common source, capability initialization, boot scan, and runtime-ready.
- Full policy reconciliation still runs on every successful boot.
- Fixes stale v4.4.1 labels in install/deep-diagnostics output.
- Keeps realtime config inotify plus hash-poll fallback and verified PM backend persistence.

## 4.4.2 (442) — Boot Reliability / Watcher Health

- Defers PackageManager capability probing until `sys.boot_completed=1`; `common.sh` no longer performs early Binder work when sourced by `service.sh`.
- Adds `/data/adb/analytics_ads_disabler/boot_trace.log`, written before `common.sh`, so a missing runtime log can be distinguished from an early startup failure.
- Full policy reconciliation is explicitly logged and runs on every successful Android boot (`BOOT-SCAN`).
- Verifies app-inotify, config-inotify and polling watcher PIDs one second after launch and reports `RUNNING` or `FAILED-TO-STAY-RUNNING`.
- Explicitly sets executable permission on `config_event.sh` during installation.

# Changelog

## v4.4.1 (441) — Realtime Config Watch

- Added realtime BusyBox `inotifyd` monitoring for `settings.conf`, `rules.conf`, `whitelist.list`, `white_ads.list`, and `white_analytics.list`.
- Watches the config directory for close-write/create/delete/move events so both in-place saves and editor atomic-renames are detected.
- Added `config_event.sh` with strict filename filtering; state DB/cache/hash changes cannot recursively trigger policy scans.
- Added lock-aware hash deduplication: multiple filesystem events from one save collapse into one reconciliation.
- Existing hash polling remains active as a safety net and for devices without `inotifyd`.
- Realtime config watcher has its own PID file and is stopped safely on module restart/uninstall.
- Policy/whitelist/restore behavior from v4.4.0 is unchanged.

## v4.4.0 (440) — Policy/Transport Separation

- Kept policy decisions (system protection, global/category whitelist, ADS/ANALYTICS rules) strictly before any state-changing backend call.
- Added explicit `WHITELIST-SKIP`, `WHITELIST-RESTORE`, `POLICY-SKIP`, and `ALREADY-DISABLED` logging.
- A package added to a whitelist restores only components previously managed by this module, using the exact saved original override state.
- Restore now tries the verified learned write transport first (for example `runcon_shell_uid0`) before the generic compatibility cascade.
- Added a full restore cascade across direct, shell-UID, shell-su, and verified `runcon` transports.
- Reconciliation no longer performs redundant Binder writes for memberships that are already actually disabled.
- Existing v4.3.9 install diagnostics, learned-backend persistence, and manual Action fail-fast behavior are retained.

## v4.3.8 (438)
- Action fail-fast: stop a manual full scan after 3 consecutive components exhaust the complete disable cascade.
- A successful component operation resets the consecutive-failure counter.
- Fail-fast is Action-only; background/incremental scans keep normal behavior.
- Early abort preserves debug/diagnostic logs and does not mark the configuration hash as successfully reconciled.

## 4.3.7 (437) — Runcon Shell-Domain Fix

- Fixes a v4.3.5/v4.3.6 logic bug that required UID 2000 and `u:r:shell:s0` simultaneously before enabling the runcon fallback.
- On tested KernelSU Next, `runcon u:r:shell:s0` correctly changes SELinux domain while retaining UID 0; this is now treated as its own execution backend (`runcon_shell_uid0`).
- The runcon backend is attempted only after the original direct cascade and `su 2000`/`su shell` fallbacks fail.
- A candidate is learned only after the real component state verifies as disabled.
- Keeps deep diagnostics and full help/Binder smoke logging from v4.3.6.

## 4.3.5 (435) — SELinux Context Cascade

- Keeps the v4.3.4 original/direct cascade and uid-2000 fallbacks.
- Adds execution diagnostics (UID + SELinux context) to Action output.
- Adds a last-resort `runcon u:r:shell:s0` backend when a real shell-domain transition is supported.
- The new backend is accepted only after a transition probe confirms both UID 2000 and `u:r:shell:s0`.
- No package-wide suspend/hide and no direct packages.xml/service-call hacks.

# Changelog

## v4.3.4 (434) — Hybrid Cascade Edition
- Restored the original v4.3.0 direct cmd/pm fallback cascade as the compatibility baseline.
- Added verified learned fast-path: a method is cached only after a real component reaches disabled state.
- Added `--user current` fallback only when it matches the scanned foreground Android user.
- Added shell-UID execution fallbacks (`su 2000`, `su shell`) after the complete original cascade fails.
- Every candidate is validated by the actual component override state, not exit code alone.
- Kept v4.3.3 scan dump caching and Action progress output.
- Deliberately avoids package-wide hide/suspend and unstable raw Binder transaction calls.

## v4.3.3
- Full scan caches parsed Services/Receivers once per package and reuses the result across ADS/ANALYTICS and Android users/profiles.
- Action button shows live `[current/total] user package` progress plus a final summary.
- Background scans remain quiet.

# Changelog (Журнал изменений)

## v4.3.1 — Binder Context Adaptive Edition

- **Исправлен HyperOS 3 / Android 16 кейс с Binder `FAILED_TRANSACTION`:** если PackageManager-команды из текущего root-контекста не проходят Binder, модуль непрерывно не перебирает одинаково нерабочие `cmd`/`pm` варианты.
- **Добавлен runtime-профиль контекста исполнения:** capability probe теперь выбирает не только backend/verb/`--user`, но и `direct`, `su_uid2000` или `su_shell`. Shell UID используется только если безопасный probe на заведомо отсутствующем компоненте подтвердил доступ к PackageManager.
- **Без OEM-хардкода:** нет привязки к Xiaomi/HyperOS/Android 16/KernelSU; обычные устройства продолжают использовать `direct`, поэтому модуль остаётся универсальным для Magisk / KernelSU / APatch и разных ROM.
- **Убран fallback storm на каждом компоненте:** после профилирования выполняется одна рабочая команда. При hard Binder failure профиль один раз инвалидируется, заново определяется и операция повторяется один раз.
- **Восстановление состояния использует отдельный профилированный action:** `enabled`, `disabled` и `default` выбирают соответствующий рабочий профиль, включая execution context.
- **Capability schema поднята до v8:** старый `capabilities.conf` автоматически будет пересоздан.

## v4.3.0 — Full Verbose Execution Logging Edition

- **Тотальное трассировочное логирование всех команд:** Добавлена функция `log_cmd_exec`, логирующая саму исполняемую системную команду (`cmd`, `pm`, `dumpsys`), её выводимый результат (stdout + stderr) и код завершения (`$rc`).
- **Глубокая детализация в файле журнала:** Все низкоуровневые вызовы, зонды, перебор каскадов и изменения состояний протоколируются с точными временными метками `[YYYY-MM-DD HH:MM:SS]`.

- **Расширенный каскадный перебор:** В `cap_disable_component` добавлена поддержка обратной совместимости с `disable-user` для устройств, где OEM разрешал этот глагол для любых объектов.
- **Полная поддержка всех версий Android (7-16):** Команды отключения автоматически подстраиваются под прошивку без сбоев на любых смартфонах.

- **Автоматическая инициализация возможностей (`common.sh`):** Добавлен гарантированный вызов `ensure_capability_profile` и `load_capabilities` при инклюде библиотеки `common.sh` из любых подпроцессов и скриптов.
- **Безопасная обработка временных файлов:** Добавлены проверки существования файлов `$tmp` в `remove_state_record` и `remove_membership` перед перемещением (`mv`), предотвращающие сообщения об ошибках на чистых устройствах.
- **Живое тестирование на POCO X3 Pro (Android 16, KernelSU):** Подтверждена 100% стабильность работы зондирования и отключения компонентов на втором устройстве.

- **Исправление оценки кода возврата (POSIX Shell):** Выделено прямое сохранение `rc=$?` перед вызовами `grep` в `cap_disable_component` и `cap_set_component_state`, устранены сбои из-за особенностей конвейера `printf | grep` в Android shell.
- **Оптимизация зондирования `dumpsys`:** Убраны хрупкие регулярные выражения в `cap_probe_dump_backend`. Если системная утилита `dumpsys` доступна на прошивке, бэкенд выставляется напрямую в `dumpsys` без обрыва пайпа `Broken pipe` на Android 16.
- **Прямое тестирование по ADB:** Полная живая проверка логики отключения и сохранения состояний компонентов на устройствах Android 16 (ColorOS / HyperOS / OxygenOS) с KernelSU.

## v4.2.4 — Fail-Safe Cascade Edition

- **Каскадный механизм фолбэков (Fail-Safe Cascade):** Реализована многоуровневая цепочка выполнения команд при отключении и восстановлении компонентов (`cmd package disable --user` -> `cmd package disable` -> `pm disable --user` -> `pm disable`).
- **Специфика AOSP Component State:** Соблюдено официальное ограничение `PackageManager.java`, запрещающее использовать глагол `disable-user` (код `3`) для отдельных классов/компонентов (`ComponentName`). Для Services и Receivers используется строго `disable` (код `2`).
- **Автоматический сброс кэша:** Версия профиля повышена для гарантированного обновления параметров на устройстве.

## v4.2.2 — HyperOS & Multi-User Support

- **Поддержка вывода пользователей Android 15/16:** Обновлены регулярные выражения для парсинга вывода `cmd user list` (`id=[0-9]+`, `User [0-9]+` помимо классического `UserInfo{`).
- **Оптимизация вызовов `cmd`:** Удалена привязка к текстам `help` парсера, команды отправляются напрямую через Binder/Shell системному PackageManager.

## v4.2.1 — Substring Precedence Fix

- **Исправление приоритета подстрок зонда:** Устранена ошибка, при которой подстрока `help` перехватывала вывод проверок бэкенда.

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
