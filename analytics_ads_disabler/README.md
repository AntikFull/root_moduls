## v4.8.0 — расширение покрытия

- **Network Killer: 17 SDK вместо 3.** `[ADS_NETWORK_HOST]` вырос с 6 правил до 69. Теперь хосты есть у каждого SDK, чью рекламную поверхность умеет находить индексатор. Где возможно, бьм по init/config-эндпоинтам, а не по CDN с креативами  так SDK вообще не инициализируется.
- **Отключение init-провайдеров.** Рекламные SDK стартуют через ContentProvider ещ до `Application.onCreate()`. Секция `[ADS_PROVIDER_AGGRESSIVE]` расширена с 8 до 16 точных правил плюс regex, ограниченный рекламными namespace'ами. Firebase/Sentry/androidx.startup он задеть не может по построению.
- **Мост для Xposed.** Если найден LSPosed/LSPatch/Xposed, модуль выкладывает `xposed_targets.json`  точный список пакет  SDK  поверхности  уверенность из завершнного Surface Index. Сам модуль по-прежнему ничего не хукает: это данные для модуля-компаньона, который сможет убрать и сам рекламный контейнер, а не только его загрузку. Управляется `XPOSED_BRIDGE=auto|1|0`.

## v4.7.0 — что изменилось

**Критично:**
- Пустой ответ PackageManager больше не стирает базу состояний. Раньше один сбой Binder приводил к потере и списка управляемых компонентов, и сохраннных оригинальных состояний  откатить было уже нечем.
- Удаление модуля наконец действительно откатывает компоненты. `uninstall.sh` выполняется в post-fs-data, где PackageManager ещ нет, поэтому все восстановления падали, а следом `rm -rf` уничтожал данные. Теперь откат двухфазный: на загруженной системе  сразу, иначе через отложенный воркер после `sys.boot_completed`.
- `full_rescan()` возвращал код `release_lock`, то есть всегда 0 — ошибки сканирования и fail-fast были не видны.
- Индексатор рекламных поверхностей на стоковых прошивках молча не находил ничего: `unzip -Z1` не поддерживается ни toybox, ни BusyBox.

**Универсальность:**
- BusyBox определяется по абсолютному пути (Magisk / KernelSU / KernelSU Next / APatch / busybox-ndk / system) и его апплеты добавляются в PATH. Дочерние воркеры запускаются по шебангу `#!/system/bin/sh` и не наследовали standalone-режим, а на Android ниже API 34 в системе нет ни `awk`, ни `strings`. Системные бинарники сохраняют приоритет.
- Ожидание `sys.boot_completed` ограничено 15 минутами.
- Добавлена защита критичных пакетов оболочек Xiaomi/HyperOS, Samsung, OPPO/realme/OnePlus, vivo, Huawei/Honor, Motorola, Transsion.

**Network Killer:**
- Убраны дублирующиеся правила (один хост принадлежал двум SDK-лейблам).
- Новый режим `ip`: TLS-SNI требует `xt_string`, которого нет во многих GKI-ядрах. Режим `ip` использует только `xt_owner` и работает почти везде. Включается через `AD_KILLER_IP_FALLBACK=1`.
- В логе теперь видно, какой именно матч отсутствует в ядре, и цепочка переустанавливается, если е снс netd.

**Правила:**
- `onesignal`, `braze`/`appboy` больше не отключаются автоматически — они доставляют реальные уведомления. Секция `[ANALYTICS_PUSH_RISK]`, включается через `BLOCK_PUSH_SDK=1`.
- Литеральные правила матчатся по классу компонента, а не по всей строке `пакет/класс`.

Полный список — в `CHANGELOG.md`.

---

- **v4.6.17 fixes cache/target lifecycle around the Network Killer:** network-host/comment edits no longer invalidate DEX/layout or manifest verified caches; valid 4.6.15/4.6.16 cache signatures migrate in place.
- Surface indexing now uses an atomic last-known-good log: a new traversal cannot erase the previous completed `ad_surface_scan.log`, and the Killer may bootstrap from that completed snapshot while the background refresh runs.
- **v4.6.16 adds the Banner / Native / App-Open Network Killer v1:** AGGRESSIVE can now join completed Ad Surface evidence to exact per-SDK ad hostnames and enforce them per app UID through an isolated `AAD_ADKILL` firewall chain. Safe default keeps QUIC forcing off.
- v4.6.16 also fixes recycled-PID stale Surface locks: a live PID is trusted only when its cmdline still belongs to `ad_surface_indexer.sh`.
- **v4.6.15 makes system-app scanning explicit opt-in:** installer uses `VOL+ = NO (SAFE)` and `VOL- = YES (OPT-IN)` for the system-app prompt.
- v4.6.15 also fixes Surface Index wall-clock telemetry and writes terminal `TRAVERSAL-COMPLETE` / `SUMMARY` / `STATUS` markers plus `ad_surface_index.status`, so completion or failure is unambiguous without cross-checking multiple logs.

- **v4.6.14 hardens Ad Surface indexing on Android.** DEX fingerprints are now verified deterministically one-by-one after a certified `strings` extraction (or a raw exact fallback), fixing incomplete multi-pattern binary grep results seen on real APKs.
- v4.6.14 also fixes Android `mksh` pipe-stat parsing and `E2BIG` on apps with thousands of layout resources; surface cache is bumped to `surface4`.
- **v4.6.13 moved Ad Surface indexing out of the policy-critical path.** PM/IFW reconciliation completes first; a separate read-only background indexer scans known ADS packages first and then the remaining apps. Strict RESOURCE evidence reports `CAPABILITY`, `LAYOUT_CONFIRMED`, or `MULTI_EVIDENCE`.
- **v4.6.12 made DEX surface discovery targeted.** The matcher searches configured advertising fingerprints instead of extracting/sorting every Java class descriptor.
- Surface cache is compact: unchanged APK/rules = `FULL_HIT`, changed surface rules = `RULE_RESCAN`, changed APK = `MISS`. Full DEX token lists are no longer persisted.
- **v4.6.11 introduced diagnostic Ad Surface Scanner** for banner/MREC/native/app-open/interstitial/rewarded/splash/video formats using DEX and compiled-layout evidence. These fingerprints are report-only and do not expand PM/IFW mutation policy.
- **v4.6.10 added the persistent Full Manifest Scanner cache.** `manifest_scan.log` exposes `MISS`, `PARSE_HIT`, and `FULL_HIT`; the cache lives at `/data/adb/analytics_ads_disabler/manifest_cache/v1`.

- v4.6.9 makes AGGRESSIVE safety scale with modern mediation stacks: exact ADS matches use a separate 64-component cap, and a safety hit freezes existing ownership instead of restoring ads. AGGRESSIVE+HYBRID also allows up to 64 exact ad Activities per package/category in IFW.
- The exact fullscreen allowlist now includes additional variants verified by the v4.6.8 manifest scan (Pangle/TikTok, InMobi, Bigo, BidMachine, current Vungle/MBridge/AppLovin and others); debugger/test-only Activities remain report-only.

- Full Activity Scanner now parses Android binary XML `ResStringPool` directly instead of depending on `strings(1)` heuristics. The on-disk AXML string pool is decoded according to its flag: UTF-8 or UTF-16; plain-text XML has a safe fallback.
- New `logs/manifest_scan.log` records every scanned base/split APK, parser/encoding, string/token counts, exact/audit hits, PM verification success and misses. `MANIFEST-SUMMARY` is written after a full scan.
- Action now has a five-second entry to runtime settings. ADS, analytics, SAFE/BALANCED/AGGRESSIVE, PM/HYBRID, all-users and system-app scan can be changed without reinstalling. Apply performs an atomic `settings.conf` update and immediate full reconciliation.
- Manual edits to `/data/adb/analytics_ads_disabler/settings.conf` remain supported and are applied by the existing inotify/polling config watcher.

> Runtime version metadata is read from `module.prop` (`name`, `version`, `versionCode`) and reused in logs/diagnostics, preventing stale hardcoded version labels.

[ Русский](#русский) | [ English](#english)

---

## <a name="русский"></a>  Описание (Russian)

**Analytics & Ads Disabler**  адаптивный systemless-модуль для Magisk / KernelSU / KernelSU Next / APatch. Режим `SAFE` отключает совпавшие Services/Receivers, `BALANCED` дополнительно обрабатывает только точные безопасные Provider-правила, а `AGGRESSIVE` добавляет отдельный allowlist точных рекламных Provider/Activity для более сильного подавления рекламы. Backend `PM` остатся стандартным, а опциональный `HYBRID` добавляет IFW-защиту для управляемых Services/Receivers и точных рекламных Activities. Неоднозначные Activity/Provider остаются только в аудите.

### Режимы компонентов
- `SAFE` — только совпавшие рекламные/аналитические Service и Receiver.
- `BALANCED` — SAFE + точные Provider из `*_PROVIDER_SAFE`; поведение прежнего BALANCED не изменено.
- `AGGRESSIVE` — BALANCED + отдельный allowlist точных рекламных Provider и полноэкранных рекламных Activity из `ADS_ACTIVITY_IFW`.
- `HYBRID` — отдельный backend: в AGGRESSIVE точные fullscreen Activity получают двойной слой PM disable + IFW; в SAFE/BALANCED Activity остаются IFW-only.

`AGGRESSIVE` повышает шанс убрать встроенную рекламу, но и риск несовместимости выше. Неоднозначные analytics-init Provider (`FirebaseInitProvider`, `FacebookInitProvider`, `Sentry` и т.п.) даже здесь остаются `REPORT_ONLY`. Exact-state rollback сохраняется.

### Основные возможности
-  **Runtime Adaptive Engine:** Автоматическая адаптация под версию Android и оболочку (MIUI, HyperOS, OneUI, ColorOS, Pixel и др.).
-  **Экономия заряда и ресурсов:** Отключение фоновых трекеров снижает расход батареи и оперативной памяти.
-  **Блокировка рекламы и трекинга:** Отключение рекламных ресиверов и служб сбора данных (Yandex Metrica, Google Analytics, Firebase, AppMetrica и др.).
-  **Поддержка динамического отслеживания:** Автоматически обрабатывает новые и обновляемые приложения.
-  **Белые списки:** Возможность внесения исключений в `whitelist.list`, `white_ads.list`, `white_analytics.list`.
-  **Full Activity Scanner:** В AGGRESSIVE/HYBRID resolver-таблицы дополняются чтением compiled `AndroidManifest.xml` из base/split APK. Exact Activity затем подтверждаются read-only запросом PackageManager с учтом уже disabled компонентов.
-  **Manifest Cache:** Неизменнные APK не распаковываются и не парсятся повторно на каждом reboot/Action. Изменение `rules.conf` переиспользует class-token cache, но заново вычисляет правила и PM verification; изменение APK/versionCode автоматически инвалидирует запись.
-  **Background Ad Surface Indexer:** После завершения PM/IFW policy отдельный read-only worker ищет `BANNER/MREC/NATIVE/APP_OPEN/INTERSTITIAL/REWARDED/SPLASH/VIDEO` в DEX и compiled layouts. Пакеты с уже известным ADS evidence идут первыми, поэтому диагностический DEX-индекс больше не задерживает готовность основной защиты.
-  **Ограниченный параллелизм:** Ad Surface Indexer использует до четырёх изолированных read-only воркеров с `nice=19` и `ionice=idle`. При свободной памяти менее 4 ГБ он ограничивается тремя воркерами, менее 2 ГБ — двумя, менее 1 ГБ — одним; PM/IFW и запись общего состояния не распараллеливаются.
-  **Strict RESOURCE Evidence:** DEX означает наличие API/класса SDK (`CAPABILITY`). RESOURCE разрешн только для отдельного allowlist реальных View/ViewGroup-контейнеров (`LAYOUT_CONFIRMED`); при совпадении обоих источников ставится `MULTI_EVIDENCE`.
-  **Surface Cache v4:** DEX matcher проверяет каждый fingerprint детерминированно после сертифицированного `strings`-прохода либо raw-exact fallback. Неизменнные APK/правила дают `FULL_HIT`; изменение surface-правил  `RULE_RESCAN`; изменение APK  `MISS`. Surface3 результаты v4.6.13 не переиспользуются.
-  **Deterministic Matcher:** System/BusyBox `strings` проходят self-test сразу по всем активным DEX fingerprints; принимается только backend с полным результатом. Каждый fingerprint затем проверяется отдельным fixed-string match. При отсутствии рабочего `strings` используется raw-exact fallback. Для single-pattern grep выбирается рабочий System/BusyBox backend.
-  **Surface Audit:** `ad_surface_scan.log` записывает SDK, формат, source, confidence, рекомендуемый будущий слой (`RUNTIME_NETWORK`/`COMPONENT_RUNTIME`), cache-state и время обработки APK.
-  **Fullscreen Ads Killer:** Точные fullscreen/interstitial Activity известных рекламных SDK могут быть отключены PM и, в HYBRID, дополнительно перекрыты IFW. Широкие совпадения остаются audit-only.
-  **Banner / Native / App-Open Network Killer v1:** В `AGGRESSIVE` завершнный Surface Index сопоставляется с точными рекламными hostname для обнаруженного SDK и блокируется только для UID соответствующего приложения через собственную цепочку `AAD_ADKILL`. По умолчанию используются точные HTTPS-host rules; `AD_KILLER_FORCE_TCP=0`, поэтому QUIC/UDP 443 не трогается без явного opt-in. SAFE/BALANCED сетевой Killer снимают.
-  **SDK Fingerprinter:** `sdk_fingerprint.log` показывает обнаруженные рекламные SDK и evidence по пакетам, не используя fingerprint как разрешение на отключение.
-  **Аудит компонентов:** Отчт `component_audit.log` разделяет найденные компоненты по типу, категории, риску и принятому действию.
-  **Изолированный IFW:** HYBRID использует только `/data/system/ifw/analytics_ads_disabler.xml`, не перезаписывая правила App Manager, Blocker и других программ. Поскольку IFW глобален для Android users, правило создатся только при единогласной policy для компонента во всех профилях, где установлен пакет.
-  **Точный откат:** При отключении HYBRID или удалении модуля собственный IFW-файл удаляется, а PM-компоненты возвращаются к сохраннному исходному override.
-  **Изолированный сетевой слой:** Killer не изменяет DNS/hosts и управляет только собственной filter-chain `AAD_ADKILL`. При отсутствии совместимого `iptables` owner+string backend он работает fail-open и не меняет PM/IFW.

---

**Analytics & Ads Disabler** is an adaptive systemless module for Magisk, KernelSU/Next and APatch. `SAFE` disables matched Services/Receivers, `BALANCED` additionally handles exact safe Provider rules, and `AGGRESSIVE` adds a separate allowlist of exact advertising Providers/Activities for stronger ad suppression. The default backend is `PM`; optional `HYBRID` adds isolated IFW rules for managed Services/Receivers and exact ad Activities. Ambiguous Activity/Provider matches remain report-only.

- `SAFE` — matched advertising/analytics Services and Receivers only.
- `BALANCED` — SAFE plus exact Providers from `*_PROVIDER_SAFE`; existing BALANCED behavior is unchanged.
- `AGGRESSIVE` — BALANCED plus a separate allowlist of exact advertising Providers and fullscreen Activities from `ADS_ACTIVITY_IFW`.
- `HYBRID` remains a separate backend: in AGGRESSIVE exact fullscreen Activities are disabled by PM and also blocked by IFW; SAFE/BALANCED keep Activity handling IFW-only.

`AGGRESSIVE` can suppress more embedded ads at a higher compatibility risk. Ambiguous analytics init Providers such as Firebase/Facebook/Sentry remain report-only. Exact-state rollback is preserved.

-  **Runtime Adaptive Engine:** Automatically adjusts behavior based on Android version and OEM ROM (MIUI, HyperOS, OneUI, ColorOS, Pixel, etc.).
-  **Battery & RAM Saver:** Disabling background telemetry services reduces idle battery drain and frees up memory.
-  **Ad & Telemetry Disabler:** Neutralizes analytics/tracking components (Google Analytics, Firebase, AppMetrica, Yandex Metrica, etc.).
-  **App Monitor:** Automatically applies disabler rules when new apps are installed or updated.
-  **Custom Whitelists:** Highly configurable via `whitelist.list`, `white_ads.list`, and `white_analytics.list`.
-  **Full Activity Scanner:** AGGRESSIVE/HYBRID augment resolver tables with compiled-manifest discovery from base/split APKs, followed by read-only PM confirmation.
-  **Manifest Cache:** Unchanged APKs reuse persistent scanner results on reboot/Action. Rule changes reuse parsed tokens but recompute rule/PM verification; APK/version changes invalidate automatically.
-  **Background Ad Surface Indexer:** After PM/IFW policy is ready, a separate read-only worker discovers `BANNER/MREC/NATIVE/APP_OPEN/INTERSTITIAL/REWARDED/SPLASH/VIDEO` surfaces. Packages with existing ADS evidence are indexed first, so DEX discovery never delays core policy readiness.
-  **Strict RESOURCE Evidence:** DEX means bundled SDK capability (`CAPABILITY`). RESOURCE is limited to a separate allowlist of actual View/ViewGroup ad containers (`LAYOUT_CONFIRMED`); matching both sources yields `MULTI_EVIDENCE`.
-  **Surface Cache v4:** DEX matching verifies every configured fingerprint after a certified `strings` pass or raw-exact fallback. Unchanged APK/rules yield `FULL_HIT`; surface-rule changes yield `RULE_RESCAN`; APK changes yield `MISS`. v4.6.13 surface3 sidecars are not reused.
-  **Deterministic Matcher:** System/BusyBox `strings` are certified against all active DEX fingerprints; every fingerprint is then verified with a single-pattern fixed-string check. If no strings backend passes, the indexer uses a raw-exact fallback. A working System/BusyBox grep backend is selected for these exact checks.
-  **Surface Audit:** `ad_surface_scan.log` records SDK, format, source, confidence, recommended future layer, cache state, and per-APK elapsed time.
-  **Fullscreen Ads Killer:** Exact allowlisted fullscreen/interstitial ad Activities can be disabled by PM and additionally blocked by IFW in AGGRESSIVE+HYBRID.
-  **Banner / Native / App-Open Network Killer v1:** In `AGGRESSIVE`, completed Surface Index evidence is joined with exact ad-service hostnames for the detected SDK and enforced only for that package UID through the owned `AAD_ADKILL` chain. v1 defaults to exact HTTPS host rules; `AD_KILLER_FORCE_TCP=0`, so QUIC/UDP 443 is untouched unless explicitly enabled. SAFE/BALANCED remove this network layer.
-  **SDK Fingerprinter:** `sdk_fingerprint.log` records detected ad SDK families and evidence without granting disable permission.
-  **Typed Audit:** `component_audit.log` records component type, category, risk, and selected action.
-  **Isolated IFW:** HYBRID owns a single dedicated IFW file and never rewrites third-party rule files. Because IFW is global across Android users, a component rule is emitted only when every installed user profile agrees that it should be blocked.

---

## Автор и Сообщество / Author & Community
- **Автор / Author:** eCubz ([https://t.me/eCubz](https://t.me/eCubz))
- **Telegram Чат / Support Group:** [https://t.me/module_ecubz](https://t.me/module_ecubz)

---

---

---

## Донаты и поддержка / Donations
Ваша поддержка помогает развивать и поддерживать проекты! / Your support helps keep these projects active!

- СБП: `+7 923 618-89-93`
- Т-Банк: [Перевод Т-Банк](https://www.tinkoff.ru/rm/r_qoRUrMgqrw.gQAquXjKzF/ca7Vm7131)
- Ю.Money (Яндекс): [Перевод Ю.Money](https://yoomoney.ru/to/410011494875904)
- Crypto: [USDT | GRAM (Telegram Crypto Bot)](http://t.me/send?start=IVjCT8LiszJ2)
- TON Wallet (USDT): `UQCLyovMu5882XPekfUqXOLFbYFHROaB9uoWMsIaifvMqEC4`

---

## Лицензия / License

Модуль распространяется бесплатно под лицензией MIT. При распространении сохранение авторства **eCubz** и ссылки на канал **https://t.me/module_ecubz** обязательно.

The compatibility backend only decides **how** a PackageManager state change is executed. It never decides **what** may be changed. System protection, global whitelist, category whitelist, ADS/ANALYTICS rules, and safety limits are evaluated first.

If a package is later added to `whitelist.list`, `white_ads.list`, or `white_analytics.list`, reconciliation removes only this module's matching memberships. A component is restored only when no remaining category still requires it, and restoration uses the exact override state saved before the module first touched that component. Components not tracked by this module are never bulk-enabled.

A verified learned write transport is reused for restore operations as well as disable operations. If it fails, the module falls back through the compatibility restore cascade and verifies the resulting state.

When `REALTIME_MONITOR=1` and BusyBox `inotifyd` is available, changes to `settings.conf`, `rules.conf`, `whitelist.list`, `white_ads.list`, and `white_analytics.list` trigger an immediate policy reconciliation. The watcher listens on the module data directory so both direct writes and atomic replace/rename saves are detected. A hash-based polling loop remains enabled as a safety net and deduplicates events under the global operation lock.

The authoritative configuration lives in `/data/adb/analytics_ads_disabler/`. For convenience, the same filenames under `/data/adb/modules/analytics_ads_disabler/` are symlinks to those persistent files, so either path is safe to edit.

All module log files (`debug.log`, `diagnostics.log`, `boot_trace.log`, `install_diagnostics.log`, `uninstall.log`, `component_audit.log`, `sdk_fingerprint.log`) are consolidated under `/data/adb/analytics_ads_disabler/logs/`. External user-accessible copies are mirrored under `/sdcard/eCubz/logs/Analytics_Ads_Disabler/`.

- `/data/adb/analytics_ads_disabler/logs/` is authoritative.
- `/sdcard/eCubz/logs/Analytics_Ads_Disabler/` is refreshed best-effort by a dedicated mirror worker about every 10 seconds; mirror failures never block scanning.
- `debug.previous.log` preserves the immediately previous boot/runtime debug log before `debug.log` is cleared.
- Legacy pre-unified log files are copied once to `*.legacy.log` names during upgrade when available.
- `uninstall.log` is copied to the external log directory before persistent module state is removed.

On API 36+, component-state writes do not use real shell UID 2000 as a fallback. The compatibility transport keeps uid 0 and can enter `u:r:shell:s0` only for a bounded PackageManager command. PackageManager stdin is always `/dev/null`, so no module state-file descriptor is transferred through Binder. Older Android releases keep the legacy fallback path.
